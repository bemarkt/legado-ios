import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { buildSource } from '../lib/build-source.mjs';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const metadata = `export const metadata = {apiVersion:1,id:'org.example.build',name:'Built fixture',version:'1.0.0',origins:['https://example.org']};`;
const operations = `export async function book(ctx, input) {return {ref:input.ref,title:metadata.name};}
export async function chapters() {return {items:[],nextCursor:null};}
export async function content() {return {body:{kind:'text',text:'Text'}};}`;
async function project(t, entry, helper = '') {
  const root = await mkdtemp(path.join(tmpdir(), 'source-builder-'));
  t.after(async () => {
    assert.equal(path.dirname(path.resolve(root)), path.resolve(tmpdir()));
    assert.ok(path.basename(root).startsWith('source-builder-'));
    await rm(root, { recursive: true, force: true });
  });
  await writeFile(path.join(root, 'index.ts'), entry);
  await writeFile(path.join(root, 'helper.ts'), helper);
  return path.join(root, 'index.ts');
}

test('builder produces deterministic readable self-contained TS source and retains licenses', async t => {
  const entry = await project(t, `import { helper } from './helper';\n${metadata}\n${operations}\nexport async function search(ctx, input: {query: string}) {return {items:[{ref:{id:'b'},title:helper(input.query)}],nextCursor:null};}`,
    `/*! Fixture license notice */\nexport function helper(value: string) {return 'Helper: '+value;}`);
  const first = await buildSource(entry), second = await buildSource(entry);
  assert.equal(first.source, second.source);
  assert.equal(first.inspection.metadata.name, 'Built fixture');
  assert.match(first.source, /Fixture license notice/);
  assert.match(first.source, /export const metadata =/);
  assert.doesNotMatch(first.source, /^import /m);
  // Execute only this repository-authored fixture, never arbitrary source input.
  const module = await import('data:text/javascript;base64,' + Buffer.from(first.source).toString('base64'));
  assert.equal((await module.search({}, {query:'book'})).items[0].title, 'Helper: book');
  module.metadata.name = 'Edited metadata';
  assert.equal((await module.book({}, {ref:{id:'b'}})).title, 'Edited metadata');
});

test('builder does not execute source initialization and rejects dynamic metadata', async t => {
  const entry = await project(t, `${metadata}\nthrow new Error('Must not run during build');\n${operations}`);
  assert.equal((await buildSource(entry)).inspection.metadata.id, 'org.example.build');
  await writeFile(entry, `${metadata.replace("name:'Built fixture'", "name:(()=>{throw Error('Must not run')})()")}\n${operations}`);
  await assert.rejects(buildSource(entry), /literal JSON/);
});

test('builder refuses dynamic and remote dependency graphs', async t => {
  const entry = await project(t, `${metadata}\n${operations}\nexport async function search(){return import('./helper');}`);
  await assert.rejects(buildSource(entry), /static local dependencies/);
  await writeFile(entry, `import 'https://example.org/library.js';\n${metadata}\n${operations}`);
  await assert.rejects(buildSource(entry), /static local dependencies/);
});

test('builder rejects sync operations rather than hiding them behind async wrappers', async t => {
  const entry = await project(t, `${metadata}\n${operations.replace('async function book','function book')}`);
  await assert.rejects(buildSource(entry), /async function: book/);
});

test('builder keeps imported metadata names independent from the public metadata literal', async t => {
  const entry = await project(t, `import { helper } from './helper';\n${metadata}\n${operations}\nconsole.log(helper());`,
    `const metadata = 'helper-private'; export function helper() {return metadata;}`);
  const built = await buildSource(entry);
  assert.equal(built.inspection.metadata.name, 'Built fixture');
  assert.equal((built.source.match(/name: "Built fixture"/g) ?? []).length, 1);
});

test('builder CLI never overwrites entry, dependencies or unapproved output', async t => {
  const entry = await project(t, `${metadata}\n${operations}`);
  const cli = fileURLToPath(new URL('../build-source.mjs', import.meta.url));
  const output = path.join(path.dirname(entry), 'out.source.js');
  const execute = promisify(execFile);
  await execute(process.execPath, [cli, entry, output]);
  const original = await readFile(output, 'utf8');
  await assert.rejects(execute(process.execPath, [cli, entry, output]), error => error.code === 1);
  assert.equal(await readFile(output, 'utf8'), original);
  await execute(process.execPath, [cli, entry, output, '--replace']);
  assert.equal(await readFile(output, 'utf8'), original);
  await writeFile(entry, `import './out.source.js';\n${metadata}\n${operations}`);
  await assert.rejects(execute(process.execPath, [cli, entry, output, '--replace']), /source dependency/);
  assert.equal(await readFile(output, 'utf8'), original);
});
