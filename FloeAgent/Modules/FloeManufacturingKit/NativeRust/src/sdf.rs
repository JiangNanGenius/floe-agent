// SPDX-License-Identifier: MIT
// Native Rust port of the pinned MIT MillSimSharp finite-cylinder cutter
// geometry subset (charlatanshost/millsimsharp family, fixed commit
// 3cdd4f54ef94e6b95f2a149dad246b4e73aad4e9, see
// Local/Private/cad106-native-closure-20261031/e38-multi-axis-predevelopment-20261103/dependencies/upstream/src/MillSimSharp):
//   * Simulation/FlatEndMillGeometry.cs — SignedDistance (exact capped-cylinder
//     distance, Inigo Quilez formulation), ported from float to f64.
//   * Geometry/SDFGrid.cs — RemoveFiniteCylinder's capped-cylinder distance
//     evaluation (radial + axial half-space composition), ported to f64.
// No .NET runtime is involved; this is a mechanical port of the geometry only.
// Unlike OpenMill's openmill-ui voxel carve shader, removal here NEVER refuses
// to cut material inside a "target" — the cutter may gouge freely.
use nalgebra::{Point3, Vector3};

/// Exact signed distance from `local` (cutter-local frame: tip at origin,
/// body along +Z, i.e. tip→shank) to a flat-ended finite cylinder
/// (MillSimSharp FlatEndMillGeometry.SignedDistance, f64 port).
///
/// Negative inside the cutter, zero on the surface, positive outside.
pub fn flat_end_mill_sdf(local: &Vector3<f64>, radius: f64, length: f64) -> f64 {
    let radial_distance = (local.x * local.x + local.y * local.y).sqrt() - radius;
    let half_length = length * 0.5;
    let axial_distance = (local.z - half_length).abs() - half_length;
    let outside = (radial_distance.max(0.0) * radial_distance.max(0.0)
        + axial_distance.max(0.0) * axial_distance.max(0.0))
    .sqrt();
    radial_distance.max(axial_distance).min(0.0) + outside
}

/// World-frame signed distance to a finite cylinder given by tip point and
/// unit axis (tip→shank). Mirrors MillSimSharp SDFGrid.RemoveFiniteCylinder's
/// per-sample evaluation (f64 port).
pub fn finite_cylinder_sdf_world(
    point: &Point3<f64>,
    tip: &Point3<f64>,
    axis: &Vector3<f64>,
    radius: f64,
    length: f64,
) -> f64 {
    debug_assert!((axis.norm() - 1.0).abs() < 1e-9);
    let to_voxel = point - tip;
    let axial = to_voxel.dot(axis);
    let radial_vec = to_voxel - axis * axial;
    let radial = radial_vec.norm();
    let half_length = length * 0.5;
    let center_axial = axial - half_length;
    let radial_distance = radial - radius;
    let axial_distance = center_axial.abs() - half_length;
    let outside = (radial_distance.max(0.0) * radial_distance.max(0.0)
        + axial_distance.max(0.0) * axial_distance.max(0.0))
    .sqrt();
    radial_distance.max(axial_distance).min(0.0) + outside
}

/// Point-in-cutter test used for voxel removal: strictly inside the cutting
/// solid. Points exactly on the surface are kept (closed-solid convention:
/// removal is for SDF < 0).
pub fn point_inside_cutter(
    point: &Point3<f64>,
    tip: &Point3<f64>,
    axis: &Vector3<f64>,
    radius: f64,
    length: f64,
) -> bool {
    finite_cylinder_sdf_world(point, tip, axis, radius, length) < 0.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use approx::assert_abs_diff_eq;

    #[test]
    fn matches_quilez_reference_cases() {
        // On the side wall midpoint.
        let d = flat_end_mill_sdf(&Vector3::new(2.0, 0.0, 5.0), 2.0, 10.0);
        assert_abs_diff_eq!(d, 0.0, epsilon = 1e-12);
        // Inside.
        assert!(flat_end_mill_sdf(&Vector3::new(1.0, 0.0, 5.0), 2.0, 10.0) < 0.0);
        // Outside beyond end cap.
        let d = flat_end_mill_sdf(&Vector3::new(0.0, 0.0, 12.0), 2.0, 10.0);
        assert_abs_diff_eq!(d, 2.0, epsilon = 1e-12);
        // Outside radially.
        let d = flat_end_mill_sdf(&Vector3::new(5.0, 0.0, 5.0), 2.0, 10.0);
        assert_abs_diff_eq!(d, 3.0, epsilon = 1e-12);
        // Tip centre is on the surface (closed solid includes it; SDF == 0).
        assert_abs_diff_eq!(flat_end_mill_sdf(&Vector3::new(0.0, 0.0, 0.0), 2.0, 10.0), 0.0, epsilon = 1e-12);
    }

    #[test]
    fn world_frame_matches_local_frame() {
        let tip = Point3::new(3.0, -2.0, 10.0);
        let axis = Vector3::new(0.0, 1.0, 0.0); // along +Y
        let p = Point3::new(3.0 + 1.5, -2.0 + 4.0, 10.0);
        let d_world = finite_cylinder_sdf_world(&p, &tip, &axis, 2.0, 15.0);
        let d_local = flat_end_mill_sdf(&Vector3::new(1.5, 0.0, 4.0), 2.0, 15.0);
        assert_abs_diff_eq!(d_world, d_local, epsilon = 1e-12);
    }

    #[test]
    fn oriented_cylinder_gouges_freely_no_target_protection() {
        // Regression guard for the forbidden OpenMill carve-shader behavior:
        // any material point inside the cutter is removable regardless of
        // where it is (no target-inside skip).
        let tip = Point3::new(0.0, 0.0, 0.0);
        let axis = Vector3::z();
        assert!(point_inside_cutter(
            &Point3::new(0.0, 0.0, 0.5), // deep inside where "target" stock would be
            &tip,
            &axis,
            2.0,
            10.0
        ));
    }
}
