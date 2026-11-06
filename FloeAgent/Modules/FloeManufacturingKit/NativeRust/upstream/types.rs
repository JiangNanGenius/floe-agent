use nalgebra::{Unit, Vector3};
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Angular threshold below which sin(A) is considered degenerate.
/// At this threshold A ≈ 0.057° — well inside any practical machine's dead band.
pub const SINGULARITY_THRESHOLD: f64 = 1e-9;

/// Wrap an angle [rad] into the canonical range (−π, π].
///
/// Rotary joint angles have to be compared against travel limits that are
/// themselves stated in that range, so any angle built by adding π (the
/// secondary IK branch) must be brought back before the comparison — see
/// [`crate::kinematics::TableTable::ik`].
pub fn wrap_to_pi(angle: f64) -> f64 {
    let two_pi = 2.0 * std::f64::consts::PI;
    let mut r = angle % two_pi;
    if r > std::f64::consts::PI {
        r -= two_pi;
    } else if r <= -std::f64::consts::PI {
        r += two_pi;
    }
    r
}

// ── Axis configuration ────────────────────────────────────────────────────────

/// Configuration of a single rotary axis.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RotaryAxis {
    /// Physical rotation axis direction in machine coordinates.
    #[serde(with = "unit_vector_serde")]
    pub axis_vector: Unit<Vector3<f64>>,
    /// Minimum travel limit [radians].
    pub min_angle: f64,
    /// Maximum travel limit [radians].
    pub max_angle: f64,
    /// Preferred / home angle [radians].
    pub home_angle: f64,
}

// ── Kinematic topology ────────────────────────────────────────────────────────

/// Supported kinematic topologies.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum KinematicType {
    /// A-C table-table trunnion.
    ///
    /// The workpiece sits on the C table; the C table is carried by the A cradle.
    ///
    /// * **A axis** — tilts the cradle around X (typically ±110°–120°).
    /// * **C axis** — rotates the table around Z (often continuous, ±360°).
    TableTable {
        a_axis: RotaryAxis,
        c_axis: RotaryAxis,
    },
}

// ── Linear travel limits ──────────────────────────────────────────────────────

/// Axis-aligned linear travel limits [mm].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AxisLimits {
    pub x: (f64, f64),
    pub y: (f64, f64),
    pub z: (f64, f64),
}

// ── Post-Processor Configuration ──────────────────────────────────────────

/// G-code unit system.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Units {
    Metric,
    Imperial,
}

/// Top-level configuration for G-code output.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PostConfig {
    /// Program number (O-word) for controls that require one.
    pub program_number: u32,
    /// Work coordinate offset code, e.g. `"G54"`, `"G55"`.
    pub work_offset: String,
    /// Unit system — determines whether the post emits G21 or G20.
    pub units: Units,
}

impl Default for PostConfig {
    fn default() -> Self {
        PostConfig {
            program_number: 1000,
            work_offset: "G54".into(),
            units: Units::Metric,
        }
    }
}

// ── Machine configuration ─────────────────────────────────────────────────────

/// Complete machine configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MachineConfig {
    pub name: String,
    /// Kinematic topology and rotary axis parameters.
    pub axes: KinematicType,
    /// Pivot point of the rotary assembly in machine coordinates [mm].
    ///
    /// This is the point that stays fixed as the rotary axes move.  For a
    /// typical hobby trunnion the pivot sits below the table surface.
    pub pivot_offset: Vector3<f64>,
    /// Linear axis travel limits [mm].
    pub travel_limits: AxisLimits,
    /// Default post-processor for this machine (e.g. "LinuxCNC", "GRBL").
    pub post_processor: String,
    /// Post-processor specific configuration.
    pub post_config: PostConfig,
}

// ── Serde helper for Unit<Vector3<f64>> ──────────────────────────────────────

mod unit_vector_serde {
    use nalgebra::{Unit, Vector3};
    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    pub fn serialize<S: Serializer>(v: &Unit<Vector3<f64>>, s: S) -> Result<S::Ok, S::Error> {
        v.as_ref().serialize(s)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Unit<Vector3<f64>>, D::Error> {
        let v = Vector3::<f64>::deserialize(d)?;
        Ok(Unit::new_normalize(v))
    }
}

// ── IK error type ─────────────────────────────────────────────────────────────

/// Errors returned by [`crate::kinematics::traits::InverseKinematics::ik`].
#[derive(Debug, Error)]
pub enum IkError {
    /// The requested tool orientation is at or very near the kinematic
    /// singularity (A ≈ 0°, tool axis vertical).  C becomes degenerate.
    #[error("kinematic singularity: tool axis is near vertical (A ≈ 0°), C is degenerate")]
    Singularity,

    /// All candidate solutions exceed at least one axis travel limit.
    #[error("no IK solution lies within machine travel limits")]
    OutOfLimits,
}
