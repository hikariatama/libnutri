import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { Store, nutrition } from '../dist/store.js';
import { Worker } from '../dist/ai.js';
function fixture() {
  const path = mkdtempSync(tmpdir() + '/nutri-'),
    store = new Store(path, Buffer.alloc(32, 1), '11111111-1111-4111-8111-111111111111');
  return {
    store,
    path,
    close: () => {
      store.db.close();
      rmSync(path, { recursive: true, force: true });
    },
  };
}
const day = { key: '2026-10-11', timeZoneID: 'Asia/Ho_Chi_Minh' },
  values = { calories: 420, protein: 28, fiber: 8 };
test('strict schema and independent thresholds before rounding', () => {
  for (const v of [
    { ...values, calories: 3000 },
    { ...values, protein: 150 },
    { ...values, fiber: 150 },
  ])
    assert.throws(() => nutrition(v), { code: 'nutrition_out_of_range' });
  for (const v of [
    { ...values, calories: true },
    { ...values, protein: null },
    { ...values, fiber: '1' },
    { ...values, calories: Infinity },
    { ...values, fiber: -1 },
    { ...values, extra: 0 },
  ])
    assert.throws(() => nutrition(v), { code: 'invalid_response' });
  assert.equal(
    nutrition({ calories: 2999.999, protein: 149.999, fiber: 149.999 }).calories,
    2999.999,
  );
});
test('creation idempotency, versions, stable day and late response after delete', () => {
  const f = fixture();
  try {
    const id = randomUUID(),
      e = f.store.create({ id, input: 'two eggs', day, nutrition: values });
    assert.equal(f.store.create({ id, input: 'two eggs', day, nutrition: values }).id, id);
    assert.equal(f.store.list().length, 1);
    const { operation: op } = f.store.start(
      id,
      'analysis',
      { operationID: randomUUID(), input: '50kg potatoes', expectedVersion: e.version },
      'model',
    );
    f.store.fail(op, 'nutrition_out_of_range');
    assert.deepEqual(f.store.get(id).nutrition, values);
    assert.equal(f.store.get(id).draftInput, '50kg potatoes');
    assert.deepEqual(f.store.get(id).day, day);
    assert.throws(() => f.store.update(id, { expectedVersion: 1, nutrition: values }), {
      code: 'version_conflict',
    });
    const next = f.store.start(
      id,
      'analysis',
      { operationID: randomUUID(), input: 'new', expectedVersion: f.store.get(id).version },
      'model',
    );
    f.store.remove(id, next.entry.version);
    f.store.complete(next.operation, { calories: 200, protein: 10, fiber: 2 });
    assert.throws(() => f.store.get(id), { code: 'not_found' });
    assert.equal(f.store.operations().length, 0);
  } finally {
    f.close();
  }
});
test('cancelled old operation cannot replace a newer meal result', () => {
  const f = fixture();
  try {
    const e = f.store.create({ input: 'eggs', day, nutrition: values }),
      a = f.store.start(
        e.id,
        'analysis',
        { operationID: randomUUID(), input: 'old', expectedVersion: e.version },
        'model',
      );
    f.store.cancel(a.operation.id);
    const b = f.store.start(
      e.id,
      'analysis',
      { operationID: randomUUID(), input: 'new', expectedVersion: f.store.get(e.id).version },
      'model',
    );
    f.store.complete(b.operation, { calories: 200, protein: 10, fiber: 2 });
    f.store.complete(a.operation, { calories: 900, protein: 10, fiber: 2 });
    assert.equal(f.store.get(e.id).nutrition.calories, 200);
  } finally {
    f.close();
  }
});
test('encrypted key, decimal receipts, unknown costs, dedup and deleted-meal spending', () => {
  const f = fixture();
  try {
    f.store.setKey('secret-test-key');
    assert.equal(f.store.key(), 'secret-test-key');
    assert(!f.store.setting('openrouter').includes('secret-test-key'));
    f.store.receipt('stt', 'transcription', 0.000508);
    f.store.receipt('ai', 'analysis', 0.000012);
    f.store.receipt('ai', 'analysis', 0.000012);
    f.store.receipt('unknown', 'analysis', null);
    assert.equal(f.store.spending().total, '0.00052');
    assert.equal(f.store.spending().unknownCount, 1);
    const e = f.store.create({ input: 'meal', day, nutrition: values });
    f.store.remove(e.id, e.version);
    assert.equal(f.store.spending().total, '0.00052');
  } finally {
    f.close();
  }
});
test('three bounded attempts count paid rejected estimates and preserve input exactly', async () => {
  const f = fixture();
  try {
    f.store.setKey('test-key');
    const text = '  Примерно two bowls фо бо\n',
      e = f.store.create({ input: text, day }),
      { operation } = f.store.start(
        e.id,
        'analysis',
        { operationID: randomUUID(), input: text, expectedVersion: e.version },
        'replacement/model',
      );
    let calls = 0;
    const delays = [];
    const payloads = [];
    const worker = new Worker(
      f.store,
      async (url, opts) => {
        payloads.push(JSON.parse(opts.body));
        calls++;
        return new Response(
          JSON.stringify({
            id: 'gen-' + calls,
            usage: { cost: 0.0001 },
            choices: [
              {
                message: { content: JSON.stringify({ calories: 38000, protein: 1, fiber: 1 }) },
                finish_reason: 'stop',
              },
            ],
          }),
          { status: 200 },
        );
      },
      async (ms) => {
        delays.push(ms);
      },
      () => 0,
    );
    await worker.run(operation, new AbortController().signal);
    assert.equal(calls, 3);
    assert.deepEqual(delays, [1000, 2000]);
    assert.equal(f.store.operation(operation.id).errorCategory, 'nutrition_out_of_range');
    assert.equal(f.store.spending().total, '0.0003');
    assert(payloads[0].messages[0].content.endsWith(text));
    assert.equal(payloads[0].model, 'replacement/model');
    assert.equal(payloads[0].response_format.json_schema.strict, true);
  } finally {
    f.close();
  }
});
test('authorization errors do not retry; 429 observes Retry-After', async () => {
  for (const status of [401, 402, 429]) {
    const f = fixture();
    try {
      f.store.setKey('key');
      const e = f.store.create({ input: 'meal', day });
      const { operation } = f.store.start(
        e.id,
        'analysis',
        { operationID: randomUUID(), input: 'meal', expectedVersion: e.version },
        'model',
      );
      let calls = 0;
      const delays = [];
      const worker = new Worker(
        f.store,
        async () => {
          calls++;
          return new Response('{}', { status, headers: { 'Retry-After': '10' } });
        },
        async (ms) => {
          delays.push(ms);
        },
        () => 0,
      );
      await worker.run(operation, new AbortController().signal);
      assert.equal(calls, status === 429 ? 3 : 1);
      if (status === 429) assert.deepEqual(delays, [10000, 10000]);
    } finally {
      f.close();
    }
  }
});
test('audio keeps original language and transcription never analyzes automatically', async () => {
  const f = fixture();
  try {
    f.store.setKey('key');
    const e = f.store.create({ day });
    const { operation } = f.store.start(
      e.id,
      'transcription',
      { operationID: randomUUID(), expectedVersion: e.version },
      'speech',
    );
    let calls = 0;
    const worker = new Worker(f.store, async (url, opts) => {
      calls++;
      const payload = JSON.parse(opts.body);
      assert.equal(payload.language, undefined);
      assert.equal(payload.input_audio.format, 'wav');
      return new Response(JSON.stringify({ text: ' Два eggs ', usage: { cost: 0.000508 } }), {
        status: 200,
      });
    });
    await worker.run(operation, new AbortController().signal, Buffer.from('RIFF'));
    assert.equal(calls, 1);
    assert.equal(f.store.get(e.id).draftInput, ' Два eggs ');
    assert.equal(f.store.get(e.id).nutrition, null);
  } finally {
    f.close();
  }
});
test('local migration is idempotent, and restart interrupts processing without losing old totals', () => {
  const f = fixture();
  let reopened;
  try {
    const e = f.store.create({ input: 'meal', day, nutrition: values });
    const op = f.store.start(
      e.id,
      'analysis',
      { operationID: randomUUID(), input: 'new', expectedVersion: e.version },
      'model',
    );
    f.store.db.close();
    reopened = new Store(f.path, Buffer.alloc(32, 1), '11111111-1111-4111-8111-111111111111');
    reopened.recoverInterrupted();
    assert.equal(reopened.get(e.id).phase, 'ready');
    assert.deepEqual(reopened.get(e.id).nutrition, values);
    assert.equal(reopened.operation(op.operation.id).phase, 'interrupted');
    const key = randomUUID(),
      old = { ...e, id: randomUUID() };
    reopened.import(key, [old]);
    reopened.import(key, [old]);
    assert.equal(reopened.list().length, 2);
  } finally {
    reopened?.db.close();
    rmSync(f.path, { recursive: true, force: true });
  }
});
test('cancellation before request arrival and during backoff prevents new requests', async () => {
  const f = fixture();
  try {
    f.store.setKey('key');
    const e = f.store.create({ input: 'meal', day }),
      late = randomUUID();
    f.store.cancel(late);
    assert.throws(
      () =>
        f.store.start(
          e.id,
          'analysis',
          { operationID: late, input: 'meal', expectedVersion: e.version },
          'model',
        ),
      { code: 'cancelled' },
    );
    const { operation } = f.store.start(
      e.id,
      'analysis',
      { operationID: randomUUID(), input: 'meal', expectedVersion: e.version },
      'model',
    );
    let calls = 0,
      waiting;
    const entered = new Promise((r) => (waiting = r));
    const worker = new Worker(
      f.store,
      async () => {
        calls++;
        return new Response('{}', { status: 503 });
      },
      async (ms, v, { signal }) => {
        waiting();
        await new Promise((resolve, reject) =>
          signal.addEventListener('abort', () => reject(new Error('cancelled')), { once: true }),
        );
      },
      () => 0,
    );
    worker.launch(operation);
    await entered;
    worker.cancel(operation.id);
    await new Promise((r) => setTimeout(r, 5));
    assert.equal(calls, 1);
    assert.equal(f.store.operation(operation.id).phase, 'cancelled');
    assert.equal(f.store.get(e.id).activeOperationID, null);
  } finally {
    f.close();
  }
});
test('network timeouts have three attempts and HTTP-date Retry-After is a minimum', async () => {
  const f = fixture();
  try {
    f.store.setKey('key');
    const e = f.store.create({ input: 'meal', day }),
      { operation } = f.store.start(
        e.id,
        'analysis',
        { operationID: randomUUID(), input: 'meal', expectedVersion: e.version },
        'model',
      );
    let calls = 0;
    const delays = [];
    const worker = new Worker(
      f.store,
      async () => {
        calls++;
        if (calls === 1) throw new DOMException('timeout', 'TimeoutError');
        return new Response('{}', {
          status: 429,
          headers: { 'Retry-After': new Date(Date.now() + 30000).toUTCString() },
        });
      },
      async (ms) => {
        delays.push(ms);
      },
      () => 0,
    );
    await worker.run(operation, new AbortController().signal);
    assert.equal(calls, 3);
    assert.equal(delays[0], 1000);
    assert(delays[1] >= 28000);
  } finally {
    f.close();
  }
});
test('storage failure retains validated values in memory and retries saving without another paid call', async () => {
  const f = fixture();
  try {
    f.store.setKey('key');
    const e = f.store.create({ input: 'old', day, nutrition: values }),
      { operation } = f.store.start(
        e.id,
        'analysis',
        { operationID: randomUUID(), input: 'edited', expectedVersion: e.version },
        'model',
      );
    let calls = 0;
    const complete = f.store.complete.bind(f.store);
    f.store.complete = () => {
      throw Error('simulated storage failure');
    };
    const worker = new Worker(f.store, async () => {
      calls++;
      return new Response(
        JSON.stringify({
          id: 'paid-once',
          usage: { cost: 0.001 },
          choices: [
            {
              message: { content: '{"calories":200,"protein":10,"fiber":2}' },
              finish_reason: 'stop',
            },
          ],
        }),
        { status: 200 },
      );
    });
    await worker.run(operation, new AbortController().signal);
    assert.equal(calls, 1);
    assert.equal(worker.operation(operation.id).errorCategory, 'persistence');
    assert.deepEqual(f.store.get(e.id).nutrition, values);
    assert.equal(f.store.get(e.id).draftInput, 'edited');
    f.store.complete = complete;
    worker.retrySave(operation.id);
    assert.equal(calls, 1);
    assert.equal(f.store.get(e.id).nutrition.calories, 200);
    assert.equal(f.store.get(e.id).originalInput, 'edited');
    assert.equal(f.store.operation(operation.id).phase, 'succeeded');
  } finally {
    f.close();
  }
});

test('delete-all discards late billing and results from the previous data generation', async () => {
  const f = fixture();
  try {
    f.store.setKey('test-key');
    const entry = f.store.create({ input: 'meal', day });
    const { operation } = f.store.start(
      entry.id,
      'analysis',
      { operationID: randomUUID(), input: 'meal', expectedVersion: entry.version },
      'model',
    );
    let release;
    const response = new Promise((resolve) => {
      release = resolve;
    });
    const worker = new Worker(f.store, async () => response);
    worker.launch(operation);
    worker.clearAll();
    f.store.clear();
    release(
      new Response(
        JSON.stringify({
          id: 'late-generation',
          usage: { cost: 0.5 },
          choices: [{ message: { content: JSON.stringify(values) }, finish_reason: 'stop' }],
        }),
      ),
    );
    while (worker.busy) await new Promise((resolve) => setTimeout(resolve, 1));
    assert.equal(f.store.list().length, 0);
    assert.equal(f.store.spending().total, '0');
    assert.equal(f.store.spending().unknownCount, 0);
  } finally {
    f.close();
  }
});
