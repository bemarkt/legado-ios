import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFile } from 'node:fs/promises';
import { parseSource } from '../lib/static-parser.mjs';

const bundle = await readFile(new URL('../../../App/Resources/SourceRuntime/SourceInspector.js', import.meta.url), 'utf8');
const cases = JSON.parse(await readFile(new URL('../../../protocols/source-v1/fixtures/static-cases.json', import.meta.url), 'utf8'));
const context = vm.createContext({ TextEncoder, URL }, { codeGeneration: { strings: false, wasm: false } });
vm.runInContext(bundle, context, { timeout: 2000 });
for (const sample of cases) test(`browser bundle matches Node: ${sample.name}`, () => {
  context.sourceText = sample.source;
  const result = JSON.parse(vm.runInContext('JSON.stringify(SourceInspector.inspect(sourceText))', context, { timeout: 2000 }));
  if (sample.valid) assert.deepEqual(result.value, JSON.parse(JSON.stringify(parseSource(sample.source))));
  else {
    assert.equal(result.error.code, sample.code);
    assert.throws(() => parseSource(sample.source), error => {
      assert.equal(result.error.line, error.line);
      assert.equal(result.error.column, error.column);
      return true;
    });
  }
});
test('browser validator rejects invalid output with dynamic code generation disabled', () => {
  context.resultJSON = '{"items":[{"ref":{"id":"x"},"title":" "}],"nextCursor":null}';
  const result = JSON.parse(vm.runInContext('JSON.stringify(SourceInspector.validate("SearchPage", resultJSON))', context));
  assert.equal(result.error.code, 'INVALID_DATA');
});
