import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import type { IncomingMessage, ServerResponse } from 'node:http';

const hash = (s: string) => createHash('sha256').update(s).digest('hex');
const secret = () => randomBytes(32).toString('base64url');
const now = () => Math.floor(Date.now() / 1000);
const escape = (s: string) =>
  s.replace(
    /[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!,
  );
export function json(res: ServerResponse, status: number, body: unknown) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(body));
}
export async function body(req: IncomingMessage, limit = 65536) {
  let s = '';
  for await (const chunk of req) {
    s += chunk;
    if (Buffer.byteLength(s) > limit) throw new Error('invalid_request');
  }
  return s;
}
function redirect(res: ServerResponse, url: string) {
  res.writeHead(303, { Location: url });
  res.end();
}
type Client = {
  client_id: string;
  client_name: string;
  redirect_uris: string[];
  token_endpoint_auth_method: 'none';
  application_type: 'native' | 'web';
};
export function redirectMatches(registered: string, requested: string, native: boolean) {
  if (registered === requested) return true;
  if (!native) return false;
  try {
    const expected = new URL(registered),
      actual = new URL(requested);
    if (
      expected.protocol !== 'http:' ||
      !['127.0.0.1', '[::1]', 'localhost'].includes(expected.hostname) ||
      actual.username ||
      actual.password ||
      actual.hash
    )
      return false;
    // RFC 8252 native loopback callbacks may choose an ephemeral port.
    // Every other URI component remains bound to the published metadata.
    expected.port = '';
    actual.port = '';
    return expected.href === actual.href;
  } catch {
    return false;
  }
}
type Pending = {
  client: Client;
  redirect: string;
  state: string;
  challenge: string;
  scope: string;
  resource: string;
  csrf: string;
  expires: number;
};
type Code = {
  client: string;
  redirect: string;
  challenge: string;
  scope: string;
  resource: string;
  expires: number;
};
type Token = {
  digest: string;
  kind: string;
  client: string;
  family: string;
  scope: string;
  resource: string;
  expires: number;
  used: number;
};
export class OAuth {
  readonly resource: string;
  private db: DatabaseSync;
  private pending = new Map<string, Pending>();
  private quota = new Map<string, { n: number; reset: number }>();
  constructor(
    readonly origin: string,
    path = '/data/oauth',
  ) {
    this.resource = origin;
    mkdirSync(path, { recursive: true, mode: 0o700 });
    this.db = new DatabaseSync(path + '/state.sqlite');
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS clients(id TEXT PRIMARY KEY, metadata TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS codes(digest TEXT PRIMARY KEY, data TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS families(id TEXT PRIMARY KEY, revoked INTEGER NOT NULL DEFAULT 0, expires INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS tokens(digest TEXT PRIMARY KEY, kind TEXT, client TEXT, family TEXT, scope TEXT, resource TEXT, expires INTEGER, used INTEGER DEFAULT 0);
      CREATE INDEX IF NOT EXISTS tokens_family ON tokens(family);`);
    const native: Client = {
      client_id: 'nutrition-ios',
      client_name: 'Nutri',
      redirect_uris: ['nutritiontracker://oauth/callback'],
      token_endpoint_auth_method: 'none',
      application_type: 'native',
    };
    this.db
      .prepare(
        'INSERT INTO clients VALUES (?,?) ON CONFLICT(id) DO UPDATE SET metadata=excluded.metadata',
      )
      .run(native.client_id, JSON.stringify(native));
  }
  private limit(key: string, max: number, seconds: number) {
    const q = this.quota.get(key);
    if (!q || q.reset <= now()) this.quota.set(key, { n: 1, reset: now() + seconds });
    else if (++q.n > max) throw new Error('temporarily_unavailable');
  }
  private redirectAllowed(value: string) {
    try {
      const u = new URL(value);
      return (
        !u.username &&
        !u.password &&
        !u.hash &&
        value.length <= 2048 &&
        ((u.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(u.hostname)) ||
          (u.protocol === 'https:' &&
            !u.port &&
            ['chatgpt.com', 'chat.openai.com', 'codex.openai.com'].includes(u.hostname)))
      );
    } catch {
      return false;
    }
  }
  private validateClient(value: unknown, id: string): Client {
    const v = value as Record<string, unknown>;
    if (
      !v ||
      !Array.isArray(v.redirect_uris) ||
      !v.redirect_uris.length ||
      v.redirect_uris.length > 20 ||
      !v.redirect_uris.every((x) => typeof x === 'string' && this.redirectAllowed(x))
    )
      throw new Error('invalid_client_metadata');
    const methods = v.token_endpoint_auth_methods_supported;
    if (
      Array.isArray(methods)
        ? !methods.includes('none')
        : v.token_endpoint_auth_method && v.token_endpoint_auth_method !== 'none'
    )
      throw new Error('invalid_client_metadata');
    return {
      client_id: id,
      client_name: typeof v.client_name === 'string' ? v.client_name.slice(0, 120) : 'MCP client',
      redirect_uris: v.redirect_uris as string[],
      token_endpoint_auth_method: 'none',
      application_type: v.application_type === 'native' ? 'native' : 'web',
    };
  }
  private async client(id: string): Promise<Client> {
    if (id.startsWith('https://')) {
      const u = new URL(id);
      if (
        u.origin !== 'https://chatgpt.com' ||
        !/^\/oauth\/(?:[a-zA-Z0-9_-]+\/)?client\.json$/.test(u.pathname) ||
        u.search ||
        u.hash
      )
        throw new Error('invalid_client');
      this.limit('cimd', 120, 60);
      const r = await fetch(id, {
        redirect: 'error',
        signal: AbortSignal.timeout(5000),
      });
      if (!r.ok) throw new Error('invalid_client');
      const text = await r.text();
      if (text.length > 32768) throw new Error('invalid_client');
      const m = JSON.parse(text);
      if (m.client_id !== id) throw new Error('invalid_client');
      return this.validateClient(m, id);
    }
    const row = this.db.prepare('SELECT metadata FROM clients WHERE id=?').get(id) as
      { metadata: string } | undefined;
    if (!row) throw new Error('invalid_client');
    return JSON.parse(row.metadata);
  }
  private scopes(s: string) {
    const scopes = [...new Set(s.split(' ').filter(Boolean))];
    if (
      !scopes.includes('nutrition:read') ||
      scopes.some((x) => !['nutrition:read', 'nutrition:write', 'offline_access'].includes(x))
    )
      throw new Error('invalid_scope');
    return scopes.join(' ');
  }
  private async owner(req: IncomingMessage): Promise<boolean> {
    const gate = /(?:^|;\s*)gate_session=([A-Za-z0-9_-]{20,128})(?:;|$)/.exec(
      req.headers.cookie || '',
    )?.[1];
    if (!gate) return false;
    const url = process.env.OWNER_GATE_URL || 'http://auth-gate-mc1wxe:8000/internal/nutri-owner';
    const r = await fetch(url, {
      headers: {
        'X-Nutri-Host': new URL(this.origin).host,
        Cookie: `gate_session=${gate}`,
      },
      redirect: 'error',
      signal: AbortSignal.timeout(5000),
    });
    return r.ok && ((await r.json()) as { owner?: boolean }).owner === true;
  }
  private issue(client: string, scope: string, resource: string, family?: string) {
    family ||= secret();
    const access = secret(),
      refresh = secret();
    // OAuth refresh tokens do not require the OIDC offline_access scope.
    // MCP clients request tool scopes only; keep those scopes unchanged.
    const refreshable =
      resource === this.origin + '/mcp' || scope.split(' ').includes('offline_access');
    if (!this.db.prepare('SELECT 1 FROM families WHERE id=?').get(family))
      this.db.prepare('INSERT INTO families VALUES (?,0,?)').run(family, now() + 30 * 86400);
    const familyExpiry = (
      this.db.prepare('SELECT expires FROM families WHERE id=?').get(family) as { expires: number }
    ).expires;
    const insert = this.db.prepare(
      'INSERT INTO tokens(digest,kind,client,family,scope,resource,expires) VALUES (?,?,?,?,?,?,?)',
    );
    insert.run(hash(access), 'access', client, family, scope, resource, now() + 900);
    if (refreshable)
      insert.run(hash(refresh), 'refresh', client, family, scope, resource, familyExpiry);
    return {
      access_token: access,
      token_type: 'Bearer',
      expires_in: 900,
      scope,
      ...(refreshable ? { refresh_token: refresh } : {}),
    };
  }
  verify(token: string, scope = 'nutrition:read', resource = this.resource): boolean {
    if (token.length > 512) return false;
    return Boolean(
      this.db
        .prepare(
          `SELECT 1 FROM tokens t JOIN families f ON f.id=t.family WHERE t.digest=? AND t.kind='access' AND t.expires>? AND f.revoked=0 AND f.expires>? AND t.resource=? AND instr(' ' || t.scope || ' ', ' ' || ? || ' ')>0`,
        )
        .get(hash(token), now(), now(), resource, scope),
    );
  }
  async handle(req: IncomingMessage, res: ServerResponse, url: URL): Promise<boolean> {
    const p = url.pathname;
    if (p.startsWith('/.well-known/')) {
      res.setHeader('Access-Control-Allow-Origin', '*');
      if (req.method !== 'GET') {
        json(res, 405, { error: 'invalid_request' });
        return true;
      }
      if (
        p === '/.well-known/oauth-protected-resource' ||
        p === '/.well-known/oauth-protected-resource/mcp'
      )
        json(res, 200, {
          resource: p.endsWith('/mcp') ? this.origin + '/mcp' : this.resource,
          authorization_servers: [this.origin],
          scopes_supported: ['nutrition:read', 'nutrition:write', 'offline_access'],
          bearer_methods_supported: ['header'],
        });
      else if (p === '/.well-known/oauth-authorization-server')
        json(res, 200, {
          issuer: this.origin,
          authorization_endpoint: this.origin + '/oauth/authorize',
          token_endpoint: this.origin + '/oauth/token',
          registration_endpoint: this.origin + '/oauth/register',
          revocation_endpoint: this.origin + '/oauth/revoke',
          response_types_supported: ['code'],
          grant_types_supported: ['authorization_code', 'refresh_token'],
          token_endpoint_auth_methods_supported: ['none'],
          code_challenge_methods_supported: ['S256'],
          scopes_supported: ['nutrition:read', 'nutrition:write', 'offline_access'],
          client_id_metadata_document_supported: true,
          authorization_response_iss_parameter_supported: true,
        });
      else json(res, 404, { error: 'not_found' });
      return true;
    }
    if (!p.startsWith('/oauth/')) return false;
    try {
      this.limit('oauth', 600, 60);
      if (p === '/oauth/register' && req.method === 'POST') {
        this.limit('register', 60, 3600);
        if (
          (
            this.db.prepare('SELECT count(*) AS n FROM clients').get() as {
              n: number;
            }
          ).n >= 1000
        )
          throw new Error('temporarily_unavailable');
        const id = secret(),
          client = this.validateClient(JSON.parse(await body(req)), id);
        this.db.prepare('INSERT INTO clients VALUES (?,?)').run(id, JSON.stringify(client));
        json(res, 201, {
          ...client,
          client_id_issued_at: now(),
          grant_types: ['authorization_code', 'refresh_token'],
          response_types: ['code'],
        });
        return true;
      }
      if (p === '/oauth/authorize' && req.method === 'GET') {
        const q = url.searchParams,
          client = await this.client(q.get('client_id') || ''),
          redir = q.get('redirect_uri') || '';
        if (
          !client.redirect_uris.some((uri) =>
            redirectMatches(uri, redir, client.application_type === 'native'),
          )
        )
          throw new Error('invalid_request');
        if (
          q.get('response_type') !== 'code' ||
          q.get('code_challenge_method') !== 'S256' ||
          !/^[A-Za-z0-9_-]{43}$/.test(q.get('code_challenge') || '') ||
          ![this.resource, this.origin + '/mcp'].includes(q.get('resource') || '')
        )
          throw new Error('invalid_request');
        const scope = this.scopes(q.get('scope') || 'nutrition:read');
        if (!(await this.owner(req))) {
          redirect(res, 'https://auth.dgazizullin.dev/login?next=' + encodeURIComponent(url.href));
          return true;
        }
        for (const [id, v] of this.pending) if (v.expires <= now()) this.pending.delete(id);
        if (this.pending.size >= 100) throw new Error('temporarily_unavailable');
        const id = secret(),
          csrf = secret();
        this.pending.set(id, {
          client,
          redirect: redir,
          state: (q.get('state') || '').slice(0, 2048),
          challenge: q.get('code_challenge')!,
          scope,
          resource: q.get('resource')!,
          csrf,
          expires: now() + 600,
        });
        res.setHeader(
          'Set-Cookie',
          `oauth_consent_${id}=${csrf}; HttpOnly; Secure; SameSite=Lax; Path=/oauth; Max-Age=600`,
        );
        // no-referrer makes Chromium serialize a navigation form's Origin as
        // null. Keep the origin for CSRF validation without leaking URL queries.
        res.setHeader('Referrer-Policy', 'strict-origin');
        res.setHeader(
          'Content-Security-Policy',
          // Chromium applies form-action to redirects from the submitted form.
          // Allow this validated client's callback origin as well as our POST.
          `default-src 'none'; style-src 'unsafe-inline'; form-action 'self' ${new URL(redir).protocol === 'nutritiontracker:' ? 'nutritiontracker:' : new URL(redir).origin}; frame-ancestors 'none'; base-uri 'none'`,
        );
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(
          `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Connect Nutri</title><body style="color-scheme:dark;max-width:560px;margin:10vh auto;padding:24px;font:18px system-ui"><h1>Connect Nutri</h1><p>${escape(client.client_name)} will be able to read your meals and spending.${scope.includes('nutrition:write') ? ' It can also add, edit, delete and reanalyze meals, and change your nutrition settings.' : ''}</p>${q.get('resource') === this.origin + '/mcp' || scope.split(' ').includes('offline_access') ? '<p>This connection can renew access automatically for up to 30 days. Disconnect it to revoke access.</p>' : ''}<p>Food descriptions and audio you submit for processing are sent to OpenRouter and its model providers. Your meals are stored on your private Nutri server.</p><form method="post" action="/oauth/consent"><input type="hidden" name="csrf" value="${csrf}"><button name="decision" value="allow">Connect</button> <button name="decision" value="deny">Cancel</button></form></body></html>`,
        );
        return true;
      }
      if (p === '/oauth/consent' && req.method === 'POST') {
        const form = new URLSearchParams(await body(req));
        const csrf = form.get('csrf') || '';
        const entry = [...this.pending].find(([, value]) => value.csrf === csrf);
        const [id, pending] = entry || ['', undefined];
        const cookieBound = Boolean(
          pending &&
          (req.headers.cookie || '').split(/;\s*/).includes(`oauth_consent_${id}=${csrf}`),
        );
        const owner = pending && cookieBound ? await this.owner(req) : false;
        const checks = {
          pending: Boolean(pending),
          unexpired: Boolean(pending && pending.expires > now()),
          origin: req.headers.origin === this.origin,
          cookie: cookieBound,
          owner: Boolean(owner),
        };
        if (Object.values(checks).some((value) => !value)) {
          // Booleans only: never log cookies, CSRF values or OAuth parameters.
          console.warn('OAuth consent rejected', JSON.stringify(checks));
          throw new Error('access_denied');
        }
        if (!pending) throw new Error('access_denied');
        this.pending.delete(id);
        res.setHeader(
          'Set-Cookie',
          `oauth_consent_${id}=; HttpOnly; Secure; SameSite=Lax; Path=/oauth; Max-Age=0`,
        );
        const target = new URL(pending.redirect);
        target.searchParams.set('iss', this.origin);
        if (pending.state) target.searchParams.set('state', pending.state);
        if (form.get('decision') !== 'allow') target.searchParams.set('error', 'access_denied');
        else {
          const code = secret(),
            data: Code = {
              client: pending.client.client_id,
              redirect: pending.redirect,
              challenge: pending.challenge,
              scope: pending.scope,
              resource: pending.resource,
              expires: now() + 120,
            };
          this.db.prepare('INSERT INTO codes VALUES (?,?)').run(hash(code), JSON.stringify(data));
          target.searchParams.set('code', code);
        }
        redirect(res, target.href);
        return true;
      }
      if (p === '/oauth/token' && req.method === 'POST') {
        const q = new URLSearchParams(await body(req));
        if (q.has('client_secret') || q.has('client_assertion') || req.headers.authorization)
          throw new Error('invalid_client');
        await this.client(q.get('client_id') || '');
        this.db.exec('BEGIN IMMEDIATE');
        try {
          if (q.get('grant_type') === 'authorization_code') {
            const codeDigest = hash(q.get('code') || ''),
              row = this.db.prepare('SELECT data FROM codes WHERE digest=?').get(codeDigest) as
                { data: string } | undefined;
            if (!row) throw new Error('invalid_grant');
            const data: Code = JSON.parse(row.data),
              verifier = q.get('code_verifier') || '';
            const challenge = createHash('sha256').update(verifier).digest('base64url');
            if (
              data.expires <= now() ||
              data.client !== q.get('client_id') ||
              data.redirect !== q.get('redirect_uri') ||
              data.resource !== q.get('resource') ||
              !/^[A-Za-z0-9._~-]{43,128}$/.test(verifier) ||
              !timingSafeEqual(Buffer.from(challenge), Buffer.from(data.challenge))
            )
              throw new Error('invalid_grant');
            this.db.prepare('DELETE FROM codes WHERE digest=?').run(codeDigest);
            const issued = this.issue(data.client, data.scope, data.resource);
            this.db.exec('COMMIT');
            json(res, 200, issued);
          } else if (q.get('grant_type') === 'refresh_token') {
            const token = this.db
              .prepare("SELECT * FROM tokens WHERE digest=? AND kind='refresh'")
              .get(hash(q.get('refresh_token') || '')) as Token | undefined;
            if (
              !token ||
              token.client !== q.get('client_id') ||
              (q.has('resource') && token.resource !== q.get('resource'))
            )
              throw new Error('invalid_grant');
            if (token.used) {
              this.db.prepare('UPDATE families SET revoked=1 WHERE id=?').run(token.family);
              this.db.exec('COMMIT');
              throw new Error('invalid_grant');
            }
            if (
              token.expires <= now() ||
              !this.db
                .prepare('SELECT 1 FROM families WHERE id=? AND revoked=0 AND expires>?')
                .get(token.family, now())
            )
              throw new Error('invalid_grant');
            if (q.has('scope') && q.get('scope') !== token.scope) throw new Error('invalid_scope');
            this.db.prepare('UPDATE tokens SET used=1 WHERE digest=?').run(token.digest);
            const issued = this.issue(token.client, token.scope, token.resource, token.family);
            this.db.exec('COMMIT');
            json(res, 200, issued);
          } else throw new Error('unsupported_grant_type');
        } catch (e) {
          try {
            this.db.exec('ROLLBACK');
          } catch {}
          throw e;
        }
        return true;
      }
      if (p === '/oauth/revoke' && req.method === 'POST') {
        const q = new URLSearchParams(await body(req));
        const row = this.db
          .prepare('SELECT family,client FROM tokens WHERE digest=?')
          .get(hash(q.get('token') || '')) as { family: string; client: string } | undefined;
        if (row && row.client === q.get('client_id'))
          this.db.prepare('UPDATE families SET revoked=1 WHERE id=?').run(row.family);
        json(res, 200, {});
        return true;
      }
      json(res, 405, { error: 'invalid_request' });
      return true;
    } catch (e) {
      const code = e instanceof Error ? e.message : '';
      json(res, code === 'temporarily_unavailable' ? 429 : 400, {
        error: [
          'invalid_client',
          'invalid_client_metadata',
          'invalid_scope',
          'invalid_request',
          'invalid_grant',
          'unsupported_grant_type',
          'access_denied',
          'temporarily_unavailable',
        ].includes(code)
          ? code
          : 'invalid_request',
      });
      return true;
    }
  }
}
