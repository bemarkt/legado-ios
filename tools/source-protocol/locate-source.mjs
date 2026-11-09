import { open } from 'node:fs/promises';
import { locateSource, sourceMapByteLimit } from './lib/source-location.mjs';
import { profile } from './lib/contracts.mjs';

async function readBounded(file, limit) {
  const handle = await open(file, 'r');
  try {
    const data = Buffer.alloc(limit + 1);
    let bytesRead = 0;
    while (bytesRead < data.length) {
      const next = await handle.read(data, bytesRead, data.length - bytesRead, null);
      if (!next.bytesRead) break;
      bytesRead += next.bytesRead;
    }
    if (bytesRead > limit) throw new Error('Input exceeds the byte budget: ' + file);
    return new TextDecoder('utf-8', { fatal: true }).decode(data.subarray(0, bytesRead));
  } finally { await handle.close(); }
}
try {
  const [sourceFile, line, column, mapFile, ...extra] = process.argv.slice(2);
  if (!sourceFile || !/^[1-9]\d*$/.test(line ?? '') || !/^[1-9]\d*$/.test(column ?? '') || extra.length) {
    throw new Error('Usage: node locate-source.mjs source.js line column [source.js.map]');
  }
  const source = await readBounded(sourceFile, profile.limits.sourceBytes);
  const map = mapFile ? JSON.parse(await readBounded(mapFile, sourceMapByteLimit)) : undefined;
  console.log(JSON.stringify(locateSource(source, Number(line), Number(column), map), null, 2));
} catch (error) { console.error(error.message); process.exitCode = 1; }
