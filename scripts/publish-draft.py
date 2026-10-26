#!/usr/bin/env python3
"""Replace verified artifacts in the current version's GitHub draft release."""
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request


class GitHub:
    def __init__(self, repository, token, api_url='https://api.github.com'):
        self.repository = repository
        self.token = token
        self.api_url = api_url.rstrip('/')

    def request(self, method, path, data=None, *, upload=None):
        url = path if path.startswith('https://') else self.api_url + '/repos/' + self.repository + path
        headers = {'Authorization': 'Bearer ' + self.token, 'Accept': 'application/vnd.github+json',
                   'X-GitHub-Api-Version': '2022-11-28'}
        if upload is not None:
            payload = upload.read_bytes()
            headers['Content-Type'] = 'application/octet-stream'
        else:
            payload = json.dumps(data).encode() if data is not None else None
            headers['Content-Type'] = 'application/json'
        request = urllib.request.Request(url, data=payload, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            raise RuntimeError(f'GitHub {method} request failed: HTTP {error.code}') from None

    def pages(self, path):
        page = 1
        while True:
            rows = self.request('GET', path + f'?per_page=100&page={page}')
            if not isinstance(rows, list):
                raise RuntimeError('GitHub did not return a list')
            yield from rows
            if len(rows) < 100:
                break
            page += 1


def collect_artifacts(directory, expected):
    files = {}
    for path in directory.rglob('*'):
        if not path.is_file():
            continue
        if path.is_symlink() or path.name in files:
            raise ValueError('Distribution contains symlinks or duplicate filenames')
        if path.stat().st_size == 0:
            raise ValueError('Distribution contains an empty file')
        files[path.name] = path
    if set(files) != set(expected):
        missing = sorted(set(expected) - set(files))
        extra = sorted(set(files) - set(expected))
        raise ValueError(f'Distribution mismatch: missing={missing}, unexpected={extra}')
    sums = directory / 'SHA256SUMS.txt'
    sums.write_text(''.join(hashlib.sha256(files[name].read_bytes()).hexdigest() + '  ' + name + '\n'
                            for name in sorted(files)))
    files[sums.name] = sums
    return files


def publish(github, version, sha, files, *, ref='refs/heads/main', notes=''):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('Invalid release version or commit')
    tag = 'v' + version
    if ref == 'refs/heads/main':
        head = github.request('GET', '/git/ref/heads/main')
        if not head or head['object']['sha'] != sha:
            raise RuntimeError('A newer commit exists; rebuild the latest main commit')
    elif ref != 'refs/tags/' + tag:
        raise ValueError('Releases can only be built from main or their matching version tag')
    existing = next((r for r in github.pages('/releases') if r['tag_name'] == tag), None)
    draft = existing['draft'] if existing else True

    reference = '/git/refs/tags/' + tag
    tag_ref = github.request('GET', '/git/ref/tags/' + tag)
    if tag_ref:
        github.request('PATCH', reference, {'sha': sha, 'force': True})
    else:
        github.request('POST', '/git/refs', {'ref': 'refs/tags/' + tag, 'sha': sha})
    payload = {'tag_name': tag, 'target_commitish': sha, 'name': github.repository.rsplit('/', 1)[-1] + ' ' + tag, 'draft': draft, 'prerelease': False,
               'body': notes.strip()}
    if existing:
        release = github.request('PATCH', '/releases/' + str(existing['id']), payload)
        for asset in github.pages('/releases/' + str(existing['id']) + '/assets'):
            github.request('DELETE', '/releases/assets/' + str(asset['id']))
    else:
        release = github.request('POST', '/releases', payload)
    if not release or release.get('draft') != draft:
        raise RuntimeError('GitHub changed the release publication state')
    uploaded = []
    for name, path in sorted(files.items()):
        url = release['upload_url'].split('{', 1)[0] + '?name=' + urllib.parse.quote(name)
        asset = github.request('POST', url, upload=path)
        digest = 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest()
        if not asset or asset.get('size') != path.stat().st_size or asset.get('digest', digest) != digest:
            raise RuntimeError('Uploaded asset verification failed: ' + name)
        uploaded.append(asset)
    current = list(github.pages('/releases/' + str(release['id']) + '/assets'))
    if {a['name'] for a in current} != set(files):
        raise RuntimeError('GitHub release assets differ from the distribution')
    return release, uploaded


def main():
    root = Path(__file__).resolve().parents[1]
    version = (root / 'VERSION').read_text().strip()
    expected = [x['name'].replace('{version}', version) for x in json.loads((root / 'scripts/release-assets.json').read_text())]
    directory = Path(sys.argv[1] if len(sys.argv) > 1 else 'artifacts')
    files = collect_artifacts(directory, expected)
    github = GitHub(os.environ['GITHUB_REPOSITORY'], os.environ['GH_TOKEN'])
    release, assets = publish(github, version, os.environ['GITHUB_SHA'], files, ref=os.environ['GITHUB_REF'], notes=(root / 'scripts/release-notes.md').read_text().strip())
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as output:
            state = 'draft' if release['draft'] else 'published'
            output.write(f"### [{release['name']}]({release['html_url']}) · {state}\n\n")
            output.write('| Package | Bytes |\n| --- | ---: |\n')
            for asset in assets:
                output.write(f"| {asset['name']} | {asset['size']} |\n")
    print(f"Release {release['tag_name']}: {len(assets)} verified assets")


if __name__ == '__main__':
    main()
