// SPDX-License-Identifier: MIT OR Apache-2.0
// R4 CAM part mesh wrapper: world mesh -> frame-local mesh (u, v, w with w
// the depth below the surface along -axis), plus validation and bbox.
use nalgebra::{Point3, Vector3};
use parry3d::shape::TriMesh;

use crate::cam::frame::CamFrame;
use crate::model::CamMeshReq;

pub struct CamPartMesh {
    pub local: TriMesh,
    pub vertex_count: usize,
    pub triangle_count: usize,
    /// Local-space AABB: (min_u, min_v, min_w, max_u, max_v, max_w).
    pub local_bounds: [f64; 6],
}

impl CamPartMesh {
    /// Build a frame-local mesh from the contract world-space mesh.
    pub fn in_frame(req: &CamMeshReq, frame: &CamFrame) -> Result<Self, String> {
        if req.vertices.len() < 3 {
            return Err("cam partMesh: at least 3 vertices required".into());
        }
        if req.triangles.is_empty() {
            return Err("cam partMesh: at least one triangle required".into());
        }
        if req.vertices.len() > u32::MAX as usize {
            return Err("cam partMesh: vertex count exceeds u32 index range".into());
        }
        let mut bounds = [f64::INFINITY, f64::INFINITY, f64::INFINITY,
                          f64::NEG_INFINITY, f64::NEG_INFINITY, f64::NEG_INFINITY];
        let mut verts32 = Vec::with_capacity(req.vertices.len());
        for (i, v) in req.vertices.iter().enumerate() {
            if !v.iter().all(|x| x.is_finite()) {
                return Err(format!("cam partMesh: vertex {i} is not finite"));
            }
            let p = Point3::new(v[0], v[1], v[2]);
            let d = p - frame.origin;
            let u = d.dot(&frame.x);
            let vv = d.dot(&frame.y);
            let w = -d.dot(&frame.axis);
            bounds[0] = bounds[0].min(u);
            bounds[1] = bounds[1].min(vv);
            bounds[2] = bounds[2].min(w);
            bounds[3] = bounds[3].max(u);
            bounds[4] = bounds[4].max(vv);
            bounds[5] = bounds[5].max(w);
            verts32.push(parry3d::math::Point::new(u as f32, vv as f32, w as f32));
        }
        let mut tris = Vec::with_capacity(req.triangles.len());
        for (i, t) in req.triangles.iter().enumerate() {
            if t.iter().any(|&ix| ix as usize >= req.vertices.len()) {
                return Err(format!(
                    "cam partMesh: triangle {i} index out of range ({} vertices)",
                    req.vertices.len()
                ));
            }
            tris.push([t[0], t[1], t[2]]);
        }
        let vertex_count = verts32.len();
        let triangle_count = tris.len();
        let mesh = TriMesh::new(verts32, tris);
        Ok(CamPartMesh {
            local: mesh,
            vertex_count,
            triangle_count,
            local_bounds: bounds,
        })
    }

    pub fn describe_bounds(&self) -> String {
        let b = &self.local_bounds;
        format!(
            "u [{:.3}...{:.3}], v [{:.3}...{:.3}], w [{:.3}...{:.3}]",
            b[0], b[3], b[1], b[4], b[2], b[5]
        )
    }
}

/// Convenience: frame-local ray direction for "down into the part" (-axis in
/// local basis is (0, 0, -1) by construction).
pub fn local_down() -> Vector3<f64> {
    Vector3::new(0.0, 0.0, -1.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::CamFrameReq;

    #[test]
    fn local_mesh_maps_world_to_uvw() {
        let frame = CamFrame::validate(&CamFrameReq {
            origin_mm: [0.0, 0.0, 10.0],
            axis: [0.0, 0.0, 1.0],
            x_direction: [1.0, 0.0, 0.0],
        })
        .unwrap();
        // Triangle in world z = 7 plane (3 mm below the surface origin).
        let req = CamMeshReq {
            vertices: vec![
                [-1.0, -1.0, 7.0],
                [1.0, -1.0, 7.0],
                [0.0, 1.0, 7.0],
            ],
            triangles: vec![[0, 1, 2]],
        };
        let m = CamPartMesh::in_frame(&req, &frame).unwrap();
        assert_eq!(m.vertex_count, 3);
        // w = +3 for all vertices.
        assert!((m.local_bounds[2] - 3.0).abs() < 1e-6);
        assert!((m.local_bounds[5] - 3.0).abs() < 1e-6);
    }

    #[test]
    fn rejects_bad_indices_and_nonfinite() {
        let frame = CamFrame::validate(&CamFrameReq {
            origin_mm: [0.0; 3],
            axis: [0.0, 0.0, 1.0],
            x_direction: [1.0, 0.0, 0.0],
        })
        .unwrap();
        let bad_idx = CamMeshReq {
            vertices: vec![[0.0; 3], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
            triangles: vec![[0, 1, 9]],
        };
        assert!(CamPartMesh::in_frame(&bad_idx, &frame).is_err());
        let nan_v = CamMeshReq {
            vertices: vec![[f64::NAN; 3], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
            triangles: vec![[0, 1, 2]],
        };
        assert!(CamPartMesh::in_frame(&nan_v, &frame).is_err());
    }
}
