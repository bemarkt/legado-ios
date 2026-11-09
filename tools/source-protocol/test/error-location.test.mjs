import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { sourceErrorLocation } from '../lib/error-location.mjs';

const url = 'blob:null/synthetic-operation';
const source = 'first\r\nemoji 😀 throws here\nlast';
test('runtime locations keep only the exact author frame and use UTF-16 columns', () => {
  assert.deepEqual(sourceErrorLocation({ stack: 'failure@host:77:2\nhelper@' + url + ':2:10\nsearch@' + url + ':3:1' }, url, source), { line: 2, column: 10 });
  assert.deepEqual(sourceErrorLocation({ stack: 'Error\n    at helper (' + url + ':2:10)' }, url, source), { line: 2, column: 10 });
  assert.deepEqual(sourceErrorLocation({ stack: 'global code@' + url + ':1:1' }, url, source), { line: 1, column: 1 });
});
test('runtime location rejects foreign, malformed, oversized and out-of-range frames', () => {
  for (const stack of ['fn@https://secret.example/path:2:10', 'fn@x' + url + ':2:10', 'fn@' + url + ':0:1',
    'fn@' + url + ':9999999:1', 'fn@' + url + ':3:99', 'fn@' + url + ':2:10?secret', 'x'.repeat(17000) + '\nfn@' + url + ':2:10']) {
    assert.deepEqual(sourceErrorLocation({ stack }, url, source), {});
  }
  assert.deepEqual(sourceErrorLocation({ get stack() { throw Error('secret'); } }, url, source), {});
  assert.deepEqual(sourceErrorLocation('text', url, source), {});
  assert.deepEqual(sourceErrorLocation(null, url, source), {});
});
test('source line endings and generated runner share the same location helper', async () => {
  for (const separator of ['\r', '\n', '\r\n', '\u2028', '\u2029']) {
    assert.deepEqual(sourceErrorLocation({ stack: 'fn@' + url + ':2:2' }, url, 'a' + separator + 'bb'), { line: 2, column: 2 });
  }
  const runner = await readFile(new URL('../browser/runner.mjs', import.meta.url), 'utf8');
  assert.match(runner, /sourceErrorLocation\(error, moduleURL, source\)/);
  assert.match(runner, /errorEnvelope\(error, blobURL, source\)/);
});
