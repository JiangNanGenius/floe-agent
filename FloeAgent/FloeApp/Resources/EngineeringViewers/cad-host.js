// SPDX-License-Identifier: MPL-2.0
// Headless CAD host page. The native `CadWebEngineSession` (agent tools and
// the Drawing Assistant) drives the same disposable Worker as the visible
// editor; no UI is installed and no file/network API is exposed.
//
// Native calls arrive through `window.floeCadHostCall(operation, payload)` via
// `callAsyncJavaScript`. Every operation maps to one typed worker message.

import { createCadEngine } from './cad-editor.js';
import { normalizeEngineRequest } from './cad-request.js';

let engine = null;
const readyPromise = (async () => {
  engine = createCadEngine();
  return true;
})();

function b64decode(input) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const str = String(input).replace(/=+$/, '');
  const output = new Uint8Array((str.length * 3 >> 2));
  let bits = 0, buffer = 0, index = 0;
  for (let i = 0; i < str.length; i += 1) {
    const value = chars.indexOf(str.charAt(i));
    if (value < 0) continue;
    bits = (bits << 6) | value;
    buffer += 6;
    if (buffer >= 8) {
      output[index++] = (bits >> (buffer - 8)) & 255;
      buffer -= 8;
    }
  }
  return output.subarray(0, index);
}

function b64encode(bytes) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const parts = [];
  let chunk = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const b0 = bytes[i], b1 = bytes[i + 1], b2 = bytes[i + 2];
    chunk += chars[b0 >> 2] + chars[((b0 & 3) << 4) | ((b1 || 0) >> 4)];
    chunk += i + 1 < bytes.length ? chars[((b1 & 15) << 2) | ((b2 || 0) >> 6)] : '=';
    chunk += i + 2 < bytes.length ? chars[b2 & 63] : '=';
    if (chunk.length >= 8192) { parts.push(chunk); chunk = ''; }
  }
  if (chunk.length) parts.push(chunk);
  return parts.join('');
}

window.floeCadHostReady = async () => {
  await readyPromise;
  return true;
};

window.floeCadHostCall = async (operation, payload) => {
  await readyPromise;
  switch (operation) {
    case 'open': {
      const result = await engine.call('open', { bytes: b64decode(payload.bytes), format: payload.format });
      return JSON.stringify(result.info);
    }
    case 'edit': {
      // Keep a native JSON string single-encoded; UI objects are stringified once.
      const request = normalizeEngineRequest(payload.edit, 'edit');
      const result = await engine.call('edit', { edit: request });
      return JSON.stringify({ created: result.created ?? [] });
    }
    case 'query': {
      const request = normalizeEngineRequest(payload.request, 'query');
      return JSON.stringify(await engine.call('query', { request }));
    }
    case 'inspect':
      // Native expects a JSON string; the worker returns a parsed object.
      return JSON.stringify(await engine.call('inspect', { offset: payload.offset, limit: payload.limit }));
    case 'undo': {
      await engine.call('undo');
      return JSON.stringify({ ok: true });
    }
    case 'save':
      return b64encode(await engine.call('save'));
    case 'dxf':
      return b64encode(await engine.call('display_dxf'));
    case 'shutdown':
      try { engine.close(); } catch {}
      return 'ok';
    default:
      throw new Error('Unknown CAD host operation ' + operation);
  }
};
