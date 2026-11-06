// SPDX-License-Identifier: MIT OR Apache-2.0
// R4 CAM explicit move model (r4/CONTRACT.md + r4/native/API.md).
//
// Every motion between operations is explicit: consecutive moves never imply
// a connecting cut. Non-cutting moves never remove material (enforced by the
// executor) and dwells are zero-length real pauses.

use nalgebra::{Point3, Unit, Vector3};

/// Contract move classes for PathOut.moveType / kind mapping.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CamMoveType {
    Cut,
    Plunge,
    Rapid,
    Retract,
    Dwell,
}

impl CamMoveType {
    pub fn path_kind(self) -> &'static str {
        match self {
            CamMoveType::Cut => "cam-cut",
            CamMoveType::Plunge => "cam-plunge",
            CamMoveType::Rapid => "cam-rapid",
            CamMoveType::Retract => "cam-retract",
            CamMoveType::Dwell => "cam-dwell",
        }
    }
    pub fn wire_name(self) -> &'static str {
        match self {
            CamMoveType::Cut => "cut",
            CamMoveType::Plunge => "plunge",
            CamMoveType::Rapid => "rapid",
            CamMoveType::Retract => "retract",
            CamMoveType::Dwell => "dwell",
        }
    }
    pub fn removes_material(self) -> bool {
        matches!(self, CamMoveType::Cut | CamMoveType::Plunge)
    }
}

/// One explicit CAM move in the OPERATION's frame-local coordinates:
/// `point` = (u, v, w) with w the depth below the surface along -axis;
/// `axis` = tool axis (tip->shank) expressed in the frame basis
/// {xDirection, y=axis×xDirection, axis}.
#[derive(Clone, Copy, Debug)]
pub struct CamMove {
    pub move_type: CamMoveType,
    pub point: Point3<f64>,
    pub axis: Unit<Vector3<f64>>,
    /// mm/min for Cut/Plunge; mm/min rapid rate for Rapid/Retract
    /// (op.rapidMMPerMinute); None for Dwell.
    pub feed: Option<f64>,
    pub dwell_seconds: Option<f64>,
}

impl CamMove {
    pub fn cut(point: Point3<f64>, axis: Unit<Vector3<f64>>, feed: f64) -> Self {
        CamMove { move_type: CamMoveType::Cut, point, axis, feed: Some(feed), dwell_seconds: None }
    }
    pub fn plunge(point: Point3<f64>, axis: Unit<Vector3<f64>>, feed: f64) -> Self {
        CamMove { move_type: CamMoveType::Plunge, point, axis, feed: Some(feed), dwell_seconds: None }
    }
    pub fn rapid(point: Point3<f64>, axis: Unit<Vector3<f64>>) -> Self {
        CamMove { move_type: CamMoveType::Rapid, point, axis, feed: None, dwell_seconds: None }
    }
    pub fn retract(point: Point3<f64>, axis: Unit<Vector3<f64>>) -> Self {
        CamMove { move_type: CamMoveType::Retract, point, axis, feed: None, dwell_seconds: None }
    }
    pub fn dwell(point: Point3<f64>, axis: Unit<Vector3<f64>>, seconds: f64) -> Self {
        CamMove { move_type: CamMoveType::Dwell, point, axis, feed: None, dwell_seconds: Some(seconds) }
    }

    /// Attach the explicit rapid feed for Rapid/Retract moves (coordinator
    /// correction 2026-11-04: cam-rapid/retract carry feedMMPerMinute =
    /// op.rapidMMPerMinute so Root's per-path timeline needs no guessing).
    pub fn with_rapid_feed(mut self, rapid_feed: f64) -> Self {
        if matches!(self.move_type, CamMoveType::Rapid | CamMoveType::Retract) {
            self.feed = Some(rapid_feed);
        }
        self
    }
}
