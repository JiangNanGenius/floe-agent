// SPDX-License-Identifier: MIT OR Apache-2.0
// fm_core_execute pipeline: cylinder voxel stock -> turning envelope cuts
// (supplied turningPlan polylines) -> fixed-angle slot milling (depth below
// the LOCAL turned surface) -> optional acMotion oriented-cylinder removal
// -> marching-tetrahedra stock mesh with phase frames, stage volumes,
// Parry3d fixture collisions, budgets and cancellation.
use nalgebra::{Point3, Unit, Vector3};

use crate::ac::BoundedAC;
use crate::collision::{
    check_cutter_against_fixtures, check_turning_nose_against_fixtures, CollisionState, FixtureBox,
    QueryBudget,
};
use crate::model::*;
use crate::stock::Stock;
use crate::tetra;
use crate::Progress;

#[derive(Debug)]
pub enum Fail {
    Cancelled,
    Message(String),
}

impl std::fmt::Display for Fail {
    fn fmt(&self,f:&mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self { Self::Cancelled => f.write_str("cancelled"), Self::Message(message) => f.write_str(message) }
    }
}

impl From<String> for Fail {
    fn from(s: String) -> Self {
        Fail::Message(s)
    }
}

impl From<&str> for Fail {
    fn from(s: &str) -> Self {
        Fail::Message(s.to_string())
    }
}

/// R4: stage-frame sink honouring budget.maxFrames and
/// budget.maxRetainedMeshBytes. Frames already retained are never evicted;
/// when a frame would exceed the budget the capture is skipped (the caller
/// records that representative frames were kept).
struct FrameSink {
    max_frames: u64,
    retained_bytes: u64,
    max_retained_bytes: u64,
    triangle_budget: u64,
}

impl FrameSink {
    fn new(budget: &BudgetReq) -> Self {
        FrameSink {
            max_frames: budget.max_frames,
            retained_bytes: 0,
            max_retained_bytes: budget.max_retained_mesh_bytes,
            triangle_budget: budget.max_triangles,
        }
    }

    fn frame_bytes(vertices: usize, triangles: usize) -> u64 {
        vertices as u64 * 24 + triangles as u64 * 12
    }

    /// Try to mesh and retain one phase frame. Returns Ok(true) when kept.
    fn capture(
        &mut self,
        stock: &Stock,
        name: &str,
        frames: &mut Vec<FrameOut>,
    ) -> Result<bool, Fail> {
        if frames.len() as u64 >= self.max_frames {
            return Ok(false);
        }
        let max_triangles = self.triangle_budget;
        let (v, t) = mesh_stock(stock, max_triangles, &mut self.triangle_budget)?;
        let bytes = Self::frame_bytes(v.len(), t.len());
        if self.retained_bytes + bytes > self.max_retained_bytes {
            return Ok(false);
        }
        self.retained_bytes += bytes;
        frames.push(FrameOut { name: name.to_string(), vertices: v, triangles: t });
        Ok(true)
    }
}

pub(crate) fn validate_budget(b: &BudgetReq) -> Result<(), Fail> {
    if b.max_cells == 0 || b.max_cells > MAX_CELLS_CEILING {
        return Err(format!(
            "budget: maxCells must be 1...{MAX_CELLS_CEILING}"
        )
        .into());
    }
    if b.max_poses == 0 || b.max_poses > MAX_POSES_CEILING {
        return Err(format!(
            "budget: maxPoses must be 1...{MAX_POSES_CEILING}"
        )
        .into());
    }
    if b.max_triangles == 0 || b.max_triangles > MAX_TRIANGLES_CEILING {
        return Err(format!(
            "budget: maxTriangles must be 1...{MAX_TRIANGLES_CEILING}"
        )
        .into());
    }
    if b.max_collision_queries == 0 || b.max_collision_queries > MAX_COLLISION_QUERIES_CEILING {
        return Err(format!(
            "budget: maxCollisionQueries must be 1...{MAX_COLLISION_QUERIES_CEILING}"
        )
        .into());
    }
    // R4: stage-frame cap and retained mesh byte budget (optional fields).
    if b.max_frames == 0 || b.max_frames > MAX_FRAMES_CEILING {
        return Err(format!("budget: maxFrames must be 1...{MAX_FRAMES_CEILING}").into());
    }
    if b.max_retained_mesh_bytes == 0 || b.max_retained_mesh_bytes > MAX_RETAINED_MESH_BYTES_CEILING
    {
        return Err(format!(
            "budget: maxRetainedMeshBytes must be 1...{MAX_RETAINED_MESH_BYTES_CEILING}"
        )
        .into());
    }
    Ok(())
}

fn validate_profile(profile: &[[f64; 2]]) -> Result<(), Fail> {
    let mut z_prev = f64::NEG_INFINITY;
    for p in profile {
        if !p[0].is_finite() || !p[1].is_finite() || p[0] < 0.0 {
            return Err("profile: finite nonnegative radii required".into());
        }
        if p[1] < z_prev {
            return Err("profile: z values must be ordered (equal-z shoulders allowed)".into());
        }
        z_prev = p[1];
    }
    Ok(())
}

fn fixtures_from(req: &[FixtureReq]) -> Result<Vec<FixtureBox>, Fail> {
    req.iter()
        .map(|f| {
            if f.id.is_empty()
                || !f.min_mm.iter().chain(f.max_mm.iter()).all(|v| v.is_finite())
            {
                return Err("fixtures: non-empty id and finite minMM/maxMM required".into());
            }
            Ok(FixtureBox {
                id: f.id.clone(),
                min: f.min_mm,
                max: f.max_mm,
            })
        })
        .collect()
}

pub(crate) fn mesh_stock(
    stock: &Stock,
    max_triangles: u64,
    _frame_budget: &mut u64,
) -> Result<(Vec<[f64; 3]>, Vec<[u32; 3]>), Fail> {
    if let Some(mesh) = crate::bounded_mesh::blank_box(stock,max_triangles).map_err(Fail::Message)? { return Ok(mesh); }
    if let Some(mesh) = stock.axisymmetric_mesh(max_triangles) { return Ok(mesh); }
    // A material node can touch every face of the stock grid. The isosurface
    // must see exterior air beyond those faces, otherwise it ends in an open
    // boundary. Sample fractional cell density and add one positive halo;
    // this changes representation only, never occupancy or removed material.
    let interior = stock.nodal_field();
    let old = [stock.nx + 1, stock.ny + 1, stock.nz + 1];
    let dims = [old[0] + 2, old[1] + 2, old[2] + 2];
    let mut values = vec![1.0; dims[0] * dims[1] * dims[2]];
    for z in 0..old[2] {
        for y in 0..old[1] {
            for x in 0..old[0] {
                values[((z+1)*dims[1]+y+1)*dims[0]+x+1] = interior[(z*old[1]+y)*old[0]+x];
            }
        }
    }
    let low = [
        stock.origin[0] - stock.h,
        stock.origin[1] - stock.h,
        stock.origin[2] - stock.h,
    ];
    crate::bounded_mesh::intersect_cylinder_domain(stock,dims,low,&mut values);
    let mesh = tetra::generate(
        dims,
        low,
        stock.h,
        &values,
        max_triangles,
    )
    .map_err(Fail::Message)?;
    // maxTriangles caps EACH mesh, per the original output contract. Retained
    // frames have separate count/byte caps; they do not spend the final mesh's
    // remaining triangles merely by being replayable.
    crate::bounded_mesh::constrain(stock,(mesh.vertices, mesh.triangles),max_triangles).map_err(Fail::Message)
}

pub(crate) fn collision_out(items: Vec<crate::collision::CutterCollisionSummary>) -> Vec<CollisionOut> {
    items
        .into_iter()
        .map(|c| CollisionOut {
            component: c.component,
            state: match c.state {
                CollisionState::Intersecting => "intersecting",
                CollisionState::Clear => "clear",
                CollisionState::Clearance => "clearance",
                CollisionState::Uncertain => "uncertain",
            }
            .to_string(),
            message: c.message,
            tool_part: c.tool_part,
            target_kind: c.target_kind,
            operation: c.operation,
            first_pose_index: c.first_pose_index,
            minimum_gap_lower_bound_mm: c.minimum_gap_lower_bound_mm,
            geometry_error_mm: c.geometry_error_mm,
        })
        .collect()
}

fn volume_warning() -> &'static str {
    "initial/remaining/removed and phase volumes all use voxel-cell occupancy; analyticInitialMM3 separately records the cylinder formula. Phase removedMM3 is incremental."
}

fn mesh_warning() -> &'static str {
    "Pristine rectangular blanks use their declared planar faces; filled-disc stock uses circular rings. Reconstructed mesh vertices are restricted to the declared stock domain, with closed-edge repair. Cut surfaces and volumes remain voxel approximations; boundary correction does not establish finer machining accuracy."
}

pub fn run_core(request_json: &str, progress: &Progress) -> Result<CoreResult, Fail> {
    let req: CoreRequest = serde_json::from_str(request_json)
        .map_err(|e| Fail::Message(format!("invalid request JSON: {e}")))?;
    if req.format_version != 1 {
        return Err("formatVersion must be 1".into());
    }
    if let Some(profile) = &req.profile {
        validate_profile(profile)?;
    }
    let budget = req.budget.clone().unwrap_or(BudgetReq {
        max_cells: default_max_cells(),
        max_poses: default_max_poses(),
        max_triangles: default_max_triangles(),
        max_collision_queries: default_max_collision_queries(),
        max_frames: default_max_frames(),
        max_retained_mesh_bytes: default_max_retained_mesh_bytes(),
    });
    validate_budget(&budget)?;
    let fixtures = fixtures_from(&req.fixtures)?;
    // R2: shared collision-query budget across milling + acMotion (actual
    // Parry calls; exhaustion is a clear failure, never a silent skip).
    let mut collision_budget = QueryBudget::new(budget.max_collision_queries);
    // R2: optional tool assembly. Cutting dimensions stay authoritative from
    // the milling section; the A/C gauge length is never used here.
    let assembly = match &req.milling_assembly {
        Some(a) => {
            let m = req.milling.as_ref().ok_or_else(|| {
                Fail::Message(
                    "millingAssembly requires the milling section (toolRadiusMM/toolLengthMM are the cutting-dimension authority)"
                        .into(),
                )
            })?;
            Some(crate::assembly::ToolAssembly::validate(
                a,
                m.tool_radius_mm,
                m.tool_length_mm,
            )?)
        }
        None => None,
    };
    let mut warnings: Vec<String> = vec![volume_warning().to_string(), mesh_warning().to_string()];
    let mut capabilities: Vec<String> = vec![
        "single-spindle-cylinder-voxel-stock".into(),
        "turning-envelope-cuts-from-supplied-polylines".into(),
        "face-cuts-approach-from-plus-z".into(),
        "fixed-angle-slot-milling-depth-below-local-turned-surface".into(),
        "ac-motion-oriented-cylinder-removal".into(),
        "marching-tetrahedra-stock-mesh".into(),
        "parry3d-fixture-collision-with-uncertain-state".into(),
        "phase-frame-snapshots".into(),
    ];
    if let Some(asm) = &assembly {
        capabilities.push("tool-assembly-shank-holder-fixture-collision".into());
        capabilities.push("tool-assembly-shank-holder-remaining-stock-per-material-step".into());
        warnings.push(
            "tool-assembly: turning tool body and full machine-chain collision remain unsupported; only shank/holder vs fixture boxes and remaining voxel stock are checked".into(),
        );
        if asm.holder_error_mm > 0.0 {
            warnings.push(
                "tool-assembly: tapered holder windows use a conservative envelope cylinder plus an inscribed cone; envelope-only contact is reported uncertain and geometryErrorMM records the max radial envelope error".into(),
            );
        }
        warnings.push(
            "tool-assembly: discrete physical pose checks only; continuous sweep between poses is not claimed"
                .into(),
        );
    } else if req.milling.as_ref().map(|m| m.enabled).unwrap_or(false)
        || req.ac_motion.is_some()
    {
        warnings.push(
            "millingAssembly absent: only the cutting cylinder was checked against fixture boxes; shank/holder coverage is not claimed"
                .into(),
        );
    }

    // ---- stock ------------------------------------------------------------
    progress.report(0.02, "stock")?;
    // R4 (coordinator addition): optional rectangular stock. Box extents must
    // match the study z extent exactly; turning is rejected on box stock.
    let mut stock = match req.stock.shape.as_deref().unwrap_or("cylinder") {
        "cylinder" => Stock::cylinder(
            req.stock.radius_mm,
            req.stock.z_min_mm,
            req.stock.z_max_mm,
            req.stock.resolution_mm,
            budget.max_cells,
        )?,
        "box" => {
            let min = req.stock.min_mm.ok_or_else(|| {
                Fail::Message("stock: minMM is required when shape=box".into())
            })?;
            let max = req.stock.max_mm.ok_or_else(|| {
                Fail::Message("stock: maxMM is required when shape=box".into())
            })?;
            if min[2] != req.stock.z_min_mm || max[2] != req.stock.z_max_mm {
                return Err(
                    "stock: box minMM[2]/maxMM[2] must equal zMinMM/zMaxMM exactly".into(),
                );
            }
            Stock::box_stock(min, max, req.stock.resolution_mm, budget.max_cells)?
        }
        other => {
            return Err(format!(
                "stock: unknown shape '{other}' (expected cylinder|box)"
            )
            .into())
        }
    };
    let initial_exact = stock.analytic_volume();
    // Continue BEFORE producing any initial stage or replay mesh. Reconstructing
    // the fresh envelope above validates the checkpoint; it must never become a
    // visible regrowth frame in a later spindle operation.
    if let Some(state) = &req.initial_stock_state {
        stock.apply_continuation(state)?;
        warnings.push(format!(
            "stockState: continued from supplied initialStockState ({} occupied cells, {} cumulative removed); initial stage/mesh and result initialMM3 are this invocation's starting material, removedMM3 is incremental, and removedCount is cumulative",
            stock.occupied_count(), stock.removed_count()
        ));
    }

    let mut frames: Vec<FrameOut> = Vec::new();
    let mut frame_sink = FrameSink::new(&budget);
    let initial_mesh = mesh_stock(&stock, budget.max_triangles, &mut frame_sink.triangle_budget)?;
    let initial_frame_bytes = FrameSink::frame_bytes(initial_mesh.0.len(),initial_mesh.1.len());
    if initial_frame_bytes > budget.max_retained_mesh_bytes {
        return Err("budget: initial replay mesh exceeds maxRetainedMeshBytes".into());
    }
    frame_sink.retained_bytes += initial_frame_bytes;
    frames.push(FrameOut {
        name: "initial".into(),
        vertices: initial_mesh.0.clone(),
        triangles: initial_mesh.1.clone(),
    });

    let mut stages: Vec<StageOut> = vec![StageOut {
        name: "initial".into(),
        remaining_mm3: stock.occupied_count() as f64 * stock.cell_volume(),
        removed_mm3: 0.0,
    }];

    if req.initial_stock_state.is_some() {
        stages.push(StageOut { name: "continued".into(),
            remaining_mm3: stock.occupied_count() as f64 * stock.cell_volume(), removed_mm3: 0.0 });
    }
    // R5 coordinator semantics: result initialMM3 is THIS invocation's
    // starting occupancy (continued occupancy when supplied), removedMM3 is
    // incremental for this invocation; analyticInitialMM3 stays the original
    // fresh-stock analytic value.
    let start_occupancy = stock.occupied_count() as f64 * stock.cell_volume();

    let mut paths_out: Vec<PathOut> = Vec::new();
    let mut collisions: Vec<CollisionOut> = Vec::new();
    let mut poses_used: u64 = 0;

    // ---- turning ------------------------------------------------------------
    let turning_enabled = req.turning.as_ref().map(|t| t.enabled).unwrap_or(false);
    // R5 dual-spindle backside facing: face-cut approach direction.
    // Mirrors the planner input contract only; longitudinal envelope cuts
    // are unchanged and the stock grid is never mirrored.
    let negative_z_face = match req.turning_approach.as_deref().unwrap_or("positiveZ") {
        "positiveZ" => false,
        "negativeZ" => true,
        other => {
            return Err(format!(
                "turning: unsupported turningApproach '{other}' (expected positiveZ|negativeZ)"
            )
            .into())
        }
    };
    if negative_z_face && turning_enabled {
        // Root fences stale binaries on this capability for negative-Z
        // (backside facing) requests.
        capabilities.push("negative-z-turning-envelope".into());
        warnings.push(
            "turningApproach negativeZ: face cuts remove z <= the face plane (approach from -z, backside facing); longitudinal envelope cuts and the stock grid are unchanged".into(),
        );
    }
    if turning_enabled {
        if !stock.is_cylinder() {
            // Coordinator addition 2026-11-04: turning is only defined on the
            // cylinder envelope; box stock fails explicitly.
            return Err("turning: stock.shape=box does not support turning (cylinder stock required)".into());
        }
        let plan = req
            .turning_plan
            .as_ref()
            .ok_or_else(|| Fail::Message("turning.enabled but no turningPlan supplied".into()))?;
        if !plan.ok {
            return Err("turningPlan.ok is false; a failed plan must not be executed".into());
        }
        if plan.paths.is_empty() {
            return Err("turningPlan contains no cut paths".into());
        }
        let nose_radius = req
            .turning
            .as_ref()
            .and_then(|t| t.tool_nose_radius_mm)
            .unwrap_or(0.0);
        if nose_radius > 0.0 {
            warnings.push(format!(
                "turning tool-nose treatment is a bounded geometric approximation: supplied polylines are applied directly and corner fillets are represented as sharp corners (local corner deviation bounded by toolNoseRadiusMM {nose_radius}); longitudinal envelope cuts are exact to voxel resolution"
            ));
        }
        progress.report(0.08, "turning")?;
        // Group consecutive paths by kind; snapshot a frame at each boundary.
        let mut i = 0usize;
        while i < plan.paths.len() {
            let kind = plan.paths[i].kind.clone();
            let start = i;
            let before_kind = stock.occupied_count();
            while i < plan.paths.len() && plan.paths[i].kind == kind {
                i += 1;
            }
            for path in &plan.paths[start..i] {
                if path.points.len() < 2 && !path.points.is_empty() {
                    // single-point path removes nothing but still counts as a pose
                }
                poses_used += path.points.len() as u64;
                if poses_used > budget.max_poses {
                    return Err(format!(
                        "budget: turning poses exceed maxPoses {}",
                        budget.max_poses
                    )
                    .into());
                }
                stock.apply_turning_path(&path.points, negative_z_face)?;
                paths_out.push(PathOut::legacy(
                    format!("turning-{}", path.kind),
                    path.points.iter().map(|p| [p[0], 0.0, p[1]]).collect(),
                    path.feed_mm_per_minute,
                ));
            }
            let removed = before_kind - stock.occupied_count();
            stages.push(StageOut {
                name: format!("turning-{kind}"),
                remaining_mm3: stock.occupied_count() as f64 * stock.cell_volume(),
                removed_mm3: removed as f64 * stock.cell_volume(),
            });
            // Turning collision: nose sphere at every path vertex (3D, angle 0).
            if !fixtures.is_empty() {
                let pts: Vec<Point3<f64>> = plan.paths[start..i]
                    .iter()
                    .flat_map(|p| p.points.iter().map(|q| Point3::new(q[0], 0.0, q[1])))
                    .collect();
                if !pts.is_empty() {
                    let r = nose_radius.max(0.05);
                    collisions.extend(collision_out(check_turning_nose_against_fixtures(
                        &fixtures, &pts, r, progress,
                    )?));
                }
            }
            frame_sink.capture(&stock, &format!("turning-{kind}"), &mut frames)?;
            progress.report(0.08 + 0.32 * (i as f64 / plan.paths.len() as f64), "turning")?;
        }
    }

    // ---- milling ------------------------------------------------------------
    let milling_enabled = req.milling.as_ref().map(|m| m.enabled).unwrap_or(false);
    if milling_enabled {
        let m = req.milling.as_ref().unwrap();
        let bad = |w: &str| -> Result<(), Fail> { Err(w.to_string().into()) };
        if ![
            m.angle_degrees,
            m.width_mm,
            m.depth_mm,
            m.start_z_mm,
            m.end_z_mm,
            m.tool_radius_mm,
            m.tool_length_mm,
        ]
        .iter()
        .all(|v| v.is_finite())
        {
            bad("milling: all dimensions must be finite")?;
        }
        if m.width_mm <= 0.0 || m.depth_mm <= 0.0 || m.tool_radius_mm <= 0.0
            || m.tool_length_mm <= 0.0
        {
            bad("milling: width, depth and tool radius/length must be positive")?;
        }
        if (m.tool_radius_mm * 2.0 - m.width_mm).abs() > 1e-9 {
            bad("milling: single-pass slot width must equal tool diameter; narrower/wider slots require another strategy")?;
        }
        if m.end_z_mm <= m.start_z_mm {
            bad("milling: endZMM must be greater than startZMM")?;
        }
        let (z0, z1) = stock.z_range();
        if m.start_z_mm < z0 || m.end_z_mm > z1 {
            bad("milling: slot z interval must lie inside the stock z extent")?;
        }
        progress.report(0.42, "milling")?;
        let theta = m.angle_degrees.to_radians();
        let radial = Unit::new_normalize(Vector3::new(theta.cos(), theta.sin(), 0.0));
        let before_milling = stock.occupied_count();
        let mut slot_bottom_clamped = false;
        let mut tips: Vec<Point3<f64>> = Vec::new();
        let mut axes: Vec<Unit<Vector3<f64>>> = Vec::new();
        // R2: per-material-step shank/holder checks happen after each slab
        // removal, before any later slab can hide the contact.
        let mut asm_checker = match &assembly {
            Some(a) => Some(crate::assembly::AssemblyChecker::new(
                a,
                &fixtures,
                &mut collision_budget,
            )?),
            None => None,
        };
        for iz in 0..stock.nz {
            let zc = stock.origin[2] + (iz as f64 + 0.5) * stock.h;
            if zc < m.start_z_mm || zc > m.end_z_mm {
                continue;
            }
            let r_env = stock.max_radius_in_slab(iz);
            if r_env <= 0.0 {
                continue; // no material left in this slab
            }
            let mut r_bottom = r_env - m.depth_mm;
            if r_bottom < 0.0 {
                r_bottom = 0.0;
                slot_bottom_clamped = true;
            }
            let tip = Point3::new(
                r_bottom * radial.x,
                r_bottom * radial.y,
                zc,
            );
            tips.push(tip);
            axes.push(radial);
            poses_used += 1;
            if poses_used > budget.max_poses {
                return Err(
                    format!("budget: milling poses exceed maxPoses {}", budget.max_poses).into(),
                );
            }
            stock.remove_oriented_cutter(&tip, &radial, m.tool_radius_mm, m.tool_length_mm);
            if let Some(chk) = asm_checker.as_mut() {
                chk.check_step(
                    tips.len() - 1,
                    stock.nz,
                    &tip,
                    &radial,
                    &stock,
                    progress,
                    0.42,
                    0.68,
                )?;
            }
            progress.report(
                0.42 + 0.26 * ((zc - m.start_z_mm) / (m.end_z_mm - m.start_z_mm)).clamp(0.0, 1.0),
                "milling",
            )?;
        }
        if slot_bottom_clamped {
            warnings.push(
                "milling: slot depth reached the part axis in at least one slab; bottom clamped to radius 0"
                    .into(),
            );
        }
        stages.push(StageOut {
            name: "milling-slot".into(),
            remaining_mm3: stock.occupied_count() as f64 * stock.cell_volume(),
            removed_mm3: (before_milling - stock.occupied_count()) as f64 * stock.cell_volume(),
        });
        paths_out.push(PathOut::legacy(
            "milling-slot".into(),
            tips.iter().map(|p| [p.x, p.y, p.z]).collect(),
            m.feed_mm_per_minute,
        ));
        if let Some(chk) = asm_checker {
            collisions.extend(chk.into_rows("milling", stock.h));
        }
        if !fixtures.is_empty() && !tips.is_empty() {
            if let Some(asm) = &assembly {
                collisions.extend(collision_out(
                    crate::assembly::check_cutter_against_fixtures_with_clearance(
                        &fixtures,
                        &tips,
                        &axes,
                        m.tool_radius_mm,
                        m.tool_length_mm,
                        asm.clearance_mm,
                        "milling",
                        &mut collision_budget,
                        progress,
                        0.68,
                        0.70,
                    )?,
                ));
            } else {
                collisions.extend(collision_out(check_cutter_against_fixtures(
                    &fixtures,
                    &tips,
                    &axes,
                    m.tool_radius_mm,
                    m.tool_length_mm,
                    "milling",
                    &mut collision_budget,
                    progress,
                    0.68,
                    0.70,
                )?));
            }
        }
        frame_sink.capture(&stock, "milling", &mut frames)?;
    }

    // ---- R4 native CAM (ordered operations on the shared stock) -------------
    let mut cam_report: Option<Vec<crate::model::CamReportRow>> = None;
    let mut sampled_cam_poses: Option<u64> = None;
    if let Some(cam_req) = &req.cam {
        if cam_req.format_version != 1 {
            return Err("cam: formatVersion must be 1".into());
        }
        let tools = crate::cam::tools::CamTool::validate_many(&cam_req.tools)
            .map_err(Fail::Message)?;
        let mut frame_note_done = false;
        let mut cam_frame_hook = |stock_ref: &Stock, name: &str| -> Result<bool, Fail> {
            let kept = frame_sink.capture(stock_ref, name, &mut frames)?;
            if !kept && !frame_note_done {
                warnings.push(
                    "cam: phase frame capture stopped (maxFrames or maxRetainedMeshBytes); previously retained representative frames are kept"
                        .into(),
                );
                frame_note_done = true;
            }
            Ok(kept)
        };
        let mut exec = crate::cam::exec::CamExec {
            stock: &mut stock,
            fixtures: &fixtures,
            budget: &budget,
            collision_budget: &mut collision_budget,
            progress,
            poses_used: &mut poses_used,
            paths: &mut paths_out,
            collisions: &mut collisions,
        };
        // Legacy milling used 0.42...0.68; acMotion below keeps its historical
        // absolute fractions, so CAM takes 0.68...0.86 (cosmetic overlap with
        // acMotion's hard-coded base is documented in r4/native/HANDOFF.md).
        let summary = crate::cam::exec::run_cam(
            cam_req,
            &tools,
            &mut exec,
            &mut cam_frame_hook,
            0.68,
            0.86,
        )?;
        stages.extend(summary.stages);
        warnings.extend(summary.warnings);
        capabilities.push("cam-ordered-operations-shared-voxel-stock".into());
        capabilities.push("cam-face-pocket-contour-drill-explicit-features".into());
        capabilities.push("cam-mesh-strategies-raycast-sampled".into());
        capabilities.push("cam-real-tool-profile-removal".into());
        capabilities.push("cam-hole-cycles-expanded".into());
        if cam_req.operations.iter().any(|o| o.enabled && o.ac_seed.is_some()) {
            capabilities.push("cam-ac-seed-ik-branch-continuity".into());
        }
        warnings.push(
            "cam: collision/remaining-stock checks are discrete sampled poses; continuous sweep between samples is not claimed"
                .into(),
        );
        cam_report = Some(summary.report);
        sampled_cam_poses = Some(summary.sampled_poses);
    }

    // ---- acMotion ------------------------------------------------------------
    let mut ac_poses_out: Option<Vec<AcPoseOut>> = None;
    if let Some(ac) = &req.ac_motion {
        progress.report(0.7, "ac-motion")?;
        // Independent of fixture presence and of milling.enabled: when the
        // milling section supplies the cutter removal dimensions they must be
        // finite and positive (Root's native-side guard for the same input).
        if let Some(m) = &req.milling {
            if !m.tool_radius_mm.is_finite()
                || m.tool_radius_mm <= 0.0
                || !m.tool_length_mm.is_finite()
                || m.tool_length_mm <= 0.0
            {
                return Err(
                    "acMotion: milling.toolRadiusMM/toolLengthMM must be finite and positive when supplied (cutter removal authority)"
                        .into(),
                );
            }
        }
        let mut spec = crate::ac::Machine::default();
        spec.tool_length_mm = ac.tool_length_mm;
        let engine = BoundedAC::new(spec)?;
        let sample = engine.sample_uniform(ac.start, ac.end, ac.steps)?;
        poses_used += sample.poses.len() as u64;
        if poses_used > budget.max_poses {
            return Err(format!("budget: acMotion poses exceed maxPoses {}", budget.max_poses).into());
        }
        if let Some(w) = &sample.warning_detail {
            warnings.push(format!("acMotion: {w}"));
        }
        // Gauge length (ac.tool_length_mm) is used ONLY for FK tip placement;
        // the removal cylinder uses the milling cutter radius and CUTTING
        // length so the two are never conflated.
        let radius = req.milling.as_ref().map(|m| m.tool_radius_mm);
        let cut_length = req.milling.as_ref().map(|m| m.tool_length_mm);
        let before_ac = stock.occupied_count();
        let mut tips = Vec::with_capacity(sample.poses.len());
        let mut axes = Vec::with_capacity(sample.poses.len());
        let mut asm_checker = match &assembly {
            Some(a) => Some(crate::assembly::AssemblyChecker::new(
                a,
                &fixtures,
                &mut collision_budget,
            )?),
            None => None,
        };
        for (i, pose) in sample.poses.iter().enumerate() {
            tips.push(Point3::from(pose.tip_mm));
            axes.push(Unit::new_normalize(Vector3::from(pose.axis)));
            if let (Some(r), Some(l)) = (radius, cut_length) {
                stock.remove_oriented_cutter(
                    &Point3::from(pose.tip_mm),
                    &Unit::new_normalize(Vector3::from(pose.axis)),
                    r,
                    l,
                );
            }
            if let Some(chk) = asm_checker.as_mut() {
                chk.check_step(
                    i,
                    sample.poses.len(),
                    &Point3::from(pose.tip_mm),
                    &Unit::new_normalize(Vector3::from(pose.axis)),
                    &stock,
                    progress,
                    0.7,
                    0.9,
                )?;
            }
            if i % 8 == 0 {
                progress.report(0.7 + 0.2 * (i as f64 / sample.poses.len() as f64), "ac-motion")?;
            }
        }
        if let Some(chk) = asm_checker {
            collisions.extend(chk.into_rows("ac", stock.h));
        }
        if radius.is_none() || cut_length.is_none() {
            warnings.push(
                "acMotion: milling.toolRadiusMM/toolLengthMM absent; oriented-cylinder removal skipped, poses returned only"
                    .into(),
            );
        }
        stages.push(StageOut {
            name: "ac-motion".into(),
            remaining_mm3: stock.occupied_count() as f64 * stock.cell_volume(),
            removed_mm3: (before_ac - stock.occupied_count()) as f64 * stock.cell_volume(),
        });
        if !fixtures.is_empty() && radius.is_some() && cut_length.is_some() {
            if let Some(asm) = &assembly {
                collisions.extend(collision_out(
                    crate::assembly::check_cutter_against_fixtures_with_clearance(
                        &fixtures,
                        &tips,
                        &axes,
                        radius.unwrap(),
                        cut_length.unwrap(),
                        asm.clearance_mm,
                        "ac",
                        &mut collision_budget,
                        progress,
                        0.9,
                        0.93,
                    )?,
                ));
            } else {
                collisions.extend(collision_out(check_cutter_against_fixtures(
                    &fixtures,
                    &tips,
                    &axes,
                    radius.unwrap(),
                    cut_length.unwrap(),
                    "ac",
                    &mut collision_budget,
                    progress,
                    0.9,
                    0.93,
                )?));
            }
        }
        ac_poses_out = Some(
            sample
                .poses
                .iter()
                .map(|p| AcPoseOut {
                    tip_mm: p.tip_mm,
                    axis: p.axis,
                    joints: p.joints,
                })
                .collect(),
        );
        frame_sink.capture(&stock, "ac", &mut frames)?;
        capabilities.push("exact-physical-c-travel-preserved".into());
    }

    // ---- final mesh + result --------------------------------------------------
    progress.report(0.93, "mesh")?;
    let final_mesh = mesh_stock(&stock, budget.max_triangles, &mut frame_sink.triangle_budget)?;
    capabilities.push("declared-stock-boundary-v1".into());
    capabilities.push("cylinder-domain-field-v1".into());
    let remaining = stock.occupied_count() as f64 * stock.cell_volume();
    if assembly.is_some()
        && !req.milling.as_ref().map(|m| m.enabled).unwrap_or(false)
        && req.ac_motion.is_none()
    {
        warnings.push(
            "tool-assembly supplied but neither milling nor acMotion ran; assembly collision was not exercised"
                .into(),
        );
    }
    let backend = if assembly.is_some() && req.cam.is_some() {
        format!("{} + tool-assembly-r2 + cam-r4", backend_string())
    } else if assembly.is_some() {
        format!("{} + tool-assembly-r2", backend_string())
    } else if req.cam.is_some() {
        format!("{} + cam-r4", backend_string())
    } else {
        backend_string()
    };
    progress.report(1.0, "done")?;

    Ok(CoreResult {
        ok: true,
        backend,
        // R5: starting occupancy of THIS invocation (continued occupancy when
        // initialStockState is supplied); removedMM3 is incremental.
        initial_mm3: start_occupancy,
        analytic_initial_mm3: initial_exact,
        remaining_mm3: remaining,
        removed_mm3: start_occupancy - remaining,
        vertices: final_mesh.0,
        triangles: final_mesh.1,
        paths: paths_out,
        stages,
        collisions,
        warnings,
        capabilities,
        frames: Some(frames),
        ac_poses: ac_poses_out,
        assembly_query_count: if assembly.is_some() || req.cam.is_some() { Some(collision_budget.parry_calls) } else { None },
        cam_report,
        sampled_cam_poses,
        // R5: exported on EVERY successful execution, even a fully machined
        // (empty) stock; removedCount is cumulative from the original stock.
        stock_state: stock.export_state(),
    })
}


#[cfg(test)]
mod tests {
    use super::*;

    fn require_closed_oriented(points: &[[f64;3]], faces: &[[u32;3]]) {
        let mut counts=std::collections::HashMap::<(u32,u32),(usize,i32)>::new();
        for t in faces {
            let a=points[t[0] as usize];let b=points[t[1] as usize];let c=points[t[2] as usize];
            let u=nalgebra::Vector3::new(b[0]-a[0],b[1]-a[1],b[2]-a[2]);
            let v=nalgebra::Vector3::new(c[0]-a[0],c[1]-a[1],c[2]-a[2]);
            assert!(u.cross(&v).norm_squared()>0.0,"no collapsed halo triangles");
            for i in 0..3 {
                let a=t[i];let b=t[(i+1)%3];let item=counts.entry((a.min(b),a.max(b))).or_default();
                item.0+=1;item.1+=if a<b { 1 } else { -1 };
            }
        }
        assert!(counts.values().all(|&(n,w)| n==2 && w==0),"closed, consistently oriented surface required");
    }

    #[test]
    fn declared_box_planes_and_right_angle_corners_do_not_expand_by_half_a_cell() {
        for (low,high,h) in [([-10.0,-8.0,0.0],[10.0,8.0,8.0],1.0),
                             ([-2.3,-1.1,-0.7],[2.2,1.4,3.65],0.7)] {
            let stock=Stock::box_stock(low,high,h,1<<20).unwrap();
            let before=stock.export_state();let mut budget=80_000;
            let (points,faces)=mesh_stock(&stock,80_000,&mut budget).unwrap();
            for i in 0..3 {
                assert_eq!(points.iter().map(|p|p[i]).fold(f64::INFINITY,f64::min),low[i]);
                assert_eq!(points.iter().map(|p|p[i]).fold(f64::NEG_INFINITY,f64::max),high[i]);
            }
            for &x in &[low[0],high[0]] { for &y in &[low[1],high[1]] { for &z in &[low[2],high[2]] {
                assert!(points.contains(&[x,y,z]),"retain each true corner, including non-grid-aligned planes");
            } } }
            assert!(faces.iter().all(|t| (0..3).any(|i| [low[i],high[i]].iter().any(|&v| t.iter().all(|&j| points[j as usize][i]==v)))));
            require_closed_oriented(&points,&faces);
            assert_eq!(stock.export_state().occupied_indices,before.occupied_indices);
            assert!(mesh_stock(&stock,8,&mut budget).is_err(),"insufficient mesh budget is explicit");
        }
    }

    #[test]
    fn bounded_box_with_bore_and_open_side_cut_is_closed_without_filling_the_bore() {
        let mut stock=Stock::box_stock([-10.0,-8.0,0.0],[10.0,8.0,8.0],1.0,1<<20).unwrap();
        stock.remove_oriented_cutter(&nalgebra::Point3::new(0.0,0.0,0.0),&nalgebra::Vector3::z(),2.0,8.0);
        stock.remove_oriented_cutter(&nalgebra::Point3::new(8.0,0.0,4.0),&nalgebra::Vector3::x(),1.0,5.0);
        let before=stock.export_state();let mut budget=80_000;
        let (points,faces)=mesh_stock(&stock,80_000,&mut budget).unwrap();
        require_closed_oriented(&points,&faces);
        assert!(points.iter().all(|p| (0..3).all(|i| p[i]>=stock.origin[i] && p[i]<=stock.physical_max[i])));
        assert!(points.iter().any(|p| p[2]>1.0 && p[2]<7.0 && p[0].hypot(p[1])<3.0));
        assert!(points.iter().filter(|p| p[2]>1.0 && p[2]<7.0).all(|p| p[0].hypot(p[1])>1.0));
        assert_eq!(stock.export_state().occupied_indices,before.occupied_indices);
        assert_eq!(stock.export_state().removed_count,before.removed_count);
    }

    #[test]
    fn nonintegral_cylinder_end_planes_are_not_rounded_to_grid_height() {
        let stock=Stock::cylinder(6.0,-0.25,7.13,0.7,1<<20).unwrap();let mut budget=80_000;
        let (points,faces)=mesh_stock(&stock,80_000,&mut budget).unwrap();
        require_closed_oriented(&points,&faces);
        assert!(points.iter().all(|p| p[2]>= -0.25 && p[2]<=7.13));
        assert_eq!(points.iter().map(|p|p[2]).fold(f64::NEG_INFINITY,f64::max),7.13);
    }

    #[test]
    fn facing_does_not_shrink_the_untouched_cylinder_layers() {
        let mut stock=Stock::cylinder(6.0,0.0,20.0,1.0,1<<20).unwrap();
        stock.apply_turning_path(&[[6.0,10.0],[0.0,10.0]],false).unwrap();
        assert!(stock.export_state().removed_count>0);
        let mut budget=80_000;let (points,faces)=mesh_stock(&stock,80_000,&mut budget).unwrap();
        require_closed_oriented(&points,&faces);
        let side:Vec<_>=points.iter().filter(|p| p[0].hypot(p[1])>1.0).collect();
        assert!(!side.is_empty());
        assert!(side.iter().all(|p| (p[0].hypot(p[1])-6.0).abs()<1e-12));
    }

    #[test]
    fn mixed_stock_mesh_retains_bore_slot_and_round_uncut_side() {
        let mut s = Stock::cylinder(12.0,0.0,40.0,1.0,1<<20).unwrap();
        s.remove_oriented_cutter(&nalgebra::Point3::new(0.0,0.0,0.0),&nalgebra::Vector3::z(),2.0,40.0);
        s.remove_oriented_cutter(&nalgebra::Point3::new(10.0,0.0,20.0),&nalgebra::Vector3::x(),2.0,8.0);
        assert!(s.axisymmetric_mesh(80_000).is_none());
        let before = s.export_state();let mut budget = 80_000;
        let (points,faces) = mesh_stock(&s,80_000,&mut budget).unwrap();
        require_closed_oriented(&points,&faces);
        assert!(points.iter().all(|p| p[0].hypot(p[1])<=12.0+1e-12 && p[2]>=0.0 && p[2]<=40.0));
        assert_eq!(s.export_state().occupied_indices,before.occupied_indices);
        let outer:Vec<f64> = points.iter().filter(|p| p[2]>8.0 && p[2]<32.0 && p[0]< -6.0)
            .map(|p| p[0].hypot(p[1])).collect();
        assert!(outer.len()>100);
        let error = outer.iter().map(|r| (r-12.0).abs()).fold(0.0,f64::max);
        assert!(error<0.75,"uncut round surface radial error {error} at 1 mm cells");
        let inner:Vec<_> = points.iter().filter(|p| p[2]>8.0 && p[2]<32.0 && p[0].hypot(p[1])<4.0).collect();
        assert!(inner.len()>100,"bore surface must remain, never fill the hole");
        assert!(inner.iter().all(|p| p[0].hypot(p[1])>1.0));
        assert!(points.iter().any(|p| p[0]>9.0 && p[0]<11.0 && p[1].abs()<1.0 && (p[2]-20.0).abs()<2.5),"actual radial slot must remain");
        let mut edges = std::collections::HashMap::<(u32,u32),usize>::new();
        for t in &faces { for i in 0..3 { let a=t[i];let b=t[(i+1)%3];*edges.entry((a.min(b),a.max(b))).or_default()+=1; } }
        assert!(edges.values().all(|&n| n==2),"mixed stock mesh must be closed");
    }

    #[test]
    fn mixed_cylinder_with_nonintegral_end_planes_keeps_a_closed_bore() {
        let mut stock=Stock::cylinder(6.0,-0.25,7.13,0.7,1<<20).unwrap();
        stock.remove_oriented_cutter(&nalgebra::Point3::new(0.0,0.0,-1.0),&nalgebra::Vector3::z(),2.0,10.0);
        stock.remove_oriented_cutter(&nalgebra::Point3::new(4.0,0.0,3.0),&nalgebra::Vector3::x(),1.0,5.0);
        let state=stock.export_state();let mut budget=80_000;
        let (points,faces)=mesh_stock(&stock,80_000,&mut budget).unwrap();
        require_closed_oriented(&points,&faces);
        assert!(points.iter().all(|p| p[0].hypot(p[1])<=6.0+1e-12 && p[2]>= -0.25 && p[2]<=7.13));
        let middle:Vec<_>=points.iter().filter(|p| p[2]>1.0 && p[2]<6.0).collect();
        assert!(middle.iter().any(|p| p[0].hypot(p[1])<3.0));
        assert!(middle.iter().all(|p| p[0].hypot(p[1])>1.0),"do not cap or fill the real bore");
        assert_eq!(stock.export_state().occupied_indices,state.occupied_indices);
        assert_eq!(stock.export_state().removed_count,state.removed_count);
    }

    const STOCK_JSON: &str = r#""stock": {"shape": "cylinder", "radiusMM": 6, "zMinMM": 0, "zMaxMM": 20, "resolutionMM": 1}"#;

    fn turning_job(points: &str) -> String {
        format!(
            r#"{{
            "formatVersion": 1,
            {STOCK_JSON},
            "turning": {{"enabled": true, "toolNoseRadiusMM": 0.4}},
            "turningPlan": {{"ok": true, "paths": [{{"kind": "rough", "points": {points}, "feedMMPerMinute": 800}}]}},
            "budget": {{"maxCells": 131072}}
        }}"#
        )
    }

    #[test]
    fn every_successful_execution_exports_stock_state() {
        let r = run_core(&turning_job("[[4.0, 5.0], [4.0, 15.0]]"), &Progress::quiet()).unwrap();
        let st = &r.stock_state;
        assert_eq!(st.format_version, 1);
        assert_eq!(st.shape, "cylinder");
        assert_eq!(st.radius_mm, Some(6.0));
        assert!(st.occupied_indices.windows(2).all(|w| w[0] < w[1]));
        // removedCount is cumulative: original initial == occupied + removed.
        let fresh = Stock::cylinder(6.0, 0.0, 20.0, 1.0, 1 << 20).unwrap();
        let initial = fresh.occupied_count();
        assert_eq!(st.occupied_indices.len() as u64 + st.removed_count, initial);
        // Volume semantics: initialMM3 is THIS invocation's starting occupancy
        // (fresh here), removedMM3 is incremental.
        let cell = fresh.cell_volume();
        assert!((r.initial_mm3 - initial as f64 * cell).abs() < 1e-9);
        assert!((r.removed_mm3 - (r.initial_mm3 - r.remaining_mm3)).abs() < 1e-9);
    }

    #[test]
    fn continuation_through_core_shares_occupancy_across_jobs() {
        // Job 1: rough cut.
        let job1 = turning_job("[[4.0, 5.0], [4.0, 15.0]]");
        let r1 = run_core(&job1, &Progress::quiet()).unwrap();
        // Job 2: finish cut continued from job 1's exported state.
        let continued = serde_json::to_string(&r1.stock_state).unwrap();
        let job2 = format!(
            r#"{{
                "formatVersion": 1,
                {STOCK_JSON},
                "initialStockState": {continued},
                "turning": {{"enabled": true, "toolNoseRadiusMM": 0.4}},
                "turningPlan": {{"ok": true, "paths": [{{"kind": "finish", "points": [[3.0, 6.0], [3.0, 14.0]], "feedMMPerMinute": 600}}]}},
                "budget": {{"maxCells": 131072}}
            }}"#
        );
        let r2 = run_core(&job2, &Progress::quiet()).unwrap();

        // initialMM3 of job 2 == remainingMM3 of job 1 (same workpiece).
        assert!((r2.initial_mm3 - r1.remaining_mm3).abs() < 1e-9);
        // removedMM3 of job 2 is incremental.
        assert!((r2.removed_mm3 - (r1.remaining_mm3 - r2.remaining_mm3)).abs() < 1e-9);
        // removedCount is cumulative and grows; occupancy strictly shrinks.
        assert!(r2.stock_state.removed_count > r1.stock_state.removed_count);
        assert!(r2.stock_state.occupied_indices.len() < r1.stock_state.occupied_indices.len());
        let occ1: std::collections::HashSet<usize> =
            r1.stock_state.occupied_indices.iter().copied().collect();
        let occ2: std::collections::HashSet<usize> =
            r2.stock_state.occupied_indices.iter().copied().collect();
        assert!(occ2.is_subset(&occ1), "no removed cell restored");
        // A continued stage records the starting occupancy.
        assert!(r2.stages.iter().any(|s| s.name == "continued"));
        assert!(r2.warnings.iter().any(|w| w.contains("stockState")));
        // Job 2 equals one continuous two-path job.
        let continuous = turning_job("[[4.0, 5.0], [4.0, 15.0]]");
        let continuous = continuous.replace(
            r#""paths": [{"kind": "rough", "points": [[4.0, 5.0], [4.0, 15.0]], "feedMMPerMinute": 800}]"#,
            r#""paths": [{"kind": "rough", "points": [[4.0, 5.0], [4.0, 15.0]], "feedMMPerMinute": 800}, {"kind": "finish", "points": [[3.0, 6.0], [3.0, 14.0]], "feedMMPerMinute": 600}]"#,
        );
        let rc = run_core(&continuous, &Progress::quiet()).unwrap();
        assert_eq!(rc.remaining_mm3, r2.remaining_mm3);
        assert_eq!(rc.stock_state.removed_count, r2.stock_state.removed_count);
    }

    #[test]
    fn corrupt_continuation_state_fails_the_core() {
        let job1 = turning_job("[[4.0, 5.0], [4.0, 15.0]]");
        let r1 = run_core(&job1, &Progress::quiet()).unwrap();
        let mut forged = r1.stock_state.clone();
        // Forge: claim zero cumulative removal (removed cells restored).
        forged.removed_count = 0;
        let job2 = format!(
            r#"{{
                "formatVersion": 1,
                {STOCK_JSON},
                "initialStockState": {},
                "turning": {{"enabled": true}},
                "turningPlan": {{"ok": true, "paths": [{{"kind": "rough", "points": [[3.0, 6.0], [3.0, 14.0]]}}]}}
            }}"#,
            serde_json::to_string(&forged).unwrap()
        );
        match run_core(&job2, &Progress::quiet()) {
            Err(Fail::Message(m)) => assert!(m.contains("initialStockState")),
            other => panic!("expected corrupt-state failure, got {other:?}"),
        }
    }

    #[test]
    fn fully_machined_continuation_succeeds_with_empty_mesh() {
        // Empty continued state: everything already removed.
        let fresh = Stock::cylinder(6.0, 0.0, 20.0, 1.0, 1 << 20).unwrap();
        let initial = fresh.occupied_count();
        let empty = crate::model::StockState {
            format_version: 1,
            dimensions: [fresh.nx, fresh.ny, fresh.nz],
            origin_mm: fresh.origin,
            resolution_mm: fresh.h,
            shape: "cylinder".into(),
            radius_mm: Some(6.0),
            declared_max_mm: Some(fresh.physical_max),
            occupied_indices: Vec::new(),
            removed_count: initial,
        };
        let job = format!(
            r#"{{
                "formatVersion": 1,
                {STOCK_JSON},
                "initialStockState": {},
                "turning": {{"enabled": true}},
                "turningPlan": {{"ok": true, "paths": [{{"kind": "rough", "points": [[2.0, 2.0], [2.0, 4.0]]}}]}}
            }}"#,
            serde_json::to_string(&empty).unwrap()
        );
        let r = run_core(&job, &Progress::quiet()).unwrap();
        assert_eq!(r.remaining_mm3, 0.0);
        assert!(r.vertices.is_empty() && r.triangles.is_empty());
        assert!(r.stock_state.occupied_indices.is_empty());
        assert_eq!(r.stock_state.removed_count, initial);
    }

    #[test]
    fn turning_approach_negative_z_fences_and_rejects_garbage() {
        // Backside facing: lower face cut at z=2 removes only the lower cap;
        // the capability fences stale binaries.
        let job = format!(
            r#"{{
                "formatVersion": 1,
                "stock": {{"shape": "cylinder", "radiusMM": 6, "zMinMM": 0, "zMaxMM": 40, "resolutionMM": 1}},
                "turning": {{"enabled": true}},
                "turningApproach": "negativeZ",
                "turningPlan": {{"ok": true, "paths": [{{"kind": "face", "points": [[0.0, 2.0], [6.0, 2.0]]}}]}},
                "budget": {{"maxCells": 131072}}
            }}"#
        );
        let r = run_core(&job, &Progress::quiet()).unwrap();
        assert!(r
            .capabilities
            .iter()
            .any(|c| c == "negative-z-turning-envelope"));
        // Only the two lower slabs removed.
        let cell = (1.0f64).powi(3);
        let removed = r.removed_mm3 / cell;
        let fresh = Stock::cylinder(6.0, 0.0, 40.0, 1.0, 1 << 20).unwrap();
        let full = fresh.occupied_count() as f64;
        assert!(removed > 0.0 && removed < full * 0.1, "removed {removed}");
        // Stock state remains in the original grid.
        assert_eq!(r.stock_state.dimensions[2], 40);

        // Unsupported approach strings fail explicitly (never silent positiveZ).
        let bad = job.replace("\"negativeZ\"", "\"sidewaysX\"");
        match run_core(&bad, &Progress::quiet()) {
            Err(Fail::Message(m)) => assert!(m.contains("turningApproach")),
            other => panic!("expected turningApproach failure, got {other:?}"),
        }

        // Default (absent) keeps the historical positive-Z behaviour and
        // does NOT claim the negative capability.
        let plain = job.replace("\"turningApproach\": \"negativeZ\",", "");
        let r2 = run_core(&plain, &Progress::quiet()).unwrap();
        assert!(!r2
            .capabilities
            .iter()
            .any(|c| c == "negative-z-turning-envelope"));
        // positiveZ face at z=2 removes everything ABOVE z=2: far more.
        assert!(r2.removed_mm3 > r.removed_mm3 * 5.0);
    }
}
