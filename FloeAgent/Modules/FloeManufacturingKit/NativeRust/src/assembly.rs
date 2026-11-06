// SPDX-License-Identifier: MIT OR Apache-2.0
// R2 tool-assembly collision core (CONTRACT.md r2/2026-11-04): shank and
// holder of a milling tool assembly checked against static workpiece-frame
// fixture boxes AND against the remaining voxel stock at every current
// material step (never only against the final mesh, so later removal cannot
// erase an earlier contact). Cutter (cutting cylinder) vs fixtures gains the
// clearance semantics when an assembly is present; cutter contact with stock
// remains removal, not collision.
//
// Geometry honesty (contract requirements):
//  * Exact native solids: cutting cylinder, shank cylinder, holder windows
//    with constant radius -> exact Parry intersection/distance queries.
//  * Holder windows with linearly varying radius (taper) are checked with a
//    conservative envelope cylinder (max radius) plus an inscribed cone. A
//    cone hit is a DEFINITE intersection; envelope clearance is DEFINITE
//    clearance; the band in between is UNCERTAIN — never a false clear, never
//    a false exact intersection. `geometryErrorMM` records the maximum radial
//    envelope error (max |r0-r1| over the profile).
//  * Shoulder steps (equal axial distances) need no separate solid: the
//    closed envelopes of the neighbouring windows cover the zero-thickness
//    step disk exactly.
//  * Remaining stock is the exact union of occupied voxel cell cuboids
//    (resolution = stock resolutionMM, recorded in the row message).
//  * Discrete physical poses only (real milling slot poses / real A/C FK
//    poses); continuous sweep between poses is NOT claimed.
//  * Query errors/unsupported -> UNCERTAIN, never clear. Budget exhaustion ->
//    clear task failure, never a silent skip.
use nalgebra::{Isometry3, Point3, Rotation3, Translation3, Unit, UnitQuaternion, Vector3};
use parry3d::query;
use parry3d::shape::{Cone, Cuboid, Cylinder, Shape};

use crate::collision::{CollisionState, CutterCollisionSummary, FixtureBox, QueryBudget};
use crate::model::MillingAssemblyReq;
use crate::stock::Stock;
use crate::upstream_tool_holder::ToolHolder;
use crate::{Fail, Progress};

// Input/resource protection ceilings — aligned with Root's ToolAssembly.swift
// (coordinator guidance 2026-11-04). These are input bounds, not a general
// machine-safety envelope.
const NAME_MAX_BYTES: usize = 512;
const SHANK_DIAMETER_MAX_MM: f64 = 1000.0;
const PROFILE_POINTS_MIN: usize = 2;
const PROFILE_POINTS_MAX: usize = 32;
const PROFILE_AXIAL_MAX_MM: f64 = 1000.0;
const PROFILE_RADIUS_MAX_MM: f64 = 500.0;
const CLEARANCE_MAX_MM: f64 = 100.0;

/// Worst-first aggregation per contract: definite intersection; then
/// unresolved queries; then definite insufficient clearance; clear only when
/// every required query was supported and completed.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
enum Rank {
    Clear = 0,
    Clearance = 1,
    Uncertain = 2,
    Intersecting = 3,
}

/// Per-pose verdict of one tool part against one collision target.
#[derive(Clone, Copy, Debug)]
enum Verdict {
    /// Definite gap >= clearance. `gap_lb` is a conservative lower bound on
    /// the true gap (exact f64 distances have the f32 query error deducted;
    /// stock-window clears are bounded conservatively by the clearance).
    Clear { gap_lb: f64 },
    /// Definite eps < gap < clearance - eps (exact shapes only).
    Clearance { gap_lb: f64 },
    /// Contact possible but unresolved: envelope-only contact, touching /
    /// near-contact inside the float band, a clearance threshold inside the
    /// float band, or a failed/unsupported query. Never a clear; carries no
    /// gap claim (a supported-subset minimum is an upper bound, never a
    /// lower bound).
    Uncertain,
    /// Definite intersection with penetration >= depth_lb (the f32 query
    /// error is deducted). `depth_exact` marks whether the exact depth is
    /// known (cone-definite tapered case is not).
    Intersecting {
        depth_lb: f64,
        depth_exact: bool,
    },
}

impl Verdict {
    fn rank(self) -> Rank {
        match self {
            Verdict::Clear { .. } => Rank::Clear,
            Verdict::Clearance { .. } => Rank::Clearance,
            Verdict::Uncertain => Rank::Uncertain,
            Verdict::Intersecting { .. } => Rank::Intersecting,
        }
    }
}

/// Conservative merge of two equal-rank verdicts (used when one part has
/// several segments, e.g. a holder with multiple profile windows).
fn combine_same_rank(a: Verdict, b: Verdict) -> Verdict {
    match (a, b) {
        (Verdict::Clear { gap_lb: x }, Verdict::Clear { gap_lb: y }) => Verdict::Clear {
            gap_lb: x.min(y),
        },
        (Verdict::Clearance { gap_lb: x }, Verdict::Clearance { gap_lb: y }) => {
            Verdict::Clearance { gap_lb: x.min(y) }
        }
        (Verdict::Uncertain, Verdict::Uncertain) => Verdict::Uncertain,
        (
            Verdict::Intersecting {
                depth_lb: x,
                depth_exact: ex,
            },
            Verdict::Intersecting {
                depth_lb: y,
                depth_exact: ey,
            },
        ) => Verdict::Intersecting {
            depth_lb: x.max(y),
            depth_exact: ex && ey,
        },
        // Unreachable for equal ranks; keep the left verdict deterministically.
        _ => a,
    }
}

fn worst_of(verdicts: impl IntoIterator<Item = Verdict>) -> Option<Verdict> {
    let mut acc: Option<Verdict> = None;
    for v in verdicts {
        acc = Some(match acc {
            None => v,
            Some(a) if v.rank() > a.rank() => v,
            Some(a) => combine_same_rank(a, v),
        });
    }
    acc
}

/// Cross-pose aggregation of one (part, target) pair within one operation.
#[derive(Clone, Debug)]
struct Record {
    verdict: Verdict,
    first_pose: usize,
    gap_lb: Option<f64>,
    max_depth_lb: f64,
    depth_unknown: bool,
    poses_checked: u64,
}

impl Record {
    fn new() -> Self {
        Record {
            verdict: Verdict::Clear {
                gap_lb: f64::INFINITY,
            },
            first_pose: usize::MAX,
            gap_lb: None,
            max_depth_lb: 0.0,
            depth_unknown: false,
            poses_checked: 0,
        }
    }

    fn absorb(&mut self, v: Verdict) {
        match v {
            Verdict::Clear { gap_lb } | Verdict::Clearance { gap_lb } => {
                if gap_lb.is_finite() {
                    self.gap_lb = Some(self.gap_lb.map_or(gap_lb, |g| g.min(gap_lb)));
                }
            }
            // Uncertain carries no gap claim; intersecting rows omit gaps.
            Verdict::Uncertain => {}
            Verdict::Intersecting {
                depth_lb,
                depth_exact,
            } => {
                self.max_depth_lb = self.max_depth_lb.max(depth_lb);
                self.depth_unknown |= !depth_exact;
            }
        }
    }

    fn observe(&mut self, v: Verdict, pose: usize) {
        self.poses_checked += 1;
        let (rn, rc) = (v.rank(), self.verdict.rank());
        if rn > rc {
            self.verdict = v;
            self.first_pose = pose;
            self.gap_lb = None;
            self.max_depth_lb = 0.0;
            self.depth_unknown = false;
        } else if rn == rc {
            // Keep the earliest occurrence of the worst rank.
            self.first_pose = self.first_pose.min(pose);
            self.verdict = combine_same_rank(self.verdict, v);
        }
        // Lower-rank observations never hide the worst state: this is what
        // keeps an early material-step contact visible after later removal.
        self.absorb(v);
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ToolPart {
    Shank,
    Holder,
}

impl ToolPart {
    fn as_str(self) -> &'static str {
        match self {
            ToolPart::Shank => "shank",
            ToolPart::Holder => "holder",
        }
    }
}

#[derive(Clone, PartialEq, Eq, Debug)]
enum TargetKey {
    Fixture(String),
    Stock,
}

/// Holder/shank segment along the tool axis (tip-origin, +axis tip->spindle).
#[derive(Clone, Copy, Debug)]
enum Seg {
    /// Shank or constant-radius holder window: exact cylinder.
    Cyl { z0: f64, z1: f64, r: f64 },
    /// Linear-radius holder window: conservative envelope + inscribed cone.
    Taper { z0: f64, z1: f64, r0: f64, r1: f64 },
}

/// Validated R2 milling tool assembly (see CONTRACT.md r2). Cutting dimensions
/// stay authoritative from milling.toolRadiusMM/toolLengthMM; the A/C gauge
/// length is never mixed into the assembly geometry.
#[derive(Clone,Debug)]
pub struct ToolAssembly {
    pub name: String,
    pub shank_radius_mm: f64,
    pub holder: ToolHolder,
    pub clearance_mm: f64,
    pub cut_length_mm: f64,
    pub tool_radius_mm: f64,
    /// Max radial envelope error over tapered holder windows (mm); also
    /// emitted as `geometryErrorMM` on holder rows.
    pub holder_error_mm: f64,
    shank: Option<Seg>,
    holder_segs: Vec<Seg>,
}

impl ToolAssembly {
    pub fn validate(
        req: &MillingAssemblyReq,
        tool_radius_mm: f64,
        cut_length_mm: f64,
    ) -> Result<ToolAssembly, Fail> {
        if req.format_version != 1 {
            return Err("millingAssembly.formatVersion must be 1".into());
        }
        if req.name.is_empty() {
            return Err("millingAssembly.name must be non-empty".into());
        }
        if req.name.len() > NAME_MAX_BYTES {
            return Err(format!("millingAssembly.name exceeds {NAME_MAX_BYTES} UTF-8 bytes").into());
        }
        if !tool_radius_mm.is_finite() || tool_radius_mm <= 0.0 {
            return Err("millingAssembly: milling.toolRadiusMM must be finite and positive (cutting-dimension authority)".into());
        }
        if !cut_length_mm.is_finite() || cut_length_mm <= 0.0 {
            return Err("millingAssembly: milling.toolLengthMM must be finite and positive (cutting-edge length authority)".into());
        }
        let d = req.shank_diameter_mm;
        if !d.is_finite() || d <= 0.0 || d > SHANK_DIAMETER_MAX_MM {
            return Err(format!(
                "millingAssembly.shankDiameterMM must be finite and 0...={SHANK_DIAMETER_MAX_MM} (diameter input; the shank radius is half of it)"
            ).into());
        }
        let shank_radius_mm = d * 0.5;
        let clearance_mm = req.clearance_mm.unwrap_or(0.0);
        if !clearance_mm.is_finite() || !(0.0..=CLEARANCE_MAX_MM).contains(&clearance_mm) {
            return Err(format!(
                "millingAssembly.clearanceMM must be finite and 0...={CLEARANCE_MAX_MM}"
            ).into());
        }
        let n = req.holder_profile.len();
        if !(PROFILE_POINTS_MIN..=PROFILE_POINTS_MAX).contains(&n) {
            return Err(format!(
                "millingAssembly.holderProfile must have {PROFILE_POINTS_MIN}...={PROFILE_POINTS_MAX} points"
            ).into());
        }
        let mut profile: Vec<(f64, f64)> = Vec::with_capacity(n);
        for (i, p) in req.holder_profile.iter().enumerate() {
            let (z, r) = (p[0], p[1]);
            if !z.is_finite() || !r.is_finite() {
                return Err(format!("millingAssembly.holderProfile[{i}]: finite [axialDistanceMM, radiusMM] required").into());
            }
            if !(0.0..=PROFILE_AXIAL_MAX_MM).contains(&z) {
                return Err(format!("millingAssembly.holderProfile[{i}]: axial distance must be 0...={PROFILE_AXIAL_MAX_MM} mm from the tool tip").into());
            }
            if r <= 0.0 || r > PROFILE_RADIUS_MAX_MM {
                return Err(format!("millingAssembly.holderProfile[{i}]: radius must be 0...={PROFILE_RADIUS_MAX_MM} mm (radius input, not diameter)").into());
            }
            if let Some(&(zp, rp)) = profile.last() {
                if z < zp {
                    return Err(format!("millingAssembly.holderProfile[{i}]: axial distances must be sorted ascending (equal distances may express a shoulder step)").into());
                }
                if z == zp && r == rp {
                    return Err(format!("millingAssembly.holderProfile[{i}]: duplicate profile point [{z}, {r}] is not allowed").into());
                }
            }
            profile.push((z, r));
        }
        let first_z = profile[0].0;
        let last_z = profile[n - 1].0;
        if first_z < cut_length_mm {
            return Err(format!(
                "millingAssembly.holderProfile: first axial distance {first_z} must not be below the cutting-edge length {cut_length_mm}"
            ).into());
        }
        if last_z <= first_z {
            return Err("millingAssembly.holderProfile: last axial distance must be greater than the first".into());
        }
        // A shoulder disk is covered by the closed solid on either side.
        // An isolated radial spike (including an enlarged terminal disk) has
        // no finite-thickness supporting segment and cannot be silently
        // discarded by the segmented solid representation.
        let mut first = 0;
        while first < n {
            let mut last = first;
            while last+1 < n && profile[last+1].0 == profile[first].0 { last += 1; }
            let covered = (if first > 0 { profile[first].1 } else { 0.0f64 })
                .max(if last+1 < n { profile[last].1 } else { 0.0f64 });
            if profile[first..=last].iter().any(|&(_,r)|r > covered) {
                return Err("millingAssembly: isolated zero-thickness holder flange unsupported; specify finite axial thickness".into());
            }
            first = last+1;
        }
        // Shank covers [cut_length, profile_first]; a zero-length shank
        // (first axial within 1e-9 of the cutting length) is omitted. A
        // shank wider than the holder base is allowed: the closed shank
        // cylinder end cap covers the junction ledge exactly.
        let shank = if first_z - cut_length_mm > 1e-9 {
            Some(Seg::Cyl {
                z0: cut_length_mm,
                z1: first_z,
                r: shank_radius_mm,
            })
        } else {
            None
        };
        let mut holder_segs = Vec::new();
        let mut holder_error_mm = 0.0f64;
        for w in profile.windows(2) {
            let ((z0, r0), (z1, r1)) = (w[0], w[1]);
            if z0 == z1 {
                // Shoulder step: covered exactly by the closed envelopes of
                // the neighbouring windows (see module header).
                continue;
            }
            if (r0 - r1).abs() <= 1e-12 {
                holder_segs.push(Seg::Cyl { z0, z1, r: r0 });
            } else {
                holder_error_mm = holder_error_mm.max((r0 - r1).abs());
                holder_segs.push(Seg::Taper { z0, z1, r0, r1 });
            }
        }
        Ok(ToolAssembly {
            name: req.name.clone(),
            shank_radius_mm,
            holder: ToolHolder {
                name: req.name.clone(),
                profile,
            },
            clearance_mm,
            cut_length_mm,
            tool_radius_mm,
            holder_error_mm,
            shank,
            holder_segs,
        })
    }

    fn segments(&self, part: ToolPart) -> &[Seg] {
        match part {
            ToolPart::Shank => match &self.shank {
                Some(s) => std::slice::from_ref(s),
                None => &[],
            },
            ToolPart::Holder => &self.holder_segs,
        }
    }
}

// ---- placement helpers ------------------------------------------------------

fn rot_y_to(axis: &Vector3<f64>) -> Rotation3<f64> {
    Rotation3::rotation_between(&Vector3::y(), axis).unwrap_or_else(|| {
        // 180-degree case: rotate Y to -Y about any orthogonal axis.
        let alt = if axis.x.abs() < 0.9 {
            Vector3::x()
        } else {
            Vector3::z()
        };
        Rotation3::from_axis_angle(
            &Unit::new_normalize(Vector3::y().cross(&alt)),
            std::f64::consts::PI,
        )
    })
}

fn point_at(tip: &Point3<f64>, axis: &Vector3<f64>, s: f64) -> Point3<f64> {
    tip + axis * s
}

enum PlacedShape {
    Cylinder { c: Cylinder, iso: Isometry3<f32> },
    Cone { c: Cone, iso: Isometry3<f32> },
}

struct Placed {
    shape: PlacedShape,
    /// Conservative world AABB of the segment solid (prefilter/candidate use).
    aabb_min: [f64; 3],
    aabb_max: [f64; 3],
}

fn aabb_of_segment(
    tip: &Point3<f64>,
    axis: &Vector3<f64>,
    z0: f64,
    z1: f64,
    radius: f64,
) -> ([f64; 3], [f64; 3]) {
    let p0 = point_at(tip, axis, z0);
    let p1 = point_at(tip, axis, z1);
    let mut lo = [0.0; 3];
    let mut hi = [0.0; 3];
    for k in 0..3 {
        lo[k] = p0[k].min(p1[k]) - radius;
        hi[k] = p0[k].max(p1[k]) + radius;
    }
    (lo, hi)
}

fn place_cylinder(
    tip: &Point3<f64>,
    axis_u: &Unit<Vector3<f64>>,
    z0: f64,
    z1: f64,
    r: f64,
) -> Placed {
    let axis = axis_u.as_ref();
    let rot = rot_y_to(axis);
    // parry's Cylinder is centred at its origin along Y: the centre of a
    // segment spanning [z0, z1] from the tip is the segment midpoint.
    let center = point_at(tip, axis, (z0 + z1) * 0.5);
    let iso = Isometry3::from_parts(
        Translation3::from(center.coords.cast::<f32>()),
        UnitQuaternion::from_rotation_matrix(&rot.cast::<f32>()),
    );
    let (aabb_min, aabb_max) = aabb_of_segment(tip, axis, z0, z1, r);
    Placed {
        shape: PlacedShape::Cylinder {
            c: Cylinder::new(((z1 - z0) * 0.5) as f32, r as f32),
            iso,
        },
        aabb_min,
        aabb_max,
    }
}

/// Inscribed cone of a taper window. For r1 < r0 the apex sits at z1 and the
/// base circle (radius r0) at z0; for r1 > r0 the apex sits at z0 and the
/// base circle (radius r1) at z1. parry's Cone has its apex at +Y and its
/// base circle at -Y.
fn place_inscribed_cone(
    tip: &Point3<f64>,
    axis_u: &Unit<Vector3<f64>>,
    z0: f64,
    z1: f64,
    r0: f64,
    r1: f64,
) -> Placed {
    let axis = axis_u.as_ref();
    let (apex_z, base_z, base_r) = if r1 < r0 {
        (z1, z0, r0)
    } else {
        (z0, z1, r1)
    };
    let h = (base_z - apex_z).abs();
    let center = point_at(tip, axis, (apex_z + base_z) * 0.5);
    // parry's Cone has its apex at +Y and its base circle at -Y. When the
    // base lies on the +axis side of the apex, -Y must map to +axis (i.e.
    // +Y maps to -axis); otherwise +Y maps directly to +axis.
    let rot = if base_z > apex_z {
        rot_y_to(axis) * Rotation3::from_axis_angle(&Vector3::x_axis(), std::f64::consts::PI)
    } else {
        rot_y_to(axis)
    };
    let iso = Isometry3::from_parts(
        Translation3::from(center.coords.cast::<f32>()),
        UnitQuaternion::from_rotation_matrix(&rot.cast::<f32>()),
    );
    let env_r = r0.max(r1);
    let (aabb_min, aabb_max) = aabb_of_segment(tip, axis, z0, z1, env_r);
    Placed {
        shape: PlacedShape::Cone {
            c: Cone::new((h * 0.5) as f32, base_r as f32),
            iso,
        },
        aabb_min,
        aabb_max,
    }
}

fn placed_shape_ref(p: &PlacedShape) -> (&dyn Shape, &Isometry3<f32>) {
    match p {
        PlacedShape::Cylinder { c, iso } => (c, iso),
        PlacedShape::Cone { c, iso } => (c, iso),
    }
}

fn aabb_dist(a_min: [f64; 3], a_max: [f64; 3], b_min: [f64; 3], b_max: [f64; 3]) -> f64 {
    let mut d2 = 0.0;
    for k in 0..3 {
        let d = if a_max[k] < b_min[k] {
            b_min[k] - a_max[k]
        } else if b_max[k] < a_min[k] {
            a_min[k] - b_max[k]
        } else {
            0.0
        };
        d2 += d * d;
    }
    d2.sqrt()
}

/// Bounded near-contact band reflecting f32 query precision: ~1e-5 relative
/// to the coordinate magnitude of the two involved AABBs. No precision
/// certification is claimed; distances inside +-eps of 0 or of the
/// clearance threshold are UNCERTAIN rather than classified.
fn geom_eps(a_min: [f64; 3], a_max: [f64; 3], b_min: [f64; 3], b_max: [f64; 3]) -> f64 {
    let mut m = 1.0f64;
    for k in 0..3 {
        m = m.max(a_min[k].abs())
            .max(a_max[k].abs())
            .max(b_min[k].abs())
            .max(b_max[k].abs());
    }
    1e-5 * m
}

// ---- budgeted Parry wrappers. Query errors become UNCERTAIN; budget
// exhaustion is a task failure. ------------------------------------------------

fn parry_distance(
    budget: &mut QueryBudget,
    iso1: &Isometry3<f32>,
    s1: &dyn Shape,
    iso2: &Isometry3<f32>,
    s2: &dyn Shape,
) -> Result<Option<f64>, Fail> {
    budget.take_parry()?;
    Ok(query::distance(iso1, s1, iso2, s2)
        .ok()
        .map(|d| d as f64)
        .filter(|d| d.is_finite()))
}

fn parry_contact_depth(
    budget: &mut QueryBudget,
    iso1: &Isometry3<f32>,
    s1: &dyn Shape,
    iso2: &Isometry3<f32>,
    s2: &dyn Shape,
) -> Result<Option<f64>, Fail> {
    budget.take_parry()?;
    Ok(match query::contact(iso1, s1, iso2, s2, 0.0) {
        Ok(Some(c)) => Some((-(c.dist as f64)).max(0.0)),
        Ok(None) => Some(0.0),
        Err(_) => None,
    })
}

// ---- per-target classification ----------------------------------------------

/// Classify an unsigned f64 distance (from an f32 Parry query, error ~eps) for
/// an EXACT solid. Touching / near-contact inside the float band and a
/// clearance threshold inside the band are UNCERTAIN, never a definite
/// penetration or a definite insufficient clearance.
fn classify_exact_distance(d: f64, clearance: f64, eps: f64, depth: Option<f64>) -> Verdict {
    // Parry distance is unsigned: both touching and penetrating solids
    // return zero. A signed contact depth must resolve that case.
    if d <= eps {
        match depth {
            Some(dep) => {
                let lb = (dep - eps).max(0.0);
                if lb <= 0.0 {
                    Verdict::Uncertain
                } else {
                    Verdict::Intersecting {
                        depth_lb: lb,
                        depth_exact: true,
                    }
                }
            }
            None => Verdict::Uncertain,
        }
    } else if d < clearance - eps {
        Verdict::Clearance {
            gap_lb: (d - eps).max(0.0),
        }
    } else if d <= clearance + eps {
        Verdict::Uncertain
    } else {
        Verdict::Clear {
            gap_lb: d - eps,
        }
    }
}

/// Exact cylinder segment vs one cuboid target (fixture box or voxel cell).
fn exact_seg_vs_box(
    seg: &Placed,
    clearance: f64,
    box_iso: &Isometry3<f32>,
    box_shape: &Cuboid,
    budget: &mut QueryBudget,
) -> Result<Verdict, Fail> {
    let (s1, iso1) = placed_shape_ref(&seg.shape);
    let eps = {
        let he = box_shape.half_extents;
        let c = box_iso.translation.vector;
        geom_eps(
            seg.aabb_min,
            seg.aabb_max,
            [(c.x - he.x) as f64, (c.y - he.y) as f64, (c.z - he.z) as f64],
            [(c.x + he.x) as f64, (c.y + he.y) as f64, (c.z + he.z) as f64],
        )
    };
    match parry_distance(budget, iso1, s1, box_iso, box_shape)? {
        None => Ok(Verdict::Uncertain),
        Some(d) if d <= eps => {
            let depth = parry_contact_depth(budget, iso1, s1, box_iso, box_shape)?;
            Ok(classify_exact_distance(d, clearance, eps, depth))
        }
        Some(d) => Ok(classify_exact_distance(d, clearance, eps, None)),
    }
}

/// Tapered holder segment vs one cuboid target: envelope distance first;
/// definite clearance when the envelope is clear beyond the float band,
/// definite intersection when the inscribed cone hits, UNCERTAIN in the
/// envelope-only or near-contact band.
fn taper_seg_vs_box(
    env: &Placed,
    cone: &Placed,
    clearance: f64,
    box_iso: &Isometry3<f32>,
    box_shape: &Cuboid,
    budget: &mut QueryBudget,
) -> Result<Verdict, Fail> {
    let (env_s, env_iso) = placed_shape_ref(&env.shape);
    let eps = {
        let he = box_shape.half_extents;
        let c = box_iso.translation.vector;
        geom_eps(
            env.aabb_min,
            env.aabb_max,
            [(c.x - he.x) as f64, (c.y - he.y) as f64, (c.z - he.z) as f64],
            [(c.x + he.x) as f64, (c.y + he.y) as f64, (c.z + he.z) as f64],
        )
    };
    match parry_distance(budget, env_iso, env_s, box_iso, box_shape)? {
        None => Ok(Verdict::Uncertain),
        Some(d_env) if d_env > clearance + eps => Ok(Verdict::Clear {
            // The envelope distance is a true lower bound of the gap; deduct
            // the f32 query error.
            gap_lb: (d_env - eps).max(0.0),
        }),
        Some(_) => {
            let (c_s, c_iso) = placed_shape_ref(&cone.shape);
            match parry_contact_depth(budget, c_iso, c_s, box_iso, box_shape)? {
                Some(depth) if depth > eps => Ok(Verdict::Intersecting {
                    depth_lb: depth - eps,
                    depth_exact: false,
                }),
                _ => Ok(Verdict::Uncertain),
            }
        }
    }
}

/// One assembly segment vs one fixture box, with AABB prefilter.
fn seg_vs_fixture(
    seg: &Seg,
    tip: &Point3<f64>,
    axis: &Unit<Vector3<f64>>,
    clearance: f64,
    f_aabb: ([f64; 3], [f64; 3]),
    box_iso: &Isometry3<f32>,
    box_shape: &Cuboid,
    budget: &mut QueryBudget,
) -> Result<Verdict, Fail> {
    match *seg {
        Seg::Cyl { z0, z1, r } => {
            let placed = place_cylinder(tip, axis, z0, z1, r);
            let d = aabb_dist(placed.aabb_min, placed.aabb_max, f_aabb.0, f_aabb.1);
            let eps = geom_eps(placed.aabb_min,placed.aabb_max,f_aabb.0,f_aabb.1);
            if d > clearance + eps {
                return Ok(Verdict::Clear { gap_lb: d - eps });
            }
            exact_seg_vs_box(&placed, clearance, box_iso, box_shape, budget)
        }
        Seg::Taper { z0, z1, r0, r1 } => {
            let placed = place_cylinder(tip, axis, z0, z1, r0.max(r1));
            let d = aabb_dist(placed.aabb_min, placed.aabb_max, f_aabb.0, f_aabb.1);
            let eps = geom_eps(placed.aabb_min,placed.aabb_max,f_aabb.0,f_aabb.1);
            if d > clearance + eps {
                return Ok(Verdict::Clear { gap_lb: d - eps });
            }
            let cone = place_inscribed_cone(tip, axis, z0, z1, r0, r1);
            taper_seg_vs_box(&placed, &cone, clearance, box_iso, box_shape, budget)
        }
    }
}

fn taper_cone_vs_cells(
    cone: &Placed,
    env_aabb: ([f64; 3], [f64; 3]),
    clearance: f64,
    eps: f64,
    centers: &[[f64; 3]],
    stock_h: f64,
    budget: &mut QueryBudget,
    progress: &Progress,
    frac_lo: f64,
    frac_hi: f64,
    pose: usize,
    poses_total: usize,
    cells_seen: &mut u64,
) -> Result<Verdict, Fail> {
    let (cone_s, cone_iso) = placed_shape_ref(&cone.shape);
    let cell_half = (stock_h * 0.5) as f32;
    let half = stock_h * 0.5;
    for c in centers {
        let c_min = [c[0] - half, c[1] - half, c[2] - half];
        let c_max = [c[0] + half, c[1] + half, c[2] + half];
        if aabb_dist(env_aabb.0, env_aabb.1, c_min, c_max) > clearance + eps {
            continue;
        }
        *cells_seen += 1;
        if *cells_seen % 256 == 0 {
            progress.report(
                frac_lo + (frac_hi - frac_lo) * (pose as f64) / (poses_total.max(1) as f64),
                "assembly-collision",
            )?;
        }
        let c_iso = Isometry3::from_parts(
            Translation3::from(Vector3::new(c[0], c[1], c[2]).cast::<f32>()),
            UnitQuaternion::identity(),
        );
        let cell = Cuboid::new(Vector3::new(cell_half, cell_half, cell_half));
        match parry_contact_depth(budget, cone_iso, cone_s, &c_iso, &cell)? {
            Some(depth) if depth > eps => {
                return Ok(Verdict::Intersecting {
                    depth_lb: depth - eps,
                    depth_exact: false,
                })
            }
            _ => {}
        }
    }
    Ok(Verdict::Uncertain)
}

#[allow(clippy::too_many_arguments)]
fn seg_vs_stock(
    seg: &Seg,
    tip: &Point3<f64>,
    axis: &Unit<Vector3<f64>>,
    stock: &Stock,
    clearance: f64,
    budget: &mut QueryBudget,
    progress: &Progress,
    frac_lo: f64,
    frac_hi: f64,
    pose: usize,
    poses_total: usize,
    cells_seen: &mut u64,
) -> Result<Verdict, Fail> {
    let (z0, z1, env_r, taper) = match *seg {
        Seg::Cyl { z0, z1, r } => (z0, z1, r, None),
        Seg::Taper { z0, z1, r0, r1 } => (z0, z1, r0.max(r1), Some((r0, r1))),
    };
    let placed = place_cylinder(tip, axis, z0, z1, env_r);
    let stock_hi = [stock.origin[0]+stock.h*stock.nx as f64,stock.origin[1]+stock.h*stock.ny as f64,stock.origin[2]+stock.h*stock.nz as f64];
    let eps = geom_eps(placed.aabb_min,placed.aabb_max,stock.origin,stock_hi);
    let margin = clearance + eps;
    let mut q_lo = [
        placed.aabb_min[0] - margin,
        placed.aabb_min[1] - margin,
        placed.aabb_min[2] - margin,
    ];
    let mut q_hi = [
        placed.aabb_max[0] + margin,
        placed.aabb_max[1] + margin,
        placed.aabb_max[2] + margin,
    ];
    // Clamp the candidate query to the stock grid for bounded work.
    q_lo[0] = q_lo[0].max(stock.origin[0]);
    q_lo[1] = q_lo[1].max(stock.origin[1]);
    q_lo[2] = q_lo[2].max(stock.origin[2]);
    q_hi[0] = q_hi[0].min(stock.origin[0] + stock.h * stock.nx as f64);
    q_hi[1] = q_hi[1].min(stock.origin[1] + stock.h * stock.ny as f64);
    q_hi[2] = q_hi[2].min(stock.origin[2] + stock.h * stock.nz as f64);
    if q_hi.iter().zip(q_lo.iter()).any(|(&hi, &lo)| hi <= lo) {
        return Ok(Verdict::Clear {
            gap_lb: f64::INFINITY,
        });
    }
    let centers = stock.occupied_centers_in_aabb(q_lo, q_hi);
    if centers.is_empty() {
        return Ok(Verdict::Clear {
            gap_lb: f64::INFINITY,
        });
    }
    let cell_half = (stock.h * 0.5) as f32;
    let cell = Cuboid::new(Vector3::new(cell_half, cell_half, cell_half));
    let cone = taper.map(|(r0, r1)| place_inscribed_cone(tip, axis, z0, z1, r0, r1));
    let (tool_s, tool_iso) = placed_shape_ref(&placed.shape);
    let cell_iso = |c: &[f64; 3]| {
        Isometry3::from_parts(
            Translation3::from(Vector3::new(c[0], c[1], c[2]).cast::<f32>()),
            UnitQuaternion::identity(),
        )
    };
    let cell_aabb = |c: &[f64; 3]| {
        let half = stock.h * 0.5;
        (
            [c[0] - half, c[1] - half, c[2] - half],
            [c[0] + half, c[1] + half, c[2] + half],
        )
    };
    let mut report = |i: usize, n: usize| -> Result<(), Fail> {
        *cells_seen += 1;
        if *cells_seen % 256 == 0 {
            progress.report(
                frac_lo
                    + (frac_hi - frac_lo)
                        * ((pose as f64) + i as f64 / n.max(1) as f64)
                        / (poses_total.max(1) as f64),
                "assembly-collision",
            )?;
        }
        Ok(())
    };

    if taper.is_none() {
        let mut verdict = Verdict::Clear { gap_lb:clearance };
        for (i,c) in centers.iter().enumerate() {
            report(i,centers.len())?;
            let (c_min,c_max) = cell_aabb(c);
            if aabb_dist(placed.aabb_min,placed.aabb_max,c_min,c_max) > margin { continue; }
            let value = exact_seg_vs_box(&placed,clearance,&cell_iso(c),&cell,budget)?;
            // A first zero distance may only be a boundary touch. Continue
            // until a supported penetrating cell proves contact, or preserve
            // the worst unresolved/clearance verdict across all candidates.
            if matches!(value,Verdict::Intersecting { .. }) { return Ok(value); }
            verdict = worst_of([verdict,value]).unwrap();
        }
        return Ok(verdict);
    }

    // Phase 1: envelope distance over candidate cells with best-distance
    // pruning. Distance is exact for cylinder/cone vs cuboid.
    let mut best = f64::INFINITY;
    let mut unsupported = false;
    for (i, c) in centers.iter().enumerate() {
        report(i, centers.len())?;
        let (c_min, c_max) = cell_aabb(c);
        if aabb_dist(placed.aabb_min, placed.aabb_max, c_min, c_max) >= best {
            continue; // cannot improve the current minimum distance
        }
        match parry_distance(budget, tool_iso, tool_s, &cell_iso(c), &cell)? {
            None => unsupported = true,
            Some(d) => {
                if d < best {
                    best = d;
                    if d <= 0.0 {
                        break; // cannot do better than an intersection
                    }
                }
            }
        }
    }
    if unsupported && best > eps {
        // `best` is a minimum over the SUPPORTED subset only: an upper
        // bound of the true minimum, never a lower bound. No gap claim.
        return Ok(Verdict::Uncertain);
    }
    if best > clearance + eps {
        // Candidates were selected within the clearance window of the
        // segment AABB; stock outside that window is only known to be
        // farther than the clearance, so the conservative lower bound of
        // the true minimum gap is the clearance itself.
        return Ok(Verdict::Clear { gap_lb: clearance });
    }
    {
            // Envelope penetration or envelope band: resolve with the
            // inscribed cone (definite intersection on a cone hit; otherwise
            // UNCERTAIN — a tapered window can never claim Clearance since
            // the envelope distance only lower-bounds the true gap).
            taper_cone_vs_cells(
                cone.as_ref().unwrap(),
                (placed.aabb_min, placed.aabb_max),
                clearance,
                eps,
                &centers,
                stock.h,
                budget,
                progress,
                frac_lo,
                frac_hi,
                pose,
                poses_total,
                cells_seen,
            )
    }
}

/// Worst verdict of one part (all its segments) vs the fixture / stock.
#[allow(clippy::too_many_arguments)]
fn part_vs_target(
    segs: &[Seg],
    tip: &Point3<f64>,
    axis: &Unit<Vector3<f64>>,
    clearance: f64,
    target: TargetRef<'_>,
    budget: &mut QueryBudget,
    progress: &Progress,
    frac_lo: f64,
    frac_hi: f64,
    pose: usize,
    poses_total: usize,
    cells_seen: &mut u64,
) -> Result<Verdict, Fail> {
    let mut vs = Vec::with_capacity(segs.len());
    for seg in segs {
        let v = match target {
            TargetRef::Fixture(faabb, iso, shape) => {
                seg_vs_fixture(seg, tip, axis, clearance, faabb, iso, shape, budget)?
            }
            TargetRef::Stock(stock) => seg_vs_stock(
                seg, tip, axis, stock, clearance, budget, progress, frac_lo, frac_hi, pose,
                poses_total, cells_seen,
            )?,
        };
        vs.push(v);
    }
    Ok(worst_of(vs).unwrap())
}

enum TargetRef<'a> {
    Fixture(([f64; 3], [f64; 3]), &'a Isometry3<f32>, &'a Cuboid),
    Stock(&'a Stock),
}

/// Accumulates (part, target) records across the poses of ONE operation
/// (milling or ac) and renders contract collision rows at the end.
pub struct AssemblyChecker<'a> {
    asm: &'a ToolAssembly,
    fixture_shapes: Vec<(String, Cuboid, Isometry3<f32>)>,
    budget: &'a mut QueryBudget,
    records: Vec<(ToolPart, TargetKey, Record)>,
}

impl<'a> AssemblyChecker<'a> {
    pub fn new(
        asm: &'a ToolAssembly,
        fixtures: &'a [FixtureBox],
        budget: &'a mut QueryBudget,
    ) -> Result<Self, Fail> {
        let fixture_shapes = fixtures
            .iter()
            .map(|f| {
                let c = f.cuboid().map_err(Fail::Message)?;
                let iso = Isometry3::from_parts(
                    Translation3::from(f.center().cast::<f32>()),
                    UnitQuaternion::identity(),
                );
                Ok((f.id.clone(), c, iso))
            })
            .collect::<Result<Vec<_>, Fail>>()?;
        let mut checker = AssemblyChecker {
            asm,
            fixture_shapes,
            budget,
            records: Vec::new(),
        };
        // Seed the required row set (Root contract): shank (when present) and
        // holder against every fixture plus the remaining stock, so even a
        // zero-pose operation reports an explicit checked scope instead of an
        // accidental empty collision list.
        for part in [ToolPart::Shank, ToolPart::Holder] {
            if checker.asm.segments(part).is_empty() {
                continue;
            }
            for (id, _, _) in &checker.fixture_shapes {
                checker.records.push((part, TargetKey::Fixture(id.clone()), Record::new()));
            }
            checker.records.push((part, TargetKey::Stock, Record::new()));
        }
        Ok(checker)
    }

    fn observe(records: &mut Vec<(ToolPart, TargetKey, Record)>, part: ToolPart, key: TargetKey, v: Verdict, pose: usize) {
        for (p, k, rec) in records.iter_mut() {
            if *p == part && *k == key {
                rec.observe(v, pose);
                return;
            }
        }
        let mut rec = Record::new();
        rec.observe(v, pose);
        records.push((part, key, rec));
    }

    /// Check shank + holder at one material step: AFTER the current removal
    /// step, BEFORE any future removal can hide the contact.
    pub fn check_step(
        &mut self,
        pose: usize,
        poses_total: usize,
        tip: &Point3<f64>,
        axis: &Unit<Vector3<f64>>,
        stock: &Stock,
        progress: &Progress,
        frac_lo: f64,
        frac_hi: f64,
    ) -> Result<(), Fail> {
        progress.report(
            frac_lo + (frac_hi - frac_lo) * (pose as f64) / (poses_total.max(1) as f64),
            "assembly-collision",
        )?;
        let clearance = self.asm.clearance_mm;
        let mut cells_seen = 0u64;
        for part in [ToolPart::Shank, ToolPart::Holder] {
            let segs = self.asm.segments(part);
            if segs.is_empty() {
                continue; // zero-length shank omitted by contract
            }
            for (id, shape, iso) in &self.fixture_shapes {
                let he = shape.half_extents;
                let c = iso.translation.vector;
                let faabb = (
                    [(c.x - he.x) as f64, (c.y - he.y) as f64, (c.z - he.z) as f64],
                    [(c.x + he.x) as f64, (c.y + he.y) as f64, (c.z + he.z) as f64],
                );
                let v = part_vs_target(
                    segs,
                    tip,
                    axis,
                    clearance,
                    TargetRef::Fixture(faabb, iso, shape),
                    self.budget,
                    progress,
                    frac_lo,
                    frac_hi,
                    pose,
                    poses_total,
                    &mut cells_seen,
                )?;
                Self::observe(&mut self.records, part, TargetKey::Fixture(id.clone()), v, pose);
            }
            let v = part_vs_target(
                segs,
                tip,
                axis,
                clearance,
                TargetRef::Stock(stock),
                self.budget,
                progress,
                frac_lo,
                frac_hi,
                pose,
                poses_total,
                &mut cells_seen,
            )?;
            Self::observe(&mut self.records, part, TargetKey::Stock, v, pose);
        }
        Ok(())
    }

    /// Render the accumulated records as contract collision rows for one
    /// operation. `stock_h` is the voxel resolution recorded in stock rows.
    pub fn into_rows(self, operation: &str, stock_h: f64) -> Vec<crate::model::CollisionOut> {
        let clearance = self.asm.clearance_mm;
        let holder_error = self.asm.holder_error_mm;
        self.records
            .into_iter()
            .map(|(part, key, rec)| {
                build_row(part, &key, &rec, operation, clearance, stock_h, holder_error)
            })
            .collect()
    }
}

#[allow(clippy::too_many_arguments)]
fn build_row(
    part: ToolPart,
    key: &TargetKey,
    rec: &Record,
    operation: &str,
    clearance: f64,
    stock_h: f64,
    holder_error: f64,
) -> crate::model::CollisionOut {
    let (component, target_kind, target_desc) = match key {
        TargetKey::Fixture(id) => (id.clone(), "fixture", format!("fixture '{id}'")),
        TargetKey::Stock => (
            "remaining-stock".to_string(),
            "stock",
            format!(
                "remaining stock (voxel cell solids, resolution h={stock_h:.2} mm, checked after each material step)"
            ),
        ),
    };
    let state = match rec.verdict {
        Verdict::Intersecting { .. } => "intersecting",
        Verdict::Uncertain => "uncertain",
        Verdict::Clearance { .. } => "clearance",
        Verdict::Clear { .. } => "clear",
    };
    let mut message = match rec.verdict {
        Verdict::Intersecting { .. } => {
            let depth_part = if rec.depth_unknown && rec.max_depth_lb > 0.0 {
                format!(
                    ", penetration at least {:.4} mm (exact depth unavailable for the tapered holder envelope)",
                    rec.max_depth_lb
                )
            } else if rec.depth_unknown {
                ", exact penetration depth unavailable (tapered holder envelope)".to_string()
            } else {
                format!(", observed penetration lower bound {:.4} mm", rec.max_depth_lb)
            };
            format!(
                "{} intersects {} (first at pose {}{})",
                part.as_str(),
                target_desc,
                rec.first_pose,
                depth_part
            )
        }
        Verdict::Uncertain => {
            format!(
                "{} vs {}: contact possible but unresolved (envelope-only contact, failed/unsupported query, or near-contact float uncertainty); never reported clear",
                part.as_str(),
                target_desc
            )
        }
        Verdict::Clearance { gap_lb } => format!(
            "{} vs {}: gap lower bound {:.4} mm; required clearance {:.4} mm is not met (first at pose {})",
            part.as_str(),
            target_desc,
            gap_lb,
            clearance,
            rec.first_pose
        ),
        Verdict::Clear { gap_lb } => {
            if gap_lb.is_finite() {
                format!(
                    "{} clear of {} at all {} checked poses (minimum gap lower bound {:.4} mm >= clearance {:.4} mm)",
                    part.as_str(),
                    target_desc,
                    rec.poses_checked,
                    gap_lb,
                    clearance
                )
            } else {
                format!(
                    "{} clear of {} (no pose required a collision query; {} checked poses)",
                    part.as_str(),
                    target_desc,
                    rec.poses_checked
                )
            }
        }
    };
    let geometry_error = if part == ToolPart::Holder && holder_error > 0.0 {
        Some(holder_error)
    } else {
        None
    };
    if let Some(e) = geometry_error {
        message.push_str(&format!(
            "; holder taper envelope error (max radial) {e:.4} mm"
        ));
    }
    // Gap claims are emitted ONLY for definite clear / insufficient-clearance
    // states; uncertain and intersecting rows carry no minimum-gap claim.
    let minimum_gap = match rec.verdict {
        Verdict::Clear { .. } | Verdict::Clearance { .. } => {
            rec.gap_lb.filter(|g| g.is_finite())
        }
        _ => None,
    };
    crate::model::CollisionOut {
        component,
        state: state.to_string(),
        message,
        tool_part: Some(part.as_str().to_string()),
        target_kind: Some(target_kind.to_string()),
        operation: Some(operation.to_string()),
        first_pose_index: if state == "clear" {
            None
        } else {
            Some(rec.first_pose)
        },
        minimum_gap_lower_bound_mm: minimum_gap,
        geometry_error_mm: geometry_error,
    }
}

/// Cutter (exact cutting cylinder) vs fixture boxes with R2 clearance
/// semantics. Used when a millingAssembly is present; the R1
/// intersection-only cutter check remains in place for assembly-free inputs.
/// Bounded cancellation via `progress` (phase "cutter-collision").
#[allow(clippy::too_many_arguments)]
pub fn check_cutter_against_fixtures_with_clearance(
    fixtures: &[FixtureBox],
    tip: &[Point3<f64>],
    axis: &[Unit<Vector3<f64>>],
    radius: f64,
    length: f64,
    clearance: f64,
    operation: &str,
    budget: &mut QueryBudget,
    progress: &Progress,
    frac_lo: f64,
    frac_hi: f64,
) -> Result<Vec<CutterCollisionSummary>, Fail> {
    if tip.len() != axis.len() || tip.is_empty() {
        return Ok(vec![]);
    }
    if !radius.is_finite() || radius <= 0.0 || !length.is_finite() || length <= 0.0 {
        return Err("collision: finite positive cutter radius/length required".into());
    }
    let mut rows: Vec<(String, Record)> = Vec::new();
    let n = tip.len().max(1);
    for (pose, (tip_p, axis_u)) in tip.iter().zip(axis.iter()).enumerate() {
        if pose % 32 == 0 {
            progress.report(
                frac_lo + (frac_hi - frac_lo) * (pose as f64) / (n as f64),
                "cutter-collision",
            )?;
        }
        let placed = place_cylinder(tip_p, axis_u, 0.0, length, radius);
        for f in fixtures {
            let (shape, iso) = {
                let c = f.cuboid().map_err(Fail::Message)?;
                let fi = Isometry3::from_parts(
                    Translation3::from(f.center().cast::<f32>()),
                    UnitQuaternion::identity(),
                );
                (c, fi)
            };
            let he = shape.half_extents;
            let c = iso.translation.vector;
            let f_min = [(c.x - he.x) as f64, (c.y - he.y) as f64, (c.z - he.z) as f64];
            let f_max = [(c.x + he.x) as f64, (c.y + he.y) as f64, (c.z + he.z) as f64];
            let gap = aabb_dist(placed.aabb_min,placed.aabb_max,f_min,f_max);
            let eps = geom_eps(placed.aabb_min,placed.aabb_max,f_min,f_max);
            let v = if gap > clearance + eps {
                Verdict::Clear {
                    gap_lb: gap - eps,
                }
            } else {
                exact_seg_vs_box(&placed, clearance, &iso, &shape, budget)?
            };
            match rows.iter_mut().find(|(id, _)| id == &f.id) {
                Some((_, rec)) => rec.observe(v, pose),
                None => {
                    let mut rec = Record::new();
                    rec.observe(v, pose);
                    rows.push((f.id.clone(), rec));
                }
            }
        }
    }
    Ok(rows
        .into_iter()
        .map(|(id, rec)| {
            let collision_state = match rec.verdict {
                Verdict::Intersecting { .. } => CollisionState::Intersecting,
                Verdict::Uncertain => CollisionState::Uncertain,
                Verdict::Clearance { .. } => CollisionState::Clearance,
                Verdict::Clear { .. } => CollisionState::Clear,
            };
            let message = match rec.verdict {
                Verdict::Intersecting { .. } => format!(
                    "cutter intersects fixture (observed penetration lower bound {:.4} mm, first at pose {})",
                    rec.max_depth_lb, rec.first_pose
                ),
                Verdict::Uncertain => {
                    "cutter vs fixture: query unsupported/errored or near-contact float uncertainty; uncertain, never clear"
                        .to_string()
                }
                Verdict::Clearance { gap_lb } => format!(
                    "cutter clear of intersection but gap {:.4} mm < clearance {:.4} mm (first at pose {})",
                    gap_lb, clearance, rec.first_pose
                ),
                Verdict::Clear { gap_lb } => {
                    if gap_lb.is_finite() {
                        format!(
                            "cutter clear of fixture at all {} checked poses (min gap lower bound {:.4} mm)",
                            rec.poses_checked, gap_lb
                        )
                    } else {
                        "cutter clear of fixture at all checked poses".to_string()
                    }
                }
            };
            let mut s = CutterCollisionSummary::bare(id, collision_state, message);
            s.tool_part = Some("cutter".into());
            s.target_kind = Some("fixture".into());
            s.operation = Some(operation.to_string());
            if !matches!(rec.verdict, Verdict::Clear { .. }) {
                s.first_pose_index = Some(rec.first_pose);
            }
            if matches!(
                rec.verdict,
                Verdict::Clear { .. } | Verdict::Clearance { .. }
            ) {
                s.minimum_gap_lower_bound_mm = rec.gap_lb.filter(|g| g.is_finite());
            }
            s
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::BudgetReq;

    fn req(name: &str, shank_d: f64, profile: Vec<[f64; 2]>, clearance: Option<f64>) -> MillingAssemblyReq {
        MillingAssemblyReq {
            format_version: 1,
            name: name.to_string(),
            shank_diameter_mm: shank_d,
            holder_profile: profile,
            clearance_mm: clearance,
        }
    }

    fn axis_x() -> Unit<Vector3<f64>> {
        Unit::new_normalize(Vector3::x())
    }

    #[test]
    fn validate_rejects_bad_inputs() {
        // version
        let mut r = req("t", 4.0, vec![[10.0, 4.0], [20.0, 4.0]], Some(0.5));
        r.format_version = 2;
        assert!(ToolAssembly::validate(&r, 2.0, 5.0).is_err());
        // empty name / oversized name
        let r0 = req("", 4.0, vec![[10.0, 4.0], [20.0, 4.0]], Some(0.5));
        assert!(ToolAssembly::validate(&r0, 2.0, 5.0).is_err());
        let big = "x".repeat(513);
        let r1 = req(&big, 4.0, vec![[10.0, 4.0], [20.0, 4.0]], Some(0.5));
        assert!(ToolAssembly::validate(&r1, 2.0, 5.0).is_err());
        // shank diameter: zero / negative / non-finite / over ceiling
        for d in [0.0, -1.0, f64::NAN, f64::INFINITY, 1000.1] {
            let r = req("t", d, vec![[10.0, 4.0], [20.0, 4.0]], Some(0.5));
            assert!(ToolAssembly::validate(&r, 2.0, 5.0).is_err(), "shank {d}");
        }
        // clearance out of band
        for c in [-0.1, 100.1, f64::NAN] {
            let r = req("t", 4.0, vec![[10.0, 4.0], [20.0, 4.0]], Some(c));
            assert!(ToolAssembly::validate(&r, 2.0, 5.0).is_err(), "clearance {c}");
        }
        // point count
        let r = req("t", 4.0, vec![[10.0, 4.0]], Some(0.5));
        assert!(ToolAssembly::validate(&r, 2.0, 5.0).is_err());
        let many = (0..33).map(|i| [10.0 + i as f64, 4.0]).collect::<Vec<_>>();
        let r = req("t", 4.0, many, Some(0.5));
        assert!(ToolAssembly::validate(&r, 2.0, 5.0).is_err());
        // duplicate identical point
        let r = req("t", 4.0, vec![[10.0, 4.0], [10.0, 4.0], [20.0, 4.0]], Some(0.5));
        assert!(ToolAssembly::validate(&r, 2.0, 5.0).is_err());
        // unsorted
        let r = req("t", 4.0, vec![[20.0, 4.0], [10.0, 4.0]], Some(0.5));
        assert!(ToolAssembly::validate(&r, 2.0, 5.0).is_err());
        // axial out of range / radius out of range
        let r = req("t", 4.0, vec![[10.0, 4.0], [1000.1, 4.0]], Some(0.5));
        assert!(ToolAssembly::validate(&r, 2.0, 5.0).is_err());
        let r = req("t", 4.0, vec![[10.0, 500.1], [20.0, 4.0]], Some(0.5));
        assert!(ToolAssembly::validate(&r, 2.0, 5.0).is_err());
        let r = req("t", 4.0, vec![[10.0, 0.0], [20.0, 4.0]], Some(0.5));
        assert!(ToolAssembly::validate(&r, 2.0, 5.0).is_err());
        // first axial below cutting length / last not greater than first
        let r = req("t", 4.0, vec![[4.0, 4.0], [20.0, 4.0]], Some(0.5));
        assert!(ToolAssembly::validate(&r, 2.0, 5.0).is_err());
        let r = req("t", 4.0, vec![[10.0, 4.0], [10.0, 6.0]], Some(0.5));
        assert!(ToolAssembly::validate(&r, 2.0, 5.0).is_err());
        // non-finite profile value
        let r = req("t", 4.0, vec![[10.0, f64::NAN], [20.0, 4.0]], Some(0.5));
        assert!(ToolAssembly::validate(&r, 2.0, 5.0).is_err());
        // valid baseline incl. shoulder step
        let r = req("t", 4.0, vec![[10.0, 4.0], [10.0, 6.0], [25.0, 6.0], [25.0, 8.0], [40.0, 8.0]], Some(0.5));
        let a = ToolAssembly::validate(&r, 2.0, 5.0).unwrap();
        assert_eq!(a.shank_radius_mm, 2.0);
        assert_eq!(a.holder.profile.len(), 5);
    }

    #[test]
    fn zero_length_shank_is_omitted() {
        let r = req("t", 4.0, vec![[5.0, 4.0], [20.0, 4.0]], None);
        let a = ToolAssembly::validate(&r, 2.0, 5.0).unwrap();
        assert!(a.segments(ToolPart::Shank).is_empty());
        // within the 1e-9 threshold
        let r = req("t", 4.0, vec![[5.0 + 5e-10, 4.0], [20.0, 4.0]], None);
        let a = ToolAssembly::validate(&r, 2.0, 5.0).unwrap();
        assert!(a.segments(ToolPart::Shank).is_empty());
        // strictly longer keeps the shank
        let r = req("t", 4.0, vec![[5.1, 4.0], [20.0, 4.0]], None);
        let a = ToolAssembly::validate(&r, 2.0, 5.0).unwrap();
        assert_eq!(a.segments(ToolPart::Shank).len(), 1);
    }

    #[test]
    fn unsupported_zero_thickness_flange_is_not_silently_discarded() {
        for profile in [vec![[10.0,4.0],[20.0,4.0],[20.0,8.0]],
                        vec![[10.0,4.0],[15.0,4.0],[15.0,8.0],[15.0,4.0],[20.0,4.0]]] {
            assert!(ToolAssembly::validate(&req("t",4.0,profile,Some(0.5)),2.0,5.0).is_err());
        }
    }

    fn fixture(id: &str, min: [f64; 3], max: [f64; 3]) -> FixtureBox {
        FixtureBox { id: id.into(), min, max }
    }

    #[test]
    fn holder_hits_fixture_while_cutter_clear() {
        // tip origin, axis +X; cutter [0,15] r2; shank [15,25] r2;
        // holder [25,35] r3. Probe sits inside the holder span only.
        let r = req("t", 4.0, vec![[25.0, 3.0], [35.0, 3.0]], Some(0.5));
        let a = ToolAssembly::validate(&r, 2.0, 15.0).unwrap();
        let stock = Stock::cylinder(5.0, 0.0, 20.0, 1.0, 1 << 20).unwrap();
        let fixtures = vec![fixture("probe", [31.0, -0.5, -0.5], [33.0, 0.5, 0.5])];
        let mut budget = QueryBudget::new(500_000);
        let mut chk = AssemblyChecker::new(&a, &fixtures, &mut budget).unwrap();
        chk.check_step(0, 1, &Point3::origin(), &axis_x(), &stock, &Progress::quiet(), 0.0, 1.0)
            .unwrap();
        let rows = chk.into_rows("milling", stock.h);
        let holder = rows.iter().find(|r| r.tool_part.as_deref() == Some("holder")
            && r.target_kind.as_deref() == Some("fixture")).unwrap();
        assert_eq!(holder.state, "intersecting");
        assert_eq!(holder.first_pose_index, Some(0));
        // cutter check separately: cutter ends at x=15(+r2); probe at x>=31.
        let mut budget2 = QueryBudget::new(500_000);
        let tips = vec![Point3::origin()];
        let axes = vec![axis_x()];
        let c = check_cutter_against_fixtures_with_clearance(
            &fixtures, &tips, &axes, 2.0, 15.0, 0.5, "milling", &mut budget2,
            &Progress::quiet(), 0.0, 1.0,
        ).unwrap();
        assert_eq!(c[0].state, CollisionState::Clear);
    }

    #[test]
    fn definite_insufficient_clearance_is_not_intersection() {
        let r = req("t", 4.0, vec![[25.0, 3.0], [35.0, 3.0]], Some(0.5));
        let a = ToolAssembly::validate(&r, 2.0, 15.0).unwrap();
        let stock = Stock::cylinder(5.0, 0.0, 20.0, 1.0, 1 << 20).unwrap();
        // Radial offset 3.3 from the axis -> exact gap 0.3 < clearance 0.5.
        let fixtures = vec![fixture("near", [30.0, 3.3, -0.5], [32.0, 4.3, 0.5])];
        let mut budget = QueryBudget::new(500_000);
        let mut chk = AssemblyChecker::new(&a, &fixtures, &mut budget).unwrap();
        chk.check_step(0, 1, &Point3::origin(), &axis_x(), &stock, &Progress::quiet(), 0.0, 1.0)
            .unwrap();
        let rows = chk.into_rows("milling", stock.h);
        let holder = rows.iter().find(|r| r.tool_part.as_deref() == Some("holder")).unwrap();
        assert_eq!(holder.state, "clearance");
        let gap = holder.minimum_gap_lower_bound_mm.unwrap();
        assert!(gap > 0.2 && gap < 0.4, "gap {gap}");
        // and the cutter (which does not reach) is clear with its own row
        let mut budget2 = QueryBudget::new(500_000);
        let c = check_cutter_against_fixtures_with_clearance(
            &fixtures, &[Point3::origin()], &[axis_x()], 2.0, 15.0, 0.5, "milling",
            &mut budget2, &Progress::quiet(), 0.0, 1.0,
        ).unwrap();
        assert_eq!(c[0].state, CollisionState::Clear);
    }

    #[test]
    fn taper_envelope_only_contact_is_uncertain_not_intersecting() {
        // Widening window [25,3] -> [35,6]: envelope r6, inscribed cone apex
        // at 25 opening to r6 at 35. The box touches only the envelope band
        // outside both the true frustum and the cone: must be UNCERTAIN. A
        // flipped cone (apex at 35) would falsely report intersecting here.
        let r = req("t", 4.0, vec![[25.0, 3.0], [35.0, 6.0]], Some(0.5));
        let a = ToolAssembly::validate(&r, 2.0, 15.0).unwrap();
        assert!(a.holder_error_mm > 2.99);
        let stock = Stock::cylinder(5.0, 0.0, 20.0, 1.0, 1 << 20).unwrap();
        let fixtures = vec![fixture("band", [26.0, 4.5, -0.5], [27.0, 5.0, 0.5])];
        let mut budget = QueryBudget::new(500_000);
        let mut chk = AssemblyChecker::new(&a, &fixtures, &mut budget).unwrap();
        chk.check_step(0, 1, &Point3::origin(), &axis_x(), &stock, &Progress::quiet(), 0.0, 1.0)
            .unwrap();
        let rows = chk.into_rows("milling", stock.h);
        let holder = rows.iter().find(|r| r.tool_part.as_deref() == Some("holder")).unwrap();
        assert_eq!(holder.state, "uncertain");
        assert_eq!(holder.geometry_error_mm, Some(3.0));
        assert!(holder.minimum_gap_lower_bound_mm.is_none());
    }

    #[test]
    fn taper_cone_hit_is_definite_intersection() {
        // Near the wide end the inscribed cone contains the box: definite.
        let r = req("t", 4.0, vec![[25.0, 3.0], [35.0, 6.0]], Some(0.5));
        let a = ToolAssembly::validate(&r, 2.0, 15.0).unwrap();
        let stock = Stock::cylinder(5.0, 0.0, 20.0, 1.0, 1 << 20).unwrap();
        let fixtures = vec![fixture("deep", [34.0, 4.5, -0.5], [35.0, 5.0, 0.5])];
        let mut budget = QueryBudget::new(500_000);
        let mut chk = AssemblyChecker::new(&a, &fixtures, &mut budget).unwrap();
        chk.check_step(0, 1, &Point3::origin(), &axis_x(), &stock, &Progress::quiet(), 0.0, 1.0)
            .unwrap();
        let rows = chk.into_rows("milling", stock.h);
        let holder = rows.iter().find(|r| r.tool_part.as_deref() == Some("holder")).unwrap();
        assert_eq!(holder.state, "intersecting");
        assert!(holder.message.contains("exact penetration depth unavailable") 
            || holder.message.contains("at least"));
    }

    #[test]
    fn narrowing_taper_cone_hit() {
        let r = req("t", 4.0, vec![[25.0, 6.0], [35.0, 3.0]], Some(0.5));
        let a = ToolAssembly::validate(&r, 2.0, 15.0).unwrap();
        let stock = Stock::cylinder(5.0, 0.0, 20.0, 1.0, 1 << 20).unwrap();
        // Cone apex at 35, base r6 at 25; box at x 26..27 y 2.5..3 is inside.
        let fixtures = vec![fixture("cone", [26.0, 2.5, -0.5], [27.0, 3.0, 0.5])];
        let mut budget = QueryBudget::new(500_000);
        let mut chk = AssemblyChecker::new(&a, &fixtures, &mut budget).unwrap();
        chk.check_step(0, 1, &Point3::origin(), &axis_x(), &stock, &Progress::quiet(), 0.0, 1.0)
            .unwrap();
        let rows = chk.into_rows("milling", stock.h);
        let holder = rows.iter().find(|r| r.tool_part.as_deref() == Some("holder")).unwrap();
        assert_eq!(holder.state, "intersecting");
    }

    #[test]
    fn shank_uses_half_diameter() {
        let r = req("t", 4.0, vec![[10.0, 4.0], [20.0, 4.0]], Some(0.5));
        let a = ToolAssembly::validate(&r, 2.0, 5.0).unwrap();
        let stock = Stock::cylinder(5.0, 0.0, 20.0, 1.0, 1 << 20).unwrap();
        let tip = Point3::new(30.0, 0.0, 10.0);
        // shank spans x 35..40, r = 2 (NOT 4).
        // grazing box at radial 2.9..3.1: clear with a real gap (would
        // intersect if the diameter were used as radius).
        let fixtures = vec![fixture("graze", [36.0, 2.9, 9.5], [38.0, 3.1, 10.5])];
        let mut budget = QueryBudget::new(500_000);
        let mut chk = AssemblyChecker::new(&a, &fixtures, &mut budget).unwrap();
        chk.check_step(0, 1, &tip, &axis_x(), &stock, &Progress::quiet(), 0.0, 1.0)
            .unwrap();
        let rows = chk.into_rows("milling", stock.h);
        let shank = rows.iter().find(|r| r.tool_part.as_deref() == Some("shank")).unwrap();
        assert_eq!(shank.state, "clear");
        let gap = shank.minimum_gap_lower_bound_mm.unwrap();
        assert!(gap > 0.5 && gap < 1.2, "gap {gap}");
        // overlapping box at radial 1.5..1.9 -> definite intersection
        let fixtures2 = vec![fixture("hit", [36.0, 1.5, 9.5], [38.0, 1.9, 10.5])];
        let mut budget2 = QueryBudget::new(500_000);
        let mut chk2 = AssemblyChecker::new(&a, &fixtures2, &mut budget2).unwrap();
        chk2.check_step(0, 1, &tip, &axis_x(), &stock, &Progress::quiet(), 0.0, 1.0)
            .unwrap();
        let rows2 = chk2.into_rows("milling", stock.h);
        let shank2 = rows2.iter().find(|r| r.tool_part.as_deref() == Some("shank")).unwrap();
        assert_eq!(shank2.state, "intersecting");
    }

    #[test]
    fn stock_contact_is_recorded_at_its_material_step() {
        // Shank brushes material that a LATER cut removes: the record must
        // keep the early intersecting state (first pose), not the later clear.
        let r = req("t", 4.0, vec![[10.0, 4.0], [20.0, 4.0]], Some(0.0));
        let a = ToolAssembly::validate(&r, 2.0, 5.0).unwrap();
        let mut stock = Stock::cylinder(10.0, 0.0, 20.0, 1.0, 1 << 20).unwrap();
        let mut budget = QueryBudget::new(500_000);
        let mut chk = AssemblyChecker::new(&a, &[], &mut budget).unwrap();
        // Step 0: cutter at (0,0,10) removes x 0..7; the shank (x 5..10, r2)
        // still overlaps remaining material near x 8.5/9.5.
        let tip0 = Point3::new(0.0, 0.0, 10.0);
        stock.remove_oriented_cutter(&tip0, &Vector3::x(), 2.0, 5.0);
        chk.check_step(0, 2, &tip0, &axis_x(), &stock, &Progress::quiet(), 0.0, 1.0)
            .unwrap();
        // Step 1: cutter at (8,0,10) removes the material the shank touched.
        let tip1 = Point3::new(8.0, 0.0, 10.0);
        stock.remove_oriented_cutter(&tip1, &Vector3::x(), 2.0, 5.0);
        chk.check_step(1, 2, &tip1, &axis_x(), &stock, &Progress::quiet(), 0.0, 1.0)
            .unwrap();
        let rows = chk.into_rows("milling", stock.h);
        let shank = rows.iter().find(|r| r.tool_part.as_deref() == Some("shank")
            && r.target_kind.as_deref() == Some("stock")).unwrap();
        assert_eq!(shank.component, "remaining-stock");
        assert_eq!(shank.state, "intersecting");
        assert_eq!(shank.first_pose_index, Some(0));
    }

    #[test]
    fn query_budget_exhaustion_is_a_clear_failure() {
        let r = req("t", 4.0, vec![[10.0, 4.0], [20.0, 4.0]], Some(0.5));
        let a = ToolAssembly::validate(&r, 2.0, 5.0).unwrap();
        let stock = Stock::cylinder(5.0, 0.0, 20.0, 1.0, 1 << 20).unwrap();
        let tip = Point3::new(30.0, 0.0, 10.0);
        let fixtures = vec![
            fixture("sh", [36.0, -0.5, 9.5], [37.0, 0.5, 10.5]),
            fixture("ho", [45.0, -1.0, 9.0], [46.0, 1.0, 11.0]),
        ];
        let mut budget = QueryBudget::new(1);
        let mut chk = AssemblyChecker::new(&a, &fixtures, &mut budget).unwrap();
        let e = chk
            .check_step(0, 1, &tip, &axis_x(), &stock, &Progress::quiet(), 0.0, 1.0)
            .unwrap_err();
        match e {
            Fail::Message(m) => assert!(m.contains("maxCollisionQueries"), "{m}"),
            _ => panic!("expected a budget refusal"),
        }
    }

    #[test]
    fn cancellation_covers_assembly_collision() {
        extern "C" fn cancel_cb(_ctx: *mut std::ffi::c_void, _f: f64, phase: *const std::ffi::c_char) -> i32 {
            let p = unsafe { std::ffi::CStr::from_ptr(phase) }.to_string_lossy();
            if p == "assembly-collision" { 1 } else { 0 }
        }
        let json = r#"{
            "formatVersion": 1,
            "stock": {"radiusMM": 12, "zMinMM": 0, "zMaxMM": 40, "resolutionMM": 1},
            "milling": {"enabled": true, "angleDegrees": 0, "widthMM": 4, "depthMM": 2,
                        "startZMM": 18, "endZMM": 26, "toolRadiusMM": 2, "toolLengthMM": 15},
            "millingAssembly": {"formatVersion": 1, "name": "t", "shankDiameterMM": 4,
                                "holderProfile": [[25, 3], [35, 3]], "clearanceMM": 0.5}
        }"#;
        let progress = Progress::new(Some(cancel_cb), std::ptr::null_mut());
        match crate::core::run_core(json, &progress) {
            Err(Fail::Cancelled) => {}
            other => panic!("expected cancellation, got {:?}", other.map(|r| r.ok)),
        }
    }

    #[test]
    fn negative_cutter_dims_rejected_in_ac_branch_without_fixtures() {
        let json = r#"{
            "formatVersion": 1,
            "stock": {"radiusMM": 12, "zMinMM": 0, "zMaxMM": 40, "resolutionMM": 1},
            "milling": {"enabled": false, "angleDegrees": 0, "widthMM": 4, "depthMM": 2,
                        "startZMM": 0, "endZMM": 1, "toolRadiusMM": -2, "toolLengthMM": -6},
            "acMotion": {"start": [0,0,60,20,-170], "end": [0,0,60,40,170],
                         "toolLengthMM": 40, "steps": 8}
        }"#;
        let progress = Progress::quiet();
        let e = crate::core::run_core(json, &progress).unwrap_err();
        match e {
            Fail::Message(m) => assert!(m.contains("finite and positive"), "{m}"),
            _ => panic!("expected a cutter-dimension refusal"),
        }
    }

    #[test]
    fn ac_fk_pose_drives_assembly_query() {
        // Real A/C FK pose: [1,2,3,A=90,C=0] gauge 0 -> tip (1,3,-2), axis +Y.
        let engine = crate::ac::BoundedAC::new(crate::ac::Machine {
            tool_length_mm: 0.0,
            ..Default::default()
        }).unwrap();
        let (tip, axis) = engine.forward([1.0, 2.0, 3.0, 90.0, 0.0]).unwrap();
        let tip = Point3::from(tip);
        let axis = Unit::new_normalize(Vector3::from(axis));
        assert!((axis.y - 1.0).abs() < 1e-12);
        let r = req("t", 4.0, vec![[10.0, 4.0], [20.0, 4.0]], Some(0.5));
        let a = ToolAssembly::validate(&r, 2.0, 5.0).unwrap();
        let stock = Stock::cylinder(5.0, 0.0, 20.0, 1.0, 1 << 20).unwrap();
        // Holder spans y 13..23 around the line x=1,z=-2: this box is inside.
        let fixtures = vec![fixture("ho", [0.0, 14.0, -3.0], [2.0, 16.0, -1.0])];
        let mut budget = QueryBudget::new(500_000);
        let mut chk = AssemblyChecker::new(&a, &fixtures, &mut budget).unwrap();
        chk.check_step(3, 7, &tip, &axis, &stock, &Progress::quiet(), 0.0, 1.0)
            .unwrap();
        let rows = chk.into_rows("ac", stock.h);
        let holder = rows.iter().find(|r| r.tool_part.as_deref() == Some("holder")
            && r.operation.as_deref() == Some("ac")).unwrap();
        assert_eq!(holder.state, "intersecting");
        assert_eq!(holder.first_pose_index, Some(3));
        assert!(budget.parry_calls > 0);
    }

    #[test]
    fn old_input_without_assembly_keeps_r1_behavior() {
        let json = r#"{
            "formatVersion": 1,
            "stock": {"radiusMM": 12, "zMinMM": 0, "zMaxMM": 40, "resolutionMM": 1},
            "milling": {"enabled": true, "angleDegrees": 0, "widthMM": 4, "depthMM": 2,
                        "startZMM": 18, "endZMM": 26, "toolRadiusMM": 2, "toolLengthMM": 15},
            "fixtures": [{"id": "chuck", "minMM": [-15,-15,-8], "maxMM": [15,15,-2]}],
            "budget": {"maxCells": 131072, "maxPoses": 12000, "maxTriangles": 180000}
        }"#;
        let progress = Progress::quiet();
        let out = crate::core::run_core(json, &progress).unwrap();
        assert!(out.ok);
        assert!(out.assembly_query_count.is_none());
        assert!(!out.backend.contains("tool-assembly-r2"));
        assert!(out.warnings.iter().any(|w| w.contains("millingAssembly absent")));
        assert!(out.collisions.iter().all(|c| c.state != "clearance"));
        assert!(out.collisions.iter().all(|c| c.tool_part.as_deref() == Some("cutter")
            || c.tool_part.as_deref() == Some("turningNose")));
        assert!(out.collisions.iter().any(|c| c.component == "chuck"));
        // milling still removed its slot
        let slot = out.stages.iter().find(|s| s.name == "milling-slot").unwrap();
        assert!(slot.removed_mm3 > 0.0);
    }

    #[test]
    fn milling_assembly_mid_motion_counterexample_via_core() {
        // Holder-only probe (x 35.5..36.5) crossed only by intermediate slab
        // poses: end poses prove nothing was erased; firstPoseIndex is the
        // per-operation milling pose index of the first hit (zc 19.5 -> 1).
        let json = r#"{
            "formatVersion": 1,
            "stock": {"radiusMM": 12, "zMinMM": 0, "zMaxMM": 40, "resolutionMM": 1},
            "milling": {"enabled": true, "angleDegrees": 0, "widthMM": 4, "depthMM": 2,
                        "startZMM": 18, "endZMM": 26, "toolRadiusMM": 2, "toolLengthMM": 15},
            "fixtures": [{"id": "holder-probe", "minMM": [35.5,-0.5,21.7], "maxMM": [36.5,0.5,22.3]}],
            "millingAssembly": {"formatVersion": 1, "name": "probe-tool", "shankDiameterMM": 4,
                                "holderProfile": [[25, 3], [35, 3]], "clearanceMM": 0.5},
            "budget": {"maxCells": 131072, "maxPoses": 12000, "maxTriangles": 180000,
                       "maxCollisionQueries": 500000}
        }"#;
        let progress = Progress::quiet();
        let out = crate::core::run_core(json, &progress).unwrap();
        assert!(out.ok);
        let count = out.assembly_query_count.expect("assemblyQueryCount must exist");
        assert!(count > 0);
        let holder = out.collisions.iter()
            .find(|c| c.tool_part.as_deref() == Some("holder") && c.component == "holder-probe")
            .unwrap();
        assert_eq!(holder.state, "intersecting");
        assert_eq!(holder.first_pose_index, Some(1));
        assert_eq!(holder.operation.as_deref(), Some("milling"));
        // cutter never reaches the probe
        let cutter = out.collisions.iter()
            .find(|c| c.tool_part.as_deref() == Some("cutter") && c.component == "holder-probe")
            .unwrap();
        assert_eq!(cutter.state, "clear");
        // required row set exists: shank+holder vs probe and vs remaining stock
        let shank_stock = out.collisions.iter()
            .find(|c| c.tool_part.as_deref() == Some("shank") && c.component == "remaining-stock")
            .unwrap();
        assert_eq!(shank_stock.target_kind.as_deref(), Some("stock"));
        assert_eq!(shank_stock.state, "clear");
        let holder_stock = out.collisions.iter()
            .find(|c| c.tool_part.as_deref() == Some("holder") && c.component == "remaining-stock")
            .unwrap();
        assert_eq!(holder_stock.state, "clear");
    }

    #[test]
    fn ac_assembly_reports_required_rows_and_query_count() {
        let json = r#"{
            "formatVersion": 1,
            "stock": {"radiusMM": 16, "zMinMM": -2, "zMaxMM": 8, "resolutionMM": 1},
            "milling": {"enabled": false, "angleDegrees": 0, "widthMM": 4, "depthMM": 2,
                        "startZMM": 0, "endZMM": 1, "toolRadiusMM": 2, "toolLengthMM": 6},
            "fixtures": [{"id": "chuck", "minMM": [-15,-15,-8], "maxMM": [15,15,-2]}],
            "acMotion": {"start": [10,0,40,20,-170], "end": [10,0,40,40,170],
                         "toolLengthMM": 40, "steps": 160},
            "millingAssembly": {"formatVersion": 1, "name": "ac-tool", "shankDiameterMM": 4,
                                "holderProfile": [[8, 3], [38, 3]], "clearanceMM": 0.5}
        }"#;
        let progress = Progress::quiet();
        let out = crate::core::run_core(json, &progress).unwrap();
        assert!(out.ok);
        assert_eq!(out.ac_poses.as_ref().unwrap().len(), 161);
        let count = out.assembly_query_count.expect("assemblyQueryCount must exist");
        assert!(count > 0);
        for part in ["shank", "holder"] {
            let row = out.collisions.iter()
                .find(|c| c.tool_part.as_deref() == Some(part)
                    && c.component == "remaining-stock"
                    && c.operation.as_deref() == Some("ac"))
                .expect("stock row");
            assert!(["clear", "clearance", "intersecting", "uncertain"].contains(&row.state.as_str()));
        }
        // every assembly row is tagged with the ac operation
        assert!(out.collisions.iter()
            .filter(|c| c.tool_part.as_deref().map(|p| p == "shank" || p == "holder").unwrap_or(false))
            .all(|c| c.operation.as_deref() == Some("ac")));
        // states are never conflated into a blanket clear for the holder vs
        // the chuck fixture: whatever the verdict, it must be a real state.
        let holder_chuck = out.collisions.iter()
            .find(|c| c.tool_part.as_deref() == Some("holder") && c.component == "chuck");
        if let Some(row) = holder_chuck {
            assert!(["clear", "clearance", "intersecting", "uncertain"].contains(&row.state.as_str()));
        }
    }

    #[test]
    fn budget_field_bounds_are_enforced() {
        let base = r#"{
            "formatVersion": 1,
            "stock": {"radiusMM": 12, "zMinMM": 0, "zMaxMM": 40, "resolutionMM": 1},
            "milling": {"enabled": true, "angleDegrees": 0, "widthMM": 4, "depthMM": 2,
                        "startZMM": 18, "endZMM": 26, "toolRadiusMM": 2, "toolLengthMM": 15}
        }"#;
        let progress = Progress::quiet();
        // over ceiling
        let over = base.replace("\"milling\":", "\"budget\": {\"maxCollisionQueries\": 500001}, \"milling\":");
        match crate::core::run_core(&over, &progress).unwrap_err() {
            Fail::Message(m) => assert!(m.contains("maxCollisionQueries"), "{m}"),
            _ => panic!("expected a budget refusal"),
        }
        // zero is out of range too
        let zero = base.replace("\"milling\":", "\"budget\": {\"maxCollisionQueries\": 0}, \"milling\":");
        match crate::core::run_core(&zero, &progress).unwrap_err() {
            Fail::Message(m) => assert!(m.contains("maxCollisionQueries"), "{m}"),
            _ => panic!("expected a budget refusal"),
        }
    }

    #[test]
    fn zero_pose_operation_still_reports_checked_scope() {
        // Slot range lies inside the stock but every slab there is empty
        // after turning: zero milling poses, yet the seeded row set exists.
        let json = r#"{
            "formatVersion": 1,
            "stock": {"radiusMM": 12, "zMinMM": 0, "zMaxMM": 40, "resolutionMM": 1},
            "profile": [[12, 0], [12, 40]],
            "turning": {"enabled": true},
            "turningPlan": {"ok": true, "paths": [
                {"kind": "rough", "points": [[0, 40], [0, 0]]}
            ]},
            "milling": {"enabled": true, "angleDegrees": 0, "widthMM": 4, "depthMM": 2,
                        "startZMM": 18, "endZMM": 26, "toolRadiusMM": 2, "toolLengthMM": 15},
            "millingAssembly": {"formatVersion": 1, "name": "t", "shankDiameterMM": 4,
                                "holderProfile": [[25, 3], [35, 3]], "clearanceMM": 0.5}
        }"#;
        let progress = Progress::quiet();
        let out = crate::core::run_core(json, &progress).unwrap();
        assert!(out.ok);
        assert!(out.assembly_query_count.is_some());
        // seeded rows for shank and holder vs remaining-stock exist even with
        // zero milling poses
        assert!(out.collisions.iter().any(|c| c.tool_part.as_deref() == Some("shank")
            && c.component == "remaining-stock"));
        assert!(out.collisions.iter().any(|c| c.tool_part.as_deref() == Some("holder")
            && c.component == "remaining-stock"));
    }

    #[test]
    fn default_budget_is_applied() {
        let b: BudgetReq = serde_json::from_str("{}").unwrap();
        assert_eq!(b.max_collision_queries, 500_000);
    }
}
