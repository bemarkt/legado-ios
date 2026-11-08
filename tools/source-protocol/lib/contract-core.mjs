import { ContractError } from './errors.mjs';

// Shared semantics; dependencies are supplied by Node or the CSP-safe browser bundle.
export function createContracts(schema, profile, validators) {
const forbiddenKeys = new Set(['__proto__', 'prototype', 'constructor']);
const encoder = new TextEncoder();
const bytes = value => encoder.encode(JSON.stringify(value)).byteLength;

// This accepts data, not live objects supplied by an arbitrary Node plugin.
// Production runtime output must cross a bounded, data-only bridge first.
function assertJSON(value, maximumBytes = profile.limits.outputBytes) {
  const stack = [{ value, depth: 0, path: '$' }];
  const seen = new WeakSet();
  let count = 0;
  while (stack.length) {
    const item = stack.pop();
    if (++count > profile.limits.jsonNodes || item.depth > profile.limits.jsonDepth) {
      throw new ContractError('RESOURCE_LIMIT', 'JSON depth or node budget exceeded', { path: item.path });
    }
    const current = item.value;
    if (typeof current === 'string' && encoder.encode(current).byteLength > maximumBytes) throw new ContractError('RESOURCE_LIMIT', 'JSON string exceeds byte budget', { path: item.path });
    if (current === null || typeof current === 'boolean' || typeof current === 'string') continue;
    if (typeof current === 'number' && Number.isFinite(current) && (!Number.isInteger(current) || Number.isSafeInteger(current))) continue;
    if (typeof current !== 'object') throw new ContractError('INVALID_DATA', 'Expected finite JSON data', { path: item.path });
    if (seen.has(current)) throw new ContractError('INVALID_DATA', 'Repeated or cyclic object reference', { path: item.path });
    seen.add(current);
    const array = Array.isArray(current);
    if (!array && ![Object.prototype, null].includes(Object.getPrototypeOf(current))) {
      throw new ContractError('INVALID_DATA', 'Expected a plain object', { path: item.path });
    }
    const descriptors = Object.getOwnPropertyDescriptors(current);
    const keys = Reflect.ownKeys(descriptors).filter(key => !(array && key === 'length'));
    if (keys.length + count + stack.length > profile.limits.jsonNodes || (array && current.length !== keys.length)) {
      throw new ContractError('INVALID_DATA', 'Oversized, sparse or decorated JSON array/object', { path: item.path });
    }
    for (const key of keys) {
      const descriptor = descriptors[key];
      if (typeof key !== 'string' || forbiddenKeys.has(key) || !('value' in descriptor) || !descriptor.enumerable ||
          (array && !/^(0|[1-9][0-9]*)$/.test(key))) {
        throw new ContractError('INVALID_DATA', 'Unsupported JSON property', { path: item.path });
      }
      stack.push({ value: descriptor.value, depth: item.depth + 1, path: `${item.path}.${key}` });
    }
  }
  if (bytes(value) > maximumBytes) throw new ContractError('RESOURCE_LIMIT', 'JSON byte budget exceeded');
}

function checkURL(value, at, originOnly = false) {
  let url;
  try { url = new URL(value); } catch { throw new ContractError('INVALID_DATA', 'Expected an absolute HTTP(S) URL', { path: at }); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password ||
      value !== value.trim() || (originOnly && value !== url.origin)) {
    throw new ContractError('INVALID_DATA', originOnly ? 'Expected a canonical origin without path, credentials or fragment' : 'Invalid resource URL', { path: at });
  }
}

function checkRef(value, at) {
  if (!value.id.trim()) throw new ContractError('INVALID_DATA', 'Empty identity', { path: `${at}.id` });
  if (value.url) checkURL(value.url, `${at}.url`);
  if ('state' in value && bytes(value.state) > profile.limits.refStateBytes) throw new ContractError('RESOURCE_LIMIT', 'Reference state too large', { path: `${at}.state` });
}

function checkBook(value, at) {
  checkRef(value.ref, `${at}.ref`);
  if (!value.title.trim()) throw new ContractError('INVALID_DATA', 'Empty title', { path: `${at}.title` });
  if (value.cover) checkURL(value.cover.url, `${at}.cover.url`);
}

function validateValue(name, value) {
  assertJSON(value, name === 'Metadata' ? profile.limits.metadataBytes : profile.limits.outputBytes);
  if (!schema.$defs[name]) throw new ContractError('INVALID_SCHEMA', `Unknown contract ${name}`);
  const validate = validators[name];
  if (!validate(value)) {
    throw new ContractError('INVALID_DATA', `Value does not satisfy ${name}`, {
      diagnostics: validate.errors.map(({ instancePath, keyword, message }) => ({ path: instancePath || '/', keyword, message }))
    });
  }
  if (name === 'Metadata') {
    if (!value.name.trim()) throw new ContractError('INVALID_DATA', 'Empty source name', { path: 'name' });
    for (const [i, origin] of value.origins.entries()) checkURL(origin, `origins[${i}]`, true);
    if (value.homepage) checkURL(value.homepage, 'homepage');
    const prerelease = value.version.split('+')[0].split('-').slice(1).join('-');
    if (prerelease.split('.').some(part => /^0[0-9]+$/.test(part))) throw new ContractError('INVALID_DATA', 'Numeric prerelease identifiers cannot have leading zeroes', { path: 'version' });
    for (const [key, setting] of Object.entries(value.settings ?? {})) {
      const at = `settings.${key}`;
      if (setting.type === 'text' && [...setting.default].length > setting.maxLength) throw new ContractError('INVALID_DATA', 'Default exceeds text limit', { path: at });
      if (setting.type === 'number' && !(setting.minimum <= setting.default && setting.default <= setting.maximum)) throw new ContractError('INVALID_DATA', 'Default outside numeric range', { path: at });
      if (setting.type === 'enum') {
        const values = setting.options.map(option => option.value);
        if (new Set(values).size !== values.length || !values.includes(setting.default)) throw new ContractError('INVALID_DATA', 'Enum defaults/options conflict', { path: at });
      }
    }
  }
  if (name === 'SourceRef') checkRef(value, '$');
  if (['BookSummary', 'BookDetails'].includes(name)) checkBook(value, '$');
  if (name === 'Chapter') { checkRef(value.ref, 'ref'); if (!value.title.trim()) throw new ContractError('INVALID_DATA', 'Empty chapter title'); }
  if (['SearchPage', 'ChapterPage'].includes(name)) {
    const ids = new Set();
    for (const [index, item] of value.items.entries()) {
      checkBook(item, `items[${index}]`);
      if (ids.has(item.ref.id)) throw new ContractError('INVALID_DATA', 'Duplicate identity within a page', { path: `items[${index}].ref.id` });
      ids.add(item.ref.id);
    }
  }
  if (['BookInput', 'ChaptersInput', 'ContentInput'].includes(name)) {
    for (const key of ['ref', 'book', 'chapter']) if (key in value) checkRef(value[key], key);
  }
  if (name === 'ChapterContent' && value.body.kind === 'html') checkURL(value.body.baseURL, 'body.baseURL');
  for (const key of ['cursor', 'nextCursor']) {
    if (value !== null && typeof value === 'object' && Object.hasOwn(value, key) && bytes(value[key]) > profile.limits.cursorBytes) throw new ContractError('RESOURCE_LIMIT', 'Cursor too large', { path: key });
  }
  return value;
}

return { schema, profile, validateValue, assertJSON };
}
