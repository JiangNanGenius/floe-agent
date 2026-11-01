// SPDX-License-Identifier: MPL-2.0
//
// C04C local viewer entry. The pinned C04A viewer remains the renderer; this
// module installs the native-package fact bridge (including the bounded
// offline B-Rep tessellation adapter) first, then imports the unchanged
// viewer module. It never fetches a CDN or opens an external URL.
import { installFloecadBridge } from './floecad.js';

try {
  await installFloecadBridge();
} catch (_) {
  // The viewer still runs; the Kotlin host validates a generic glb/m ready
  // event against the native package session before accepting it.
}
await import('./viewer.js');
