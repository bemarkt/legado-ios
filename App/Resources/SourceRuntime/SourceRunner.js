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
  const failure = (code, message) => Object.assign(new Error(message), { code });
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
    const send = async (method, id, request) => {
      if (ended) throw failure('CANCELLED', 'Operation ended');
      const raw = await post(stringify({ session, operation: operationID, method, id, ...(request ? { request } : {}) }));
      if (ended) throw failure('CANCELLED', 'Operation ended');
      const result = parse(raw);
      if (result.error) throw failure(result.error.code, result.error.message);
      return result;
    };
    const errors = freeze({
      parse: ({ field, message }) => failure('PARSE', field + ': ' + message),
      authRequired: ({ message = 'Authentication required' } = {}) => failure('AUTH_REQUIRED', message),
      http: ({ status }) => failure(status === 401 || status === 403 ? 'AUTH_REQUIRED' : status === 429 ? 'RATE_LIMITED' : 'HTTP', 'HTTP ' + status)
    });
    const unsupported = async () => { throw failure('UNSUPPORTED', 'Persistent source storage is not implemented in the P1 prototype'); };
    const context = freeze({
      signal: controller.signal,
      config: freeze(parse(configJSON)),
      storage: freeze({ get: unsupported, set: unsupported, remove: unsupported }),
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
      return stringify({ error: { code: typeof error?.code === 'string' ? error.code.slice(0, 128) : 'SCRIPT_ERROR',
        message: String(error?.message ?? error).slice(0, 2048) } });
    } finally {
      ended = true;
      controller.abort();
      if (blobURL) URL.revokeObjectURL(blobURL);
    }
  }
  return freeze({ run });
})();
