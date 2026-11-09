import { createHash } from 'node:crypto';
import { SourceMap } from 'node:module';
import path from 'node:path';

export const sourceMapByteLimit = 8 * 1024 * 1024;
export function locateSource(source, line, column, map) {
  if (typeof source !== 'string' || Buffer.byteLength(source) > 2 * 1024 * 1024) throw new Error('Source exceeds the development byte budget');
  if (map !== undefined && Buffer.byteLength(JSON.stringify(map)) > sourceMapByteLimit) throw new Error('Source map exceeds the development byte budget');
  const lines = source.split(/\r\n|[\n\r\u2028\u2029]/);
  if (!Number.isSafeInteger(line) || !Number.isSafeInteger(column) || line < 1 || line > lines.length || column < 1 || column > lines[line - 1].length + 1) {
    throw new Error('Source location must be an existing 1-based UTF-16 line and column');
  }
  const sha256 = createHash('sha256').update(source).digest('hex');
  const result = { sha256, generated: { line, column }, excerpt: lines.slice(Math.max(0, line - 3), line + 2)
    .map((text, index) => ({ line: Math.max(1, line - 2) + index, text: text.slice(0, 500), selected: Math.max(1, line - 2) + index === line })) };
  if (map === undefined) return result;
  if (!map || map.version !== 3 || typeof map.mappings !== 'string' || !Array.isArray(map.sources) || !Array.isArray(map.names)
      || map.sections !== undefined || map.sourceRoot || !/^[a-f0-9]{64}$/.test(map.x_source_sha256 ?? '')
      || map.sources.some(source => typeof source !== 'string' || !source || /[\u0000-\u001f\u007f]/.test(source)
        || path.posix.isAbsolute(source) || path.win32.isAbsolute(source) || /^[a-z][a-z0-9+.-]*:/i.test(source))) {
    throw new Error('Expected a flat local development source map with a source digest');
  }
  if (map.x_source_sha256 !== sha256) throw new Error('Source map digest mismatch; rebuild it for these exact source bytes');
  const entry = new SourceMap(map).findEntry(line - 1, column - 1);
  // SourceMap uses greatest-lower-bound lookup. Never carry a prior line into generated wrapper text.
  if (entry.generatedLine === line - 1 && typeof entry.originalSource === 'string'
      && Number.isSafeInteger(entry.originalLine) && entry.originalLine >= 0
      && Number.isSafeInteger(entry.originalColumn) && entry.originalColumn >= 0) {
    result.original = { source: entry.originalSource, line: entry.originalLine + 1, column: entry.originalColumn + 1 };
  }
  return result;
}
