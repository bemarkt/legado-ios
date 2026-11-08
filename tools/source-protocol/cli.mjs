import { inspectSource, readSource } from './lib/inspect.mjs';
const files = process.argv.slice(2);
if (!files.length) {
  console.error('Usage: npm run validate -- path/to/file.source.js [...]');
  process.exitCode = 2;
}
for (const file of files) {
  try {
    const result = await inspectSource(await readSource(file));
    const supported = result.unsupportedRequirements.length === 0;
    console.log(JSON.stringify({ file, status: supported ? 'static-valid' : 'unsupported-capability', ...result }, null, 2));
    if (!supported) process.exitCode = 1;
  } catch (error) {
    console.error(JSON.stringify({ file, status: 'rejected', error: error.toJSON?.() ?? { code: 'IO_ERROR', message: error.code ?? 'Unable to read source' } }, null, 2));
    process.exitCode = 1;
  }
}
