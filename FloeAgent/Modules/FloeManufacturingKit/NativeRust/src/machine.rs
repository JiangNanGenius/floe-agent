// SPDX-License-Identifier: MIT OR Apache-2.0
// R5 generalized bounded machine-axis-chain/body collision query
// (CONTRACT.md r5/2026-11-05, INTERFACES.md, API_SCHEMA.json in the r5
// native-worker evidence directory).
//
// What this IS:
//  * Explicit serial parent-ID axis chains (linear/revolute, per-joint
//    pivot/frame, rigid base frame, explicit units, closed travel limits,
//    unwrapped multi-turn revolute windows), forward kinematics only.
//  * Identified solid bodies (box/cylinder/capsule or bounded triangle mesh)
//    attached to axis frames, plus static world fixtures; collision checks of
//    query-selected pairs (default: every distinct pair minus permitted
//    intentional contacts) at adaptively sampled discrete poses using the
//    actual pinned Parry3d 0.17.6 shape queries.
//  * Synchronized simultaneous moved joints (common-t interpolation) with
//    held non-moving jointPositions; forward-transform output per sample for
//    world tool paths.
//
// What this is NOT: no generic IK, no continuous sweep certification (motion
// between samples is not certified), no machine-safety guarantee. The
// existing verified A/C chain (ac.rs/kinematics) and all R1-R4 strategies
// are untouched by this module.
//
// Honesty policy (unchanged from R2/R4): unknown geometry kinds and corrupt
// structure fail the request explicitly; Parry query errors never become
// clear (per-pair incomplete/uncertain); collision-query budget exhaustion
// is a clear task failure, never a silent skip; AABB prefilter separations
// consume no budget.
use std::collections::BTreeMap;

use nalgebra::{Isometry3, Point3, Translation3, Unit, UnitQuaternion, Vector3};
use parry3d::query;
use parry3d::shape::{Capsule, Cuboid, Cylinder, Shape, TriMesh};
use serde::{Deserialize, Serialize};

use crate::collision::QueryBudget;
use crate::{Fail, Progress};

const NAME_MAX_BYTES: usize = 256;
const MAX_AXES: usize = 32;
const MAX_BODIES_AND_FIXTURES: usize = 64;
const MAX_PAIR_LIST: usize = 512;
const MAX_MOTIONS: usize = 8;
const MAX_MESH_VERTICES: usize = 65_536;
const MAX_MESH_TRIANGLES: usize = 131_072;
const MAX_MESH_COORD_MM: f64 = 1e6;
const AXIS_ORIGIN_MAX_MM: f64 = 10_000.0;
const LINEAR_TRAVEL_MAX_MM: f64 = 10_000.0;
const REVOLUTE_TRAVEL_MAX_DEG: f64 = 36_000.0;
const BASIS_TOLERANCE: f64 = 1e-6;

const MAX_SAMPLES_DEFAULT: u64 = 512;
const MAX_SAMPLES_CEILING: u64 = 4096;
const MAX_COLLISION_QUERIES_DEFAULT: u64 = 50_000;
const MAX_COLLISION_QUERIES_CEILING: u64 = 500_000;
const CLEARANCE_MAX_MM: f64 = 100.0;
const SAMPLE_SPACING_DEFAULT_MM: f64 = 1.0;
const MAX_ROTATION_DEFAULT_DEG: f64 = 15.0;

pub const SCOPE_STRING: &str =
    "discrete-sampled-poses-only; continuous sweep between samples not claimed; FK only, no IK";

// ---- request types (camelCase JSON) -----------------------------------------

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MachineQueryRequest {
    pub format_version: u32,
    pub chain: MachineChainReq,
    #[serde(default)]
    pub bodies: Vec<MachineBodyReq>,
    #[serde(default)]
    pub fixtures: Vec<MachineBodyReq>,
    /// Legacy single-motion convenience (exclusive with `motions`).
    #[serde(default)]
    pub motion: Option<MotionReq>,
    /// Synchronized simultaneous moved joints (exclusive with `motion`).
    #[serde(default)]
    pub motions: Option<Vec<MotionReq>>,
    /// Held non-moving joint positions {axisId: value}.
    #[serde(default)]
    pub joint_positions: Option<BTreeMap<String, f64>>,
    /// Permitted intentional contacts: EXCLUDED from evaluation.
    #[serde(rename = "allowedContactPairs", default)]
    pub allowed_contact_pairs: Option<Vec<[String; 2]>>,
    /// Explicit pair selection to check (default: all minus allowed).
    #[serde(rename = "queryPairs", default)]
    pub query_pairs: Option<Vec<[String; 2]>>,
    #[serde(default)]
    pub budget: Option<MachineBudgetReq>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MachineChainReq {
    #[serde(default = "default_chain_version")]
    pub format_version: u32,
    #[serde(default)]
    pub base_frame: Option<FrameReq>,
    #[serde(default)]
    pub axes: Vec<AxisReq>,
}

fn default_chain_version() -> u32 {
    1
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FrameReq {
    #[serde(rename = "originMM")]
    pub origin_mm: [f64; 3],
    #[serde(rename = "xDirection")]
    pub x_direction: [f64; 3],
    #[serde(rename = "zDirection")]
    pub z_direction: [f64; 3],
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AxisReq {
    pub id: String,
    pub kind: String,
    #[serde(default)]
    pub parent: Option<String>,
    #[serde(rename = "originMM", default)]
    pub origin_mm: Option<[f64; 3]>,
    #[serde(default)]
    pub axis: Option<[f64; 3]>,
    #[serde(rename = "limitsMM", default)]
    pub limits_mm: Option<[f64; 2]>,
    #[serde(rename = "limitsDeg", default)]
    pub limits_deg: Option<[f64; 2]>,
    #[serde(default)]
    pub units: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AttachReq {
    pub axis: String,
    #[serde(default)]
    pub frame: Option<FrameReq>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MachineBodyReq {
    pub id: String,
    #[serde(rename = "resourceID", default)]
    pub resource_id: Option<String>,
    pub shape: ShapeReq,
    #[serde(default)]
    pub attach: Option<AttachReq>,
    #[serde(default)]
    pub frame: Option<FrameReq>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShapeReq {
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(rename = "halfExtentsMM", default)]
    pub half_extents_mm: Option<[f64; 3]>,
    #[serde(rename = "radiusMM", default)]
    pub radius_mm: Option<f64>,
    #[serde(rename = "lengthMM", default)]
    pub length_mm: Option<f64>,
    #[serde(default)]
    pub vertices: Option<Vec<[f64; 3]>>,
    #[serde(default)]
    pub triangles: Option<Vec<[u32; 3]>>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MotionReq {
    pub joint: String,
    #[serde(rename = "fromDeg", default)]
    pub from_deg: Option<f64>,
    #[serde(rename = "toDeg", default)]
    pub to_deg: Option<f64>,
    #[serde(rename = "fromMM", default)]
    pub from_mm: Option<f64>,
    #[serde(rename = "toMM", default)]
    pub to_mm: Option<f64>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MachineBudgetReq {
    #[serde(rename = "maxSamples", default)]
    pub max_samples: Option<u64>,
    #[serde(rename = "maxCollisionQueries", default)]
    pub max_collision_queries: Option<u64>,
    #[serde(rename = "clearanceMM", default)]
    pub clearance_mm: Option<f64>,
    #[serde(rename = "sampleSpacingMM", default)]
    pub sample_spacing_mm: Option<f64>,
    #[serde(rename = "maxRotationDegPerSample", default)]
    pub max_rotation_deg_per_sample: Option<f64>,
}

// ---- result types ------------------------------------------------------------

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RigidFrameOut {
    #[serde(rename = "originMM")]
    pub origin_mm: [f64; 3],
    #[serde(rename = "xDirection")]
    pub x_direction: [f64; 3],
    #[serde(rename = "yDirection")]
    pub y_direction: [f64; 3],
    #[serde(rename = "zDirection")]
    pub z_direction: [f64; 3],
}

impl RigidFrameOut {
    fn from_iso(iso: &Isometry3<f64>) -> Self {
        let m = iso.rotation.to_rotation_matrix();
        let col = |j: usize| [m[(0, j)], m[(1, j)], m[(2, j)]];
        let t = iso.translation.vector;
        RigidFrameOut {
            origin_mm: [t.x, t.y, t.z],
            x_direction: col(0),
            y_direction: col(1),
            z_direction: col(2),
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IdFrameOut {
    pub id: String,
    #[serde(rename = "resourceID", skip_serializing_if = "Option::is_none")]
    pub resource_id: Option<String>,
    pub frame: RigidFrameOut,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PoseOut {
    pub t: f64,
    /// All axis values at this sample (moved interpolated verbatim,
    /// positioned held, all others 0). Unit per axis kind.
    pub joint_values: BTreeMap<String, f64>,
    pub axes: Vec<IdFrameOut>,
    pub bodies: Vec<IdFrameOut>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MotionOut {
    pub joint: String,
    #[serde(rename = "fromDeg", skip_serializing_if = "Option::is_none")]
    pub from_deg: Option<f64>,
    #[serde(rename = "toDeg", skip_serializing_if = "Option::is_none")]
    pub to_deg: Option<f64>,
    #[serde(rename = "fromMM", skip_serializing_if = "Option::is_none")]
    pub from_mm: Option<f64>,
    #[serde(rename = "toMM", skip_serializing_if = "Option::is_none")]
    pub to_mm: Option<f64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum PairState {
    /// Definite intersection at >=1 evaluated sample (earliest reported).
    Intersecting,
    /// No intersection; min gap < clearanceMM; every planned sample evaluated.
    Clearance,
    /// No intersection; every planned sample evaluated; gap >= clearance.
    Clear,
    /// No intersection found but >=1 planned sample uncertifiable (Parry error).
    Incomplete,
    /// No sample certifiable at all; never a clear.
    Uncertain,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairOut {
    pub a: String,
    pub b: String,
    pub state: PairState,
    pub scope: String,
    /// Planned pose evaluations for this pair (n+1 for dynamic pairs, 1 for
    /// pose-independent static-static pairs).
    pub samples_planned: u64,
    pub samples_evaluated: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_sample: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_time: Option<f64>,
    /// Joint values (all axes) at the first intersecting sample.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_joint_values: Option<BTreeMap<String, f64>>,
    #[serde(rename = "penetrationDepthMM", skip_serializing_if = "Option::is_none")]
    pub penetration_depth_mm: Option<f64>,
    #[serde(rename = "minimumGapMM", skip_serializing_if = "Option::is_none")]
    pub minimum_gap_mm: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transform_a: Option<RigidFrameOut>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transform_b: Option<RigidFrameOut>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExcludedPairOut {
    pub a: String,
    pub b: String,
    pub reason: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MachineResult {
    pub ok: bool,
    pub backend: String,
    pub scope: String,
    pub motions: Vec<MotionOut>,
    /// Held non-moved joint positions actually applied.
    pub joint_positions: BTreeMap<String, f64>,
    pub samples_planned: u64,
    pub samples_evaluated: u64,
    pub parry_calls: u64,
    pub poses: Vec<PoseOut>,
    pub fixtures: Vec<IdFrameOut>,
    pub excluded_pairs: Vec<ExcludedPairOut>,
    pub pairs: Vec<PairOut>,
    pub warnings: Vec<String>,
}

// ---- validated internal model -------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AxisKind {
    Linear,
    Revolute,
}

struct VAxis {
    id: String,
    kind: AxisKind,
    parent: Option<usize>,
    origin: Vector3<f64>,
    axis: Unit<Vector3<f64>>,
    limits: [f64; 2],
}

enum VShape {
    Box {
        half: Vector3<f64>,
    },
    Cylinder {
        radius: f64,
        length: f64,
    },
    Capsule {
        radius: f64,
        length: f64,
    },
    Mesh {
        vertices: Vec<Point3<f32>>,
        indices: Vec<[u32; 3]>,
    },
}

struct VBody {
    id: String,
    resource_id: Option<String>,
    /// Axis index when dynamic; None = static world body.
    attach: Option<usize>,
    /// Rigid local frame: in the attach axis frame, or world frame when static.
    local: Isometry3<f64>,
    shape: VShape,
    /// Axis-aligned local bounds (f64, body frame, closed).
    local_min: [f64; 3],
    local_max: [f64; 3],
}

impl VShape {
    fn validate(req: &ShapeReq, body_id: &str) -> Result<VShape, Fail> {
        let need = |v: Option<f64>, what: &str| -> Result<f64, Fail> {
            v.filter(|x| x.is_finite() && *x > 0.0).ok_or_else(|| {
                Fail::Message(format!(
                    "machine-query: body '{body_id}' shape requires finite positive {what}"
                ))
            })
        };
        match req.kind.as_str() {
            "box" => {
                let he = req.half_extents_mm.ok_or_else(|| {
                    Fail::Message(format!(
                        "machine-query: body '{body_id}' box requires halfExtentsMM"
                    ))
                })?;
                if !he.iter().all(|v| v.is_finite() && *v > 0.0) {
                    return Err(Fail::Message(format!(
                        "machine-query: body '{body_id}' box halfExtentsMM must be finite and positive"
                    )));
                }
                Ok(VShape::Box {
                    half: Vector3::from(he),
                })
            }
            "cylinder" => Ok(VShape::Cylinder {
                radius: need(req.radius_mm, "radiusMM")?,
                length: need(req.length_mm, "lengthMM")?,
            }),
            "capsule" => Ok(VShape::Capsule {
                radius: need(req.radius_mm, "radiusMM")?,
                length: need(
                    req.length_mm,
                    "lengthMM (cylindrical section; overall = length + 2*radius)",
                )?,
            }),
            "mesh" => {
                let vertices = req.vertices.as_ref().ok_or_else(|| {
                    Fail::Message(format!(
                        "machine-query: body '{body_id}' mesh requires vertices"
                    ))
                })?;
                let triangles = req.triangles.as_ref().ok_or_else(|| {
                    Fail::Message(format!(
                        "machine-query: body '{body_id}' mesh requires triangles"
                    ))
                })?;
                if vertices.len() < 3 || vertices.len() > MAX_MESH_VERTICES {
                    return Err(Fail::Message(format!(
                        "machine-query: body '{body_id}' mesh needs 3...{MAX_MESH_VERTICES} vertices"
                    )));
                }
                if triangles.is_empty() || triangles.len() > MAX_MESH_TRIANGLES {
                    return Err(Fail::Message(format!(
                        "machine-query: body '{body_id}' mesh needs 1...{MAX_MESH_TRIANGLES} triangles"
                    )));
                }
                let mut pts = Vec::with_capacity(vertices.len());
                for v in vertices {
                    if !v.iter().all(|x| x.is_finite()) || v.iter().any(|x| x.abs() > MAX_MESH_COORD_MM)
                    {
                        return Err(Fail::Message(format!(
                            "machine-query: body '{body_id}' mesh has non-finite or unbounded vertex"
                        )));
                    }
                    pts.push(Point3::new(v[0] as f32, v[1] as f32, v[2] as f32));
                }
                for t in triangles {
                    if t.iter().any(|&i| i as usize >= vertices.len()) {
                        return Err(Fail::Message(format!(
                            "machine-query: body '{body_id}' mesh triangle index out of range"
                        )));
                    }
                }
                Ok(VShape::Mesh {
                    vertices: pts,
                    indices: triangles.clone(),
                })
            }
            other => Err(Fail::Message(format!(
                "machine-query: body '{body_id}' has unknown geometry type '{other}' (expected box|cylinder|capsule|mesh)"
            ))),
        }
    }

    /// Body-local bounds (closed), body frame. Cylinders/capsules are +Z
    /// aligned in body frame; Parry cylinders map +Y internally.
    fn local_bounds(&self) -> ([f64; 3], [f64; 3]) {
        match self {
            VShape::Box { half } => ([-half.x, -half.y, -half.z], [half.x, half.y, half.z]),
            VShape::Cylinder { radius, length } => {
                let (r, h) = (*radius, *length * 0.5);
                ([-r, -r, -h], [r, r, h])
            }
            VShape::Capsule { radius, length } => {
                let (r, h) = (*radius, *length * 0.5 + *radius);
                ([-r, -r, -h], [r, r, h])
            }
            VShape::Mesh { vertices, .. } => {
                let mut mn = [f64::INFINITY; 3];
                let mut mx = [f64::NEG_INFINITY; 3];
                for p in vertices {
                    for k in 0..3 {
                        let v = p[k] as f64;
                        mn[k] = mn[k].min(v);
                        mx[k] = mx[k].max(v);
                    }
                }
                (mn, mx)
            }
        }
    }

    fn parry(&self) -> Box<dyn Shape> {
        match self {
            VShape::Box { half } => Box::new(Cuboid::new(half.cast())),
            VShape::Cylinder { radius, length } => {
                Box::new(Cylinder::new((*length as f32) * 0.5, *radius as f32))
            }
            VShape::Capsule { radius, length } => {
                let h = (*length as f32) * 0.5;
                Box::new(Capsule::new(
                    Point3::new(0.0, 0.0, -h),
                    Point3::new(0.0, 0.0, h),
                    *radius as f32,
                ))
            }
            VShape::Mesh { vertices, indices } => {
                Box::new(TriMesh::new(vertices.clone(), indices.clone()))
            }
        }
    }

    /// Extra body-frame pose mapping the Parry primitive into the documented
    /// body-frame convention (+Z aligned cylinders).
    fn local_shape_pose(&self) -> Isometry3<f32> {
        match self {
            VShape::Cylinder { .. } => Isometry3::from_parts(
                Translation3::identity(),
                UnitQuaternion::rotation_between(&Vector3::y(), &Vector3::z())
                    .unwrap_or_else(UnitQuaternion::identity),
            ),
            _ => Isometry3::identity(),
        }
    }
}

/// Validate a rigid frame request: finite, orthonormal within tolerance.
fn frame_from(req: &FrameReq, what: &str) -> Result<Isometry3<f64>, Fail> {
    let o = req.origin_mm;
    let x = Vector3::from(req.x_direction);
    let z = Vector3::from(req.z_direction);
    if !o.iter().all(|v| v.is_finite())
        || !x.iter().all(|v| v.is_finite())
        || !z.iter().all(|v| v.is_finite())
    {
        return Err(Fail::Message(format!(
            "machine-query: {what} frame must be finite"
        )));
    }
    let (xn, zn) = (x.norm(), z.norm());
    if (xn - 1.0).abs() > BASIS_TOLERANCE || (zn - 1.0).abs() > BASIS_TOLERANCE {
        return Err(Fail::Message(format!(
            "machine-query: {what} frame directions must be unit within {BASIS_TOLERANCE}"
        )));
    }
    let (xu, zu) = (x / xn, z / zn);
    if xu.dot(&zu).abs() > BASIS_TOLERANCE {
        return Err(Fail::Message(format!(
            "machine-query: {what} frame xDirection/zDirection must be orthogonal within {BASIS_TOLERANCE}"
        )));
    }
    let y = zu.cross(&xu);
    let rot = nalgebra::Rotation3::from_basis_unchecked(&[xu, y, zu]);
    Ok(Isometry3::from_parts(
        Translation3::from(Vector3::from(o)),
        UnitQuaternion::from_rotation_matrix(&rot),
    ))
}

fn check_id(id: &str, what: &str) -> Result<(), Fail> {
    if id.is_empty() || id.len() > NAME_MAX_BYTES {
        return Err(Fail::Message(format!(
            "machine-query: {what} id must be 1...{NAME_MAX_BYTES} bytes"
        )));
    }
    Ok(())
}

struct Validated {
    base: Isometry3<f64>,
    axes: Vec<VAxis>,
    /// Axis id -> index.
    axis_index: BTreeMap<String, usize>,
    bodies: Vec<VBody>,
    /// body/fixture id -> index into `bodies`.
    id_index: BTreeMap<String, usize>,
    motions: Vec<MotionSpec>,
    joint_positions: BTreeMap<String, f64>,
    excluded_pairs: Vec<(String, String)>,
    query_pairs: Option<Vec<(String, String)>>,
    clearance_mm: f64,
    max_samples: u64,
    max_collision_queries: u64,
    sample_spacing_mm: f64,
    max_rotation_deg_per_sample: f64,
}

struct MotionSpec {
    axis: usize,
    kind: AxisKind,
    from: f64,
    to: f64,
}

fn pair_key<'a>(a: &'a str, b: &'a str) -> (&'a str, &'a str) {
    if a < b {
        (a, b)
    } else {
        (b, a)
    }
}

fn validate_pair_list(
    list: &[[String; 2]],
    what: &str,
    id_index: &BTreeMap<String, usize>,
) -> Result<Vec<(String, String)>, Fail> {
    if list.len() > MAX_PAIR_LIST {
        return Err(Fail::Message(format!(
            "machine-query: {what} exceeds {MAX_PAIR_LIST} entries"
        )));
    }
    let mut seen: Vec<(&str, &str)> = Vec::with_capacity(list.len());
    for pair in list {
        let (a, b) = (pair[0].as_str(), pair[1].as_str());
        if a == b {
            return Err(Fail::Message(format!(
                "machine-query: {what} contains a self pair '{a}'"
            )));
        }
        if !id_index.contains_key(a) || !id_index.contains_key(b) {
            return Err(Fail::Message(format!(
                "machine-query: {what} references unknown body/fixture id [{a}, {b}]"
            )));
        }
        let key = pair_key(a, b);
        if seen.contains(&key) {
            return Err(Fail::Message(format!(
                "machine-query: {what} contains duplicate pair [{a}, {b}]"
            )));
        }
        seen.push(key);
    }
    Ok(list.iter().map(|p| (p[0].clone(), p[1].clone())).collect())
}

fn validate(req: &MachineQueryRequest) -> Result<Validated, Fail> {
    if req.format_version != 1 {
        return Err(Fail::Message(
            "machine-query: formatVersion must be 1".into(),
        ));
    }
    if req.chain.format_version != 1 {
        return Err(Fail::Message(
            "machine-query: chain.formatVersion must be 1".into(),
        ));
    }
    let base = match &req.chain.base_frame {
        Some(f) => frame_from(f, "chain.baseFrame")?,
        None => Isometry3::identity(),
    };

    // ---- axes: serial parent-ID chain ---------------------------------------
    if req.chain.axes.len() > MAX_AXES {
        return Err(Fail::Message(format!(
            "machine-query: chain exceeds {MAX_AXES} axes"
        )));
    }
    let mut axes: Vec<VAxis> = Vec::with_capacity(req.chain.axes.len());
    let mut axis_index: BTreeMap<String, usize> = BTreeMap::new();
    for (i, a) in req.chain.axes.iter().enumerate() {
        check_id(&a.id, "axis")?;
        if axis_index.insert(a.id.clone(), i).is_some() {
            return Err(Fail::Message(format!(
                "machine-query: duplicate axis id '{}'",
                a.id
            )));
        }
        let kind = match a.kind.as_str() {
            "linear" => AxisKind::Linear,
            "revolute" => AxisKind::Revolute,
            other => {
                return Err(Fail::Message(format!(
                    "machine-query: axis '{}' has unknown kind '{other}' (expected linear|revolute)",
                    a.id
                )))
            }
        };
        if let Some(u) = &a.units {
            let expected = match kind {
                AxisKind::Linear => "mm",
                AxisKind::Revolute => "deg",
            };
            if u != expected {
                return Err(Fail::Message(format!(
                    "machine-query: axis '{}' units must be '{expected}' for its kind",
                    a.id
                )));
            }
        }
        // Serial chain: the parent must be declared strictly earlier (or be the
        // base frame), so cycles and forward references are rejected by
        // construction.
        let parent = match a.parent.as_deref() {
            None | Some("base") => None,
            Some(p) => match axis_index.get(p) {
                Some(&pi) if pi < i => Some(pi),
                Some(_) => {
                    return Err(Fail::Message(format!(
                        "machine-query: axis '{}' parent '{p}' must be declared BEFORE it (serial chain; cycles are rejected by construction)",
                        a.id
                    )))
                }
                None => {
                    return Err(Fail::Message(format!(
                        "machine-query: axis '{}' references unknown parent '{p}'; parents must be declared BEFORE their children",
                        a.id
                    )))
                }
            },
        };
        let origin = Vector3::from(a.origin_mm.unwrap_or([0.0; 3]));
        if !origin.iter().all(|v| v.is_finite())
            || origin.iter().any(|v| v.abs() > AXIS_ORIGIN_MAX_MM)
        {
            return Err(Fail::Message(format!(
                "machine-query: axis '{}' originMM must be finite within +/-{AXIS_ORIGIN_MAX_MM}",
                a.id
            )));
        }
        let axis_vec = Vector3::from(a.axis.ok_or_else(|| {
            Fail::Message(format!(
                "machine-query: axis '{}' requires a joint axis vector",
                a.id
            ))
        })?);
        if !axis_vec.iter().all(|v| v.is_finite()) || axis_vec.norm() < 1e-12 {
            return Err(Fail::Message(format!(
                "machine-query: axis '{}' joint axis must be finite and nonzero",
                a.id
            )));
        }
        let limits = match kind {
            AxisKind::Linear => {
                let l = a.limits_mm.ok_or_else(|| {
                    Fail::Message(format!(
                        "machine-query: linear axis '{}' requires limitsMM",
                        a.id
                    ))
                })?;
                if !l.iter().all(|v| v.is_finite())
                    || l[0] > l[1]
                    || l.iter().any(|v| v.abs() > LINEAR_TRAVEL_MAX_MM)
                {
                    return Err(Fail::Message(format!(
                        "machine-query: linear axis '{}' limitsMM must be finite, ordered, within +/-{LINEAR_TRAVEL_MAX_MM}",
                        a.id
                    )));
                }
                l
            }
            AxisKind::Revolute => {
                let l = a.limits_deg.ok_or_else(|| {
                    Fail::Message(format!(
                        "machine-query: revolute axis '{}' requires limitsDeg",
                        a.id
                    ))
                })?;
                if !l.iter().all(|v| v.is_finite())
                    || l[0] > l[1]
                    || l.iter().any(|v| v.abs() > REVOLUTE_TRAVEL_MAX_DEG)
                {
                    return Err(Fail::Message(format!(
                        "machine-query: revolute axis '{}' limitsDeg must be finite, ordered, within +/-{REVOLUTE_TRAVEL_MAX_DEG} (unwrapped multi-turn windows allowed)",
                        a.id
                    )));
                }
                l
            }
        };
        axes.push(VAxis {
            id: a.id.clone(),
            kind,
            parent,
            origin,
            axis: Unit::new_normalize(axis_vec),
            limits,
        });
    }

    // ---- bodies + fixtures ----------------------------------------------------
    let total = req.bodies.len() + req.fixtures.len();
    if total > MAX_BODIES_AND_FIXTURES {
        return Err(Fail::Message(format!(
            "machine-query: bodies+fixtures exceed {MAX_BODIES_AND_FIXTURES}"
        )));
    }
    if total < 2 {
        return Err(Fail::Message(
            "machine-query: at least two bodies/fixtures are required for a collision query"
                .into(),
        ));
    }
    let mut bodies: Vec<VBody> = Vec::with_capacity(total);
    let mut id_index: BTreeMap<String, usize> = BTreeMap::new();
    for (b, is_fixture) in req
        .bodies
        .iter()
        .map(|b| (b, false))
        .chain(req.fixtures.iter().map(|f| (f, true)))
    {
        check_id(&b.id, if is_fixture { "fixture" } else { "body" })?;
        if id_index.contains_key(&b.id) {
            return Err(Fail::Message(format!(
                "machine-query: duplicate body/fixture id '{}'",
                b.id
            )));
        }
        let shape = VShape::validate(&b.shape, &b.id)?;
        let (local_min, local_max) = shape.local_bounds();
        let local = match &b.attach {
            Some(at) => {
                if b.frame.is_some() {
                    return Err(Fail::Message(format!(
                        "machine-query: body '{}' supplies both attach and frame; frame is only valid for static bodies (dynamic bodies use attach.frame)",
                        b.id
                    )));
                }
                if !axis_index.contains_key(&at.axis) {
                    return Err(Fail::Message(format!(
                        "machine-query: body '{}' attaches to unknown axis '{}'",
                        b.id, at.axis
                    )));
                }
                match &at.frame {
                    Some(f) => frame_from(f, &format!("body '{}' attach", b.id))?,
                    None => Isometry3::identity(),
                }
            }
            None => match &b.frame {
                Some(f) => frame_from(f, &format!("body '{}'", b.id))?,
                None => {
                    return Err(Fail::Message(format!(
                        "machine-query: body '{}' requires attach.axis (dynamic) or frame (static world body)",
                        b.id
                    )))
                }
            },
        };
        let attach = b
            .attach
            .as_ref()
            .and_then(|at| axis_index.get(&at.axis).copied());
        id_index.insert(b.id.clone(), bodies.len());
        bodies.push(VBody {
            id: b.id.clone(),
            resource_id: b.resource_id.clone(),
            attach,
            local,
            shape,
            local_min,
            local_max,
        });
    }

    // ---- motions / jointPositions ---------------------------------------------
    let raw_motions: Vec<MotionReq> = match (&req.motion, &req.motions) {
        (Some(_), Some(_)) => {
            return Err(Fail::Message(
                "machine-query: motion and motions are exclusive; supply exactly one".into(),
            ))
        }
        (Some(m), None) => vec![m.clone()],
        (None, Some(ms)) => {
            if ms.is_empty() {
                return Err(Fail::Message(
                    "machine-query: motions must not be empty".into(),
                ));
            }
            if ms.len() > MAX_MOTIONS {
                return Err(Fail::Message(format!(
                    "machine-query: motions exceeds {MAX_MOTIONS} synchronized joints"
                )));
            }
            ms.clone()
        }
        (None, None) => {
            return Err(Fail::Message(
                "machine-query: motion (single) or motions (synchronized) is required".into(),
            ))
        }
    };
    let mut moved = Vec::with_capacity(raw_motions.len());
    let mut motions = Vec::with_capacity(raw_motions.len());
    for m in &raw_motions {
        let idx = *axis_index.get(&m.joint).ok_or_else(|| {
            Fail::Message(format!(
                "machine-query: motion references unknown joint '{}'",
                m.joint
            ))
        })?;
        if moved.contains(&idx) {
            return Err(Fail::Message(format!(
                "machine-query: joint '{}' appears in more than one motion",
                m.joint
            )));
        }
        moved.push(idx);
        let ax = &axes[idx];
        let (from, to) = match ax.kind {
            AxisKind::Linear => {
                if m.from_mm.is_none() || m.to_mm.is_none() {
                    return Err(Fail::Message(format!(
                        "machine-query: linear motion on '{}' requires fromMM/toMM",
                        m.joint
                    )));
                }
                (m.from_mm.unwrap(), m.to_mm.unwrap())
            }
            AxisKind::Revolute => {
                if m.from_deg.is_none() || m.to_deg.is_none() {
                    return Err(Fail::Message(format!(
                        "machine-query: revolute motion on '{}' requires fromDeg/toDeg",
                        m.joint
                    )));
                }
                (m.from_deg.unwrap(), m.to_deg.unwrap())
            }
        };
        if !from.is_finite() || !to.is_finite() {
            return Err(Fail::Message(format!(
                "machine-query: motion on '{}' requires finite endpoints",
                m.joint
            )));
        }
        // Reachability/travel failure: endpoints must lie inside the declared
        // closed travel; values are used verbatim, never wrapped or clipped.
        if from < ax.limits[0] || from > ax.limits[1] || to < ax.limits[0] || to > ax.limits[1] {
            return Err(Fail::Message(format!(
                "machine-query: motion on '{}' travels [{from}, {to}] outside declared limits [{}, {}]; reachability/travel failure, no clipping or wrapping applied",
                m.joint, ax.limits[0], ax.limits[1]
            )));
        }
        motions.push(MotionSpec {
            axis: idx,
            kind: ax.kind,
            from,
            to,
        });
    }
    let mut joint_positions: BTreeMap<String, f64> = BTreeMap::new();
    if let Some(jp) = &req.joint_positions {
        for (id, val) in jp {
            let idx = *axis_index.get(id).ok_or_else(|| {
                Fail::Message(format!(
                    "machine-query: jointPositions references unknown axis '{id}'"
                ))
            })?;
            if moved.contains(&idx) {
                return Err(Fail::Message(format!(
                    "machine-query: jointPositions cannot target moved joint '{id}'"
                )));
            }
            if !val.is_finite() {
                return Err(Fail::Message(format!(
                    "machine-query: jointPositions '{id}' must be finite"
                )));
            }
            let ax = &axes[idx];
            if *val < ax.limits[0] || *val > ax.limits[1] {
                return Err(Fail::Message(format!(
                    "machine-query: jointPositions '{id}' value {val} outside declared travel [{}, {}]",
                    ax.limits[0], ax.limits[1]
                )));
            }
            joint_positions.insert(id.clone(), *val);
        }
    }

    // ---- pair selection ---------------------------------------------------------
    let excluded_pairs = validate_pair_list(
        req.allowed_contact_pairs.as_deref().unwrap_or(&[]),
        "allowedContactPairs",
        &id_index,
    )?;
    let query_pairs = match &req.query_pairs {
        Some(qp) => Some(validate_pair_list(qp, "queryPairs", &id_index)?),
        None => None,
    };
    if let Some(qp) = &query_pairs {
        for p in qp {
            let key = pair_key(&p.0, &p.1);
            if excluded_pairs.iter().any(|e| pair_key(&e.0, &e.1) == key) {
                return Err(Fail::Message(format!(
                    "machine-query: pair [{}, {}] is listed in both allowedContactPairs and queryPairs (contradictory)",
                    p.0, p.1
                )));
            }
        }
    }

    // ---- budget -------------------------------------------------------------------
    let b = req.budget.clone().unwrap_or(MachineBudgetReq {
        max_samples: None,
        max_collision_queries: None,
        clearance_mm: None,
        sample_spacing_mm: None,
        max_rotation_deg_per_sample: None,
    });
    let max_samples = b.max_samples.unwrap_or(MAX_SAMPLES_DEFAULT);
    if !(1..=MAX_SAMPLES_CEILING).contains(&max_samples) {
        return Err(Fail::Message(format!(
            "machine-query: budget.maxSamples must be 1...{MAX_SAMPLES_CEILING}"
        )));
    }
    let max_collision_queries = b
        .max_collision_queries
        .unwrap_or(MAX_COLLISION_QUERIES_DEFAULT);
    if !(1..=MAX_COLLISION_QUERIES_CEILING).contains(&max_collision_queries) {
        return Err(Fail::Message(format!(
            "machine-query: budget.maxCollisionQueries must be 1...{MAX_COLLISION_QUERIES_CEILING}"
        )));
    }
    let clearance_mm = b.clearance_mm.unwrap_or(0.0);
    if !clearance_mm.is_finite() || !(0.0..=CLEARANCE_MAX_MM).contains(&clearance_mm) {
        return Err(Fail::Message(format!(
            "machine-query: budget.clearanceMM must be 0...{CLEARANCE_MAX_MM}"
        )));
    }
    let sample_spacing_mm = b.sample_spacing_mm.unwrap_or(SAMPLE_SPACING_DEFAULT_MM);
    if !sample_spacing_mm.is_finite() || !(0.01..=100.0).contains(&sample_spacing_mm) {
        return Err(Fail::Message(
            "machine-query: budget.sampleSpacingMM must be 0.01...100".into(),
        ));
    }
    let max_rotation = b
        .max_rotation_deg_per_sample
        .unwrap_or(MAX_ROTATION_DEFAULT_DEG);
    if !max_rotation.is_finite() || !(0.05..=180.0).contains(&max_rotation) {
        return Err(Fail::Message(
            "machine-query: budget.maxRotationDegPerSample must be 0.05...180".into(),
        ));
    }

    Ok(Validated {
        base,
        axes,
        axis_index,
        bodies,
        id_index,
        motions,
        joint_positions,
        excluded_pairs,
        query_pairs,
        clearance_mm,
        max_samples,
        max_collision_queries,
        sample_spacing_mm,
        max_rotation_deg_per_sample: max_rotation,
    })
}

// ---- FK -------------------------------------------------------------------------

fn axis_worlds(v: &Validated, q: &[f64]) -> Vec<Isometry3<f64>> {
    let mut worlds: Vec<Isometry3<f64>> = Vec::with_capacity(v.axes.len());
    for (i, ax) in v.axes.iter().enumerate() {
        let parent = ax.parent.map(|p| worlds[p]).unwrap_or(v.base);
        let rotation = match ax.kind {
            AxisKind::Linear => UnitQuaternion::identity(),
            AxisKind::Revolute => UnitQuaternion::from_axis_angle(&ax.axis, q[i].to_radians()),
        };
        let motion = match ax.kind {
            AxisKind::Linear => Translation3::from(ax.axis.as_ref() * q[i]),
            AxisKind::Revolute => Translation3::identity(),
        };
        worlds.push(
            parent
                * Isometry3::from_parts(Translation3::from(ax.origin), rotation)
                * motion,
        );
    }
    worlds
}

fn body_world(b: &VBody, worlds: &[Isometry3<f64>]) -> Isometry3<f64> {
    match b.attach {
        Some(i) => worlds[i] * b.local,
        None => b.local,
    }
}

/// Is `body` in the moved subtree of `axis` (axis itself or a descendant)?
fn in_moved_subtree(v: &Validated, body: &VBody, axis: usize) -> bool {
    let mut at = body.attach;
    while let Some(i) = at {
        if i == axis {
            return true;
        }
        at = v.axes[i].parent;
    }
    false
}

fn world_aabb(iso: &Isometry3<f64>, min: &[f64; 3], max: &[f64; 3]) -> ([f64; 3], [f64; 3]) {
    let mut wmin = [f64::INFINITY; 3];
    let mut wmax = [f64::NEG_INFINITY; 3];
    for &dx in &[min[0], max[0]] {
        for &dy in &[min[1], max[1]] {
            for &dz in &[min[2], max[2]] {
                let p = iso * Point3::new(dx, dy, dz);
                for k in 0..3 {
                    wmin[k] = wmin[k].min(p[k]);
                    wmax[k] = wmax[k].max(p[k]);
                }
            }
        }
    }
    (wmin, wmax)
}

fn q_with_motions(v: &Validated, t: f64) -> Vec<f64> {
    let mut q = vec![0.0; v.axes.len()];
    for (id, val) in &v.joint_positions {
        if let Some(&i) = v.axis_index.get(id) {
            q[i] = *val;
        }
    }
    for m in &v.motions {
        q[m.axis] = m.from + t * (m.to - m.from);
    }
    q
}

/// Bound surface displacement by summing every moved joint's contribution.
/// Nested revolute chains are nonlinear: endpoint radii can both be small
/// while the arm unfolds in between. The descendant-link triangle bound is
/// valid throughout the complete joint interval, including those interiors.
fn sample_segments(v: &Validated) -> Result<u64, Fail> {
    let q0 = q_with_motions(v, 0.0);
    let q1 = q_with_motions(v, 1.0);
    let mut need = 0.0f64;
    for m in &v.motions {
        let delta = (m.to - m.from).abs();
        if delta == 0.0 { continue; }
        match m.kind {
            AxisKind::Linear => need += delta / v.sample_spacing_mm,
            AxisKind::Revolute => {
                let mut r_max = 0.0f64;
                for b in &v.bodies {
                    if b.attach.is_none() || !in_moved_subtree(v, b, m.axis) { continue; }
                    let mut shape_radius = 0.0f64;
                    for &x in &[b.local_min[0], b.local_max[0]] {
                        for &y in &[b.local_min[1], b.local_max[1]] {
                            for &z in &[b.local_min[2], b.local_max[2]] {
                                shape_radius = shape_radius.max(Vector3::new(x,y,z).norm());
                            }
                        }
                    }
                    let mut radius = b.local.translation.vector.norm() + shape_radius;
                    let mut axis = b.attach.unwrap();
                    while axis != m.axis {
                        radius += v.axes[axis].origin.norm();
                        if v.axes[axis].kind == AxisKind::Linear {
                            radius += q0[axis].abs().max(q1[axis].abs());
                        }
                        axis = v.axes[axis].parent.ok_or_else(|| Fail::Message(
                            "machine-query: inconsistent descendant chain".into()))?;
                    }
                    r_max = r_max.max(radius);
                }
                need += r_max * delta.to_radians() / v.sample_spacing_mm;
                need += delta / v.max_rotation_deg_per_sample;
            }
        }
    }
    let n = need.ceil().max(1.0) as u64;
    if n > v.max_samples {
        return Err(Fail::Message(format!(
            "machine-query: cannot cover motion within maxSamples {} (conservative displacement bound needs {n} segments); increase budget.maxSamples or coarsen sampleSpacingMM",
            v.max_samples
        )));
    }
    Ok(n)
}

fn to_f32_iso(iso: &Isometry3<f64>) -> Isometry3<f32> {
    Isometry3::from_parts(
        Translation3::from(iso.translation.vector.cast::<f32>()),
        iso.rotation.cast::<f32>(),
    )
}

// ---- pair accumulation -----------------------------------------------------------

struct PairAcc {
    a: usize,
    b: usize,
    planned: u64,
    evaluated: u64,
    intersecting: bool,
    first_sample: Option<u64>,
    first_time: Option<f64>,
    first_q: Option<Vec<f64>>,
    max_depth: f64,
    min_gap: f64,
    sample_errors: u64,
    clearance_mm: f64,
    transform_a: Option<Isometry3<f64>>,
    transform_b: Option<Isometry3<f64>>,
}

impl PairAcc {
    fn new(a: usize, b: usize, planned: u64, clearance_mm: f64) -> Self {
        PairAcc {
            a,
            b,
            planned,
            evaluated: 0,
            intersecting: false,
            first_sample: None,
            first_time: None,
            first_q: None,
            max_depth: 0.0,
            min_gap: f64::INFINITY,
            sample_errors: 0,
            clearance_mm,
            transform_a: None,
            transform_b: None,
        }
    }

    fn state(&self) -> PairState {
        if self.intersecting {
            PairState::Intersecting
        } else if self.evaluated == 0 {
            PairState::Uncertain
        } else if self.sample_errors > 0 {
            PairState::Incomplete
        } else if self.min_gap < self.clearance_mm {
            PairState::Clearance
        } else {
            PairState::Clear
        }
    }
}

// ---- entry ---------------------------------------------------------------------

pub fn run_machine_query(request_json: &str, progress: &Progress) -> Result<MachineResult, Fail> {
    let req: MachineQueryRequest = serde_json::from_str(request_json)
        .map_err(|e| Fail::Message(format!("invalid machine query request JSON: {e}")))?;
    let v = validate(&req)?;

    let segments = sample_segments(&v)?;

    // Pair selection: explicit queryPairs, else every distinct pair minus the
    // permitted intentional contacts (allowedContactPairs).
    let excluded: Vec<(String, String)> = v.excluded_pairs.clone();
    let pair_list: Vec<(String, String)> = match &v.query_pairs {
        Some(qp) => qp.clone(),
        None => {
            let mut all = Vec::new();
            for i in 0..v.bodies.len() {
                for j in (i + 1)..v.bodies.len() {
                    let (a, b) = (&v.bodies[i].id, &v.bodies[j].id);
                    let key = pair_key(a, b);
                    let is_excluded = excluded.iter().any(|e| pair_key(&e.0, &e.1) == key);
                    if !is_excluded {
                        all.push((a.clone(), b.clone()));
                    }
                }
            }
            all
        }
    };
    let evaluated_pairs: Vec<(usize, usize)> = pair_list
        .iter()
        .map(|(a, b)| (*v.id_index.get(a).unwrap(), *v.id_index.get(b).unwrap()))
        .collect();

    // Per-pair accumulators. Static-static pairs are pose-independent: one
    // evaluation at the first sample.
    let mut accs: Vec<PairAcc> = evaluated_pairs
        .iter()
        .map(|&(ia, ib)| {
            let planned = if v.bodies[ia].attach.is_none() && v.bodies[ib].attach.is_none() {
                1u64
            } else {
                segments + 1
            };
            PairAcc::new(ia, ib, planned, v.clearance_mm)
        })
        .collect();
    let clearance = v.clearance_mm;
    let mut budget = QueryBudget::new(v.max_collision_queries);

    // Parry shapes and local poses, built once.
    let shapes: Vec<(Box<dyn Shape>, Isometry3<f32>)> = v
        .bodies
        .iter()
        .map(|b| (b.shape.parry(), b.shape.local_shape_pose()))
        .collect();

    let mut poses_out: Vec<PoseOut> = Vec::with_capacity(segments as usize + 1);
    let mut warnings: Vec<String> = Vec::new();

    for i in 0..=segments {
        if i % 16 == 0 {
            progress.report(i as f64 / (segments as f64 + 1.0), "machine-query")?;
        }
        let t = i as f64 / segments as f64;
        let q = q_with_motions(&v, t);
        let worlds = axis_worlds(&v, &q);
        let body_isos: Vec<Isometry3<f64>> = v.bodies.iter().map(|b| body_world(b, &worlds)).collect();

        // Forward-transform output for world tool paths.
        let mut joint_values = BTreeMap::new();
        for (k, ax) in v.axes.iter().enumerate() {
            joint_values.insert(ax.id.clone(), q[k]);
        }
        poses_out.push(PoseOut {
            t,
            joint_values,
            axes: v
                .axes
                .iter()
                .enumerate()
                .map(|(k, ax)| IdFrameOut {
                    id: ax.id.clone(),
                    resource_id: None,
                    frame: RigidFrameOut::from_iso(&worlds[k]),
                })
                .collect(),
            bodies: v
                .bodies
                .iter()
                .enumerate()
                .filter(|(_, b)| b.attach.is_some())
                .map(|(k, b)| IdFrameOut {
                    id: b.id.clone(),
                    resource_id: b.resource_id.clone(),
                    frame: RigidFrameOut::from_iso(&body_isos[k]),
                })
                .collect(),
        });

        for acc in accs.iter_mut() {
            if i >= acc.planned {
                continue;
            }
            let (ia, ib) = (acc.a, acc.b);
            let a_iso = &body_isos[ia];
            let b_iso = &body_isos[ib];
            let (amin, amax) = world_aabb(a_iso, &v.bodies[ia].local_min, &v.bodies[ia].local_max);
            let (bmin, bmax) = world_aabb(b_iso, &v.bodies[ib].local_min, &v.bodies[ib].local_max);
            // Conservative single-axis AABB separation (a lower bound on the
            // true shape gap). A sample is provably non-intersecting AND
            // provably outside clearance only when the separation reaches the
            // clearance; such samples certify without a Parry call.
            let mut sep = 0.0f64;
            for k in 0..3 {
                sep = sep.max(amin[k] - bmax[k]).max(bmin[k] - amax[k]);
            }
            if clearance > 0.0 && sep >= clearance {
                acc.evaluated += 1;
                continue;
            }
            budget.take_parry().map_err(Fail::Message)?;
            let pose_a = to_f32_iso(a_iso) * shapes[ia].1;
            let pose_b = to_f32_iso(b_iso) * shapes[ib].1;
            match query::intersection_test(&pose_a, &*shapes[ia].0, &pose_b, &*shapes[ib].0) {
                Ok(true) => {
                    if !acc.intersecting {
                        acc.intersecting = true;
                        acc.first_sample = Some(i);
                        acc.first_time = Some(t);
                        acc.first_q = Some(q.clone());
                        acc.transform_a = Some(*a_iso);
                        acc.transform_b = Some(*b_iso);
                    }
                    budget.take_parry().map_err(Fail::Message)?;
                    match query::contact(&pose_a, &*shapes[ia].0, &pose_b, &*shapes[ib].0, 0.0) {
                        Ok(Some(c)) => {
                            acc.max_depth = acc.max_depth.max((-c.dist).max(0.0) as f64);
                        }
                        Ok(None) => {}
                        Err(_) => acc.sample_errors += 1,
                    }
                }
                Ok(false) => {
                    // A TriMesh is queried as a triangle surface. No triangle
                    // crossing cannot exclude a solid wholly contained inside
                    // a closed mesh (nor prove an arbitrary mesh is watertight).
                    // AABB-overlapping mesh pairs therefore remain unresolved.
                    if matches!(&v.bodies[ia].shape, VShape::Mesh { .. })
                        || matches!(&v.bodies[ib].shape, VShape::Mesh { .. }) {
                        acc.sample_errors += 1;
                    }
                    if clearance > 0.0 {
                        budget.take_parry().map_err(Fail::Message)?;
                        match query::contact(
                            &pose_a,
                            &*shapes[ia].0,
                            &pose_b,
                            &*shapes[ib].0,
                            clearance as f32,
                        ) {
                            Ok(Some(c)) => {
                                let gap = (c.dist as f64).max(0.0);
                                acc.min_gap = acc.min_gap.min(gap);
                            }
                            Ok(None) => {
                                // gap > clearance at this sample: record the
                                // clearance as an upper bound placeholder.
                                acc.min_gap = acc.min_gap.min(clearance);
                            }
                            Err(_) => acc.sample_errors += 1,
                        }
                    } else {
                        // No gap claim with clearanceMM = 0.
                        acc.min_gap = 0.0;
                    }
                }
                Err(_) => acc.sample_errors += 1,
            }
            acc.evaluated += 1;
        }
    }

    let parry_calls = budget.parry_calls;
    let pairs_out: Vec<PairOut> = accs
        .into_iter()
        .map(|acc| {
            let state = acc.state();
            let scope = match state {
                PairState::Intersecting => format!(
                    "intersection certified at {} evaluated pose(s); discrete poses only",
                    acc.evaluated
                ),
                PairState::Clear => format!(
                    "all {} planned pose evaluations completed; certified clear at sampled poses only",
                    acc.planned
                ),
                PairState::Clearance => format!(
                    "all {} planned pose evaluations completed; minimum gap below clearance",
                    acc.planned
                ),
                PairState::Incomplete => format!(
                    "{} of {} planned pose evaluations completed; errored samples cannot be certified, never clear",
                    acc.evaluated, acc.planned
                ),
                PairState::Uncertain => {
                    "no pose could be certified (queries unsupported/errored); never clear"
                        .to_string()
                }
            };
            let first_joint_values = acc.first_q.map(|q| {
                let mut m = BTreeMap::new();
                for (k, ax) in v.axes.iter().enumerate() {
                    m.insert(ax.id.clone(), q[k]);
                }
                m
            });
            PairOut {
                a: v.bodies[acc.a].id.clone(),
                b: v.bodies[acc.b].id.clone(),
                state,
                scope,
                samples_planned: acc.planned,
                samples_evaluated: acc.evaluated,
                first_sample: acc.first_sample,
                first_time: acc.first_time,
                first_joint_values,
                penetration_depth_mm: if state == PairState::Intersecting {
                    Some(acc.max_depth)
                } else {
                    None
                },
                minimum_gap_mm: if state == PairState::Clearance {
                    Some(acc.min_gap)
                } else {
                    None
                },
                transform_a: acc.transform_a.map(|iso| RigidFrameOut::from_iso(&iso)),
                transform_b: acc.transform_b.map(|iso| RigidFrameOut::from_iso(&iso)),
            }
        })
        .collect();

    let motions_out: Vec<MotionOut> = v
        .motions
        .iter()
        .map(|m| {
            let ax = &v.axes[m.axis];
            match ax.kind {
                AxisKind::Linear => MotionOut {
                    joint: ax.id.clone(),
                    from_deg: None,
                    to_deg: None,
                    from_mm: Some(m.from),
                    to_mm: Some(m.to),
                },
                AxisKind::Revolute => MotionOut {
                    joint: ax.id.clone(),
                    from_deg: Some(m.from),
                    to_deg: Some(m.to),
                    from_mm: None,
                    to_mm: None,
                },
            }
        })
        .collect();

    if clearance == 0.0 {
        warnings.push(
            "machine-query: clearanceMM = 0; no gap distance queries were run and minimumGapMM is not reported (budget saved)"
                .into(),
        );
    }
    if v.bodies.iter().any(|b| matches!(&b.shape, VShape::Mesh { .. })) {
        warnings.push("Mesh bodies use triangle-surface queries. Without a separate closed-solid containment proof, AABB-overlapping samples with no surface hit remain uncertain/incomplete, never clear.".into());
    }

    progress.report(1.0, "machine-query")?;
    Ok(MachineResult {
        ok: true,
        backend: format!("{} + machine-query-r5", crate::model::backend_string()),
        scope: SCOPE_STRING.to_string(),
        motions: motions_out,
        joint_positions: v.joint_positions.clone(),
        samples_planned: segments,
        samples_evaluated: segments,
        parry_calls,
        poses: poses_out,
        fixtures: v
            .bodies
            .iter()
            .filter(|b| b.attach.is_none())
            .map(|b| IdFrameOut {
                id: b.id.clone(),
                resource_id: b.resource_id.clone(),
                frame: RigidFrameOut::from_iso(&b.local),
            })
            .collect(),
        excluded_pairs: excluded
            .into_iter()
            .map(|(a, b)| ExcludedPairOut {
                a,
                b,
                reason: "allowed-contact".to_string(),
            })
            .collect(),
        pairs: pairs_out,
        warnings,
    })
}

// ---- tests ---------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{c_char, c_void};

    fn run(json: &str) -> Result<MachineResult, Fail> {
        run_machine_query(json, &Progress::quiet())
    }

    /// Rotary C sweep: arm endpoints are clear of the fixture, but the arm
    /// crosses it mid-arc. Endpoints alone must not certify this motion.
    /// The arm box spans radially [0,20] via an attach-frame offset.
    const SWEEP_REQUEST: &str = r#"{
        "formatVersion": 1,
        "chain": { "formatVersion": 1, "axes": [
            {"id": "c", "kind": "revolute", "parent": null, "axis": [0, 0, 1], "limitsDeg": [-360, 360]}
        ]},
        "bodies": [
            {"id": "arm", "attach": {"axis": "c", "frame": {"originMM": [10, 0, 0], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]}},
             "shape": {"type": "box", "halfExtentsMM": [10, 1, 1]}}
        ],
        "fixtures": [
            {"id": "block", "frame": {"originMM": [10, -12, 0], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]},
             "shape": {"type": "box", "halfExtentsMM": [2, 2, 2]}}
        ],
        "motion": {"joint": "c", "fromDeg": 0, "toDeg": -90},
        "budget": {"sampleSpacingMM": 0.5, "maxRotationDegPerSample": 5.0}
    }"#;

    #[test]
    fn contained_box_in_closed_mesh_cannot_be_reported_clear() {
        let request = r#"{
          "formatVersion":1,
          "chain":{"axes":[{"id":"x","kind":"linear","axis":[1,0,0],"limitsMM":[-1,1]}]},
          "bodies":[
            {"id":"inner","attach":{"axis":"x"},"shape":{"type":"box","halfExtentsMM":[0.25,0.25,0.25]}},
            {"id":"shell","frame":{"originMM":[0,0,0],"xDirection":[1,0,0],"zDirection":[0,0,1]},
             "shape":{"type":"mesh",
               "vertices":[[-2,-2,-2],[2,-2,-2],[2,2,-2],[-2,2,-2],[-2,-2,2],[2,-2,2],[2,2,2],[-2,2,2]],
               "triangles":[[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],[1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]]}}
          ],
          "motion":{"joint":"x","fromMM":0,"toMM":0.1}
        }"#;
        let result = run(request).unwrap();
        assert_eq!(result.pairs.len(),1);
        assert_ne!(result.pairs[0].state,PairState::Clear,
                   "lack of triangle crossings cannot certify solid containment clear");
        assert_ne!(result.pairs[0].state,PairState::Clearance);
    }

    #[test]
    fn endpoints_clear_but_intermediate_collides() {
        let r = run(SWEEP_REQUEST).unwrap();
        assert_eq!(r.pairs.len(), 1);
        let p = &r.pairs[0];
        assert_eq!(p.state, PairState::Intersecting);
        let first = p.first_sample.expect("first sample");
        assert!(
            first > 0 && first < r.samples_planned,
            "mid-motion hit; endpoints alone are insufficient"
        );
        let t = p.first_time.unwrap();
        assert!(t > 0.0 && t < 1.0);
        assert!(p.penetration_depth_mm.unwrap() > 0.0);
        assert!(p.transform_a.is_some() && p.transform_b.is_some());
        assert!(p.first_joint_values.as_ref().unwrap().contains_key("c"));
    }

    #[test]
    fn clearance_is_distinguished_from_intersection() {
        // Linear approach: the tool stops 0.5mm short of the vice; with
        // clearanceMM = 1.0 the pair must report clearance, never
        // intersecting, and minimumGapMM must be the measured 0.5mm.
        let json = r#"{
            "formatVersion": 1,
            "chain": { "formatVersion": 1, "axes": [
                {"id": "x", "kind": "linear", "parent": null, "axis": [1, 0, 0], "limitsMM": [-100, 100]}
            ]},
            "bodies": [
                {"id": "tool", "attach": {"axis": "x"}, "shape": {"type": "box", "halfExtentsMM": [2, 2, 2]}}
            ],
            "fixtures": [
                {"id": "vice", "frame": {"originMM": [9.5, 0, 0], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]},
                 "shape": {"type": "box", "halfExtentsMM": [2, 2, 2]}}
            ],
            "motion": {"joint": "x", "fromMM": 0, "toMM": 5},
            "budget": {"clearanceMM": 1.0, "sampleSpacingMM": 0.25}
        }"#;
        let r = run(json).unwrap();
        let p = &r.pairs[0];
        assert_eq!(p.state, PairState::Clearance);
        let gap = p.minimum_gap_mm.unwrap();
        assert!(gap > 0.2 && gap < 1.0, "measured gap {gap}");
    }

    #[test]
    fn clear_when_every_sample_evaluated() {
        let json = r#"{
            "formatVersion": 1,
            "chain": { "formatVersion": 1, "axes": [
                {"id": "c", "kind": "revolute", "parent": null, "axis": [0, 0, 1], "limitsDeg": [-360, 360]}
            ]},
            "bodies": [
                {"id": "arm", "attach": {"axis": "c", "frame": {"originMM": [10, 0, 0], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]}},
                 "shape": {"type": "box", "halfExtentsMM": [10, 1, 1]}}
            ],
            "fixtures": [
                {"id": "block", "frame": {"originMM": [10, -25, 0], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]},
                 "shape": {"type": "box", "halfExtentsMM": [2, 2, 2]}}
            ],
            "motion": {"joint": "c", "fromDeg": -20, "toDeg": 20},
            "budget": {"clearanceMM": 1.0, "sampleSpacingMM": 0.2, "maxRotationDegPerSample": 2.0}
        }"#;
        let r = run(json).unwrap();
        let p = &r.pairs[0];
        assert_eq!(p.state, PairState::Clear);
        assert_eq!(p.samples_evaluated, p.samples_planned);
        // AABB separation distance proves every clearance without Parry calls.
        assert_eq!(r.parry_calls, 0);
    }

    #[test]
    fn multi_turn_joint_never_wrapped() {
        let json = r#"{
            "formatVersion": 1,
            "chain": { "formatVersion": 1, "axes": [
                {"id": "c", "kind": "revolute", "parent": null, "axis": [0, 0, 1], "limitsDeg": [-1080, 1080]}
            ]},
            "bodies": [
                {"id": "probe", "attach": {"axis": "c", "frame": {"originMM": [50, 0, 0], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]}},
                 "shape": {"type": "box", "halfExtentsMM": [50, 5, 5]}}
            ],
            "fixtures": [
                {"id": "sensor", "frame": {"originMM": [0, 70, 0], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]},
                 "shape": {"type": "box", "halfExtentsMM": [10, 10, 10]}}
            ],
            "motion": {"joint": "c", "fromDeg": 0, "toDeg": 720},
            "budget": {"sampleSpacingMM": 40.0, "maxRotationDegPerSample": 45.0}
        }"#;
        let r = run(json).unwrap();
        assert_eq!(r.poses.first().unwrap().joint_values["c"], 0.0);
        assert_eq!(r.poses.last().unwrap().joint_values["c"], 720.0);
        // Quarter pose must be a half-turn, not a wrapped shortest arc.
        let quarter = &r.poses[r.poses.len() / 4];
        assert!((quarter.joint_values["c"] - 180.0).abs() < 1e-9);
        let probe_frame = quarter.bodies.iter().find(|b| b.id == "probe").unwrap();
        assert!((probe_frame.frame.x_direction[0] + 1.0).abs() < 1e-6);
        assert!(probe_frame.frame.x_direction[1].abs() < 1e-6);
        // The probe passes the sensor twice over two turns.
        assert_eq!(r.pairs[0].state, PairState::Intersecting);
    }

    #[test]
    fn invalid_parent_cycle_and_unknown_parent_fail() {
        let later_parent = r#"{
            "formatVersion": 1,
            "chain": { "formatVersion": 1, "axes": [
                {"id": "a", "kind": "revolute", "parent": "b", "axis": [0, 0, 1], "limitsDeg": [-10, 10]},
                {"id": "b", "kind": "revolute", "parent": null, "axis": [0, 0, 1], "limitsDeg": [-10, 10]}
            ]},
            "bodies": [
                {"id": "p", "frame": {"originMM": [0,0,0], "xDirection": [1,0,0], "zDirection": [0,0,1]}, "shape": {"type": "box", "halfExtentsMM": [1,1,1]}},
                {"id": "q", "frame": {"originMM": [5,0,0], "xDirection": [1,0,0], "zDirection": [0,0,1]}, "shape": {"type": "box", "halfExtentsMM": [1,1,1]}}
            ],
            "fixtures": [],
            "motion": {"joint": "b", "fromDeg": 0, "toDeg": 1}
        }"#;
        match run(later_parent) {
            Err(Fail::Message(m)) => assert!(m.contains("BEFORE")),
            other => panic!("expected serial-chain failure, got {other:?}"),
        }
        let self_parent = r#"{
            "formatVersion": 1,
            "chain": { "formatVersion": 1, "axes": [
                {"id": "a", "kind": "revolute", "parent": "a", "axis": [0, 0, 1], "limitsDeg": [-10, 10]}
            ]},
            "bodies": [
                {"id": "p", "frame": {"originMM": [0,0,0], "xDirection": [1,0,0], "zDirection": [0,0,1]}, "shape": {"type": "box", "halfExtentsMM": [1,1,1]}},
                {"id": "q", "frame": {"originMM": [5,0,0], "xDirection": [1,0,0], "zDirection": [0,0,1]}, "shape": {"type": "box", "halfExtentsMM": [1,1,1]}}
            ],
            "fixtures": [],
            "motion": {"joint": "a", "fromDeg": 0, "toDeg": 1}
        }"#;
        assert!(matches!(run(self_parent), Err(Fail::Message(_))));
        let unknown_parent = r#"{
            "formatVersion": 1,
            "chain": { "formatVersion": 1, "axes": [
                {"id": "a", "kind": "revolute", "parent": "ghost", "axis": [0, 0, 1], "limitsDeg": [-10, 10]}
            ]},
            "bodies": [
                {"id": "p", "frame": {"originMM": [0,0,0], "xDirection": [1,0,0], "zDirection": [0,0,1]}, "shape": {"type": "box", "halfExtentsMM": [1,1,1]}},
                {"id": "q", "frame": {"originMM": [5,0,0], "xDirection": [1,0,0], "zDirection": [0,0,1]}, "shape": {"type": "box", "halfExtentsMM": [1,1,1]}}
            ],
            "fixtures": [],
            "motion": {"joint": "a", "fromDeg": 0, "toDeg": 1}
        }"#;
        match run(unknown_parent) {
            Err(Fail::Message(m)) => assert!(m.contains("unknown parent")),
            other => panic!("expected unknown-parent failure, got {other:?}"),
        }
    }

    #[test]
    fn out_of_travel_motion_is_a_reachability_failure() {
        let json = r#"{
            "formatVersion": 1,
            "chain": { "formatVersion": 1, "axes": [
                {"id": "c", "kind": "revolute", "parent": null, "axis": [0, 0, 1], "limitsDeg": [-180, 180]}
            ]},
            "bodies": [
                {"id": "p", "frame": {"originMM": [0,0,0], "xDirection": [1,0,0], "zDirection": [0,0,1]}, "shape": {"type": "box", "halfExtentsMM": [1,1,1]}},
                {"id": "q", "frame": {"originMM": [5,0,0], "xDirection": [1,0,0], "zDirection": [0,0,1]}, "shape": {"type": "box", "halfExtentsMM": [1,1,1]}}
            ],
            "fixtures": [],
            "motion": {"joint": "c", "fromDeg": 0, "toDeg": 400}
        }"#;
        match run(json) {
            Err(Fail::Message(m)) => assert!(m.contains("travel")),
            other => panic!("expected travel failure, got {other:?}"),
        }
    }

    #[test]
    fn cannot_cover_motion_within_sample_cap_fails() {
        let json = r#"{
            "formatVersion": 1,
            "chain": { "formatVersion": 1, "axes": [
                {"id": "c", "kind": "revolute", "parent": null, "axis": [0, 0, 1], "limitsDeg": [-36000, 36000]}
            ]},
            "bodies": [
                {"id": "arm", "attach": {"axis": "c"}, "shape": {"type": "box", "halfExtentsMM": [80, 8, 8]}},
                {"id": "q", "frame": {"originMM": [500,0,0], "xDirection": [1,0,0], "zDirection": [0,0,1]}, "shape": {"type": "box", "halfExtentsMM": [1,1,1]}}
            ],
            "fixtures": [],
            "motion": {"joint": "c", "fromDeg": 0, "toDeg": 3600},
            "budget": {"maxSamples": 64, "sampleSpacingMM": 1.0, "maxRotationDegPerSample": 180.0}
        }"#;
        match run(json) {
            Err(Fail::Message(m)) => {
                assert!(m.contains("cannot cover") && m.contains("maxSamples"))
            }
            other => panic!("expected cannot-cover failure, got {other:?}"),
        }
    }

    #[test]
    fn collision_query_budget_exhaustion_fails_explicitly() {
        let json = r#"{
            "formatVersion": 1,
            "chain": { "formatVersion": 1, "axes": [
                {"id": "x", "kind": "linear", "parent": null, "axis": [1, 0, 0], "limitsMM": [-1000, 1000]}
            ]},
            "bodies": [
                {"id": "tool", "attach": {"axis": "x"}, "shape": {"type": "box", "halfExtentsMM": [2, 2, 2]}}
            ],
            "fixtures": [
                {"id": "vice", "frame": {"originMM": [5, 0, 0], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]},
                 "shape": {"type": "box", "halfExtentsMM": [10, 10, 10]}}
            ],
            "motion": {"joint": "x", "fromMM": 0, "toMM": 10},
            "budget": {"maxCollisionQueries": 3, "sampleSpacingMM": 0.5}
        }"#;
        match run(json) {
            Err(Fail::Message(m)) => assert!(m.contains("maxCollisionQueries")),
            other => panic!("expected budget failure, got {other:?}"),
        }
    }

    extern "C" fn cancel_everything(
        _ctx: *mut c_void,
        _fraction: f64,
        _phase: *const c_char,
    ) -> i32 {
        1
    }

    #[test]
    fn cancellation_propagates_as_cancelled() {
        let raw = Progress::new(Some(cancel_everything), std::ptr::null_mut());
        match run_machine_query(SWEEP_REQUEST, &raw) {
            Err(Fail::Cancelled) => {}
            other => panic!("expected cancellation, got {other:?}"),
        }
    }

    #[test]
    fn unknown_geometry_and_units_fail() {
        let bad_shape = r#"{
            "formatVersion": 1,
            "chain": { "formatVersion": 1, "axes": [
                {"id": "c", "kind": "revolute", "parent": null, "axis": [0, 0, 1], "limitsDeg": [-10, 10]}
            ]},
            "bodies": [
                {"id": "b1", "attach": {"axis": "c"}, "shape": {"type": "torus", "radiusMM": 5}},
                {"id": "b2", "frame": {"originMM": [50,0,0], "xDirection": [1,0,0], "zDirection": [0,0,1]}, "shape": {"type": "box", "halfExtentsMM": [1,1,1]}}
            ],
            "fixtures": [],
            "motion": {"joint": "c", "fromDeg": 0, "toDeg": 1}
        }"#;
        match run(bad_shape) {
            Err(Fail::Message(m)) => assert!(m.contains("unknown geometry")),
            other => panic!("expected unknown-geometry failure, got {other:?}"),
        }
        let bad_units = r#"{
            "formatVersion": 1,
            "chain": { "formatVersion": 1, "axes": [
                {"id": "c", "kind": "revolute", "parent": null, "axis": [0, 0, 1], "limitsDeg": [-10, 10], "units": "radians"}
            ]},
            "bodies": [
                {"id": "p", "frame": {"originMM": [0,0,0], "xDirection": [1,0,0], "zDirection": [0,0,1]}, "shape": {"type": "box", "halfExtentsMM": [1,1,1]}},
                {"id": "q", "frame": {"originMM": [5,0,0], "xDirection": [1,0,0], "zDirection": [0,0,1]}, "shape": {"type": "box", "halfExtentsMM": [1,1,1]}}
            ],
            "fixtures": [],
            "motion": {"joint": "c", "fromDeg": 0, "toDeg": 1}
        }"#;
        match run(bad_units) {
            Err(Fail::Message(m)) => assert!(m.contains("units")),
            other => panic!("expected units failure, got {other:?}"),
        }
    }

    #[test]
    fn mesh_body_intersects_and_corrupt_mesh_fails() {
        let tetra = r#"{
            "formatVersion": 1,
            "chain": { "formatVersion": 1, "axes": [
                {"id": "x", "kind": "linear", "parent": null, "axis": [1, 0, 0], "limitsMM": [-100, 100]}
            ]},
            "bodies": [
                {"id": "wedge", "attach": {"axis": "x"}, "shape": {
                    "type": "mesh",
                    "vertices": [[0,0,0],[10,0,0],[0,10,0],[0,0,10]],
                    "triangles": [[0,2,1],[0,1,3],[0,3,2],[1,2,3]]
                }}
            ],
            "fixtures": [
                {"id": "plate", "frame": {"originMM": [6, 0, 0], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]},
                 "shape": {"type": "box", "halfExtentsMM": [2, 20, 20]}}
            ],
            "motion": {"joint": "x", "fromMM": -5, "toMM": 5},
            "budget": {"sampleSpacingMM": 1.0}
        }"#;
        let r = run(tetra).unwrap();
        assert_eq!(r.pairs[0].state, PairState::Intersecting);

        let corrupt = r#"{
            "formatVersion": 1,
            "chain": { "formatVersion": 1, "axes": [
                {"id": "x", "kind": "linear", "parent": null, "axis": [1, 0, 0], "limitsMM": [-100, 100]}
            ]},
            "bodies": [
                {"id": "wedge", "attach": {"axis": "x"}, "shape": {
                    "type": "mesh",
                    "vertices": [[0,0,0],[10,0,0],[0,10,0]],
                    "triangles": [[0,1,9]]
                }},
                {"id": "plate", "frame": {"originMM": [6, 0, 0], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]}, "shape": {"type": "box", "halfExtentsMM": [2, 20, 20]}}
            ],
            "fixtures": [],
            "motion": {"joint": "x", "fromMM": -5, "toMM": 5}
        }"#;
        match run(corrupt) {
            Err(Fail::Message(m)) => assert!(m.contains("out of range")),
            other => panic!("expected corrupt-mesh failure, got {other:?}"),
        }
    }

    #[test]
    fn allowed_pairs_are_excluded_and_reported() {
        // The arm sweeps THROUGH the hub volume, but the pair is a permitted
        // intentional contact: excluded from evaluation and reported.
        let json = r#"{
            "formatVersion": 1,
            "chain": { "formatVersion": 1, "axes": [
                {"id": "c", "kind": "revolute", "parent": null, "axis": [0, 0, 1], "limitsDeg": [-360, 360]}
            ]},
            "bodies": [
                {"id": "arm", "attach": {"axis": "c", "frame": {"originMM": [10, 0, 0], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]}},
                 "shape": {"type": "box", "halfExtentsMM": [10, 1, 1]}}
            ],
            "fixtures": [
                {"id": "hub", "frame": {"originMM": [5, 0, 0], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]},
                 "shape": {"type": "box", "halfExtentsMM": [3, 3, 3]}},
                {"id": "ground", "frame": {"originMM": [0, 0, -50], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]},
                 "shape": {"type": "box", "halfExtentsMM": [200, 200, 5]}}
            ],
            "motion": {"joint": "c", "fromDeg": 0, "toDeg": -90},
            "allowedContactPairs": [["arm", "hub"]],
            "budget": {"sampleSpacingMM": 0.5}
        }"#;
        let r = run(json).unwrap();
        assert!(r.pairs.iter().all(|p| p.a != "arm" || p.b != "hub"));
        assert_eq!(r.excluded_pairs.len(), 1);
        assert_eq!(r.excluded_pairs[0].reason, "allowed-contact");
        assert_eq!(r.excluded_pairs[0].a, "arm");
        assert_eq!(r.excluded_pairs[0].b, "hub");
        // arm vs ground is still checked by default and clear.
        let ground = r.pairs.iter().find(|p| p.a == "arm" && p.b == "ground").unwrap();
        assert_eq!(ground.state, PairState::Clear);
    }

    #[test]
    fn query_pairs_restrict_and_contradiction_fails() {
        let json = r#"{
            "formatVersion": 1,
            "chain": { "formatVersion": 1, "axes": [
                {"id": "c", "kind": "revolute", "parent": null, "axis": [0, 0, 1], "limitsDeg": [-360, 360]}
            ]},
            "bodies": [
                {"id": "arm", "attach": {"axis": "c", "frame": {"originMM": [10, 0, 0], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]}},
                 "shape": {"type": "box", "halfExtentsMM": [10, 1, 1]}},
                {"id": "other", "attach": {"axis": "c"}, "shape": {"type": "box", "halfExtentsMM": [1, 1, 10]}}
            ],
            "fixtures": [
                {"id": "block", "frame": {"originMM": [10, -12, 0], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]},
                 "shape": {"type": "box", "halfExtentsMM": [2, 2, 2]}}
            ],
            "motion": {"joint": "c", "fromDeg": 0, "toDeg": -90},
            "queryPairs": [["other", "block"]],
            "budget": {"sampleSpacingMM": 0.5}
        }"#;
        let r = run(json).unwrap();
        assert_eq!(r.pairs.len(), 1);
        assert!(r.pairs[0].a == "other" || r.pairs[0].b == "other");

        let contradictory = json.replace(
            "\"queryPairs\": [[\"other\", \"block\"]]",
            "\"queryPairs\": [[\"other\", \"block\"]], \"allowedContactPairs\": [[\"block\", \"other\"]]",
        );
        match run(&contradictory) {
            Err(Fail::Message(m)) => assert!(m.contains("contradictory")),
            other => panic!("expected contradictory-pair failure, got {other:?}"),
        }
    }

    #[test]
    fn synchronized_motions_interpolate_at_common_t() {
        // c sweeps the arm through the block while y sinks the whole arm by
        // 8mm; both joints interpolate linearly at the SAME t and the
        // crossing is still found mid-motion (endpoints are clear).
        let json = r#"{
            "formatVersion": 1,
            "chain": { "formatVersion": 1, "axes": [
                {"id": "y", "kind": "linear", "parent": null, "axis": [0, 1, 0], "limitsMM": [-500, 500]},
                {"id": "c", "kind": "revolute", "parent": "y", "axis": [0, 0, 1], "limitsDeg": [-360, 360]}
            ]},
            "bodies": [
                {"id": "arm", "attach": {"axis": "c", "frame": {"originMM": [10, 0, 0], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]}},
                 "shape": {"type": "box", "halfExtentsMM": [10, 1, 1]}}
            ],
            "fixtures": [
                {"id": "block", "frame": {"originMM": [10, -12, 0], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]},
                 "shape": {"type": "box", "halfExtentsMM": [2, 2, 2]}}
            ],
            "motions": [
                {"joint": "c", "fromDeg": 0, "toDeg": -90},
                {"joint": "y", "fromMM": 0, "toMM": -8}
            ],
            "budget": {"sampleSpacingMM": 0.5, "maxRotationDegPerSample": 5.0}
        }"#;
        let r = run(json).unwrap();
        assert_eq!(r.motions.len(), 2);
        for pose in &r.poses {
            assert!((pose.joint_values["y"] - (-8.0 * pose.t)).abs() < 1e-9);
            assert!((pose.joint_values["c"] - (-90.0 * pose.t)).abs() < 1e-9);
        }
        let p = &r.pairs[0];
        assert_eq!(p.state, PairState::Intersecting);
        let t = p.first_time.unwrap();
        assert!(t > 0.05 && t < 0.95, "mid-motion crossing at t={t}");
    }

    #[test]
    fn joint_positions_hold_and_validate() {
        // Held carriage position shifts the whole arm away from the block:
        // with y held at -30mm the sweep no longer reaches it.
        let json = r#"{
            "formatVersion": 1,
            "chain": { "formatVersion": 1, "axes": [
                {"id": "y", "kind": "linear", "parent": null, "axis": [0, 1, 0], "limitsMM": [-500, 500]},
                {"id": "c", "kind": "revolute", "parent": "y", "axis": [0, 0, 1], "limitsDeg": [-360, 360]}
            ]},
            "bodies": [
                {"id": "arm", "attach": {"axis": "c", "frame": {"originMM": [10, 0, 0], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]}},
                 "shape": {"type": "box", "halfExtentsMM": [10, 1, 1]}}
            ],
            "fixtures": [
                {"id": "block", "frame": {"originMM": [10, -12, 0], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]},
                 "shape": {"type": "box", "halfExtentsMM": [2, 2, 2]}}
            ],
            "motion": {"joint": "c", "fromDeg": 0, "toDeg": -90},
            "jointPositions": {"y": -30},
            "budget": {"sampleSpacingMM": 0.5, "maxRotationDegPerSample": 5.0}
        }"#;
        let r = run(json).unwrap();
        assert_eq!(r.joint_positions["y"], -30.0);
        for pose in &r.poses {
            assert_eq!(pose.joint_values["y"], -30.0);
        }
        assert_eq!(r.pairs[0].state, PairState::Clear);

        // Moved joints cannot also be positioned.
        let contradictory = json.replace(
            "\"jointPositions\": {\"y\": -30}",
            "\"jointPositions\": {\"c\": 5}",
        );
        match run(&contradictory) {
            Err(Fail::Message(m)) => assert!(m.contains("moved joint")),
            other => panic!("expected moved-joint failure, got {other:?}"),
        }
        // Unknown axes cannot be positioned.
        let unknown = json.replace(
            "\"jointPositions\": {\"y\": -30}",
            "\"jointPositions\": {\"ghost\": 1}",
        );
        match run(&unknown) {
            Err(Fail::Message(m)) => assert!(m.contains("unknown axis")),
            other => panic!("expected unknown-axis failure, got {other:?}"),
        }
        // Out-of-travel held positions fail too.
        let oob = json.replace(
            "\"jointPositions\": {\"y\": -30}",
            "\"jointPositions\": {\"y\": -3000}",
        );
        match run(&oob) {
            Err(Fail::Message(m)) => assert!(m.contains("outside declared travel")),
            other => panic!("expected travel failure, got {other:?}"),
        }
    }

    #[test]
    fn unknown_extra_fields_do_not_disable_checks() {
        let json = r#"{
            "formatVersion": 1,
            "futureExtension": {"anything": [1, 2, 3]},
            "chain": { "formatVersion": 1, "futureAxisField": true, "axes": [
                {"id": "c", "kind": "revolute", "parent": null, "axis": [0, 0, 1], "limitsDeg": [-360, 360], "futureFlag": 42}
            ]},
            "bodies": [
                {"id": "arm", "attach": {"axis": "c", "frame": {"originMM": [10, 0, 0], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]}},
                 "shape": {"type": "box", "halfExtentsMM": [10, 1, 1]}, "futureBodyField": "x"}
            ],
            "fixtures": [
                {"id": "block", "frame": {"originMM": [10, -12, 0], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]},
                 "shape": {"type": "box", "halfExtentsMM": [2, 2, 2]}}
            ],
            "motion": {"joint": "c", "fromDeg": 0, "toDeg": -90, "futureMotion": null},
            "budget": {"sampleSpacingMM": 0.5, "maxRotationDegPerSample": 5.0, "futureBudget": {}}
        }"#;
        let r = run(json).unwrap();
        assert_eq!(r.pairs[0].state, PairState::Intersecting);
    }

    #[test]
    fn fixtures_output_and_linear_motion_forward_transforms() {
        let json = r#"{
            "formatVersion": 1,
            "chain": { "formatVersion": 1, "axes": [
                {"id": "x", "kind": "linear", "parent": null, "axis": [1, 0, 0], "limitsMM": [-100, 100]},
                {"id": "a", "kind": "revolute", "parent": "x", "originMM": [0, 0, 10], "axis": [0, 1, 0], "limitsDeg": [-180, 180]}
            ]},
            "bodies": [
                {"id": "slide", "resourceID": "machine.x.carriage", "attach": {"axis": "x"}, "shape": {"type": "box", "halfExtentsMM": [5, 5, 5]}},
                {"id": "rotor", "attach": {"axis": "a"}, "shape": {"type": "cylinder", "radiusMM": 3, "lengthMM": 12}}
            ],
            "fixtures": [
                {"id": "base", "frame": {"originMM": [0, 0, -20], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]},
                 "shape": {"type": "box", "halfExtentsMM": [30, 30, 5]}},
                {"id": "floor", "frame": {"originMM": [0, 0, -60], "xDirection": [1, 0, 0], "zDirection": [0, 0, 1]},
                 "shape": {"type": "box", "halfExtentsMM": [500, 500, 10]}}
            ],
            "motion": {"joint": "x", "fromMM": 0, "toMM": 40},
            "jointPositions": {"a": 90},
            "budget": {"sampleSpacingMM": 5.0}
        }"#;
        let r = run(json).unwrap();
        assert_eq!(r.fixtures.len(), 2);
        assert_eq!(r.fixtures[0].id, "base");
        let first = &r.poses[0];
        let slide = first.bodies.iter().find(|b| b.id == "slide").unwrap();
        assert_eq!(slide.frame.origin_mm, [0.0, 0.0, 0.0]);
        assert_eq!(
            slide.resource_id.as_deref(),
            Some("machine.x.carriage")
        );
        let last = r.poses.last().unwrap();
        let slide_last = last.bodies.iter().find(|b| b.id == "slide").unwrap();
        assert_eq!(slide_last.frame.origin_mm, [40.0, 0.0, 0.0]);
        // rotor held at a=90: the +Z body cylinder axis now points along +X.
        let rotor = last.bodies.iter().find(|b| b.id == "rotor").unwrap();
        assert!((rotor.frame.z_direction[0] - 1.0).abs() < 1e-6);
        assert_eq!(last.joint_values["a"], 90.0);
        // base/floor is pose-independent: a single planned evaluation.
        let ss = r
            .pairs
            .iter()
            .find(|p| p.a == "base" && p.b == "floor")
            .unwrap();
        assert_eq!(ss.samples_planned, 1);
        assert_eq!(ss.samples_evaluated, 1);
        // Every pair is clear; dynamic pairs evaluated all planned poses.
        assert!(r.pairs.iter().all(|p| p.state == PairState::Clear));
        let sb = r
            .pairs
            .iter()
            .find(|p| p.a == "slide" && p.b == "base")
            .unwrap();
        assert_eq!(sb.samples_planned, r.samples_planned + 1);
        assert_eq!(sb.samples_evaluated, sb.samples_planned);
    }
}
