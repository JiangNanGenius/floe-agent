//! Table-table A-C trunnion forward and inverse kinematics.
//!
//! # Conventions
//!
//! * Machine frame: +Z up, +X right, +Y away from operator.
//! * The **spindle** / tool always points in **−Z** in the machine frame.
//!   The tool-axis unit vector (tip → shank) is therefore `[0, 0, +1]`
//!   expressed in the machine frame.
//! * The **workpiece frame** is fixed to the C table and rotates with it.
//! * Joint vector order: `[X mm, Y mm, Z mm, A_deg, C_deg]`.
//!
//! # Kinematic chain (workpiece → machine)
//!
//! ```text
//! p_machine = Rx(A) · Rz(C) · (p_workpiece − pivot) + pivot
//! ```
//!
//! So the inverse (machine → workpiece) is:
//!
//! ```text
//! p_workpiece = Rᵀ · (p_machine − pivot) + pivot,   R = Rx(A)·Rz(C)
//! ```
//!
//! # IK derivation
//!
//! The tool axis in workpiece coords must satisfy:
//!
//! ```text
//! Rx(A) · Rz(C) · d_w = [0, 0, 1]      (machine +Z, tip→shank)
//! ```
//!
//! Setting v = Rz(C)·d_w and requiring its x-component to vanish gives:
//!
//! ```text
//! C = atan2(dx, dy)
//! A = acos(dz)          (primary, A ∈ [0, π])
//! ```
//!
//! The second solution uses C₂ = C + π, A₂ = −A.

use std::f64::consts::PI;

use anyhow::Result;
use nalgebra::{Isometry3, Matrix3, Point3, Rotation3, Translation3, Unit, Vector3};

use super::{
    traits::{ForwardKinematics, InverseKinematics},
    types::{
        wrap_to_pi, IkError, KinematicType, MachineConfig, RotaryAxis, SINGULARITY_THRESHOLD,
    },
};

// ── TableTable ────────────────────────────────────────────────────────────────

/// Kinematics engine for a table-table A-C trunnion machine.
pub struct TableTable {
    config: MachineConfig,
}

impl TableTable {
    /// Construct from a [`MachineConfig`] whose `axes` variant is
    /// [`KinematicType::TableTable`].
    pub fn new(config: MachineConfig) -> anyhow::Result<Self> {
        match &config.axes {
            KinematicType::TableTable { .. } => Ok(TableTable { config }),
        }
    }

    /// Borrow the A-axis configuration.
    fn a_axis(&self) -> &RotaryAxis {
        match &self.config.axes {
            KinematicType::TableTable { a_axis, .. } => a_axis,
        }
    }

    /// Borrow the C-axis configuration.
    fn c_axis(&self) -> &RotaryAxis {
        match &self.config.axes {
            KinematicType::TableTable { c_axis, .. } => c_axis,
        }
    }

    /// Borrow the machine configuration.
    pub fn config(&self) -> &MachineConfig {
        &self.config
    }

    /// A-axis travel limits `(min, max)` [radians].
    pub fn a_limits(&self) -> (f64, f64) {
        let a = self.a_axis();
        (a.min_angle, a.max_angle)
    }

    /// C-axis travel limits `(min, max)` [radians].  Either bound may be
    /// non-finite, which marks the axis as continuous (no limit).
    pub fn c_limits(&self) -> (f64, f64) {
        let c = self.c_axis();
        (c.min_angle, c.max_angle)
    }

    /// Home / preferred rotary position `(A, C)` [degrees].
    ///
    /// Used as the reference pose when a joint-space path has no predecessor
    /// to stay continuous with.
    pub fn home_joints_deg(&self) -> (f64, f64) {
        (
            self.a_axis().home_angle.to_degrees(),
            self.c_axis().home_angle.to_degrees(),
        )
    }

    /// Is `a_rad` inside the A-axis travel limits?
    pub fn a_in_limits(&self, a_rad: f64) -> bool {
        let (lo, hi) = self.a_limits();
        a_rad >= lo && a_rad <= hi
    }

    /// Is `c_rad` inside the C-axis travel limits?  Always `true` for a
    /// continuous C axis (non-finite limits).
    pub fn c_in_limits(&self, c_rad: f64) -> bool {
        let (lo, hi) = self.c_limits();
        if !lo.is_finite() || !hi.is_finite() {
            return true;
        }
        c_rad >= lo && c_rad <= hi
    }

    /// Machine-frame linear axis position for a tool tip held at a given
    /// rotary pair.
    ///
    /// ```text
    /// p_machine = Rx(A) · Rz(C) · (p_workpiece − pivot) + pivot
    /// ```
    ///
    /// This is the *only* position that has to fit inside the machine's linear
    /// travel limits — the workpiece-frame coordinate does not, since the
    /// trunnion swings the part away from the program origin as A grows.
    pub fn linear_axes(&self, tool_tip: &Point3<f64>, a_deg: f64, c_deg: f64) -> [f64; 3] {
        let pivot = self.config.pivot_offset;
        let r = Self::rotation(a_deg.to_radians(), c_deg.to_radians());
        let p = r * (tool_tip.coords - pivot) + pivot;
        [p.x, p.y, p.z]
    }

    /// Build the combined rotation matrix R = Rx(a) · Rz(c).
    ///
    /// This rotation transforms vectors from the workpiece frame into the
    /// machine frame.
    fn rotation(a_rad: f64, c_rad: f64) -> Rotation3<f64> {
        let rz = Rotation3::from_axis_angle(&Vector3::z_axis(), c_rad);
        let rx = Rotation3::from_axis_angle(&Vector3::x_axis(), a_rad);
        rx * rz
    }

    /// Build a rotation whose columns are a right-handed frame with +Z = `dir`.
    ///
    /// Used to fill the orientation part of the FK [`Isometry3`].
    fn frame_from_z(dir: &Vector3<f64>) -> Rotation3<f64> {
        // Choose a stable secondary reference axis avoiding collinearity.
        let ref_axis = if dir.x.abs() < 0.9 {
            Vector3::x_axis().into_inner()
        } else {
            Vector3::y_axis().into_inner()
        };

        let y = dir.cross(&ref_axis).normalize();
        let x = y.cross(dir);

        // Columns: x, y, z
        Rotation3::from_matrix_unchecked(Matrix3::from_columns(&[x, y, *dir]))
    }
}

// ── ForwardKinematics ─────────────────────────────────────────────────────────

impl ForwardKinematics for TableTable {
    /// Joints: `[X mm, Y mm, Z mm, A_deg, C_deg]` → tool pose in workpiece frame.
    fn fk(&self, x: f64, y: f64, z: f64, a_deg: f64, c_deg: f64) -> Isometry3<f64> {
        let a = a_deg.to_radians();
        let c = c_deg.to_radians();
        let pivot = self.config.pivot_offset;

        // R = Rx(A)·Rz(C) transforms workpiece → machine.
        let r = Self::rotation(a, c);
        let r_inv = r.inverse(); // = Rᵀ for orthogonal matrix

        // Tool tip in workpiece frame.
        let xyz = Vector3::new(x, y, z);
        let p_w = r_inv * (xyz - pivot) + pivot;

        // Tool axis direction (tip→shank) in workpiece frame.
        // In machine frame it is [0, 0, +1], so we pull it back through R.
        let tool_axis_w = r_inv * Vector3::new(0.0, 0.0, 1.0);

        let rotation = Self::frame_from_z(&tool_axis_w);

        Isometry3::from_parts(Translation3::from(p_w), rotation.into())
    }
}

// ── InverseKinematics ─────────────────────────────────────────────────────────

impl InverseKinematics for TableTable {
    fn ik(
        &self,
        tool_tip: &Point3<f64>,
        tool_axis: &Unit<Vector3<f64>>,
    ) -> Result<Vec<[f64; 5]>> {
        let d = **tool_axis; // Vector3<f64>
        let (dx, dy, dz) = (d.x, d.y, d.z);
        let pivot = self.config.pivot_offset;
        let p_w = tool_tip.coords; // Vector3<f64>

        // ── Singularity check ─────────────────────────────────────────────
        // sin(A) = sqrt(dx² + dy²).  Near zero means tool is near vertical
        // and C becomes indeterminate.
        let sin_a = (dx * dx + dy * dy).sqrt();
        if sin_a < SINGULARITY_THRESHOLD {
            return Err(IkError::Singularity.into());
        }

        // ── Solve for A and C ─────────────────────────────────────────────
        // Primary solution: A ∈ [0, π], C ∈ (−π, π]
        let a1 = f64::acos(dz.clamp(-1.0, 1.0));
        let c1 = dx.atan2(dy); // atan2(dx, dy): angle from +Y toward +X

        // Secondary solution: A₂ = −A₁, C₂ = C₁ + π.
        //
        // C₁ + π can reach ~2π, so it is wrapped back into (−π, π] before the
        // limit test below.  Without the wrap a machine configured for a
        // ±180° C axis rejects perfectly valid secondary solutions purely
        // because of how the angle happens to be written.
        let a2 = -a1;
        let c2 = wrap_to_pi(c1 + PI);

        let a_axis = self.a_axis();
        let c_axis = self.c_axis();

        let mut solutions: Vec<[f64; 5]> = Vec::new();

        for (a_sol, c_sol) in [(a1, c1), (a2, c2)] {
            // Check A-axis limits.
            if a_sol < a_axis.min_angle || a_sol > a_axis.max_angle {
                continue;
            }
            // Check C-axis limits (skip when axis is configured as continuous).
            if c_axis.min_angle.is_finite() && c_axis.max_angle.is_finite() {
                if c_sol < c_axis.min_angle || c_sol > c_axis.max_angle {
                    continue;
                }
            }

            // ── Solve linear axes ─────────────────────────────────────────
            // p_machine = R · (p_w − pivot) + pivot
            let r = Self::rotation(a_sol, c_sol);
            let p_machine = r * (p_w - pivot) + pivot;

            solutions.push([
                p_machine.x,
                p_machine.y,
                p_machine.z,
                a_sol.to_degrees(),
                c_sol.to_degrees(),
            ]);
        }

        if solutions.is_empty() {
            return Err(IkError::OutOfLimits.into());
        }

        Ok(solutions)
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kinematics::{
        default_machines::default_trunnion,
        types::{AxisLimits, KinematicType, MachineConfig, RotaryAxis},
    };
    use approx::assert_abs_diff_eq;

    // ── helpers ───────────────────────────────────────────────────────────────

    /// Extract (tool_tip, tool_axis) from an FK isometry.
    fn iso_to_tip_axis(iso: &Isometry3<f64>) -> (Point3<f64>, Unit<Vector3<f64>>) {
        let tip = Point3::from(iso.translation.vector);
        // FK builds orientation so that R * +Z = tool_axis_in_workpiece.
        let axis_vec = iso.rotation * Vector3::new(0.0, 0.0, 1.0);
        let axis = Unit::new_normalize(axis_vec);
        (tip, axis)
    }

    // ── FK → IK round-trip ────────────────────────────────────────────────────

    /// For 20 deterministic joint configurations with A > 0 (no singularity),
    /// verify that FK then IK recovers the original joints within 1 × 10⁻⁶.
    #[test]
    fn fk_ik_roundtrip_20_poses() {
        let machine = default_trunnion();

        for i in 0..20_usize {
            let a_deg = 5.0 + (i as f64) * 4.0; // 5°…81°, always positive
            let c_deg = -90.0 + (i as f64) * 9.0; // −90°…81°
            let x = (i as f64 - 10.0) * 5.0; // −50…45 mm
            let y = (i as f64 - 10.0) * 3.0; // −30…27 mm
            let z = -(i as f64); // 0…−19 mm

            let iso = machine.fk(x, y, z, a_deg, c_deg);
            let (tip, axis) = iso_to_tip_axis(&iso);

            let solutions = machine
                .ik(&tip, &axis)
                .unwrap_or_else(|e| panic!("IK failed at i={i}: {e}"));

            let matched = solutions.iter().any(|sol| {
                (sol[0] - x).abs() < 1e-6
                    && (sol[1] - y).abs() < 1e-6
                    && (sol[2] - z).abs() < 1e-6
                    && (sol[3] - a_deg).abs() < 1e-6
                    && (sol[4] - c_deg).abs() < 1e-6
            });

            assert!(
                matched,
                "Round-trip failed at i={i}: joints=[{x}, {y}, {z}, {a_deg}°, {c_deg}°]\n\
                 IK returned: {solutions:?}"
            );
        }
    }

    // ── Singularity detection ─────────────────────────────────────────────────

    /// A perfectly vertical tool axis ([0,0,1]) must produce IkError::Singularity.
    #[test]
    fn singularity_vertical_axis_is_err() {
        let machine = default_trunnion();
        let tip = Point3::new(0.0, 0.0, 10.0);
        let axis = Vector3::z_axis(); // exactly [0, 0, 1]

        let result = machine.ik(&tip, &axis);
        assert!(result.is_err(), "Expected Err for vertical tool axis");

        let msg = result.unwrap_err().to_string();
        assert!(
            msg.contains("singularity"),
            "Error message should mention 'singularity', got: {msg}"
        );
    }

    /// A near-vertical axis (just within the singularity threshold) should also
    /// return an error.
    #[test]
    fn singularity_near_vertical_is_err() {
        let machine = default_trunnion();
        let tip = Point3::origin();
        // sin(A) ≈ 1e-10 < SINGULARITY_THRESHOLD
        let tiny = 1e-10_f64;
        let axis = Unit::new_normalize(Vector3::new(tiny, 0.0, (1.0 - tiny * tiny).sqrt()));

        assert!(machine.ik(&tip, &axis).is_err());
    }

    // ── Pivot compensation ────────────────────────────────────────────────────

    /// FK output with a non-zero pivot must differ from FK with a zero pivot
    /// whenever A ≠ 0° (otherwise the pivot cancels algebraically).
    #[test]
    fn pivot_compensation_changes_fk_output() {
        let machine_pivot = default_trunnion(); // pivot = (0, 0, −50)

        // Build an identical machine but with pivot = (0, 0, 0).
        let config_no_pivot = MachineConfig {
            name: "no-pivot".into(),
            axes: KinematicType::TableTable {
                a_axis: RotaryAxis {
                    axis_vector: Vector3::x_axis(),
                    min_angle: (-120_f64).to_radians(),
                    max_angle: (120_f64).to_radians(),
                    home_angle: 0.0,
                },
                c_axis: RotaryAxis {
                    axis_vector: Vector3::z_axis(),
                    min_angle: (-360_f64).to_radians(),
                    max_angle: (360_f64).to_radians(),
                    home_angle: 0.0,
                },
            },
            pivot_offset: Vector3::zeros(),
            travel_limits: AxisLimits {
                x: (-200.0, 200.0),
                y: (-200.0, 200.0),
                z: (-150.0, 0.0),
            },
            post_processor: "LinuxCNC".to_string(),
            post_config: crate::PostConfig::default(),
        };
        let machine_no_pivot = TableTable::new(config_no_pivot).unwrap();

        let iso_with = machine_pivot.fk(0.0, 0.0, 0.0, 30.0, 45.0);
        let iso_without = machine_no_pivot.fk(0.0, 0.0, 0.0, 30.0, 45.0);

        let diff = (iso_with.translation.vector - iso_without.translation.vector).norm();
        assert!(
            diff > 1e-6,
            "FK tool-tip positions should differ with different pivot offsets (diff={diff})"
        );
    }

    // ── Both IK solutions reproduce the same tool tip ─────────────────────────

    /// Both solutions returned by IK must, when fed back into FK, reproduce the
    /// original tool tip position (within 1 × 10⁻⁸ mm).
    #[test]
    fn both_solutions_reproduce_tool_tip() {
        let machine = default_trunnion();

        // Axis tilted ~30° — far from singularity.
        // d = (sin30°·sin45°, sin30°·cos45°, cos30°) = (0.354, 0.354, 0.866)
        let a_rad = 30_f64.to_radians();
        let c_rad = 45_f64.to_radians();
        let axis = Unit::new_normalize(Vector3::new(
            a_rad.sin() * c_rad.sin(),
            a_rad.sin() * c_rad.cos(),
            a_rad.cos(),
        ));
        let tip = Point3::new(15.0, -10.0, -25.0);

        let solutions = machine
            .ik(&tip, &axis)
            .expect("IK should succeed for non-singular tilt");

        assert_eq!(solutions.len(), 2, "Expected exactly 2 solutions");

        for (_i, sol) in solutions.iter().enumerate() {
            let iso = machine.fk(sol[0], sol[1], sol[2], sol[3], sol[4]);
            let p_rt = iso.translation.vector;

            assert_abs_diff_eq!(p_rt.x, tip.x, epsilon = 1e-8);
            assert_abs_diff_eq!(p_rt.y, tip.y, epsilon = 1e-8);
            assert_abs_diff_eq!(p_rt.z, tip.z, epsilon = 1e-8);
        }
    }

    /// Verify that the two solutions have opposite A values and C values 180° apart.
    #[test]
    fn solution_pair_geometry() {
        let machine = default_trunnion();

        let axis = Unit::new_normalize(Vector3::new(0.3, 0.4, 0.866));
        let tip = Point3::origin();

        let solutions = machine.ik(&tip, &axis).unwrap();
        assert_eq!(solutions.len(), 2);

        let a1 = solutions[0][3];
        let c1 = solutions[0][4];
        let a2 = solutions[1][3];
        let c2 = solutions[1][4];

        // A values are negatives of each other.
        assert_abs_diff_eq!(a1, -a2, epsilon = 1e-10);
        // C values differ by 180°.
        assert_abs_diff_eq!((c2 - c1).abs(), 180.0, epsilon = 1e-10);
    }
}
