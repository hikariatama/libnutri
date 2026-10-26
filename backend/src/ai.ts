import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';
import { Store, Fault, nutrition, type Operation, type Nutrition } from './store.js';
const prompt = readFileSync(new URL('./nutrition-prompt.txt', import.meta.url), 'utf8').replace(
  /\n$/,
  '',
);
export class Worker {
  private billingEpoch = 0;
  clearAll() {
    this.billingEpoch += 1;
    this.cancelAll();
  }
  get busy() {
    return this.running.size > 0 || this.pending.size > 0;
  }
  private running = new Map<string, AbortController>();
  private pending = new Map<string, { operation: Operation; result: Nutrition | string }>();
  operation(id: string) {
    return this.pending.get(id)?.operation || this.store.operation(id);
  }
  private commit(op: Operation, result: Nutrition | string) {
    try {
      this.store.complete(op, result);
    } catch {
      op.phase = 'failed';
      op.errorCategory = 'persistence';
      op.waitingUntil = null;
      this.pending.set(op.id, { operation: { ...op }, result });
      try {
        const e = this.store.current(op);
        if (e) {
          e.phase = 'saving';
          this.store.put(e);
          this.store.saveOperation(op);
        }
      } catch {}
    }
  }
  retrySave(id: string) {
    const pending = this.pending.get(id);
    if (!pending) throw new Fault('not_found', 404);
    if (!this.store.current(pending.operation)) {
      this.pending.delete(id);
      throw new Fault('version_conflict', 409);
    }
    try {
      this.store.complete(pending.operation, pending.result);
      this.pending.delete(id);
    } catch {
      throw new Fault('persistence', 503);
    }
    return this.store.operation(id)!;
  }
  constructor(
    private store: Store,
    private send: typeof fetch = fetch,
    private wait: typeof sleep = sleep,
    private jitter = () => Math.random() * 250,
  ) {}
  launch(op: Operation, audio?: Buffer) {
    const controller = new AbortController();
    this.running.set(op.id, controller);
    void this.run(op, controller.signal, audio)
      .catch(() => console.error('Operation persistence failed'))
      .finally(() => this.running.delete(op.id));
  }
  cancel(id: string) {
    this.running.get(id)?.abort();
    this.pending.delete(id);
    this.store.cancel(id);
  }
  cancelAll() {
    for (const id of new Set([...this.running.keys(), ...this.pending.keys()])) this.cancel(id);
  }
  async run(op: Operation, signal: AbortSignal, audio?: Buffer) {
    const store = this.store;
    const billingEpoch = this.billingEpoch;
    try {
      const key = store.key();
      const payload =
        op.kind === 'analysis'
          ? {
              model: op.model,
              stream: false,
              messages: [
                {
                  role: 'user',
                  content: prompt.replace(/\{\{TRANSCRIPT\}\}$/, () => op.inputSnapshot),
                },
              ],
              provider: { require_parameters: true },
              response_format: {
                type: 'json_schema',
                json_schema: {
                  name: 'nutrition',
                  strict: true,
                  schema: {
                    type: 'object',
                    properties: {
                      calories: { type: 'number' },
                      protein: { type: 'number' },
                      fiber: { type: 'number' },
                    },
                    required: ['calories', 'protein', 'fiber'],
                    additionalProperties: false,
                  },
                },
              },
            }
          : {
              model: op.model,
              input_audio: { data: audio?.toString('base64'), format: 'wav' },
              response_format: 'json',
            };
      for (let attempt = 1; attempt <= 3; attempt++) {
        signal.throwIfAborted();
        if (!store.current(op)) return;
        op.requestCount = attempt;
        op.phase = 'running';
        op.waitingUntil = null;
        store.saveOperation(op);
        let delay = 2 ** (attempt - 1) * 1000 + this.jitter(),
          received = false;
        try {
          const r = await this.send(
            'https://openrouter.ai/api/v1/' +
              (op.kind === 'analysis' ? 'chat/completions' : 'audio/transcriptions'),
            {
              method: 'POST',
              headers: { Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
              body: JSON.stringify(payload),
              signal: AbortSignal.any([signal, AbortSignal.timeout(75000)]),
            },
          );
          const raw = await r.text();
          received = true;
          let data: any;
          try {
            data = JSON.parse(raw);
          } catch {}
          if (billingEpoch === this.billingEpoch && (r.ok || typeof data?.usage?.cost === 'number'))
            store.receipt(
              data?.id || r.headers.get('x-generation-id') || randomUUID(),
              op.kind,
              data?.usage?.cost,
            );
          signal.throwIfAborted();
          const retry = r.headers.get('retry-after');
          if (retry) {
            const seconds = Number(retry);
            const ms = Number.isFinite(seconds) ? seconds * 1000 : Date.parse(retry) - Date.now();
            if (Number.isFinite(ms)) delay = Math.max(delay, ms);
          }
          if (!r.ok)
            throw new Fault(
              (
                {
                  401: 'invalid_key',
                  402: 'insufficient_balance',
                  403: 'permission',
                  404: 'unavailable_model',
                  429: 'rate_limited',
                } as Record<number, string>
              )[r.status] || (r.status >= 500 || r.status === 408 ? 'connection' : 'configuration'),
            );
          if (op.kind === 'analysis') {
            if (
              !Array.isArray(data?.choices) ||
              data.choices.length !== 1 ||
              data.choices[0]?.message?.refusal ||
              data.choices[0]?.finish_reason === 'length'
            )
              throw new Fault('invalid_response');
            let value: unknown;
            try {
              value = JSON.parse(data.choices[0].message.content);
            } catch {
              throw new Fault('invalid_response');
            }
            this.commit(op, nutrition(value));
          } else {
            if (typeof data?.text !== 'string') throw new Fault('invalid_response');
            if (!data.text.trim()) throw new Fault('no_speech');
            this.commit(op, data.text);
          }
          return;
        } catch (error) {
          if (!received && billingEpoch === this.billingEpoch)
            store.receipt(randomUUID(), op.kind, null);
          signal.throwIfAborted();
          const fault = error instanceof Fault ? error : new Fault('connection');
          if (
            !['connection', 'rate_limited', 'invalid_response', 'nutrition_out_of_range'].includes(
              fault.code,
            ) ||
            attempt === 3
          )
            throw fault;
          op.phase = 'waiting';
          op.waitingUntil = Date.now() + delay;
          store.saveOperation(op);
          await this.wait(delay, undefined, { signal });
        }
      }
    } catch (error) {
      if (!signal.aborted) this.store.fail(op, error instanceof Fault ? error.code : 'connection');
    }
  }
}
