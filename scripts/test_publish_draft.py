import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('publish_draft', Path(__file__).with_name('publish-draft.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
SHA = 'a' * 40


class FakeGitHub:
    def __init__(self, *, draft=True, sha=SHA, existing=True):
        self.repository = 'hikariatama/libnutri'
        self.existing = existing
        self.sha = sha
        self.release = {'id': 1, 'tag_name': 'v0.0.1', 'draft': draft, 'upload_url': 'https://uploads.github.com/assets{?name}'}
        self.assets = [{'id': 2, 'name': 'stale-package.zip'}] if existing else []
        self.mutations = []

    def pages(self, path):
        return iter(([self.release] if self.existing else []) if path == '/releases' else list(self.assets))

    def request(self, method, path, data=None, *, upload=None):
        if method == 'GET':
            return {'object': {'sha': self.sha}}
        self.mutations.append((method, path, data))
        if method == 'DELETE':
            self.assets = []
            return None
        if upload is not None:
            asset = {'id': 3, 'name': upload.name, 'size': upload.stat().st_size,
                     'digest': 'sha256:' + hashlib.sha256(upload.read_bytes()).hexdigest()}
            self.assets.append(asset)
            return asset
        if path in ('/releases/1', '/releases'):
            self.release.update(data)
            return self.release
        return {}


class DraftReleaseTests(unittest.TestCase):
    def test_missing_package_fails_before_publishing(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(ValueError):
                release.collect_artifacts(Path(root), ['missing.zip'])

    def test_draft_rebuild_retargets_tag_and_replaces_all_assets(self):
        github = FakeGitHub()
        with tempfile.TemporaryDirectory() as root:
            package = Path(root) / 'app.zip'
            package.write_bytes(b'verified build')
            files = release.collect_artifacts(Path(root), ['app.zip'])
            notes = Path(__file__).with_name('release-notes.md').read_text().strip()
            draft, _ = release.publish(github, '0.0.1', SHA, files, notes=notes)
        self.assertTrue(draft['draft'])
        self.assertEqual(draft['name'], 'libnutri v0.0.1')
        self.assertEqual(draft['body'], notes)
        self.assertEqual({a['name'] for a in github.assets}, {'app.zip', 'SHA256SUMS.txt'})
        self.assertIn(('PATCH', '/git/refs/tags/v0.0.1', {'sha': SHA, 'force': True}), github.mutations)
        self.assertTrue(any(method == 'DELETE' for method, _, _ in github.mutations))

    def test_first_release_starts_as_draft(self):
        github = FakeGitHub(existing=False)
        with tempfile.TemporaryDirectory() as root:
            package = Path(root) / 'app.zip'
            package.write_bytes(b'first build')
            files = release.collect_artifacts(Path(root), ['app.zip'])
            current, _ = release.publish(github, '0.0.1', SHA, files)
        self.assertTrue(current['draft'])
        self.assertTrue(any(method == 'POST' and path == '/releases' for method, path, _ in github.mutations))
        self.assertFalse(any(method == 'DELETE' for method, _, _ in github.mutations))

    def test_published_rebuild_replaces_assets_without_unpublishing(self):
        github = FakeGitHub(draft=False)
        with tempfile.TemporaryDirectory() as root:
            package = Path(root) / 'app.zip'
            package.write_bytes(b'rebuilt package')
            files = release.collect_artifacts(Path(root), ['app.zip'])
            current, uploaded = release.publish(github, '0.0.1', SHA, files)
        self.assertFalse(current['draft'])
        self.assertEqual(current['id'], 1)
        self.assertEqual({a['name'] for a in github.assets}, {'app.zip', 'SHA256SUMS.txt'})
        self.assertEqual(len(uploaded), 2)
        self.assertIn(('PATCH', '/git/refs/tags/v0.0.1', {'sha': SHA, 'force': True}), github.mutations)

    def test_stale_build_cannot_replace_current_draft(self):
        github = FakeGitHub(sha='b' * 40)
        with self.assertRaises(RuntimeError):
            release.publish(github, '0.0.1', SHA, {})
        self.assertEqual(github.mutations, [])


if __name__ == '__main__':
    unittest.main()
