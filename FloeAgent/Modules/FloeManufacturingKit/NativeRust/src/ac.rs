// SPDX-License-Identifier: MIT OR Apache-2.0
// Floe bounded physical A/C adapter around the unchanged, pinned OpenMill
// TableTable FK/IK (see kinematics/mod.rs for provenance). Adapted from the
// component-qualified adapter in
// Local/Private/cad106-native-closure-20261031/e38-ac-trunnion-kinematics-20261103/src/bounded.rs
// (same Floe project, MIT/Apache licensed deliverable directory).
//
// This adapter adds explicit gauge-point travel, principal C travel, tool
// length and an orientation-conditioning policy on top of the upstream math;
// those additions are Floe's and are not claimed as upstream capabilities.
// It is NOT a motion planner, collision checker or safety certificate.
use nalgebra::{Point3, Unit, Vector3};

use crate::kinematics::types::{
    AxisLimits, KinematicType, MachineConfig, PostConfig, RotaryAxis,
    SINGULARITY_THRESHOLD,
};
use crate::kinematics::{ForwardKinematics, InverseKinematics, TableTable};

/// Explicit maximum for fm_core_ac `steps` (documented maxSteps policy).
pub const MAX_STEPS: u32 = 4096;
/// Default orientation-conditioning policy: reject/report inverse when
/// 1/|sin(A)| exceeds this (inverse orientation sensitivity).
pub const DEFAULT_MAX_CONDITION: f64 = 1000.0;

#[derive(Clone, Debug)]
pub struct Machine {
    pub pivot_mm: [f64; 3],
    pub a_limits_deg: [f64; 2],
    pub c_limits_deg: [f64; 2],
    pub linear_limits_mm: [[f64; 2]; 3],
    pub tool_length_mm: f64,
    pub max_condition: f64,
}

impl Default for Machine {
    fn default() -> Self {
        Machine {
            pivot_mm: [0.0; 3],
            a_limits_deg: [-120.0, 120.0],
            c_limits_deg: [-180.0, 180.0],
            linear_limits_mm: [[-10000.0, 10000.0]; 3],
            tool_length_mm: 0.0,
            max_condition: DEFAULT_MAX_CONDITION,
        }
    }
}

#[derive(Clone, Debug)]
pub struct AcPose {
    pub tip_mm: [f64; 3],
    pub axis: [f64; 3],
    pub joints: [f64; 5],
}

#[derive(Debug)]
pub struct AcSampleSet {
    pub poses: Vec<AcPose>,
    pub warning_detail: Option<String>,
}

fn finite(v: &[f64]) -> bool {
    v.iter().all(|x| x.is_finite())
}

fn range_ok(r: [f64; 2], lo: f64, hi: f64) -> bool {
    finite(&r) && r[0] <= r[1] && r[0] >= lo && r[1] <= hi
}

pub struct BoundedAC {
    pub spec: Machine,
    kernel: TableTable,
}

impl BoundedAC {
    pub fn new(spec: Machine) -> Result<Self, String> {
        if !finite(&spec.pivot_mm)
            || spec.pivot_mm.iter().any(|x| x.abs() > 1000.0)
            || !range_ok(spec.a_limits_deg, -120.0, 120.0)
            || !range_ok(spec.c_limits_deg, -180.0, 180.0)
            || spec
                .linear_limits_mm
                .iter()
                .any(|r| !range_ok(*r, -10000.0, 10000.0))
            || !spec.tool_length_mm.is_finite()
            || !(0.0..=1000.0).contains(&spec.tool_length_mm)
            || !spec.max_condition.is_finite()
            || !(1.0..=1e6).contains(&spec.max_condition)
        {
            return Err(
                "invalid finite pivot, physical gauge-axis travel, principal C window, tool length or conditioning policy"
                    .into(),
            );
        }
        let cfg = MachineConfig {
            name: "floe bounded physical A-C (OpenMill pinned chain)".into(),
            axes: KinematicType::TableTable {
                a_axis: RotaryAxis {
                    axis_vector: Vector3::x_axis(),
                    min_angle: spec.a_limits_deg[0].to_radians(),
                    max_angle: spec.a_limits_deg[1].to_radians(),
                    home_angle: 0.0,
                },
                // Enumerate both original geometric branches first; the
                // physical principal C window is enforced by this adapter.
                c_axis: RotaryAxis {
                    axis_vector: Vector3::z_axis(),
                    min_angle: -std::f64::consts::PI,
                    max_angle: std::f64::consts::PI,
                    home_angle: 0.0,
                },
            },
            pivot_offset: Vector3::from(spec.pivot_mm),
            travel_limits: AxisLimits {
                x: (spec.linear_limits_mm[0][0], spec.linear_limits_mm[0][1]),
                y: (spec.linear_limits_mm[1][0], spec.linear_limits_mm[1][1]),
                z: (spec.linear_limits_mm[2][0], spec.linear_limits_mm[2][1]),
            },
            post_processor: "unused-no-gcode".into(),
            post_config: PostConfig::default(),
        };
        TableTable::new(cfg)
            .map(|kernel| BoundedAC { spec, kernel })
            .map_err(|e| format!("upstream TableTable rejected config: {e}"))
    }

    fn linear_ok(&self, j: &[f64; 5]) -> bool {
        (0..3).all(|i| {
            j[i] >= self.spec.linear_limits_mm[i][0] && j[i] <= self.spec.linear_limits_mm[i][1]
        })
    }

    pub fn joints_in_travel(&self, j: &[f64; 5]) -> bool {
        self.linear_ok(j)
            && j[3] >= self.spec.a_limits_deg[0]
            && j[3] <= self.spec.a_limits_deg[1]
            && j[4] >= self.spec.c_limits_deg[0]
            && j[4] <= self.spec.c_limits_deg[1]
    }

    /// FK of physical gauge joints [X,Y,Z,A,C] (degrees). The physical tool
    /// tip is exactly toolLengthMM below the gauge point along machine Z.
    pub fn forward(&self, gauge: [f64; 5]) -> Result<([f64; 3], [f64; 3]), String> {
        if !finite(&gauge) {
            return Err("finite physical gauge XYZ mm and A/C degrees required".into());
        }
        if !self.joints_in_travel(&gauge) {
            return Err(
                "physical gauge/rotary joint exceeds its closed travel interval; no angle wrap or clipping applied"
                    .into(),
            );
        }
        let iso = self
            .kernel
            .fk(gauge[0], gauge[1], gauge[2] - self.spec.tool_length_mm, gauge[3], gauge[4]);
        let p = iso.translation.vector;
        let a = iso.rotation * Vector3::z();
        if !finite(p.as_slice()) || !finite(a.as_slice()) || (a.norm() - 1.0).abs() > 1e-12 {
            return Err("nonfinite or nonunit upstream FK".into());
        }
        Ok(([p.x, p.y, p.z], [a.x, a.y, a.z]))
    }

    /// R4 CAM (acSeed): qualified-chain IK of a workpiece-frame tool pose.
    /// Returns up to two `[X, Y, Z, A, C]` solutions whose LINEAR components
    /// are the kernel tip machine position (the physical gauge point sits
    /// `tool_length_mm` above along machine Z — callers add it). Branch and
    /// travel-window selection are the caller's job; this only runs the
    /// pinned upstream inverse on the unchanged chain.
    pub fn inverse(
        &self,
        tool_tip: &Point3<f64>,
        tool_axis: &Unit<Vector3<f64>>,
    ) -> Result<Vec<[f64; 5]>, String> {
        self.kernel
            .ik(tool_tip, tool_axis)
            .map_err(|e| format!("{e}"))
    }

    /// 1/|sin(A)| for a workpiece-frame tool axis (inverse orientation
    /// sensitivity for this trunnion topology).
    pub fn orientation_condition(&self, axis: &[f64; 3]) -> f64 {
        let s = axis[0].hypot(axis[1]);
        if s > f64::MIN_POSITIVE {
            1.0 / s
        } else {
            f64::INFINITY
        }
    }

    /// Uniform physical joint interpolation from gauge `start` to `end`
    /// with `steps` segments (steps+1 samples). Physical C travel is kept
    /// exactly as given — never wrapped to a shortest arc.
    pub fn sample_uniform(
        &self,
        start: [f64; 5],
        end: [f64; 5],
        steps: u32,
    ) -> Result<AcSampleSet, String> {
        if !(1..=MAX_STEPS).contains(&steps) {
            return Err(format!(
                "explicit maxSteps policy: steps must be 1...{MAX_STEPS}"
            ));
        }
        if !finite(&start) || !finite(&end) {
            return Err("finite start/end [x,y,z,a,c] required".into());
        }
        if !self.joints_in_travel(&start) || !self.joints_in_travel(&end) {
            return Err(
                "start or end gauge joints exceed declared physical travel; path rejected as inaccessible"
                    .into(),
            );
        }
        let n = steps as usize;
        let mut poses = Vec::with_capacity(n + 1);
        let mut worst_condition = 0f64;
        for i in 0..=n {
            let t = i as f64 / n as f64;
            let mut j = [0f64; 5];
            for k in 0..5 {
                j[k] = start[k] + t * (end[k] - start[k]);
            }
            // Joint travel intervals are convex: interpolated samples stay
            // inside travel when both endpoints do. FK stays defined at
            // A = 0 (forward-singular); report the inverse-orientation
            // singularity/conditioning as a warning, never silently.
            let (tip, axis) = self.forward(j)?;
            let cond = self.orientation_condition(&axis);
            worst_condition = worst_condition.max(cond);
            poses.push(AcPose {
                tip_mm: tip,
                axis,
                joints: j,
            });
        }
        let warning_detail = if worst_condition > self.spec.max_condition || poses.iter().any(|p| p.axis[0].hypot(p.axis[1]) < SINGULARITY_THRESHOLD) {
            Some(format!(
                "inverse orientation singularity/conditioning: at least one sample has sin(A) < {SINGULARITY_THRESHOLD} or 1/|sin(A)| > {} (worst {worst_condition:.6}); FK poses remain defined, inverse C underdetermined there",
                self.spec.max_condition
            ))
        } else {
            None
        };
        Ok(AcSampleSet {
            poses,
            warning_detail,
        })
    }
}

// ---- fm_core_ac C-ABI entry -------------------------------------------------

use serde::Serialize;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AcResult {
    pub ok: bool,
    pub poses: Vec<crate::model::AcPoseOut>,
    pub warnings: Vec<String>,
    pub backend: String,
}

#[derive(Clone, Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AcRequest {
    pub format_version: u32,
    pub start: [f64; 5],
    pub end: [f64; 5],
    #[serde(rename = "toolLengthMM")]
    pub tool_length_mm: f64,
    pub steps: u32,
}

/// fm_core_ac: uniform physical joint sampling through the pinned OpenMill
/// A/C chain with explicit tool length, preserving exact C travel.
pub fn run_ac(request_json: &str, progress: &crate::Progress) -> Result<AcResult, crate::Fail> {
    let req: AcRequest = serde_json::from_str(request_json)
        .map_err(|e| crate::Fail::Message(format!("invalid ac request JSON: {e}")))?;
    if req.format_version != 1 {
        return Err(crate::Fail::Message("formatVersion must be 1".into()));
    }
    let mut spec = Machine::default();
    spec.tool_length_mm = req.tool_length_mm;
    let engine = BoundedAC::new(spec).map_err(crate::Fail::Message)?;
    let sample = engine
        .sample_uniform(req.start, req.end, req.steps)
        .map_err(crate::Fail::Message)?;
    let mut warnings = Vec::new();
    if let Some(w) = &sample.warning_detail {
        warnings.push(w.clone());
    }
    let n = sample.poses.len().max(1);
    for (i, _) in sample.poses.iter().enumerate() {
        if i % 16 == 0 {
            progress.report(i as f64 / n as f64, "ac")?;
        }
    }
    Ok(AcResult {
        ok: true,
        poses: sample
            .poses
            .iter()
            .map(|p| crate::model::AcPoseOut {
                tip_mm: p.tip_mm,
                axis: p.axis,
                joints: p.joints,
            })
            .collect(),
        warnings,
        backend: crate::model::backend_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fk_matches_adapter_quarter_frame() {
        let mut spec = Machine::default();
        spec.tool_length_mm = 0.0;
        let e = BoundedAC::new(spec).unwrap();
        let (tip, axis) = e.forward([1.0, 2.0, 3.0, 90.0, 0.0]).unwrap();
        for (v, w) in tip.iter().zip([1.0, 3.0, -2.0]) {
            assert!((v - w).abs() < 1e-12);
        }
        for (v, w) in axis.iter().zip([0.0, 1.0, 0.0]) {
            assert!((v - w).abs() < 1e-12);
        }
    }

    #[test]
    fn physical_c_travel_is_never_wrapped() {
        let e = BoundedAC::new(Machine::default()).unwrap();
        let s = e
            .sample_uniform([0.0, 0.0, 60.0, 30.0, 179.0], [0.0, 0.0, 60.0, 30.0, -179.0], 8)
            .unwrap();
        assert_eq!(s.poses.first().unwrap().joints[4], 179.0);
        assert_eq!(s.poses.last().unwrap().joints[4], -179.0);
        let total: f64 = s.poses.windows(2).map(|w| w[1].joints[4] - w[0].joints[4]).sum();
        assert!((total - (-358.0)).abs() < 1e-9);
    }

    #[test]
    fn out_of_travel_is_rejected() {
        let e = BoundedAC::new(Machine::default()).unwrap();
        assert!(e
            .sample_uniform([0.0; 5], [0.0, 0.0, 0.0, 30.0, 181.0], 4)
            .is_err());
        assert!(e.sample_uniform([0.0; 5], [0.0; 5], 0).is_err());
        assert!(e.sample_uniform([0.0; 5], [0.0; 5], MAX_STEPS + 1).is_err());
    }

    #[test]
    fn singularity_is_a_warning_not_a_failure() {
        let e = BoundedAC::new(Machine::default()).unwrap();
        let s = e
            .sample_uniform([0.0; 5], [0.0, 0.0, 0.0, 0.0, 45.0], 4)
            .unwrap();
        assert!(s.warning_detail.unwrap().contains("singularity"));
    }
}
