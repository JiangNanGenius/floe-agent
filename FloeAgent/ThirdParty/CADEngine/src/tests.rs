// SPDX-License-Identifier: MPL-2.0
//! Native qualification for the CAD engine. Run with `cargo test --locked`.
use super::*;
use acadrust::objects::ObjectType;
use acadrust::{DxfVersion, Layer, LineType, TableEntry, TextStyle};

fn fixture(version: DxfVersion) -> CadDocument {
    let mut doc = CadDocument::new();
    doc.version = version;
    doc.layers.add(Layer::new("Dimensions")).unwrap();
    doc.add_entity(EntityType::Line(Line::from_coords(0., 0., 0., 100., 50., 0.))).unwrap();
    doc.add_entity(EntityType::Circle(Circle::from_coords(40., 30., 0., 12.))).unwrap();
    doc.add_entity(EntityType::Text(Text::with_value("尺寸 / CAD", Vector3::new(5., 8., 0.)).with_height(2.5))).unwrap();
    doc
}

fn session(version: DxfVersion, format: &str) -> CadSession {
    let input = encode(&fixture(version), format).unwrap();
    CadSession::new(&input, format).unwrap()
}

fn handle_of(session: &CadSession, kind: &str) -> String {
    for entity in session.document.entities() {
        if entity_kind(entity) == kind {
            return format!("{:X}", entity.common().handle);
        }
    }
    panic!("no {kind} entity")
}

fn created_handles(session: &CadSession, json_value: &str) -> Vec<String> {
    let _ = session;
    let value: Value = serde_json::from_str(json_value).unwrap();
    value["created"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect()
}

fn edit_ok(session: &mut CadSession, request: Value) -> String {
    session.edit(&request.to_string()).unwrap_or_else(|e| panic!("edit failed: {e}"))
}

#[test]
fn native_dxf_and_dwg_edit_save_reopen() {
    for version in [DxfVersion::AC1024, DxfVersion::AC1027, DxfVersion::AC1032] {
        for format in ["dxf", "dwg"] {
            let input = encode(&fixture(version), format).unwrap();
            let mut session = CadSession::new(&input, format).unwrap();
            let line = session.document.entities().find(|e| matches!(e, EntityType::Line(_))).unwrap().common().handle;
            edit_ok(&mut session, json!({"operation":"move","handle":format!("{line:X}"),"delta":[5,7,0]}));
            edit_ok(&mut session, json!({"operation":"addCircle","center":[80,20,0],"radius":3,"layer":"Dimensions"}));
            assert!(session.undo());
            assert!(session.redo());
            let output = session.save().unwrap_or_else(|e| panic!("{format} {version:?}: {e}"));
            std::fs::create_dir_all("qualification-fixtures").unwrap();
            std::fs::write(format!("qualification-fixtures/input-{version:?}.{format}"), &input).unwrap();
            std::fs::write(format!("qualification-fixtures/edited-{version:?}.{format}"), &output).unwrap();
            if format == "dwg" {
                assert_eq!(&output[..6], &input[..6]);
            }
            let reopened = read(&output, format).unwrap();
            assert_eq!(reopened.entity_count(), 4);
            match reopened.get_entity(line).unwrap() {
                EntityType::Line(e) => assert_eq!(e.start, Vector3::new(5., 7., 0.)),
                _ => panic!(),
            }
        }
    }
}

#[test]
fn invalid_edits_do_not_change_history_or_document() {
    let mut session = session(DxfVersion::AC1032, "dxf");
    let before = session.inspect(0, 500).unwrap();
    assert!(session
        .edit(r#"{"operation":"addCircle","center":[0,0,0],"radius":-1,"layer":"0"}"#)
        .is_err());
    assert!(session.edit(r#"{"operation":"delete","handle":"FFFFFFFFFFFF"}"#).is_err());
    assert!(session.edit(r#"{"operation":"unknownOp"}"#).is_err());
    assert_eq!(before, session.inspect(0, 500).unwrap());
    assert!(!session.undo());
}

fn annotation_lines(session: &CadSession) -> Vec<&Line> {
    session
        .document
        .entities()
        .filter_map(|e| match e {
            EntityType::Line(l) if l.common.layer == ANNOTATION_LAYER => Some(l),
            _ => None,
        })
        .collect()
}

#[test]
fn add_stroke_is_atomic_with_one_history_entry() {
    let mut session = session(DxfVersion::AC1032, "dxf");
    let base = session.document.entity_count();
    edit_ok(&mut session, json!({"operation":"addStroke","points":[[0,0,0],[10,0,0],[10,10,0]],"color":1,"lineWeight":25}));
    assert_eq!(session.document.entity_count(), base + 2);
    let lines = annotation_lines(&session);
    assert_eq!(lines.len(), 2);
    for line in &lines {
        assert_eq!(line.common.layer, ANNOTATION_LAYER);
        assert_eq!(line.common.color, Color::Index(1));
        assert_eq!(line.common.line_weight, LineWeight::Value(25));
    }
    assert_eq!(lines[0].start, Vector3::new(0., 0., 0.));
    assert_eq!(lines[0].end, Vector3::new(10., 0., 0.));
    assert_eq!(lines[1].end, Vector3::new(10., 10., 0.));
    // Exactly one snapshot for the whole stroke.
    assert!(session.undo());
    assert_eq!(session.document.entity_count(), base);
    assert!(annotation_lines(&session).is_empty());
    assert!(session.redo());
    assert_eq!(session.document.entity_count(), base + 2);
    assert_eq!(annotation_lines(&session).len(), 2);
}

#[test]
fn add_stroke_invalid_input_rolls_back_without_history() {
    let mut session = session(DxfVersion::AC1032, "dxf");
    let before = session.inspect(0, 500).unwrap();
    assert!(session
        .edit(r#"{"operation":"addStroke","points":[[0,0,0],[1,0,0],[10000000000000,0,0]]}"#)
        .is_err());
    assert!(session.edit(r#"{"operation":"addStroke","points":[[0,0,0]]}"#).is_err());
    let many: Vec<[f64; 3]> = (0..=MAX_STROKE_POINTS).map(|i| [i as f64, 0., 0.]).collect();
    assert!(session.edit(&json!({"operation":"addStroke","points":many}).to_string()).is_err());
    assert!(session.edit(r#"{"operation":"addStroke","points":[[0,0,0],[1,0,0]],"color":0}"#).is_err());
    assert!(session.edit(r#"{"operation":"addStroke","points":[[0,0,0],[1,0,0]],"color":300}"#).is_err());
    assert!(session.edit(r#"{"operation":"addStroke","points":[[0,0,0],[1,0,0]],"lineWeight":17}"#).is_err());
    assert!(session.edit(r#"{"operation":"addStroke","points":[[0,0,0],[1,0,0]],"lineWeight":-1}"#).is_err());
    assert_eq!(before, session.inspect(0, 500).unwrap());
    assert!(!session.undo());
}

#[test]
fn add_stroke_rejects_locked_annotation_layer() {
    let mut document = fixture(DxfVersion::AC1032);
    document.layers.add(Layer::new(ANNOTATION_LAYER)).unwrap();
    document.layers.get_mut(ANNOTATION_LAYER).unwrap().lock();
    let mut session = CadSession { document, format: "dxf".into(), undo: vec![], redo: vec![], active_layer: "0".into() };
    let before = session.inspect(0, 500).unwrap();
    assert!(session.edit(r#"{"operation":"addStroke","points":[[0,0,0],[5,0,0]]}"#).is_err());
    assert_eq!(before, session.inspect(0, 500).unwrap());
    assert!(!session.undo());
}

#[test]
fn add_stroke_saves_and_reopens_in_dwg() {
    let mut session = session(DxfVersion::AC1032, "dwg");
    let base = session.document.entity_count();
    edit_ok(&mut session, json!({"operation":"addStroke","points":[[0,0,0],[10,0,0],[10,10,0]],"color":1,"lineWeight":50}));
    let output = session.save().unwrap();
    assert_eq!(&output[..6], b"AC1032");
    let reopened = read(&output, "dwg").unwrap();
    assert_eq!(reopened.entity_count(), base + 2);
    assert!(reopened.layers.get(ANNOTATION_LAYER).is_some());
    let lines: Vec<&Line> = reopened
        .entities()
        .filter_map(|e| match e {
            EntityType::Line(l) if l.common.layer == ANNOTATION_LAYER => Some(l),
            _ => None,
        })
        .collect();
    assert_eq!(lines.len(), 2);
    assert_eq!(lines[0].common.color, Color::Index(1));
    assert_eq!(lines[0].common.line_weight, LineWeight::Value(50));
}

/// Remove one SECTION (by its `  2` name value) from encoded DXF text,
/// producing a well-formed drawing that omits that section entirely.
fn without_dxf_section(bytes: &[u8], section: &str) -> Vec<u8> {
    let text = String::from_utf8_lossy(bytes);
    let crlf = text.contains("\r\n");
    let lines: Vec<&str> = text.split('\n').map(|line| line.trim_end_matches('\r')).collect();
    let mut kept = Vec::with_capacity(lines.len());
    let mut i = 0;
    while i < lines.len() {
        let target = lines.get(i).is_some_and(|line| line.trim() == "0")
            && lines.get(i + 1).is_some_and(|line| line.trim() == "SECTION")
            && lines.get(i + 2).is_some_and(|line| line.trim() == "2")
            && lines.get(i + 3) == Some(&section);
        if target {
            i += 4;
            while i + 1 < lines.len() && !(lines[i].trim() == "0" && lines[i + 1].trim() == "ENDSEC") {
                i += 1;
            }
            i += 2; // consume the 0/ENDSEC pair
        } else {
            kept.push(lines[i]);
            i += 1;
        }
    }
    let eol = if crlf { "\r\n" } else { "\n" };
    let mut out = kept.join(eol);
    out.push_str(eol);
    out.into_bytes()
}

fn entity_images(session: &CadSession) -> Vec<Value> {
    session.document.entities().map(entity_image).collect()
}

#[test]
fn dxf_without_objects_section_saves_and_reopens() {
    let input = encode(&fixture(DxfVersion::AC1032), "dxf").unwrap();
    let stripped = without_dxf_section(&input, "OBJECTS");
    assert!(!stripped.windows(7).any(|window| window == b"OBJECTS"));
    let mut session = CadSession::new(&stripped, "dxf").unwrap();
    let before = entity_images(&session);
    let output = session.save().expect("no-op save of a drawing without OBJECTS");
    let reopened = CadSession::new(&output, "dxf").unwrap();
    assert_eq!(before, entity_images(&reopened));
    edit_ok(&mut session, json!({"operation":"addStroke","points":[[0,0,0],[4,0,0],[4,4,0]],"color":3,"lineWeight":35}));
    let output = session.save().expect("stroke save of a drawing without OBJECTS");
    let reopened = read(&output, "dxf").unwrap();
    assert_eq!(reopened.entity_count(), session.document.entity_count());
    assert!(reopened.layers.get(ANNOTATION_LAYER).is_some());
}

#[test]
fn roundtrip_preserves_custom_styles_objects_and_layouts() {
    let mut document = fixture(DxfVersion::AC1032);
    let mut linetype = LineType::dashed();
    linetype.set_handle(document.allocate_handle());
    let linetype_handle = linetype.handle;
    document.line_types.add(linetype).unwrap();
    let mut text_style = TextStyle::new("FLOE_TXT");
    text_style.font_file = "MiSans-Regular.ttf".into();
    text_style.set_handle(document.allocate_handle());
    let text_style_handle = text_style.handle;
    document.text_styles.add(text_style).unwrap();
    for object in document.objects.values_mut() {
        match object {
            ObjectType::MultiLeaderStyle(style) => style.line_type_handle = Some(linetype_handle),
            ObjectType::TableStyle(style) => {
                style.set_all_text_styles("FLOE_TXT", Some(text_style_handle));
                style.set_all_text_heights(0.42);
            }
            ObjectType::Layout(layout) if layout.name == "Layout1" => {
                layout.paper_width = 420.0;
                layout.paper_height = 297.0;
            }
            _ => {}
        }
    }
    let mut session = CadSession { document, format: "dxf".into(), undo: vec![], redo: vec![], active_layer: "0".into() };
    let output = session.save().unwrap();
    let reopened = read(&output, "dxf").unwrap();
    let dashed = reopened.line_types.get("Dashed").expect("custom linetype preserved");
    assert!(!dashed.elements.is_empty());
    let custom = reopened.text_styles.get("FLOE_TXT").expect("custom text style preserved");
    assert_eq!(custom.font_file, "MiSans-Regular.ttf");
    let mleader = reopened
        .objects
        .values()
        .find_map(|object| match object {
            ObjectType::MultiLeaderStyle(style) => Some(style),
            _ => None,
        })
        .unwrap();
    let resolved = reopened
        .line_types
        .iter()
        .find(|entry| Some(entry.handle) == mleader.line_type_handle)
        .map(|entry| entry.name.as_str());
    assert_eq!(resolved, Some("Dashed"));
    let table = reopened
        .objects
        .values()
        .find_map(|object| match object {
            ObjectType::TableStyle(style) if style.name == "Standard" => Some(style),
            _ => None,
        })
        .unwrap();
    assert_eq!(table.data_row_style.text_style_name, "FLOE_TXT");
    assert!((table.data_row_style.text_height - 0.42).abs() < 1e-9);
    assert!(table.data_row_style.text_style_handle.is_none());
    let layout = reopened
        .objects
        .values()
        .find_map(|object| match object {
            ObjectType::Layout(layout) if layout.name == "Layout1" => Some(layout),
            _ => None,
        })
        .unwrap();
    assert_eq!(layout.paper_width, 420.0);
    assert_eq!(layout.paper_height, 297.0);
}

#[test]
fn roundtrip_gate_rejects_unpreserved_font_and_paper_units() {
    for font_case in [true, false] {
        let mut document = fixture(DxfVersion::AC1032);
        if font_case {
            let mut style = TextStyle::with_truetype("FLOE_LOSS", "MiSans-Regular.ttf");
            style.set_handle(document.allocate_handle());
            document.text_styles.add(style).unwrap();
        } else {
            let layout = document
                .objects
                .values_mut()
                .find_map(|object| match object {
                    ObjectType::Layout(layout) if layout.name == "Layout1" => Some(layout),
                    _ => None,
                })
                .unwrap();
            layout.plot_paper_units = 1;
        }
        let mut session = CadSession { document, format: "dxf".into(), undo: vec![], redo: vec![], active_layer: "0".into() };
        let before = auxiliary_image(&session.document);
        assert!(session.save().is_err());
        assert_eq!(before, auxiliary_image(&session.document));
    }
}

#[test]
fn roundtrip_gate_still_rejects_missing_objects() {
    let document = fixture(DxfVersion::AC1032);
    let mut reopened = read(&encode(&document, "dxf").unwrap(), "dxf").unwrap();
    verify(&document, &reopened).unwrap();
    let mut removed = 0;
    reopened.objects.retain(|_, object| {
        let keep = !matches!(object, ObjectType::MultiLeaderStyle(_));
        if !keep {
            removed += 1;
        }
        keep
    });
    assert_eq!(removed, 1);
    assert!(verify(&document, &reopened).is_err());
}

#[test]
fn add_stroke_undo_redo_in_dwg() {
    let mut session = session(DxfVersion::AC1032, "dwg");
    let base = session.document.entity_count();
    edit_ok(&mut session, json!({"operation":"addStroke","points":[[1,1,0],[9,1,0],[9,9,0]],"color":5,"lineWeight":70}));
    assert_eq!(session.document.entity_count(), base + 2);
    assert!(session.undo());
    assert_eq!(session.document.entity_count(), base);
    assert!(annotation_lines(&session).is_empty());
    assert!(session.redo());
    assert_eq!(session.document.entity_count(), base + 2);
    assert!(session.undo());
    assert_eq!(session.document.entity_count(), base);
    let output = session.save().unwrap();
    assert_eq!(&output[..6], b"AC1032");
}

#[test]
fn inspect_declares_add_stroke_capabilities() {
    let session = session(DxfVersion::AC1032, "dxf");
    let metadata: Value = serde_json::from_str(&session.inspect(0, 1).unwrap()).unwrap();
    let stroke = &metadata["capabilities"]["addStroke"];
    assert_eq!(metadata["capabilities"]["version"].as_u64(), Some(2));
    assert_eq!(stroke["pointCount"]["min"].as_u64(), Some(MIN_STROKE_POINTS as u64));
    assert_eq!(stroke["pointCount"]["max"].as_u64(), Some(MAX_STROKE_POINTS as u64));
    assert_eq!(stroke["layer"], ANNOTATION_LAYER);
    assert_eq!(stroke["color"]["min"].as_u64(), Some(1));
    assert_eq!(stroke["color"]["max"].as_u64(), Some(255));
    assert!(stroke["lineWeight"]["allowed"].as_array().unwrap().contains(&json!(25)));
    assert!(!stroke["lineWeight"]["allowed"].as_array().unwrap().contains(&json!(17)));
}

#[test]
fn diagnostics_and_corrupt_files_cannot_be_saved() {
    assert!(CadSession::new(b"not a DWG", "dwg").is_err());
    let mut doc = fixture(DxfVersion::AC1032);
    doc.notifications.notify(acadrust::notification::NotificationType::NotSupported, "unknown entity");
    let session = CadSession { document: doc, format: "dwg".into(), undo: vec![], redo: vec![], active_layer: "0".into() };
    assert!(session.save().is_err());
    let mut doc = fixture(DxfVersion::AC1032);
    doc.notifications
        .notify(acadrust::notification::NotificationType::Warning, "AC18: Invalid compressed size 0 for page 1");
    assert!(blocking_diagnostics(&doc));
}

#[test]
fn arc_and_polyline_create_save_reopen() {
    for format in ["dxf", "dwg"] {
        let mut session = session(DxfVersion::AC1032, format);
        let base = session.document.entity_count();
        edit_ok(&mut session, json!({"operation":"addArc","center":[0,0,0],"radius":10,"startAngle":0,"endAngle":1.5707963267948966,"layer":"0"}));
        edit_ok(&mut session, json!({"operation":"addLwPolyline","points":[[0,0],[20,0],[20,10],[0,10]],"closed":true,"layer":"Dimensions"}));
        assert_eq!(session.document.entity_count(), base + 2);
        let output = session.save().unwrap();
        let reopened = read(&output, format).unwrap();
        assert_eq!(reopened.entity_count(), base + 2);
        let arc = reopened.entities().find_map(|e| match e {
            EntityType::Arc(a) => Some(a),
            _ => None,
        });
        assert_eq!(arc.unwrap().radius, 10.0);
        let poly = reopened.entities().find_map(|e| match e {
            EntityType::LwPolyline(p) => Some(p),
            _ => None,
        });
        let poly = poly.unwrap();
        assert!(poly.is_closed);
        assert_eq!(poly.vertex_count(), 4);
    }
}

#[test]
fn copy_rotate_scale_mirror_are_exact_and_undoable() {
    let mut session = session(DxfVersion::AC1032, "dxf");
    let line = handle_of(&session, "Line");
    let result = edit_ok(&mut session, json!({"operation":"copy","handle":line,"delta":[0,100,0]}));
    let created = created_handles(&session, &result);
    assert_eq!(created.len(), 1);
    edit_ok(&mut session, json!({"operation":"rotate","handle":created[0],"center":[0,0,0],"angle":1.5707963267948966}));
    match session.document.get_entity(handle(&created[0]).unwrap()).unwrap() {
        EntityType::Line(e) => {
            assert!((e.start.x + 100.0).abs() < 1e-6 && (e.start.y - 0.0).abs() < 1e-6);
            assert!((e.end.x + 150.0).abs() < 1e-6 && (e.end.y - 100.0).abs() < 1e-6);
        }
        _ => panic!(),
    }
    let circle = handle_of(&session, "Circle");
    edit_ok(&mut session, json!({"operation":"scale","handle":circle,"center":[40,30,0],"factor":2.0}));
    match session.document.get_entity(handle(&circle).unwrap()).unwrap() {
        EntityType::Circle(e) => assert!((e.radius - 24.0).abs() < 1e-9),
        _ => panic!(),
    }
    edit_ok(&mut session, json!({"operation":"mirror","handle":line,"axis":[[0,0,0],[0,10,0]]}));
    match session.document.get_entity(handle(&line).unwrap()).unwrap() {
        EntityType::Line(e) => {
            assert!((e.start.x - 0.0).abs() < 1e-9);
            assert!((e.end.x + 100.0).abs() < 1e-9);
        }
        _ => panic!(),
    }
    let before = entity_images(&session);
    edit_ok(&mut session, json!({"operation":"rotate","handle":circle,"center":[0,0,0],"angle":0.5}));
    assert!(session.undo());
    assert_eq!(before, entity_images(&session));
}

#[test]
fn locked_layer_blocks_modify_and_delete() {
    let mut session = session(DxfVersion::AC1032, "dxf");
    let line = handle_of(&session, "Line");
    edit_ok(&mut session, json!({"operation":"addLayer","name":"LockedWork","color":3,"lineType":"Continuous","lineWeight":25}));
    edit_ok(&mut session, json!({"operation":"setLayer","handle":line,"layer":"LockedWork"}));
    edit_ok(&mut session, json!({"operation":"updateLayer","name":"LockedWork","locked":true}));
    let before = session.inspect(0, 500).unwrap();
    let history = session.undo.len();
    assert!(session.edit(&json!({"operation":"move","handle":line,"delta":[1,0,0]}).to_string()).is_err());
    assert!(session.edit(&json!({"operation":"delete","handle":line}).to_string()).is_err());
    assert_eq!(before, session.inspect(0, 500).unwrap());
    assert_eq!(session.undo.len(), history, "failed edits must not add history");
}

#[test]
fn layer_create_rename_delete_rules() {
    let mut session = session(DxfVersion::AC1032, "dxf");
    edit_ok(&mut session, json!({"operation":"addLayer","name":"Walls","color":1,"lineType":"Continuous","lineWeight":50}));
    edit_ok(&mut session, json!({"operation":"renameLayer","from":"Walls","to":"Walls-2"}));
    let line = handle_of(&session, "Line");
    edit_ok(&mut session, json!({"operation":"setLayer","handle":line,"layer":"Walls-2"}));
    let layers: Value = serde_json::from_str(&session.query(r#"{"operation":"layers"}"#).unwrap()).unwrap();
    let layer = layers["layers"].as_array().unwrap().iter().find(|l| l["name"] == "Walls-2").cloned().unwrap();
    assert_eq!(layer["color"], "1");
    assert_eq!(layer["entityCount"].as_u64(), Some(1));
    // Referenced layer cannot be deleted.
    assert!(session.edit(r#"{"operation":"deleteLayer","name":"Walls-2"}"#).is_err());
    // Duplicate names are rejected; layer 0 cannot be renamed or deleted.
    assert!(session.edit(r#"{"operation":"addLayer","name":"Walls-2","color":2}"#).is_err());
    assert!(session.edit(r#"{"operation":"renameLayer","from":"0","to":"Zero"}"#).is_err());
    assert!(session.edit(r#"{"operation":"deleteLayer","name":"0"}"#).is_err());
    // Unknown linetypes are rejected rather than silently substituted.
    assert!(session.edit(r#"{"operation":"addLayer","name":"Dash","lineType":"Nope"}"#).is_err());
    // Rename updates entity references.
    let rows: Value = serde_json::from_str(&session.query(r#"{"operation":"entities","type":"Line"}"#).unwrap()).unwrap();
    assert_eq!(rows["entities"][0]["layer"], "Walls-2");
    // Unassign, then deletion succeeds.
    edit_ok(&mut session, json!({"operation":"setLayer","handle":line,"layer":"0"}));
    edit_ok(&mut session, json!({"operation":"deleteLayer","name":"Walls-2"}));
    let layers: Value = serde_json::from_str(&session.query(r#"{"operation":"layers"}"#).unwrap()).unwrap();
    assert!(layers["layers"].as_array().unwrap().iter().all(|l| l["name"] != "Walls-2"));
}

#[test]
fn trim_and_extend_lines() {
    let mut session = session(DxfVersion::AC1032, "dxf");
    edit_ok(&mut session, json!({"operation":"addLine","start":[0,0,0],"end":[100,0,0],"layer":"0"}));
    edit_ok(&mut session, json!({"operation":"addLine","start":[50,-10,0],"end":[50,10,0],"layer":"0"}));
    let rows: Value = serde_json::from_str(&session.query(r#"{"operation":"entities","type":"Line"}"#).unwrap()).unwrap();
    let cells = rows["entities"].as_array().unwrap();
    let horizontal = cells.iter().find(|r| r["image"]["Line"]["end"]["y"] == 0.0 && r["image"]["Line"]["end"]["x"] == 100.0).unwrap()["handle"].as_str().unwrap().to_string();
    let vertical = cells.iter().find(|r| r["image"]["Line"]["start"]["y"] == -10.0).unwrap()["handle"].as_str().unwrap().to_string();
    // Pick the left half: the start segment is removed, leaving [50,100].
    edit_ok(&mut session, json!({"operation":"trim","handle":horizontal,"boundary":vertical,"pick":[10,0,0]}));
    match session.document.get_entity(handle(&horizontal).unwrap()).unwrap() {
        EntityType::Line(e) => {
            assert!((e.start.x - 50.0).abs() < 1e-9);
            assert!((e.end.x - 100.0).abs() < 1e-9);
        }
        _ => panic!(),
    }
    // Picking inside the remaining line would remove the entire entity, which
    // is rejected instead of leaving a zero-length line.
    let before = entity_images(&session);
    assert!(session
        .edit(&json!({"operation":"trim","handle":horizontal,"boundary":vertical,"pick":[75,0,0]}).to_string())
        .is_err());
    assert_eq!(before, entity_images(&session));
    // Extend a short line out to the vertical boundary.
    edit_ok(&mut session, json!({"operation":"addLine","start":[0,20,0],"end":[20,20,0],"layer":"0"}));
    let rows: Value = serde_json::from_str(&session.query(r#"{"operation":"entities","type":"Line"}"#).unwrap()).unwrap();
    let short = rows["entities"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["image"]["Line"]["start"]["y"] == 20.0)
        .unwrap()["handle"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(session.edit(&json!({"operation":"extend","handle":short,"boundary":vertical,"pick":[19,20,0]}).to_string()).is_err());
    // A diagonal boundary crosses y=20 at x=-15; extend the left endpoint to it.
    edit_ok(&mut session, json!({"operation":"addLine","start":[-40,30,0],"end":[0,10,0],"layer":"0"}));
    let rows: Value = serde_json::from_str(&session.query(r#"{"operation":"entities","type":"Line"}"#).unwrap()).unwrap();
    let diagonal = rows["entities"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["image"]["Line"]["start"]["y"] == 30.0)
        .unwrap()["handle"]
        .as_str()
        .unwrap()
        .to_string();
    edit_ok(&mut session, json!({"operation":"extend","handle":short,"boundary":diagonal,"pick":[1,20,0]}));
    match session.document.get_entity(handle(&short).unwrap()).unwrap() {
        EntityType::Line(e) => {
            assert!((e.start.x + 20.0).abs() < 1e-9, "{:?}", e.start);
            assert!((e.start.y - 20.0).abs() < 1e-9);
            assert!((e.end.x - 20.0).abs() < 1e-9);
        }
        _ => panic!(),
    }
}

#[test]
fn trim_arc_and_reject_bulge_polyline() {
    let mut session = session(DxfVersion::AC1032, "dxf");
    edit_ok(&mut session, json!({"operation":"addArc","center":[0,0,0],"radius":10,"startAngle":0,"endAngle":3.141592653589793,"layer":"0"}));
    edit_ok(&mut session, json!({"operation":"addLine","start":[0,-5,0],"end":[0,15,0],"layer":"0"}));
    let arc = handle_of(&session, "Arc");
    let line = session
        .document
        .entities()
        .find_map(|e| match e {
            EntityType::Line(l) if l.start.x.abs() < 1e-9 && l.end.x.abs() < 1e-9 && (l.start.y + 5.0).abs() < 1e-9 => {
                Some(format!("{:X}", l.common.handle))
            }
            _ => None,
        })
        .unwrap();
    // Pick the left half of the upper semicircle: the start segment is removed.
    edit_ok(&mut session, json!({"operation":"trim","handle":arc,"boundary":line,"pick":[-9,2,0]}));
    match session.document.get_entity(handle(&arc).unwrap()).unwrap() {
        EntityType::Arc(e) => {
            assert!(e.start_angle.abs() < 1e-6);
            assert!((e.end_angle - 1.5707963267948966).abs() < 1e-6);
        }
        _ => panic!(),
    }
    // Bulge polylines are refused for trim boundaries.
    edit_ok(&mut session, json!({"operation":"addLwPolyline","points":[[0,100],[10,100]],"closed":false,"layer":"0"}));
    let poly = session
        .document
        .entities()
        .find_map(|e| match e {
            EntityType::LwPolyline(p) => Some(format!("{:X}", p.common.handle)),
            _ => None,
        })
        .unwrap();
    assert!(session.edit(&json!({"operation":"offset","handle":poly,"distance":1,"side":[5,101,0]}).to_string()).is_ok());
    assert!(session
        .edit(&json!({"operation":"trim","handle":line,"boundary":poly,"pick":[0,-2,0]}).to_string())
        .is_err());
}

#[test]
fn offset_line_circle_arc_and_polyline() {
    let mut session = session(DxfVersion::AC1032, "dxf");
    let line = handle_of(&session, "Line");
    let result = edit_ok(&mut session, json!({"operation":"offset","handle":line,"distance":5,"side":[0,10,0]}));
    let created = created_handles(&session, &result);
    assert_eq!(created.len(), 1);
    match session.document.get_entity(handle(&created[0]).unwrap()).unwrap() {
        EntityType::Line(e) => {
            let n = geometry::P::new(5.0 * -50.0 / 111.80339887498948, 5.0 * 100.0 / 111.80339887498948);
            assert!((e.start.x - n.x).abs() < 1e-9 && (e.start.y - n.y).abs() < 1e-9);
            assert!((e.end.x - (100.0 + n.x)).abs() < 1e-9 && (e.end.y - (50.0 + n.y)).abs() < 1e-9);
        }
        _ => panic!(),
    }
    let circle = handle_of(&session, "Circle");
    let result = edit_ok(&mut session, json!({"operation":"offset","handle":circle,"distance":3,"side":[100,30,0]}));
    let created = created_handles(&session, &result);
    match session.document.get_entity(handle(&created[0]).unwrap()).unwrap() {
        EntityType::Circle(e) => assert!((e.radius - 15.0).abs() < 1e-9),
        _ => panic!(),
    }
    edit_ok(&mut session, json!({"operation":"addLwPolyline","points":[[0,0],[10,0],[10,10]],"closed":false,"layer":"0"}));
    let poly = session
        .document
        .entities()
        .find_map(|e| match e {
            EntityType::LwPolyline(p) => Some(format!("{:X}", p.common.handle)),
            _ => None,
        })
        .unwrap();
    let result = edit_ok(&mut session, json!({"operation":"offset","handle":poly,"distance":1,"side":[5,5,0]}));
    let created = created_handles(&session, &result);
    match session.document.get_entity(handle(&created[0]).unwrap()).unwrap() {
        EntityType::LwPolyline(e) => {
            assert_eq!(e.vertex_count(), 3);
            assert!((e.vertices[0].location.y - 1.0).abs() < 1e-9);
            assert!((e.vertices[1].location.x - 9.0).abs() < 1e-9);
        }
        _ => panic!(),
    }
}

#[test]
fn dimensions_and_leader_roundtrip_in_dwg() {
    let mut session = session(DxfVersion::AC1032, "dwg");
    let base = session.document.entity_count();
    edit_ok(&mut session, json!({"operation":"addDimension","kind":"linear","points":[[0,0,0],[10,0,0]],"layer":"Dimensions","offset":5}));
    edit_ok(&mut session, json!({"operation":"addDimension","kind":"aligned","points":[[0,0,0],[8,6,0]],"layer":"Dimensions","offset":3}));
    edit_ok(&mut session, json!({"operation":"addDimension","kind":"angular","points":[[0,0,0],[10,0,0],[0,10,0]],"layer":"Dimensions"}));
    edit_ok(&mut session, json!({"operation":"addDimension","kind":"radius","points":[[40,30,0],[52,30,0]],"layer":"Dimensions"}));
    edit_ok(&mut session, json!({"operation":"addDimension","kind":"diameter","points":[[28,30,0],[52,30,0]],"layer":"Dimensions"}));
    edit_ok(&mut session, json!({"operation":"addLeader","points":[[60,60,0],[70,70,0],[80,70,0]],"layer":"Dimensions"}));
    assert_eq!(session.document.entity_count(), base + 6);
    let before: Vec<Value> = entity_images(&session);
    let output = session.save().unwrap();
    let reopened = read(&output, "dwg").unwrap();
    let after: Vec<Value> = reopened.entities().map(entity_image).collect();
    assert_eq!(before.len(), after.len());
    assert_eq!(before, after, "dimension/leader entities must round-trip byte-identically");
    // Measurements survive as native values.
    let measurements: Vec<f64> = reopened
        .entities()
        .filter_map(|e| match e {
            EntityType::Dimension(d) => Some(d.measurement()),
            _ => None,
        })
        .collect();
    assert!(measurements.iter().any(|m| (m - 10.0).abs() < 1e-9), "{measurements:?}");
    assert!(measurements.iter().any(|m| (m - 10.0).abs() < 1e-9));
    assert!(measurements.iter().any(|m| (m - 90.0).abs() < 1e-9), "{measurements:?}");
    assert!(measurements.iter().any(|m| (m - 12.0).abs() < 1e-9), "{measurements:?}");
}

#[test]
fn dimension_rejects_bad_arity_and_kinds() {
    let mut session = session(DxfVersion::AC1032, "dxf");
    let before = session.inspect(0, 500).unwrap();
    assert!(session
        .edit(r#"{"operation":"addDimension","kind":"linear","points":[[0,0,0]],"layer":"0"}"#)
        .is_err());
    assert!(session
        .edit(r#"{"operation":"addDimension","kind":"nope","points":[[0,0,0],[1,0,0]],"layer":"0"}"#)
        .is_err());
    assert_eq!(before, session.inspect(0, 500).unwrap());
    assert!(!session.undo());
}

#[test]
fn batch_is_atomic_with_one_history_entry() {
    let mut session = session(DxfVersion::AC1032, "dxf");
    let base = session.document.entity_count();
    let result = edit_ok(
        &mut session,
        json!({"operation":"batch","operations":[
            {"operation":"addLine","start":[0,0,0],"end":[5,0,0],"layer":"0"},
            {"operation":"addCircle","center":[0,0,0],"radius":2,"layer":"0"},
            {"operation":"addArc","center":[0,0,0],"radius":4,"startAngle":0,"endAngle":1,"layer":"0"}
        ]}),
    );
    let created = created_handles(&session, &result);
    assert_eq!(created.len(), 3);
    assert_eq!(session.document.entity_count(), base + 3);
    assert!(session.undo());
    assert_eq!(session.document.entity_count(), base);
    assert!(session.redo());
    let before = session.inspect(0, 500).unwrap();
    // A failing operation anywhere rejects the whole batch.
    assert!(session
        .edit(&json!({"operation":"batch","operations":[
            {"operation":"addLine","start":[0,0,0],"end":[1,0,0],"layer":"0"},
            {"operation":"addCircle","center":[0,0,0],"radius":-3,"layer":"0"}
        ]}).to_string())
        .is_err());
    assert_eq!(before, session.inspect(0, 500).unwrap());
    // Nested batch and stroke in batch are rejected.
    assert!(session
        .edit(&json!({"operation":"batch","operations":[{"operation":"batch","operations":[]}]}).to_string())
        .is_err());
    assert!(session
        .edit(&json!({"operation":"batch","operations":[{"operation":"addStroke","points":[[0,0,0],[1,0,0]]}]}).to_string())
        .is_err());
}

#[test]
fn snap_query_finds_endpoint_midpoint_center_intersection() {
    let mut session = session(DxfVersion::AC1032, "dxf");
    edit_ok(&mut session, json!({"operation":"addLine","start":[0,0,0],"end":[10,0,0],"layer":"0"}));
    edit_ok(&mut session, json!({"operation":"addLine","start":[5,-5,0],"end":[5,5,0],"layer":"0"}));
    let result: Value = serde_json::from_str(
        &session
            .query(r#"{"operation":"snap","point":[5,0,0],"tolerance":0.5}"#)
            .unwrap(),
    )
    .unwrap();
    let kinds: Vec<String> = result["candidates"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["kind"].as_str().unwrap().to_string())
        .collect();
    assert!(kinds.contains(&"intersection".to_string()), "{kinds:?}");
    assert!(kinds.contains(&"midpoint".to_string()), "{kinds:?}");
    let center: Value = serde_json::from_str(
        &session
            .query(r#"{"operation":"snap","point":[40,30,0],"tolerance":0.5,"kinds":["center"]}"#)
            .unwrap(),
    )
    .unwrap();
    let candidates = center["candidates"].as_array().unwrap();
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0]["kind"], "center");
    assert_eq!(candidates[0]["handle"], handle_of(&session, "Circle"));
}

#[test]
fn measure_query_kinds() {
    let session = session(DxfVersion::AC1032, "dxf");
    let distance: Value = serde_json::from_str(
        &session
            .query(r#"{"operation":"measure","kind":"distance","points":[[0,0,0],[3,4,0]]}"#)
            .unwrap(),
    )
    .unwrap();
    assert!((distance["value"].as_f64().unwrap() - 5.0).abs() < 1e-9);
    let angle: Value = serde_json::from_str(
        &session
            .query(r#"{"operation":"measure","kind":"angle","points":[[0,0,0],[1,0,0],[0,1,0]]}"#)
            .unwrap(),
    )
    .unwrap();
    assert!((angle["value"].as_f64().unwrap() - 90.0).abs() < 1e-9);
    let circle = handle_of(&session, "Circle");
    let radius: Value = serde_json::from_str(
        &session
            .query(&json!({"operation":"measure","kind":"radius","handles":[circle]}).to_string())
            .unwrap(),
    )
    .unwrap();
    assert!((radius["value"].as_f64().unwrap() - 12.0).abs() < 1e-9);
    let line = handle_of(&session, "Line");
    let perimeter: Value = serde_json::from_str(
        &session
            .query(&json!({"operation":"measure","kind":"perimeter","handles":[line]}).to_string())
            .unwrap(),
    )
    .unwrap();
    assert!((perimeter["value"].as_f64().unwrap() - 111.80339887498948).abs() < 1e-6);
    // Unknown handle is a structured error, not a panic.
    assert!(session.query(r#"{"operation":"measure","kind":"radius","handles":["FFFFFFFFFFFF"]}"#).is_err());
}

#[test]
fn check_query_reports_zero_length_duplicates_and_layers() {
    let mut session = session(DxfVersion::AC1032, "dxf");
    edit_ok(&mut session, json!({"operation":"addLine","start":[0,0,0],"end":[0,0,0],"layer":"0"}));
    edit_ok(&mut session, json!({"operation":"addLine","start":[10,10,0],"end":[20,20,0],"layer":"0"}));
    edit_ok(&mut session, json!({"operation":"addLine","start":[20,20,0],"end":[10,10,0],"layer":"0"}));
    edit_ok(&mut session, json!({"operation":"addLwPolyline","points":[[0,0],[5,0],[5,5]],"closed":false,"layer":"0"}));
    let result: Value = serde_json::from_str(&session.query(r#"{"operation":"check","tolerance":0.001}"#).unwrap()).unwrap();
    assert!(!result["zeroLength"].as_array().unwrap().is_empty());
    assert!(!result["duplicates"].as_array().unwrap().is_empty());
    assert!(!result["openContours"].as_array().unwrap().is_empty());
    assert_eq!(result["layerUsage"]["0"].as_u64(), Some(7));
    assert_eq!(result["pairwiseChecks"], true);
}

#[test]
fn locate_and_text_query_are_read_only() {
    let session = session(DxfVersion::AC1032, "dxf");
    let text = handle_of(&session, "Text");
    let located: Value = serde_json::from_str(
        &session
            .query(&json!({"operation":"locate","handle":text}).to_string())
            .unwrap(),
    )
    .unwrap();
    assert_eq!(located["type"], "Text");
    assert!(located["point"].as_array().is_some());
    let texts: Value = serde_json::from_str(&session.query(r#"{"operation":"text","text":"尺寸"}"#).unwrap()).unwrap();
    assert_eq!(texts["entities"].as_array().unwrap().len(), 1);
    let before = session.inspect(0, 500).unwrap();
    let _ = session.query(r#"{"operation":"unknown"}"#).unwrap_err();
    assert_eq!(before, session.inspect(0, 500).unwrap());
}

#[test]
fn planar_gate_rejects_sloped_lines_and_mixed_elevations() {
    let mut document = fixture(DxfVersion::AC1032);
    let sloped = document.add_entity(EntityType::Line(Line::from_coords(0., 0., 0., 50., 0., 10.))).unwrap();
    let mut session = CadSession { document, format: "dxf".into(), undo: vec![], redo: vec![], active_layer: "0".into() };
    let before = entity_images(&session);
    let sloped_id = format!("{sloped:X}");
    for request in [
        json!({"operation":"rotate","handle":sloped_id,"center":[0,0,0],"angle":0.5}),
        json!({"operation":"scale","handle":sloped_id,"center":[0,0,0],"factor":2}),
        json!({"operation":"mirror","handle":sloped_id,"axis":[[0,0,0],[0,10,0]]}),
        json!({"operation":"offset","handle":sloped_id,"distance":1,"side":[0,1,0]}),
        json!({"operation":"trim","handle":sloped_id,"boundary":sloped_id,"pick":[10,0,0]}),
        json!({"operation":"extend","handle":sloped_id,"boundary":sloped_id,"pick":[10,0,0]}),
    ] {
        assert!(session.edit(&request.to_string()).is_err(), "{request}");
    }
    assert_eq!(before, entity_images(&session));
    assert!(session.undo.is_empty(), "rejected planar edits must not add history");
    // Translation is exact and stays allowed for a sloped member.
    assert!(session.edit(&json!({"operation":"move","handle":sloped_id,"delta":[1,2,3]}).to_string()).is_ok());

    // Crossing lines at different elevations must never be trimmed/projected.
    let mut document = fixture(DxfVersion::AC1032);
    let ground = document.add_entity(EntityType::Line(Line::from_coords(-10., 0., 0., 10., 0., 0.))).unwrap();
    let raised = document.add_entity(EntityType::Line(Line::from_coords(0., -10., 5., 0., 10., 5.))).unwrap();
    let mut session = CadSession { document, format: "dxf".into(), undo: vec![], redo: vec![], active_layer: "0".into() };
    let before = entity_images(&session);
    assert!(session
        .edit(&json!({"operation":"trim","handle":format!("{ground:X}"),"boundary":format!("{raised:X}"),"pick":[5,0,0]}).to_string())
        .is_err());
    assert!(session
        .edit(&json!({"operation":"extend","handle":format!("{ground:X}"),"boundary":format!("{raised:X}"),"pick":[5,0,0]}).to_string())
        .is_err());
    assert_eq!(before, entity_images(&session));
    assert!(session.undo.is_empty());
    // Creation on a non-zero plane is rejected, not silently flattened.
    assert!(session
        .edit(r#"{"operation":"addLine","start":[0,0,5],"end":[10,0,5],"layer":"0"}"#)
        .is_err());
}

#[test]
fn model_space_and_ocs_eligibility_is_enforced() {
    let mut document = fixture(DxfVersion::AC1032);
    let circle = document
        .entities()
        .find_map(|e| match e {
            EntityType::Circle(c) => Some(c.common.handle),
            _ => None,
        })
        .unwrap();
    if let Some(entity) = document.get_entity_mut(circle) {
        entity.common_mut().entity_mode = Some(1);
    }
    let mut session = CadSession { document, format: "dxf".into(), undo: vec![], redo: vec![], active_layer: "0".into() };
    let before = entity_images(&session);
    for request in [
        json!({"operation":"delete","handle":format!("{circle:X}")}),
        json!({"operation":"move","handle":format!("{circle:X}"),"delta":[1,0,0]}),
        json!({"operation":"setRadius","handle":format!("{circle:X}"),"radius":3}),
        json!({"operation":"setLayer","handle":format!("{circle:X}"),"layer":"Dimensions"}),
        json!({"operation":"setColor","handle":format!("{circle:X}"),"color":2}),
        json!({"operation":"copy","handle":format!("{circle:X}"),"delta":[5,0,0]}),
        json!({"operation":"offset","handle":format!("{circle:X}"),"distance":1,"side":[100,30,0]}),
    ] {
        assert!(session.edit(&request.to_string()).is_err(), "paper space must stay read-only: {request}");
    }
    assert_eq!(before, entity_images(&session));
    assert!(session.undo.is_empty());
}

#[test]
fn locked_source_blocks_copy_and_offset() {
    let mut document = fixture(DxfVersion::AC1032);
    document.layers.get_mut("0").unwrap().lock();
    let line = document.entities().find_map(|e| match e {
        EntityType::Line(l) => Some(l.common.handle),
        _ => None,
    }).unwrap();
    let mut session = CadSession { document, format: "dxf".into(), undo: vec![], redo: vec![], active_layer: "0".into() };
    let before = entity_images(&session);
    assert!(session.edit(&json!({"operation":"copy","handle":format!("{line:X}"),"delta":[0,5,0]}).to_string()).is_err());
    assert!(session.edit(&json!({"operation":"offset","handle":format!("{line:X}"),"distance":1,"side":[0,5,0]}).to_string()).is_err());
    assert_eq!(before, entity_images(&session));
    assert!(session.undo.is_empty());
}

#[test]
fn rejected_batch_leaves_document_and_history_unchanged() {
    let mut document = fixture(DxfVersion::AC1032);
    let sloped = document.add_entity(EntityType::Line(Line::from_coords(0., 0., 0., 10., 0., 5.))).unwrap();
    let mut session = CadSession { document, format: "dxf".into(), undo: vec![], redo: vec![], active_layer: "0".into() };
    let before = entity_images(&session);
    assert!(session
        .edit(&json!({"operation":"batch","operations":[
            {"operation":"addLine","start":[0,0,0],"end":[1,0,0],"layer":"0"},
            {"operation":"rotate","handle":format!("{sloped:X}"),"center":[0,0,0],"angle":0.5}
        ]}).to_string())
        .is_err());
    assert_eq!(before, entity_images(&session));
    assert!(session.undo.is_empty());
}

#[test]
fn non_planar_entities_refuse_planar_edits() {
    let mut document = fixture(DxfVersion::AC1032);
    let mut circle = Circle::from_coords(0., 0., 0., 5.);
    circle.normal = Vector3::new(1.0, 0.0, 0.0);
    let handle = document.add_entity(EntityType::Circle(circle)).unwrap();
    let mut session = CadSession { document, format: "dxf".into(), undo: vec![], redo: vec![], active_layer: "0".into() };
    let before = session.inspect(0, 500).unwrap();
    assert!(session
        .edit(&json!({"operation":"rotate","handle":format!("{handle:X}"),"center":[0,0,0],"angle":0.1}).to_string())
        .is_err());
    assert!(session
        .edit(&json!({"operation":"trim","handle":format!("{handle:X}"),"boundary":format!("{handle:X}"),"pick":[1,0,0]}).to_string())
        .is_err());
    assert_eq!(before, session.inspect(0, 500).unwrap());
    assert!(!session.undo());
}

#[test]
fn active_layer_is_session_state_not_file_state() {
    let mut session = session(DxfVersion::AC1032, "dxf");
    session.set_active_layer("Dimensions").unwrap();
    assert!(session.set_active_layer("Missing").is_err());
    let drawing: Value = serde_json::from_str(&session.query(r#"{"operation":"drawing"}"#).unwrap()).unwrap();
    assert_eq!(drawing["activeLayer"], "Dimensions");
    assert_eq!(drawing["unit"], "unitless drawing units");
    let output = session.save().unwrap();
    let reopened = CadSession::new(&output, "dxf").unwrap();
    let drawing: Value = serde_json::from_str(&reopened.query(r#"{"operation":"drawing"}"#).unwrap()).unwrap();
    assert_eq!(drawing["activeLayer"], "0", "active layer must not persist into the drawing");
}

