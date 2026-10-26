import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer, request as rawRequest } from 'node:http';
import { randomUUID, randomBytes } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { service } from '../dist/server.js';
const a = '11111111-1111-4111-8111-111111111111',
  b = '22222222-2222-4222-8222-222222222222';
const day = { key: '2026-10-19', timeZoneID: 'Asia/Ho_Chi_Minh' };
const nutrition = { calories: 204, protein: 12, fiber: 2 };
test('REST and MCP isolate two users, same UUIDs, settings, costs, operations and polling', async () => {
  const dir = mkdtempSync(tmpdir() + '/libnutri-api-');
  let unavailable = false;
  const introspection = createServer(async (req, res) => {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    assert.equal(
      req.headers.authorization,
      'Basic ' + Buffer.from('test:secret').toString('base64'),
    );
    if (unavailable) {
      res.writeHead(503);
      res.end('{}');
      return;
    }
    const token = new URLSearchParams(Buffer.concat(chunks).toString()).get('token');
    res.setHeader('Content-Type', 'application/json');
    const user = token?.startsWith('a') ? a : b;
    res.end(
      JSON.stringify(
        token === 'invalid'.repeat(5)
          ? { active: false }
          : {
              active: true,
              iss: 'https://libauth.avx.so',
              sub: user,
              username: user === a ? 'dan' : 'alice',
              aud: 'https://libnutri.avx.so' + (token?.includes('mcp') ? '/mcp' : ''),
              scope: token?.includes('readonly')
                ? 'nutrition:read'
                : 'nutrition:read nutrition:write',
            },
      ),
    );
  });
  await new Promise((r) => introspection.listen(0, '127.0.0.1', r));
  const app = service('https://libnutri.avx.so', dir, randomBytes(32), fetch, {
    issuer: 'https://libauth.avx.so',
    introspectionURL: 'http://127.0.0.1:' + introspection.address().port,
    clientId: 'test',
    clientSecret: 'secret',
    ownerId: a,
  });
  await new Promise((r) => app.server.listen(0, '127.0.0.1', r));
  const token = (who, mcp = false) => who.repeat(24) + (mcp ? 'mcp' : '');
  const request = (path, who = 'a', method = 'GET', input, mcp = false) =>
    new Promise((resolve, reject) => {
      const payload = input ? JSON.stringify(input) : undefined;
      const req = rawRequest(
        'http://127.0.0.1:' + app.server.address().port + path,
        {
          method,
          headers: {
            host: 'libnutri.avx.so',
            authorization: 'Bearer ' + token(who, mcp),
            'Content-Type': 'application/json',
            Accept: 'application/json, text/event-stream',
            ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}),
          },
        },
        (res) => {
          const chunks = [];
          res.on('data', (c) => chunks.push(c));
          res.on('end', () =>
            resolve(
              new Response(Buffer.concat(chunks), { status: res.statusCode, headers: res.headers }),
            ),
          );
        },
      );
      req.on('error', reject);
      req.end(payload);
    });
  const api = (path, who = 'a', method = 'GET', input) =>
    request('/api/v1/' + path, who, method, input);
  const tool = async (name, args = {}, who = 'a') => {
    const r = await request(
      '/mcp',
      who,
      'POST',
      { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } },
      true,
    );
    assert.equal(r.status, 200);
    return (await r.json()).result;
  };
  try {
    assert.equal((await api('me')).status, 200);
    assert.equal((await (await api('me', 'b')).json()).id, b);
    const id = randomUUID();
    let r = await api('entries', 'a', 'POST', { id, input: 'Meal A', day, nutrition });
    assert.equal(r.status, 201);
    assert.equal((await api('entries/' + id, 'b')).status, 404);
    assert.equal(
      (
        await api('entries', 'b', 'POST', {
          id,
          input: 'Meal B',
          day,
          nutrition: { ...nutrition, calories: 50 },
        })
      ).status,
      201,
    );
    assert.equal((await tool('get_profile', {}, 'a')).structuredContent.id, a);
    assert.equal(
      (await tool('get_meal', { id }, 'b')).structuredContent.entry.originalInput,
      'Meal B',
    );
    assert.equal(
      (await api('settings', 'a', 'PATCH', { apiKey: 'test-key-a', nutritionModel: 'model-a' }))
        .status,
      200,
    );
    assert.equal((await (await api('settings', 'b')).json()).hasKey, false);
    app.context(a).store.receipt('same-receipt', 'analysis', 0.12);
    app.context(b).store.receipt('same-receipt', 'transcription', 0.34);
    assert.equal((await (await api('spending', 'a')).json()).total, '0.12');
    assert.equal((await (await api('spending', 'b')).json()).total, '0.34');
    const baseline = await (await api('changes')).json();
    let woke = false;
    const waiting = api('changes?after=' + baseline.cursor).then(async (r) => {
      woke = true;
      return r.json();
    });
    await new Promise((r) => setTimeout(r, 20));
    assert.equal(
      (
        await tool(
          'update_meal',
          { id, expectedVersion: 1, nutrition: { ...nutrition, calories: 51 } },
          'b',
        )
      ).isError,
      undefined,
    );
    await new Promise((r) => setTimeout(r, 60));
    assert.equal(woke, false);
    await tool(
      'update_meal',
      { id, expectedVersion: 1, nutrition: { ...nutrition, calories: 205 } },
      'a',
    );
    const changed = await waiting;
    assert.equal(changed.state.entries[0].nutrition.calories, 205);
    assert.notEqual((await (await api('changes', 'b')).json()).cursor, changed.cursor);
    assert.equal(
      (
        await api('entries', 'b', 'POST', {
          id: randomUUID(),
          input: 'Injected',
          day,
          nutrition,
          user_id: a,
        })
      ).status,
      400,
    );
    assert.equal((await api('import', 'b', 'POST', { id: randomUUID(), entries: [] })).status, 403);
    const op = app
      .context(a)
      .store.start(
        id,
        'analysis',
        { operationID: randomUUID(), input: 'Meal A again', expectedVersion: 2 },
        'test-model',
      ).operation;
    assert.equal((await api('operations/' + op.id, 'b')).status, 404);
    assert.equal((await tool('retry_saving', { id: op.id }, 'b')).isError, true);
    assert.equal(
      (await api('data', 'b', 'DELETE', { confirmation: 'DELETE_ALL_DATA' })).status,
      200,
    );
    assert.equal((await (await api('state', 'b')).json()).entries.length, 0);
    assert.equal((await (await api('state', 'a')).json()).entries.length, 1);
    assert.equal((await (await api('spending', 'a')).json()).total, '0.12');
    unavailable = true;
    assert.equal((await api('state')).status, 503);
    unavailable = false;
    assert.equal((await api('state')).status, 200);
    const profile = await tool('get_profile', {}, 'a');
    assert.equal(profile.structuredContent.username, 'dan');
  } finally {
    for (const c of app.contexts.values()) {
      c.worker.cancelAll();
      c.store.db.close();
    }
    app.legacyOAuth.db.close();
    app.server.closeAllConnections();
    introspection.closeAllConnections();
    await new Promise((r) => app.server.close(r));
    await new Promise((r) => introspection.close(r));
    rmSync(dir, { recursive: true, force: true });
  }
});
