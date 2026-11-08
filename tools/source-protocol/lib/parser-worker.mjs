import { parentPort, workerData } from 'node:worker_threads';
import { parseSource } from './static-parser.mjs';
try { parentPort.postMessage({ ok: true, result: parseSource(workerData.source) }); }
catch (error) { parentPort.postMessage({ ok: false, error: error.toJSON?.() ?? { code: 'PARSER_FAILED', message: 'Parser rejected the input' } }); }
