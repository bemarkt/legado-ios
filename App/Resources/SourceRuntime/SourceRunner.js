/* P1 host bootstrap. Author code runs only in a disposable, network-restricted page. */
const SourceRunner = (() => {
  'use strict';
  const stringify = JSON.stringify.bind(JSON);
  const parse = JSON.parse.bind(JSON);
  const post = window.webkit.messageHandlers.sourceHost.postMessage.bind(window.webkit.messageHandlers.sourceHost);
  const encode = new TextEncoder();
  const decodeBase64 = atob.bind(window);
  const encodeBase64 = btoa.bind(window);
  const Decoder = TextDecoder;
  const Bytes = Uint8Array;
  const controller = new AbortController();
  const failure = (code, message, retryAfterMs) => Object.assign(new Error(message), {
    code, ...(retryAfterMs === undefined ? {} : { retryAfterMs })
  });
  const errorCodes = new Set(['INVALID_INPUT', 'INVALID_RESULT', 'INVALID_DATA', 'NETWORK', 'HTTP',
    'RATE_LIMITED', 'AUTH_REQUIRED', 'PARSE', 'UNSUPPORTED', 'TIMEOUT', 'CANCELLED', 'RESOURCE_LIMIT',
    'PERMISSION_DENIED', 'STORAGE_CONFLICT']);
  const isErrorCode = Set.prototype.has.bind(errorCodes);
  const isInteger = Number.isInteger;
  const validRetry = value => isInteger(value) && value >= 0 && value <= 86400000;
  function errorEnvelope(error) {
    // Exception properties may themselves throw. Reporting an exception must not depend on toString().
    let code = 'SCRIPT_ERROR', message = 'Source operation failed', retryAfterMs;
    try {
      if (isErrorCode(error?.code)) code = error.code;
      const text = typeof error?.message === 'string' ? error.message : typeof error === 'string' ? error : '';
      if (text) message = text.slice(0, 2048);
      if (validRetry(error?.retryAfterMs)) retryAfterMs = error.retryAfterMs;
    } catch { /* Keep a bounded diagnostic even for a hostile exception object. */ }
    return { code, message, ...(retryAfterMs === undefined ? {} : { retryAfterMs }) };
  }
  // CSP remains the resource policy. Disable APIs with side channels CSP does not cover uniformly.
  for (const name of ['fetch', 'XMLHttpRequest', 'WebSocket', 'EventSource', 'Worker', 'SharedWorker',
    'RTCPeerConnection', 'webkitRTCPeerConnection', 'WebTransport', 'open', 'indexedDB', 'caches']) {
    Object.defineProperty(window, name, { value: undefined, writable: false, configurable: false });
  }
  if (navigator.sendBeacon) Object.defineProperty(navigator, 'sendBeacon', { value: () => false, configurable: false });
  const freeze = Object.freeze.bind(Object);
  let used = false;

  function base64(bytes) {
    let text = '';
    for (let index = 0; index < bytes.length; index += 8192) text += String.fromCharCode(...bytes.subarray(index, index + 8192));
    return encodeBase64(text);
  }
  function response(raw) {
    let consumed = false;
    const consume = () => {
      if (consumed) throw failure('INVALID_INPUT', 'Response body already consumed');
      consumed = true;
      const binary = decodeBase64(raw.body);
      return Bytes.from(binary, char => char.charCodeAt(0));
    };
    const text = (bytes, charset) => {
      const normalized = charset.toLowerCase();
      if (!['utf-8', 'utf8', 'utf-16le', 'utf-16be'].includes(normalized)) throw failure('UNSUPPORTED', 'Unverified response charset: ' + charset);
      try { return new Decoder(normalized, { fatal: true }).decode(bytes); }
      catch { throw failure('PARSE', 'Invalid response text encoding'); }
    };
    return freeze({ status: raw.status, ok: raw.status >= 200 && raw.status < 300, url: raw.url,
      headers: freeze(raw.headers), get bodyUsed() { return consumed; },
      async bytes() { return consume(); },
      async text() {
        const bytes = consume();
        const charset = /charset\s*=\s*["']?([^\s;"']+)/i.exec(raw.headers['content-type'] ?? '')?.[1] ?? 'utf-8';
        return text(bytes, charset);
      },
      async json() {
        const value = text(consume(), 'utf-8');
        try { return parse(value); } catch { throw failure('PARSE', 'Invalid JSON response'); }
      }
    });
  }

  async function run(source, operation, inputJSON, session, operationID, configJSON) {
    if (used) throw failure('HOST_ERROR', 'Execution page already used');
    used = true;
    let ended = false;
    let sequence = 0;
    const send = async (method, id, request, state) => {
      if (ended) throw failure('CANCELLED', 'Operation ended');
      const raw = await post(stringify({ session, operation: operationID, method, id, ...(request ? { request } : {}), ...(state ? { state } : {}) }));
      if (ended) throw failure('CANCELLED', 'Operation ended');
      const result = parse(raw);
      if (result?.error) throw failure(result.error.code, result.error.message, result.error.retryAfterMs);
      return result;
    };
    const errors = freeze({
      parse: ({ field, message }) => failure('PARSE', field + ': ' + message),
      authRequired: ({ message = 'Authentication required' } = {}) => failure('AUTH_REQUIRED', message),
      http: ({ status, retryAfterMs }) => {
        if (!isInteger(status) || status < 100 || status > 599 || (retryAfterMs !== undefined && !validRetry(retryAfterMs))) {
          return failure('INVALID_INPUT', 'Invalid HTTP error status or retry delay');
        }
        return failure(status === 401 ? 'AUTH_REQUIRED' : status === 429 ? 'RATE_LIMITED' : 'HTTP',
          'HTTP ' + status, retryAfterMs);
      }
    });
    const storageCall = async (method, key, extra = {}) => {
      if (typeof key !== 'string' || !key || [...key].length > 128 || key.includes('\0')) throw failure('INVALID_INPUT', 'Invalid storage key');
      return send(method, String(++sequence), undefined, { key, ...extra });
    };
    const condition = options => {
      if (options === undefined) return {};
      if (!options || typeof options !== 'object' || Object.keys(options).some(key => key !== 'ifRevision') ||
          !Object.hasOwn(options, 'ifRevision') || (options.ifRevision !== null && typeof options.ifRevision !== 'string')) {
        throw failure('INVALID_INPUT', 'Invalid storage revision condition');
      }
      return { ifRevision: options.ifRevision };
    };
    const storageValue = value => {
      const seen = new Set(); let nodes = 0;
      const visit = (value, depth) => {
        if (++nodes > 100000 || depth > 32) throw failure('RESOURCE_LIMIT', 'Storage JSON structure budget exceeded');
        if (value === null || typeof value === 'boolean' || typeof value === 'string') return;
        if (typeof value === 'number' && Number.isFinite(value) && (!Number.isInteger(value) || Number.isSafeInteger(value))) return;
        if (!value || typeof value !== 'object' || seen.has(value)) throw failure('INVALID_INPUT', 'Storage needs finite, acyclic JSON');
        seen.add(value);
        const array = Array.isArray(value);
        if (!array && ![Object.prototype, null].includes(Object.getPrototypeOf(value))) throw failure('INVALID_INPUT', 'Storage needs plain JSON objects');
        const descriptors = Object.getOwnPropertyDescriptors(value);
        const keys = Reflect.ownKeys(descriptors).filter(key => !(array && key === 'length'));
        if (array && keys.length !== value.length) throw failure('INVALID_INPUT', 'Sparse storage array');
        for (const key of keys) {
          const descriptor = descriptors[key];
          if (typeof key !== 'string' || ['__proto__','prototype','constructor'].includes(key) || !descriptor.enumerable || !Object.hasOwn(descriptor,'value') ||
              (array && !/^(0|[1-9][0-9]*)$/.test(key))) throw failure('INVALID_INPUT', 'Unsupported storage property');
          visit(descriptor.value, depth + 1);
        }
      };
      visit(value, 0);
      const json = stringify(value);
      if (encode.encode(json).length > 65536) throw failure('RESOURCE_LIMIT', 'Storage value byte budget exceeded');
      return parse(json);
    };
    const context = freeze({
      signal: controller.signal,
      config: freeze(parse(configJSON)),
      storage: freeze({
        get: key => storageCall('storageGet', key),
        set: (key, value, options) => storageCall('storageSet', key, { value: storageValue(value), ...condition(options) }),
        remove: async (key, options) => { await storageCall('storageRemove', key, condition(options)); }
      }),
      errors,
      // Prototype logs are deliberately not persisted. No credentials enter this page.
      log: freeze({ debug() {}, info() {}, warn() {}, error() {} }),
      http: freeze({ async fetch(url, init = {}) {
        const id = String(++sequence);
        const signal = init.signal;
        if (controller.signal.aborted || signal?.aborted) throw failure('CANCELLED', 'Request cancelled');
        const abort = () => { send('abortHTTP', id).catch(() => {}); };
        signal?.addEventListener('abort', abort, { once: true });
        try {
          let body;
          if (init.body !== undefined) {
            const bytes = typeof init.body === 'string' ? encode.encode(init.body) : init.body;
            if (!(bytes instanceof Bytes)) throw failure('INVALID_INPUT', 'HTTP body must be text or Uint8Array');
            if (bytes.length > 2097152) throw failure('RESOURCE_LIMIT', 'HTTP request body exceeds 2 MiB');
            body = base64(bytes);
          }
          const raw = await send('http', id, { url, method: init.method ?? 'GET', headers: init.headers ?? {},
            ...(body !== undefined ? { body } : {}), redirect: init.redirect ?? 'follow' });
          if (signal?.aborted) throw failure('CANCELLED', 'Request cancelled');
          return response(raw);
        } finally { signal?.removeEventListener('abort', abort); }
      } })
    });
    let blobURL;
    try {
      // This is the only evaluation of source, after native static inspection and explicit execution.
      blobURL = URL.createObjectURL(new Blob([source], { type: 'text/javascript' }));
      const module = await import(blobURL);
      await send('ready', 'ready');
      const value = await module[operation](context, parse(inputJSON));
      const json = stringify(value);
      if (typeof json !== 'string') throw failure('INVALID_DATA', 'Operation returned no JSON value');
      if (encode.encode(json).length > 8388608) throw failure('RESOURCE_LIMIT', 'Output byte budget exceeded');
      return stringify({ json });
    } catch (error) {
      return stringify({ error: errorEnvelope(error) });
    } finally {
      ended = true;
      controller.abort();
      if (blobURL) URL.revokeObjectURL(blobURL);
    }
  }
  return freeze({ run });
})();
