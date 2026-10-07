// SPDX-License-Identifier: MPL-2.0
// Single place where a typed engine request crosses the Worker boundary.
// Native callers pass a JSON string; UI callers pass an object. The engine's
// wasm binding accepts exactly one JSON string, so this normalizes without
// ever double-encoding (a JSON string passed in stays as-is).

export function normalizeEngineRequest(value, what = 'request') {
  if (typeof value === 'string') {
    if (!value.trim()) throw new Error(`Empty CAD ${what}`);
    JSON.parse(value); // fail fast with a clear error before the wasm call
    return value;
  }
  if (value && typeof value === 'object') {
    return JSON.stringify(value);
  }
  throw new Error(`Invalid CAD ${what}`);
}
