import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

const fixtureRoot = new URL('../../protocols/source-v1/fixtures/', import.meta.url);
const canonicalURL = new URL('http://127.0.0.1:18764');
const manifest = JSON.parse(await readFile(new URL('manifest.json', fixtureRoot), 'utf8'));
const bodies = new Map(await Promise.all(manifest.resources.map(async route => [route.file, await readFile(new URL(route.file, fixtureRoot), 'utf8')])));
function routeKey(url) { const copy = new URL(url); copy.searchParams.sort(); return copy.pathname + copy.search; }
const routes = new Map(manifest.resources.map(route => [routeKey(new URL(route.route, canonicalURL)), route]));

export async function startFixtureServer({ port = 0 } = {}) {
  const requests = [];
  let activeRequests = 0;
  let baseURL;
  const server = createServer(async (request, response) => {
    activeRequests++;
    let closed = false;
    response.once('close', () => { if (!closed) { closed = true; activeRequests--; } });
    const url = new URL(request.url, baseURL);
    // Only synthetic public diagnostics are stored, never cookies or authorization values.
    requests.push({ method: request.method, path: url.pathname + url.search,
      hasAuthorization: Boolean(request.headers.authorization), hasCookie: Boolean(request.headers.cookie) });
    if (requests.length > 1000) requests.shift();
    const send = (status, body, headers = {}) => {
      if (response.destroyed) return;
      response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', ...headers });
      response.end(body);
    };
    const json = (status, body, headers) => send(status, JSON.stringify(body), headers);
    if (request.headers.host !== new URL(baseURL).host) { json(400, { error: 'Unexpected Host' }); return; }
    if (!['GET', 'POST'].includes(request.method)) { json(405, { error: 'Unsupported method' }); return; }
    if (url.pathname === '/') {
      send(200, `<!doctype html><html><head><title>Fixture login</title><meta name="viewport" content="width=device-width,initial-scale=1"></head><body><h1>Fixture login</h1><button id="login" onclick="fetch('/state/login').then(() => document.getElementById('status').textContent='Saved in browser')">Sign in</button><p id="status">Temporary browser</p></body></html>`, { 'Content-Type': 'text/html; charset=utf-8' });
      return;
    }
    if (url.pathname === '/health') { json(200, { fixtureVersion: 1 }); return; }
    if (url.pathname === '/diagnostics') { json(200, { requests, activeRequests: activeRequests - 1 }); return; }
    if (url.pathname === '/redirect/allowed') { send(302, '', { Location: '/health' }); return; }
    if (url.pathname === '/redirect/forbidden') { send(302, '', { Location: 'http://127.0.0.1:18765/forbidden' }); return; }
    if (url.pathname === '/redirect/loop') { send(302, '', { Location: '/redirect/loop' }); return; }
    if (url.pathname === '/failure/chunked-oversized') {
      response.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Transfer-Encoding': 'chunked' });
      for (let index = 0; index < 9; index++) response.write(Buffer.alloc(1024 * 1024, 120));
      response.end(); return;
    }
    if (url.pathname === '/encoding/utf16le') { send(200, Buffer.from('中文 fixture', 'utf16le'), { 'Content-Type': 'text/plain; charset=utf-16le' }); return; }
    if (url.pathname === '/encoding/invalid-utf8') { send(200, Buffer.from([0xff, 0xfe]), { 'Content-Type': 'text/plain; charset=utf-8' }); return; }

    if (url.pathname === '/failure/slow') {
      const delay = Math.min(2000, Math.max(0, Number(url.searchParams.get('ms')) || 100));
      const timer = setTimeout(() => json(200, { delayed: true }), delay);
      response.once('close', () => clearTimeout(timer));
      return;
    }
    if (url.pathname === '/failure/disconnect') { request.socket.destroy(); return; }
    if (url.pathname === '/failure/empty') { json(200, { items: [], nextCursor: null }); return; }
    if (url.pathname === '/failure/repeat-cursor') { json(200, { items: [], nextCursor: { page: 1 } }); return; }
    if (url.pathname === '/failure/rate-limited') { json(429, { error: 'limited' }, { 'Retry-After': '3' }); return; }
    if (url.pathname === '/failure/server-error') { json(503, { error: 'unavailable' }); return; }
    if (url.pathname === '/failure/oversized') { send(200, 'x'.repeat(9 * 1024 * 1024), { 'Content-Type': 'text/plain' }); return; }
    if (url.pathname === '/failure/parse') { send(200, '<html><body>Required article missing</body></html>', { 'Content-Type': 'text/html' }); return; }
    if (url.pathname === '/state/login') { json(200, { fixtureSession: true }, { 'Set-Cookie': 'fixture_session=fixture-a; Path=/; HttpOnly; SameSite=Lax' }); return; }
    if (url.pathname === '/state/account') {
      const account = /(?:^|;\s*)fixture_session=(fixture-[ab])(?:;|$)/.exec(request.headers.cookie ?? '')?.[1];
      json(account ? 200 : 401, account ? { account } : { error: 'AUTH_REQUIRED' }); return;
    }
    if (url.pathname === '/state/expired') { json(401, { error: 'AUTH_REQUIRED' }); return; }
    if (url.pathname === '/changes/catalog') {
      const scenario = url.searchParams.get('scenario') ?? 'base';
      const page = Number(url.searchParams.get('page') ?? 1);
      const chapter = id => ({ ref: { id }, title: id === 'ch-1' || id === 'ch-2' ? 'Repeated title' : id });
      const ids = { base: ['ch-1', 'ch-2'], reorder: ['ch-2', 'ch-1'], delete: ['ch-2'], insert: ['ch-1', 'ch-3', 'ch-2'], replace: ['ch-1', 'ch-3'], revision: page === 1 ? ['ch-1'] : ['ch-2'] }[scenario];
      if (!ids) { json(400, { error: 'Unknown scenario' }); return; }
      json(200, { items: ids.map(chapter), nextCursor: scenario === 'revision' && page === 1 ? { page: 2 } : null,
        revision: scenario === 'base' || (scenario === 'revision' && page === 1) ? 'r1' : 'r2' }); return;
    }
    if (url.pathname === '/api/echo' && request.method === 'POST') {
      let size = 0; const chunks = [];
      try {
        for await (const chunk of request) { size += chunk.length; if (size > 16384) { json(413, { error: 'Too large' }); return; } chunks.push(chunk); }
        json(200, { method: request.method, contentType: request.headers['content-type'] ?? null, body: Buffer.concat(chunks).toString('utf8') });
      } catch { if (!response.destroyed) json(400, { error: 'Bad request body' }); }
      return;
    }
    const route = routes.get(routeKey(url));
    if (!route || route.method !== request.method) { json(404, { error: 'Unknown fixture route' }); return; }
    const body = bodies.get(route.file).replaceAll(canonicalURL.origin, baseURL);
    send(200, body, { 'Content-Type': route.contentType });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
  baseURL = `http://127.0.0.1:${server.address().port}`;
  return { baseURL, requests, get activeRequests() { return activeRequests; },
    async close() { server.closeAllConnections(); await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve())); }
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const fixture = await startFixtureServer({ port: 18764 });
  console.log(`Source protocol fixtures: ${fixture.baseURL} (loopback only; Ctrl+C to stop)`);
  const stop = async () => { await fixture.close(); process.exitCode = 0; };
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
}
