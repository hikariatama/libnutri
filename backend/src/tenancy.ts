import { DatabaseSync } from 'node:sqlite';
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';

const definitions: Record<string, string> = {
  entries: 'id TEXT NOT NULL,data TEXT NOT NULL,deleted INTEGER NOT NULL DEFAULT 0',
  operations:
    'id TEXT NOT NULL,entry_id TEXT NOT NULL,data TEXT NOT NULL,FOREIGN KEY(user_id,entry_id) REFERENCES entries(user_id,id)',
  receipts: 'id TEXT NOT NULL,kind TEXT NOT NULL,cost TEXT,created INTEGER NOT NULL',
  settings: 'id TEXT NOT NULL,value TEXT NOT NULL',
  cancelled_operations: 'id TEXT NOT NULL',
  imports: 'id TEXT NOT NULL,created INTEGER NOT NULL',
  audit: 'id TEXT NOT NULL,action TEXT,entry_id TEXT,created INTEGER NOT NULL',
};
export function initializeDatabase(db: DatabaseSync, key: Buffer, ownerId?: string) {
  db.exec(
    'PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON;',
  );
  const exists = db
    .prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='entries'")
    .get();
  const legacy =
    exists &&
    !(db.prepare('PRAGMA table_info(entries)').all() as { name: string }[]).some(
      (c) => c.name === 'user_id',
    );
  if (legacy && !ownerId) throw Error('Legacy data requires an explicitly configured owner UUID');
  if (ownerId && !/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(ownerId))
    throw Error('Invalid legacy owner UUID');
  db.exec('BEGIN IMMEDIATE');
  try {
    if (legacy)
      for (const name of Object.keys(definitions))
        db.exec(`ALTER TABLE ${name} RENAME TO legacy_${name}`);
    for (const [name, columns] of Object.entries(definitions))
      db.exec(
        `CREATE TABLE IF NOT EXISTS ${name}(user_id TEXT NOT NULL,${columns},PRIMARY KEY(user_id,id))`,
      );
    if (legacy) {
      for (const name of Object.keys(definitions))
        db.prepare(`INSERT INTO ${name} SELECT ?,* FROM legacy_${name}`).run(ownerId!);
      const row = db
        .prepare("SELECT value FROM settings WHERE user_id=? AND id='openrouter'")
        .get(ownerId!) as { value: string } | undefined;
      if (row) {
        const b = Buffer.from(row.value, 'base64'),
          dec = createDecipheriv('aes-256-gcm', key, b.subarray(0, 12));
        dec.setAuthTag(b.subarray(12, 28));
        const plaintext = Buffer.concat([dec.update(b.subarray(28)), dec.final()]);
        const iv = randomBytes(12),
          cipher = createCipheriv('aes-256-gcm', key, iv);
        cipher.setAAD(Buffer.from(ownerId! + ':openrouter'));
        const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
        plaintext.fill(0);
        db.prepare("UPDATE settings SET value=? WHERE user_id=? AND id='openrouter'").run(
          Buffer.concat([iv, cipher.getAuthTag(), ciphertext]).toString('base64'),
          ownerId!,
        );
      }
      for (const name of Object.keys(definitions)) db.exec(`DROP TABLE legacy_${name}`);
    }
    db.exec(
      'CREATE INDEX IF NOT EXISTS operations_tenant_entry ON operations(user_id,entry_id); PRAGMA user_version=2; COMMIT',
    );
  } catch (error) {
    db.exec('ROLLBACK');
    throw error;
  }
}
