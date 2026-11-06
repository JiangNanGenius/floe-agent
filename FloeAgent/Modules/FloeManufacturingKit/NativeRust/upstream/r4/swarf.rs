// SPDX-License-Identifier: MIT
// Extracted from charlatanshost/OpenMill@0432a8c540d1187dc6cb9383ce1b4f2dd97287f6
// (openmill-core/src/strategies/swarf_5axis.rs), carried under the upstream MIT
// license option (see ../LICENSE-MIT).
//
// Change map (Floe adaptations):
//  * `flank_offset_dir` is a verbatim port (f32 normal in, f64 out).
//  * The radial ruling scan no longer derives its centre/radius from the
//    model AABB: the caller supplies the frame-local scan centre, the wall
//    depth, the angular resolution and the tool radius. The two scan planes
//    are w = 0 (top) and w = depth (bottom) in frame-local coordinates.
//  * Upstream star-convex limitation is preserved and stated: only surfaces
//    visible from the scan centre produce rulings; shadowed regions are
//    missed (never mis-cut) and are counted by the caller into `limits`.
//  * Degenerate rulings (top == bottom), unsupported faces and inward
//    normals follow upstream: skipped via `None`, never NaN.

use nalgebra::{Point3, Unit, Vector3};
use parry3d::query::{Ray, RayCast};
use parry3d::shape::TriMesh;

/// Direction to offset a flank-contact point by the tool radius.
///
/// * `hit_normal` — surface normal reported by the raycast, arbitrary sign.
/// * `outward` — scan-centre -> ray-origin direction; the true outward normal
///   must point back this way (resolves the sign ambiguity).
/// * `ruling` — unit tool-axis / ruling direction.
///
/// Returns `None` when the face is perpendicular to the ruling (floor/roof —
/// no flank contact), where the projection would otherwise normalize a zero
/// vector into NaNs. (Verbatim upstream port.)
pub fn flank_offset_dir(
    hit_normal: &Vector3<f32>,
    outward: &Vector3<f64>,
    ruling: &Vector3<f64>,
) -> Option<Vector3<f64>> {
    let mut n = Vector3::new(
        hit_normal.x as f64,
        hit_normal.y as f64,
        hit_normal.z as f64,
    );
    if n.dot(outward) < 0.0 {
        n = -n; // flip to the outward-facing side
    }
    // Strip the component along the ruling: what remains is the in-plane
    // direction the cutter radius actually spans.
    let perp = n - ruling * n.dot(ruling);
    if perp.norm() < 1e-9 {
        return None;
    }
    Some(perp.normalize())
}

/// One extracted ruling: tool-axis-aligned flank pair at this station.
#[derive(Clone, Copy, Debug)]
pub struct UpRuling {
    /// Offset contact point at w = 0 (top).
    pub top: Point3<f64>,
    /// Offset contact point at w = depth (bottom).
    pub bottom: Point3<f64>,
    /// Unit ruling / tool axis direction (bottom -> top).
    pub axis: Unit<Vector3<f64>>,
}

/// Radial ruling scan (upstream swarf extraction, bounded). `mesh` is in
/// frame-local coordinates (w along -axis as +z of local space is the
/// CALLER's mapping; here we scan in the (u, v) plane with rays along -axis
/// at depths w_top = 0 and w_bottom = depth). Returns the ruling list in
/// angular order plus the number of shadowed/degenerate stations skipped.
pub fn ruling_scan(
    mesh: &TriMesh,
    centre: (f64, f64),
    depth: f64,
    scan_radius: f64,
    tool_radius: f64,
    angular_step_deg: f64,
) -> (Vec<UpRuling>, usize) {
    let mut rulings = Vec::new();
    let mut skipped = 0usize;
    let step = angular_step_deg.max(0.1);
    let stations = (360.0 / step).ceil() as usize;
    for i in 0..stations {
        let angle = (i as f64 * step).to_radians();
        let dir = Vector3::new(angle.cos(), angle.sin(), 0.0);
        // At the exact cap/side edge TriMesh may return a roof normal or
        // miss an edge according to f32 tie-breaking. Query strictly inside
        // the wall interval, then extrapolate the same ruled line to the
        // requested planes. Do not turn missing stations into connecting cuts.
        let inset = (depth*1e-5).max(1e-6).min(depth*0.1);
        let top_hit = raycast_in_plane(mesh, centre, &dir, scan_radius, inset);
        let bot_hit = raycast_in_plane(mesh, centre, &dir, scan_radius, depth-inset);
        let (Some(t), Some(b)) = (top_hit, bot_hit) else {
            skipped += 1;
            continue;
        };
        let slope = (b.0-t.0)/(depth-2.0*inset);
        let top = t.0-slope*inset;
        let bottom = b.0+slope*inset;
        let ruling_vec = top-bottom;
        if ruling_vec.norm() < 1e-9 {
            skipped += 1; // degenerate: top and bottom hits coincide
            continue;
        }
        let u = Unit::new_normalize(ruling_vec);
        let (Some(n_top), Some(n_bot)) = (
            flank_offset_dir(&t.1, &dir, &u),
            flank_offset_dir(&b.1, &dir, &u),
        ) else {
            skipped += 1; // face perpendicular to the ruling — not a wall
            continue;
        };
        rulings.push(UpRuling {
            top: top + n_top * tool_radius,
            bottom: bottom + n_bot * tool_radius,
            axis: u,
        });
    }
    (rulings, skipped)
}

/// Raycast in the (u, v) scan plane at depth `w`, from the scan circle
/// inward. Returns (hit point in frame-local (u, v, w), outward normal f32).
fn raycast_in_plane(
    mesh: &TriMesh,
    centre: (f64, f64),
    dir: &Vector3<f64>,
    scan_radius: f64,
    w: f64,
) -> Option<(Point3<f64>, Vector3<f32>)> {
    // Frame-local ray origin on the scan circle at depth w; the local mesh
    // space maps (u, v, w) -> (x, y, z) with w along +z here (the caller
    // builds the mesh in this local space).
    let origin = Point3::new(
        centre.0 + dir.x * scan_radius,
        centre.1 + dir.y * scan_radius,
        w,
    );
    let inward = Unit::new_normalize(-*dir);
    let ray = Ray::new(
        parry3d::math::Point::new(origin.x as f32, origin.y as f32, origin.z as f32),
        *inward.cast::<f32>(),
    );
    let hit = mesh.cast_local_ray_and_get_normal(&ray, (scan_radius * 2.0) as f32, true)?;
    let p = ray.point_at(hit.time_of_impact);
    let n = hit.normal;
    let n64 = Vector3::new(n.x as f64, n.y as f64, n.z as f64);
    Some((
        Point3::new(p.x as f64, p.y as f64, p.z as f64),
        Vector3::new(n64.x as f32, n64.y as f32, n64.z as f32),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tapered_wall_offsets_along_true_normal() {
        // 30-degree leaning wall, running along +Y; outward is +X.
        let t = 30_f64.to_radians();
        let ruling = Vector3::new(t.sin(), 0.0, t.cos());
        let normal = Vector3::new(t.cos() as f32, 0.0, -t.sin() as f32);
        let outward = Vector3::new(1.0, 0.0, 0.0);
        let d = flank_offset_dir(&normal, &outward, &ruling).unwrap();
        assert!((d.x - t.cos()).abs() < 1e-12);
        assert!((d.z + t.sin()).abs() < 1e-12);
        assert!(d.dot(&ruling).abs() < 1e-12, "offset must be perpendicular");
    }

    #[test]
    fn inward_normal_is_flipped_outward() {
        let ruling = Vector3::new(0.0, 0.0, 1.0);
        let inward = Vector3::new(-1.0f32, 0.0, 0.0);
        let d = flank_offset_dir(&inward, &Vector3::new(1.0, 0.0, 0.0), &ruling).unwrap();
        assert!(d.x > 0.0);
    }

    #[test]
    fn face_perpendicular_to_ruling_is_skipped() {
        let ruling = Vector3::new(0.0, 0.0, 1.0);
        let floor = Vector3::new(0.0f32, 0.0, 1.0);
        assert!(flank_offset_dir(&floor, &Vector3::new(0.0, 0.0, 1.0), &ruling).is_none());
    }

    /// Four-sided pyramid trunk (upstream test model): rulings all around.
    #[test]
    fn ruling_scan_finds_closed_wall() {
        let v = vec![
            parry3d::math::Point::new(-5.0f32, -5.0, 0.0),
            parry3d::math::Point::new(5.0, -5.0, 0.0),
            parry3d::math::Point::new(5.0, 5.0, 0.0),
            parry3d::math::Point::new(-5.0, 5.0, 0.0),
            parry3d::math::Point::new(-5.0, -5.0, 10.0),
            parry3d::math::Point::new(5.0, -5.0, 10.0),
            parry3d::math::Point::new(5.0, 5.0, 10.0),
            parry3d::math::Point::new(-5.0, 5.0, 10.0),
        ];
        let tris = vec![
            [0u32, 1, 5], [0, 5, 4],
            [1, 2, 6], [1, 6, 5],
            [2, 3, 7], [2, 7, 6],
            [3, 0, 4], [3, 4, 7],
        ];
        let mesh = TriMesh::new(v, tris);
        let (rulings, skipped) = ruling_scan(&mesh, (0.0, 0.0), 5.0, 30.0, 3.0, 10.0);
        assert!(!rulings.is_empty());
        // Mesh w increases inward: bottom -> top is -Z before move-basis conversion.
        for r in &rulings {
            assert!(r.axis.z < -0.99);
        }
        assert_eq!(skipped,0,"closed ruled wall must cover every station");
    }
}
