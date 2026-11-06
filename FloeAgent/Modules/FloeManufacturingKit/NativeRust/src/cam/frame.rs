// SPDX-License-Identifier: MIT OR Apache-2.0
// R4 CAM workpiece frame (r4/CONTRACT.md): origin + axis (surface normal,
// depth along -axis) + xDirection. The second in-plane axis is axis×x.
use nalgebra::{Point3, Vector3};

use crate::model::CamFrameReq;

/// Orthonormal workpiece frame. All three direction vectors are stored
/// normalized; depth w runs along -axis from the surface (w = 0).
#[derive(Clone, Copy, Debug)]
pub struct CamFrame {
    pub origin: Point3<f64>,
    pub x: Vector3<f64>,
    pub y: Vector3<f64>,
    pub axis: Vector3<f64>,
}

impl CamFrame {
    pub fn validate(req: &CamFrameReq) -> Result<Self, String> {
        let o = req.origin_mm;
        let a = req.axis;
        let x = req.x_direction;
        if !o.iter().chain(a.iter()).chain(x.iter()).all(|v| v.is_finite()) {
            return Err("cam frame: originMM/axis/xDirection must be finite".into());
        }
        let av = Vector3::new(a[0], a[1], a[2]);
        let xv = Vector3::new(x[0], x[1], x[2]);
        let a_len = av.norm();
        let x_len = xv.norm();
        if (a_len - 1.0).abs() > 1e-9 || (x_len - 1.0).abs() > 1e-9 {
            return Err("cam frame: axis and xDirection must be unit length (1 +/- 1e-9)".into());
        }
        if av.dot(&xv).abs() > 1e-9 {
            return Err("cam frame: axis and xDirection must be orthogonal (|dot| <= 1e-9)".into());
        }
        let axis = av / a_len;
        let xu = xv / x_len;
        let yv = axis.cross(&xu);
        if yv.norm() < 1e-12 {
            return Err("cam frame: axis and xDirection are collinear".into());
        }
        let y = yv / yv.norm();
        Ok(CamFrame { origin: Point3::new(o[0], o[1], o[2]), x: xu, y, axis })
    }

    /// Local (u, v, w) -> world. w is depth along -axis (w = 0 at surface).
    pub fn local_to_world(&self, u: f64, v: f64, w: f64) -> Point3<f64> {
        self.origin + self.x * u + self.y * v - self.axis * w
    }

    /// Local vector (in the basis {x, y, axis}) -> world vector.
    pub fn local_vector_to_world(&self, a: f64, b: f64, c: f64) -> Vector3<f64> {
        self.x * a + self.y * b + self.axis * c
    }

    pub fn world_vector_to_local(&self, v: &Vector3<f64>) -> Vector3<f64> {
        Vector3::new(v.dot(&self.x), v.dot(&self.y), v.dot(&self.axis))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame_req() -> CamFrameReq {
        CamFrameReq {
            origin_mm: [1.0, 2.0, 3.0],
            axis: [0.0, 0.0, 1.0],
            x_direction: [1.0, 0.0, 0.0],
        }
    }

    #[test]
    fn valid_frame_maps_points() {
        let f = CamFrame::validate(&frame_req()).unwrap();
        let p = f.local_to_world(0.0, 0.0, 0.0);
        assert!((p.x - 1.0).abs() < 1e-12 && (p.y - 2.0).abs() < 1e-12 && (p.z - 3.0).abs() < 1e-12);
        // Depth goes along -axis.
        let p = f.local_to_world(0.0, 0.0, 2.0);
        assert!((p.z - 1.0).abs() < 1e-12);
        // u along xDirection, v along axis×x = +Y.
        let p = f.local_to_world(4.0, 5.0, 0.0);
        assert!((p.x - 5.0).abs() < 1e-12 && (p.y - 7.0).abs() < 1e-12);
    }

    #[test]
    fn rejects_nonunit_nonorthogonal() {
        let mut r = frame_req();
        r.axis = [0.0, 0.0, 2.0];
        assert!(CamFrame::validate(&r).is_err());
        let mut r = frame_req();
        r.x_direction = [0.0, 0.0, 1.0]; // parallel to axis
        assert!(CamFrame::validate(&r).is_err());
        let mut r = frame_req();
        r.origin_mm = [f64::NAN; 3];
        assert!(CamFrame::validate(&r).is_err());
    }

    #[test]
    fn vector_roundtrip() {
        let f = CamFrame::validate(&frame_req()).unwrap();
        let w = f.local_vector_to_world(1.0, 2.0, 3.0);
        let l = f.world_vector_to_local(&w);
        assert!((l.x - 1.0).abs() < 1e-12 && (l.y - 2.0).abs() < 1e-12 && (l.z - 3.0).abs() < 1e-12);
    }
}
