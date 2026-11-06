//! Pre-built machine configurations for common hobbyist setups.

use nalgebra::Vector3;

use super::{
    table_table::TableTable,
    types::{AxisLimits, KinematicType, MachineConfig, RotaryAxis},
};

/// Configuration for a typical hobby A-C trunnion machine.
///
/// | Parameter | Value |
/// |---|---|
/// | A axis | ±120°, rotates around X |
/// | C axis | ±360° (continuous), rotates around Z |
/// | Pivot offset | (0, 0, −50 mm) — table surface below spindle nose |
/// | X travel | ±200 mm |
/// | Y travel | ±200 mm |
/// | Z travel | −150 mm … 0 mm |
pub fn default_trunnion_config() -> MachineConfig {
    MachineConfig {
        name: "Hobby A-C Trunnion".into(),
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
        pivot_offset: Vector3::new(0.0, 0.0, -50.0),
        travel_limits: AxisLimits {
            x: (-200.0, 200.0),
            y: (-200.0, 200.0),
            z: (-150.0, 0.0),
        },
        post_processor: "LinuxCNC".into(),
        post_config: crate::kinematics::types::PostConfig::default(),
    }
}

/// Ready-to-use [`TableTable`] kinematics for the default hobby trunnion.
///
/// # Panics
/// Never panics — the config is always valid.
pub fn default_trunnion() -> TableTable {
    TableTable::new(default_trunnion_config())
        .expect("default_trunnion_config is always a valid TableTable config")
}
