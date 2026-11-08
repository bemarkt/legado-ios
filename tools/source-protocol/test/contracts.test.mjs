import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { validateValue, assertJSON, profile } from '../lib/contracts.mjs';
import { normalizeText } from '../lib/text.mjs';
const root = new URL('../../../protocols/source-v1/fixtures/', import.meta.url);
const mappings = { 'json-search-page-1.json': 'SearchPage', 'json-book.json': 'BookDetails',
  'json-chapters-page-1.json': 'ChapterPage', 'json-chapters-page-2.json': 'ChapterPage',
  'json-content-ch-1.json': 'ChapterContent', 'json-content-ch-2.json': 'ChapterContent' };
for (const [file, name] of Object.entries(mappings)) test(`contract: ${file}`, async () => {
  validateValue(name, JSON.parse(await readFile(new URL(file, root), 'utf8')));
});
test('empty page with a next cursor remains valid', () => {
  validateValue('ChapterPage', { items: [], nextCursor: { page: 2 } });
});
test('page terminal cursor is required and identities are unique within a page', () => {
  assert.throws(() => validateValue('ChapterPage', { items: [] }), { code: 'INVALID_DATA' });
  const item = { ref: { id: 'chapter' }, title: 'Repeated title' };
  assert.throws(() => validateValue('ChapterPage', { items: [item, structuredClone(item)], nextCursor: null }), { code: 'INVALID_DATA' });
  validateValue('ChapterPage', { items: [item, { ref: { id: 'other' }, title: item.title }], nextCursor: null });
});
test('shape and semantic constraints reject invalid source data', () => {
  for (const value of [{ id: '' }, { id: '   ' }, { id: 'x', url: 'javascript:alert(1)' }, { id: 'x', url: 'https://user:pass@example.org/' }, { id: 'x', unknown: true }]) {
    assert.throws(() => validateValue('SourceRef', value));
  }
  assert.throws(() => validateValue('ChapterContent', { body: { kind: 'html', html: '<p>x</p>' } }));
  assert.throws(() => validateValue('SourceRef', { id: 'x', state: 'a'.repeat(profile.limits.refStateBytes + 1) }), { code: 'RESOURCE_LIMIT' });
});
test('JSON bridge data is finite, acyclic and has no getters or special prototypes', () => {
  const cycle = {}; cycle.self = cycle;
  const getter = Object.defineProperty({}, 'value', { enumerable: true, get() { throw new Error('getter must not execute'); } });
  for (const value of [NaN, Infinity, 1n, undefined, () => {}, cycle, getter, new Date(), [,,], { value: Number.MAX_SAFE_INTEGER + 1 }, JSON.parse('{"__proto__":{}}')]) {
    assert.throws(() => assertJSON(value), { code: 'INVALID_DATA' });
  }
  let value = null; for (let i = 0; i < 34; i++) value = [value];
  assert.throws(() => assertJSON(value), { code: 'RESOURCE_LIMIT' });
});
test('settings defaults must agree with their declared domain', () => {
  const metadata = { apiVersion: 1, id: 'org.example.test', name: 'Test', version: '1.0.0', origins: ['https://example.org'] };
  const invalid = [
    { type: 'number', label: 'n', default: 10, minimum: 0, maximum: 5 },
    { type: 'text', label: 's', default: 'abc', maxLength: 2 },
    { type: 'enum', label: 'e', default: 'missing', options: [{ value: 'a', label: 'A' }] },
    { type: 'enum', label: 'e', default: 'a', options: [{ value: 'a', label: 'A' }, { value: 'a', label: 'B' }] }
  ];
  for (const setting of invalid) assert.throws(() => validateValue('Metadata', { ...metadata, settings: { value: setting } }), { code: 'INVALID_DATA' });
  validateValue('Metadata', { ...metadata, settings: { value: { type: 'boolean', label: 'on', default: false } } });
});
const normalizationCases = JSON.parse(await readFile(new URL('text-normalization.json', root), 'utf8'));
for (const sample of normalizationCases) test(`text normalization: ${sample.name}`, () => {
  assert.equal(normalizeText(sample.input), sample.expected);
});
test('generic JSON definition accepts scalar values without assuming object fields', () => {
  for (const value of [null, true, 1, 'text', []]) validateValue('Json', value);
});
