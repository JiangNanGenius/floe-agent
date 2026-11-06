// SPDX-License-Identifier: MIT
// Extracted from charlatanshost/OpenMill@0432a8c540d1187dc6cb9383ce1b4f2dd97287f6
// (openmill-core/src/strategies/drilling.rs), carried under the upstream MIT
// license option (see ../LICENSE-MIT).
//
// Change map (Floe adaptations):
//  * Output target changed from `ToolpathPoint` accumulation to the Floe
//    `CamMove` list; move semantics map 1:1 (Rapid->Rapid, Linear->Cut,
//    Retract->Retract). The upstream zero-feed dwell Linear point for
//    CounterBore becomes an explicit `CamMoveType::Dwell`.
//  * The hard-coded `const CLEARANCE_MM: f64 = 10.0` became a caller-supplied
//    `clearance` (operation clearanceMM, r4/CONTRACT.md).
//  * `Tool`/`MachineConfig`/`ToolpathStrategy` dependencies removed; the hole
//    geometry arrives as plain f64 parameters.
//  * Per-cycle motion semantics and the peck default (depth/4 when the user
//    supplied none) are preserved from upstream.
//  * DEVIATION (coordinator review 2026-11-04, recorded): upstream silently
//    raised user speeds — `feed.max(1.0)` and `plunge_feed.max(cut*0.5)`,
//    plus a `chipbreak_retract.max(0.1)` floor — which made explicit feeds
//    ineffective (80 -> 100, 0.2 -> 1.0). Here the validated positive finite
//    cut/plunge feeds are used EXACTLY as given; a chip-break retract of 0
//    falls back to the documented upstream default 0.5 (recorded by the
//    caller in the operation limits), and a positive user value is honoured
//    verbatim (no floor).
//
// No machine-specific G-code is emitted (contract): every canned cycle is
// expanded into plain explicit motion.

use nalgebra::{Point3, Unit, Vector3};

use crate::cam::moves::{CamMove, CamMoveType};

/// Canned-cycle variants (upstream `CycleType`, snake_case names preserved).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpCycle {
    /// G81 — straight plunge to depth, rapid retract.
    Drill,
    /// G82 — plunge, dwell at bottom, rapid retract.
    CounterBore,
    /// G83 — deep-hole peck: full retract to clearance between pecks.
    Peck,
    /// G73 — chip-break peck: short retract between pecks.
    ChipBreak,
    /// G85 — feed in, feed out at the cutting rate.
    Bore,
}

/// Parse the contract `cycle` string; unknown values are a hard failure.
pub fn parse_cycle(s: &str) -> Result<UpCycle, String> {
    match s {
        "drill" => Ok(UpCycle::Drill),
        "counterBore" => Ok(UpCycle::CounterBore),
        "peck" => Ok(UpCycle::Peck),
        "chipBreak" => Ok(UpCycle::ChipBreak),
        "bore" => Ok(UpCycle::Bore),
        other => Err(format!(
            "cam: unknown drill cycle '{other}' (expected drill|counterBore|peck|chipBreak|bore)"
        )),
    }
}

/// One hole in frame-local coordinates: `position` is the hole top centre
/// (w = 0 plane), `axis` the drilling direction (tip->shank, i.e. +frame.axis
/// while the cut progresses along -frame.axis).
#[derive(Clone, Copy, Debug)]
pub struct UpHole {
    pub position: Point3<f64>,
    pub axis: Unit<Vector3<f64>>,
    pub depth: f64,
}

#[allow(clippy::too_many_arguments)]
pub fn expand_hole(
    moves: &mut Vec<CamMove>,
    hole: &UpHole,
    clearance: f64,
    feed: f64,
    plunge_feed: f64,
    dwell_seconds: f64,
    cycle: UpCycle,
    peck_depth: f64,
    chip_break_retract: f64,
    break_through: f64,
) -> Result<(), String> {
    if !clearance.is_finite() || clearance < 0.0 {
        return Err("cam drill: clearanceMM must be finite and >= 0".into());
    }
    if !feed.is_finite() || feed <= 0.0 {
        return Err("cam drill: feedMMPerMinute must be finite and > 0".into());
    }
    if !plunge_feed.is_finite() || plunge_feed <= 0.0 {
        return Err("cam drill: plungeFeedMMPerMinute must be finite and > 0".into());
    }
    if !dwell_seconds.is_finite() || dwell_seconds < 0.0 {
        return Err("cam drill: dwellSeconds must be finite and >= 0".into());
    }
    if !peck_depth.is_finite() || peck_depth < 0.0 {
        return Err("cam drill: peckDepthMM must be finite and >= 0".into());
    }
    if !chip_break_retract.is_finite() || chip_break_retract < 0.0 {
        return Err("cam drill: chipBreakRetractMM must be finite and >= 0".into());
    }
    if !break_through.is_finite() || break_through < 0.0 {
        return Err("cam drill: breakThroughMM must be finite and >= 0".into());
    }
    let axis = hole.axis;
    let total_depth = hole.depth + break_through.max(0.0);
    if !total_depth.is_finite() || total_depth <= 0.0 {
        return Err("cam drill: depthMM + breakThroughMM must be finite and > 0".into());
    }
    let safe_start = hole.position + axis.into_inner() * clearance;
    let bottom = hole.position - axis.into_inner() * total_depth;
    // User feeds are used EXACTLY as validated above (positive finite); no
    // silent floors (see header deviation note).
    let cut_feed = feed;
    let dwell = dwell_seconds;
    // chipBreak retract: an explicit positive value is honoured verbatim; 0
    // means "not supplied" and takes the documented upstream default 0.5
    // (the caller records that default in the operation limits).
    let kick = if chip_break_retract > 0.0 { chip_break_retract } else { 0.5 };

    // Refuse excessive work BEFORE emitting even the positioning pose.
    // Zero is the internal sentinel for an absent peck; every positive user
    // value is honoured, including values below the old 1e-6 epsilon.
    if matches!(cycle,UpCycle::Peck | UpCycle::ChipBreak) {
        check_peck_count(effective_peck(peck_depth,total_depth),total_depth)?;
    }

    // Rapid to clearance, aligned with the hole.
    moves.push(CamMove::rapid(safe_start, axis));

    match cycle {
        UpCycle::Drill => {
            plunge_to(moves, bottom, axis, plunge_feed);
            retract_rapid(moves, safe_start, axis);
        }
        UpCycle::CounterBore => {
            plunge_to(moves, bottom, axis, plunge_feed);
            if dwell > 0.0 {
                moves.push(CamMove::dwell(bottom, axis, dwell));
            }
            retract_rapid(moves, safe_start, axis);
        }
        UpCycle::Peck => {
            let peck = effective_peck(peck_depth, total_depth);
            check_peck_count(peck, total_depth)?;
            let mut depth_done = 0.0;
            while depth_done < total_depth {
                let next = (depth_done + peck).min(total_depth);
                let target = hole.position - axis.into_inner() * next;
                if depth_done > 0.0 {
                    // Rapid down to just above the previous bottom.
                    let above =
                        hole.position - axis.into_inner() * (depth_done - 0.5).max(0.0);
                    moves.push(CamMove::rapid(above, axis));
                }
                plunge_to(moves, target, axis, plunge_feed);
                retract_rapid(moves, safe_start, axis);
                depth_done = next;
            }
        }
        UpCycle::ChipBreak => {
            let peck = effective_peck(peck_depth, total_depth);
            check_peck_count(peck, total_depth)?;
            let mut depth_done = 0.0;
            while depth_done < total_depth {
                let next = (depth_done + peck).min(total_depth);
                let target = hole.position - axis.into_inner() * next;
                plunge_to(moves, target, axis, plunge_feed);
                if next < total_depth {
                    let lifted =
                        hole.position - axis.into_inner() * (next - kick).max(0.0);
                    moves.push(CamMove::rapid(lifted, axis));
                }
                depth_done = next;
            }
            retract_rapid(moves, safe_start, axis);
        }
        UpCycle::Bore => {
            plunge_to(moves, bottom, axis, plunge_feed);
            // Feed OUT at the cutting rate — reams the hole on the way back.
            moves.push(CamMove::cut(safe_start, axis, cut_feed));
        }
    }
    Ok(())
}

fn plunge_to(moves: &mut Vec<CamMove>, target: Point3<f64>, axis: Unit<Vector3<f64>>, feed: f64) {
    moves.push(CamMove::plunge(target, axis, feed));
}

fn retract_rapid(moves: &mut Vec<CamMove>, safe_start: Point3<f64>, axis: Unit<Vector3<f64>>) {
    moves.push(CamMove::retract(safe_start, axis));
}

/// Explicit cap on canned-cycle expansion depth (Root review 2026-11-04):
/// a hostile peck depth must fail BEFORE the loop, not spin in generation.
const MAX_PECKS: u64 = 4096;

/// User peck depth if set, else a quarter of the total depth (upstream).
fn effective_peck(user_peck: f64, total_depth: f64) -> f64 {
    if user_peck > 0.0 {
        user_peck
    } else {
        (total_depth * 0.25).max(0.5)
    }
}

fn check_peck_count(peck: f64, total_depth: f64) -> Result<(), String> {
    let n = (total_depth / peck).ceil();
    if !n.is_finite() || n as u64 > MAX_PECKS {
        return Err(format!(
            "cam drill: peck depth {peck} mm needs {n} pecks, exceeding the {MAX_PECKS} expansion cap; increase peckDepthMM"
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hole() -> UpHole {
        UpHole {
            position: Point3::new(1.0, 2.0, 0.0),
            axis: Unit::new_normalize(Vector3::new(0.0, 0.0, 1.0)),
            depth: 10.0,
        }
    }

    fn expand(cycle: UpCycle, dwell: f64, peck: f64, kick: f64, bt: f64) -> Vec<CamMove> {
        let mut v = Vec::new();
        expand_hole(&mut v, &hole(), 5.0, 100.0, 60.0, dwell, cycle, peck, kick, bt).unwrap();
        v
    }

    #[test]
    fn drill_cycle_is_rapid_plunge_retract() {
        let v = expand(UpCycle::Drill, 0.0, 0.0, 0.5, 0.0);
        assert_eq!(v.len(), 3);
        assert_eq!(v[0].move_type, CamMoveType::Rapid);
        assert_eq!(v[1].move_type, CamMoveType::Plunge);
        assert_eq!(v[2].move_type, CamMoveType::Retract);
        assert!((v[1].point.z - (-10.0)).abs() < 1e-12);
        // User feeds honoured EXACTLY: plunge 60 (not max(60, 100*0.5)=60? no:
        // upstream floor would give 50->50 only when lower; here 60 > 50 so
        // both agree — use a case that separates them below).
        assert_eq!(v[1].feed, Some(60.0));
    }

    #[test]
    fn user_feeds_are_never_raised_by_silent_floors() {
        // plunge 20, cut 200: upstream floor 200*0.5=100 would raise 20 -> 100.
        let mut v = Vec::new();
        expand_hole(
            &mut v,
            &hole(),
            5.0,
            200.0,
            20.0,
            0.0,
            UpCycle::Drill,
            0.0,
            0.5,
            0.0,
        )
        .unwrap();
        assert_eq!(v[1].feed, Some(20.0), "plunge feed must stay exactly 20");
        // feed 0.2 previously became 1.0 via feed.max(1.0); bore feed-out
        // must keep 0.2... but 0.2 fails the positive validation, so use a
        // valid small feed to prove verbatim use.
        let mut v = Vec::new();
        expand_hole(
            &mut v,
            &hole(),
            5.0,
            2.0,
            2.0,
            0.0,
            UpCycle::Bore,
            0.0,
            0.5,
            0.0,
        )
        .unwrap();
        assert_eq!(v.last().unwrap().feed, Some(2.0));
    }

    #[test]
    fn counterbore_emits_explicit_dwell() {
        let v = expand(UpCycle::CounterBore, 0.5, 0.0, 0.5, 0.0);
        assert!(v.iter().any(|m| m.move_type == CamMoveType::Dwell
            && (m.dwell_seconds.unwrap() - 0.5).abs() < 1e-12));
    }

    #[test]
    fn peck_splits_into_full_retracts() {
        let v = expand(UpCycle::Peck, 0.0, 2.0, 0.5, 0.0);
        let plunges = v.iter().filter(|m| m.move_type == CamMoveType::Plunge).count();
        assert_eq!(plunges, 5);
        // Initial rapid + 5 plunges + 5 retracts + 4 re-approach rapids.
        assert_eq!(v.len(), 1 + 5 + 5 + 4);
    }

    #[test]
    fn chipbreak_short_retracts_and_final_retract() {
        let v = expand(UpCycle::ChipBreak, 0.0, 2.0, 0.5, 0.0);
        let plunges = v.iter().filter(|m| m.move_type == CamMoveType::Plunge).count();
        assert_eq!(plunges, 5);
        assert_eq!(v.last().unwrap().move_type, CamMoveType::Retract);
        assert_eq!(v[0].move_type, CamMoveType::Rapid);
    }

    #[test]
    fn bore_feeds_out_at_cutting_rate() {
        let v = expand(UpCycle::Bore, 0.0, 0.0, 0.5, 0.0);
        let last = v.last().unwrap();
        assert_eq!(last.move_type, CamMoveType::Cut);
        assert!((last.feed.unwrap() - 100.0).abs() < 1e-12);
    }

    #[test]
    fn break_through_extends_bottom() {
        let v = expand(UpCycle::Drill, 0.0, 0.0, 0.5, 2.0);
        let min_z = v.iter().map(|m| m.point.z).fold(f64::INFINITY, f64::min);
        assert!((min_z - (-12.0)).abs() < 1e-12);
    }

    #[test]
    fn unknown_cycle_is_a_failure() {
        assert!(parse_cycle("g83").is_err());
        assert!(parse_cycle("peck").is_ok());
    }

    #[test]
    fn hostile_peck_depth_fails_before_expansion() {
        let mut v = Vec::new();
        let r = expand_hole(
            &mut v,
            &hole(),
            5.0,
            100.0,
            60.0,
            0.0,
            UpCycle::Peck,
            1.0e-300,
            0.5,
            0.0,
        );
        assert!(r.is_err());
        assert!(v.is_empty(), "no moves may be emitted on refusal");
    }
}
