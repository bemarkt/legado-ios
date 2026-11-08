import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { schema } from './lib/contracts.mjs';
const names = ['SourceRef','Cover','BookSummary','BookDetails','Volume','Chapter','SearchPage','ChapterPage','TextBody','HTMLBody','ChapterContent','SearchInput','BookInput','ChaptersInput','ContentInput'];
const reserved = new Set(['description', 'default']);
const field = name => reserved.has(name) ? '`'+name+'`' : name;
function swift(node) {
  if (node.$ref) return node.$ref.endsWith('/Json') ? 'SourceJSON' : node.$ref.split('/').at(-1);
  if (node.oneOf) {
    if (JSON.stringify(node.oneOf) === JSON.stringify(schema.$defs.ChapterContent.properties.body.oneOf)) return 'Body';
    throw Error('Unsupported union');
  }
  if ('const' in node || node.enum) return 'String';
  if(node.type==='string') return 'String';
  if(node.type==='integer') return 'Int';
  if(node.type==='number') return 'Double';
  if(node.type==='boolean') return 'Bool';
  if(node.type==='array') return '['+swift(node.items)+']';
  if(node.type==='object' && !node.properties) return '[String: '+swift(node.additionalProperties)+']';
  throw Error('Unsupported Swift schema mapping: '+JSON.stringify(node));
}
const structures=names.map(name=>{
  const definition=schema.$defs[name];
  const entries=Object.entries(definition.properties);
  const optional=key=>!definition.required.includes(key);
  const fields=entries.map(([key,node])=>'        public let '+field(key)+': '+swift(node)+(optional(key)?'?':'')).join('\n');
  const params=entries.map(([key,node])=>field(key)+': '+swift(node)+(optional(key)?'? = nil':('const' in node?' = '+JSON.stringify(node.const):''))).join(', ');
  const assignments=entries.map(([key])=>'            self.'+field(key)+' = '+field(key)).join('\n');
  const custom = entries.some(([key,node]) => optional(key) && node.$ref?.endsWith('/Json'));
  const decoding = custom ? '\n        private enum CodingKeys: String, CodingKey { case '+entries.map(([key])=>field(key)).join(', ')+' }\n' +
    '        public init(from decoder: Decoder) throws {\n            let container = try decoder.container(keyedBy: CodingKeys.self)\n'+
    entries.map(([key,node])=>'            '+field(key)+' = '+(optional(key) && node.$ref?.endsWith('/Json') ?
      'container.contains(.'+field(key)+') ? try container.decode(SourceJSON.self, forKey: .'+field(key)+') : nil' :
      'try container.'+(optional(key)?'decodeIfPresent':'decode')+'('+swift(node)+'.self, forKey: .'+field(key)+')')).join('\n')+'\n        }' : '';
  return `    public struct ${name}: Codable, Sendable, Equatable {\n${fields}\n        public init(${params}) {\n${assignments}\n        }${decoding}\n    }`;
});
const output='// Generated from protocols/source-v1/schema.json; do not edit.\n// Shape only: source boundary validation remains mandatory.\nimport Foundation\n\npublic enum SourceWire {\n'+structures.join('\n\n')+'\n}\n';
const target=new URL('../../Sources/LegadoCore/SourceDomain/SourceWire.generated.swift',import.meta.url);
if(process.argv.includes('--check')) {
  if(await readFile(target,'utf8')!==output) throw Error('Swift wire types are stale: npm run generate');
  console.log('Swift wire types match schema.');
} else {await writeFile(target,output);console.log('Generated SourceWire.generated.swift');}

const fixtureDirectory = new URL('../../Tests/LegadoCoreTests/Fixtures/SourceProtocol/', import.meta.url);
await mkdir(fixtureDirectory, { recursive: true });
for (const name of ['text-normalization.json', 'html-normalization.expected.json']) {
  const expected = await readFile(new URL('../../protocols/source-v1/fixtures/'+name, import.meta.url), 'utf8');
  const target = new URL(name, fixtureDirectory);
  if (process.argv.includes('--check')) {
    if (await readFile(target,'utf8') !== expected) throw Error('Native fixture copy is stale: '+name);
  } else await writeFile(target, expected);
}
