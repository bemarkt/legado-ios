// Only this repository-authored project is executed. No caller supplies a source path or script.
import { fileURLToPath } from 'node:url';
import { buildSource } from './build-source.mjs';
import { validateValue } from './contracts.mjs';
import { locateSource } from './source-location.mjs';
export async function builtOfflineFixture() {
  const entry = fileURLToPath(new URL('../../../docs/examples/source-project/index.ts', import.meta.url));
  const built = await buildSource(entry, { sourceMap: true });
  const module = await import('data:text/javascript;base64,' + Buffer.from(built.source).toString('base64'));
  const cases = [];
  const execute = async (operation, input, contract) => {
    const output = await module[operation]({}, input);
    validateValue(contract, output);
    cases.push({ operation, input, expected: output });
    return output;
  };
  const search = await execute('search', { query: 'fixture' }, 'SearchPage');
  const ref = search.items[0].ref;
  await execute('book', { ref }, 'BookDetails');
  const chapters = await execute('chapters', { book: ref }, 'ChapterPage');
  for (const chapter of chapters.items) await execute('content', { book: ref, chapter: chapter.ref }, 'ChapterContent');
  const lines = built.source.split('\n');
  const line = lines.findIndex(text => text.includes('throw ctx.errors.parse')) + 1;
  const column = lines[line - 1].indexOf('ctx.errors.parse') + 1;
  return { source: built.source, sha256: built.map.x_source_sha256, cases,
    failure: { input: { book: ref, chapter: { id: 'missing' } }, code: 'PARSE', line,
      original: locateSource(built.source, line, column, built.map).original } };
}
