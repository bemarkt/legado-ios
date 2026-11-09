import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { builtOfflineFixture } from './lib/built-offline-fixture.mjs';

const fixtureRoot = new URL('../../protocols/source-v1/fixtures/', import.meta.url);
const canonicalURL = new URL('http://127.0.0.1:18764');
const manifest = JSON.parse(await readFile(new URL('manifest.json', fixtureRoot), 'utf8'));
const bodies = new Map(await Promise.all(manifest.resources.map(async route => [route.file, await readFile(new URL(route.file, fixtureRoot), 'utf8')])));
function routeKey(url) { const copy = new URL(url); copy.searchParams.sort(); return copy.pathname + copy.search; }
const routes = new Map(manifest.resources.map(route => [routeKey(new URL(route.route, canonicalURL)), route]));

export async function startFixtureServer({ port = 0 } = {}) {
  const compiledFixture = await builtOfflineFixture();
  const requests = [];
  const rotatingSessions = new Map();
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
    const alternateOrigin = baseURL.replace('127.0.0.1', 'localhost');
    const alternateWebsite = url.pathname.startsWith('/website/') && request.headers.host === new URL(alternateOrigin).host;
    if (request.headers.host !== new URL(baseURL).host && !alternateWebsite) { json(400, { error: 'Unexpected Host' }); return; }
    if (!['GET', 'POST'].includes(request.method)) { json(405, { error: 'Unsupported method' }); return; }
    if (url.pathname === '/website/rotating-login') {
      const session = url.searchParams.get('session');
      if (!session || session.length > 64) { json(400, { error: 'Missing fixture session' }); return; }
      if (rotatingSessions.size >= 100) rotatingSessions.clear();
      rotatingSessions.set(session, 0);
      send(200, '<h1 id="login-ready">Rotating login</h1>', { 'Content-Type': 'text/html',
        'Set-Cookie': ['fixture_rotation=step-0; Path=/; HttpOnly; SameSite=Lax', 'obsolete=old; Path=/'] }); return;
    }
    if (url.pathname === '/website/rotating/catalog' || url.pathname === '/website/rotating/chapter') {
      const session = url.searchParams.get('session');
      const expected = rotatingSessions.get(session);
      const supplied = /(?:^|;\s*)fixture_rotation=step-(\d+)(?:;|$)/.exec(request.headers.cookie ?? '')?.[1];
      if (expected === undefined || supplied !== String(expected)) {
        send(202, '<html><body>Fixture verification required</body></html>', { 'Content-Type': 'text/html' }); return;
      }
      rotatingSessions.set(session, expected + 1);
      const body = url.pathname.endsWith('/catalog')
        ? `<ul><li class="chapter"><a href="/website/rotating/chapter?session=${encodeURIComponent(session)}">Rotating chapter</a></li></ul>`
        : '<article><p>Rotating session chapter.</p></article>';
      send(200, body, { 'Content-Type': 'text/html', 'Set-Cookie': [
        `fixture_rotation=step-${expected + 1}; Path=/; HttpOnly; SameSite=Lax`, 'obsolete=; Path=/; Max-Age=0'] }); return;
    }
    if (url.pathname === '/website/login') {
      send(200, `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><script src="${alternateOrigin}/website/login-script.js" defer></script></head><body></body></html>`, { 'Content-Type': 'text/html; charset=utf-8' }); return;
    }
    if (url.pathname === '/website/login-script.js') {
      send(200, `document.body.innerHTML='<h1 id="login-ready">Website login</h1><button id="login">Sign in</button>';document.getElementById('login').onclick=async()=>{await fetch('/state/login');document.body.dataset.signedIn='true';};`, { 'Content-Type': 'application/javascript' }); return;
    }
    if (url.pathname === '/website/cross-origin') {
      json(200, { website: true }, { 'Access-Control-Allow-Origin': baseURL }); return;
    }
    if (url.pathname === '/website/catalog') {
      if (!/(?:^|;\s*)fixture_session=fixture-a(?:;|$)/.test(request.headers.cookie ?? '')) {
        send(202, '<html><body><script src="/website/login-script.js"></script></body></html>', { 'Content-Type': 'text/html' }); return;
      }
      send(200, '<ul><li class="chapter"><a href="/website/chapter">First chapter</a></li></ul>', { 'Content-Type': 'text/html' }); return;
    }
    if (url.pathname === '/website/chapter') {
      if (!/(?:^|;\s*)fixture_session=fixture-a(?:;|$)/.test(request.headers.cookie ?? '')) { json(401, { error: 'AUTH_REQUIRED' }); return; }
      send(200, '<article><p>Signed in chapter.</p></article>', { 'Content-Type': 'text/html' }); return;
    }
    if (url.pathname === '/') {
      send(200, `<!doctype html><html><head><title>Fixture login</title><meta name="viewport" content="width=device-width,initial-scale=1"></head><body><h1>Fixture login</h1><button id="login" onclick="fetch('/state/login').then(() => document.getElementById('status').textContent='Saved in browser')">Sign in</button><p id="status">Temporary browser</p></body></html>`, { 'Content-Type': 'text/html; charset=utf-8' });
      return;
    }
    if (url.pathname === '/covers/public.png' || url.pathname === '/covers/private.png') {
      if (url.pathname.includes('private') && !/(?:^|;\s*)fixture_session=fixture-a(?:;|$)/.test(request.headers.cookie ?? '')) { json(401, { error: 'AUTH_REQUIRED' }); return; }
      send(200, Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAEAAAABgCAIAAAAip+O/AAABxklEQVR4nNXCA3YjAABF0becsW12bNdIGptt7Nq2bXeMjc06/j2XI8UG6RwtMUrnWGmtdI6XmaRzotwsnZMVFumcqrRK53SVTTpnqu3SOVvjkM45g1M6540u6VyodUvnoskjnUtmr3QuW3zSuWL1S+eqLSCda/agdK47QtK54QxL56arTjq33PXSue2JSOeONyqdu76YdO7549K5H0hI50EwKZ2HoZR0isJp6Tyqy0jncX1WOk8iOek8jeal8yxWkM7zeIN0XiQapfMy2SSdV6lm6bxOt0jnTaZVOm+zbdJ5l2uXzvt8h3Q+FDql87GhSzqfGrul87mpRzpfmnulU9zSJ52S1n7plLYNSKesfVA65R1D0qnoHJZOZdeIdKq6R6VT3TMmnZrecekY+iakY+yflE7twJR0TIPT0jEPzUjHMjwrHevInHRso/PSsY8tSMcxvigd58SSdFyTy9JxT61IxzO9Kh3vzJp0fLPr0vHPbUgnML8pneDClnRCi9vSCS/tSKdueVc69St70oms7ksnunYgndj6oXTiG1+lk9j8Jp3k1nfppLZ/SCe981M6md1f0snu/ZZObv+PdPIHf6VTOPwn/T/zbe3/96qaXAAAAABJRU5ErkJggg==', 'base64'), { 'Content-Type': 'image/png' }); return;
    }
    if (url.pathname === '/built-offline') { json(200, compiledFixture); return; }
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
