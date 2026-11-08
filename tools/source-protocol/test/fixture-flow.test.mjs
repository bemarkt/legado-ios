import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { startFixtureServer } from '../fixture-server.mjs';
import { validateValue } from '../lib/contracts.mjs';

// Only this fixed, project-authored module is executed. Never expose this import
// as a general untrusted-source runner: Node is not the App execution sandbox.
async function loadTrustedJSONFixture(baseURL) {
  const source = await readFile(new URL('../../../protocols/source-v1/fixtures/json.source.js', import.meta.url), 'utf8');
  return import(`data:text/javascript;base64,${Buffer.from(source.replaceAll('http://127.0.0.1:18764', baseURL)).toString('base64')}`);
}
test('JSON source completes all operations, catalog pagination and fresh-module recovery', async t => {
  const fixture = await startFixtureServer(); t.after(() => fixture.close());
  const source = await loadTrustedJSONFixture(fixture.baseURL);
  const ctx = { http: { fetch }, errors: { http: details => Object.assign(new Error('HTTP'), details) } };
  const search = validateValue('SearchPage', await source.search(ctx, { query: 'demo' }));
  const ref = JSON.parse(JSON.stringify(search.items[0].ref));
  const book = validateValue('BookDetails', await source.book(ctx, { ref }));
  const first = validateValue('ChapterPage', await source.chapters(ctx, { book: ref }));
  const second = validateValue('ChapterPage', await source.chapters(ctx, { book: ref, cursor: first.nextCursor }));
  assert.equal(book.title, 'Fixture Book');
  assert.equal(second.nextCursor, null);
  assert.equal(first.revision, second.revision);
  const chapters = [...first.items, ...second.items];
  assert.deepEqual(chapters.map(item => item.ref.id), ['ch-1', 'ch-2']);
  const content = validateValue('ChapterContent', await source.content(ctx, { book: ref, chapter: chapters[0].ref }));
  assert.equal(content.body.text, 'First paragraph.\n\nSecond paragraph.');
  const saved = JSON.parse(JSON.stringify({ book: ref, chapter: chapters[1].ref }));
  const freshText = (await readFile(new URL('../../../protocols/source-v1/fixtures/json.source.js', import.meta.url), 'utf8')).replaceAll('http://127.0.0.1:18764', fixture.baseURL) + '\n// fresh module instance';
  const fresh = await import(`data:text/javascript;base64,${Buffer.from(freshText).toString('base64')}`);
  assert.equal(validateValue('ChapterContent', await fresh.content(ctx, saved)).body.text, 'Next chapter.');
  assert.deepEqual(fixture.requests.map(item => item.path), [
    '/api/search?q=demo&page=1', '/api/book/fixture-book', '/api/book/fixture-book/chapters?page=1',
    '/api/book/fixture-book/chapters?page=2', '/api/book/fixture-book/content/ch-1', '/api/book/fixture-book/content/ch-2'
  ]);
});
test('HTML fixture has both catalog pages and intentionally hostile markup as data', async t => {
  const fixture = await startFixtureServer(); t.after(() => fixture.close());
  const first = await (await fetch(fixture.baseURL + '/html/book/fixture-book/chapters?page=1')).text();
  const second = await (await fetch(fixture.baseURL + '/html/book/fixture-book/chapters?page=2')).text();
  const content = await (await fetch(fixture.baseURL + '/html/book/fixture-book/chapter/ch-1')).text();
  assert.match(first, /data-chapter-id="ch-1"/); assert.match(second, /data-chapter-id="ch-2"/);
  assert.match(content, /fixture script must not run/);
  // This verifies fixture availability only, not DOM extraction or sanitization.
});
test('failure, state, request-body and catalog-change fixtures are deterministic', async t => {
  const fixture = await startFixtureServer(); t.after(() => fixture.close());
  const request = route => fetch(fixture.baseURL + route);
  assert.equal((await request('/failure/rate-limited')).status, 429);
  assert.equal((await request('/failure/rate-limited')).headers.get('retry-after'), '3');
  assert.equal((await request('/failure/server-error')).status, 503);
  validateValue('SearchPage', await (await request('/failure/empty')).json());
  assert.equal((await request('/state/account')).status, 401);
  assert.match((await request('/state/login')).headers.get('set-cookie'), /fixture_session=fixture-a/);
  for (const account of ['fixture-a', 'fixture-b']) {
    const response = await fetch(fixture.baseURL + '/state/account', { headers: { cookie: 'fixture_session=' + account } });
    assert.deepEqual(await response.json(), { account });
  }
  const echo = await fetch(fixture.baseURL + '/api/echo', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{"q":"demo"}' });
  assert.deepEqual(await echo.json(), { method: 'POST', contentType: 'application/json', body: '{"q":"demo"}' });
  const one = await (await request('/changes/catalog?scenario=revision&page=1')).json();
  const two = await (await request('/changes/catalog?scenario=revision&page=2')).json();
  validateValue('ChapterPage', one); validateValue('ChapterPage', two); assert.notEqual(one.revision, two.revision);
  const reorder = await (await request('/changes/catalog?scenario=reorder')).json();
  assert.deepEqual(reorder.items.map(item => item.ref.id), ['ch-2', 'ch-1']);
  assert.equal((await request('/does-not-exist')).status, 404);
});
test('slow request can be aborted and fixture server remains usable', async t => {
  const fixture = await startFixtureServer(); t.after(() => fixture.close());
  const controller = new AbortController();
  const pending = fetch(fixture.baseURL + '/failure/slow?ms=2000', { signal: controller.signal });
  const timer = setTimeout(() => controller.abort(), 50); t.after(() => clearTimeout(timer));
  await assert.rejects(pending, { name: 'AbortError' });
  assert.equal((await fetch(fixture.baseURL + '/health')).status, 200);
});
