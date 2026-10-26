import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { randomUUID, randomBytes, createCipheriv } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { Store } from '../dist/store.js';
const a = '11111111-1111-4111-8111-111111111111',
  b = '22222222-2222-4222-8222-222222222222';
test('legacy migration preserves data and costs, binds only the configured owner, reencrypts once', () => {
  const path = mkdtempSync(tmpdir() + '/libnutri-migrate-'),
    key = randomBytes(32),
    raw = new DatabaseSync(path + '/nutri.sqlite');
  const definitions = {
    entries: 'id TEXT PRIMARY KEY,data TEXT,deleted INTEGER',
    operations: 'id TEXT PRIMARY KEY,entry_id TEXT,data TEXT',
    receipts: 'id TEXT PRIMARY KEY,kind TEXT,cost TEXT,created INTEGER',
    settings: 'id TEXT PRIMARY KEY,value TEXT',
    cancelled_operations: 'id TEXT PRIMARY KEY',
    imports: 'id TEXT PRIMARY KEY,created INTEGER',
    audit: 'id TEXT PRIMARY KEY,action TEXT,entry_id TEXT,created INTEGER',
  };
  for (const [name, columns] of Object.entries(definitions))
    raw.exec(`CREATE TABLE ${name}(${columns})`);
  const entry = {
    id: randomUUID(),
    originalInput: 'Original meal',
    nutrition: { calories: 204.4, protein: 5.2, fiber: 1.1 },
    day: { key: '2026-10-11', timeZoneID: 'Asia/Ho_Chi_Minh' },
    createdAt: 1,
    updatedAt: 2,
    consumedAt: 1,
    activeOperationID: null,
  };
  raw.prepare('INSERT INTO entries VALUES (?,?,0)').run(entry.id, JSON.stringify(entry));
  raw.prepare('INSERT INTO receipts VALUES (?,?,?,?)').run('receipt', 'analysis', '0.1234', 1);
  const iv = randomBytes(12),
    cipher = createCipheriv('aes-256-gcm', key, iv);
  const encrypted = Buffer.concat([cipher.update('original-private-key'), cipher.final()]);
  raw
    .prepare('INSERT INTO settings VALUES (?,?)')
    .run('openrouter', Buffer.concat([iv, cipher.getAuthTag(), encrypted]).toString('base64'));
  raw.close();
  let owner, other, again;
  try {
    assert.throws(() => new Store(path, key, a), /explicitly configured owner/);
    owner = new Store(path, key, a, a);
    other = new Store(path, key, b);
    assert.deepEqual(owner.get(entry.id), entry);
    assert.equal(owner.spending().total, '0.1234');
    assert.equal(owner.key(), 'original-private-key');
    assert.equal(other.list().length, 0);
    assert.equal(other.settings().hasKey, false);
    assert.throws(
      () => other.get(entry.id),
      (e) => e.code === 'not_found',
    );
    again = new Store(path, key, a, a);
    assert.deepEqual(again.get(entry.id), entry);
    assert.equal(again.key(), 'original-private-key');
    other.setSetting('openrouter', owner.setting('openrouter'));
    assert.throws(() => other.key());
  } finally {
    owner?.db.close();
    other?.db.close();
    again?.db.close();
    rmSync(path, { recursive: true, force: true });
  }
});
