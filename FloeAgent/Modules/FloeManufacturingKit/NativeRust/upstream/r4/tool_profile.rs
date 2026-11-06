// SPDX-License-Identifier: MIT
// Extracted from charlatanshost/OpenMill@0432a8c540d1187dc6cb9383ce1b4f2dd97287f6
// (openmill-core/src/tool.rs, ToolShape::cutter_radius_at, lines ~121-194),
// carried under the upstream MIT license option (see ../LICENSE-MIT).
//
// Change map (Floe adaptations):
//  * Only the three R4 contract tool kinds are kept: flatEndMill, ballNose,
//    drill. The other eight upstream shapes are NOT extracted (out of scope).
//  * Converted from a ToolShape method to free functions over an explicit
//    `ToolProfile` descriptor; f64 math unchanged.
//  * DEVIATION (contract-required, recorded): the upstream Drill arm of
//    cutter_radius_at is a CONSTANT radius (upstream never models the point);
//    the R4 contract demands the real twist-drill tip shape, so the Drill
//    profile here is `min(r, h * tan(half_angle))` up to the cone height.
//    This is the standard conical point, not an upstream algorithm.
//
// Semantics preserved from upstream: `cutter_radius_at(h)` returns the
// cutting radius at axial height `h` above the tip (h = 0 is the cutting
// tip); heights past the flute clamp to the flute-top radius — the shank
// above is not a cutter.

/// R4 contract tool kinds (r4/CONTRACT.md).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UpToolKind {
    FlatEndMill,
    BallNose,
    Drill,
}

#[derive(Clone, Copy, Debug)]
pub struct UpToolProfile {
    pub kind: UpToolKind,
    /// Nominal diameter [mm].
    pub diameter: f64,
    /// Fluted cutting length [mm].
    pub flute_length: f64,
    /// Included drill point angle [degrees] (Drill only).
    pub tip_angle_degrees: f64,
}

/// Cutter radius [mm] at axial height `h` above the tip
/// (OpenMill ToolShape::cutter_radius_at, f64, subset).
pub fn cutter_radius_at(p: &UpToolProfile, h: f64) -> f64 {
    let h = h.max(0.0);
    let r = p.diameter * 0.5;
    match p.kind {
        UpToolKind::FlatEndMill => r,
        // Floe deviation (see header): real conical drill point.
        UpToolKind::Drill => {
            let tip_h = drill_tip_height(p);
            if h >= tip_h {
                r
            } else {
                (h * (p.tip_angle_degrees * 0.5).to_radians().tan()).min(r)
            }
        }
        UpToolKind::BallNose => {
            if h >= r {
                r
            } else {
                let dh = r - h;
                (r * r - dh * dh).max(0.0).sqrt()
            }
        }
    }
}

/// Axial height of the drill's conical tip [mm]: the height at which the
/// cone reaches the full barrel radius (r / tan(half included angle)).
pub fn drill_tip_height(p: &UpToolProfile) -> f64 {
    debug_assert_eq!(p.kind, UpToolKind::Drill);
    let half = (p.tip_angle_degrees * 0.5).to_radians();
    // tan(half) > 0 enforced by the caller's 10...179 degree validation.
    (p.diameter * 0.5) / half.tan()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn flat() -> UpToolProfile {
        UpToolProfile { kind: UpToolKind::FlatEndMill, diameter: 6.0, flute_length: 20.0, tip_angle_degrees: 0.0 }
    }
    fn ball() -> UpToolProfile {
        UpToolProfile { kind: UpToolKind::BallNose, diameter: 6.0, flute_length: 20.0, tip_angle_degrees: 0.0 }
    }
    fn drill() -> UpToolProfile {
        UpToolProfile { kind: UpToolKind::Drill, diameter: 6.0, flute_length: 20.0, tip_angle_degrees: 118.0 }
    }

    #[test]
    fn flat_radius_is_constant() {
        let p = flat();
        assert!((cutter_radius_at(&p, 0.0) - 3.0).abs() < 1e-12);
        assert!((cutter_radius_at(&p, 20.0) - 3.0).abs() < 1e-12);
    }

    #[test]
    fn ball_radius_is_spherical_then_cylinder() {
        let p = ball();
        assert!(cutter_radius_at(&p, 0.0).abs() < 1e-12);
        assert!((cutter_radius_at(&p, 3.0) - 3.0).abs() < 1e-12);
        assert!((cutter_radius_at(&p, 10.0) - 3.0).abs() < 1e-12);
    }

    #[test]
    fn drill_tip_height_matches_half_angle() {
        let p = drill();
        let h = drill_tip_height(&p);
        // 118 degree included -> half 59 deg; 3 / tan(59 deg).
        let expect = 3.0 / (59.0f64.to_radians().tan());
        assert!((h - expect).abs() < 1e-12);
        // Conical point: zero radius at the apex, barrel radius at cone top.
        assert!(cutter_radius_at(&p, 0.0).abs() < 1e-12);
        assert!((cutter_radius_at(&p, h) - 3.0).abs() < 1e-12);
        assert!((cutter_radius_at(&p, h * 0.5) - 1.5).abs() < 1e-9);
    }
}
