import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { OAuth, redirectMatches } from '../dist/oauth.js';

test('OAuth binds owner consent, PKCE, client, resource and refresh family', async () => {
  const dir = mkdtempSync(tmpdir() + '/grab-oauth-');
  const origin = 'https://nutri.avx.so',
    resource = origin;
  const gate = createServer((req, res) => {
    res.writeHead(req.headers.cookie === 'gate_session=owner_owner_owner_owner_owner' ? 200 : 403, {
      'Content-Type': 'application/json',
    });
    res.end('{"owner":true}');
  });
  await new Promise((r) => gate.listen(0, '127.0.0.1', r));
  process.env.OWNER_GATE_URL = 'http://127.0.0.1:' + gate.address().port;
  const oauth = new OAuth(origin, dir);
  const app = createServer((req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    void oauth.handle(req, res, new URL(req.url, origin));
  });
  await new Promise((r) => app.listen(0, '127.0.0.1', r));
  const base = 'http://127.0.0.1:' + app.address().port;
  const request = (path, options = {}) => fetch(base + path, { redirect: 'manual', ...options });
  const form = (path, data, headers = {}) =>
    request(path, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ...headers,
      },
      body: new URLSearchParams(data),
    });
  try {
    const registration = await request('/oauth/register', {
      method: 'POST',
      body: JSON.stringify({
        client_name: 'test',
        redirect_uris: ['http://127.0.0.1:9999/callback'],
        token_endpoint_auth_method: 'none',
      }),
    });
    assert.equal(registration.status, 201);
    const client = await registration.json();
    const verifier = 'v'.repeat(64),
      challenge = createHash('sha256').update(verifier).digest('base64url');
    const auth =
      '/oauth/authorize?' +
      new URLSearchParams({
        client_id: client.client_id,
        redirect_uri: client.redirect_uris[0],
        response_type: 'code',
        code_challenge_method: 'S256',
        code_challenge: challenge,
        resource,
        scope: 'nutrition:read offline_access',
        state: 'test-state',
      });
    assert.equal((await request(auth)).status, 303);
    assert.equal(
      (
        await request(
          auth.replace(encodeURIComponent(resource), encodeURIComponent('https://evil.example')),
        )
      ).status,
      400,
    );
    const owner = 'gate_session=owner_owner_owner_owner_owner';
    const consent = await request(auth, { headers: { Cookie: owner } });
    assert.equal(consent.status, 200);
    assert.equal(consent.headers.get('referrer-policy'), 'strict-origin');
    const csrf = /name="csrf" value="([^"]+)"/.exec(await consent.text())[1];
    // A second tab must not replace the first tab's consent binding.
    const otherTab = await request(auth, { headers: { Cookie: owner } });
    assert.equal(otherTab.status, 200);
    const cookie =
      owner +
      '; ' +
      consent.headers.get('set-cookie').split(';')[0] +
      '; ' +
      otherTab.headers.get('set-cookie').split(';')[0];
    assert.equal(
      (
        await form(
          '/oauth/consent',
          { csrf: 'wrong', decision: 'allow' },
          { Cookie: cookie, Origin: origin },
        )
      ).status,
      400,
    );
    const accepted = await form(
      '/oauth/consent',
      { csrf, decision: 'allow' },
      { Cookie: cookie, Origin: origin },
    );
    assert.equal(accepted.status, 303);
    assert.match(accepted.headers.get('set-cookie'), /Max-Age=0/);
    const redirect = new URL(accepted.headers.get('location'));
    assert.equal(redirect.searchParams.get('iss'), origin);
    assert.equal(redirect.searchParams.get('state'), 'test-state');
    const exchange = {
      grant_type: 'authorization_code',
      code: redirect.searchParams.get('code'),
      redirect_uri: client.redirect_uris[0],
      client_id: client.client_id,
      resource,
      code_verifier: verifier,
    };
    assert.equal(
      (
        await form('/oauth/token', {
          ...exchange,
          code_verifier: 'w'.repeat(64),
        })
      ).status,
      400,
    );
    assert.equal(
      (
        await form('/oauth/token', {
          ...exchange,
          resource: 'https://evil.example',
        })
      ).status,
      400,
    );
    const issued = await form('/oauth/token', exchange);
    assert.equal(issued.status, 200);
    const tokens = await issued.json();
    assert(oauth.verify(tokens.access_token));
    assert(!oauth.verify('invalid'));
    assert(!oauth.verify(tokens.refresh_token));
    assert.equal((await form('/oauth/token', exchange)).status, 400);
    const refresh = {
      grant_type: 'refresh_token',
      refresh_token: tokens.refresh_token,
      client_id: client.client_id,
      resource,
    };
    const rotated = await form('/oauth/token', refresh);
    assert.equal(rotated.status, 200);
    const newer = await rotated.json();
    assert.notEqual(newer.refresh_token, tokens.refresh_token);
    assert(oauth.verify(newer.access_token));
    assert.equal((await form('/oauth/token', refresh)).status, 400);
    assert(!oauth.verify(tokens.access_token));
    assert(!oauth.verify(newer.access_token));
    assert.equal(
      (
        await form('/oauth/token', {
          ...refresh,
          refresh_token: newer.refresh_token,
        })
      ).status,
      400,
    );
    const consent2 = await request(auth, { headers: { Cookie: owner } });
    const csrf2 = /name="csrf" value="([^"]+)"/.exec(await consent2.text())[1];
    const accepted2 = await form(
      '/oauth/consent',
      { csrf: csrf2, decision: 'allow' },
      {
        Cookie: owner + '; ' + consent2.headers.get('set-cookie').split(';')[0],
        Origin: origin,
      },
    );
    const issued2 = await form('/oauth/token', {
      ...exchange,
      code: new URL(accepted2.headers.get('location')).searchParams.get('code'),
    });
    const tokens2 = await issued2.json();
    assert(oauth.verify(tokens2.access_token));
    assert.equal(
      (
        await form('/oauth/revoke', {
          client_id: client.client_id,
          token: tokens2.refresh_token,
        })
      ).status,
      200,
    );
    assert(!oauth.verify(tokens2.access_token));
    const evil = await request('/oauth/register', {
      method: 'POST',
      body: JSON.stringify({ redirect_uris: ['http://evil.example/callback'] }),
    });
    assert.equal(evil.status, 400);
  } finally {
    await new Promise((r) => app.close(r));
    await new Promise((r) => gate.close(r));
    rmSync(dir, { recursive: true, force: true });
    delete process.env.OWNER_GATE_URL;
  }
});
test('native loopback callbacks vary only their port', () => {
  assert(redirectMatches('http://127.0.0.1/callback', 'http://127.0.0.1:52452/callback', true));
  assert(redirectMatches('http://[::1]/callback', 'http://[::1]:52452/callback', true));
  for (const url of [
    'http://evil.example:52452/callback',
    'http://127.0.0.1:52452/other',
    'http://127.0.0.1:52452/callback?x=1',
    'https://127.0.0.1:52452/callback',
    'http://u@127.0.0.1:52452/callback',
  ])
    assert(!redirectMatches('http://127.0.0.1/callback', url, true));
  assert(!redirectMatches('http://127.0.0.1/callback', 'http://127.0.0.1:52452/callback', false));
});
