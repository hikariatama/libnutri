import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { OAuth } from '../dist/oauth.js';

test('MCP tool scopes receive rotating refresh tokens that survive expiry and restart', async () => {
  const dir = mkdtempSync(tmpdir() + '/nutri-mcp-refresh-');
  const origin = 'https://nutri.avx.so',
    resource = origin + '/mcp';
  const owner = 'gate_session=owner_owner_owner_owner_owner';
  const gate = createServer((req, res) => {
    res.writeHead(req.headers.cookie === owner ? 200 : 403, { 'Content-Type': 'application/json' });
    res.end('{"owner":true}');
  });
  await new Promise((r) => gate.listen(0, '127.0.0.1', r));
  process.env.OWNER_GATE_URL = 'http://127.0.0.1:' + gate.address().port;
  let oauth = new OAuth(origin, dir);
  const app = createServer((req, res) => {
    void oauth.handle(req, res, new URL(req.url, origin));
  });
  await new Promise((r) => app.listen(0, '127.0.0.1', r));
  const request = (path, options = {}) =>
    fetch('http://127.0.0.1:' + app.address().port + path, { redirect: 'manual', ...options });
  const form = (path, data, headers = {}) =>
    request(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', ...headers },
      body: new URLSearchParams(data),
    });
  const digest = (value) => createHash('sha256').update(value).digest('hex');
  try {
    const verifier = 'v'.repeat(64);
    const params = {
      client_id: 'nutrition-ios',
      redirect_uri: 'nutritiontracker://oauth/callback',
      response_type: 'code',
      code_challenge_method: 'S256',
      code_challenge: createHash('sha256').update(verifier).digest('base64url'),
      resource,
      scope: 'nutrition:read nutrition:write',
    };
    const consent = await request('/oauth/authorize?' + new URLSearchParams(params), {
      headers: { cookie: owner },
    });
    assert.equal(consent.status, 200);
    const csrf = /name="csrf" value="([^"]+)"/.exec(await consent.text())[1];
    const accepted = await form(
      '/oauth/consent',
      { csrf, decision: 'allow' },
      { cookie: owner + '; ' + consent.headers.get('set-cookie').split(';')[0], origin },
    );
    assert.equal(accepted.status, 303);
    const response = await form('/oauth/token', {
      grant_type: 'authorization_code',
      client_id: params.client_id,
      redirect_uri: params.redirect_uri,
      resource,
      code_verifier: verifier,
      code: new URL(accepted.headers.get('location')).searchParams.get('code'),
    });
    assert.equal(response.status, 200);
    const initial = await response.json();
    assert.equal(initial.scope, params.scope);
    assert.equal(initial.expires_in, 900);
    assert.equal(typeof initial.refresh_token, 'string');
    assert(oauth.verify(initial.access_token, 'nutrition:write', resource));
    assert(!oauth.verify(initial.access_token, 'nutrition:read', origin));
    const db = new DatabaseSync(dir + '/state.sqlite');
    db.prepare('UPDATE tokens SET expires=0 WHERE digest=?').run(digest(initial.access_token));
    assert(!oauth.verify(initial.access_token, 'nutrition:read', resource));
    oauth.db.close();
    oauth = new OAuth(origin, dir);
    const refresh = {
      grant_type: 'refresh_token',
      client_id: params.client_id,
      refresh_token: initial.refresh_token,
    };
    assert.equal((await form('/oauth/token', { ...refresh, resource: origin })).status, 400);
    const renewed = await form('/oauth/token', refresh);
    assert.equal(renewed.status, 200);
    const next = await renewed.json();
    assert.equal(next.scope, params.scope);
    assert.notEqual(next.refresh_token, initial.refresh_token);
    assert(oauth.verify(next.access_token, 'nutrition:write', resource));
    assert(!oauth.verify(next.access_token, 'nutrition:read', origin));
    assert.equal(
      (
        await form('/oauth/token', {
          ...refresh,
          refresh_token: next.refresh_token,
          scope: params.scope + ' offline_access',
        })
      ).status,
      400,
    );
    assert.equal(
      (await form('/oauth/token', { ...refresh, refresh_token: next.refresh_token, resource }))
        .status,
      200,
    );
    assert.equal((await form('/oauth/token', refresh)).status, 400);
    assert(!oauth.verify(next.access_token, 'nutrition:read', resource));
    db.close();
  } finally {
    await new Promise((r) => app.close(r));
    await new Promise((r) => gate.close(r));
    oauth.db.close();
    rmSync(dir, { recursive: true, force: true });
    delete process.env.OWNER_GATE_URL;
  }
});
