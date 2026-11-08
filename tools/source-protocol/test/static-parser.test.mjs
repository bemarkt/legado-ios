import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { inspectSource, readSource } from '../lib/inspect.mjs';
import { profile } from '../lib/contracts.mjs';

const root = new URL('../../../protocols/source-v1/fixtures/', import.meta.url);
const cases = JSON.parse(await readFile(new URL('static-cases.json', root), 'utf8'));
for (const sample of cases) test(`static: ${sample.name}`, async () => {
  if (sample.valid) {
    const result = await inspectSource(sample.source);
    assert.equal(result.metadata.id, 'org.example.test');
    assert.deepEqual(result.operations, ['book', 'chapters', 'content']);
    assert.deepEqual(result.unsupportedRequirements, sample.unsupported ?? []);
    assert.match(result.sourceSHA256, /^[0-9a-f]{64}$/);
  } else {
    await assert.rejects(inspectSource(sample.source), error => {
      assert.equal(error.code, sample.code);
      assert.ok(error.line > 0);
      return true;
    });
  }
});
for (const file of ['html.source.js', 'json.source.js']) test(`fixture ${file} is statically valid`, async () => {
  const result = await inspectSource(await readFile(new URL(file, root), 'utf8'));
  assert.deepEqual(result.operations, ['search', 'book', 'chapters', 'content']);
});
test('UTF-8 input is bounded; invalid encoding and oversize files are rejected', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'source-protocol-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const file = join(directory, 'input.js');
  await writeFile(file, Buffer.from([0xff, 0xfe]));
  await assert.rejects(readSource(file), { code: 'INVALID_ENCODING' });
  await writeFile(file, 'x'.repeat(profile.limits.sourceBytes + 1));
  await assert.rejects(readSource(file), { code: 'RESOURCE_LIMIT' });
  await assert.rejects(inspectSource('x'.repeat(profile.limits.sourceBytes + 1)), { code: 'RESOURCE_LIMIT' });
});
test('parser deadline rejects and worker is terminated', async () => {
  await assert.rejects(inspectSource(cases[0].source, { timeoutMs: 1 }), { code: 'PARSER_TIMEOUT' });
  assert.equal((await inspectSource(cases[0].source)).metadata.apiVersion, 1);
});
test('AST depth is bounded independently from file size', async () => {
  const deep = `const nested = ${'['.repeat(140)}0${']'.repeat(140)};\n${cases[0].source}`;
  await assert.rejects(inspectSource(deep), { code: 'RESOURCE_LIMIT' });
});

test('runtime fault modules are inspected as data only', async () => {
  for (const file of ['infinite-computation', 'never-settles', 'late-storage-write', 'unawaited-network']) {
    const result = await inspectSource(await readFile(new URL('runtime-faults/' + file + '.source.js', root), 'utf8'));
    assert.equal(result.metadata.apiVersion, 1);
  }
});
