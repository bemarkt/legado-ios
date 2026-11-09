// Locations are advisory diagnostics, never authority to execute or identify a module.
// Keep only a frame belonging to the exact ephemeral author module; never export a raw stack.
const slice = Function.call.bind(String.prototype.slice);
const split = Function.call.bind(String.prototype.split);
const lastIndexOf = Function.call.bind(String.prototype.lastIndexOf);
const charCodeAt = Function.call.bind(String.prototype.charCodeAt);
const exec = Function.call.bind(RegExp.prototype.exec);
const arraySlice = Function.call.bind(Array.prototype.slice);
const includes = Function.call.bind(Array.prototype.includes);
const startsWith = Function.call.bind(String.prototype.startsWith);
const toNumber = Number;
const positionPattern = /^([1-9]\d{0,6}):([1-9]\d{0,6})\)?$/;
export function sourceErrorLocation(error, moduleURL, source) {
  try {
    if (typeof moduleURL !== 'string' || !startsWith(moduleURL, 'blob:') || typeof source !== 'string'
        || source.length > 2097152 || !error) return {};
    const value = error.stack;
    if (typeof value !== 'string') return {};
    const stack = slice(value, 0, 16384);
    for (const frame of arraySlice(split(stack, '\n'), 0, 64)) {
      const index = lastIndexOf(frame, moduleURL + ':');
      if (index < 0 || index > 0 && !includes(['@', '(', ' '], frame[index - 1])) continue;
      const match = exec(positionPattern, slice(frame, index + moduleURL.length + 1));
      if (!match) continue;
      const line = toNumber(match[1]), column = toNumber(match[2]);
      if (line > 2097152 || column > 2097152) return {};
      let current = 1, start = 0;
      for (let i = 0; i < source.length && current < line; i++) {
        const c = charCodeAt(source, i);
        if (c === 13 || c === 10 || c === 0x2028 || c === 0x2029) {
          if (c === 13 && charCodeAt(source, i + 1) === 10) i++;
          current++; start = i + 1;
        }
      }
      if (current !== line) return {};
      let end = start;
      while (end < source.length && !includes([10, 13, 0x2028, 0x2029], charCodeAt(source, end))) end++;
      if (column > end - start + 1) return {};
      return { line, column };
    }
  } catch { /* Hostile error properties cannot prevent the primary error from being reported. */ }
  return {};
}
