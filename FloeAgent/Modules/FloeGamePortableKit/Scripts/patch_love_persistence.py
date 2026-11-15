# SPDX-License-Identifier: MPL-2.0
"""Fixed patch for the exact reviewed npm love.js 11.4.1 loader.

Keep the upstream MIT/NCSA notices. This source patch is shipped under MPL-2.0
alongside the modified, readable JS; it does not modify any WASM or user game.
"""
import hashlib
from pathlib import Path

UPSTREAM = {
    '12db012a5cf4e0661f9eaf154c4c10c3cba7a7db31e6a36856028bbaf5f942f0',
    'eb20a4d947dc99e08e906e946c5b783e3f542f60a3107167a1e92d07bfe531d4',
}
ANCHOR = b'window.addEventListener("beforeunload",function(event){FS.syncfs(false,function(err){if(err){Module["printErr"](err)}})})'
PATCH = b'''
/* Floe persistence addition, SPDX-License-Identifier: MPL-2.0.
 * Upstream generated loader retains its original MIT/NCSA notices.
 * The complete readable addition and patch tool accompany this distribution. */
var floeSaveQueue = Promise.resolve();
Module["floePrepareToStop"] = function () {
  if (typeof Browser !== "undefined" && Browser.mainLoop && Browser.mainLoop.pause) Browser.mainLoop.pause();
  floeSaveQueue = floeSaveQueue.catch(function () {}).then(function () {
    return new Promise(function (resolve, reject) {
      FS.syncfs(false, function (error) { if (error) reject(error); else resolve(true); });
    });
  });
  return floeSaveQueue;
};
'''


def patch_bytes(original: bytes) -> bytes:
    digest = hashlib.sha256(original).hexdigest()
    if digest not in UPSTREAM:
        raise ValueError('Unreviewed love.js bytes; no persistence patch applied: ' + digest)
    if original.count(ANCHOR) != 1:
        raise ValueError('Expected unique original IDBFS shutdown hook')
    return original.replace(ANCHOR, ANCHOR + PATCH)


def patch_file(path: Path) -> dict:
    original = path.read_bytes()
    modified = patch_bytes(original)
    path.write_bytes(modified)
    return {'file': str(path), 'originalSHA256': hashlib.sha256(original).hexdigest(),
            'modifiedSHA256': hashlib.sha256(modified).hexdigest(),
            'patchSourceLicense': 'MPL-2.0', 'upstreamLicenseRetained': 'MIT/NCSA',
            'wasmChanged': False, 'userProjectChanged': False}
