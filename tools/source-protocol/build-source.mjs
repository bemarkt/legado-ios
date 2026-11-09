import path from 'node:path';
import { writeFile, mkdir, rename, unlink, link, lstat } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { buildSource } from './lib/build-source.mjs';
import { sourceMapByteLimit } from './lib/source-location.mjs';

const [entry, output, ...flags] = process.argv.slice(2);
const comparable = value => process.platform === 'win32' ? path.resolve(value).toLowerCase() : path.resolve(value);
try {
  if (!entry || !output || flags.some(flag => !['--replace', '--source-map'].includes(flag))) {
    throw new Error('Usage: node build-source.mjs entry.ts output.source.js [--replace] [--source-map]');
  }
  if (!output.endsWith('.source.js')) throw new Error('Output must end with .source.js');
  if (comparable(entry) === comparable(output)) throw new Error('Output must not replace the source entry');
  const { source, inspection, inputs, map } = await buildSource(entry, { sourceMap: flags.includes('--source-map') });
  const destination = path.resolve(output), entryRoot = path.dirname(path.resolve(entry));
  const outputs = [{ destination, text: source }];
  if (map) {
    map.file = path.basename(destination);
    map.sources = map.sources.map(source => {
      const relative = path.relative(path.dirname(destination), path.resolve(entryRoot, source));
      if (path.isAbsolute(relative)) throw new Error('A development map must stay on the same filesystem volume as its sources');
      return relative.split(path.sep).join('/');
    });
    const text = JSON.stringify(map) + '\n';
    if (Buffer.byteLength(text) > sourceMapByteLimit) throw new Error('Source map exceeds the development byte budget');
    outputs.push({ destination: destination + '.map', text });
  }
  const dependencies = [entry, ...inputs.map(input => path.resolve(entryRoot, input))].map(comparable);
  for (const file of outputs) {
    if (dependencies.includes(comparable(file.destination))) throw new Error('Output must not replace any source dependency');
    if (!flags.includes('--replace')) {
      const exists = await lstat(file.destination).then(() => true, error => { if (error.code === 'ENOENT') return false; throw error; });
      if (exists) throw new Error('Output exists; pass --replace to replace it: ' + file.destination);
    }
  }
  await mkdir(path.dirname(destination), { recursive: true });
  const pending = [];
  try {
    for (const file of outputs) {
      const temporary = file.destination + '.pending-' + randomUUID();
      pending.push(temporary);
      await writeFile(temporary, file.text, { encoding: 'utf8', flag: 'wx' });
    }
    for (const [index, file] of outputs.entries()) {
      if (flags.includes('--replace')) await rename(pending[index], file.destination);
      else await link(pending[index], file.destination);
    }
  } finally {
    for (const temporary of pending) await unlink(temporary).catch(error => { if (error.code !== 'ENOENT') throw error; });
  }
  console.log(JSON.stringify({ output: destination, ...(map ? { sourceMap: destination + '.map', sha256: map.x_source_sha256 } : {}),
    bytes: Buffer.byteLength(source), inputs, ...inspection }, null, 2));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
