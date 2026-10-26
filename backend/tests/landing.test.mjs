import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { landing } from '../dist/landing.js';

test('landing serves allowlisted files and leaves API clients on JSON', async () => {
  const site = landing();
  const server = createServer((req, res) => {
    if (site(req, res, new URL(req.url, 'http://x').pathname)) return;
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end('{"error":"not_found"}');
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = 'http://127.0.0.1:' + server.address().port;
  try {
    const page = await fetch(base + '/', { headers: { Accept: 'text/html' } });
    assert.equal(page.status, 200);
    assert.match(page.headers.get('content-type'), /^text\/html/);
    assert.match(page.headers.get('content-security-policy'), /default-src 'none'/);
    assert.match(await page.text(), /The simplest nutrition tracker/);

    const api = await fetch(base + '/', { headers: { Accept: 'application/json' } });
    assert.equal(api.status, 404);

    for (const [path, type] of [
      ['/style.css', 'text/css'],
      ['/main.js', 'text/javascript'],
      ['/fonts/huninn-subset.woff2', 'font/woff2'],
      ['/icons/mic.png', 'image/png'],
    ]) {
      const asset = await fetch(base + path);
      assert.equal(asset.status, 200, path);
      assert.match(asset.headers.get('content-type'), new RegExp('^' + type));
    }

    for (const path of ['/index.html', '/../package.json', '/fonts/', '/landing/main.js']) {
      assert.equal((await fetch(base + path)).status, 404, path);
    }
    assert.equal((await fetch(base + '/style.css', { method: 'POST' })).status, 404);
  } finally {
    server.close();
  }
});
