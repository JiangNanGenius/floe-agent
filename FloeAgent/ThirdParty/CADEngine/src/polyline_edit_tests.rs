// SPDX-License-Identifier: MPL-2.0
//! E21 source tests. Run with cargo test --locked e21_ after integration.
use super::*;
use crate::polyline_edit::{self, Plane};
use acadrust::DxfVersion;

fn e21_document() -> CadDocument {
    let mut document = CadDocument::new();
    document.version = DxfVersion::AC1032;
    let mut profile = LwPolyline::from_points(vec![
        Vector2::new(0.0, 0.0), Vector2::new(20.0, 0.0),
        Vector2::new(20.0, 10.0), Vector2::new(0.0, 10.0),
    ]);
    profile.is_closed = true;
    profile.normal = Vector3::new(0.0, 0.6, 0.8);
    profile.elevation = 7.0;
    for (i, vertex) in profile.vertices.iter_mut().enumerate() {
        vertex.vertex_id = i as i32 + 1;
        vertex.bulge = if i % 2 == 1 { 1.0 } else { 0.0 };
    }
    let plane = Plane::of(&profile).unwrap();
    document.add_entity(EntityType::LwPolyline(profile)).unwrap();
    document.add_entity(EntityType::Line(Line::from_points(
        plane.world(P::new(10.0, -15.0)), plane.world(P::new(10.0, 25.0)),
    ))).unwrap();
    document.add_entity(EntityType::Text(Text::with_value("Untouched E21", Vector3::new(70.0, 80.0, 0.0)).with_height(2.5))).unwrap();
    document
}

fn e21_session(format: &str) -> CadSession {
    let input = encode(&e21_document(), format).unwrap();
    let session = CadSession::new(&input, format).unwrap();
    session.save().unwrap(); // baseline writer/reader must already preserve this fixture
    session
}

fn e21_id(session: &CadSession, kind: &str) -> String {
    session.document.entities().find(|e| entity_kind(e) == kind)
        .map(|e| format!("{:X}", e.common().handle)).unwrap()
}

fn e21_poly<'a>(session: &'a CadSession, id: &str) -> &'a LwPolyline {
    match session.document.get_entity(handle(id).unwrap()).unwrap() {
        EntityType::LwPolyline(p) => p,
        _ => panic!("expected polyline"),
    }
}

fn e21_image(session: &CadSession, id: &str) -> Value {
    entity_image(session.document.get_entity(handle(id).unwrap()).unwrap())
}

fn e21_world(polyline: &LwPolyline, point: P) -> [f64; 3] {
    let p = Plane::of(polyline).unwrap().world(point);
    [p.x, p.y, p.z]
}

fn e21_edit(session: &mut CadSession, request: Value) -> Value {
    serde_json::from_str(&session.edit(&request.to_string()).unwrap()).unwrap()
}

fn e21_near(a: f64, b: f64) { assert!((a - b).abs() < 1e-7, "{a} != {b}"); }
fn e21_radius(a: &LwVertex, b: &LwVertex) -> f64 {
    let chord = (a.location.x - b.location.x).hypot(a.location.y - b.location.y);
    chord * (1.0 + a.bulge * a.bulge) / (4.0 * a.bulge.abs())
}
fn e21_area(p: &LwPolyline) -> f64 {
    polyline_signed_area(&p.vertices.iter().map(|v| P::new(v.location.x, v.location.y)).collect::<Vec<_>>(),
        &p.vertices.iter().map(|v| v.bulge).collect::<Vec<_>>(), true)
}

#[test]
fn e21_oblique_closed_bulge_offset_trim_undo_same_format_reopen() {
    for format in ["dxf", "dwg"] {
        let mut session = e21_session(format);
        let id = e21_id(&session, "LwPolyline");
        let boundary = e21_id(&session, "Line");
        let sentinel = e21_id(&session, "Text");
        let original = e21_image(&session, &id);
        let sentinel_image = e21_image(&session, &sentinel);
        let boundary_image = e21_image(&session, &boundary);
        let side = e21_world(e21_poly(&session, &id), P::new(30.0, 5.0));
        let reply = e21_edit(&mut session, json!({"operation":"offset","handle":id,"distance":2.0,"side":side}));
        let copy_id = reply["created"][0].as_str().unwrap().to_owned();
        assert_ne!(copy_id, id);
        assert_eq!(original, e21_image(&session, &id));
        let offset = e21_poly(&session, &copy_id);
        assert!(offset.is_closed);
        assert_eq!(offset.normal, Vector3::new(0.0, 0.6, 0.8));
        e21_near(offset.elevation, 7.0);
        assert_eq!(offset.vertices.iter().map(|v| v.vertex_id).collect::<Vec<_>>(), vec![1, 2, 3, 4]);
        for (vertex, point) in offset.vertices.iter().zip([(0.0, -2.0), (20.0, -2.0), (20.0, 12.0), (0.0, 12.0)]) {
            e21_near(vertex.location.x, point.0); e21_near(vertex.location.y, point.1);
        }
        e21_near(e21_radius(&offset.vertices[1], &offset.vertices[2]), 7.0);
        e21_near(e21_area(offset), 280.0 + 49.0 * std::f64::consts::PI);
        let offset_image = e21_image(&session, &copy_id);
        assert!(session.undo());
        assert!(session.document.get_entity(handle(&copy_id).unwrap()).is_none());
        assert!(!session.undo()); // one snapshot for the one offset
        assert!(session.redo());
        assert_eq!(offset_image, e21_image(&session, &copy_id));
        let bytes = session.save().unwrap();
        let document = read(&bytes, format).unwrap();
        verify(&session.document, &document).unwrap();
        let mut reopened = CadSession::new(&bytes, format).unwrap();
        assert_eq!(offset_image, e21_image(&reopened, &copy_id));
        let pick = e21_world(e21_poly(&reopened, &id), P::new(25.0, 5.0));
        e21_edit(&mut reopened, json!({"operation":"trim","handle":id,"boundary":boundary,"pick":pick}));
        let trimmed = e21_poly(&reopened, &id);
        assert!(!trimmed.is_closed);
        assert_eq!(trimmed.vertices.len(), 4);
        assert_eq!(trimmed.vertices.iter().map(|v| v.vertex_id).collect::<Vec<_>>(), vec![5, 4, 1, 6]);
        for (vertex, (x, y, bulge)) in trimmed.vertices.iter().zip([(10.0, 10.0, 0.0), (0.0, 10.0, 1.0), (0.0, 0.0, 0.0), (10.0, 0.0, 0.0)]) {
            e21_near(vertex.location.x, x); e21_near(vertex.location.y, y); e21_near(vertex.bulge, bulge);
        }
        e21_near(e21_radius(&trimmed.vertices[1], &trimmed.vertices[2]), 5.0);
        let trimmed_image = e21_image(&reopened, &id);
        assert_eq!(sentinel_image, e21_image(&reopened, &sentinel));
        assert_eq!(boundary_image, e21_image(&reopened, &boundary));
        assert_eq!(offset_image, e21_image(&reopened, &copy_id));
        assert!(reopened.undo());
        assert_eq!(original, e21_image(&reopened, &id));
        assert!(!reopened.undo());
        assert!(reopened.redo());
        assert_eq!(trimmed_image, e21_image(&reopened, &id));
        let saved = reopened.save().unwrap();
        let final_session = CadSession::new(&saved, format).unwrap();
        verify(&reopened.document, &final_session.document).unwrap();
        assert_eq!(trimmed_image, e21_image(&final_session, &id));
        assert_eq!(sentinel_image, e21_image(&final_session, &sentinel));
        assert_eq!(boundary_image, e21_image(&final_session, &boundary));
        assert_eq!(offset_image, e21_image(&final_session, &copy_id));
    }
}

#[test]
fn e21_trim_inside_arcs_retains_exact_bulges_radii_ids_and_widths() {
    let session = e21_session("dxf");
    let id = e21_id(&session, "LwPolyline");
    let mut source = e21_poly(&session, &id).clone();
    source.constant_width = 0.3;
    source.vertices[1].start_width = 2.0;
    source.vertices[1].end_width = 4.0;
    source.vertices[3].start_width = 6.0;
    source.vertices[3].end_width = 8.0;
    let world_pick = Plane::of(&source).unwrap().world(P::new(10.0, -3.0));
    let cut = [Primitive::Segment { a: P::new(-15.0, 5.0), b: P::new(35.0, 5.0) }];
    let result = polyline_edit::trim(&source, &cut, world_pick).unwrap();
    assert!(!result.is_closed);
    assert_eq!(result.vertices.len(), 4);
    e21_near(result.vertices[0].location.x, 25.0);
    e21_near(result.vertices[3].location.x, -5.0);
    e21_near(result.vertices[0].bulge, (std::f64::consts::PI / 8.0).tan());
    e21_near(result.vertices[2].bulge, (std::f64::consts::PI / 8.0).tan());
    e21_near(e21_radius(&result.vertices[0], &result.vertices[1]), 5.0);
    e21_near(e21_radius(&result.vertices[2], &result.vertices[3]), 5.0);
    assert_eq!(result.vertices[1].vertex_id, 3);
    assert_eq!(result.vertices[2].vertex_id, 4);
    e21_near(result.vertices[0].start_width, 3.0);
    e21_near(result.vertices[0].end_width, 4.0);
    e21_near(result.vertices[2].start_width, 6.0);
    e21_near(result.vertices[2].end_width, 7.0);
    e21_near(result.constant_width, source.constant_width);
    assert_eq!(result.common.handle, source.common.handle);
    assert_eq!(result.normal, source.normal);
    assert_eq!(result.elevation, source.elevation);
}

#[test]
fn e21_clockwise_offset_and_major_bulge_preserve_traversal() {
    let session = e21_session("dxf");
    let id = e21_id(&session, "LwPolyline");
    let source = e21_poly(&session, &id);
    let mut clockwise = source.clone();
    clockwise.vertices = source.vertices.iter().rev().enumerate().map(|(i, vertex)| {
        let mut v = *vertex;
        let index = source.vertices.len() - 1 - i;
        v.bulge = -source.vertices[(index + source.vertices.len() - 1) % source.vertices.len()].bulge;
        v
    }).collect();
    let side = Plane::of(&clockwise).unwrap().world(P::new(30.0, 5.0));
    let result = polyline_edit::offset(&clockwise, 2.0, side).unwrap();
    assert!(e21_area(&clockwise) < 0.0 && e21_area(&result) < 0.0);
    assert_eq!(result.vertices.iter().map(|v| v.vertex_id).collect::<Vec<_>>(), clockwise.vertices.iter().map(|v| v.vertex_id).collect::<Vec<_>>());
    assert!(result.vertices.iter().filter(|v| v.bulge != 0.0).all(|v| v.bulge < 0.0));
    e21_near(e21_area(&result), -(280.0 + 49.0 * std::f64::consts::PI));
    // One 270-degree arc is retained as one exact arc, not split into chords.
    let mut major = LwPolyline::from_points(vec![Vector2::new(5.0, 0.0), Vector2::new(0.0, -5.0)]);
    major.vertices[0].bulge = (3.0 * std::f64::consts::PI / 8.0).tan();
    let result = polyline_edit::offset(&major, 1.0, Vector3::new(0.0, 7.0, 0.0)).unwrap();
    assert_eq!(result.vertices.len(), 2);
    e21_near(result.vertices[0].bulge, major.vertices[0].bulge);
    e21_near(e21_radius(&result.vertices[0], &result.vertices[1]), 6.0);
}

#[test]
fn e21_open_polyline_offset_and_trim_keep_one_chain() {
    let mut source = LwPolyline::from_points(vec![Vector2::new(0.0, 0.0), Vector2::new(10.0, 0.0), Vector2::new(10.0, 10.0)]);
    for (i, vertex) in source.vertices.iter_mut().enumerate() { vertex.vertex_id = i as i32 + 1; }
    let result = polyline_edit::offset(&source, 1.0, Vector3::new(5.0, 5.0, 0.0)).unwrap();
    assert_eq!(result.vertices.len(), 3);
    for (v, (x, y)) in result.vertices.iter().zip([(0.0, 1.0), (9.0, 1.0), (9.0, 10.0)]) {
        e21_near(v.location.x, x); e21_near(v.location.y, y);
    }
    let boundaries = [Primitive::Segment { a: P::new(5.0, -5.0), b: P::new(5.0, 5.0) }];
    let result = polyline_edit::trim(&source, &boundaries, Vector3::new(0.0, 0.0, 0.0)).unwrap();
    e21_near(result.vertices[0].location.x, 5.0);
    assert_eq!(result.vertices[1].vertex_id, 2);
    assert_eq!(result.vertices[2].vertex_id, 3);
}

#[test]
fn e21_opposite_ocs_normal_boundary_has_the_same_exact_intersections() {
    let session = e21_session("dxf");
    let id = e21_id(&session, "LwPolyline");
    let source = e21_poly(&session, &id);
    let mut opposite = source.clone();
    opposite.normal = opposite.normal * -1.0;
    opposite.elevation *= -1.0;
    for vertex in &mut opposite.vertices { vertex.location.x *= -1.0; vertex.bulge *= -1.0; }
    let a = polyline_edit::primitives_in_plane(&EntityType::LwPolyline(source.clone()), Plane::of(source).unwrap()).unwrap();
    let b = polyline_edit::primitives_in_plane(&EntityType::LwPolyline(opposite), Plane::of(source).unwrap()).unwrap();
    let line = Primitive::Segment { a: P::new(10.0, -15.0), b: P::new(10.0, 25.0) };
    let hits = |primitives: &[Primitive]| -> Vec<P> { primitives.iter().flat_map(|p| intersections(&line, p)).collect() };
    let ah = hits(&a); let bh = hits(&b);
    assert_eq!(ah.len(), 2); assert_eq!(bh.len(), 2);
    for point in ah { assert!(bh.iter().any(|p| p.distance(point) < 1e-8)); }
}

#[test]
fn e21_bulge_boundary_trims_a_world_xy_line_without_sampling() {
    let mut document = CadDocument::new();
    let line = document.add_entity(EntityType::Line(Line::from_coords(-10.0, 0.0, 0.0, 10.0, 0.0, 0.0))).unwrap();
    let mut polyline = LwPolyline::from_points(vec![Vector2::new(0.0, -5.0), Vector2::new(0.0, 5.0)]);
    polyline.vertices[0].bulge = 1.0; // right semicircle, crosses line at x=5
    let boundary = document.add_entity(EntityType::LwPolyline(polyline)).unwrap();
    let mut session = CadSession { document, format: "dxf".into(), undo: vec![], redo: vec![], active_layer: "0".into() };
    e21_edit(&mut session, json!({"operation":"trim","handle":format!("{line:X}"),"boundary":format!("{boundary:X}"),"pick":[9.0,0.0,0.0]}));
    match session.document.get_entity(line).unwrap() {
        EntityType::Line(line) => e21_near(line.end.x, 5.0),
        _ => panic!(),
    }
}

#[test]
fn e21_rejections_leave_document_and_both_history_stacks_unchanged() {
    let mut session = e21_session("dxf");
    let id = e21_id(&session, "LwPolyline");
    let boundary = e21_id(&session, "Line");
    let side = e21_world(e21_poly(&session, &id), P::new(30.0, 5.0));
    e21_edit(&mut session, json!({"operation":"offset","handle":id,"distance":2.0,"side":side}));
    assert!(session.undo()); // establish a redo entry which failures must preserve
    let inside = e21_world(e21_poly(&session, &id), P::new(10.0, 5.0));
    for request in [
        json!({"operation":"offset","handle":id,"distance":6.0,"side":inside}),
        json!({"operation":"offset","handle":id,"distance":2.0,"side":[30.0,5.0,0.0]}),
        json!({"operation":"trim","handle":id,"boundary":boundary,"pick":[25.0,5.0,0.0]}),
        json!({"operation":"trim","handle":id,"boundary":id,"pick":side}),
    ] {
        let before = session.inspect(0, 500).unwrap();
        assert!(session.edit(&request.to_string()).is_err());
        assert_eq!(session.inspect(0, 500).unwrap(), before);
        assert_eq!(session.undo.len(), 0); assert_eq!(session.redo.len(), 1);
    }
    assert!(session.redo());
}

#[test]
fn e21_reactors_and_attached_data_are_not_silently_dropped() {
    let mut session = e21_session("dxf");
    let id = e21_id(&session, "LwPolyline");
    let boundary = e21_id(&session, "Line");
    if let EntityType::LwPolyline(p) = session.document.get_entity_mut(handle(&id).unwrap()).unwrap() {
        p.common.reactors.push(Handle::new(0xABC));
    }
    let pick = e21_world(e21_poly(&session, &id), P::new(25.0, 5.0));
    let before = e21_image(&session, &id);
    assert!(session.edit(&json!({"operation":"trim","handle":id,"boundary":boundary,"pick":pick}).to_string()).is_err());
    assert!(session.edit(&json!({"operation":"offset","handle":id,"distance":2.0,"side":pick}).to_string()).is_err());
    assert_eq!(before, e21_image(&session, &id));
    assert!(!session.undo()); assert!(!session.redo());
}

#[test]
fn e21_folded_and_overlapping_inputs_are_rejected() {
    for points in [
        vec![(0.0,0.0),(10.0,10.0),(0.0,10.0),(10.0,0.0)],
        vec![(0.0,0.0),(10.0,0.0),(5.0,0.0)],
    ] {
        let mut polyline = LwPolyline::from_points(points.into_iter().map(|(x,y)| Vector2::new(x,y)).collect());
        polyline.is_closed = true;
        assert!(polyline_edit::offset(&polyline, 1.0, Vector3::new(3.0, 4.0, 0.0)).is_err());
    }
}

#[test]
fn e21_capabilities_explain_the_bounded_ocs_scope() {
    let value = capabilities();
    assert_eq!(value["modify"]["trim"]["bulgePolylines"], true);
    assert_eq!(value["modify"]["offset"]["closedLwPolyline"], true);
    assert_eq!(value["modify"]["lwPolylineOCS"]["trim"], true);
    assert_eq!(value["modify"]["nonDefaultOCS"], false); // no blanket OCS claim
}

#[test]
fn e21_imported_oblique_dxf_fixture_keeps_handles_and_ocs_on_save() {
    let bytes = include_bytes!("fixtures/e21-oblique-closed-bulge.dxf");
    let session = CadSession::new(bytes, "dxf").unwrap();
    let polyline = e21_poly(&session, "F010");
    assert!(polyline.is_closed);
    assert_eq!(polyline.normal, Vector3::new(0.0, 0.6, 0.8));
    e21_near(polyline.elevation, 7.0);
    let output = session.save().unwrap();
    let reread = CadSession::new(&output, "dxf").unwrap();
    verify(&session.document, &reread.document).unwrap();
    for id in ["F010", "F011", "F012"] { assert_eq!(e21_image(&session, id), e21_image(&reread, id)); }
}

#[test]
fn e21_partial_arc_trim_undo_same_format_reopen() {
    for format in ["dxf", "dwg"] {
        let mut document = e21_document();
        let source = document.entities().find_map(|entity| match entity {
            EntityType::LwPolyline(polyline) => Some(polyline.clone()), _ => None,
        }).unwrap();
        let plane = Plane::of(&source).unwrap();
        for entity in document.entities_mut() {
            if let EntityType::Line(line) = entity {
                line.start = plane.world(P::new(-15.0, 5.0));
                line.end = plane.world(P::new(35.0, 5.0));
            }
        }
        let bytes = encode(&document, format).unwrap();
        let mut session = CadSession::new(&bytes, format).unwrap();
        let id = e21_id(&session, "LwPolyline");
        let boundary = e21_id(&session, "Line");
        let original = e21_image(&session, &id);
        let pick = e21_world(e21_poly(&session, &id), P::new(10.0, -3.0));
        e21_edit(&mut session, json!({"operation":"trim","handle":id,"boundary":boundary,"pick":pick}));
        let result = e21_poly(&session, &id);
        assert_eq!(result.vertices.len(), 4);
        e21_near(result.vertices[0].bulge, (std::f64::consts::PI / 8.0).tan());
        e21_near(result.vertices[2].bulge, (std::f64::consts::PI / 8.0).tan());
        e21_near(e21_radius(&result.vertices[0], &result.vertices[1]), 5.0);
        e21_near(e21_radius(&result.vertices[2], &result.vertices[3]), 5.0);
        let trimmed = e21_image(&session, &id);
        assert!(session.undo()); assert_eq!(e21_image(&session, &id), original);
        assert!(session.redo()); assert_eq!(e21_image(&session, &id), trimmed);
        let saved = session.save().unwrap();
        let reopened = CadSession::new(&saved, format).unwrap();
        verify(&session.document, &reopened.document).unwrap();
        assert_eq!(e21_image(&reopened, &id), trimmed);
    }
}

#[test]
fn e21_bulge_area_counts_each_circular_segment_once() {
    let vertices = [P::new(0.0, 0.0), P::new(0.0, 10.0)];
    let area = 25.0 * std::f64::consts::PI;
    e21_near(polyline_signed_area(&vertices, &[1.0, 1.0], true), area);
    e21_near(polyline_signed_area(&vertices, &[-1.0, -1.0], true), -area);
}
