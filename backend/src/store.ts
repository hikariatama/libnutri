import { DatabaseSync } from 'node:sqlite';
import { initializeDatabase } from './tenancy.js';
import { mkdirSync } from 'node:fs';
import { randomUUID, createHash, createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { Decimal } from 'decimal.js';

export class Fault extends Error {
  constructor(
    public code: string,
    public status = 400,
  ) {
    super(code);
  }
}
export type Nutrition = { calories: number; protein: number; fiber: number };
export type Entry = {
  id: string;
  originalInput: string;
  draftInput: string | null;
  inputSource: 'text' | 'voice';
  nutrition: Nutrition | null;
  day: { key: string; timeZoneID: string };
  consumedAt: number;
  createdAt: number;
  updatedAt: number;
  phase: string;
  activeOperationID: string | null;
  version: number;
};
export type Operation = {
  id: string;
  entryID: string;
  kind: 'analysis' | 'transcription';
  inputSnapshot: string;
  model: string;
  requestCount: number;
  phase: string;
  errorCategory: string | null;
  createdAt: number;
  updatedAt: number;
  promptVersion: string;
  entryVersion: number;
  waitingUntil: number | null;
  transcript?: string;
};
export function description(value: unknown): string {
  if (typeof value !== 'string' || !value.trim() || value.length > 10000)
    throw new Fault('empty_input');
  return value;
}
export function nutrition(value: unknown): Nutrition {
  const v = value as Nutrition;
  if (
    !v ||
    typeof v !== 'object' ||
    Array.isArray(v) ||
    Object.keys(v).sort().join(',') !== 'calories,fiber,protein' ||
    ![v.calories, v.protein, v.fiber].every(
      (n) => typeof n === 'number' && Number.isFinite(n) && n >= 0,
    )
  )
    throw new Fault('invalid_response');
  if (v.calories >= 3000 || v.protein >= 150 || v.fiber >= 150)
    throw new Fault('nutrition_out_of_range');
  return v;
}
export function day(value: unknown): { key: string; timeZoneID: string } {
  const v = value as Entry['day'];
  if (
    !v ||
    !/^\d{4}-\d{2}-\d{2}$/.test(v.key) ||
    new Date(v.key + 'T12:00:00Z').toISOString().slice(0, 10) !== v.key
  )
    throw new Fault('invalid_day');
  try {
    new Intl.DateTimeFormat('en', { timeZone: v.timeZoneID }).format();
  } catch {
    throw new Fault('invalid_timezone');
  }
  return v;
}
export function uuid(value: unknown): string {
  if (typeof value !== 'string' || !/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(value))
    throw new Fault('invalid_id');
  return value.toLowerCase();
}
export class Store {
  db: DatabaseSync;
  onChange?: () => void;
  private changeQueued = false;
  private changed() {
    if (this.changeQueued) return;
    this.changeQueued = true;
    queueMicrotask(() => {
      this.changeQueued = false;
      this.onChange?.();
    });
  }
  constructor(
    path: string,
    private encryptionKey: Buffer,
    readonly userId: string,
    legacyOwnerId?: string,
  ) {
    uuid(userId);
    if (encryptionKey.length !== 32) throw Error('MASTER_KEY must contain 32 bytes');
    mkdirSync(path, { recursive: true, mode: 0o700 });
    this.db = new DatabaseSync(path + '/nutri.sqlite');
    initializeDatabase(this.db, encryptionKey, legacyOwnerId);
    this.prepare('INSERT OR IGNORE INTO settings VALUES ($user,?,?)').run(
      'startedAt',
      String(Date.now()),
    );
  }
  private prepare(sql: string) {
    if (!sql.includes('$user')) throw Error('Unscoped tenant query');
    const statement = this.db.prepare(sql);
    const bindings = { $user: this.userId };
    return {
      run: (...args: any[]) => statement.run(bindings, ...args),
      get: (...args: any[]) => statement.get(bindings, ...args),
      all: (...args: any[]) => statement.all(bindings, ...args),
    };
  }
  recoverInterrupted() {
    for (const e of this.list())
      if (e.activeOperationID) {
        const op = this.operation(e.activeOperationID);
        if (op) {
          op.phase = 'interrupted';
          op.errorCategory = op.kind === 'transcription' ? 'record_again' : 'interrupted';
          this.saveOperation(op);
        }
        e.activeOperationID = null;
        e.phase = e.nutrition ? 'ready' : 'interrupted';
        this.put(e);
      }
  }
  transaction<T>(fn: () => T): T {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const r = fn();
      this.db.exec('COMMIT');
      return r;
    } catch (e) {
      this.db.exec('ROLLBACK');
      throw e;
    }
  }
  list(all = false): Entry[] {
    return (
      this.prepare('SELECT data FROM entries WHERE user_id=$user AND deleted=0').all() as {
        data: string;
      }[]
    )
      .map((r) => JSON.parse(r.data))
      .sort((a, b) => b.createdAt - a.createdAt);
  }
  get(id: string): Entry {
    const row = this.prepare(
      'SELECT data FROM entries WHERE user_id=$user AND id=? AND deleted=0',
    ).get(uuid(id)) as { data: string } | undefined;
    if (!row) throw new Fault('not_found', 404);
    return JSON.parse(row.data);
  }
  put(e: Entry) {
    this.prepare('UPDATE entries SET data=? WHERE user_id=$user AND id=? AND deleted=0').run(
      JSON.stringify(e),
      e.id,
    );
    this.changed();
  }
  create(input: Record<string, unknown>): Entry {
    const id = uuid(input.id || randomUUID());
    const existing = this.prepare(
      'SELECT data,deleted FROM entries WHERE user_id=$user AND id=?',
    ).get(id) as { data: string; deleted: number } | undefined;
    if (existing) {
      if (existing.deleted) throw new Fault('deleted', 410);
      const e: Entry = JSON.parse(existing.data);
      if (e.originalInput !== (input.input || '')) throw new Fault('idempotency_conflict', 409);
      return e;
    }
    const text = input.input === undefined ? '' : description(input.input);
    const e: Entry = {
      id,
      originalInput: text,
      draftInput: text,
      inputSource: input.inputSource === 'voice' ? 'voice' : 'text',
      nutrition: input.nutrition === undefined ? null : nutrition(input.nutrition),
      day: day(input.day),
      consumedAt: Date.now(),
      createdAt: Date.now(),
      updatedAt: Date.now(),
      phase: input.nutrition ? 'ready' : 'pending',
      activeOperationID: null,
      version: 1,
    };
    this.prepare('INSERT INTO entries VALUES ($user,?,?,0)').run(id, JSON.stringify(e));
    this.audit('create', id);
    return e;
  }
  update(id: string, input: Record<string, unknown>): Entry {
    return this.transaction(() => {
      const e = this.get(id);
      if (input.expectedVersion !== e.version) throw new Fault('version_conflict', 409);
      if (e.activeOperationID) throw new Fault('operation_in_progress', 409);
      if (input.input !== undefined) e.originalInput = description(input.input);
      if (input.nutrition !== undefined) e.nutrition = nutrition(input.nutrition);
      if (input.day !== undefined) e.day = day(input.day);
      e.draftInput = null;
      e.phase = e.nutrition ? 'ready' : 'pending';
      e.version++;
      e.updatedAt = Date.now();
      this.put(e);
      this.audit('update', id);
      return e;
    });
  }
  draft(id: string, text: string) {
    const e = this.get(id);
    if (e.activeOperationID) throw new Fault('operation_in_progress', 409);
    if (text.length > 10000) throw new Fault('input_too_long');
    e.draftInput = text;
    this.put(e);
    return e;
  }
  remove(id: string, version: number) {
    id = uuid(id);
    const e = this.get(id);
    if (e.version !== version) throw new Fault('version_conflict', 409);
    this.transaction(() => {
      if (e.activeOperationID) this.cancel(e.activeOperationID);
      this.prepare("UPDATE entries SET deleted=1,data='{}' WHERE user_id=$user AND id=?").run(id);
      this.prepare('DELETE FROM operations WHERE user_id=$user AND entry_id=?').run(id);
      this.audit('delete', id);
    });
  }
  audit(action: string, id: string) {
    this.prepare('INSERT INTO audit VALUES ($user,?,?,?,?)').run(
      randomUUID(),
      action,
      id,
      Date.now(),
    );
    this.changed();
  }
  operation(id: string): Operation | undefined {
    const row = this.prepare('SELECT data FROM operations WHERE user_id=$user AND id=?').get(
      uuid(id),
    ) as { data: string } | undefined;
    return row ? JSON.parse(row.data) : undefined;
  }
  operations(): Operation[] {
    return (
      this.prepare(
        'SELECT data FROM operations WHERE user_id=$user ORDER BY rowid DESC LIMIT 1000',
      ).all() as { data: string }[]
    ).map((r) => JSON.parse(r.data));
  }
  saveOperation(op: Operation) {
    op.updatedAt = Date.now();
    this.prepare(
      'INSERT INTO operations VALUES ($user,?,?,?) ON CONFLICT(user_id,id) DO UPDATE SET data=excluded.data',
    ).run(op.id, op.entryID, JSON.stringify(op));
    this.changed();
  }
  start(
    id: string,
    kind: Operation['kind'],
    input: Record<string, unknown>,
    model: string,
  ): { entry: Entry; operation: Operation; fresh: boolean } {
    id = uuid(id);
    return this.transaction(() => {
      const opID = uuid(input.operationID),
        text = kind === 'analysis' ? description(input.input) : '';
      if (this.prepare('SELECT 1 FROM cancelled_operations WHERE user_id=$user AND id=?').get(opID))
        throw new Fault('cancelled', 409);
      const old = this.operation(opID);
      if (old) {
        if (old.entryID !== id || old.kind !== kind || old.inputSnapshot !== text)
          throw new Fault('idempotency_conflict', 409);
        return { entry: this.get(id), operation: old, fresh: false };
      }
      const e = this.get(id);
      if (e.version !== input.expectedVersion) throw new Fault('version_conflict', 409);
      if (e.activeOperationID) throw new Fault('operation_in_progress', 409);
      e.activeOperationID = opID;
      e.phase = kind === 'analysis' ? 'analyzing' : 'transcribing';
      e.version++;
      e.updatedAt = Date.now();
      if (kind === 'analysis') e.draftInput = text;
      const op: Operation = {
        id: opID,
        entryID: id,
        kind,
        inputSnapshot: text,
        model,
        requestCount: 0,
        phase: 'running',
        errorCategory: null,
        createdAt: Date.now(),
        updatedAt: Date.now(),
        promptVersion: 'nutrition-v1',
        entryVersion: e.version,
        waitingUntil: null,
      };
      this.put(e);
      this.saveOperation(op);
      this.audit(kind, id);
      return { entry: e, operation: op, fresh: true };
    });
  }
  current(op: Operation): Entry | undefined {
    try {
      const e = this.get(op.entryID);
      return e.activeOperationID === op.id && e.version === op.entryVersion ? e : undefined;
    } catch {
      return undefined;
    }
  }
  complete(op: Operation, result: Nutrition | string) {
    this.transaction(() => {
      const e = this.current(op);
      if (!e) return;
      if (op.kind === 'analysis') {
        e.originalInput = op.inputSnapshot;
        e.draftInput = null;
        e.nutrition = result as Nutrition;
        e.phase = 'ready';
      } else {
        op.transcript = result as string;
        e.draftInput = op.transcript;
        e.inputSource = 'voice';
        e.phase = 'pending';
      }
      e.activeOperationID = null;
      e.version++;
      e.updatedAt = Date.now();
      op.phase = 'succeeded';
      op.errorCategory = null;
      op.waitingUntil = null;
      this.put(e);
      this.saveOperation(op);
    });
  }
  fail(op: Operation, code: string) {
    this.transaction(() => {
      const e = this.current(op);
      if (!e) return;
      op.phase = 'failed';
      op.errorCategory = code;
      op.waitingUntil = null;
      e.activeOperationID = null;
      e.phase = 'failed';
      this.put(e);
      this.saveOperation(op);
    });
  }
  cancel(id: string) {
    id = uuid(id);
    this.prepare('INSERT OR IGNORE INTO cancelled_operations VALUES ($user,?)').run(id);
    const op = this.operation(id);
    if (!op) return;
    const e = this.current(op);
    if (!e) return;
    op.phase = 'cancelled';
    op.waitingUntil = null;
    this.saveOperation(op);
    e.activeOperationID = null;
    e.phase = e.nutrition ? 'ready' : 'interrupted';
    e.version++;
    this.put(e);
  }
  receipt(id: string, kind: string, cost: unknown) {
    let amount: string | null = null;
    if (typeof cost === 'number' && Number.isFinite(cost) && cost >= 0)
      amount = new Decimal(cost.toString()).toString();
    this.prepare(
      'INSERT INTO receipts VALUES ($user,?,?,?,?) ON CONFLICT(user_id,id) DO UPDATE SET cost=coalesce(receipts.cost,excluded.cost)',
    ).run(id, kind, amount, Date.now());
    this.changed();
  }
  spending() {
    const totals = { analysis: new Decimal(0), transcription: new Decimal(0) };
    let unknownCount = 0;
    for (const r of this.prepare('SELECT kind,cost FROM receipts WHERE user_id=$user').all() as {
      kind: keyof typeof totals;
      cost: string | null;
    }[])
      if (r.cost === null) unknownCount++;
      else totals[r.kind] = totals[r.kind].plus(r.cost);
    return {
      analysis: totals.analysis.toString(),
      transcription: totals.transcription.toString(),
      total: totals.analysis.plus(totals.transcription).toString(),
      unknownCount,
      startedAt: Number(this.setting('startedAt')),
    };
  }
  setting(key: string): string | undefined {
    return (
      this.prepare('SELECT value FROM settings WHERE user_id=$user AND id=?').get(key) as
        { value: string } | undefined
    )?.value;
  }
  setSetting(key: string, value: string) {
    this.prepare(
      'INSERT INTO settings VALUES ($user,?,?) ON CONFLICT(user_id,id) DO UPDATE SET value=excluded.value',
    ).run(key, value);
    this.changed();
  }
  key(): string {
    const encoded = this.setting('openrouter');
    if (!encoded) throw new Fault('missing_key');
    const b = Buffer.from(encoded, 'base64'),
      dec = createDecipheriv('aes-256-gcm', this.encryptionKey, b.subarray(0, 12));
    dec.setAAD(Buffer.from(this.userId + ':openrouter'));
    dec.setAuthTag(b.subarray(12, 28));
    return Buffer.concat([dec.update(b.subarray(28)), dec.final()]).toString();
  }
  setKey(key: string) {
    if (!key) {
      this.prepare('DELETE FROM settings WHERE user_id=$user AND id=?').run('openrouter');
      this.changed();
      return;
    }
    const iv = randomBytes(12),
      c = createCipheriv('aes-256-gcm', this.encryptionKey, iv);
    c.setAAD(Buffer.from(this.userId + ':openrouter'));
    const encrypted = Buffer.concat([c.update(key), c.final()]);
    this.setSetting(
      'openrouter',
      Buffer.concat([iv, c.getAuthTag(), encrypted]).toString('base64'),
    );
  }
  settings() {
    return {
      hasKey: Boolean(this.setting('openrouter')),
      nutritionModel: this.setting('nutritionModel') || 'google/gemini-2.5-flash-lite',
      transcriptionModel: this.setting('transcriptionModel') || 'openai/whisper-large-v3-turbo',
    };
  }
  clear() {
    this.transaction(() => {
      for (const op of this.operations()) if (this.current(op)) this.cancel(op.id);
      this.prepare("UPDATE entries SET deleted=1,data='{}' WHERE user_id=$user").run();
      for (const table of ['operations', 'receipts', 'imports', 'settings'])
        this.prepare(`DELETE FROM ${table} WHERE user_id=$user`).run();
      this.setSetting('startedAt', String(Date.now()));
      this.audit('clear', 'all');
    });
  }
  import(
    key: string,
    entries: Entry[],
    ledger?: {
      charges: Record<string, { id: string; kind: string; costUSD: number | null; date: number }>;
      startedAt: number;
    },
  ) {
    if (entries.length > 1000) throw new Fault('too_many_entries');
    uuid(key);
    return this.transaction(() => {
      if (this.prepare('SELECT 1 FROM imports WHERE user_id=$user AND id=?').get(key)) return;
      for (const raw of entries) {
        const id = uuid(raw.id);
        if (this.prepare('SELECT 1 FROM entries WHERE user_id=$user AND id=?').get(id)) continue;
        const e: Entry = {
          ...raw,
          id,
          day: day(raw.day),
          nutrition: raw.nutrition ? nutrition(raw.nutrition) : null,
          activeOperationID: null,
          version: 1,
          phase: raw.nutrition ? 'ready' : 'interrupted',
        };
        if (
          typeof e.originalInput !== 'string' ||
          e.originalInput.length > 10000 ||
          ![e.createdAt, e.updatedAt, e.consumedAt].every((x) => Number.isFinite(x) && x > 0)
        )
          throw new Fault('invalid_import');
        this.prepare('INSERT INTO entries VALUES ($user,?,?,0)').run(id, JSON.stringify(e));
      }
      if (ledger) {
        if (
          !ledger.charges ||
          typeof ledger.charges !== 'object' ||
          Object.keys(ledger.charges).length > 100000 ||
          !Number.isFinite(ledger.startedAt)
        )
          throw new Fault('invalid_import');
        for (const c of Object.values(ledger.charges)) {
          if (
            typeof c.id !== 'string' ||
            c.id.length > 512 ||
            !['analysis', 'transcription'].includes(c.kind) ||
            !(
              c.costUSD === null ||
              c.costUSD === undefined ||
              (typeof c.costUSD === 'number' && Number.isFinite(c.costUSD) && c.costUSD >= 0)
            )
          )
            throw new Fault('invalid_import');
          this.receipt(c.id, c.kind, c.costUSD);
        }
        this.setSetting(
          'startedAt',
          String(Math.min(Number(this.setting('startedAt')), ledger.startedAt)),
        );
      }
      this.prepare('INSERT INTO imports VALUES ($user,?,?)').run(key, Date.now());
      this.audit('import', key);
    });
  }
}
