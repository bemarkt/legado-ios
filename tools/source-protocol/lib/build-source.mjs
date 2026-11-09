import path from 'node:path';
import { createHash } from 'node:crypto';
import MagicString, { Bundle } from 'magic-string';
import remapping from '@jridgewell/remapping';
import { build } from 'esbuild';
import { parse } from 'acorn';
import { inspectSource } from './inspect.mjs';
import { profile } from './contracts.mjs';

const operations = ['search', 'book', 'chapters', 'content'];

// Author-side compiler only. No user plugin/config JS is loaded, and no source module is executed.
export async function buildSource(entry, { sourceMap = false } = {}) {
  const absolute = path.resolve(entry);
  const result = await build({
    absWorkingDir: path.dirname(absolute), entryPoints: [absolute], bundle: true, write: false,
    outfile: path.join(path.dirname(absolute), '__source_bundle__.js'), allowOverwrite: true,
    platform: 'browser', format: 'esm', target: 'es2022', charset: 'utf8',
    minify: false, legalComments: 'inline', treeShaking: false, sourcemap: sourceMap ? 'external' : false,
    sourcesContent: false, metafile: true,
    logLevel: 'silent', tsconfigRaw: {},
    plugins: [{ name: 'self-contained-source', setup(builder) {
      builder.onResolve({ filter: /.*/ }, args => {
        if (args.kind === 'dynamic-import' || /^(https?:|data:|node:|\/\/)/i.test(args.path)) {
          return { errors: [{ text: 'Source builds require static local dependencies; dynamic/remote imports are unsupported' }] };
        }
      });
    } }]
  });
  if (result.outputFiles.length !== (sourceMap ? 2 : 1)) throw new Error('A source must build to one JavaScript file without assets');
  const code = result.outputFiles.find(file => file.path.endsWith('.js'))?.text;
  if (!code) throw new Error('Compiler did not produce JavaScript');
  if (Buffer.byteLength(code) > profile.limits.sourceBytes) throw new Error('Built source exceeds the source byte budget');
  const ast = parse(code, { ecmaVersion: 2022, sourceType: 'module' });
  const pending = [ast];
  while (pending.length) {
    const node = pending.pop();
    if (node.type === 'ImportExpression' || (node.type === 'Identifier' && node.name === 'require')) {
      throw new Error('Built source must not retain runtime module loading');
    }
    for (const value of Object.values(node)) {
      if (Array.isArray(value)) pending.push(...value.filter(child => child && typeof child.type === 'string'));
      else if (value && typeof value.type === 'string') pending.push(value);
    }
  }
  const exports = new Map(), bindings = new Map(), edits = [];
  for (const statement of ast.body) {
    if (statement.type === 'ExportNamedDeclaration') {
      if (statement.declaration || statement.source) throw new Error('Unexpected compiler export form');
      for (const item of statement.specifiers) exports.set(item.exported.name ?? item.exported.value, item.local.name);
      edits.push({ start: statement.start, end: statement.end, text: '' });
    } else if (statement.type === 'VariableDeclaration') {
      for (const binding of statement.declarations) if (binding.id.type === 'Identifier') bindings.set(binding.id.name, binding.init);
    } else if (statement.type === 'FunctionDeclaration') bindings.set(statement.id.name, statement);
    else if (['ImportDeclaration', 'ExportAllDeclaration', 'ExportDefaultDeclaration'].includes(statement.type)) {
      throw new Error('Source build contains an external or unsupported export');
    }
  }
  for (const name of exports.keys()) if (name !== 'metadata' && !operations.includes(name)) throw new Error('Unknown source export: ' + name);
  const metadata = bindings.get(exports.get('metadata'));
  if (!metadata) throw new Error('Source must export literal metadata');
  for (const name of ['book', 'chapters', 'content']) if (!exports.has(name)) throw new Error('Missing source operation: ' + name);
  for (const name of operations.filter(name => exports.has(name))) {
    const binding = bindings.get(exports.get(name));
    if (!binding || !['FunctionDeclaration', 'FunctionExpression', 'ArrowFunctionExpression'].includes(binding.type) || !binding.async || binding.generator) {
      throw new Error('Operation must be an async function: ' + name);
    }
  }
  // esbuild normally changes `export const metadata` into a private var plus an export list.
  // Keep one editable literal at the top, passing that same object into the bundled implementation.
  let argument = '__sourceMetadata';
  while (code.includes(argument)) argument += '_';
  edits.push({ start: metadata.start, end: metadata.end, text: argument });
  const implementation = new MagicString(code);
  for (const edit of edits) implementation.overwrite(edit.start, edit.end, edit.text);
  implementation.trimEnd().indent('  ');
  const names = operations.filter(name => exports.has(name));
  // Retain mappings across metadata extraction, indentation and generated async wrappers.
  // Wrapper text is deliberately unmapped; it must not be attributed to an author's last line.
  const bundle = new Bundle({ separator: '' });
  bundle.append('// Self-contained source. Metadata and all dependencies remain readable.\nexport const metadata = ');
  bundle.addSource({ filename: '__source_bundle__.js', content: new MagicString(code).snip(metadata.start, metadata.end) });
  bundle.append(';\n\nconst __sourceOperations = ((' + argument + ') => {\n');
  bundle.addSource({ filename: '__source_bundle__.js', content: implementation });
  bundle.append('\n  return { ' + names.map(name => name + ': ' + exports.get(name)).join(', ') + ' };\n})(metadata);\n\n');
  bundle.append(names.map(name => 'export async function ' + name + '(ctx, input) {\n  return __sourceOperations.' + name + '(ctx, input);\n}').join('\n\n') + '\n');
  const source = bundle.toString();
  let map;
  if (sourceMap) {
    const compiledMap = JSON.parse(result.outputFiles.find(file => file.path.endsWith('.map')).text);
    const transformedMap = bundle.generateMap({ file: 'source.source.js', hires: true, includeContent: false });
    map = JSON.parse(remapping([transformedMap, compiledMap], () => null, { excludeContent: true }).toString());
    map.x_source_sha256 = createHash('sha256').update(source).digest('hex');
    if (Buffer.byteLength(JSON.stringify(map)) > 8 * 1024 * 1024) throw new Error('Source map exceeds the 8 MiB development budget');
  }
  const inspection = await inspectSource(source);
  if (inspection.unsupportedRequirements.length) throw new Error('Built source requires unsupported capabilities: ' + inspection.unsupportedRequirements.join(', '));
  return { source, inspection, inputs: Object.keys(result.metafile.inputs).sort(), ...(map ? { map } : {}) };
}
