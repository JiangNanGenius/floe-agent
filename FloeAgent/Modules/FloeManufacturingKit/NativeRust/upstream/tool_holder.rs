// SPDX-License-Identifier: MIT
// Extracted subset of charlatanshost/OpenMill@0432a8c540d1187dc6cb9383ce1b4f2dd97287f6
// (openmill-core/src/tool.rs, "── Tool holder ──" section, approx upstream lines
// 296-347), carried under the upstream MIT license option (see LICENSE-MIT
// copied alongside; upstream LICENSE-APACHE also applies upstream-only).
//
// Floe R2 extraction (CONTRACT.md r2/2026-11-04): only the axisymmetric
// silhouette container and the linear `radius_at` interpolation are reused.
// OpenMill's own `holder_collision` path (vertex-only tests with the
// contradictory frame comments) is deliberately NOT reused: it can false-clear
// a holder whose face collides between mesh vertices.
//
// FRAME RECORD (required by the R2 contract): upstream documents `z` as the
// "distance from spindle nose face". The Floe R2 wire contract instead gives
// holderProfile as [distance FROM THE TOOL TIP, radius], with the local +axis
// pointing tip→spindle. The conversion adopted here is therefore: the R2 input
// profile is ALREADY in the tip frame and is stored verbatim; the upstream
// nose-face origin is not introduced and no origin shift is applied. The
// reuse is limited to data layout + clamped linear radius evaluation.
//
// Upstream `radius_at` clamps out-of-range queries to the nearest profile
// point; that behaviour is preserved verbatim.

/// Axisymmetric holder silhouette as a series of (z, r) profile points.
///
/// In the Floe R2 contract frame, each point is `(distance_from_tool_tip_mm,
/// outer_radius_mm)` with the tool axis pointing tip→spindle; points must be
/// sorted by distance (ascending; equal distances may express a shoulder
/// step). Upstream's original nose-frame documentation is kept in the
/// header comment of this file for provenance.
#[derive(Debug, Clone, PartialEq)]
pub struct ToolHolder {
    pub name: String,
    /// `(distance_mm, radius_mm)` pairs defining the outer silhouette.
    /// Must be sorted by distance (ascending).
    pub profile: Vec<(f64, f64)>,
}

impl ToolHolder {
    /// Linear interpolate the holder's outer radius at axial distance `z`.
    /// Out-of-range queries clamp to the nearest profile point (upstream
    /// behaviour, byte-faithful port).
    pub fn radius_at(&self, z: f64) -> f64 {
        if self.profile.is_empty() {
            return 0.0;
        }
        let first = self.profile[0];
        let last = *self.profile.last().unwrap();
        if z <= first.0 {
            return first.1;
        }
        if z >= last.0 {
            return last.1;
        }
        for w in self.profile.windows(2) {
            let (z0, r0) = w[0];
            let (z1, r1) = w[1];
            if z >= z0 && z <= z1 {
                let dz = (z1 - z0).max(1e-9);
                let t = (z - z0) / dz;
                return r0 + t * (r1 - r0);
            }
        }
        last.1
    }
}
