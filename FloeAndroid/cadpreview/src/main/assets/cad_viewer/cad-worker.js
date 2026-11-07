// SPDX-License-Identifier: MPL-2.0
// Read-only DWG -> DXF projection. The Floe/acadrust engine keeps the native
// DWG document; this worker returns only the bounded display DXF projection.
// It never exposes an editor command or a save path.
import init, { CadSession } from './floe_cad_engine.js';

let session = null;
let initialized = null;

self.onmessage = async ({ data }) => {
  const { id, operation, bytes, format } = data ?? {};
  try {
    initialized ??= init();
    await initialized;
    if (operation !== 'open') throw new Error('Unknown CAD operation');
    if (!(bytes instanceof Uint8Array) || bytes.length === 0) {
      throw new Error('Empty CAD input');
    }
    if (bytes.length > 10 * 1024 * 1024) throw new Error('CAD input exceeds 10 MiB');
    if (format !== 'dwg') throw new Error('Unsupported CAD input');
    session?.free();
    session = new CadSession(bytes, format);
    const dxf = session.display_dxf();
    self.postMessage({ id, dxf }, [dxf.buffer]);
  } catch (error) {
    self.postMessage({ id, error: String(error?.message ?? error) });
  }
};
