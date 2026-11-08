import { Worker } from 'node:worker_threads';
import { open } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { profile } from './contracts.mjs';
import { ContractError } from './errors.mjs';

export async function readSource(file) {
  const handle = await open(file, 'r');
  try {
    const buffer = Buffer.alloc(profile.limits.sourceBytes + 1);
    let length = 0;
    while (length < buffer.length) {
      const { bytesRead } = await handle.read(buffer, length, buffer.length - length, null);
      if (!bytesRead) break;
      length += bytesRead;
    }
    if (length > profile.limits.sourceBytes) throw new ContractError('RESOURCE_LIMIT', 'Source file too large');
    try { return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(buffer.subarray(0, length)); }
    catch { throw new ContractError('INVALID_ENCODING', 'Source must be UTF-8'); }
  } finally { await handle.close(); }
}

export async function inspectSource(source, { timeoutMs = profile.parser.timeoutMs } = {}) {
  if (typeof source !== 'string') throw new ContractError('INVALID_INPUT', 'Expected source text');
  if (source.length > profile.limits.sourceBytes || Buffer.byteLength(source) > profile.limits.sourceBytes) throw new ContractError('RESOURCE_LIMIT', 'Source file too large');
  const worker = new Worker(new URL('./parser-worker.mjs', import.meta.url), {
    workerData: { source },
    resourceLimits: { maxOldGenerationSizeMb: profile.parser.maxOldGenerationSizeMb,
      maxYoungGenerationSizeMb: profile.parser.maxYoungGenerationSizeMb, stackSizeMb: profile.parser.stackSizeMb }
  });
  let timer;
  try {
    const result = await new Promise((resolve, reject) => {
      timer = setTimeout(() => reject(new ContractError('PARSER_TIMEOUT', 'Static parser exceeded its deadline')), timeoutMs);
      worker.once('message', message => message.ok ? resolve(message.result) : reject(new ContractError(message.error.code, message.error.message, message.error)));
      worker.once('error', error => reject(new ContractError(error.code === 'ERR_WORKER_OUT_OF_MEMORY' ? 'RESOURCE_LIMIT' : 'PARSER_FAILED', 'Static parser worker failed')));
      worker.once('exit', code => reject(new ContractError('PARSER_FAILED', `Static parser exited before returning (code ${code})`)));
    });
    return { ...result, sourceSHA256: createHash('sha256').update(source, 'utf8').digest('hex') };
  } finally {
    clearTimeout(timer);
    await worker.terminate();
  }
}
