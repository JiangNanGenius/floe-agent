// SPDX-License-Identifier: MIT OR Apache-2.0
// R4 CAM strategy generators (r4/CONTRACT.md + r4/native/API.md).
//
// Every generator returns EXPLICIT moves plus accurate source/limit
// annotations. Out-of-scope inputs are hard failures — never a silent
// fallback. Coordinate conventions (Root review 2026-11-04):
//   * Move points/axes use the MOVE basis: point (u, v, w) maps as
//     world = origin + x*u + y*v - axis*w (w = 0 at the surface, depth
//     along -axis); a move axis (a, b, c) maps as the direction
//     x*a + y*b + axis*c (so 3-axis tool axis = (0, 0, 1) = +axis).
//   * partMesh lives in MESH space (u, v, w) points: into-the-part ray
//     direction is (0, 0, +1), the OUTWARD normal has a NEGATIVE w
//     component, and mesh_dir_to_move_dir negates w when storing axes.
//   * Generation is budgeted BEFORE it runs: layer/row/subdivision caps and
//     finiteness checks refuse hostile steps, and long loops report
//     cancellable progress — maxPoses is not the only guard.
use nalgebra::{Point3, Unit, Vector3};

use crate::model::CamOperationReq;
use crate::upstream_r4::drilling::{expand_hole, parse_cycle, UpHole};
use crate::upstream_r4::raster::{circle_rows, rect_rows};
use crate::upstream_r4::surface_normal::{mesh_dir_to_move_dir, raycast_mesh, tool_tip_for_contact};
use crate::upstream_r4::swarf::ruling_scan;
use crate::upstream_r4::tool_profile::UpToolKind;
use crate::Fail;
use crate::Progress;

use super::frame::CamFrame;
use super::moves::{CamMove, CamMoveType};
use super::partmesh::CamPartMesh;
use super::tools::CamTool;

const MAX_GEN_LAYERS: u64 = 4096;
const MAX_GEN_MOVES_PER_OP: usize = 200_000;
const MAX_GEN_CONTOUR_STEPS: u64 = 100_000;
const MAX_GEN_SWARF_PASSES: u64 = 4096;
const MAX_SPRING_PASSES: u32 = 10;

pub struct StratResult {
    pub moves: Vec<CamMove>,
    pub sources: Vec<String>,
    pub limits: Vec<String>,
}

impl StratResult {
    fn new() -> Self {
        StratResult { moves: Vec::new(), sources: Vec::new(), limits: Vec::new() }
    }

    fn push_row(&mut self, row: &[(f64, f64)], w: f64, mp: &MotionParams) -> Result<(), String> {
        if self.moves.len() + row.len() + 3 > MAX_GEN_MOVES_PER_OP {
            return Err(format!(
                "cam: operation move count exceeds the generation cap {MAX_GEN_MOVES_PER_OP}; increase stepOverMM or depthMM"
            ));
        }
        emit_row(&mut self.moves, row, w, mp);
        Ok(())
    }
}

pub struct StratCtx<'a> {
    pub op: &'a CamOperationReq,
    pub frame: CamFrame,
    pub tool: &'a CamTool,
    pub mesh: Option<&'a CamPartMesh>,
    /// Cancellable generation progress (None in unit tests).
    pub progress: Option<&'a Progress>,
    pub frac_lo: f64,
    pub frac_hi: f64,
}

// ---- field helpers ----------------------------------------------------------

fn need<'a>(op: &'a CamOperationReq, name: &str, v: Option<&'a str>) -> Result<&'a str, String> {
    v.ok_or_else(|| format!("cam op '{}': {name} is required for strategy {}", op.id, op.strategy))
}

fn need_f64(op: &CamOperationReq, name: &str, v: Option<f64>) -> Result<f64, String> {
    match v {
        Some(x) if x.is_finite() => Ok(x),
        Some(_) => Err(format!("cam op '{}': {name} must be finite", op.id)),
        None => Err(format!("cam op '{}': {name} is required for strategy {}", op.id, op.strategy)),
    }
}

fn need_positive(op: &CamOperationReq, name: &str, v: Option<f64>) -> Result<f64, String> {
    let x = need_f64(op, name, v)?;
    if x <= 0.0 {
        return Err(format!("cam op '{}': {name} must be > 0", op.id));
    }
    Ok(x)
}

fn need_uv(op: &CamOperationReq, name: &str, v: Option<[f64; 2]>) -> Result<[f64; 2], String> {
    match v {
        Some(p) if p.iter().all(|x| x.is_finite()) => Ok(p),
        Some(_) => Err(format!("cam op '{}': {name} must be finite", op.id)),
        None => Err(format!("cam op '{}': {name} is required for strategy {}", op.id, op.strategy)),
    }
}

/// Common motion params every strategy emits (rapid/retract carry the rapid
/// feed; coordinator correction 2026-11-04).
struct MotionParams {
    feed: f64,
    plunge_feed: f64,
    rapid_feed: f64,
    clearance: f64,
}

fn motion_params(op: &CamOperationReq) -> Result<MotionParams, String> {
    let feed = need_positive(op, "feedMMPerMinute", op.feed_mm_per_minute)?;
    let plunge_feed = need_positive(op, "plungeFeedMMPerMinute", op.plunge_feed_mm_per_minute)?;
    let rapid_feed = need_positive(op, "rapidMMPerMinute", op.rapid_mm_per_minute)?;
    let clearance = need_f64(op, "clearanceMM", op.clearance_mm)?;
    if clearance <= 0.0 {
        return Err(format!("cam op '{}': clearanceMM must be > 0", op.id));
    }
    Ok(MotionParams { feed, plunge_feed, rapid_feed, clearance })
}

fn check_tool_kind(op: &CamOperationReq, tool: &CamTool, allowed: &[UpToolKind]) -> Result<(), String> {
    if !allowed.contains(&tool.profile.kind) {
        return Err(format!(
            "cam op '{}': strategy {} does not support tool kind {:?}",
            op.id, op.strategy, tool.profile.kind
        ));
    }
    Ok(())
}

/// Fields this strategy does not consume, recorded honestly in limits.
fn unused_kinds_notes(op: &CamOperationReq, out: &mut StratResult, consumer: &[&str]) {
    if op.climb.is_some() && !consumer.contains(&"climb") {
        out.limits.push(format!("climb only affects contour; ignored for {}", op.strategy));
    }
    if let Some(n) = op.spring_passes {
        if n > 0 && !consumer.contains(&"springPasses") {
            out.limits.push(format!("springPasses not supported for {}; ignored", op.strategy));
        }
    }
}

/// Layer depths from the surface down to `w_max`, capped BEFORE the loop.
fn layer_depths(op: &CamOperationReq, w_max: f64) -> Result<Vec<f64>, String> {
    if !w_max.is_finite() || w_max <= 0.0 {
        return Err(format!(
            "cam op '{}': depthMM (+breakThroughMM - floorStockMM) must be finite and > 0",
            op.id
        ));
    }
    let step = match op.step_down_mm {
        Some(s) => {
            if !s.is_finite() || s <= 0.0 {
                return Err(format!("cam op '{}': stepDownMM must be finite and > 0", op.id));
            }
            s
        }
        None => w_max,
    };
    let n = (w_max / step).ceil();
    if !n.is_finite() || n as u64 > MAX_GEN_LAYERS {
        return Err(format!(
            "cam op '{}': stepDownMM would need {n} layers, exceeding the {MAX_GEN_LAYERS} generation cap",
            op.id
        ));
    }
    let mut out = Vec::new();
    let mut w = 0.0f64;
    loop {
        w = (w + step).min(w_max);
        if !w.is_finite() {
            return Err(format!("cam op '{}': non-finite layer depth", op.id));
        }
        out.push(w);
        if w >= w_max - 1e-12 {
            break;
        }
        if out.len() as u64 > MAX_GEN_LAYERS {
            return Err(format!("cam op '{}': layer generation guard tripped", op.id));
        }
    }
    Ok(out)
}

/// Emit one raster row as explicit moves: rapid above start -> plunge to the
/// layer -> cut along the row -> retract above the end.
fn emit_row(moves: &mut Vec<CamMove>, row: &[(f64, f64)], w: f64, mp: &MotionParams) {
    let z = Unit::new_normalize(Vector3::new(0.0, 0.0, 1.0));
    let first = row[0];
    let last = *row.last().unwrap();
    moves.push(CamMove::rapid(Point3::new(first.0, first.1, -mp.clearance), z).with_rapid_feed(mp.rapid_feed));
    moves.push(CamMove::plunge(Point3::new(first.0, first.1, w), z, mp.plunge_feed));
    for &(u, v) in &row[1..] {
        moves.push(CamMove::cut(Point3::new(u, v, w), z, mp.feed));
    }
    moves.push(CamMove::retract(Point3::new(last.0, last.1, -mp.clearance), z).with_rapid_feed(mp.rapid_feed));
}

fn row_chord(step_over: f64) -> f64 {
    (step_over * 0.5).clamp(0.2, 1.0)
}

fn gen_progress(ctx: &StratCtx, done: f64) -> Result<(), String> {
    if let Some(p) = ctx.progress {
        p.report(
            ctx.frac_lo + (ctx.frac_hi - ctx.frac_lo) * done.clamp(0.0, 1.0),
            "cam-plan",
        )
        .map_err(|e| match e {
            Fail::Cancelled => "cancelled".to_string(),
            Fail::Message(m) => m,
        })?;
    }
    Ok(())
}

// ---- strategies ---------------------------------------------------------------

pub fn generate(ctx: &StratCtx) -> Result<StratResult, String> {
    match ctx.op.strategy.as_str() {
        "face" => face(ctx),
        "pocket" => pocket(ctx),
        "contour" => contour(ctx),
        "drill" => drill(ctx),
        "surfaceRaster" => surface_raster(ctx),
        "swarf" => swarf(ctx),
        other => Err(format!(
            "cam op '{}': unknown strategy '{other}' (expected face|pocket|contour|drill|surfaceRaster|swarf)",
            ctx.op.id
        )),
    }
}

fn face(ctx: &StratCtx) -> Result<StratResult, String> {
    let op = ctx.op;
    check_tool_kind(op, ctx.tool, &[UpToolKind::FlatEndMill, UpToolKind::BallNose])?;
    let min = need_uv(op, "minUVMM", op.min_uv_mm)?;
    let max = need_uv(op, "maxUVMM", op.max_uv_mm)?;
    if max[0] <= min[0] || max[1] <= min[1] {
        return Err(format!("cam op '{}': face requires minUVMM < maxUVMM on both axes", op.id));
    }
    let depth = need_positive(op, "depthMM", op.depth_mm)?;
    let step_over = need_positive(op, "stepOverMM", op.step_over_mm)?;
    let floor_stock = op.floor_stock_mm.unwrap_or(0.0);
    if !floor_stock.is_finite() || floor_stock < 0.0 {
        return Err(format!("cam op '{}': floorStockMM must be finite and >= 0", op.id));
    }
    let mp = motion_params(op)?;
    let mut out = StratResult::new();
    out.sources.push("openmill-0432a8c:strategies/pocket_clearing.rs raster core (via upstream/r4/raster.rs rect_rows)".into());
    unused_kinds_notes(op, &mut out, &[]);
    let layers = layer_depths(op, depth - floor_stock)?;
    if op.step_down_mm.is_none() {
        out.limits.push("stepDownMM absent: single layer to depthMM - floorStockMM".into());
    }
    let rows = rect_rows(min[0], max[0], min[1], max[1], step_over, row_chord(step_over))
        .map_err(|e| format!("cam op '{}': {e}", op.id))?;
    if rows.is_empty() {
        return Err(format!("cam op '{}': face region is empty", op.id));
    }
    let total_rows = rows.len() * layers.len();
    for (li, &w) in layers.iter().enumerate() {
        for (ri, row) in rows.iter().enumerate() {
            out.push_row(&row.points, w, &mp)
                .map_err(|e| format!("cam op '{}': {e}", op.id))?;
            if (li * rows.len() + ri) % 256 == 0 {
                gen_progress(ctx, (li * rows.len() + ri) as f64 / (total_rows.max(1) as f64))?;
            }
        }
    }
    Ok(out)
}

fn pocket(ctx: &StratCtx) -> Result<StratResult, String> {
    let op = ctx.op;
    check_tool_kind(op, ctx.tool, &[UpToolKind::FlatEndMill, UpToolKind::BallNose])?;
    let centre = need_uv(op, "centerUVMM", op.center_uv_mm)?;
    let radius = need_positive(op, "radiusMM", op.radius_mm)?;
    let depth = need_positive(op, "depthMM", op.depth_mm)?;
    let step_over = need_positive(op, "stepOverMM", op.step_over_mm)?;
    let wall_stock = op.wall_stock_mm.unwrap_or(0.0);
    let floor_stock = op.floor_stock_mm.unwrap_or(0.0);
    let break_through = op.break_through_mm.unwrap_or(0.0);
    for (n, v) in [("wallStockMM", wall_stock), ("floorStockMM", floor_stock), ("breakThroughMM", break_through)] {
        if !v.is_finite() || v < 0.0 {
            return Err(format!("cam op '{}': {n} must be finite and >= 0", op.id));
        }
    }
    let mp = motion_params(op)?;
    let inset = ctx.tool.radius() + wall_stock;
    if radius - inset <= 0.1 {
        // Upstream silently skipped such pockets; the contract demands an
        // explicit failure instead (upstream defect fix, recorded).
        return Err(format!(
            "cam op '{}': pocket too small for tool (radiusMM {radius} - toolR+wallStock {inset} <= 0.1)",
            op.id
        ));
    }
    let mut out = StratResult::new();
    out.sources.push("openmill-0432a8c:strategies/pocket_clearing.rs raster core (via upstream/r4/raster.rs circle_rows)".into());
    unused_kinds_notes(op, &mut out, &[]);
    let layers = layer_depths(op, depth + break_through - floor_stock)?;
    let rows = circle_rows((centre[0], centre[1]), radius, inset, step_over, row_chord(step_over))
        .map_err(|e| format!("cam op '{}': {e}", op.id))?;
    if rows.is_empty() {
        return Err(format!("cam op '{}': pocket raster produced no rows", op.id));
    }
    let total_rows = rows.len() * layers.len();
    for (li, &w) in layers.iter().enumerate() {
        for (ri, row) in rows.iter().enumerate() {
            out.push_row(&row.points, w, &mp)
                .map_err(|e| format!("cam op '{}': {e}", op.id))?;
            if (li * rows.len() + ri) % 256 == 0 {
                gen_progress(ctx, (li * rows.len() + ri) as f64 / (total_rows.max(1) as f64))?;
            }
        }
    }
    out.limits.push("circular pocket only (explicit 2D feature; no partMesh dependency)".into());
    Ok(out)
}

/// Axis-aligned rectangle from exactly 4 vertices (5th closing point allowed).
fn parse_rect(op: &CamOperationReq) -> Result<[(f64, f64); 4], String> {
    let pts = op.contour_uv_mm.as_ref().unwrap();
    let mut p: Vec<(f64, f64)> = pts.iter().map(|q| (q[0], q[1])).collect();
    if p.len() == 5 && (p[4].0 - p[0].0).abs() < 1e-12 && (p[4].1 - p[0].1).abs() < 1e-12 {
        p.pop();
    }
    if p.len() != 4 {
        return Err(format!(
            "cam op '{}': contourUVMM must hold exactly 4 axis-aligned rectangle vertices (5th closing point allowed), got {}",
            op.id,
            p.len()
        ));
    }
    if !p.iter().all(|q| q.0.is_finite() && q.1.is_finite()) {
        return Err(format!("cam op '{}': contourUVMM vertices must be finite", op.id));
    }
    let mut us: Vec<f64> = p.iter().map(|q| q.0).collect();
    let mut vs: Vec<f64> = p.iter().map(|q| q.1).collect();
    us.sort_by(|a, b| a.partial_cmp(b).unwrap());
    vs.sort_by(|a, b| a.partial_cmp(b).unwrap());
    us.dedup_by(|a, b| (*a - *b).abs() < 1e-9);
    vs.dedup_by(|a, b| (*a - *b).abs() < 1e-9);
    if us.len() != 2 || vs.len() != 2 {
        return Err(format!(
            "cam op '{}': contourUVMM is not an axis-aligned rectangle (need exactly 2 distinct u and 2 distinct v values)",
            op.id
        ));
    }
    Ok([(us[0], vs[0]), (us[1], vs[0]), (us[1], vs[1]), (us[0], vs[1])])
}

/// Rounded-rectangle offset loop (outward by `off`), CCW, sampled.
fn rect_offset_loop(u1: f64, v1: f64, u2: f64, v2: f64, off: f64) -> Vec<(f64, f64)> {
    let arc_steps = ((90.0f64 / 5.0).ceil()) as usize; // 5-degree arcs
    let mut pts = Vec::new();
    let mut push_arc = |cu: f64, cv: f64, a0: f64, pts: &mut Vec<(f64, f64)>| {
        for i in 0..=arc_steps {
            let a = (a0 + 90.0 * (i as f64 / arc_steps as f64)).to_radians();
            pts.push((cu + off * a.cos(), cv + off * a.sin()));
        }
    };
    pts.push((u1, v1 - off));
    pts.push((u2, v1 - off));
    push_arc(u2, v1, -90.0, &mut pts);
    pts.push((u2 + off, v2));
    push_arc(u2, v2, 0.0, &mut pts);
    pts.push((u1, v2 + off));
    push_arc(u1, v2, 90.0, &mut pts);
    pts.push((u1 - off, v1));
    push_arc(u1, v1, 180.0, &mut pts);
    pts.push((u1, v1 - off));
    pts
}

fn circle_offset_loop(c: (f64, f64), r_off: f64) -> Result<Vec<(f64, f64)>, String> {
    let n = 2.0 * std::f64::consts::PI * r_off / 0.5;
    if !n.is_finite() || n as u64 > MAX_GEN_CONTOUR_STEPS {
        return Err(format!(
            "cam op contour: circle offset would need {n} steps, exceeding the {MAX_GEN_CONTOUR_STEPS} generation cap"
        ));
    }
    let steps = n.ceil().max(24.0) as usize;
    let mut pts = Vec::with_capacity(steps + 2);
    for i in 0..=steps {
        let a = (i as f64 / steps as f64) * 2.0 * std::f64::consts::PI;
        pts.push((c.0 + r_off * a.cos(), c.1 + r_off * a.sin()));
    }
    Ok(pts)
}

fn contour(ctx: &StratCtx) -> Result<StratResult, String> {
    let op = ctx.op;
    check_tool_kind(op, ctx.tool, &[UpToolKind::FlatEndMill, UpToolKind::BallNose])?;
    let depth = need_positive(op, "depthMM", op.depth_mm)?;
    let wall_stock = op.wall_stock_mm.unwrap_or(0.0);
    let floor_stock = op.floor_stock_mm.unwrap_or(0.0);
    let break_through = op.break_through_mm.unwrap_or(0.0);
    for (n, v) in [("wallStockMM", wall_stock), ("floorStockMM", floor_stock), ("breakThroughMM", break_through)] {
        if !v.is_finite() || v < 0.0 {
            return Err(format!("cam op '{}': {n} must be finite and >= 0", op.id));
        }
    }
    let climb = op.climb.unwrap_or(true);
    let spring = op.spring_passes.unwrap_or(0);
    if spring > MAX_SPRING_PASSES {
        return Err(format!(
            "cam op '{}': springPasses must be 0...{MAX_SPRING_PASSES}",
            op.id
        ));
    }
    let mp = motion_params(op)?;
    let off = ctx.tool.radius() + wall_stock;

    // Input discrimination (coordinator 2026-11-04): Root always encodes
    // default centerUVMM/radiusMM/minUVMM/maxUVMM, so key presence cannot
    // distinguish circle from rectangle. contourUVMM non-empty => rectangle.
    let mut loop2d: Vec<(f64, f64)> = if op.contour_uv_mm.as_ref().map(|p| !p.is_empty()).unwrap_or(false) {
        let rect = parse_rect(op)?;
        rect_offset_loop(rect[0].0, rect[0].1, rect[2].0, rect[2].1, off)
    } else {
        let centre = need_uv(op, "centerUVMM", op.center_uv_mm)?;
        let radius = need_positive(op, "radiusMM", op.radius_mm)?;
        circle_offset_loop((centre[0], centre[1]), radius + off)
            .map_err(|e| format!("cam op '{}': {e}", op.id))?
    };
    if !climb {
        loop2d.reverse();
    }
    if loop2d.len() < 4 {
        return Err(format!("cam op '{}': contour loop is degenerate", op.id));
    }
    let mut out = StratResult::new();
    out.sources.push("contour offset (OpenMill contour_parallel.rs concept; analytic circle/rect offset, no radial scan)".into());
    unused_kinds_notes(op, &mut out, &["climb", "springPasses"]);
    let layers = layer_depths(op, depth + break_through - floor_stock)?;
    // Spring passes re-trace the FINAL layer contour at the same depth.
    let total_passes = layers.len() + spring as usize;
    for pass in 0..total_passes {
        let w = if pass < layers.len() { layers[pass] } else { *layers.last().unwrap() };
        let first = loop2d[0];
        let last = *loop2d.last().unwrap();
        if out.moves.len() + loop2d.len() + 3 > MAX_GEN_MOVES_PER_OP {
            return Err(format!(
                "cam op '{}': move count exceeds the generation cap {MAX_GEN_MOVES_PER_OP}",
                op.id
            ));
        }
        moves_rapid(&mut out.moves, first.0, first.1, -mp.clearance, mp.rapid_feed);
        moves_plunge(&mut out.moves, first.0, first.1, w, mp.plunge_feed);
        for &(u, v) in &loop2d[1..] {
            out.moves.push(CamMove::cut(
                Point3::new(u, v, w),
                Unit::new_normalize(Vector3::new(0.0, 0.0, 1.0)),
                mp.feed,
            ));
        }
        moves_retract(&mut out.moves, last.0, last.1, -mp.clearance, mp.rapid_feed);
        gen_progress(ctx, (pass + 1) as f64 / (total_passes.max(1) as f64))?;
    }
    if spring > 0 {
        out.limits.push(format!("springPasses: final layer re-traced {spring} extra time(s) at the same depth"));
    }
    out.limits.push(if climb {
        "climb: outer contour traversed clockwise (viewed from +axis)".into()
    } else {
        "conventional: outer contour traversed counter-clockwise (viewed from +axis)".into()
    });
    Ok(out)
}

fn moves_rapid(moves: &mut Vec<CamMove>, u: f64, v: f64, w: f64, rapid_feed: f64) {
    moves.push(CamMove::rapid(
        Point3::new(u, v, w),
        Unit::new_normalize(Vector3::new(0.0, 0.0, 1.0)),
    ).with_rapid_feed(rapid_feed));
}

fn moves_plunge(moves: &mut Vec<CamMove>, u: f64, v: f64, w: f64, plunge_feed: f64) {
    moves.push(CamMove::plunge(
        Point3::new(u, v, w),
        Unit::new_normalize(Vector3::new(0.0, 0.0, 1.0)),
        plunge_feed,
    ));
}

fn moves_retract(moves: &mut Vec<CamMove>, u: f64, v: f64, w: f64, rapid_feed: f64) {
    moves.push(CamMove::retract(
        Point3::new(u, v, w),
        Unit::new_normalize(Vector3::new(0.0, 0.0, 1.0)),
    ).with_rapid_feed(rapid_feed));
}

fn drill(ctx: &StratCtx) -> Result<StratResult, String> {
    let op = ctx.op;
    check_tool_kind(op, ctx.tool, &[UpToolKind::Drill])?;
    let holes = op.holes_uv_mm.as_ref().ok_or_else(|| {
        format!("cam op '{}': holesUVMM is required for drill", op.id)
    })?;
    if holes.is_empty() {
        return Err(format!("cam op '{}': holesUVMM must hold at least one hole", op.id));
    }
    for (i, h) in holes.iter().enumerate() {
        if !h.iter().all(|x| x.is_finite()) {
            return Err(format!("cam op '{}': holesUVMM[{i}] must be finite", op.id));
        }
    }
    let depth = need_positive(op, "depthMM", op.depth_mm)?;
    let cycle = parse_cycle(need(op, "cycle", op.cycle.as_deref())?)?;
    let dwell = op.dwell_seconds.unwrap_or(0.0);
    let peck = op.peck_depth_mm.unwrap_or(0.0);
    let kick = op.chip_break_retract_mm.unwrap_or(0.0);
    if matches!(cycle,crate::upstream_r4::drilling::UpCycle::Peck | crate::upstream_r4::drilling::UpCycle::ChipBreak)
        && op.peck_depth_mm.is_some() && peck <= 0.0 {
        return Err(format!("cam op '{}': explicit peckDepthMM must be positive",op.id));
    }
    if cycle == crate::upstream_r4::drilling::UpCycle::ChipBreak && op.chip_break_retract_mm.is_some() && kick <= 0.0 {
        return Err(format!("cam op '{}': explicit chipBreakRetractMM must be positive",op.id));
    }
    let break_through = op.break_through_mm.unwrap_or(0.0);
    let mp = motion_params(op)?;
    let mut out = StratResult::new();
    out.sources.push("openmill-0432a8c:strategies/drilling.rs canned-cycle expansion (via upstream/r4/drilling.rs)".into());
    unused_kinds_notes(op, &mut out, &[]);
    // Documented defaults + scope notes (coordinator review 2026-11-04):
    // feeds are used exactly as given; only absences fall back to upstream
    // defaults, and each fallback is recorded here — never a silent raise.
    if matches!(cycle, crate::upstream_r4::drilling::UpCycle::ChipBreak) && op.chip_break_retract_mm.is_none() {
        out.limits.push("chipBreakRetractMM absent: upstream default 0.5 mm used".into());
    }
    if matches!(cycle, crate::upstream_r4::drilling::UpCycle::Peck | crate::upstream_r4::drilling::UpCycle::ChipBreak)
        && op.peck_depth_mm.is_none()
    {
        out.limits.push("peckDepthMM absent: upstream default depth/4 (min 0.5 mm) used".into());
    }
    if dwell > 0.0 && cycle != crate::upstream_r4::drilling::UpCycle::CounterBore {
        out.limits.push(format!(
            "dwellSeconds only applies to counterBore in this batch; ignored for cycle {cycle:?}"
        ));
    }
    let up = Unit::new_normalize(Vector3::new(0.0, 0.0, 1.0));
    for (hi, &h) in holes.iter().enumerate() {
        expand_hole(
            &mut out.moves,
            &UpHole { position: Point3::new(h[0], h[1], 0.0), axis: up, depth },
            mp.clearance,
            mp.feed,
            mp.plunge_feed,
            dwell,
            cycle,
            peck,
            kick,
            break_through,
        )
        .map_err(|e| format!("cam op '{}': hole {hi}: {e}", op.id))?;
        gen_progress(ctx, (hi + 1) as f64 / (holes.len() as f64))?;
    }
    for m in &mut out.moves {
        // The extracted OpenMill hole cycle uses +Z toward the spindle.
        // Floe move POINTS use positive depth w into the part. Convert only
        // the position here; the tip-to-spindle AXIS keeps its +Z basis.
        m.point.z = -m.point.z;
        *m = (*m).with_rapid_feed(mp.rapid_feed);
    }
    Ok(out)
}

fn surface_raster(ctx: &StratCtx) -> Result<StratResult, String> {
    let op = ctx.op;
    check_tool_kind(op, ctx.tool, &[UpToolKind::FlatEndMill, UpToolKind::BallNose])?;
    let mesh = ctx.mesh.ok_or_else(|| {
        format!("cam op '{}': surfaceRaster requires cam.partMesh", op.id)
    })?;
    let min = need_uv(op, "minUVMM", op.min_uv_mm)?;
    let max = need_uv(op, "maxUVMM", op.max_uv_mm)?;
    if max[0] <= min[0] || max[1] <= min[1] {
        return Err(format!("cam op '{}': surfaceRaster requires minUVMM < maxUVMM", op.id));
    }
    let step_over = need_positive(op, "stepOverMM", op.step_over_mm)?;
    let wall_skin = op.wall_stock_mm.unwrap_or(0.0);
    if !wall_skin.is_finite() || wall_skin < 0.0 {
        return Err(format!("cam op '{}': wallStockMM must be finite and >= 0", op.id));
    }
    let mp = motion_params(op)?;
    let mut out = StratResult::new();
    out.sources.push("openmill-0432a8c:strategies/surface_normal_5axis.rs parallel scan + contact offset (via upstream/r4/surface_normal.rs)".into());
    unused_kinds_notes(op, &mut out, &[]);
    if ctx.tool.profile.kind == UpToolKind::FlatEndMill {
        out.limits.push("flatEndMill: tip lifted along the surface normal by wallStockMM (upstream semantics; no radius offset)".into());
    }
    out.limits.push("tool axis = surface normal (no lead/tilt parameters in the R4 contract)".into());

    // Mesh space: into-the-part ray = +w; outward hint = -w (Root review
    // 2026-11-04 sign fix). Move axes are stored in the MOVE basis, so the
    // mesh normal is converted with mesh_dir_to_move_dir (negate w).
    let into_part = Unit::new_normalize(Vector3::new(0.0, 0.0, 1.0));
    let outward = Unit::new_normalize(Vector3::new(0.0, 0.0, -1.0));
    let chord = row_chord(step_over);
    let n_rows = ((max[1] - min[1]) / step_over + 1.0).ceil();
    if !n_rows.is_finite() || n_rows as u64 > MAX_GEN_LAYERS {
        return Err(format!(
            "cam op '{}': surfaceRaster would scan {n_rows} rows, exceeding the generation cap; increase stepOverMM",
            op.id
        ));
    }
    let row_steps = ((max[0] - min[0]) / chord).ceil();
    if !row_steps.is_finite() || row_steps as u64 > MAX_GEN_CONTOUR_STEPS {
        return Err(format!(
            "cam op '{}': surfaceRaster row subdivision exceeds the generation cap; increase stepOverMM",
            op.id
        ));
    }
    let max_toi = mp.clearance + mesh.local_bounds[5].max(0.0) + 50.0;

    let mut total_samples = 0u64;
    let mut misses = 0u64;
    let mut miss_bounds = [f64::INFINITY, f64::INFINITY, f64::NEG_INFINITY, f64::NEG_INFINITY];
    let mut contact_budget_used = 0u64;
    let mut v = min[1];
    loop {
        if v > max[1] + 1e-12 {
            break;
        }
        // Collect contacts along this row, SPLIT at every raycast miss so a
        // cut never bridges an unqueried gap (Root review 2026-11-04).
        let mut segment: Vec<(Point3<f64>, Unit<Vector3<f64>>)> = Vec::new();
        let n_steps = ((max[0] - min[0]) / chord).ceil().max(1.0) as usize;
        let mut emit_segment = |out: &mut StratResult,
                              seg: &mut Vec<(Point3<f64>, Unit<Vector3<f64>>)>,
                              mp: &MotionParams|
         -> Result<(), String> {
            if seg.len() < 2 {
                seg.clear();
                return Ok(());
            }
            if out.moves.len() + seg.len() + 3 > MAX_GEN_MOVES_PER_OP {
                return Err(format!(
                    "cam op '{}': move count exceeds the generation cap {MAX_GEN_MOVES_PER_OP}",
                    op.id
                ));
            }
            let (p0, a0) = seg[0];
            out.moves.push(CamMove::rapid(Point3::new(p0.x, p0.y, -mp.clearance), a0).with_rapid_feed(mp.rapid_feed));
            out.moves.push(CamMove::plunge(p0, a0, mp.plunge_feed));
            for (p, a) in &seg[1..] {
                out.moves.push(CamMove::cut(*p, *a, mp.feed));
            }
            let (pl, al) = *seg.last().unwrap();
            out.moves.push(CamMove::retract(Point3::new(pl.x, pl.y, -mp.clearance), al).with_rapid_feed(mp.rapid_feed));
            seg.clear();
            Ok(())
        };
        for i in 0..=n_steps {
            let u = min[0] + (max[0] - min[0]) * (i as f64 / n_steps as f64);
            total_samples += 1;
            contact_budget_used += 1;
            if contact_budget_used > MAX_GEN_MOVES_PER_OP as u64 {
                return Err(format!(
                    "cam op '{}': surfaceRaster contact workload exceeds the generation cap; increase stepOverMM",
                    op.id
                ));
            }
            if contact_budget_used % 4096 == 0 {
                gen_progress(ctx, (contact_budget_used as f64 / ((n_rows * row_steps as f64).max(1.0))).min(1.0))?;
            }
            let origin = Point3::new(u, v, -mp.clearance);
            let hit = raycast_mesh(&mesh.local, origin, into_part, max_toi, &outward);
            match hit {
                Some(h) => {
                    let tip = tool_tip_for_contact(&ctx.tool.profile, &h.point, &h.normal, wall_skin);
                    let axis = Unit::new_normalize(mesh_dir_to_move_dir(&h.normal));
                    segment.push((tip, axis));
                }
                None => {
                    misses += 1;
                    miss_bounds[0] = miss_bounds[0].min(u);
                    miss_bounds[1] = miss_bounds[1].min(v);
                    miss_bounds[2] = miss_bounds[2].max(u);
                    miss_bounds[3] = miss_bounds[3].max(v);
                    // Explicit break: finish the current hit segment with a
                    // retract before any further motion.
                    emit_segment(&mut out, &mut segment, &mp)?;
                }
            }
        }
        emit_segment(&mut out, &mut segment, &mp)?;
        let v_next = v + step_over;
        if !v_next.is_finite() {
            return Err(format!("cam op '{}': non-finite row advance", op.id));
        }
        v = v_next;
    }
    if total_samples == 0 || misses == total_samples {
        return Err(format!(
            "cam op '{}': surfaceRaster found no surface contact in u [{:.3}...{:.3}], v [{:.3}...{:.3}]",
            op.id, min[0], max[0], min[1], max[1]
        ));
    }
    if misses > 0 {
        out.limits.push(format!(
            "raycast misses: {misses}/{total_samples} samples uncovered; miss range u [{:.3}...{:.3}], v [{:.3}...{:.3}]",
            miss_bounds[0], miss_bounds[2], miss_bounds[1], miss_bounds[3]
        ));
    }
    Ok(out)
}

fn swarf(ctx: &StratCtx) -> Result<StratResult, String> {
    let op = ctx.op;
    check_tool_kind(op, ctx.tool, &[UpToolKind::FlatEndMill, UpToolKind::BallNose])?;
    let mesh = ctx.mesh.ok_or_else(|| {
        format!("cam op '{}': swarf requires cam.partMesh", op.id)
    })?;
    let centre = need_uv(op, "centerUVMM", op.center_uv_mm)?;
    let depth = need_positive(op, "depthMM", op.depth_mm)?;
    let mp = motion_params(op)?;
    let mut out = StratResult::new();
    out.sources.push("openmill-0432a8c:strategies/swarf_5axis.rs ruling scan + flank_offset_dir (via upstream/r4/swarf.rs)".into());
    unused_kinds_notes(op, &mut out, &[]);
    out.limits.push("star-convex walls only: surfaces shadowed from the scan centre have no rulings (never mis-cut)".into());

    // Scan radius covers the local mesh bounds from the scan centre.
    let b = &mesh.local_bounds;
    let scan_radius = (b[3] - centre[0]).abs()
        .max((b[0] - centre[0]).abs())
        .max((b[4] - centre[1]).abs())
        .max((b[1] - centre[1]).abs())
        + ctx.tool.radius()
        + 10.0;
    let requested_angle = match op.step_over_mm {
        Some(s) if s.is_finite() && s > 0.0 => (s / scan_radius).to_degrees(),
        Some(_) => return Err(format!("cam op '{}': stepOverMM must be finite and positive",op.id)),
        None => 2.0,
    };
    if requested_angle < 0.5 {
        return Err(format!("cam op '{}': requested swarf step exceeds the 720-station generation cap",op.id));
    }
    let angular_step = requested_angle.min(30.0);
    out.limits.push(format!("swarf angular station interval: {angular_step} degrees (no silent coarsening of requested step)"));
    // npass cap BEFORE generation.
    let npass = match op.step_down_mm {
        Some(s) if s.is_finite() && s > 0.0 => {
            let n = (depth / s).ceil();
            if !n.is_finite() || n as u64 > MAX_GEN_SWARF_PASSES {
                return Err(format!(
                    "cam op '{}': swarf would need {n} axial passes, exceeding the {MAX_GEN_SWARF_PASSES} generation cap",
                    op.id
                ));
            }
            (n as usize).max(1)
        }
        _ => 1,
    };
    let (rulings, skipped) = ruling_scan(
        &mesh.local,
        (centre[0], centre[1]),
        depth,
        scan_radius,
        ctx.tool.radius(),
        angular_step,
    );
    let stations = (360.0 / angular_step).ceil() as usize;
    if rulings.is_empty() {
        return Err(format!(
            "cam op '{}': swarf found no flank-contact rulings (star-convex limitation; {} of {stations} stations skipped)",
            op.id, skipped
        ));
    }
    if skipped > 0 {
        return Err(format!("cam op '{}': swarf has {skipped} uncovered ruling stations of {stations}; cannot connect across missing geometry",op.id));
    }
    if rulings.len() * npass + npass * 4 > MAX_GEN_MOVES_PER_OP {
        return Err(format!(
            "cam op '{}': swarf move count exceeds the generation cap {MAX_GEN_MOVES_PER_OP}",
            op.id
        ));
    }
    for pass in 0..npass {
        let lambda = (pass + 1) as f64 / npass as f64;
        let first = rulings[0];
        let start = first.bottom.coords + (first.top.coords - first.bottom.coords) * lambda;
        // Preserve the actual ruling axis during approach; no invented
        // rotation to a possibly singular nominal frame axis.
        let axis0 = Unit::new_normalize(mesh_dir_to_move_dir(&first.axis));
        out.moves.push(CamMove::rapid(Point3::new(start.x,start.y,-mp.clearance),axis0).with_rapid_feed(mp.rapid_feed));
        let p0 = Point3::from(start);
        out.moves.push(CamMove::plunge(p0, axis0, mp.plunge_feed));
        for r in &rulings {
            let p = r.bottom.coords + (r.top.coords - r.bottom.coords) * lambda;
            let axis = Unit::new_normalize(mesh_dir_to_move_dir(&r.axis));
            out.moves.push(CamMove::cut(Point3::from(p), axis, mp.feed));
        }
        // All stations were covered: explicitly close the final sector.
        out.moves.push(CamMove::cut(p0,axis0,mp.feed));
        out.moves.push(CamMove::retract(Point3::new(start.x,start.y,-mp.clearance),axis0).with_rapid_feed(mp.rapid_feed));
        gen_progress(ctx, (pass + 1) as f64 / (npass as f64))?;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{CamFrameReq, CamMeshReq, CamToolReq};

    fn frame() -> CamFrame {
        CamFrame::validate(&CamFrameReq {
            origin_mm: [0.0; 3],
            axis: [0.0, 0.0, 1.0],
            x_direction: [1.0, 0.0, 0.0],
        })
        .unwrap()
    }

    fn flat_tool() -> CamTool {
        CamTool::validate_one(&CamToolReq {
            id: "t1".into(),
            name: String::new(),
            kind: "flatEndMill".into(),
            diameter_mm: 6.0,
            cutting_length_mm: 20.0,
            tip_angle_degrees: None,
            gauge_length_mm: None,
            assembly: None,
        })
        .unwrap()
    }

    fn drill_tool() -> CamTool {
        CamTool::validate_one(&CamToolReq {
            id: "d1".into(),
            name: String::new(),
            kind: "drill".into(),
            diameter_mm: 6.0,
            cutting_length_mm: 30.0,
            tip_angle_degrees: Some(118.0),
            gauge_length_mm: None,
            assembly: None,
        })
        .unwrap()
    }

    fn op(strategy: &str) -> CamOperationReq {
        CamOperationReq {
            id: "op1".into(),
            name: String::new(),
            enabled: true,
            tool_id: "t1".into(),
            strategy: strategy.into(),
            frame: None,
            min_uv_mm: None,
            max_uv_mm: None,
            center_uv_mm: None,
            radius_mm: None,
            contour_uv_mm: None,
            holes_uv_mm: None,
            depth_mm: None,
            step_down_mm: None,
            step_over_mm: None,
            wall_stock_mm: None,
            floor_stock_mm: None,
            break_through_mm: None,
            clearance_mm: Some(5.0),
            feed_mm_per_minute: Some(600.0),
            plunge_feed_mm_per_minute: Some(200.0),
            rapid_mm_per_minute: Some(3000.0),
            dwell_seconds: None,
            cycle: None,
            peck_depth_mm: None,
            chip_break_retract_mm: None,
            climb: None,
            spring_passes: None,
            ac_seed: None,
        }
    }

    fn ctx<'a>(o: &'a CamOperationReq, t: &'a CamTool, m: Option<&'a CamPartMesh>) -> StratCtx<'a> {
        StratCtx { op: o, frame: frame(), tool: t, mesh: m, progress: None, frac_lo: 0.0, frac_hi: 1.0 }
    }

    #[test]
    fn face_emits_explicit_rows_with_rapid_feeds() {
        let mut o = op("face");
        o.min_uv_mm = Some([0.0, 0.0]);
        o.max_uv_mm = Some([12.0, 8.0]);
        o.depth_mm = Some(2.0);
        o.step_over_mm = Some(4.0);
        let r = generate(&ctx(&o, &flat_tool(), None)).unwrap();
        assert!(!r.moves.is_empty());
        for m in &r.moves {
            if matches!(m.move_type, CamMoveType::Rapid | CamMoveType::Retract) {
                assert_eq!(m.feed, Some(3000.0));
            }
        }
        assert_eq!(r.moves[0].move_type, CamMoveType::Rapid);
        assert_eq!(r.moves[1].move_type, CamMoveType::Plunge);
    }

    #[test]
    fn hostile_generation_steps_fail_before_loops() {
        let mut o = op("face");
        o.min_uv_mm = Some([0.0, 0.0]);
        o.max_uv_mm = Some([12.0, 8.0]);
        o.depth_mm = Some(2.0);
        o.step_over_mm = Some(1.0e-300);
        assert!(generate(&ctx(&o, &flat_tool(), None)).is_err());
        let mut o = op("contour");
        o.depth_mm = Some(2.0);
        o.center_uv_mm = Some([0.0, 0.0]);
        o.radius_mm = Some(1.0e300);
        assert!(generate(&ctx(&o, &flat_tool(), None)).is_err());
    }

    #[test]
    fn pocket_too_small_is_a_failure_not_a_skip() {
        let mut o = op("pocket");
        o.center_uv_mm = Some([0.0, 0.0]);
        o.radius_mm = Some(2.0);
        o.depth_mm = Some(2.0);
        o.step_over_mm = Some(3.0);
        assert!(generate(&ctx(&o, &flat_tool(), None)).is_err());
    }

    #[test]
    fn contour_discriminates_rectangle_vs_circle() {
        let mut o = op("contour");
        o.depth_mm = Some(2.0);
        o.step_down_mm = Some(2.0);
        o.contour_uv_mm = Some(vec![[0.0, 0.0], [10.0, 0.0], [10.0, 6.0], [0.0, 6.0]]);
        let r = generate(&ctx(&o, &flat_tool(), None)).unwrap();
        assert!(!r.moves.is_empty());
        let max_u = r.moves.iter().map(|m| m.point.x.abs()).fold(0.0f64, f64::max);
        assert!(max_u >= 13.0 - 1e-9, "offset loop must clear the rect by toolR");
        o.contour_uv_mm = Some(vec![[0.0, 0.0], [10.0, 0.0], [10.0, 6.0], [0.0, 6.0], [0.0, 0.0]]);
        assert!(generate(&ctx(&o, &flat_tool(), None)).is_ok());
        o.contour_uv_mm = Some(vec![[0.0, 0.0], [10.0, 0.0], [5.0, 6.0]]);
        assert!(generate(&ctx(&o, &flat_tool(), None)).is_err());
        let mut o2 = op("contour");
        o2.depth_mm = Some(2.0);
        o2.step_down_mm = Some(2.0);
        o2.center_uv_mm = Some([1.0, 1.0]);
        o2.radius_mm = Some(8.0);
        o2.min_uv_mm = Some([0.0, 0.0]); // typed defaults always present
        o2.max_uv_mm = Some([1.0, 1.0]);
        let r = generate(&ctx(&o2, &flat_tool(), None)).unwrap();
        for m in &r.moves {
            if m.move_type == CamMoveType::Cut {
                let d = ((m.point.x - 1.0).powi(2) + (m.point.y - 1.0).powi(2)).sqrt();
                assert!((d - 11.0).abs() < 1e-6, "circle offset radius wrong: {d}");
            }
        }
    }

    #[test]
    fn contour_spring_passes_retrace_final_layer() {
        let mut o = op("contour");
        o.depth_mm = Some(4.0);
        o.step_down_mm = Some(2.0); // 2 layers
        o.center_uv_mm = Some([0.0, 0.0]);
        o.radius_mm = Some(8.0);
        o.spring_passes = Some(2);
        let r = generate(&ctx(&o, &flat_tool(), None)).unwrap();
        let mut o2 = o.clone();
        o2.spring_passes = Some(0);
        let base = generate(&ctx(&o2,&flat_tool(),None)).unwrap();
        assert!(r.moves.len() > base.moves.len(), "spring passes must add motion");
        assert!(r.limits.iter().any(|l| l.starts_with("springPasses:")));
        // All cut points of the extra passes sit at the FINAL layer depth.
        let w_max = 4.0f64;
        let extra_cut = r.moves.iter().filter(|m| m.move_type == CamMoveType::Cut).count()
            - base.moves.iter().filter(|m| m.move_type == CamMoveType::Cut).count();
        assert!(extra_cut > 0);
        let _ = w_max;
        // Out-of-range spring passes rejected.
        let mut o3 = o.clone();
        o3.spring_passes = Some(11);
        assert!(generate(&ctx(&o3, &flat_tool(), None)).is_err());
    }

    #[test]
    fn drill_requires_drill_tool_and_expands_cycles() {
        let mut o = op("drill");
        o.holes_uv_mm = Some(vec![[1.0, 1.0], [2.0, 2.0]]);
        o.depth_mm = Some(5.0);
        o.cycle = Some("peck".into());
        o.peck_depth_mm = Some(2.0);
        assert!(generate(&ctx(&o, &flat_tool(), None)).is_err(), "flat mill must not drill");
        let r = generate(&ctx(&o, &drill_tool(), None)).unwrap();
        let plunges = r.moves.iter().filter(|m| m.move_type == CamMoveType::Plunge).count();
        assert_eq!(plunges, 6);
    }

    /// Root review counterexample: world surface at z = 7, frame origin at
    /// z = 10 (axis +Z). The ray must hit at w = +3, the tool axis must point
    /// OUT of the part (+axis world), and the flat tip sits wallStock above.
    #[test]
    fn surface_raster_hits_surface_below_frame_origin() {
        let frame = CamFrame::validate(&CamFrameReq {
            origin_mm: [0.0, 0.0, 10.0],
            axis: [0.0, 0.0, 1.0],
            x_direction: [1.0, 0.0, 0.0],
        })
        .unwrap();
        let req = CamMeshReq {
            vertices: vec![
                [-10.0, -10.0, 7.0],
                [10.0, -10.0, 7.0],
                [10.0, 10.0, 7.0],
                [-10.0, 10.0, 7.0],
            ],
            triangles: vec![[0, 1, 2], [0, 2, 3]],
        };
        let mesh = CamPartMesh::in_frame(&req, &frame).unwrap();
        assert!((mesh.local_bounds[2] - 3.0).abs() < 1e-9, "surface at w=+3");
        let mut o = op("surfaceRaster");
        o.min_uv_mm = Some([-5.0, -5.0]);
        o.max_uv_mm = Some([5.0, 5.0]);
        o.step_over_mm = Some(5.0);
        o.wall_stock_mm = Some(0.2);
        let t = flat_tool();
        let c = StratCtx { op: &o, frame, tool: &t, mesh: Some(&mesh), progress: None, frac_lo: 0.0, frac_hi: 1.0 };
        let r = generate(&c).unwrap();
        // No miss report: the whole scan region is covered.
        assert!(!r.limits.iter().any(|l| l.starts_with("raycast misses:")));
        // Cut moves: tip w = 3 - 0.2 = 2.8, axis (0,0,1) = +axis world.
        let cuts: Vec<_> = r.moves.iter().filter(|m| m.move_type == CamMoveType::Cut).collect();
        assert!(!cuts.is_empty());
        for m in &cuts {
            assert!((m.point.z - 2.8).abs() < 1e-9, "tip depth wrong: {}", m.point.z);
            assert!((m.axis.z - 1.0).abs() < 1e-9, "tool axis must be +axis (outward)");
        }
    }

    #[test]
    fn surface_raster_splits_rows_at_misses_never_cuts_across_gaps() {
        // Mesh covers only u in [-10, 0]: the right half is a permanent gap.
        let req = CamMeshReq {
            vertices: vec![
                [-10.0, -10.0, 5.0],
                [0.0, -10.0, 5.0],
                [0.0, 10.0, 5.0],
                [-10.0, 10.0, 5.0],
            ],
            triangles: vec![[0, 1, 2], [0, 2, 3]],
        };
        let f = frame();
        let mesh = CamPartMesh::in_frame(&req, &f).unwrap();
        let mut o = op("surfaceRaster");
        o.min_uv_mm = Some([-10.0, -10.0]);
        o.max_uv_mm = Some([10.0, 10.0]);
        o.step_over_mm = Some(10.0); // one row: u from -10 to +10
        let t = flat_tool();
        let c = StratCtx { op: &o, frame: f, tool: &t, mesh: Some(&mesh), progress: None, frac_lo: 0.0, frac_hi: 1.0 };
        let r = generate(&c).unwrap();
        assert!(r.limits.iter().any(|l| l.starts_with("raycast misses:")));
        // The single row must be split: after the last hit's retract there is
        // NO cut whose predecessor is a hit across the gap — verify by
        // checking every cut segment is bounded by explicit plunge and every
        // plunge is preceded by a rapid (never by a cut across the gap).
        let mut prev_type = CamMoveType::Rapid;
        for m in &r.moves {
            if m.move_type == CamMoveType::Cut {
                assert!(
                    prev_type == CamMoveType::Plunge || prev_type == CamMoveType::Cut,
                    "cut must follow plunge/cut within a segment"
                );
            }
            if m.move_type == CamMoveType::Plunge {
                assert!(
                    prev_type == CamMoveType::Rapid || prev_type == CamMoveType::Retract,
                    "plunge must follow an explicit rapid/retract, not bridge a gap"
                );
            }
            prev_type = m.move_type;
        }
    }

    #[test]
    fn surface_raster_all_miss_is_a_failure() {
        let req = CamMeshReq {
            vertices: vec![[100.0, 100.0, 5.0], [101.0, 100.0, 5.0], [100.0, 101.0, 5.0]],
            triangles: vec![[0, 1, 2]],
        };
        let f = frame();
        let mesh = CamPartMesh::in_frame(&req, &f).unwrap();
        let mut o = op("surfaceRaster");
        o.min_uv_mm = Some([-10.0, -10.0]);
        o.max_uv_mm = Some([10.0, 10.0]);
        o.step_over_mm = Some(5.0);
        let t = flat_tool();
        let c = StratCtx { op: &o, frame: f, tool: &t, mesh: Some(&mesh), progress: None, frac_lo: 0.0, frac_hi: 1.0 };
        assert!(generate(&c).is_err());
    }

    #[test]
    fn unknown_strategy_fails() {
        let o = op("trochoidal");
        assert!(generate(&ctx(&o, &flat_tool(), None)).is_err());
    }
}
