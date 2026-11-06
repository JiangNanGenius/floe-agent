// SPDX-License-Identifier: MIT OR Apache-2.0
// Fixture collision queries via the actual native Parry3d library (pinned
// 0.17.6; OpenMill upstream declares parry3d 0.17). Unlike OpenMill's
// openmill-sim collision.rs — which does query::intersection_test(...).unwrap_or(false)
// and silently reports errored queries as "no collision", and skips points
// whose IK fails — an errored or unsupported query here is reported as
// `uncertain` and can never become `clear`.
use nalgebra::{Isometry3, Point3, Translation3, Unit, Vector3};
use parry3d::query;
use parry3d::shape::{Ball, Cuboid, Cylinder};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CollisionState {
    Intersecting,
    Clear,
    /// R2: definite positive gap below the required clearance — NOT an
    /// intersection and NOT a clear; must alert in the UI.
    Clearance,
    Uncertain,
}

/// R2: shared budget for ACTUAL Parry query calls within one task. The budget
/// is honoured across milling and acMotion together; exhaustion is a clear
/// failure (never a silent skip of parts, fixtures or remaining stock).
/// Turning-nose fixture checks are outside this budget (R1 scope, frozen).
#[derive(Debug)]
pub struct QueryBudget {
    max: u64,
    remaining: u64,
    /// Total Parry calls made against the budget (milling + ac scopes).
    pub parry_calls: u64,
}

impl QueryBudget {
    pub fn new(max: u64) -> Self {
        QueryBudget {
            max,
            remaining: max,
            parry_calls: 0,
        }
    }

    /// Consume one query slot for one actual Parry call.
    pub fn take_parry(&mut self) -> Result<(), String> {
        if self.remaining == 0 {
            return Err(format!(
                "budget: maxCollisionQueries {} exhausted by actual Parry collision queries",
                self.max
            ));
        }
        self.remaining -= 1;
        self.parry_calls += 1;
        Ok(())
    }
}

#[derive(Clone, Debug)]
pub struct FixtureBox {
    pub id: String,
    pub min: [f64; 3],
    pub max: [f64; 3],
}

impl FixtureBox {
    pub fn cuboid(&self) -> Result<Cuboid, String> {
        let half = Vector3::new(
            (self.max[0] - self.min[0]) * 0.5,
            (self.max[1] - self.min[1]) * 0.5,
            (self.max[2] - self.min[2]) * 0.5,
        );
        if !half.iter().all(|v| v.is_finite()) || half.iter().any(|&v| v <= 0.0) {
            return Err(format!(
                "fixture '{}' must have finite positive extents (minMM < maxMM)",
                self.id
            ));
        }
        let c = Cuboid::new(half.cast());
        Ok(c)
    }

    pub fn center(&self) -> Vector3<f64> {
        Vector3::new(
            (self.min[0] + self.max[0]) * 0.5,
            (self.min[1] + self.max[1]) * 0.5,
            (self.min[2] + self.max[2]) * 0.5,
        )
    }
}

#[derive(Debug)]
struct FixtureQuery {
    id: String,
    state: CollisionState,
    max_depth: f64,
    first_pose: Option<usize>,
    any_error: bool,
}

impl FixtureQuery {
    fn new(id: &str) -> Self {
        FixtureQuery {
            id: id.to_string(),
            state: CollisionState::Clear,
            max_depth: 0.0,
            first_pose: None,
            any_error: false,
        }
    }
}

/// Aggregate collision status of one cutter swept over discrete poses.
#[derive(Clone, Debug)]
pub struct CutterCollisionSummary {
    pub component: String,
    pub state: CollisionState,
    pub message: String,
    /// R2 optional row fields (assembly contract); absent => not emitted.
    pub tool_part: Option<String>,
    pub target_kind: Option<String>,
    pub operation: Option<String>,
    pub first_pose_index: Option<usize>,
    pub minimum_gap_lower_bound_mm: Option<f64>,
    pub geometry_error_mm: Option<f64>,
}

impl CutterCollisionSummary {
    pub(crate) fn bare(component: String, state: CollisionState, message: String) -> Self {
        CutterCollisionSummary {
            component,
            state,
            message,
            tool_part: None,
            target_kind: None,
            operation: None,
            first_pose_index: None,
            minimum_gap_lower_bound_mm: None,
            geometry_error_mm: None,
        }
    }
}

/// Query cutter (finite cylinder) at the given poses against fixture boxes.
/// `poses` are (tip, unit tip→shank axis) pairs. A conservative AABB
/// prefilter declares "clear" without a Parry query only when the cutter
/// AABB cannot overlap the fixture AABB; overlapping cases always go
/// through Parry, and any Parry error is `uncertain`. Bounded cancellation
/// is reported through `progress` (phase "cutter-collision").
#[allow(clippy::too_many_arguments)]
pub fn check_cutter_against_fixtures(
    fixtures: &[FixtureBox],
    tip: &[Point3<f64>],
    axis: &[Unit<Vector3<f64>>],
    radius: f64,
    length: f64,
    operation: &str,
    budget: &mut QueryBudget,
    progress: &crate::Progress,
    frac_lo: f64,
    frac_hi: f64,
) -> Result<Vec<CutterCollisionSummary>, crate::Fail> {
    if tip.len() != axis.len() || tip.is_empty() {
        return Ok(vec![]);
    }
    let radius32 = radius as f32;
    let length32 = length as f32;
    if !radius32.is_finite() || radius32 <= 0.0 || !length32.is_finite() || length32 <= 0.0 {
        return Err("collision: finite positive cutter radius/length required".into());
    }
    let cutter = Cylinder::new(length32 * 0.5, radius32);
    let mut queries: Vec<FixtureQuery> = fixtures.iter().map(|f| FixtureQuery::new(&f.id)).collect();
    let fixtures_shapes: Vec<(Cuboid, Isometry3<f32>)> = fixtures
        .iter()
        .map(|f| {
            let c = f.cuboid().map_err(crate::Fail::Message)?;
            let iso = Isometry3::from_parts(
                Translation3::from(f.center().cast::<f32>()),
                nalgebra::UnitQuaternion::identity(),
            );
            Ok((c, iso))
        })
        .collect::<Result<_, crate::Fail>>()?;

    let n = tip.len().max(1);
    for (pose_i, (tip_p, axis_u)) in tip.iter().zip(axis.iter()).enumerate() {
        if pose_i % 32 == 0 {
            progress.report(
                frac_lo + (frac_hi - frac_lo) * (pose_i as f64) / (n as f64),
                "cutter-collision",
            )?;
        }
        let tip32 = tip_p.cast::<f32>();
        // Parry's Cylinder is aligned along +Y (centred at origin): build an
        // orientation mapping +Y to the tool axis (tip→shank).
        let rot = nalgebra::Rotation3::rotation_between(&Vector3::y(), axis_u.as_ref())
            .unwrap_or_else(|| {
                // 180-degree case: rotate Y to -Y about any orthogonal axis.
                let alt = if axis_u.x.abs() < 0.9 {
                    Vector3::x()
                } else {
                    Vector3::z()
                };
                nalgebra::Rotation3::from_axis_angle(
                    &Unit::new_normalize(Vector3::y().cross(&alt)),
                    std::f64::consts::PI,
                )
            });
        // Parry's cylinder is centred at its origin; the tool tip must sit at
        // the -Y end of the mapped axis, so translate by half the length.
        let half = axis_u.as_ref().cast::<f32>() * (length as f32 * 0.5);
        let pose = Isometry3::from_parts(
            Translation3::from(tip32.coords + half),
            nalgebra::UnitQuaternion::from_rotation_matrix(&rot.cast::<f32>()),
        );

        // Cutter world AABB (segment endpoints expanded by radius).
        let end = tip_p + axis_u.as_ref() * length;
        let c_min = Vector3::new(
            tip_p.x.min(end.x) - radius,
            tip_p.y.min(end.y) - radius,
            tip_p.z.min(end.z) - radius,
        );
        let c_max = Vector3::new(
            tip_p.x.max(end.x) + radius,
            tip_p.y.max(end.y) + radius,
            tip_p.z.max(end.z) + radius,
        );

        for (q, (shape, shape_iso)) in queries.iter_mut().zip(fixtures_shapes.iter()) {
            // AABB overlap test against this fixture.
            let he = shape.half_extents;
            let fcenter = shape_iso.translation.vector;
            let f_min = [
                (fcenter.x - he.x) as f64,
                (fcenter.y - he.y) as f64,
                (fcenter.z - he.z) as f64,
            ];
            let f_max = [
                (fcenter.x + he.x) as f64,
                (fcenter.y + he.y) as f64,
                (fcenter.z + he.z) as f64,
            ];
            let overlap = c_min[0] <= f_max[0]
                && c_max[0] >= f_min[0]
                && c_min[1] <= f_max[1]
                && c_max[1] >= f_min[1]
                && c_min[2] <= f_max[2]
                && c_max[2] >= f_min[2];
            if !overlap {
                continue; // provably clear at this pose (no Parry call, no budget)
            }
            budget.take_parry().map_err(crate::Fail::Message)?;
            match query::intersection_test(&pose, &cutter, shape_iso, shape) {
                Ok(true) => {
                    if q.state != CollisionState::Intersecting {
                        q.state = CollisionState::Intersecting;
                        q.first_pose = Some(pose_i);
                    }
                    // Penetration depth (non-negative contact distance).
                    budget.take_parry().map_err(crate::Fail::Message)?;
                    match query::contact(&pose, &cutter, shape_iso, shape, 0.0) {
                        Ok(Some(contact)) => {
                            let depth = (-contact.dist).max(0.0) as f64;
                            if depth > q.max_depth {
                                q.max_depth = depth;
                            }
                        }
                        Ok(None) => {}
                        Err(_) => {
                            q.any_error = true;
                        }
                    }
                }
                Ok(false) => {}
                Err(_) => {
                    q.any_error = true;
                }
            }
        }
    }

    Ok(queries
        .into_iter()
        .map(|q| {
            let state = if q.any_error && q.state != CollisionState::Intersecting {
                CollisionState::Uncertain
            } else if q.state == CollisionState::Intersecting && q.any_error {
                // Intersecting with an errored depth query stays intersecting,
                // but the message must disclose the uncertainty.
                CollisionState::Intersecting
            } else {
                q.state
            };
            let mut message = match state {
                CollisionState::Clearance => "insufficient fixture clearance".into(),
                CollisionState::Intersecting => format!(
                    "cutter intersects fixture (max penetration {:.4} mm, first at pose {})",
                    q.max_depth,
                    q.first_pose.map(|p| p.to_string()).unwrap_or_else(|| "?".into())
                ),
                CollisionState::Clear => "cutter clear of fixture at all checked poses".to_string(),
                CollisionState::Uncertain => {
                    "collision query unsupported/errored; state is uncertain, never clear".to_string()
                }
            };
            if q.any_error && state == CollisionState::Intersecting {
                message.push_str("; some depth queries errored (depth may be understated)");
            }
            let mut s = CutterCollisionSummary::bare(q.id, state, message);
            s.tool_part = Some("cutter".into());
            s.target_kind = Some("fixture".into());
            s.operation = Some(operation.to_string());
            if state == CollisionState::Intersecting {
                s.first_pose_index = q.first_pose;
            }
            s
        })
        .collect())
}

/// Turning-cutter approximation: a sphere of the tool nose radius centred at
/// the path point (bounded documented approximation; see stock.rs). Bounded
/// cancellation via `progress` (phase "turning-collision").
pub fn check_turning_nose_against_fixtures(
    fixtures: &[FixtureBox],
    points: &[Point3<f64>],
    nose_radius: f64,
    progress: &crate::Progress,
) -> Result<Vec<CutterCollisionSummary>, crate::Fail> {
    if points.is_empty() {
        return Ok(vec![]);
    }
    let r32 = nose_radius as f32;
    if !r32.is_finite() || r32 <= 0.0 {
        return Err("collision: finite positive tool nose radius required".into());
    }
    let ball = Ball::new(r32);
    let mut out = Vec::with_capacity(fixtures.len());
    let n = points.len().max(1);
    for f in fixtures {
        let cuboid = f.cuboid().map_err(crate::Fail::Message)?;
        let f_iso = Isometry3::from_parts(
            Translation3::from(f.center().cast::<f32>()),
            nalgebra::UnitQuaternion::identity(),
        );
        let mut state = CollisionState::Clear;
        let mut max_depth = 0.0f64;
        let mut first = None;
        let mut any_error = false;
        for (i, p) in points.iter().enumerate() {
            if i % 64 == 0 {
                progress.report(i as f64 / n as f64, "turning-collision")?;
            }
            let pose = Isometry3::from_parts(
                Translation3::from(p.cast::<f32>().coords),
                nalgebra::UnitQuaternion::identity(),
            );
            match query::intersection_test(&pose, &ball, &f_iso, &cuboid) {
                Ok(true) => {
                    if state != CollisionState::Intersecting {
                        state = CollisionState::Intersecting;
                        first = Some(i);
                    }
                    if let Ok(Some(c)) = query::contact(&pose, &ball, &f_iso, &cuboid, 0.0) {
                        max_depth = max_depth.max((-c.dist).max(0.0) as f64);
                    }
                }
                Ok(false) => {}
                Err(_) => any_error = true,
            }
        }
        let state = if state == CollisionState::Clear && any_error {
            CollisionState::Uncertain
        } else {
            state
        };
        let message = match state {
            CollisionState::Clearance => "insufficient fixture clearance".into(),
            CollisionState::Intersecting => format!(
                "turning nose sphere intersects fixture (max penetration {:.4} mm, first at point {})",
                max_depth,
                first.map(|p| p.to_string()).unwrap_or_else(|| "?".into())
            ),
            CollisionState::Clear => "turning nose clear of fixture at all path points".into(),
            CollisionState::Uncertain => {
                "collision query unsupported/errored; state is uncertain, never clear".into()
            }
        };
        out.push({
            let mut s = CutterCollisionSummary::bare(f.id.clone(), state, message);
            s.tool_part = Some("turningNose".into());
            s.target_kind = Some("fixture".into());
            s.operation = Some("turning".into());
            if state == CollisionState::Intersecting {
                s.first_pose_index = first;
            }
            s
        });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn far_fixture() -> FixtureBox {
        FixtureBox {
            id: "vice".into(),
            min: [100.0, 100.0, 100.0],
            max: [110.0, 110.0, 110.0],
        }
    }

    #[test]
    fn clear_when_no_overlap() {
        let f = vec![far_fixture()];
        let tips = vec![Point3::origin()];
        let axes = vec![Unit::new_normalize(Vector3::z())];
        let mut budget = QueryBudget::new(100);
        let r = check_cutter_against_fixtures(
            &f, &tips, &axes, 2.0, 10.0, "milling", &mut budget,
            &crate::Progress::quiet(), 0.0, 1.0,
        )
        .unwrap();
        assert_eq!(r[0].state, CollisionState::Clear);
        assert_eq!(r[0].tool_part.as_deref(), Some("cutter"));
        assert_eq!(r[0].target_kind.as_deref(), Some("fixture"));
        assert_eq!(r[0].operation.as_deref(), Some("milling"));
    }

    #[test]
    fn intersecting_when_inside() {
        let f = vec![FixtureBox {
            id: "chuck".into(),
            min: [-5.0, -5.0, -5.0],
            max: [5.0, 5.0, 5.0],
        }];
        let tips = vec![Point3::origin()];
        let axes = vec![Unit::new_normalize(Vector3::z())];
        let mut budget = QueryBudget::new(100);
        let r = check_cutter_against_fixtures(
            &f, &tips, &axes, 2.0, 10.0, "milling", &mut budget,
            &crate::Progress::quiet(), 0.0, 1.0,
        )
        .unwrap();
        assert_eq!(r[0].state, CollisionState::Intersecting);
        assert!(r[0].message.contains("penetration"));
        assert_eq!(r[0].first_pose_index, Some(0));
    }

    #[test]
    fn invalid_fixture_is_an_error_not_clear() {
        let f = vec![FixtureBox {
            id: "bad".into(),
            min: [0.0; 3],
            max: [0.0; 3],
        }];
        let tips = vec![Point3::origin()];
        let axes = vec![Unit::new_normalize(Vector3::z())];
        let mut budget = QueryBudget::new(100);
        assert!(check_cutter_against_fixtures(
            &f, &tips, &axes, 2.0, 10.0, "milling", &mut budget,
            &crate::Progress::quiet(), 0.0, 1.0,
        )
        .is_err());
    }

    #[test]
    fn query_budget_refuses_when_exhausted() {
        let f = vec![FixtureBox {
            id: "chuck".into(),
            min: [-5.0, -5.0, -5.0],
            max: [5.0, 5.0, 5.0],
        }];
        let tips = vec![Point3::origin(), Point3::new(0.1, 0.0, 0.0)];
        let axes = vec![Unit::new_normalize(Vector3::z()); 2];
        // Two overlapping poses each need intersection_test + contact = 4 calls.
        let mut budget = QueryBudget::new(3);
        match check_cutter_against_fixtures(
            &f, &tips, &axes, 2.0, 10.0, "milling", &mut budget,
            &crate::Progress::quiet(), 0.0, 1.0,
        ) {
            Err(crate::Fail::Message(m)) => assert!(m.contains("maxCollisionQueries")),
            _ => panic!("expected a maxCollisionQueries refusal"),
        }
    }
}
