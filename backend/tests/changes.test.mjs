import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { randomBytes, randomUUID } from 'node:crypto';
import { Store } from '../dist/store.js';
import { ChangeFeed } from '../dist/changes.js';

test('long polling waits, wakes all clients after commits, and reconciles deletes and restarts', async () => {
  const dir = mkdtempSync(tmpdir() + '/nutri-changes-'),
    key = randomBytes(32),
    store = new Store(dir, key, '11111111-1111-4111-8111-111111111111'),
    feed = new ChangeFeed(store);
  const signal = new AbortController().signal;
  try {
    const initial = await feed.wait(null, signal),
      id = randomUUID();
    let settled = false;
    const first = feed.wait(initial.cursor, signal).then((v) => {
      settled = true;
      return v;
    });
    const second = feed.wait(initial.cursor, signal);
    await new Promise((r) => setTimeout(r, 15));
    assert.equal(settled, false);
    assert.equal(feed.pending, 2);
    const entry = store.create({
      id,
      input: 'meal',
      day: { key: '2026-10-12', timeZoneID: 'Asia/Ho_Chi_Minh' },
      nutrition: { calories: 200, protein: 10, fiber: 2 },
    });
    const [a, b] = await Promise.all([first, second]);
    assert.equal(a.cursor, b.cursor);
    assert.equal(a.state.entries[0].id, id);
    assert.equal(feed.pending, 0);
    const pending = feed.wait(a.cursor, signal);
    store.update(id, {
      expectedVersion: entry.version,
      input: 'edited',
      nutrition: { calories: 250, protein: 12, fiber: 3 },
    });
    const edited = await pending;
    assert.equal(edited.state.entries[0].originalInput, 'edited');
    const removed = feed.wait(edited.cursor, signal);
    store.remove(id, 2);
    assert.deepEqual((await removed).state.entries, []);
    const cursor = feed.capture().cursor;
    const reopened = new Store(dir, key, '11111111-1111-4111-8111-111111111111'),
      again = new ChangeFeed(reopened);
    assert.equal(again.capture().cursor, cursor);
    reopened.db.close();
    assert.deepEqual(await feed.wait(cursor, signal, 15), { cursor, state: null });
  } finally {
    store.db.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test('disconnect cleans waiters; rolled-back writes do not wake clients; settings/spending/AI progress do', async () => {
  const dir = mkdtempSync(tmpdir() + '/nutri-changes-'),
    store = new Store(dir, randomBytes(32), '11111111-1111-4111-8111-111111111111'),
    feed = new ChangeFeed(store);
  const controller = new AbortController();
  try {
    let cursor = feed.capture().cursor;
    const cancelled = feed.wait(cursor, controller.signal);
    controller.abort();
    await assert.rejects(cancelled, { name: 'AbortError' });
    assert.equal(feed.pending, 0);
    const signal = new AbortController().signal;
    const unchanged = feed.wait(cursor, signal, 20);
    assert.throws(() =>
      store.transaction(() => {
        store.setSetting('nutritionModel', 'temporary');
        throw Error('rollback');
      }),
    );
    assert.equal((await unchanged).state, null);
    let waiting = feed.wait(cursor, signal);
    store.setKey('test-key');
    let next = await waiting;
    assert.equal(next.settings.hasKey, true);
    assert.equal(JSON.stringify(next).includes('test-key'), false);
    cursor = next.cursor;
    waiting = feed.wait(cursor, signal);
    store.receipt('receipt', 'analysis', 0.001);
    next = await waiting;
    assert.equal(next.spending.total, '0.001');
    const entry = store.create({
      id: randomUUID(),
      input: 'meal',
      day: { key: '2026-10-12', timeZoneID: 'UTC' },
    });
    const { operation } = store.start(
      entry.id,
      'analysis',
      { operationID: randomUUID(), input: 'meal', expectedVersion: 1 },
      'model',
    );
    cursor = feed.capture().cursor;
    waiting = feed.wait(cursor, signal);
    store.complete(operation, { calories: 120, protein: 2, fiber: 1 });
    next = await waiting;
    assert.equal(next.state.entries[0].nutrition.calories, 120);
    assert.equal(next.state.attempts[0].phase, 'succeeded');
    assert.equal(feed.pending, 0);
  } finally {
    store.db.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
