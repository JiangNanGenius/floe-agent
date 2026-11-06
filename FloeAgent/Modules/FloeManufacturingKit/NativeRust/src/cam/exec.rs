// SPDX-License-Identifier: MIT OR Apache-2.0
// R4 CAM executor: simulates the explicit move list of every ordered
// operation against the SHARED voxel stock, with:
//   * real tool-profile removal on cutting moves (mid-segment sampling at
//     <= min(h/2, toolR/2) — no silent coarsening floor; budget exhaustion
//     is a clear failure);
//   * rapid/retract collision-only sampling (never removes material) with
//     rapid-through-stock feedback via the real profile;
//   * fixture cutter queries over the ACTUAL subsampled poses (initial pose
//     included) — never endpoint-only, so a mid-segment collision cannot
//     hide behind clean endpoints (Root review 2026-11-04);
//   * R2 AssemblyChecker reuse per material step (first pose included) when
//     the tool carries an assembly — early contact can never be hidden by
//     later removal;
//   * envelope-cylinder fixture queries with the honest intersecting ->
//     uncertain downgrade for ball-nose/drill profiles; query errors stay
//     uncertain and the collision budget is globally shared;
//   * optional acSeed IK through the qualified A/C chain for EVERY SAMPLED
//     POSE (never endpoint-only) with branch continuity — an unreachable
//     mid-segment pose fails the operation;
//   * global maxPoses / maxCollisionQueries budgets and cancellation.
//
// Output contract (Root review 2026-11-04): every non-dwell path contains
// the actual previous endpoint as its first point plus each move destination
// in the group, so the emitted paths reconstruct the simulated moves exactly.
// Groups break on move type or feed change. The first positioning-only rapid
// is omitted from output (its initial pose is not a counted connection; the
// note lands in the operation limits). Dwells are emitted one path each —
// dwells at different positions are never merged.
use nalgebra::{Point3, Unit, Vector3};

use crate::ac::BoundedAC;
use crate::assembly::AssemblyChecker;
use crate::collision::{check_cutter_against_fixtures, QueryBudget};
use crate::model::{BudgetReq, CamOperationReq, CamReportRow, CamRequest, CollisionOut, PathOut, StageOut};
use crate::stock::Stock;
use crate::upstream_r4::tool_profile::UpToolKind;
use crate::Fail;
use crate::Progress;

use super::frame::CamFrame;
use super::moves::{CamMove, CamMoveType};
use super::partmesh::CamPartMesh;
use super::strategies::{generate, StratCtx};
use super::tools::CamTool;

const AXIS_STEP_DEG: f64 = 15.0;

pub struct CamExec<'a> {
    pub stock: &'a mut Stock,
    pub fixtures: &'a [crate::collision::FixtureBox],
    pub budget: &'a BudgetReq,
    pub collision_budget: &'a mut QueryBudget,
    pub progress: &'a Progress,
    pub poses_used: &'a mut u64,
    pub paths: &'a mut Vec<PathOut>,
    pub collisions: &'a mut Vec<CollisionOut>,
}

pub struct CamSummary {
    pub report: Vec<CamReportRow>,
    pub sampled_poses: u64,
    pub stages: Vec<StageOut>,
    pub warnings: Vec<String>,
}

/// Phase-frame capture hook: called with the stock and the proposed frame
/// name after each operation; returns true when a frame was retained.
pub type FrameHook<'a> = dyn FnMut(&Stock, &str) -> Result<bool, Fail> + 'a;

pub fn run_cam(
    req: &CamRequest,
    tools: &[CamTool],
    exec: &mut CamExec,
    frame_hook: &mut FrameHook,
    frac_lo: f64,
    frac_hi: f64,
) -> Result<CamSummary, Fail> {
    if req.format_version != 1 {
        return Err("cam: formatVersion must be 1".into());
    }
    let enabled_ops: Vec<&CamOperationReq> =
        req.operations.iter().filter(|o| o.enabled).collect();
    if enabled_ops.is_empty() {
        return Err("cam: no enabled operations".into());
    }

    let mut summary = CamSummary {
        report: Vec::new(),
        sampled_poses: 0,
        stages: Vec::new(),
        warnings: Vec::new(),
    };
    let n_ops = enabled_ops.len().max(1);
    let h = exec.stock.h;
    let mut rapid_stock_warned = false;

    for (op_i, op) in enabled_ops.iter().enumerate() {
        let tool = tools
            .iter()
            .find(|t| t.id == op.tool_id)
            .ok_or_else(|| Fail::Message(format!("cam op '{}': tool '{}' not found", op.id, op.tool_id)))?;
        let frame_req = op.frame.as_ref().ok_or_else(|| {
            Fail::Message(format!("cam op '{}': frame is required", op.id))
        })?;
        let frame = CamFrame::validate(frame_req).map_err(Fail::Message)?;
        let mesh = match &req.part_mesh {
            Some(m) => Some(CamPartMesh::in_frame(m, &frame).map_err(Fail::Message)?),
            None => None,
        };

        exec.progress.report(
            frac_lo + (frac_hi - frac_lo) * (op_i as f64) / (n_ops as f64),
            "cam-plan",
        )?;
        let strat = generate(&StratCtx {
            op,
            frame,
            tool,
            mesh: mesh.as_ref(),
            progress: Some(exec.progress),
            frac_lo,
            frac_hi,
        })
        .map_err(Fail::Message)?;
        if strat.moves.is_empty() {
            return Err(Fail::Message(format!("cam op '{}': strategy produced no motion", op.id)));
        }
        if strat.moves[0].move_type != CamMoveType::Rapid {
            return Err(Fail::Message(format!("cam op '{}': initial positioning pose is required",op.id)));
        }

        // acSeed: 5-element [X,Y,Z,A,C] joints seed (coordinator 2026-11-04).
        let mut ik = match &op.ac_seed {
            None => None,
            Some(seed) => Some(IkChain::new(op, tool, seed)?),
        };

        // ---- simulate ------------------------------------------------------
        // Sampling step per contract: min(h/2, toolR/2) with NO floor — a
        // tiny tool samples densely and may legitimately exhaust the pose
        // budget (a clear failure), never a silent coarsening.
        let max_step = (h * 0.5).min(tool.radius() * 0.5);
        let mut asm_checker = match &tool.assembly {
            Some(a) => Some(AssemblyChecker::new(a, exec.fixtures, exec.collision_budget)?),
            None => None,
        };
        let mut prev: Option<(Point3<f64>, Unit<Vector3<f64>>)> = None;
        let mut cut_poses = 0u64;
        let mut op_pose_count = 0usize;
        let mut rapid_stock_hit: Option<usize> = None;
        let before = exec.stock.occupied_count();
        // Per-move endpoint joints (path output), aligned with move indices.
        let mut move_joints: Vec<Option<[f64; 5]>> = vec![None; strat.moves.len()];
        let mut last_joints: Option<[f64; 5]> = None;
        // Actual sampled poses driving the fixture cutter query (initial
        // pose included). Bounded by maxPoses via the walk itself; only
        // retained when fixtures exist (the only consumer).
        let collect_samples = !exec.fixtures.is_empty();
        let mut samples: Vec<(Point3<f64>, Unit<Vector3<f64>>)> = Vec::new();

        for (mi, mv) in strat.moves.iter().enumerate() {
            let tip_w = frame.local_to_world(mv.point.x, mv.point.y, mv.point.z);
            let axis_local = Vector3::new(mv.axis.x, mv.axis.y, mv.axis.z);
            let axis_w = Unit::new_normalize(frame.local_vector_to_world(
                axis_local.x, axis_local.y, axis_local.z,
            ));
            if mv.move_type == CamMoveType::Dwell {
                // Zero-length pause at the current pose.
                move_joints[mi] = last_joints;
                continue;
            }
            let Some((p_tip, p_axis)) = prev else {
                // First move of the operation: the endpoint pose anchors the
                // chain; the assembly checker sees this initial pose too.
                *exec.poses_used += 1;
                summary.sampled_poses += 1;
                if *exec.poses_used > exec.budget.max_poses {
                    return Err(Fail::Message(format!("budget: cam poses exceed maxPoses {}",exec.budget.max_poses)));
                }
                if !mv.move_type.removes_material() && exec.stock.profile_intersects_material(
                    &tip_w,&axis_w,tool.radius(),tool.profile.flute_length,&|hh| tool.radius_at(hh)) {
                    rapid_stock_hit = Some(0);
                }
                if let Some(ch) = ik.as_mut() {
                    let j = ch.solve(&tip_w, &axis_w).map_err(|e| {
                        Fail::Message(format!("cam op '{}': initial pose: {e}", op.id))
                    })?;
                    last_joints = Some(j);
                    move_joints[mi] = Some(j);
                }
                if collect_samples {
                    samples.push((tip_w, axis_w));
                }
                if let Some(chk) = asm_checker.as_mut() {
                    chk.check_step(
                        0,
                        strat.moves.len().max(1),
                        &tip_w,
                        &axis_w,
                        exec.stock,
                        exec.progress,
                        frac_lo,
                        frac_hi,
                    )?;
                }
                op_pose_count += 1;
                prev = Some((tip_w, axis_w));
                continue;
            };
            let dist = (tip_w - p_tip).norm();
            // dot is an inherent Matrix method (no trait import required).
            let angle_deg = p_axis.dot(&axis_w).clamp(-1.0, 1.0).acos().to_degrees();
            let steps = ((dist / max_step).ceil() as usize)
                .max((angle_deg / AXIS_STEP_DEG).ceil() as usize)
                .max(1);
            for k in 1..=steps {
                let t = k as f64 / steps as f64;
                let tip = p_tip + (tip_w - p_tip) * t;
                let axis = interpolate_axis(&p_axis,&axis_w,t).map_err(Fail::Message)?;
                if let Some(ch) = ik.as_mut() {
                    // IK for EVERY sampled pose: an unreachable mid-segment
                    // pose fails the operation here, not silently later.
                    let j = ch.solve(&tip, &axis).map_err(|e| {
                        Fail::Message(format!("cam op '{}': {e}", op.id))
                    })?;
                    last_joints = Some(j);
                    if k == steps {
                        move_joints[mi] = Some(j);
                    }
                }
                if collect_samples {
                    samples.push((tip, axis));
                }
                *exec.poses_used += 1;
                summary.sampled_poses += 1;
                op_pose_count += 1;
                if *exec.poses_used > exec.budget.max_poses {
                    return Err(Fail::Message(format!(
                        "budget: cam poses exceed maxPoses {}",
                        exec.budget.max_poses
                    )));
                }
                if summary.sampled_poses % 32 == 0 {
                    exec.progress.report(
                        frac_lo + (frac_hi - frac_lo)
                            * ((op_i as f64) + (mi as f64 + t) / (strat.moves.len() as f64))
                            / (n_ops as f64),
                        "cam",
                    )?;
                }
                let removes = mv.move_type.removes_material();
                if removes {
                    exec.stock.remove_oriented_profile(
                        &tip,
                        &axis,
                        tool.radius(),
                        tool.profile.flute_length,
                        &|hh| tool.radius_at(hh),
                    );
                    cut_poses += 1;
                } else if rapid_stock_hit.is_none()
                    && exec.stock.profile_intersects_material(
                        &tip,
                        &axis,
                        tool.radius(),
                        tool.profile.flute_length,
                        &|hh| tool.radius_at(hh),
                    )
                {
                    rapid_stock_hit = Some(op_pose_count - 1);
                }
                if let Some(chk) = asm_checker.as_mut() {
                    chk.check_step(
                        op_pose_count - 1,
                        strat.moves.len().max(1),
                        &tip,
                        &axis,
                        exec.stock,
                        exec.progress,
                        frac_lo,
                        frac_hi,
                    )?;
                }
            }
            prev = Some((tip_w, axis_w));
        }
        if let Some(chk) = asm_checker {
            exec.collisions.extend(chk.into_rows(&op.id, exec.stock.h));
        }
        if let Some(first_pose) = rapid_stock_hit {
            exec.collisions.push(CollisionOut {
                component: "remaining-stock".into(),
                state: "intersecting".into(),
                message: "rapid/retract move intersects remaining stock (real tool profile at voxel centres; rapid moves never remove material)".into(),
                tool_part: Some("cutter".into()),
                target_kind: Some("stock".into()),
                operation: Some(op.id.clone()),
                first_pose_index: Some(first_pose),
                minimum_gap_lower_bound_mm: None,
                geometry_error_mm: None,
            });
        }

        // Fixture cutter query over the ACTUAL sampled poses (never
        // endpoint-only); the same shared collision budget and the same
        // ball/drill envelope downgrade apply.
        if !exec.fixtures.is_empty() && !samples.is_empty() {
            let tips: Vec<Point3<f64>> = samples.iter().map(|s| s.0).collect();
            let axes: Vec<Unit<Vector3<f64>>> = samples.iter().map(|s| s.1).collect();
            let rows = check_cutter_against_fixtures(
                exec.fixtures,
                &tips,
                &axes,
                tool.radius(),
                tool.profile.flute_length,
                &op.id,
                exec.collision_budget,
                exec.progress,
                frac_lo,
                frac_hi,
            )?;
            for mut r in rows {
                if r.state == crate::collision::CollisionState::Intersecting
                    && matches!(tool.profile.kind, UpToolKind::BallNose | UpToolKind::Drill)
                {
                    r.state = crate::collision::CollisionState::Uncertain;
                    r.message = format!(
                        "envelope-only intersection (ball-nose/drill profile is inside the envelope cylinder); real-shape fixture contact not certified: {}",
                        r.message
                    );
                }
                exec.collisions.push(crate::core::collision_out(vec![r]).pop().unwrap());
            }
        }

        // ---- emit paths (previous endpoint included; grouped by type+feed) --
        let joints_all: Option<Vec<[f64; 5]>> = if ik.is_some() {
            let mut all = Vec::with_capacity(move_joints.len());
            for (idx, j) in move_joints.iter().enumerate() {
                all.push(j.ok_or_else(|| {
                    Fail::Message(format!(
                        "cam op '{}': internal: move {idx} missing joints after IK walk",
                        op.id
                    ))
                })?);
            }
            Some(all)
        } else {
            None
        };
        let (generated_points, mut emit_limits) =
            emit_paths(&strat.moves, &frame, joints_all.as_deref(), op, tool, exec.paths);

        let removed = before - exec.stock.occupied_count();
        summary.stages.push(StageOut {
            name: format!("cam-{}", op.id),
            remaining_mm3: exec.stock.occupied_count() as f64 * exec.stock.cell_volume(),
            removed_mm3: removed as f64 * exec.stock.cell_volume(),
        });
        frame_hook(exec.stock, &format!("cam-{}", op.id))?;

        let mut limits = strat.limits.clone();
        limits.append(&mut emit_limits);
        limits.extend(tool.notes.iter().cloned());
        if tool.assembly.is_none() {
            limits.push("no tool assembly: shank/holder coverage not claimed (cutter envelope only)".into());
            if !rapid_stock_warned {
                summary.warnings.push(
                    "cam: at least one operation has no tool assembly; shank/holder collision was not checked for it".into(),
                );
                rapid_stock_warned = true;
            }
        }
        summary.report.push(CamReportRow {
            operation_id: op.id.clone(),
            strategy: op.strategy.clone(),
            tool_id: tool.id.clone(),
            generated_points: generated_points as u64,
            cut_poses,
            remaining_mm3: exec.stock.occupied_count() as f64 * exec.stock.cell_volume(),
            removed_mm3: removed as f64 * exec.stock.cell_volume(),
            sources: strat.sources.clone(),
            limits,
        });
    }
    Ok(summary)
}

// Uniform angular sampling; opposite axes need an explicit intermediate pose.
fn interpolate_axis(a:&Unit<Vector3<f64>>,b:&Unit<Vector3<f64>>,t:f64) -> Result<Unit<Vector3<f64>>,String> {
    let dot = a.dot(b).clamp(-1.0,1.0);
    if dot <= -1.0+1e-8 { return Err("opposite tool axes require an explicit intermediate pose".into()); }
    if t <= 0.0 { return Ok(*a); }
    if t >= 1.0 { return Ok(*b); }
    if dot > 1.0-1e-12 { return Ok(*a); }
    let angle = dot.acos();
    let v = **a*((1.0-t)*angle).sin()/angle.sin()+**b*(t*angle).sin()/angle.sin();
    Ok(Unit::new_normalize(v))
}

/// Group contiguous moves by (move type, feed) and emit PathOut rows. Each
/// non-dwell path leads with the group's actual previous endpoint (point,
/// axis and joints) so the path reconstructs the simulated segment; dwells
/// are emitted one path each. The first positioning-only rapid is omitted
/// (recorded in the returned notes). Returns (total points, notes).
fn emit_paths(
    moves: &[CamMove],
    frame: &CamFrame,
    joints: Option<&[[f64; 5]]>,
    op: &CamOperationReq,
    tool: &CamTool,
    paths: &mut Vec<PathOut>,
) -> (usize, Vec<String>) {
    let mut total = 0usize;
    let mut notes = Vec::new();
    // World-space endpoints for every move (also the group-start source).
    let world: Vec<(Point3<f64>, Vector3<f64>)> = moves
        .iter()
        .map(|m| {
            let p = frame.local_to_world(m.point.x, m.point.y, m.point.z);
            let a = Vector3::new(m.axis.x, m.axis.y, m.axis.z);
            (p, frame.local_vector_to_world(a.x, a.y, a.z))
        })
        .collect();

    // Group boundaries: move type or feed change; dwells are always solitary.
    let same_group = |a: &CamMove, b: &CamMove| {
        a.move_type == b.move_type
            && a.feed == b.feed
            && a.move_type != CamMoveType::Dwell
            && b.move_type != CamMoveType::Dwell
    };
    let mut i = 0usize;
    while i < moves.len() {
        let mut j = i + 1;
        while j < moves.len() && same_group(&moves[i], &moves[j]) {
            j += 1;
        }
        let mt = moves[i].move_type;
        // Previous endpoint = the move before the group (the same physical
        // pose chain the simulator walked between moves).
        let has_prev = i > 0;
        if mt == CamMoveType::Dwell {
            // One path per dwell; never merged across positions.
            let (p, a) = world[i];
            let js = joints.map(|all| vec![all[i]]);
            paths.push(PathOut {
                kind: mt.path_kind().to_string(),
                points: vec![[p.x, p.y, p.z]],
                feed_mm_per_minute: None,
                operation_id: Some(op.id.clone()),
                tool_id: Some(tool.id.clone()),
                move_type: Some(mt.wire_name().to_string()),
                tool_axes: Some(vec![[a.x, a.y, a.z]]),
                joints: js,
                dwell_seconds: moves[i].dwell_seconds,
            });
            total += 1;
            i = j;
            continue;
        }
        if !has_prev && mt == CamMoveType::Rapid {
            // First positioning-only rapid: not emitted; the initial pose is
            // not a counted connection (Root review 2026-11-04).
            notes.push("initial positioning rapid not emitted; the approach pose is not counted as a connection".into());
            i = j;
            continue;
        }
        if !has_prev {
            notes.push(format!(
                "first {} move has no previous endpoint; emitted as a single-point path",
                moves[i].move_type.wire_name()
            ));
        }
        let mut points = Vec::with_capacity(j - i + 1);
        let mut axes = Vec::with_capacity(j - i + 1);
        let mut js = Vec::with_capacity(j - i + 1);
        if has_prev {
            let (p, a) = world[i - 1];
            points.push([p.x, p.y, p.z]);
            axes.push([a.x, a.y, a.z]);
            if let Some(all) = joints {
                js.push(all[i - 1]);
            }
        }
        for k in i..j {
            let (p, a) = world[k];
            points.push([p.x, p.y, p.z]);
            axes.push([a.x, a.y, a.z]);
            if let Some(all) = joints {
                js.push(all[k]);
            }
        }
        total += points.len();
        paths.push(PathOut {
            kind: mt.path_kind().to_string(),
            points,
            feed_mm_per_minute: moves[i].feed,
            operation_id: Some(op.id.clone()),
            tool_id: Some(tool.id.clone()),
            move_type: Some(mt.wire_name().to_string()),
            tool_axes: Some(axes),
            joints: if joints.is_some() { Some(js) } else { None },
            dwell_seconds: None,
        });
        i = j;
    }
    (total, notes)
}

/// acSeed IK chain through the qualified A/C machine: the seed's rotary pair
/// [3], [4] selects the initial IK branch; every later solve (endpoints and
/// mid-segment samples alike) keeps A/C continuity with the previous pose.
/// Linear seeds [0..2] are validated finite but the linear axes follow
/// exactly from the kinematic chain (they are not approximated from seeds).
struct IkChain {
    engine: BoundedAC,
    gauge: f64,
    seed_ac: Option<(f64, f64)>,
    prev_ac: Option<(f64, f64)>,
}

impl IkChain {
    fn new(op: &CamOperationReq, tool: &CamTool, seed: &[f64]) -> Result<Self, Fail> {
        if seed.len() != 5 || !seed.iter().all(|v| v.is_finite()) {
            return Err(Fail::Message(format!(
                "cam op '{}': acSeed must hold exactly 5 finite [X,Y,Z,A,C] values",
                op.id
            )));
        }
        let gauge = tool.gauge_length_mm.ok_or_else(|| {
            Fail::Message(format!(
                "cam op '{}': acSeed requires the tool's gaugeLengthMM",
                op.id
            ))
        })?;
        let mut spec = crate::ac::Machine::default();
        spec.tool_length_mm = gauge;
        let engine = BoundedAC::new(spec).map_err(Fail::Message)?;
        let supplied = [seed[0],seed[1],seed[2],seed[3],seed[4]];
        if !engine.joints_in_travel(&supplied) { return Err("acSeed is outside the declared physical travel window".into()); }
        Ok(IkChain {
            engine,
            gauge,
            seed_ac: Some((seed[3], seed[4])),
            prev_ac: None,
        })
    }

    fn solve(
        &mut self,
        tip: &Point3<f64>,
        axis: &Unit<Vector3<f64>>,
    ) -> Result<[f64; 5], String> {
        let solutions = self
            .engine
            .inverse(tip, axis)
            .map_err(|e| format!("pose unreachable: {e}"))?;
        let candidates: Vec<[f64; 5]> = solutions
            .iter()
            .map(|s| [s[0], s[1], s[2] + self.gauge, s[3], s[4]])
            .filter(|g| self.engine.joints_in_travel(g))
            .filter(|g| match self.prev_ac {
                None => true,
                Some((a,c)) => g[3].signum() == a.signum() && (g[4]-c).abs() <= 180.0,
            })
            .collect();
        if candidates.is_empty() {
            return Err(
                "pose unreachable (no IK solution inside the physical A/C travel window)".into(),
            );
        }
        let chosen = match self.prev_ac {
            None => match self.seed_ac {
                None => candidates[0],
                Some((sa, sc)) => *candidates
                    .iter()
                    .min_by(|x, y| {
                        ((x[3] - sa).abs() + (x[4] - sc).abs())
                            .partial_cmp(&((y[3] - sa).abs() + (y[4] - sc).abs()))
                            .unwrap()
                    })
                    .unwrap(),
            },
            Some((pa, pc)) => *candidates
                .iter()
                .min_by(|x, y| {
                    ((x[3] - pa).abs() + (x[4] - pc).abs())
                        .partial_cmp(&((y[3] - pa).abs() + (y[4] - pc).abs()))
                        .unwrap()
                })
                .unwrap(),
        };
        // Self-check: FK of the chosen gauge joints must reproduce the pose.
        let (fk_tip, fk_axis) = self.engine.forward(chosen)?;
        if (Point3::from(fk_tip) - *tip).norm() > 1e-6 || (Vector3::from(fk_axis) - **axis).norm() > 1e-6 {
            return Err("IK/FK mismatch (internal inconsistency)".into());
        }
        self.prev_ac = Some((chosen[3], chosen[4]));
        Ok(chosen)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::CamFrameReq;

    fn frame() -> CamFrame {
        CamFrame::validate(&CamFrameReq {
            origin_mm: [0.0; 3],
            axis: [0.0, 0.0, 1.0],
            x_direction: [1.0, 0.0, 0.0],
        })
        .unwrap()
    }

    fn flat_tool(gauge: Option<f64>) -> CamTool {
        CamTool::validate_one(&crate::model::CamToolReq {
            id: "t1".into(),
            name: String::new(),
            kind: "flatEndMill".into(),
            diameter_mm: 6.0,
            cutting_length_mm: 20.0,
            tip_angle_degrees: None,
            gauge_length_mm: gauge,
            assembly: None,
        })
        .unwrap()
    }

    fn op_with_seed(seed: Option<Vec<f64>>) -> CamOperationReq {
        CamOperationReq {
            id: "op".into(),
            name: String::new(),
            enabled: true,
            tool_id: "t1".into(),
            strategy: "contour".into(),
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
            clearance_mm: None,
            feed_mm_per_minute: None,
            plunge_feed_mm_per_minute: None,
            rapid_mm_per_minute: None,
            dwell_seconds: None,
            cycle: None,
            peck_depth_mm: None,
            chip_break_retract_mm: None,
            climb: None,
            spring_passes: None,
            ac_seed: seed,
        }
    }

    #[test]
    fn ac_seed_outside_physical_rotary_travel_is_refused() {
        let op = op_with_seed(None);
        assert!(IkChain::new(&op, &flat_tool(Some(40.0)), &[0.0,0.0,40.0,20.0,720.0]).is_err());
    }

    #[test]
    fn ac_chain_refuses_cross_wrap_jump_or_branch_flip() {
        let op = op_with_seed(None);
        let mut chain = IkChain::new(&op, &flat_tool(Some(40.0)), &[0.0,0.0,40.0,20.0,170.0]).unwrap();
        let (p,a) = chain.engine.forward([0.0,0.0,40.0,20.0,170.0]).unwrap();
        let first = chain.solve(&Point3::from(p), &Unit::new_normalize(Vector3::from(a))).unwrap();
        assert!((first[3]-20.0).abs()<1e-6 && (first[4]-170.0).abs()<1e-6);
        let (p,a) = chain.engine.forward([0.0,0.0,40.0,20.0,-170.0]).unwrap();
        assert!(chain.solve(&Point3::from(p), &Unit::new_normalize(Vector3::from(a))).is_err(),
            "do not replace physical 340-degree travel by a 20-degree wrap or opposite A branch");
    }

    fn z_moves() -> Vec<CamMove> {
        let z = Unit::new_normalize(Vector3::new(0.0, 0.0, 1.0));
        vec![
            CamMove::rapid(Point3::new(0.0, 0.0, -5.0), z),
            CamMove::plunge(Point3::new(0.0, 0.0, 1.0), z, 100.0),
            CamMove::cut(Point3::new(5.0, 0.0, 1.0), z, 200.0),
        ]
    }

    #[test]
    fn ik_chain_rejects_bad_seed_and_requires_gauge() {
        let f = frame();
        let tool = flat_tool(Some(40.0));
        let op = op_with_seed(Some(vec![0.0, 0.0, 50.0]));
        assert!(IkChain::new(&op, &tool, &op.ac_seed.clone().unwrap()).is_err());
        let op = op_with_seed(Some(vec![0.0, 0.0, 50.0, 10.0, f64::NAN]));
        assert!(IkChain::new(&op, &tool, &op.ac_seed.clone().unwrap()).is_err());
        let op = op_with_seed(Some(vec![0.0, 0.0, 50.0, 10.0, 0.0]));
        let no_gauge = flat_tool(None);
        assert!(IkChain::new(&op, &no_gauge, &op.ac_seed.clone().unwrap()).is_err());
        let _ = f;
    }

    #[test]
    fn ik_chain_rejects_vertical_axis_at_singularity() {
        let tool = flat_tool(Some(40.0));
        let op = op_with_seed(Some(vec![0.0, 0.0, 50.0, 10.0, 0.0]));
        let mut ch = IkChain::new(&op, &tool, &[0.0, 0.0, 50.0, 10.0, 0.0]).unwrap();
        let z = Unit::new_normalize(Vector3::new(0.0, 0.0, 1.0));
        assert!(ch.solve(&Point3::new(0.0, 0.0, -5.0), &z).is_err());
    }

    #[test]
    fn ik_chain_keeps_branch_continuity_on_tilted_frame() {
        let f = CamFrame::validate(&CamFrameReq {
            origin_mm: [0.0; 3],
            axis: [0.0, 0.342_020_143_325_668_7, 0.939_692_620_785_908_4],
            x_direction: [1.0, 0.0, 0.0],
        })
        .unwrap();
        let tool = flat_tool(Some(40.0));
        let op = op_with_seed(Some(vec![0.0, 0.0, 50.0, 20.0, 0.0]));
        let mut ch = IkChain::new(&op, &tool, &[0.0, 0.0, 50.0, 20.0, 0.0]).unwrap();
        // Convert move-space axes through the frame (as the walk does).
        let joints: Vec<_> = z_moves()
            .iter()
            .map(|m| {
                let tip = f.local_to_world(m.point.x, m.point.y, m.point.z);
                let a = Vector3::new(m.axis.x, m.axis.y, m.axis.z);
                let aw = Unit::new_normalize(f.local_vector_to_world(a.x, a.y, a.z));
                ch.solve(&tip, &aw).unwrap()
            })
            .collect();
        for w in joints.windows(2) {
            assert!((w[0][3] - w[1][3]).abs() < 1e-9, "A continuity");
            assert!((w[0][4] - w[1][4]).abs() < 1e-9, "C continuity");
        }
        // FK self-check passed inside solve; A near the 20-degree seed.
        assert!((joints[0][3] - 20.0).abs() < 1.0, "branch follows seed A");
    }

    #[test]
    fn axis_interpolation_is_angular_and_rejects_opposites() {
        let a = Unit::new_normalize(Vector3::new(1.0,0.0,0.0));
        let b = Unit::new_normalize(Vector3::new(0.0,0.0,1.0));
        let q = interpolate_axis(&a,&b,0.25).unwrap();
        assert!((q.x-std::f64::consts::FRAC_PI_8.cos()).abs()<1e-12);
        assert!((q.z-std::f64::consts::FRAC_PI_8.sin()).abs()<1e-12);
        assert!(interpolate_axis(&a,&Unit::new_normalize(-*a),0.5).is_err());
    }

    #[test]
    fn emit_paths_includes_previous_endpoint_and_omits_first_rapid() {
        let f = frame();
        let z = Unit::new_normalize(Vector3::new(0.0, 0.0, 1.0));
        let moves = vec![
            CamMove::rapid(Point3::new(0.0, 0.0, -5.0), z).with_rapid_feed(3000.0),
            CamMove::plunge(Point3::new(0.0, 0.0, 1.0), z, 100.0),
            CamMove::cut(Point3::new(5.0, 0.0, 1.0), z, 200.0),
            CamMove::cut(Point3::new(5.0, 5.0, 1.0), z, 200.0),
            CamMove::retract(Point3::new(5.0, 5.0, -5.0), z).with_rapid_feed(3000.0),
        ];
        let op = op_with_seed(None);
        let tool = flat_tool(None);
        let mut paths = Vec::new();
        let (total, notes) = emit_paths(&moves, &f, None, &op, &tool, &mut paths);
        // First rapid omitted -> note present.
        assert!(notes.iter().any(|n| n.contains("initial positioning rapid")));
        // No single-point non-dwell path; first path is the plunge group
        // [rapid endpoint, plunge destination].
        for p in &paths {
            assert!(p.points.len() >= 2, "non-dwell path must reconstruct its segment");
        }
        assert_eq!(paths[0].kind, "cam-plunge");
        assert_eq!(paths[0].points.len(), 2);
        assert_eq!(paths[1].kind, "cam-cut");
        assert_eq!(paths[1].points.len(), 3);
        assert_eq!(paths[2].kind, "cam-retract");
        assert_eq!(paths[2].points.len(), 2);
        assert!(total >= 7);
    }

    #[test]
    fn emit_paths_splits_on_feed_change_and_keeps_dwells_solitary() {
        let f = frame();
        let z = Unit::new_normalize(Vector3::new(0.0, 0.0, 1.0));
        let moves = vec![
            CamMove::rapid(Point3::new(0.0, 0.0, -5.0), z).with_rapid_feed(3000.0),
            CamMove::cut(Point3::new(1.0, 0.0, 0.0), z, 200.0),
            CamMove::cut(Point3::new(2.0, 0.0, 0.0), z, 250.0), // feed change -> new group
            CamMove::dwell(Point3::new(2.0, 0.0, 0.0), z, 0.5),
            CamMove::dwell(Point3::new(3.0, 0.0, 0.0), z, 0.5), // different position
        ];
        let op = op_with_seed(None);
        let tool = flat_tool(None);
        let mut paths = Vec::new();
        emit_paths(&moves, &f, None, &op, &tool, &mut paths);
        let kinds: Vec<_> = paths.iter().map(|p| p.kind.as_str()).collect();
        assert_eq!(
            kinds,
            vec!["cam-cut", "cam-cut", "cam-dwell", "cam-dwell"],
            "feed change splits the cut group; dwells stay one path each"
        );
        // The second cut group leads with the previous endpoint (1,0,0)-world.
        assert_eq!(paths[1].points[0], paths[0].points[1]);
        // Dwells at different positions are NOT merged.
        assert_ne!(paths[2].points, paths[3].points);
    }
}
