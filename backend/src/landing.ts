import { readdirSync, readFileSync } from 'node:fs';
import type { IncomingMessage, ServerResponse } from 'node:http';

const files = [
  'index.html',
  'style.css',
  'main.js',
  'logo.svg',
  'icon.png',
  'fonts/huninn-subset.woff2',
  'fonts/OFL.txt',
];
const types: Record<string, string> = {
  html: 'text/html; charset=utf-8',
  css: 'text/css; charset=utf-8',
  js: 'text/javascript; charset=utf-8',
  svg: 'image/svg+xml',
  png: 'image/png',
  woff2: 'font/woff2',
  txt: 'text/plain; charset=utf-8',
};
const policy =
  "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

// Serves the static landing page from a fixed allowlist. `/` is HTML only for browsers;
// API clients keep receiving the JSON service description.
export function landing(directory = new URL('../../landing/', import.meta.url)) {
  const content = new Map<string, { body: Buffer; type: string }>();
  let icons: string[] = [];
  try {
    // SF Symbol masks rendered by scripts/render-symbols.swift.
    icons = readdirSync(new URL('icons/', directory))
      .filter((name) => /^[a-z-]+\.png$/.test(name))
      .map((name) => 'icons/' + name);
  } catch {}
  for (const name of [...files, ...icons]) {
    try {
      content.set(name === 'index.html' ? '/' : '/' + name, {
        body: readFileSync(new URL(name, directory)),
        type: types[name.split('.').pop()!],
      });
    } catch {}
  }
  return (req: IncomingMessage, res: ServerResponse, path: string): boolean => {
    if (req.method !== 'GET' && req.method !== 'HEAD') return false;
    if (path === '/' && !(req.headers.accept || '').includes('text/html')) return false;
    const file = content.get(path);
    if (!file) return false;
    res.writeHead(200, {
      'Content-Type': file.type,
      'Content-Length': file.body.length,
      'Cache-Control': path === '/' ? 'public, max-age=300' : 'public, max-age=3600',
      'Content-Security-Policy': policy,
    });
    res.end(req.method === 'HEAD' ? undefined : file.body);
    return true;
  };
}
