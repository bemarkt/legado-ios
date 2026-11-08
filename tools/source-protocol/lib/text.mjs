// P0 plain-text normalization only. HTML must be normalized in the target DOM
// environment against the shared expectations; this function is not a sanitizer.
export function normalizeText(text) {
  return text.replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n').replaceAll('\u0000', '')
    .split('\n').map(line => line.replace(/[\t \u3000]+$/g, '')).join('\n').replace(/^\n+|\n+$/g, '');
}
