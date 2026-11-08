import { readFile, writeFile } from 'node:fs/promises';
import { schema } from './lib/contracts.mjs';
function ts(node) {
  if (node.$ref) return node.$ref.split('/').at(-1);
  if ('const' in node) return JSON.stringify(node.const);
  if (node.enum) return node.enum.map(value => JSON.stringify(value)).join(' | ');
  if (node.oneOf || node.anyOf) return (node.oneOf ?? node.anyOf).map(ts).join(' | ');
  if (node.type === 'object') {
    if (!node.properties) return `{ [key: string]: ${ts(node.additionalProperties)} }`;
    return '{\n' + Object.entries(node.properties).map(([key,value]) => `  ${JSON.stringify(key)}${node.required?.includes(key) ? '' : '?'}: ${ts(value)};`).join('\n') + '\n}';
  }
  if (node.type === 'array') return `Array<${ts(node.items)}>`;
  if (node.type === 'integer' || node.type === 'number') return 'number';
  if (['string', 'boolean', 'null'].includes(node.type)) return node.type;
  throw new Error('Unsupported schema form: update generator explicitly');
}
const output = '// Generated from schema.json; do not edit. Candidate protocol; not an App SDK.\n' +
  '// Types describe shape; runtime semantic and resource validation remains required.\n\n' +
  Object.entries(schema.$defs).map(([name,definition]) => `export type ${name} = ${ts(definition)};`).join('\n\n') + '\n';
const target = new URL('../../protocols/source-v1/types.generated.d.ts', import.meta.url);
if (process.argv.includes('--check')) {
  if (await readFile(target, 'utf8') !== output) throw new Error('Generated types are stale: npm run generate');
  console.log('Generated types match schema.');
} else {
  await writeFile(target, output);
  console.log('Generated types.generated.d.ts');
}
