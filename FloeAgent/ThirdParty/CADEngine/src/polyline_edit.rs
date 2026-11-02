// SPDX-License-Identifier: MPL-2.0
//! Exact LWPolyline trim/offset in the entity's OCS. No curve tessellation.
//! Work is bounded by MAX_POLYLINE_POINTS and the session's atomic edit clone.
use crate::geometry::{self, intersections, norm_angle, polyline_signed_area, Primitive, P};
use acadrust::entities::LwVertex;
use acadrust::types::{Matrix3, Vector2};
use acadrust::{EntityType, LwPolyline, Vector3};
use std::f64::consts::{PI, TAU};

const EPS: f64 = 1e-9;

#[derive(Clone, Copy)]
pub(crate) struct Plane {
    x: Vector3,
    y: Vector3,
    n: Vector3,
    elevation: f64,
}

impl Plane {
    pub(crate) fn new(normal: Vector3, elevation: f64) -> Result<Self, String> {
        let len = (normal.x * normal.x + normal.y * normal.y + normal.z * normal.z).sqrt();
        if !len.is_finite() || len <= EPS || !elevation.is_finite() || elevation.abs() > 1e12 {
            return Err("Invalid drawing plane".into());
        }
        let n = normal * (1.0 / len);
        let basis = Matrix3::arbitrary_axis(n);
        Ok(Self { x: basis * Vector3::UNIT_X, y: basis * Vector3::UNIT_Y, n, elevation })
    }

    pub(crate) fn of(polyline: &LwPolyline) -> Result<Self, String> {
        Self::new(polyline.normal, polyline.elevation)
    }

    pub(crate) fn world(&self, p: P) -> Vector3 {
        self.x * p.x + self.y * p.y + self.n * self.elevation
    }

    pub(crate) fn local(&self, point: Vector3) -> Result<P, String> {
        let p = crate::vector([point.x, point.y, point.z])?;
        // A world-space pick/boundary must really lie on the target plane.
        // This never drops Z to project unrelated geometry into a drawing.
        let tolerance = EPS.max(32.0 * f64::EPSILON * (1.0 + p.x.abs() + p.y.abs() + p.z.abs()));
        if (p.dot(&self.n) - self.elevation).abs() > tolerance {
            return Err("Point or boundary is outside the selected drawing plane".into());
        }
        Ok(P::new(p.dot(&self.x), p.dot(&self.y)))
    }

    fn orientation(&self, other: &Self) -> Result<f64, String> {
        let dot = self.n.dot(&other.n);
        if (dot.abs() - 1.0).abs() > EPS {
            return Err("Boundary is not coplanar with the selected entity".into());
        }
        self.local(other.world(P::new(0.0, 0.0)))?;
        Ok(if dot >= 0.0 { 1.0 } else { -1.0 })
    }
}

#[derive(Clone, Copy, Debug)]
struct Curve {
    a: P,
    b: P,
    center: P,
    radius: f64,
    sweep: f64, // signed; zero denotes a line, never an approximated arc
}

impl Curve {
    fn new(a: P, b: P, bulge: f64) -> Result<Self, String> {
        if !a.is_finite() || !b.is_finite() || !bulge.is_finite() || a.distance(b) <= EPS {
            return Err("Polyline contains a non-finite or zero-length segment".into());
        }
        if bulge == 0.0 {
            return Ok(Self { a, b, center: P::new(0.0, 0.0), radius: 0.0, sweep: 0.0 });
        }
        let sweep = 4.0 * bulge.atan();
        // Ill-conditioned/full-circle bulges are refused, never made straight.
        if sweep.abs() <= 1e-10 || sweep.abs() >= TAU - 1e-10 {
            return Err("Arc bulge is too close to a line or full circle for a stable edit".into());
        }
        let chord = b.sub(a);
        let center = a.add(b).scale(0.5).add(P::new(-chord.y, chord.x).scale((1.0 - bulge * bulge) / (4.0 * bulge)));
        let radius = a.distance(center);
        if !center.is_finite() || !radius.is_finite() || radius <= EPS {
            return Err("Invalid polyline arc".into());
        }
        Ok(Self { a, b, center, radius, sweep })
    }

    fn primitive(self) -> Primitive {
        if self.sweep == 0.0 {
            Primitive::Segment { a: self.a, b: self.b }
        } else {
            let a = self.a.sub(self.center).angle();
            let b = self.b.sub(self.center).angle();
            let (start, end) = if self.sweep > 0.0 { (a, b) } else { (b, a) };
            Primitive::Arc { c: self.center, r: self.radius, start, end }
        }
    }

    fn point(self, t: f64) -> P {
        if t <= 0.0 { return self.a; }
        if t >= 1.0 { return self.b; }
        if self.sweep == 0.0 {
            self.a.add(self.b.sub(self.a).scale(t))
        } else {
            self.a.rotated(self.center, self.sweep * t)
        }
    }

    fn parameter(self, p: P) -> Option<f64> {
        if p.distance(self.a) <= EPS { return Some(0.0); }
        if p.distance(self.b) <= EPS { return Some(1.0); }
        let t = if self.sweep == 0.0 {
            geometry::projection_t(p, self.a, self.b)?
        } else {
            let start = self.a.sub(self.center).angle();
            let angle = p.sub(self.center).angle();
            if self.sweep > 0.0 { norm_angle(angle - start) / self.sweep }
            else { norm_angle(start - angle) / -self.sweep }
        };
        ((-EPS..=1.0 + EPS).contains(&t)).then_some(t.clamp(0.0, 1.0))
    }

    fn closest(self, p: P) -> (f64, P) {
        if self.sweep == 0.0 {
            let t = geometry::projection_t(p, self.a, self.b).unwrap_or(0.0).clamp(0.0, 1.0);
            return (t, self.point(t));
        }
        if let Some(radial) = p.sub(self.center).normalized() {
            let foot = self.center.add(radial.scale(self.radius));
            if let Some(t) = self.parameter(foot) { return (t, foot); }
        } else {
            return (0.5, self.point(0.5));
        }
        if p.distance(self.a) <= p.distance(self.b) { (0.0, self.a) } else { (1.0, self.b) }
    }

    fn tangent(self, t: f64) -> P {
        if self.sweep == 0.0 { self.b.sub(self.a).normalized().unwrap() }
        else {
            let radial = self.point(t).sub(self.center).scale(self.sweep.signum() / self.radius);
            P::new(-radial.y, radial.x)
        }
    }

    fn shifted(self, left: f64) -> Result<Self, String> {
        if self.sweep == 0.0 {
            let d = self.tangent(0.0);
            let shift = P::new(-d.y, d.x).scale(left);
            Ok(Self { a: self.a.add(shift), b: self.b.add(shift), ..self })
        } else {
            let radius = self.radius - self.sweep.signum() * left;
            if radius <= EPS || !radius.is_finite() { return Err("Offset collapses an arc".into()); }
            Ok(Self {
                a: self.center.add(self.a.sub(self.center).scale(radius / self.radius)),
                b: self.center.add(self.b.sub(self.center).scale(radius / self.radius)),
                radius, ..self
            })
        }
    }

    fn joined(self, a: P, b: P) -> Result<Self, String> {
        if self.sweep == 0.0 {
            if b.sub(a).dot(self.b.sub(self.a)) <= EPS { return Err("Offset reverses a segment".into()); }
            return Ok(Self { a, b, ..self });
        }
        let delta = |from: P, to: P| {
            (to.sub(self.center).angle() - from.sub(self.center).angle() + PI).rem_euclid(TAU) - PI
        };
        let sweep = self.sweep + delta(self.b, b) - delta(self.a, a);
        if sweep * self.sweep <= EPS || sweep.abs() >= TAU - EPS {
            return Err("Offset reverses or closes an arc segment".into());
        }
        Ok(Self { a, b, sweep, ..self })
    }

    fn bulge(self) -> f64 { (self.sweep / 4.0).tan() }
}

fn curves(polyline: &LwPolyline) -> Result<Vec<Curve>, String> {
    if !(2..=crate::MAX_POLYLINE_POINTS).contains(&polyline.vertices.len()) {
        return Err("Polyline is outside the supported edit vertex limit".into());
    }
    if !polyline.thickness.is_finite() || polyline.thickness.abs() > EPS {
        return Err("Extruded polylines are retained but cannot be trimmed or offset".into());
    }
    if !polyline.constant_width.is_finite() || polyline.constant_width < 0.0
        || polyline.vertices.iter().any(|v| !v.start_width.is_finite() || !v.end_width.is_finite() || v.start_width < 0.0 || v.end_width < 0.0) {
        return Err("Invalid polyline widths".into());
    }
    let count = polyline.vertices.len() - usize::from(!polyline.is_closed);
    (0..count).map(|i| {
        let a = polyline.vertices[i];
        let b = polyline.vertices[(i + 1) % polyline.vertices.len()];
        crate::vector2([a.location.x, a.location.y])?;
        crate::vector2([b.location.x, b.location.y])?;
        Curve::new(P::new(a.location.x, a.location.y), P::new(b.location.x, b.location.y), a.bulge)
    }).collect()
}

fn independent(polyline: &LwPolyline) -> Result<(), String> {
    let common = &polyline.common;
    if !common.reactors.is_empty() || common.xdictionary_handle.is_some()
        || !common.extended_data.is_empty() || !common.extended_data.raw_dwg_eed.is_empty()
        || common.graphic_data.as_ref().is_some_and(|v| !v.is_empty()) {
        return Err("This polyline has attached data or dependencies; trim/offset cannot preserve them safely".into());
    }
    Ok(())
}

fn simple(path: &[Curve], closed: bool) -> Result<(), String> {
    for i in 0..path.len() {
        for j in i + 1..path.len() {
            let mut allowed = Vec::with_capacity(2);
            if j == i + 1 { allowed.push(path[i].b); }
            if closed && i == 0 && j + 1 == path.len() { allowed.push(path[i].a); }
            if intersections(&path[i].primitive(), &path[j].primitive()).iter()
                .any(|p| !allowed.iter().any(|a| a.distance(*p) <= 1e-7)) {
                return Err("Intersecting or folded polyline needs a topology-changing offset/trim, which is unsupported".into());
            }
            // Existing intersection helpers intentionally return no hits for
            // coincident supports. Detect overlap analytically as well.
            let same_support = if path[i].sweep == 0.0 && path[j].sweep == 0.0 {
                let d = path[i].b.sub(path[i].a);
                d.cross(path[j].a.sub(path[i].a)).abs() <= EPS
                    && d.cross(path[j].b.sub(path[i].a)).abs() <= EPS
            } else {
                path[i].sweep != 0.0 && path[j].sweep != 0.0
                    && path[i].center.distance(path[j].center) <= EPS
                    && (path[i].radius - path[j].radius).abs() <= EPS
            };
            if same_support {
                for (a, b) in [(path[i], path[j]), (path[j], path[i])] {
                    for p in [a.a, a.point(0.5), a.b] {
                        if b.parameter(p).is_some_and(|t| t > EPS && t < 1.0 - EPS) {
                            return Err("Overlapping polyline segments are unsupported".into());
                        }
                    }
                }
            }
        }
    }
    Ok(())
}

/// Convert an actual coplanar boundary to the target OCS, including signed
/// bulge arcs and opposite normal directions. LINE coordinates are WCS;
/// CIRCLE/ARC centers and LWPOLYLINE vertices are OCS in pinned acadrust.
pub(crate) fn primitives_in_plane(entity: &EntityType, target: Plane) -> Result<Vec<Primitive>, String> {
    match entity {
        EntityType::Line(e) => Ok(vec![Primitive::Segment { a: target.local(e.start)?, b: target.local(e.end)? }]),
        EntityType::LwPolyline(e) => {
            let source = Plane::of(e)?;
            let sign = target.orientation(&source)?;
            curves(e)?.iter().map(|curve| {
                let curve = Curve::new(target.local(source.world(curve.a))?, target.local(source.world(curve.b))?, curve.bulge() * sign)?;
                Ok(curve.primitive())
            }).collect()
        }
        EntityType::Circle(e) => {
            let plane = Plane::new(e.normal, e.center.z)?;
            target.orientation(&plane)?;
            if !e.radius.is_finite() || e.radius <= EPS { return Err("Invalid boundary circle".into()); }
            Ok(vec![Primitive::Circle { c: target.local(plane.world(P::new(e.center.x, e.center.y)))?, r: e.radius }])
        }
        EntityType::Arc(e) => {
            let plane = Plane::new(e.normal, e.center.z)?;
            let sign = target.orientation(&plane)?;
            if !e.radius.is_finite() || e.radius <= EPS || !e.start_angle.is_finite() || !e.end_angle.is_finite() {
                return Err("Invalid boundary arc".into());
            }
            let center = P::new(e.center.x, e.center.y);
            let c = target.local(plane.world(center))?;
            let angle = |a: f64| -> Result<f64, String> {
                Ok(target.local(plane.world(center.add(P::new(a.cos(), a.sin()).scale(e.radius))))?.sub(c).angle())
            };
            let a = angle(e.start_angle)?;
            let b = angle(e.end_angle)?;
            let (start, end) = if sign > 0.0 { (a, b) } else { (b, a) };
            Ok(vec![Primitive::Arc { c, r: e.radius, start, end }])
        }
        _ => Err("This boundary has no supported planar geometry".into()),
    }
}

fn support_join(a: Curve, b: Curve, old_vertex: P) -> Result<P, String> {
    if a.b.distance(b.a) <= 1e-7 { return Ok(a.b.add(b.a).scale(0.5)); }
    let candidates: Vec<P> = match (a.sweep == 0.0, b.sweep == 0.0) {
        (true, true) => geometry::line_line_intersection(a.a, a.b, b.a, b.b).into_iter().collect(),
        (true, false) => geometry::line_circle_intersections_infinite(a.a, a.b, b.center, b.radius).into_iter().map(|(_, p)| p).collect(),
        (false, true) => geometry::line_circle_intersections_infinite(b.a, b.b, a.center, a.radius).into_iter().map(|(_, p)| p).collect(),
        (false, false) => geometry::circle_circle_intersections(a.center, a.radius, b.center, b.radius),
    };
    candidates.into_iter().min_by(|a, b| a.distance(old_vertex).total_cmp(&b.distance(old_vertex)))
        .ok_or_else(|| "Offset supports do not meet without changing topology".into())
}

pub(crate) fn offset(polyline: &LwPolyline, distance: f64, world_side: Vector3) -> Result<LwPolyline, String> {
    independent(polyline)?;
    let side = Plane::of(polyline)?.local(world_side)?;
    let original = curves(polyline)?;
    simple(&original, polyline.is_closed)?;
    let (index, parameter, foot) = original.iter().enumerate().map(|(i, curve)| {
        let (t, p) = curve.closest(side); (i, t, p)
    }).min_by(|a, b| a.2.distance(side).total_cmp(&b.2.distance(side))).unwrap();
    let toward = original[index].tangent(parameter).cross(side.sub(foot));
    if toward.abs() <= EPS { return Err("Pick a side away from the polyline".into()); }
    let shifted = original.iter().map(|curve| curve.shifted(distance * toward.signum())).collect::<Result<Vec<_>, _>>()?;
    let mut joints = Vec::with_capacity(polyline.vertices.len());
    if !polyline.is_closed { joints.push(shifted[0].a); }
    let first = usize::from(!polyline.is_closed);
    for i in first..shifted.len() {
        let previous = (i + shifted.len() - 1) % shifted.len();
        joints.push(support_join(shifted[previous], shifted[i % shifted.len()], P::new(polyline.vertices[i].location.x, polyline.vertices[i].location.y))?);
    }
    if !polyline.is_closed { joints.push(shifted.last().unwrap().b); }
    let joined = shifted.iter().enumerate().map(|(i, curve)| curve.joined(joints[i], joints[(i + 1) % joints.len()])).collect::<Result<Vec<_>, _>>()?;
    simple(&joined, polyline.is_closed)?;
    let mut result = polyline.clone();
    for (i, vertex) in result.vertices.iter_mut().enumerate() {
        crate::vector2([joints[i].x, joints[i].y])?;
        vertex.location = Vector2::new(joints[i].x, joints[i].y);
        if i < joined.len() { vertex.bulge = joined[i].bulge(); }
    }
    if polyline.is_closed {
        let area = |p: &LwPolyline| polyline_signed_area(
            &p.vertices.iter().map(|v| P::new(v.location.x, v.location.y)).collect::<Vec<_>>(),
            &p.vertices.iter().map(|v| v.bulge).collect::<Vec<_>>(), true);
        if !area(&result).is_finite() || area(polyline) * area(&result) <= EPS {
            return Err("Offset collapses or reverses the contour".into());
        }
    }
    Ok(result)
}

/// Remove the picked interval. A closed contour becomes one open chain in
/// its original direction; open contours accept only a trim at an endpoint.
/// Surviving vertex IDs/widths remain, cut endpoints get fresh IDs.
pub(crate) fn trim(polyline: &LwPolyline, boundaries: &[Primitive], world_pick: Vector3) -> Result<LwPolyline, String> {
    independent(polyline)?;
    let pick = Plane::of(polyline)?.local(world_pick)?;
    let path = curves(polyline)?;
    simple(&path, polyline.is_closed)?;
    let count = path.len() as f64;
    let mut cuts = Vec::new();
    for (i, curve) in path.iter().enumerate() {
        for boundary in boundaries {
            for point in intersections(&curve.primitive(), boundary) {
                if let Some(t) = curve.parameter(point) {
                    let mut u = i as f64 + t;
                    if polyline.is_closed && (u - count).abs() <= EPS { u = 0.0; }
                    cuts.push(u);
                }
            }
        }
    }
    cuts.sort_by(f64::total_cmp);
    cuts.dedup_by(|a, b| (*a - *b).abs() <= EPS);
    if cuts.is_empty() || (polyline.is_closed && cuts.len() < 2) {
        return Err("No two usable intersections on the closed contour, or no intersection on the open contour".into());
    }
    let (index, t, _) = path.iter().enumerate().map(|(i, curve)| {
        let (t, p) = curve.closest(pick); (i, t, p)
    }).min_by(|a, b| a.2.distance(pick).total_cmp(&b.2.distance(pick))).unwrap();
    let parameter = if polyline.is_closed { (index as f64 + t) % count } else { index as f64 + t };
    if cuts.iter().any(|cut| (cut - parameter).abs() <= EPS) {
        return Err("Pick is on the boundary intersection; nothing to trim".into());
    }
    let lower = cuts.iter().rev().find(|u| **u < parameter).copied();
    let upper = cuts.iter().find(|u| **u > parameter).copied();
    let (start, end) = if polyline.is_closed {
        (upper.unwrap_or(cuts[0] + count), lower.unwrap_or(cuts[cuts.len() - 1] - count) + count)
    } else {
        match (lower, upper) {
            (None, Some(u)) => (u, count),
            (Some(l), None) => (0.0, l),
            _ => return Err("This trim would split the open polyline into separate entities".into()),
        }
    };
    if end - start <= EPS { return Err("Trim would remove the entire polyline".into()); }
    let mut next_id = polyline.vertices.iter().map(|v| v.vertex_id).max().unwrap_or(0).max(0);
    let mut cut_vertex = |source: LwVertex, curve: Curve, t: f64| -> Result<LwVertex, String> {
        let mut vertex = source;
        if t > EPS && t < 1.0 - EPS {
            next_id = next_id.checked_add(1).ok_or("Polyline vertex ID limit")?;
            vertex.vertex_id = next_id;
        }
        let p = curve.point(t);
        crate::vector2([p.x, p.y])?;
        vertex.location = Vector2::new(p.x, p.y);
        Ok(vertex)
    };
    let mut vertices = Vec::new();
    let mut final_vertex = None;
    for k in start.floor() as usize..end.ceil() as usize {
        let i = k % path.len();
        let lo = (start - k as f64).max(0.0);
        let hi = (end - k as f64).min(1.0);
        if hi - lo <= EPS { continue; }
        let source = polyline.vertices[i];
        let mut vertex = cut_vertex(source, path[i], lo)?;
        vertex.bulge = (path[i].sweep * (hi - lo) / 4.0).tan();
        vertex.start_width = source.start_width + (source.end_width - source.start_width) * lo;
        vertex.end_width = source.start_width + (source.end_width - source.start_width) * hi;
        vertices.push(vertex);
        let endpoint = if hi >= 1.0 - EPS { polyline.vertices[(i + 1) % polyline.vertices.len()] } else { source };
        let mut last = cut_vertex(endpoint, path[i], hi)?;
        last.bulge = 0.0;
        final_vertex = Some(last);
    }
    vertices.push(final_vertex.ok_or("No polyline segment remains")?);
    if vertices.len() > crate::MAX_POLYLINE_POINTS { return Err("Trim exceeds the edit vertex limit".into()); }
    let mut result = polyline.clone();
    result.vertices = vertices;
    result.is_closed = false;
    curves(&result)?;
    Ok(result)
}
