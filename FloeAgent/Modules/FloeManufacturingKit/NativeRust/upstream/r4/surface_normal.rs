// SPDX-License-Identifier: MIT
// Extracted from charlatanshost/OpenMill@0432a8c540d1187dc6cb9383ce1b4f2dd97287f6
// (openmill-core/src/strategies/surface_normal_5axis.rs, parallel-scan core and
// calculate_tool_pos_with_offset), carried under the upstream MIT license
// option (see ../LICENSE-MIT).
//
// Change map (Floe adaptations):
//  * Lead/tilt angles are NOT carried: the R4 contract Operation has no
//    lead/tilt fields, so the tool axis is exactly the (re-oriented) surface
//    normal. Upstream defaults were lead 5 deg / tilt 0 deg; dropping them is
//    a documented deviation, not a silent reuse.
//  * Coordinates are frame-local MESH space: (u, v, w) where a point maps as
//    world = origin + x*u + y*v - axis*w, so the part lives at w > 0 and
//    "down into the part" is the +w direction (0,0,+1) IN MESH SPACE — while
//    the OUTWARD surface normal has a NEGATIVE w component (Root review
//    2026-11-04 caught the sign flip). Upstream used world XYZ with -Z rays.
//  * `WorkpieceModel`/`Tool` dependencies replaced by a bare Parry3d TriMesh
//    (pinned parry3d 0.17.6, same family upstream declares) plus an
//    `UpToolProfile`.
//  * Raycast misses return `None` and are COUNTED by the caller (limits);
//    upstream silently skipped them. An all-miss pass is the caller's
//    explicit failure.
//
// DIRECTION CONVENTION (mesh space vs move space): a mesh-space direction
// (a, b, c) equals the move-space direction (a, b, -c), because mesh points
// map with -axis*w while move axes map with +axis*c. Callers converting a
// mesh normal into a CamMove.axis MUST negate the w component.

use nalgebra::{Point3, Unit, Vector3};
use parry3d::query::{Ray, RayCast};
use parry3d::shape::TriMesh;

use super::tool_profile::UpToolProfile;

/// Hit result of a mesh-space raycast: contact point in (u, v, w) mesh space
/// and the surface normal re-oriented so dot(normal, axis_hint) >= 0 (the
/// caller passes the mesh-space OUTWARD hint, i.e. negative w side).
pub struct UpHit {
    pub point: Point3<f64>,
    pub normal: Unit<Vector3<f64>>,
}

/// Convert a mesh-space direction into the move-axis convention
/// (negate the w component). See the header convention note.
pub fn mesh_dir_to_move_dir(v: &Vector3<f64>) -> Vector3<f64> {
    Vector3::new(v.x, v.y, -v.z)
}

/// Cast a ray from `origin` along `dir` (both f64, converted to f32 for the
/// pinned Parry3d query). Returns the first hit with its re-oriented normal.
pub fn raycast_mesh(
    mesh: &TriMesh,
    origin: Point3<f64>,
    dir: Unit<Vector3<f64>>,
    max_toi: f64,
    axis_hint: &Unit<Vector3<f64>>,
) -> Option<UpHit> {
    let ray = Ray::new(
        parry3d::math::Point::new(origin.x as f32, origin.y as f32, origin.z as f32),
        *dir.cast::<f32>(),
    );
    let hit = mesh.cast_local_ray_and_get_normal(&ray, max_toi as f32, true)?;
    let p = ray.point_at(hit.time_of_impact);
    let mut n = Vector3::new(hit.normal.x as f64, hit.normal.y as f64, hit.normal.z as f64);
    if n.norm() < 1e-12 {
        return None;
    }
    if n.dot(axis_hint) < 0.0 {
        n = -n;
    }
    Some(UpHit {
        point: Point3::new(p.x as f64, p.y as f64, p.z as f64),
        normal: Unit::new_normalize(n),
    })
}

/// Tool TIP position for a surface contact, in MESH point space (upstream
/// `calculate_tool_pos_with_offset`, tip-convention conversion):
///  * ballNose — the ball centre sits at (radius + skin) along the outward
///    normal, so the tip = contact + normal * skin (upstream stored the ball
///    centre; converting to the tip convention subtracts one radius back).
///  * flatEndMill/drill — the tip is lifted along the normal by `skin`
///    (upstream semantics: no automatic radius offset; recorded as a limit).
/// `normal` MUST be the mesh-space OUTWARD direction (negative w side for a
/// top face).
pub fn tool_tip_for_contact(
    _tool: &UpToolProfile,
    contact: &Point3<f64>,
    normal: &Unit<Vector3<f64>>,
    wall_skin: f64,
) -> Point3<f64> {
    let skin = wall_skin.max(0.0);
    contact + normal.as_ref() * skin
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cam::frame::CamFrame;
    use crate::model::CamFrameReq;

    /// Plane at mesh w = +3 (3 mm below the frame surface), built through the
    /// REAL frame mapping: world z = 7 with origin z = 10 (axis +Z).
    fn framed_mesh() -> (CamFrame, TriMesh) {
        let frame = CamFrame::validate(&CamFrameReq {
            origin_mm: [0.0, 0.0, 10.0],
            axis: [0.0, 0.0, 1.0],
            x_direction: [1.0, 0.0, 0.0],
        })
        .unwrap();
        let world_verts = [
            [-10.0f64, -10.0, 7.0],
            [10.0, -10.0, 7.0],
            [10.0, 10.0, 7.0],
            [-10.0, 10.0, 7.0],
        ];
        let v32: Vec<_> = world_verts
            .iter()
            .map(|w| {
                // world -> mesh (u, v, w): w = -(z - 10) = +3 at z = 7.
                parry3d::math::Point::new(w[0] as f32, w[1] as f32, (10.0 - w[2]) as f32)
            })
            .collect();
        let tris = vec![[0u32, 1, 2], [0, 2, 3]];
        (frame, TriMesh::new(v32, tris))
    }

    #[test]
    fn raycast_hits_surface_and_orients_outward() {
        let (_f, m) = framed_mesh();
        // Into-the-part ray in MESH space is +w.
        let into = Unit::new_normalize(Vector3::new(0.0, 0.0, 1.0));
        let outward = Unit::new_normalize(Vector3::new(0.0, 0.0, -1.0));
        let hit = raycast_mesh(&m, Point3::new(0.0, 0.0, -5.0), into, 100.0, &outward).unwrap();
        assert!((hit.point.z - 3.0).abs() < 1e-6, "hit at w=+3, got {}", hit.point.z);
        // Outward normal has NEGATIVE w in mesh space...
        assert!(hit.normal.z < -0.99, "outward normal must point to -w");
        // ...and converts to +axis in move space.
        let mv = mesh_dir_to_move_dir(&hit.normal);
        assert!(mv.z > 0.99, "move-space tool axis must be +axis (outward)");
    }

    #[test]
    fn raycast_miss_is_none() {
        let (_f, m) = framed_mesh();
        let into = Unit::new_normalize(Vector3::new(0.0, 0.0, 1.0));
        let outward = Unit::new_normalize(Vector3::new(0.0, 0.0, -1.0));
        assert!(raycast_mesh(&m, Point3::new(50.0, 50.0, -5.0), into, 100.0, &outward).is_none());
    }

    #[test]
    fn tip_lifts_along_outward_normal() {
        let tool = UpToolProfile {
            kind: super::super::tool_profile::UpToolKind::BallNose,
            diameter: 6.0,
            flute_length: 20.0,
            tip_angle_degrees: 0.0,
        };
        let c = Point3::new(0.0, 0.0, 3.0);
        let n = Unit::new_normalize(Vector3::new(0.0, 0.0, -1.0)); // outward
        let tip = tool_tip_for_contact(&tool, &c, &n, 0.2);
        // tip w = 3 - 0.2 = 2.8 (0.2 mm above the surface).
        assert!((tip.z - 2.8).abs() < 1e-12);
    }
}
