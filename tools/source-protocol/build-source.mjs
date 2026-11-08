import path from 'node:path';
import { writeFile, mkdir, rename, unlink, link } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { buildSource } from './lib/build-source.mjs';

const [entry, output, ...flags] = process.argv.slice(2);
try {
  if (!entry || !output || flags.some(flag => flag !== '--replace')) throw new Error('Usage: npm run build-source -- entry.ts output.source.js [--replace]');
  if (!output.endsWith('.source.js')) throw new Error('Output must end with .source.js');
  if (path.resolve(entry) === path.resolve(output)) throw new Error('Output must not replace the source entry');
  const { source, inspection, inputs } = await buildSource(entry);
  const destination = path.resolve(output);
  if (inputs.some(input => path.resolve(path.dirname(path.resolve(entry)), input) === destination)) {
    throw new Error('Output must not replace any source dependency');
  }
  await mkdir(path.dirname(destination), { recursive: true });
  const temporary = destination + '.pending-' + randomUUID();
  try {
    await writeFile(temporary, source, { encoding: 'utf8', flag: 'wx' });
    if (flags.includes('--replace')) await rename(temporary, destination);
    else await link(temporary, destination); // Atomically refuse an existing output.
  } finally { await unlink(temporary).catch(error => { if (error.code !== 'ENOENT') throw error; }); }
  console.log(JSON.stringify({ output: destination, bytes: Buffer.byteLength(source), inputs, ...inspection }, null, 2));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
