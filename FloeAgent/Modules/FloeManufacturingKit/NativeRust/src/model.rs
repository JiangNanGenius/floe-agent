// SPDX-License-Identifier: MIT OR Apache-2.0
// JSON v1 request/result types for the frozen C ABI (CONTRACT.md 2026-11-04).
// Unknown fields are ignored per contract; units are millimetres with
// explicit degrees for A/C and [radius, z] profile pairs.
use serde::{Deserialize, Serialize};

fn default_true() -> bool {
    true
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StockReq {
    /// "cylinder" (default) or "box" (coordinator addition 2026-11-04).
    #[serde(default)]
    pub shape: Option<String>,
    #[serde(rename = "radiusMM")]
    pub radius_mm: f64,
    #[serde(rename = "zMinMM")]
    pub z_min_mm: f64,
    #[serde(rename = "zMaxMM")]
    pub z_max_mm: f64,
    #[serde(rename = "resolutionMM")]
    pub resolution_mm: f64,
    /// Box stock extents (required when shape == "box"); Z must equal
    /// zMinMM/zMaxMM exactly.
    #[serde(rename = "minMM", default)]
    pub min_mm: Option<[f64; 3]>,
    #[serde(rename = "maxMM", default)]
    pub max_mm: Option<[f64; 3]>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurningReq {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(rename = "stepOverMM", default)]
    pub step_over_mm: Option<f64>,
    #[serde(rename = "allowanceMM", default)]
    pub allowance_mm: Option<f64>,
    #[serde(rename = "finishPasses", default)]
    pub finish_passes: Option<u32>,
    #[serde(rename = "toolNoseRadiusMM", default)]
    pub tool_nose_radius_mm: Option<f64>,
    #[serde(rename = "feedMMPerMinute", default)]
    pub feed_mm_per_minute: Option<f64>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MillingReq {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(rename = "angleDegrees")]
    pub angle_degrees: f64,
    #[serde(rename = "widthMM")]
    pub width_mm: f64,
    #[serde(rename = "depthMM")]
    pub depth_mm: f64,
    #[serde(rename = "startZMM")]
    pub start_z_mm: f64,
    #[serde(rename = "endZMM")]
    pub end_z_mm: f64,
    #[serde(rename = "toolRadiusMM")]
    pub tool_radius_mm: f64,
    #[serde(rename = "toolLengthMM")]
    pub tool_length_mm: f64,
    #[serde(rename = "feedMMPerMinute", default)]
    pub feed_mm_per_minute: Option<f64>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MillingAssemblyReq {
    pub format_version: u32,
    #[serde(default)]
    pub name: String,
    #[serde(rename = "shankDiameterMM")]
    pub shank_diameter_mm: f64,
    /// Each pair is `[distanceFromTipMM, radiusMM]` (radius, not diameter;
    /// tip-origin + axis toward spindle per R2 contract).
    #[serde(rename = "holderProfile")]
    pub holder_profile: Vec<[f64; 2]>,
    #[serde(rename = "clearanceMM", default)]
    pub clearance_mm: Option<f64>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FixtureReq {
    pub id: String,
    #[serde(rename = "minMM")]
    pub min_mm: [f64; 3],
    #[serde(rename = "maxMM")]
    pub max_mm: [f64; 3],
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BudgetReq {
    #[serde(rename = "maxCells", default = "default_max_cells")]
    pub max_cells: u64,
    #[serde(rename = "maxPoses", default = "default_max_poses")]
    pub max_poses: u64,
    #[serde(rename = "maxTriangles", default = "default_max_triangles")]
    pub max_triangles: u64,
    #[serde(rename = "maxCollisionQueries", default = "default_max_collision_queries")]
    pub max_collision_queries: u64,
    /// R4: stage-frame cap (default 8, ceiling 16) and retained phase-frame
    /// byte budget (default 128 MB, ceiling 256 MB). Old inputs omit both and
    /// keep the historical behaviour.
    #[serde(rename = "maxFrames", default = "default_max_frames")]
    pub max_frames: u64,
    #[serde(rename = "maxRetainedMeshBytes", default = "default_max_retained_mesh_bytes")]
    pub max_retained_mesh_bytes: u64,
}

pub(crate) fn default_max_cells() -> u64 {
    131_072
}
pub(crate) fn default_max_poses() -> u64 {
    12_000
}
pub(crate) fn default_max_triangles() -> u64 {
    180_000
}
pub(crate) fn default_max_collision_queries() -> u64 {
    500_000
}
pub(crate) fn default_max_frames() -> u64 {
    8
}
pub(crate) fn default_max_retained_mesh_bytes() -> u64 {
    128_000_000
}

/// Hard protocol ceilings (documented) above which a budget request itself is
/// invalid rather than honoured.
pub const MAX_CELLS_CEILING: u64 = 1 << 24;
pub const MAX_POSES_CEILING: u64 = 1_000_000;
pub const MAX_TRIANGLES_CEILING: u64 = 5_000_000;
/// R2: optional collision-query budget; default equals the ceiling (aligned
/// with Root's ToolAssembly.swift protection caps).
pub const MAX_COLLISION_QUERIES_CEILING: u64 = 500_000;
/// R4 contract ceilings.
pub const MAX_FRAMES_CEILING: u64 = 16;
pub const MAX_RETAINED_MESH_BYTES_CEILING: u64 = 256_000_000;

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurningPlanPath {
    pub kind: String,
    pub points: Vec<[f64; 2]>,
    #[serde(rename = "feedMMPerMinute", default)]
    pub feed_mm_per_minute: Option<f64>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurningPlanReq {
    pub ok: bool,
    pub paths: Vec<TurningPlanPath>,
    #[serde(default)]
    pub warnings: Vec<String>,
    #[serde(default)]
    pub backend: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AcMotionReq {
    pub start: [f64; 5],
    pub end: [f64; 5],
    #[serde(rename = "toolLengthMM")]
    pub tool_length_mm: f64,
    pub steps: u32,
}

// ---- R4 native CAM domain (see r4/CONTRACT.md + r4/native/API.md) -----------

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CamToolReq {
    pub id: String,
    #[serde(default)]
    pub name: String,
    pub kind: String,
    #[serde(rename = "diameterMM")]
    pub diameter_mm: f64,
    #[serde(rename = "cuttingLengthMM")]
    pub cutting_length_mm: f64,
    #[serde(rename = "tipAngleDegrees", default)]
    pub tip_angle_degrees: Option<f64>,
    #[serde(rename = "gaugeLengthMM", default)]
    pub gauge_length_mm: Option<f64>,
    /// Root may persist Tool.flutes / Operation.cutting; per coordinator
    /// direction the native side never reads them (unknown fields ignored).
    #[serde(rename = "assembly", default)]
    pub assembly: Option<MillingAssemblyReq>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CamMeshReq {
    pub vertices: Vec<[f64; 3]>,
    pub triangles: Vec<[u32; 3]>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CamFrameReq {
    #[serde(rename = "originMM")]
    pub origin_mm: [f64; 3],
    pub axis: [f64; 3],
    #[serde(rename = "xDirection")]
    pub x_direction: [f64; 3],
}

/// Every business field is optional; each strategy validates exactly the
/// fields it actually uses (r4/native/API.md §2). Absent `enabled` means true.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CamOperationReq {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(rename = "toolID")]
    pub tool_id: String,
    pub strategy: String,
    #[serde(default)]
    pub frame: Option<CamFrameReq>,
    #[serde(rename = "minUVMM", default)]
    pub min_uv_mm: Option<[f64; 2]>,
    #[serde(rename = "maxUVMM", default)]
    pub max_uv_mm: Option<[f64; 2]>,
    #[serde(rename = "centerUVMM", default)]
    pub center_uv_mm: Option<[f64; 2]>,
    #[serde(rename = "radiusMM", default)]
    pub radius_mm: Option<f64>,
    #[serde(rename = "contourUVMM", default)]
    pub contour_uv_mm: Option<Vec<[f64; 2]>>,
    #[serde(rename = "holesUVMM", default)]
    pub holes_uv_mm: Option<Vec<[f64; 2]>>,
    #[serde(rename = "depthMM", default)]
    pub depth_mm: Option<f64>,
    #[serde(rename = "stepDownMM", default)]
    pub step_down_mm: Option<f64>,
    #[serde(rename = "stepOverMM", default)]
    pub step_over_mm: Option<f64>,
    #[serde(rename = "wallStockMM", default)]
    pub wall_stock_mm: Option<f64>,
    #[serde(rename = "floorStockMM", default)]
    pub floor_stock_mm: Option<f64>,
    #[serde(rename = "breakThroughMM", default)]
    pub break_through_mm: Option<f64>,
    #[serde(rename = "clearanceMM", default)]
    pub clearance_mm: Option<f64>,
    #[serde(rename = "feedMMPerMinute", default)]
    pub feed_mm_per_minute: Option<f64>,
    #[serde(rename = "plungeFeedMMPerMinute", default)]
    pub plunge_feed_mm_per_minute: Option<f64>,
    #[serde(rename = "rapidMMPerMinute", default)]
    pub rapid_mm_per_minute: Option<f64>,
    #[serde(rename = "dwellSeconds", default)]
    pub dwell_seconds: Option<f64>,
    #[serde(default)]
    pub cycle: Option<String>,
    #[serde(rename = "peckDepthMM", default)]
    pub peck_depth_mm: Option<f64>,
    #[serde(rename = "chipBreakRetractMM", default)]
    pub chip_break_retract_mm: Option<f64>,
    #[serde(default)]
    pub climb: Option<bool>,
    #[serde(rename = "springPasses", default)]
    pub spring_passes: Option<u32>,
    #[serde(rename = "acSeed", default)]
    pub ac_seed: Option<Vec<f64>>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CamRequest {
    pub format_version: u32,
    #[serde(default)]
    pub tools: Vec<CamToolReq>,
    #[serde(default)]
    pub operations: Vec<CamOperationReq>,
    #[serde(rename = "partMesh", default)]
    pub part_mesh: Option<CamMeshReq>,
}

/// R5 remaining-stock continuation state (INTERFACES.md shared schema, exact
/// key layout). Request: top-level `initialStockState`; response: top-level
/// `stockState` exported on EVERY successful core execution (even a fully
/// machined/empty stock). `removedCount` is CUMULATIVE from the original
/// initial occupancy; `occupiedIndices` are sorted, unique and each names a
/// cell inside the ORIGINAL initial occupancy envelope.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StockState {
    pub format_version: u32,
    /// Voxel grid [nx, ny, nz].
    pub dimensions: [usize; 3],
    #[serde(rename = "originMM")]
    pub origin_mm: [f64; 3],
    #[serde(rename = "resolutionMM")]
    pub resolution_mm: f64,
    /// "cylinder" | "box".
    pub shape: String,
    /// Cylinder radius (positive). Null/absent for box stock.
    #[serde(rename = "radiusMM", default, skip_serializing_if = "Option::is_none")]
    pub radius_mm: Option<f64>,
    /// Optional for legacy archives; present in new checkpoints so ceil-rounded
    /// grids cannot hide a change to the physical stock end planes.
    #[serde(rename = "declaredMaxMM", default, skip_serializing_if = "Option::is_none")]
    pub declared_max_mm: Option<[f64; 3]>,
    /// Sorted strictly ascending unique occupied cell indices (empty valid).
    #[serde(rename = "occupiedIndices", default)]
    pub occupied_indices: Vec<usize>,
    /// Cumulative removed count: original initial occupancy minus end
    /// occupancy of this invocation.
    #[serde(rename = "removedCount")]
    pub removed_count: u64,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CoreRequest {
    pub format_version: u32,
    pub stock: StockReq,
    /// R5: optional continuation state; when supplied the execution starts
    /// from this occupancy instead of a fresh envelope. Never resets stock.
    #[serde(rename = "initialStockState", default)]
    pub initial_stock_state: Option<StockState>,
    #[serde(default)]
    pub profile: Option<Vec<[f64; 2]>>,
    #[serde(default)]
    pub turning: Option<TurningReq>,
    #[serde(default)]
    pub milling: Option<MillingReq>,
    #[serde(default)]
    pub fixtures: Vec<FixtureReq>,
    #[serde(default)]
    pub budget: Option<BudgetReq>,
    #[serde(rename = "turningPlan", default)]
    pub turning_plan: Option<TurningPlanReq>,
    /// R5 dual-spindle support: face-cut approach direction. "positiveZ"
    /// (default): face cuts remove z >= the face plane (approach from +z).
    /// "negativeZ": face cuts remove z <= the face plane (approach from -z,
    /// backside facing). Longitudinal envelope cuts are unchanged; the stock
    /// grid is never mirrored. Unknown values fail explicitly.
    #[serde(rename = "turningApproach", default)]
    pub turning_approach: Option<String>,
    #[serde(rename = "acMotion", default)]
    pub ac_motion: Option<AcMotionReq>,
    #[serde(rename = "millingAssembly", default)]
    pub milling_assembly: Option<MillingAssemblyReq>,
    #[serde(rename = "cam", default)]
    pub cam: Option<CamRequest>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PathOut {
    pub kind: String,
    pub points: Vec<[f64; 3]>,
    #[serde(rename = "feedMMPerMinute", skip_serializing_if = "Option::is_none")]
    pub feed_mm_per_minute: Option<f64>,
    /// R4 CAM fields (all optional; absent for legacy turning/milling/ac
    /// paths so old serializations stay byte-identical).
    #[serde(rename = "operationID", skip_serializing_if = "Option::is_none")]
    pub operation_id: Option<String>,
    #[serde(rename = "toolID", skip_serializing_if = "Option::is_none")]
    pub tool_id: Option<String>,
    #[serde(rename = "moveType", skip_serializing_if = "Option::is_none")]
    pub move_type: Option<String>,
    #[serde(rename = "toolAxes", skip_serializing_if = "Option::is_none")]
    pub tool_axes: Option<Vec<[f64; 3]>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub joints: Option<Vec<[f64; 5]>>,
    #[serde(rename = "dwellSeconds", skip_serializing_if = "Option::is_none")]
    pub dwell_seconds: Option<f64>,
}

impl PathOut {
    /// Legacy R1-R3 constructor (kept so existing call sites stay unchanged).
    pub fn legacy(kind: String, points: Vec<[f64; 3]>, feed_mm_per_minute: Option<f64>) -> Self {
        PathOut {
            kind,
            points,
            feed_mm_per_minute,
            operation_id: None,
            tool_id: None,
            move_type: None,
            tool_axes: None,
            joints: None,
            dwell_seconds: None,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StageOut {
    pub name: String,
    #[serde(rename = "remainingMM3")]
    pub remaining_mm3: f64,
    #[serde(rename = "removedMM3")]
    pub removed_mm3: f64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CollisionOut {
    pub component: String,
    pub state: String,
    pub message: String,
    #[serde(rename = "toolPart", skip_serializing_if = "Option::is_none")]
    pub tool_part: Option<String>,
    #[serde(rename = "targetKind", skip_serializing_if = "Option::is_none")]
    pub target_kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub operation: Option<String>,
    #[serde(rename = "firstPoseIndex", skip_serializing_if = "Option::is_none")]
    pub first_pose_index: Option<usize>,
    #[serde(rename = "minimumGapLowerBoundMM", skip_serializing_if = "Option::is_none")]
    pub minimum_gap_lower_bound_mm: Option<f64>,
    #[serde(rename = "geometryErrorMM", skip_serializing_if = "Option::is_none")]
    pub geometry_error_mm: Option<f64>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FrameOut {
    pub name: String,
    pub vertices: Vec<[f64; 3]>,
    pub triangles: Vec<[u32; 3]>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AcPoseOut {
    #[serde(rename = "tipMM")]
    pub tip_mm: [f64; 3],
    pub axis: [f64; 3],
    pub joints: [f64; 5],
}

/// R4 per-operation CAM report row (r4/native/API.md §6).
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CamReportRow {
    #[serde(rename = "operationID")]
    pub operation_id: String,
    pub strategy: String,
    #[serde(rename = "toolID")]
    pub tool_id: String,
    pub generated_points: u64,
    pub cut_poses: u64,
    #[serde(rename = "remainingMM3")]
    pub remaining_mm3: f64,
    #[serde(rename = "removedMM3")]
    pub removed_mm3: f64,
    pub sources: Vec<String>,
    pub limits: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CoreResult {
    pub ok: bool,
    pub backend: String,
    #[serde(rename = "initialMM3")]
    pub initial_mm3: f64,
    #[serde(rename = "analyticInitialMM3")]
    pub analytic_initial_mm3: f64,
    #[serde(rename = "remainingMM3")]
    pub remaining_mm3: f64,
    #[serde(rename = "removedMM3")]
    pub removed_mm3: f64,
    pub vertices: Vec<[f64; 3]>,
    pub triangles: Vec<[u32; 3]>,
    pub paths: Vec<PathOut>,
    pub stages: Vec<StageOut>,
    pub collisions: Vec<CollisionOut>,
    pub warnings: Vec<String>,
    pub capabilities: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub frames: Option<Vec<FrameOut>>,
    #[serde(rename = "acPoses", skip_serializing_if = "Option::is_none")]
    pub ac_poses: Option<Vec<AcPoseOut>>,
    #[serde(rename = "assemblyQueryCount", skip_serializing_if = "Option::is_none")]
    pub assembly_query_count: Option<u64>,
    #[serde(rename = "camReport", skip_serializing_if = "Option::is_none")]
    pub cam_report: Option<Vec<CamReportRow>>,
    #[serde(rename = "sampledCamPoses", skip_serializing_if = "Option::is_none")]
    pub sampled_cam_poses: Option<u64>,
    /// R5: exported remaining-stock state on EVERY successful execution
    /// (even a fully machined/empty stock). `removedCount` is cumulative
    /// from the original initial occupancy.
    #[serde(rename = "stockState")]
    pub stock_state: StockState,
}

pub fn backend_string() -> String {
    "floe-machining-native 0.1.0 (OpenMill 0432a8c TableTable FK/IK + Floe bounded adapter; \
     MillSimSharp 3cdd4f54 finite-cylinder geometry port; isosurface 22eba3c8 \
     marching-tetrahedra port; Parry3d 0.17.6 queries)"
        .to_string()
}

/// Standard failure envelope: exactly ok=false plus the error. Never carries
/// success-only fields.
pub fn failure_json(error: &str) -> String {
    serde_json::json!({ "ok": false, "error": error }).to_string()
}
