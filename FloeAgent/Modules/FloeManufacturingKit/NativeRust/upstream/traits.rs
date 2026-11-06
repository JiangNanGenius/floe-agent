use anyhow::Result;
use nalgebra::{Isometry3, Point3, Unit, Vector3};

/// Forward kinematics: machine joint positions → tool pose in workpiece frame.
///
/// Joint order: `(X mm, Y mm, Z mm, A_deg, C_deg)`.
///
/// The returned [`Isometry3`] encodes:
/// * **Translation** — tool tip position in workpiece coordinates.
/// * **Rotation** — orientation that maps `+Z` to the tool axis direction
///   (tip→shank) in workpiece coordinates.
pub trait ForwardKinematics {
    fn fk(&self, x: f64, y: f64, z: f64, a_deg: f64, c_deg: f64) -> Isometry3<f64>;
}

/// Inverse kinematics: desired tool pose in workpiece frame → joint positions.
///
/// * `tool_tip` — desired tool tip in workpiece coordinates [mm].
/// * `tool_axis` — desired tool axis direction (tip→shank, unit vector) in
///   workpiece coordinates.
///
/// Returns up to **two** solutions `[X, Y, Z, A_deg, C_deg]` — one for the
/// primary C angle and one for C ± 180° — ordered so that the solution that
/// satisfies A ≥ 0 is first.  Solutions that exceed axis travel limits are
/// silently dropped.
///
/// # Errors
/// * [`IkError::Singularity`] — tool axis is within `SINGULARITY_THRESHOLD`
///   of vertical `[0,0,1]`; C is indeterminate.
/// * [`IkError::OutOfLimits`] — all candidate solutions exceed travel limits.
///
/// [`IkError::Singularity`]: crate::kinematics::types::IkError::Singularity
/// [`IkError::OutOfLimits`]: crate::kinematics::types::IkError::OutOfLimits
pub trait InverseKinematics {
    fn ik(
        &self,
        tool_tip: &Point3<f64>,
        tool_axis: &Unit<Vector3<f64>>,
    ) -> Result<Vec<[f64; 5]>>;
}
