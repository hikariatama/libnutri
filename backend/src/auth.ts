import type { IncomingMessage } from 'node:http';
import { Fault, uuid } from './store.js';
export type Principal = { id: string; username: string; owner: boolean };
export type Authorization = {
  issuer: string;
  introspectionURL: string;
  clientId: string;
  clientSecret: string;
  ownerId: string;
};
export async function authorize(
  req: IncomingMessage,
  resource: string,
  scope: string,
  config: Authorization,
  send: typeof fetch = fetch,
): Promise<Principal> {
  const token = /^Bearer ([A-Za-z0-9._~-]{20,4096})$/.exec(req.headers.authorization || '')?.[1];
  if (!token) throw new Fault('invalid_token', 401);
  let response: Response;
  try {
    response = await send(config.introspectionURL, {
      method: 'POST',
      headers: {
        Authorization:
          'Basic ' + Buffer.from(config.clientId + ':' + config.clientSecret).toString('base64'),
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: new URLSearchParams({ token }),
      signal: AbortSignal.timeout(5000),
    });
  } catch {
    throw new Fault('auth_unavailable', 503);
  }
  if (!response.ok) throw new Fault('auth_unavailable', 503);
  let value: any;
  try {
    value = await response.json();
  } catch {
    throw new Fault('auth_unavailable', 503);
  }
  if (
    value.active !== true ||
    value.iss !== config.issuer ||
    value.aud !== resource ||
    typeof value.sub !== 'string'
  )
    throw new Fault('invalid_token', 401);
  if (
    !String(value.scope || '')
      .split(' ')
      .includes(scope)
  )
    throw new Fault('insufficient_scope', 403);
  let id: string;
  try {
    id = uuid(value.sub);
  } catch {
    throw new Fault('invalid_token', 401);
  }
  if (typeof value.username !== 'string' || !/^[a-z0-9_]{3,32}$/.test(value.username))
    throw new Fault('invalid_token', 401);
  return { id, username: value.username, owner: id === config.ownerId };
}
