import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { buildSource } from '../lib/build-source.mjs';
import { locateSource } from '../lib/source-location.mjs';

const execute = promisify(execFile);
const metadata = "export const metadata = {apiVersion:1,id:'org.example.maps',name:'Map fixture',version:'1.0.0',origins:['https://example.org']};";
const operations = "export async function book(ctx,input){return {ref:input.ref,title:metadata.name};}\nexport async function chapters(){return {items:[],nextCursor:null};}\nexport async function content(){return {body:{kind:'text',text:'Text'}};}";
async function project(t) {
  const root = await mkdtemp(path.join(tmpdir(), 'source-maps-'));
  t.after(async () => { assert.equal(path.dirname(path.resolve(root)), path.resolve(tmpdir())); assert.ok(path.basename(root).startsWith('source-maps-')); await rm(root, {recursive:true,force:true}); });
  const entry = path.join(root, 'index.ts');
  await writeFile(entry, "import { helper } from './helper';\n"+metadata+'\n'+operations+'\nexport async function search(ctx,input){return helper(input.query);}');
  await writeFile(path.join(root, 'helper.ts'), "/*! Fixture dependency license */\nexport function helper(value: string) {\n  const message = '😀: ' + value;\n  throw new Error(message);\n}\n");
  return { root, entry };
}
function location(source, text) { const lines=source.split('\n'), index=lines.findIndex(line=>line.includes(text)); assert.notEqual(index,-1); return [index+1,lines[index].indexOf(text)+1]; }

test('optional source maps leave shared JS bytes unchanged and map helper and moved metadata', async t => {
  const {entry}=await project(t), mapped=await buildSource(entry,{sourceMap:true}), plain=await buildSource(entry);
  assert.equal(mapped.source,plain.source);
  assert.equal(mapped.map.sourcesContent,undefined);
  assert.ok(mapped.map.sources.every(source=>!path.isAbsolute(source)));
  assert.doesNotMatch(JSON.stringify(mapped.map),/source-maps-/);
  let at=location(mapped.source,'new Error(message)');
  assert.deepEqual(locateSource(mapped.source,...at,mapped.map).original,{source:'helper.ts',line:4,column:9});
  at=location(mapped.source,'name: "Map fixture"');
  assert.equal(locateSource(mapped.source,...at,mapped.map).original.source,'index.ts');
  assert.equal(locateSource(mapped.source,...at,mapped.map).original.line,2);
  at=location(mapped.source,'return __sourceOperations.search');
  assert.equal(locateSource(mapped.source,...at,mapped.map).original,undefined);
});
test('location refuses stale maps, unsafe paths and invalid coordinates without reading mapped files', async t => {
  const {entry}=await project(t), built=await buildSource(entry,{sourceMap:true});
  const at=location(built.source,'new Error(message)');
  assert.throws(()=>locateSource(built.source+'\n',...at,built.map),/digest mismatch/);
  for(const source of ['https://example.org/private','file:///private','C:\\private\\source.ts','/private/source.ts','secret\npath']) {
    assert.throws(()=>locateSource(built.source,...at,{...built.map,sources:[source]}),/local development/);
  }
  for(const [line,column] of [[0,1],[1,0],[900000,1],[1,900000],[1.5,1]]) assert.throws(()=>locateSource(built.source,line,column),/UTF-16/);
  assert.equal(locateSource(built.source,...at).sha256,built.map.x_source_sha256);
  assert.equal(locateSource(built.source,...at).original,undefined);
});
test('CLI map output is optional, uses relative paths, and refuses existing files before changing JS', async t => {
  const {root,entry}=await project(t), cli=fileURLToPath(new URL('../build-source.mjs',import.meta.url));
  const output=path.join(root,'dist','out.source.js');
  await execute(process.execPath,[cli,entry,output,'--source-map']);
  const source=await readFile(output,'utf8'), map=JSON.parse(await readFile(output+'.map','utf8'));
  assert.equal(map.file,'out.source.js');
  assert.ok(map.sources.includes('../helper.ts'));
  assert.doesNotMatch(source,/sourceMappingURL/);
  const at=location(source,'new Error(message)');
  const locate=fileURLToPath(new URL('../locate-source.mjs',import.meta.url));
  const result=JSON.parse((await execute(process.execPath,[locate,output,...at.map(String),output+'.map'])).stdout);
  assert.deepEqual(result.original,{source:'../helper.ts',line:4,column:9});
  await rm(output);
  await assert.rejects(execute(process.execPath,[cli,entry,output,'--source-map']), /Output exists/);
  await assert.rejects(readFile(output),error=>error.code==='ENOENT');
  await execute(process.execPath,[cli,entry,output,'--source-map','--replace']);
  assert.equal(await readFile(output,'utf8'),source);
});
