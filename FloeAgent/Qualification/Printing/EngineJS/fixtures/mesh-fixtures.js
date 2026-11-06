/** Copyright (c) 2026 Floe Contributors — MPL-2.0
 * Synthetic authored meshes with exact known dimensions (millimeters).
 * Used as deterministic slicing fixtures; not derived from any external model.
 */
'use strict';

/** Append an axis-aligned box (12 tris) to out (plain number array). */
function pushBox(out, x0, y0, z0, x1, y1, z1) {
    const v = [
        [x0, y0, z0], [x1, y0, z0], [x1, y1, z0], [x0, y1, z0],
        [x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1],
    ];
    const tri = (a, b, c) => out.push(...v[a], ...v[b], ...v[c]);
    // bottom (z0, normal -Z)
    tri(0, 2, 1); tri(0, 3, 2);
    // top (z1, normal +Z)
    tri(4, 5, 6); tri(4, 6, 7);
    // front (y0, -Y)
    tri(0, 1, 5); tri(0, 5, 4);
    // back (y1, +Y)
    tri(3, 7, 6); tri(3, 6, 2);
    // left (x0, -X)
    tri(0, 4, 7); tri(0, 7, 3);
    // right (x1, +X)
    tri(1, 2, 6); tri(1, 6, 5);
}

export const MESH_FIXTURES = Object.freeze({
    'cube20': Object.freeze({
        id: 'cube20',
        description: 'single 20x20x20 mm cube, corner at origin, Z 0..20',
        bounds: { min: [0, 0, 0], max: [20, 20, 20] },
        volumeMM3: 8000,
        build() {
            const out = [];
            pushBox(out, 0, 0, 0, 20, 20, 20);
            return new Float32Array(out);
        },
    }),
    'plate-two-solids': Object.freeze({
        id: 'plate-two-solids',
        description: 'disconnected two-object plate: 12mm cube at origin + 30x15x4mm slab at (25,5,0)',
        bounds: { min: [0, 0, 0], max: [55, 20, 12] },
        volumeMM3: 1728 + 1800,
        solids: 2,
        build() {
            const out = [];
            pushBox(out, 0, 0, 0, 12, 12, 12);
            pushBox(out, 25, 5, 0, 55, 20, 4);
            return new Float32Array(out);
        },
    }),
});

/** Write positions array as binary STL (80-byte header + uint32 count + 50-byte records). */
export function writeBinarySTL(positions, headerText = 'FLOE synthetic fixture') {
    const tris = positions.length / 9;
    const buf = new ArrayBuffer(84 + tris * 50);
    const view = new DataView(buf);
    const header = new Uint8Array(buf, 0, 80);
    for (let i = 0; i < Math.min(80, headerText.length); i++) header[i] = headerText.charCodeAt(i) & 0x7f;
    view.setUint32(80, tris, true);
    for (let t = 0; t < tris; t++) {
        const o = 84 + t * 50;
        // normal = 0 (readers recompute); vertices follow
        for (let k = 0; k < 9; k++) view.setFloat32(o + 12 + k * 4, positions[t * 9 + k], true);
        view.setUint16(o + 48, 0, true);
    }
    return buf;
}
