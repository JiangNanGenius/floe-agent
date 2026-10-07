// SPDX-License-Identifier: MPL-2.0
//! Deterministic 2D geometry for drawing-unit edit operations.
//!
//! acadrust 0.5.5 has no general 2D geometry toolkit (only XLine/XLine
//! intersection), so trim/extend/offset/snap/measure are implemented here
//! against plain drawing-unit coordinates. Every routine works in the XY
//! plane; callers must reject entities whose extrusion normal is not +Z for
//! these operations, so a non-default OCS is never silently flattened.
//!
//! All tolerances are caller-supplied drawing units. Functions are pure and
//! allocation-bounded; no floating point result is trusted without a finite
//! check.

use std::f64::consts::PI;

pub const TAU: f64 = 2.0 * PI;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct P {
    pub x: f64,
    pub y: f64,
}

impl P {
    pub fn new(x: f64, y: f64) -> Self {
        P { x, y }
    }
    pub fn add(self, o: P) -> P {
        P::new(self.x + o.x, self.y + o.y)
    }
    pub fn sub(self, o: P) -> P {
        P::new(self.x - o.x, self.y - o.y)
    }
    pub fn scale(self, s: f64) -> P {
        P::new(self.x * s, self.y * s)
    }
    pub fn dot(self, o: P) -> f64 {
        self.x * o.x + self.y * o.y
    }
    pub fn cross(self, o: P) -> f64 {
        self.x * o.y - self.y * o.x
    }
    pub fn length(self) -> f64 {
        self.x.hypot(self.y)
    }
    pub fn distance(self, o: P) -> f64 {
        (self.x - o.x).hypot(self.y - o.y)
    }
    pub fn is_finite(self) -> bool {
        self.x.is_finite() && self.y.is_finite()
    }
    pub fn normalized(self) -> Option<P> {
        let len = self.length();
        if len <= f64::EPSILON || !len.is_finite() {
            return None;
        }
        Some(self.scale(1.0 / len))
    }
    /// Rotate by `angle` radians around `origin`.
    pub fn rotated(self, origin: P, angle: f64) -> P {
        let (s, c) = angle.sin_cos();
        let d = self.sub(origin);
        P::new(origin.x + d.x * c - d.y * s, origin.y + d.x * s + d.y * c)
    }
    /// Mirror across the line through `a` and `b`.
    pub fn mirrored(self, a: P, b: P) -> Option<P> {
        let axis = b.sub(a);
        let len2 = axis.dot(axis);
        if len2 <= f64::EPSILON {
            return None;
        }
        let d = self.sub(a);
        let t = d.dot(axis) / len2;
        let foot = a.add(axis.scale(t));
        Some(foot.scale(2.0).sub(self))
    }
    pub fn angle(self) -> f64 {
        self.y.atan2(self.x)
    }
}

/// Normalize to [0, TAU).
pub fn norm_angle(a: f64) -> f64 {
    let mut v = a % TAU;
    if v < 0.0 {
        v += TAU;
    }
    v
}

/// Whether `angle` lies in the CCW sweep from `start` to `end`.
pub fn angle_in_arc(angle: f64, start: f64, end: f64) -> bool {
    let sweep = norm_angle(end - start);
    if sweep <= 1e-12 {
        // Degenerate arc: treat as a full turn to remain permissive.
        return true;
    }
    norm_angle(angle - start) <= sweep + 1e-12
}

/// Intersection of two segments (endpoints included). Parallel/colinear
/// segments return `None`; colinear overlap is resolved by the caller if ever
/// needed.
pub fn segment_intersection(a1: P, a2: P, b1: P, b2: P) -> Option<P> {
    let r = a2.sub(a1);
    let s = b2.sub(b1);
    let denom = r.cross(s);
    if denom.abs() <= 1e-12 {
        return None;
    }
    let q = b1.sub(a1);
    let t = q.cross(s) / denom;
    let u = q.cross(r) / denom;
    if (-1e-9..=1.0 + 1e-9).contains(&t) && (-1e-9..=1.0 + 1e-9).contains(&u) {
        let point = a1.add(r.scale(t));
        if point.is_finite() {
            return Some(point);
        }
    }
    None
}

/// Intersections of a segment with a circle. Returns 0..=2 points.
pub fn segment_circle_intersections(a1: P, a2: P, center: P, radius: f64) -> Vec<P> {
    let d = a2.sub(a1);
    let len2 = d.dot(d);
    if len2 <= 1e-24 || !radius.is_finite() || radius <= 0.0 {
        return vec![];
    }
    let f = a1.sub(center);
    let b = f.dot(d);
    let c = f.dot(f) - radius * radius;
    let disc = b * b - len2 * c;
    if disc < 0.0 {
        return vec![];
    }
    let sqrt = disc.sqrt();
    let mut out = Vec::with_capacity(2);
    for t in [(-b - sqrt) / len2, (-b + sqrt) / len2] {
        if (-1e-9..=1.0 + 1e-9).contains(&t) {
            let point = a1.add(d.scale(t));
            if point.is_finite() && !out.iter().any(|p: &P| p.distance(point) <= 1e-9) {
                out.push(point);
            }
        }
    }
    out
}

/// Intersections of an infinite line through `a1`/`a2` with a circle.
/// Returns `(t, point)` with `t` measured along `a2 - a1` (any real value).
pub fn line_circle_intersections_infinite(a1: P, a2: P, center: P, radius: f64) -> Vec<(f64, P)> {
    let d = a2.sub(a1);
    let len2 = d.dot(d);
    if len2 <= 1e-24 || !radius.is_finite() || radius <= 0.0 {
        return vec![];
    }
    let f = a1.sub(center);
    let b = f.dot(d);
    let c = f.dot(f) - radius * radius;
    let disc = b * b - len2 * c;
    if disc < 0.0 {
        return vec![];
    }
    let sqrt = disc.sqrt();
    let mut out = Vec::with_capacity(2);
    for t in [(-b - sqrt) / len2, (-b + sqrt) / len2] {
        let point = a1.add(d.scale(t));
        if point.is_finite() && !out.iter().any(|(_, p): &(f64, P)| p.distance(point) <= 1e-9) {
            out.push((t, point));
        }
    }
    out
}

/// Intersections of an infinite line through `a1`/`a2` with an arc; `t` is
/// measured along `a2 - a1`.
pub fn line_arc_intersections_infinite(a1: P, a2: P, center: P, radius: f64, start: f64, end: f64) -> Vec<(f64, P)> {
    line_circle_intersections_infinite(a1, a2, center, radius)
        .into_iter()
        .filter(|(_, p)| angle_in_arc(p.sub(center).angle(), start, end))
        .collect()
}

/// Intersections of a segment with an arc (angles in radians).
pub fn segment_arc_intersections(a1: P, a2: P, center: P, radius: f64, start: f64, end: f64) -> Vec<P> {
    segment_circle_intersections(a1, a2, center, radius)
        .into_iter()
        .filter(|p| angle_in_arc(p.sub(center).angle(), start, end))
        .collect()
}

/// Intersections of two circles (0..=2).
pub fn circle_circle_intersections(c1: P, r1: f64, c2: P, r2: f64) -> Vec<P> {
    let d = c2.sub(c1);
    let dist = d.length();
    if dist <= 1e-12 || dist > r1 + r2 + 1e-9 || dist < (r1 - r2).abs() - 1e-9 {
        return vec![];
    }
    let a = (r1 * r1 - r2 * r2 + dist * dist) / (2.0 * dist);
    let h2 = r1 * r1 - a * a;
    let h = if h2 > 0.0 { h2.sqrt() } else { 0.0 };
    let base = c1.add(d.scale(a / dist));
    let perp = P::new(-d.y / dist, d.x / dist);
    let mut out = vec![base];
    if h > 1e-9 {
        out = vec![base.add(perp.scale(h)), base.sub(perp.scale(h))];
    }
    out.retain(|p| p.is_finite());
    out
}

/// Intersections of two arcs.
pub fn arc_arc_intersections(c1: P, r1: f64, s1: f64, e1: f64, c2: P, r2: f64, s2: f64, e2: f64) -> Vec<P> {
    circle_circle_intersections(c1, r1, c2, r2)
        .into_iter()
        .filter(|p| angle_in_arc(p.sub(c1).angle(), s1, e1) && angle_in_arc(p.sub(c2).angle(), s2, e2))
        .collect()
}

/// Closest distance between two segments.
pub fn segment_segment_distance(a1: P, a2: P, b1: P, b2: P) -> f64 {
    if segment_intersection(a1, a2, b1, b2).is_some() {
        return 0.0;
    }
    let d = [
        point_segment_distance(a1, b1, b2),
        point_segment_distance(a2, b1, b2),
        point_segment_distance(b1, a1, a2),
        point_segment_distance(b2, a1, a2),
    ];
    d.into_iter().fold(f64::INFINITY, f64::min)
}

pub fn point_segment_distance(p: P, a: P, b: P) -> f64 {
    let ab = b.sub(a);
    let len2 = ab.dot(ab);
    if len2 <= 1e-24 {
        return p.distance(a);
    }
    let t = (p.sub(a).dot(ab) / len2).clamp(0.0, 1.0);
    p.distance(a.add(ab.scale(t)))
}

/// Projection parameter of `p` on the infinite line a..b (0 at a, 1 at b).
pub fn projection_t(p: P, a: P, b: P) -> Option<f64> {
    let ab = b.sub(a);
    let len2 = ab.dot(ab);
    if len2 <= 1e-24 {
        return None;
    }
    Some(p.sub(a).dot(ab) / len2)
}

/// Intersections between two primitives used as trim boundaries.
#[derive(Clone, Copy, Debug)]
pub enum Primitive {
    Segment { a: P, b: P },
    Circle { c: P, r: f64 },
    Arc { c: P, r: f64, start: f64, end: f64 },
}

pub fn intersections(a: &Primitive, b: &Primitive) -> Vec<P> {
    match (a, b) {
        (Primitive::Segment { a: a1, b: a2 }, Primitive::Segment { a: b1, b: b2 }) => {
            segment_intersection(*a1, *a2, *b1, *b2).into_iter().collect()
        }
        (Primitive::Segment { a: a1, b: a2 }, Primitive::Circle { c, r }) => {
            segment_circle_intersections(*a1, *a2, *c, *r)
        }
        (Primitive::Segment { a: a1, b: a2 }, Primitive::Arc { c, r, start, end }) => {
            segment_arc_intersections(*a1, *a2, *c, *r, *start, *end)
        }
        (Primitive::Circle { c, r }, Primitive::Segment { a: a1, b: a2 }) => {
            segment_circle_intersections(*a1, *a2, *c, *r)
        }
        (Primitive::Arc { c, r, start, end }, Primitive::Segment { a: a1, b: a2 }) => {
            segment_arc_intersections(*a1, *a2, *c, *r, *start, *end)
        }
        (Primitive::Circle { c: c1, r: r1 }, Primitive::Circle { c: c2, r: r2 }) => {
            circle_circle_intersections(*c1, *r1, *c2, *r2)
        }
        (Primitive::Circle { c: c1, r: r1 }, Primitive::Arc { c: c2, r: r2, start, end }) => {
            circle_circle_intersections(*c1, *r1, *c2, *r2)
                .into_iter()
                .filter(|p| angle_in_arc(p.sub(*c2).angle(), *start, *end))
                .collect()
        }
        (Primitive::Arc { c: c1, r: r1, start: s1, end: e1 }, Primitive::Circle { c: c2, r: r2 }) => {
            circle_circle_intersections(*c1, *r1, *c2, *r2)
                .into_iter()
                .filter(|p| angle_in_arc(p.sub(*c1).angle(), *s1, *e1))
                .collect()
        }
        (
            Primitive::Arc { c: c1, r: r1, start: s1, end: e1 },
            Primitive::Arc { c: c2, r: r2, start: s2, end: e2 },
        ) => arc_arc_intersections(*c1, *r1, *s1, *e1, *c2, *r2, *s2, *e2),
    }
}

/// Shortest distance between two primitives (0 when intersecting). Used by
/// the `measure distance` query for entity pairs.
pub fn primitive_distance(a: &Primitive, b: &Primitive) -> f64 {
    if !intersections(a, b).is_empty() {
        return 0.0;
    }
    match (a, b) {
        (Primitive::Segment { a: a1, b: a2 }, Primitive::Segment { a: b1, b: b2 }) => {
            segment_segment_distance(*a1, *a2, *b1, *b2)
        }
        (Primitive::Segment { a: a1, b: a2 }, Primitive::Circle { c, r })
        | (Primitive::Circle { c, r }, Primitive::Segment { a: a1, b: a2 }) => {
            point_segment_distance(*c, *a1, *a2) - r
        }
        (Primitive::Segment { a: a1, b: a2 }, Primitive::Arc { c, r, start, end })
        | (Primitive::Arc { c, r, start, end }, Primitive::Segment { a: a1, b: a2 }) => {
            // Conservative: distance to the supporting circle, then to both
            // arc endpoints; the minimum of these is an upper bound and is
            // exact when the closest point on the circle is inside the arc.
            let seg = point_segment_distance(*c, *a1, *a2) - r;
            let e1 = c.add(P::new(r * start.cos(), r * start.sin()));
            let e2 = c.add(P::new(r * end.cos(), r * end.sin()));
            seg.min(point_segment_distance(e1, *a1, *a2))
                .min(point_segment_distance(e2, *a1, *a2))
        }
        (Primitive::Circle { c: c1, r: r1 }, Primitive::Circle { c: c2, r: r2 }) => {
            (c1.distance(*c2) - r1 - r2).abs().min((c1.distance(*c2) - (r1 - r2).abs()).abs())
        }
        (Primitive::Circle { c: c1, r: r1 }, Primitive::Arc { c: c2, r: r2, start, end })
        | (Primitive::Arc { c: c2, r: r2, start, end }, Primitive::Circle { c: c1, r: r1 }) => {
            let mut d = (c1.distance(*c2) - r1 - r2).abs();
            let e1 = c2.add(P::new(r2 * start.cos(), r2 * start.sin()));
            let e2 = c2.add(P::new(r2 * end.cos(), r2 * end.sin()));
            d = d.min((c1.distance(e1) - r1).abs()).min((c1.distance(e2) - r1).abs());
            d
        }
        (
            Primitive::Arc { c: c1, r: r1, start: s1, end: e1 },
            Primitive::Arc { c: c2, r: r2, start: s2, end: e2 },
        ) => {
            let mut d = (c1.distance(*c2) - r1 - r2).abs().min((c1.distance(*c2) - (r1 - r2).abs()).abs());
            let a1 = c1.add(P::new(r1 * s1.cos(), r1 * s1.sin()));
            let a2 = c1.add(P::new(r1 * e1.cos(), r1 * e1.sin()));
            let b1 = c2.add(P::new(r2 * s2.cos(), r2 * s2.sin()));
            let b2 = c2.add(P::new(r2 * e2.cos(), r2 * e2.sin()));
            for p in [a1, a2] {
                for q in [b1, b2] {
                    d = d.min(p.distance(q));
                }
            }
            d
        }
    }
}

/// Offset a polyline (open, non-self-intersecting assumed by caller) by
/// `distance` on the side of `side`. Returns `None` when the offset folds
/// (miter would reverse a segment), which the caller reports as unsupported.
pub fn offset_open_polyline(points: &[P], distance: f64, side: P) -> Option<Vec<P>> {
    if points.len() < 2 || distance <= 0.0 {
        return None;
    }
    let segment_offset = |a: P, b: P| -> Option<(P, P, P)> {
        // Returns the shifted endpoints plus the unit normal used.
        let dir = b.sub(a).normalized()?;
        let n = P::new(-dir.y, dir.x);
        // Choose the normal sign that points toward `side`.
        let toward = side.sub(a).dot(n);
        let n = if toward >= 0.0 { n } else { n.scale(-1.0) };
        Some((a.add(n.scale(distance)), b.add(n.scale(distance)), n))
    };
    let mut shifted: Vec<(P, P, P)> = Vec::with_capacity(points.len() - 1);
    for pair in points.windows(2) {
        shifted.push(segment_offset(pair[0], pair[1])?);
    }
    let mut out = Vec::with_capacity(points.len());
    out.push(shifted[0].0);
    for i in 1..shifted.len() {
        let (_, b1, _) = shifted[i - 1];
        let (a2, _, _) = shifted[i];
        // Intersect the two offset lines; fall back to the shared shifted
        // point when they are parallel.
        let p1 = shifted[i - 1].0;
        let p2 = shifted[i - 1].1;
        let p3 = shifted[i].0;
        let p4 = shifted[i].1;
        let join = line_line_intersection(p1, p2, p3, p4).unwrap_or(b1);
        if !join.is_finite() {
            return None;
        }
        let _ = a2;
        out.push(join);
    }
    out.push(shifted.last()?.1);
    // Reject a folded offset: every new segment must keep the original
    // direction within less than a right angle.
    for (i, pair) in out.windows(2).enumerate() {
        let orig = points[i + 1].sub(points[i]);
        let next = pair[1].sub(pair[0]);
        if orig.dot(next) <= 0.0 {
            return None;
        }
    }
    Some(out)
}

/// Intersection of two infinite lines (not segments).
pub fn line_line_intersection(a1: P, a2: P, b1: P, b2: P) -> Option<P> {
    let r = a2.sub(a1);
    let s = b2.sub(b1);
    let denom = r.cross(s);
    if denom.abs() <= 1e-12 {
        return None;
    }
    let t = b1.sub(a1).cross(s) / denom;
    let point = a1.add(r.scale(t));
    point.is_finite().then_some(point)
}

/// Polyline segment lengths including bulge arcs.
pub fn polyline_length(points: &[P], bulges: &[f64], closed: bool) -> f64 {
    let n = points.len();
    if n < 2 {
        return 0.0;
    }
    let count = if closed { n } else { n - 1 };
    let mut total = 0.0;
    for i in 0..count {
        let a = points[i];
        let b = points[(i + 1) % n];
        let chord = a.distance(b);
        let bulge = bulges.get(i).copied().unwrap_or(0.0);
        if bulge.abs() <= 1e-12 {
            total += chord;
        } else {
            let theta = 4.0 * bulge.abs().atan();
            if theta.abs() > 1e-9 {
                total += chord * theta / (2.0 * (theta / 2.0).sin());
            } else {
                total += chord;
            }
        }
    }
    total
}

/// Signed area of a polyline in the XY plane (shoelace, arcs as circular
/// segments). Positive is CCW.
pub fn polyline_signed_area(points: &[P], bulges: &[f64], closed: bool) -> f64 {
    let n = points.len();
    if n < 2 {
        return 0.0;
    }
    let mut area = 0.0;
    let count = if closed { n } else { n - 1 };
    for i in 0..count {
        let a = points[i];
        let b = points[(i + 1) % n];
        let cross = a.cross(b);
        area += cross;
        let bulge = bulges.get(i).copied().unwrap_or(0.0);
        if bulge.abs() > 1e-12 {
            let theta = 4.0 * bulge.atan();
            let chord = a.distance(b);
            let r2 = (chord / (2.0 * (theta / 2.0).sin())).powi(2);
            // Circular segment area = r²/2 (θ - sin θ); signed by bulge.
            let segment = 0.5 * r2 * (theta - theta.sin());
            area += segment;
        }
    }
    area * 0.5
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn segment_intersection_basic() {
        let p = segment_intersection(P::new(0.0, 0.0), P::new(10.0, 0.0), P::new(5.0, -5.0), P::new(5.0, 5.0)).unwrap();
        assert!((p.x - 5.0).abs() < 1e-9 && p.y.abs() < 1e-9);
        assert!(segment_intersection(P::new(0.0, 0.0), P::new(1.0, 0.0), P::new(0.0, 1.0), P::new(1.0, 1.0)).is_none());
    }

    #[test]
    fn segment_circle_and_arc() {
        let hits = segment_circle_intersections(P::new(-10.0, 0.0), P::new(10.0, 0.0), P::new(0.0, 0.0), 5.0);
        assert_eq!(hits.len(), 2);
        let arc = segment_arc_intersections(P::new(-10.0, 0.0), P::new(10.0, 0.0), P::new(0.0, 0.0), 5.0, 0.0, PI / 2.0);
        assert_eq!(arc.len(), 1);
        assert!((arc[0].x - 5.0).abs() < 1e-9);
    }

    #[test]
    fn circle_circle_intersections_two_points() {
        let hits = circle_circle_intersections(P::new(0.0, 0.0), 5.0, P::new(6.0, 0.0), 5.0);
        assert_eq!(hits.len(), 2);
        for h in hits {
            assert!((h.distance(P::new(0.0, 0.0)) - 5.0).abs() < 1e-9);
        }
    }

    #[test]
    fn offset_polyline_right_angle() {
        let points = [P::new(0.0, 0.0), P::new(10.0, 0.0), P::new(10.0, 10.0)];
        let out = offset_open_polyline(&points, 1.0, P::new(5.0, 5.0)).unwrap();
        assert_eq!(out.len(), 3);
        assert!((out[0].y - 1.0).abs() < 1e-9);
        assert!((out[1].x - 9.0).abs() < 1e-9 && (out[1].y - 1.0).abs() < 1e-9);
        assert!((out[2].x - 9.0).abs() < 1e-9);
    }

    #[test]
    fn polyline_area_and_length() {
        let square = [P::new(0.0, 0.0), P::new(4.0, 0.0), P::new(4.0, 4.0), P::new(0.0, 4.0)];
        assert!((polyline_length(&square, &[], true) - 16.0).abs() < 1e-9);
        assert!((polyline_signed_area(&square, &[], true) - 16.0).abs() < 1e-9);
    }

    #[test]
    fn arc_angle_range() {
        assert!(angle_in_arc(0.0, -PI / 2.0, PI / 2.0));
        assert!(!angle_in_arc(PI, -PI / 2.0, PI / 2.0));
        assert!(!angle_in_arc(3.0 * PI / 2.0, PI / 2.0, PI));
        assert!(angle_in_arc(0.0, 7.0 * PI / 4.0, PI / 4.0));
    }
}
