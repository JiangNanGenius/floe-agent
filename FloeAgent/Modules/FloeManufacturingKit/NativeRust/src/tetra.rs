// SPDX-License-Identifier: MIT
// Copyright (c) 2013 Mikola Lysenko (isosurface, pinned 22eba3c8c646a478a79a3871223bab0608fb1c04, MIT).
// Mechanical Rust port of the pinned marching-tetrahedra surface used by the
// component-qualified stage at
// Local/Private/cad106-native-closure-20261031/e38-ac-trunnion-kinematics-20261103/tetra-surface/source/
//   PinnedTetrahedralSurface.cs + PinnedTetraCases.cs
// No case-table edits: the 16-case polygon table below is byte-equivalent to
// the pinned table. The port keeps the pinned strict nonzero nodal domain
// (every nodal value must satisfy |v| > 1e-6; sign-changing source edges must
// have a strictly interior crossing) and the shared grid-edge identity cache.
// Zero-level-set quads fan from vertex 0, exactly as in the pinned host.

/// Polygon table indexed by the 4-bit inside mask (node value < 0).
/// Entries are (tetLocalA, tetLocalB) edge pairs, as in PinnedTetraCases.cs.
/// (edge pairs, edge count) per 4-bit inside mask — byte-equivalent to the
/// pinned PinnedTetraCases.cs table; count 0 marks the empty cases.
#[rustfmt::skip]
const POLYGONS: ([[(u8, u8); 4]; 16], [u8; 16]) = ([
    [(0,0),(0,0),(0,0),(0,0)],                                 // 0
    [(0,1),(0,2),(0,3),(0,0)],                                 // 1
    [(1,0),(1,3),(1,2),(0,0)],                                 // 2
    [(1,2),(0,2),(0,3),(1,3)],                                 // 3
    [(2,0),(2,1),(2,3),(0,0)],                                 // 4
    [(0,1),(1,2),(2,3),(0,3)],                                 // 5
    [(2,3),(0,2),(0,1),(1,3)],                                 // 6
    [(3,0),(3,1),(3,2),(0,0)],                                 // 7
    [(3,0),(3,2),(3,1),(0,0)],                                 // 8
    [(2,3),(1,3),(0,1),(0,2)],                                 // 9
    [(0,1),(0,3),(2,3),(1,2)],                                 // 10
    [(2,0),(2,3),(2,1),(0,0)],                                 // 11
    [(1,2),(1,3),(0,3),(0,2)],                                 // 12
    [(1,0),(1,2),(1,3),(0,0)],                                 // 13
    [(0,1),(0,3),(0,2),(0,0)],                                 // 14
    [(0,0),(0,0),(0,0),(0,0)],                                 // 15
], [0, 3, 3, 4, 3, 4, 4, 3, 3, 4, 4, 3, 4, 3, 3, 0]);

const CUBE: [[usize; 3]; 8] = [
    [0, 0, 0],
    [1, 0, 0],
    [1, 1, 0],
    [0, 1, 0],
    [0, 0, 1],
    [1, 0, 1],
    [1, 1, 1],
    [0, 1, 1],
];

/// Six tetrahedra per cube, as in the pinned implementation.
const TETS: [[usize; 4]; 6] = [[0, 2, 3, 7], [0, 6, 2, 7], [0, 4, 6, 7], [0, 6, 1, 2], [0, 1, 6, 4], [5, 6, 1, 4]];

pub struct TetraMesh {
    pub vertices: Vec<[f64; 3]>,
    pub triangles: Vec<[u32; 3]>,
}

/// Marching-tetrahedra over a regular nodal grid.
///
/// * `dims` — node counts [nx, ny, nz] (>= 2 each).
/// * `low` — world position of node (0,0,0).
/// * `h` — node spacing (mm).
/// * `values` — nodal field, len == nx*ny*nz; every value must be finite and
///   |v| > 1e-6 (the pinned strict nonzero domain; no near-zero fallback).
/// * `max_triangles` — explicit output budget.
pub fn generate(
    dims: [usize; 3],
    low: [f64; 3],
    h: f64,
    values: &[f64],
    max_triangles: u64,
) -> Result<TetraMesh, String> {
    let (nx, ny, nz) = (dims[0], dims[1], dims[2]);
    if nx < 2 || ny < 2 || nz < 2 || values.len() != nx * ny * nz {
        return Err("mesher: nodal grid dimensions mismatch".into());
    }
    if !h.is_finite() || h <= 0.0 || !low.iter().all(|v| v.is_finite()) {
        return Err("mesher: finite positive spacing and finite origin required".into());
    }
    for &v in values {
        if !v.is_finite() || v.abs() <= 1e-6 {
            return Err(
                "mesher: strict nonzero nodal domain required (|value| > 1e-6); no near-zero interpolation fallback"
                    .into(),
            );
        }
    }
    let mut mesh = TetraMesh {
        vertices: Vec::new(),
        triangles: Vec::new(),
    };
    let mut cache: std::collections::HashMap<(usize, usize), u32> = std::collections::HashMap::new();

    let node_id = |x: usize, y: usize, z: usize| (z * ny + y) * nx + x;
    let node_coord = |id: usize| [id % nx, (id / nx) % ny, id / (nx * ny)];

    let interpolate = |a: usize,
                           b: usize,
                           cache: &mut std::collections::HashMap<(usize, usize), u32>,
                           mesh: &mut TetraMesh|
     -> Result<u32, String> {
        let (a, b) = if a > b { (b, a) } else { (a, b) };
        if let Some(&existing) = cache.get(&(a, b)) {
            return Ok(existing);
        }
        let (ga, gb) = (values[a], values[b]);
        let den = ga - gb;
        if !(ga * gb < 0.0) || den.abs() <= 1e-6 {
            return Err("mesher: strict sign-changing source edge required".into());
        }
        let t = ga / den;
        if !(t > 0.0 && t < 1.0) {
            return Err("mesher: edge intersection outside source edge".into());
        }
        let na = node_coord(a);
        let nb = node_coord(b);
        let p = [
            low[0] + h * (na[0] as f64 + t * (nb[0] as f64 - na[0] as f64)),
            low[1] + h * (na[1] as f64 + t * (nb[1] as f64 - na[1] as f64)),
            low[2] + h * (na[2] as f64 + t * (nb[2] as f64 - na[2] as f64)),
        ];
        let id = mesh.vertices.len() as u32;
        mesh.vertices.push(p);
        cache.insert((a, b), id);
        Ok(id)
    };

    for z in 0..nz - 1 {
        for y in 0..ny - 1 {
            for x in 0..nx - 1 {
                let mut nodes = [0usize; 8];
                for k in 0..8 {
                    nodes[k] = node_id(
                        x + CUBE[k][0],
                        y + CUBE[k][1],
                        z + CUBE[k][2],
                    );
                }
                for tet in TETS {
                    let mut mask = 0u8;
                    for (k, &t) in tet.iter().enumerate() {
                        if values[nodes[t]] < 0.0 {
                            mask |= 1 << k;
                        }
                    }
                    let edge_count = POLYGONS.1[mask as usize] as usize;
                    if edge_count == 0 {
                        continue;
                    }
                    let mut face = [0u32; 4];
                    let mut face_len = 0usize;
                    for &(ia, ib) in POLYGONS.0[mask as usize].iter().take(edge_count) {
                        face[face_len] = interpolate(
                            nodes[tet[ia as usize]],
                            nodes[tet[ib as usize]],
                            &mut cache,
                            &mut mesh,
                        )?;
                        face_len += 1;
                    }
                    // Ordered fan policy from the pinned host.
                    for k in 1..face_len - 1 {
                        mesh.triangles.push([face[0], face[k], face[k + 1]]);
                        if mesh.triangles.len() as u64 > max_triangles {
                            return Err(format!(
                                "budget: mesher exceeded maxTriangles budget {max_triangles}"
                            ));
                        }
                    }
                }
            }
        }
    }
    Ok(mesh)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f64::consts::PI;

    /// Nodal sphere field on a small grid; marching tetrahedra of an SDF
    /// approximates the sphere within cell error.
    #[test]
    fn sphere_volume_close_to_exact() {
        let n = 21;
        let h = 0.5;
        let r = 4.0;
        let low = [-5.0; 3];
        let mut values = Vec::with_capacity(n * n * n);
        for z in 0..n {
            for y in 0..n {
                for x in 0..n {
                    let p = [
                        low[0] + x as f64 * h,
                        low[1] + y as f64 * h,
                        low[2] + z as f64 * h,
                    ];
                    let d = (p[0] * p[0] + p[1] * p[1] + p[2] * p[2]).sqrt() - r;
                    values.push(if d < 0.0 { d.max(-1.0) } else { d.min(1.0) });
                }
            }
        }
        // The pinned strict domain forbids near-zero nodes; clamp strictly.
        for v in values.iter_mut() {
            if v.abs() <= 1e-6 {
                *v = if *v < 0.0 { -1.0 } else { 1.0 };
            }
        }
        let mesh = generate([n, n, n], low, h, &values, 1_000_000).unwrap();
        assert!(!mesh.triangles.is_empty());
        // Signed volume of the closed mesh.
        let mut vol = 0.0;
        for t in &mesh.triangles {
            let a = mesh.vertices[t[0] as usize];
            let b = mesh.vertices[t[1] as usize];
            let c = mesh.vertices[t[2] as usize];
            vol += (a[0] * (b[1] * c[2] - b[2] * c[1])
                - a[1] * (b[0] * c[2] - b[2] * c[0])
                + a[2] * (b[0] * c[1] - b[1] * c[0]))
                / 6.0;
        }
        let exact = 4.0 / 3.0 * PI * r * r * r;
        assert!(
            (vol - exact).abs() / exact < 0.05,
            "mesh volume {vol} vs exact {exact}"
        );
    }

    #[test]
    fn strict_nonzero_domain_is_enforced() {
        let n = 4;
        let values = vec![1.0f64; n * n * n];
        let mut v2 = values.clone();
        v2[0] = 1e-9; // near-zero node must be rejected
        assert!(generate([n, n, n], [0.0; 3], 1.0, &v2, 100).is_err());
        assert!(generate([n, n, n], [0.0; 3], 1.0, &values, 100)
            .unwrap()
            .triangles
            .is_empty());
    }
}
