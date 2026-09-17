// SPDX-License-Identifier: MPL-2.0
//! Local CAD document engine. Run in a terminable Web Worker, never on the UI thread.
//! Original DWG documents stay native; DXF projection is only for display.
//!
//! Source: `FloeAgent/ThirdParty/CADEngine/src/lib.rs` (Floe-owned MPL-2.0 binding
//! over acadrust 0.5.5). CAD formats: DWG is read and written natively; DXF is
//! read and projected for display and shares the same save round-trip guard.
//! Coordinate units: values are unitless drawing units; pencil strokes use the
//! drawing's own world coordinates `[x, y, z]` with Z preserved.
use acadrust::{CadDocument, Circle, Color, DwgReader, DwgWriter, DxfReader, DxfWriter,
              EntityType, Handle, Layer, Line, LineWeight, Text, Vector3};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::Cursor;
use wasm_bindgen::prelude::*;

const MAX_BYTES: usize = 10 * 1024 * 1024;
const MAX_ENTITIES: usize = 20_000;
const HISTORY: usize = 8;

/// Dedicated layer for Floe pencil/ink annotations. Kept separate from drawing
/// geometry so a stroke set can be hidden or removed without touching the
/// original entities. Created on demand by the atomic stroke operation.
const ANNOTATION_LAYER: &str = "FLOE_ANNOTATION";
const MIN_STROKE_POINTS: usize = 2;
const MAX_STROKE_POINTS: usize = 256;
/// Canonical line weights (1/100 mm) that acadrust 0.5.5 round-trips through the
/// DWG 5-bit table index (`types/line_weight.rs::INDEXED_VALUES`). DWG maps any
/// other value to `Default`, so unsupported widths are rejected rather than
/// advertised and silently lost. DXF code 370 carries the raw value.
const INDEXED_LINE_WEIGHTS: [i16; 24] = [
    0, 5, 9, 13, 15, 18, 20, 25, 30, 35, 40, 50, 53, 60, 70, 80, 90, 100, 106, 120, 140, 158, 200,
    211,
];

fn read(bytes: &[u8], format: &str) -> Result<CadDocument, String> {
    if bytes.is_empty() || bytes.len() > MAX_BYTES { return Err("CAD file size limit".into()); }
    let document = match format {
        "dxf" => DxfReader::from_reader(Cursor::new(bytes.to_vec()))
            .and_then(|reader| reader.read()),
        "dwg" => DwgReader::from_stream(Cursor::new(bytes)).read(),
        _ => return Err("Expected DXF or DWG".into()),
    }.map_err(|e| e.to_string())?;
    if document.entity_count() > MAX_ENTITIES { return Err("CAD entity limit".into()); }
    Ok(document)
}

fn encode(document: &CadDocument, format: &str) -> Result<Vec<u8>, String> {
    let bytes = match format {
        "dwg" => DwgWriter::write_to_vec(document),
        "dxf" => DxfWriter::new(document).write_to_vec(),
        _ => return Err("Expected DXF or DWG".into()),
    }.map_err(|e| e.to_string())?;
    if bytes.len() > MAX_BYTES { return Err("CAD output size limit".into()); }
    Ok(bytes)
}

fn diagnostics(document: &CadDocument) -> Vec<String> {
    document.notifications.iter().map(ToString::to_string).collect()
}

/// Versioned, exact description of the typed edit surface. Callers must gate
/// UI controls on these fields instead of assuming capabilities: only the
/// fields below are actually saved by this engine.
fn capabilities() -> Value {
    json!({
        "version": 1,
        "coordinateUnits": "unitless drawing units; stroke points are world coordinates [x,y,z] with Z preserved",
        "addStroke": {
            "pointCount": { "min": MIN_STROKE_POINTS, "max": MAX_STROKE_POINTS },
            "coordinateBounds": "finite, abs(value) <= 1e12",
            "segments": "points - 1 LINE entities",
            "layer": ANNOTATION_LAYER,
            "layerPolicy": "created on demand; whole stroke rejected when the layer is locked",
            "color": { "field": "color", "type": "ACI index", "min": 1, "max": 255, "default": "ByLayer" },
            "lineWeight": { "field": "lineWeight", "unit": "1/100 mm", "allowed": INDEXED_LINE_WEIGHTS.to_vec(), "default": "ByLayer" },
            "atomicity": "all segments applied or none",
            "history": "one undo/redo snapshot per stroke"
        }
    })
}

fn blocking_diagnostics(document: &CadDocument) -> bool {
    use acadrust::notification::NotificationType;
    document.notifications.omitted_count() > 0 || document.notifications.iter().any(|n| {
        // acadrust 0.5.5 uses Warning for these four successful header/map
        // progress reports (dwg_reader.rs:1258,1550,1630,1745). Preserve them in
        // inspection, but do not mistake them for lost/unsupported content.
        let informational = n.notification_type == NotificationType::Warning && (
            n.message.starts_with("Reading DWG file version: AC")
            || n.message.starts_with("AC18 inner header: page_map_address=")
            || (n.message.starts_with("AC18: Read ") && (
                n.message.ends_with(" page records from page map")
                || n.message.ends_with(" section descriptors from section map"))));
        !informational
    })
}

// Serde excludes some native references. Compare the complete entity value as
// well as the preserved reference fields; only ownership synthesized for newly
// inserted entities is permitted to change during writing.
fn entity_image(entity: &EntityType) -> Value {
    let mut value = serde_json::to_value(entity).expect("entity serialization");
    if let Some(body) = value.as_object_mut().and_then(|m| m.values_mut().next()) {
        if let Some(common) = body.get_mut("common").and_then(Value::as_object_mut) {
            common.remove("owner_handle");
        }
    }
    value
}

fn equivalent(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(a), Value::Number(b)) => {
            if let (Some(a), Some(b)) = (a.as_f64(), b.as_f64()) {
                (a - b).abs() <= 1e-9 * a.abs().max(b.abs()).max(1.0)
            } else { a == b }
        }
        (Value::Array(a), Value::Array(b)) => a.len() == b.len() && a.iter().zip(b).all(|(a,b)| equivalent(a,b)),
        (Value::Object(a), Value::Object(b)) => a.len() == b.len() && a.iter().all(|(key,a)| b.get(key).is_some_and(|b| equivalent(a,b))),
        _ => a == b,
    }
}

fn verify(document: &CadDocument, reopened: &CadDocument) -> Result<(), String> {
    if document.version != reopened.version || document.entity_count() != reopened.entity_count() {
        return Err("CAD round-trip changed version or entity count; original preserved".into());
    }
    if blocking_diagnostics(reopened) {
        return Err(format!("CAD round-trip diagnostics: {:?}", diagnostics(reopened)));
    }
    for entity in document.entities() {
        let handle = entity.common().handle;
        let other = reopened.get_entity(handle).ok_or("CAD round-trip lost an entity")?;
        if !equivalent(&entity_image(entity), &entity_image(other)) {
            #[cfg(test)] eprintln!("Entity before: {}\nEntity after: {}", entity_image(entity), entity_image(other));
            return Err(format!("CAD round-trip changed entity {handle}; original preserved"));
        }
        let a = entity.common();
        let b = other.common();
        if a.graphic_data != b.graphic_data || a.material_handle != b.material_handle
            || a.color_book_handle != b.color_book_handle || a.face_visual_style_handle != b.face_visual_style_handle
            || a.edge_visual_style_handle != b.edge_visual_style_handle {
            return Err(format!("CAD round-trip changed references for {handle}"));
        }
    }
    // Table entries are compared by semantic values, excluding allocated handles.
    let mut before = serde_json::to_value(&document.layers).map_err(|e| e.to_string())?;
    let mut after = serde_json::to_value(&reopened.layers).map_err(|e| e.to_string())?;
    strip_table_handles(&mut before); strip_table_handles(&mut after);
    if !equivalent(&before, &after) { return Err("CAD round-trip changed layers".into()); }
    // Preserve nongraphical content too: annotations may rely on styles,
    // named dictionaries, layouts, reactors and custom application data.
    // Reference handles inside objects are compared by resolved table name
    // where the acadrust 0.5.5 writer demonstrably persists only a name or
    // substitutes a documented default (see `normalize_auxiliary`).
    let before = auxiliary_image(document);
    let after = auxiliary_image(reopened);
    if !equivalent(&before, &after) {
        #[cfg(test)] eprintln!("Auxiliary before: {}\nAuxiliary after: {}", before, after);
        return Err("CAD round-trip changed styles, objects or layout data; original preserved".into());
    }
    Ok(())
}

/// Versioned, exact image of the non-graphical content used by the round-trip
/// gate. Builds the same semantic JSON for both documents, then applies the
/// narrowly justified reference normalizations.
fn auxiliary_image(document: &CadDocument) -> Value {
    let mut value = json!({"objects":document.objects,"lineTypes":document.line_types,
        "textStyles":document.text_styles,"dimensionStyles":document.dim_styles,"views":document.views,
        "viewports":document.vports,"coordinateSystems":document.ucss,"applications":document.app_ids,"classes":document.classes});
    normalize_auxiliary(document, &mut value);
    value
}

/// Normalize the two reference fields where the pinned acadrust 0.5.5 writer
/// provably cannot round-trip the in-memory value, so that synthesized
/// defaults from `initialize_defaults()` (kept for drawings that omit an
/// OBJECTS section) compare equal to their writer→reader counterpart:
///
/// - `MultiLeaderStyle.line_type_handle`: the constructor default is `None`,
///   and the DXF writer substitutes the ByLayer linetype handle (writer code
///   340, `section_writer.rs::write_multileader_style`), so a re-read document
///   legitimately holds `Some(bylayer)`. `None` therefore compares as the
///   resolved name of the ByLayer linetype, i.e. "ByLayer".
/// - `TableStyle` row `text_style_handle`: the writer persists only the text
///   style name (code 7, `write_table_cell_style`) and the reader never
///   restores a handle (`read_table_style`), while `set_all_text_styles` used
///   by the defaults stores `Some(Standard)`. The handle therefore compares
///   as the row's persisted `text_style_name`.
///
/// Both sides are resolved through their own document's tables, so a custom
/// linetype/text style is still compared by its exact name, and a handle that
/// resolves to no table entry is kept verbatim so a dangling reference still
/// fails the gate. Nothing else is stripped: every other field, object,
/// dictionary entry and layout value must still round-trip exactly.
fn normalize_auxiliary(document: &CadDocument, auxiliary: &mut Value) {
    let line_type_names: HashMap<u64, &str> = document.line_types.iter()
        .map(|entry| (entry.handle.value(), entry.name.as_str())).collect();
    let text_style_names: HashMap<u64, &str> = document.text_styles.iter()
        .map(|entry| (entry.handle.value(), entry.name.as_str())).collect();
    let resolve = |field: &Value, names: &HashMap<u64, &str>, fallback: Value| -> Value {
        match field.as_u64().and_then(|handle| names.get(&handle)) {
            Some(name) => Value::String(name.to_string()),
            // Unresolvable handles stay verbatim so genuine loss still fails.
            None if field.is_u64() => field.clone(),
            None => fallback,
        }
    };
    let Some(objects) = auxiliary.get_mut("objects").and_then(Value::as_object_mut) else { return };
    for object in objects.values_mut() {
        let Some(body) = object.as_object_mut() else { continue };
        if let Some(style) = body.get_mut("MultiLeaderStyle").and_then(Value::as_object_mut) {
            if let Some(field) = style.get_mut("line_type_handle") {
                *field = resolve(field, &line_type_names, Value::String("ByLayer".into()));
            }
        }
        if let Some(style) = body.get_mut("TableStyle").and_then(Value::as_object_mut) {
            for row in ["data_row_style", "title_row_style", "header_row_style"] {
                let Some(cells) = style.get_mut(row).and_then(Value::as_object_mut) else { continue };
                let fallback = cells.get("text_style_name").cloned().unwrap_or(Value::Null);
                if let Some(field) = cells.get_mut("text_style_handle") {
                    *field = resolve(field, &text_style_names, fallback);
                }
            }
        }
    }
}

fn strip_table_handles(value: &mut Value) {
    match value {
        Value::Object(map) => {
            map.remove("handle"); map.remove("owner_handle");
            for value in map.values_mut() { strip_table_handles(value); }
        }
        Value::Array(values) => for value in values { strip_table_handles(value); },
        _ => {}
    }
}

#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "camelCase", deny_unknown_fields)]
enum Edit {
    AddLine { start: [f64;3], end: [f64;3], layer: String },
    AddCircle { center: [f64;3], radius: f64, layer: String },
    AddText { position: [f64;3], text: String, height: f64, layer: String },
    Move { handle: String, delta: [f64;3] },
    SetText { handle: String, text: String },
    SetRadius { handle: String, radius: f64 },
    Delete { handle: String },
    /// One atomic pencil/ink stroke: all points become consecutive LINE
    /// segments on `FLOE_ANNOTATION` in a single document mutation and a single
    /// undo snapshot. No batch nesting is accepted, so the request cannot
    /// recurse or amplify work.
    AddStroke {
        points: Vec<[f64;3]>,
        #[serde(default)]
        color: Option<i32>,
        #[serde(default, rename = "lineWeight")]
        line_weight: Option<i32>,
    },
}

fn vector(value: [f64;3]) -> Result<Vector3, String> {
    if !value.iter().all(|v| v.is_finite() && v.abs() <= 1e12) { return Err("Invalid CAD coordinate".into()); }
    Ok(Vector3::new(value[0], value[1], value[2]))
}
fn positive(value: f64) -> Result<f64, String> {
    if value.is_finite() && value > 0.0 && value <= 1e12 { Ok(value) } else { Err("Expected positive CAD dimension".into()) }
}
fn text_value(value: String) -> Result<String, String> {
    if value.len() > 16_384 || value.contains('\0') { Err("CAD text limit".into()) } else { Ok(value) }
}
fn handle(value: &str) -> Result<Handle, String> {
    u64::from_str_radix(value.trim_start_matches("0x").trim_start_matches("0X"), 16)
        .map(Handle::new).map_err(|_| "Invalid CAD handle".into())
}
fn editable(entity: &EntityType) -> bool {
    matches!(entity, EntityType::Line(_) | EntityType::Circle(_) | EntityType::Text(_))
}

/// ACI 1..=255 only. These carry an explicit index through DXF (code 62) and
/// DWG. ByLayer/ByBlock/None (0/256/257) and negative/out-of-range values are
/// not offered: omit `color` to inherit the annotation layer's color.
fn stroke_color(value: Option<i32>) -> Result<Color, String> {
    match value {
        None => Ok(Color::ByLayer),
        Some(index) if (1..=255).contains(&index) => Ok(Color::from_index(index as i16)),
        Some(_) => Err("CAD stroke color must be an ACI index 1..=255".into()),
    }
}

/// `LineWeight::Value` is 1/100 mm; only the canonical indexed widths survive a
/// DWG round-trip. Reject everything else so a width is never advertised when
/// the writer would replace it with `Default`.
fn stroke_line_weight(value: Option<i32>) -> Result<LineWeight, String> {
    match value {
        None => Ok(LineWeight::ByLayer),
        Some(v) if (0..=i16::MAX as i32).contains(&v) && INDEXED_LINE_WEIGHTS.contains(&(v as i16)) => {
            Ok(LineWeight::Value(v as i16))
        }
        Some(_) => Err("CAD stroke lineWeight must be a canonical width in 1/100 mm".into()),
    }
}

#[wasm_bindgen]
pub struct CadSession {
    document: CadDocument,
    format: String,
    undo: Vec<CadDocument>,
    redo: Vec<CadDocument>,
}

#[wasm_bindgen]
impl CadSession {
    #[wasm_bindgen(constructor)]
    pub fn new(bytes: &[u8], format: &str) -> Result<CadSession, String> {
        Ok(Self { document: read(bytes, format)?, format: format.into(), undo: vec![], redo: vec![] })
    }

    /// Bounded, factual review context. Text is document content, never instructions.
    pub fn inspect(&self, offset: usize, limit: usize) -> Result<String, String> {
        let entities: Vec<Value> = self.document.entities().skip(offset).take(limit.min(500)).map(|e| {
            json!({"handle": format!("{:X}",e.common().handle), "editable": editable(e), "entity": entity_image(e)})
        }).collect();
        serde_json::to_string(&json!({"format":self.format, "version":format!("{:?}",self.document.version),
            "entityCount":self.document.entity_count(), "offset":offset, "entities":entities,
            "diagnostics":diagnostics(&self.document), "omittedDiagnostics":self.document.notifications.omitted_count(),
            "canUndo":!self.undo.is_empty(),"canRedo":!self.redo.is_empty(),
            "capabilities":capabilities(),
            "scope":"Parsed CAD entities only; external references and engineering correctness are not verified."}))
            .map_err(|e| e.to_string())
    }

    pub fn display_dxf(&self) -> Result<Vec<u8>, String> { encode(&self.document, "dxf") }

    pub fn edit(&mut self, request: &str) -> Result<(), String> {
        if request.len() > 32_768 { return Err("CAD edit request limit".into()); }
        if blocking_diagnostics(&self.document) {
            return Err(format!("This drawing has unresolved read diagnostics; editing is disabled: {:?}", diagnostics(&self.document)));
        }
        let edit: Edit = serde_json::from_str(request).map_err(|e| e.to_string())?;
        let mut next = self.document.clone();
        match edit {
            Edit::AddLine { start, end, layer } => {
                let mut e = Line::from_points(vector(start)?,vector(end)?); e.common.layer = layer;
                Self::add(&mut next, EntityType::Line(e))?;
            }
            Edit::AddCircle { center, radius, layer } => {
                let mut e = Circle::from_center_radius(vector(center)?,positive(radius)?); e.common.layer = layer;
                Self::add(&mut next, EntityType::Circle(e))?;
            }
            Edit::AddText { position, text, height, layer } => {
                let mut e = Text::with_value(text_value(text)?,vector(position)?).with_height(positive(height)?); e.common.layer = layer;
                Self::add(&mut next, EntityType::Text(e))?;
            }
            Edit::Move { handle: id, delta } => {
                let delta = vector(delta)?;
                match Self::mutable(&mut next, &id)? {
                    EntityType::Line(e) => { e.start = e.start + delta; e.end = e.end + delta; }
                    EntityType::Circle(e) if e.normal == Vector3::new(0.0,0.0,1.0) => e.center = e.center + delta,
                    EntityType::Text(e) if e.normal == Vector3::new(0.0,0.0,1.0) => {
                        e.insertion_point = e.insertion_point + delta;
                        e.alignment_point = e.alignment_point.map(|p| p + delta);
                    }
                    _ => return Err("Moving this entity or coordinate system is not supported".into()),
                }
            }
            Edit::SetText { handle:id, text } => match Self::mutable(&mut next,&id)? {
                EntityType::Text(e) => e.value = text_value(text)?,
                _ => return Err("Select a text entity".into()),
            },
            Edit::SetRadius { handle:id, radius } => match Self::mutable(&mut next,&id)? {
                EntityType::Circle(e) => e.radius = positive(radius)?,
                _ => return Err("Select a circle".into()),
            },
            Edit::Delete { handle:id } => {
                let key = handle(&id)?;
                if !editable(Self::mutable(&mut next,&id)?) { return Err("Deleting this entity is not supported".into()); }
                next.remove_entity(key);
            }
            Edit::AddStroke { points, color, line_weight } => {
                Self::add_stroke(&mut next, &points, color, line_weight)?;
            }
        }
        if self.undo.len() == HISTORY { self.undo.remove(0); }
        self.undo.push(std::mem::replace(&mut self.document, next)); self.redo.clear();
        Ok(())
    }

    pub fn undo(&mut self) -> bool {
        if let Some(previous) = self.undo.pop() {
            self.redo.push(std::mem::replace(&mut self.document, previous)); true
        } else { false }
    }
    pub fn redo(&mut self) -> bool {
        if let Some(next) = self.redo.pop() {
            self.undo.push(std::mem::replace(&mut self.document, next)); true
        } else { false }
    }

    /// Must succeed before offering bytes to the native compare-and-swap writer.
    pub fn save(&self) -> Result<Vec<u8>, String> {
        if blocking_diagnostics(&self.document) { return Err("Unresolved CAD diagnostics".into()); }
        let bytes = encode(&self.document, &self.format)?;
        verify(&self.document, &read(&bytes, &self.format)?)?;
        Ok(bytes)
    }
}

impl CadSession {
    fn add(document: &mut CadDocument, entity: EntityType) -> Result<(), String> {
        if document.entity_count() >= MAX_ENTITIES { return Err("CAD entity limit".into()); }
        let layer = document.layers.get(&entity.common().layer).ok_or("Unknown CAD layer")?;
        if layer.is_locked() { return Err("CAD layer is locked".into()); }
        document.add_entity(entity).map(|_| ()).map_err(|e| e.to_string())
    }
    fn mutable<'a>(document: &'a mut CadDocument, id: &str) -> Result<&'a mut EntityType, String> {
        let key = handle(id)?;
        let entity = document.get_entity(key).ok_or("CAD entity no longer exists")?;
        if document.layers.get(&entity.common().layer).is_some_and(|l| l.is_locked()) { return Err("CAD layer is locked".into()); }
        document.get_entity_mut(key).ok_or("CAD entity no longer exists".into())
    }

    /// Apply one atomic pencil stroke to a cloned document. Every point, the
    /// color and the line weight are validated before any segment is created,
    /// so a mid-stroke failure cannot leave a partial stroke or a history
    /// entry. The caller commits exactly one snapshot only when this is `Ok`.
    fn add_stroke(
        document: &mut CadDocument,
        points: &[[f64; 3]],
        color: Option<i32>,
        line_weight: Option<i32>,
    ) -> Result<(), String> {
        if !(MIN_STROKE_POINTS..=MAX_STROKE_POINTS).contains(&points.len()) {
            return Err(format!("CAD stroke needs {MIN_STROKE_POINTS}..={MAX_STROKE_POINTS} points"));
        }
        // Validate the complete stroke up front; this is the rollback boundary.
        let vertices: Vec<Vector3> = points.iter().map(|p| vector(*p)).collect::<Result<_, _>>()?;
        let color = stroke_color(color)?;
        let line_weight = stroke_line_weight(line_weight)?;
        let segments = vertices.len() - 1;
        if document.entity_count().saturating_add(segments) > MAX_ENTITIES {
            return Err("CAD entity limit".into());
        }
        if document.layers.get(ANNOTATION_LAYER).is_none() {
            document.layers.add(Layer::new(ANNOTATION_LAYER))
                .map_err(|e| format!("CAD annotation layer: {e}"))?;
        }
        if document.layers.get(ANNOTATION_LAYER).is_some_and(|l| l.is_locked()) {
            return Err("CAD layer is locked".into());
        }
        for pair in vertices.windows(2) {
            let mut segment = Line::from_points(pair[0], pair[1]);
            segment.common.layer = ANNOTATION_LAYER.to_string();
            segment.common.color = color;
            segment.common.line_weight = line_weight;
            document.add_entity(EntityType::Line(segment)).map_err(|e| e.to_string())?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use acadrust::{DxfVersion, Layer, LineType, TableEntry, TextStyle};
    use acadrust::objects::ObjectType;

    fn fixture(version: DxfVersion) -> CadDocument {
        let mut doc = CadDocument::new(); doc.version = version;
        doc.layers.add(Layer::new("Dimensions")).unwrap();
        doc.add_entity(EntityType::Line(Line::from_coords(0.,0.,0.,100.,50.,0.))).unwrap();
        doc.add_entity(EntityType::Circle(Circle::from_coords(40.,30.,0.,12.))).unwrap();
        doc.add_entity(EntityType::Text(Text::with_value("尺寸 / CAD",Vector3::new(5.,8.,0.)).with_height(2.5))).unwrap();
        doc
    }

    #[test]
    fn native_dxf_and_dwg_edit_save_reopen() {
        for version in [DxfVersion::AC1024, DxfVersion::AC1027, DxfVersion::AC1032] {
            for format in ["dxf","dwg"] {
                let input = encode(&fixture(version),format).unwrap();
                let mut session = CadSession::new(&input,format).unwrap();
                eprintln!("Input {format} {version:?}: {:?}", diagnostics(&session.document));
                let line = session.document.entities().find(|e|matches!(e,EntityType::Line(_))).unwrap().common().handle;
                session.edit(&json!({"operation":"move","handle":format!("{line:X}"),"delta":[5,7,0]}).to_string()).unwrap();
                session.edit(r#"{"operation":"addCircle","center":[80,20,0],"radius":3,"layer":"Dimensions"}"#).unwrap();
                assert!(session.undo()); assert!(session.redo());
                let output = session.save().unwrap_or_else(|e|panic!("{format} {version:?}: {e}"));
                std::fs::create_dir_all("qualification-fixtures").unwrap();
                std::fs::write(format!("qualification-fixtures/input-{version:?}.{format}"),&input).unwrap();
                std::fs::write(format!("qualification-fixtures/edited-{version:?}.{format}"),&output).unwrap();
                if format == "dwg" { assert_eq!(&output[..6], &input[..6]); }
                let reopened = read(&output,format).unwrap();
                assert_eq!(reopened.entity_count(),4);
                match reopened.get_entity(line).unwrap() {
                    EntityType::Line(e) => assert_eq!(e.start,Vector3::new(5.,7.,0.)), _ => panic!(),
                }
            }
        }
    }

    #[test]
    fn invalid_edits_do_not_change_history_or_document() {
        let input = encode(&fixture(DxfVersion::AC1032),"dxf").unwrap();
        let mut session = CadSession::new(&input,"dxf").unwrap();
        let before = session.inspect(0,500).unwrap();
        assert!(session.edit(r#"{"operation":"addCircle","center":[0,0,0],"radius":-1,"layer":"0"}"#).is_err());
        assert!(session.edit(r#"{"operation":"delete","handle":"FFFFFFFFFFFF"}"#).is_err());
        assert_eq!(before,session.inspect(0,500).unwrap());
        assert!(!session.undo());
    }

    fn annotation_lines(session: &CadSession) -> Vec<&Line> {
        session.document.entities().filter_map(|e| match e {
            EntityType::Line(l) if l.common.layer == ANNOTATION_LAYER => Some(l),
            _ => None,
        }).collect()
    }

    #[test]
    fn add_stroke_is_atomic_with_one_history_entry() {
        let input = encode(&fixture(DxfVersion::AC1032),"dxf").unwrap();
        let mut session = CadSession::new(&input,"dxf").unwrap();
        let base = session.document.entity_count();
        session.edit(r#"{"operation":"addStroke","points":[[0,0,0],[10,0,0],[10,10,0]],"color":1,"lineWeight":25}"#).unwrap();
        assert_eq!(session.document.entity_count(), base + 2);
        let lines = annotation_lines(&session);
        assert_eq!(lines.len(), 2);
        for line in &lines {
            assert_eq!(line.common.layer, ANNOTATION_LAYER);
            assert_eq!(line.common.color, Color::Index(1));
            assert_eq!(line.common.line_weight, LineWeight::Value(25));
        }
        assert_eq!(lines[0].start, Vector3::new(0.,0.,0.));
        assert_eq!(lines[0].end, Vector3::new(10.,0.,0.));
        assert_eq!(lines[1].end, Vector3::new(10.,10.,0.));
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
        let input = encode(&fixture(DxfVersion::AC1032),"dxf").unwrap();
        let mut session = CadSession::new(&input,"dxf").unwrap();
        let before = session.inspect(0,500).unwrap();
        // Out-of-bounds third point: the stroke must be rejected as a whole.
        assert!(session.edit(r#"{"operation":"addStroke","points":[[0,0,0],[1,0,0],[10000000000000,0,0]]}"#).is_err());
        // Too few / too many points.
        assert!(session.edit(r#"{"operation":"addStroke","points":[[0,0,0]]}"#).is_err());
        let many: Vec<[f64;3]> = (0..=MAX_STROKE_POINTS).map(|i| [i as f64,0.,0.]).collect();
        assert!(session.edit(&json!({"operation":"addStroke","points":many}).to_string()).is_err());
        // Color and line weight must be values the engine actually saves.
        assert!(session.edit(r#"{"operation":"addStroke","points":[[0,0,0],[1,0,0]],"color":0}"#).is_err());
        assert!(session.edit(r#"{"operation":"addStroke","points":[[0,0,0],[1,0,0]],"color":300}"#).is_err());
        assert!(session.edit(r#"{"operation":"addStroke","points":[[0,0,0],[1,0,0]],"lineWeight":17}"#).is_err());
        assert!(session.edit(r#"{"operation":"addStroke","points":[[0,0,0],[1,0,0]],"lineWeight":-1}"#).is_err());
        assert_eq!(before, session.inspect(0,500).unwrap());
        assert!(!session.undo());
    }

    #[test]
    fn add_stroke_point_boundaries() {
        let input = encode(&fixture(DxfVersion::AC1032),"dxf").unwrap();
        let mut session = CadSession::new(&input,"dxf").unwrap();
        let minimum = json!({"operation":"addStroke","points":[[0.,0.,0.],[1.,2.,3.]]}).to_string();
        session.edit(&minimum).unwrap();
        assert_eq!(annotation_lines(&session).len(), 1);
        assert!(session.undo());
        let maximum: Vec<[f64;3]> = (0..MAX_STROKE_POINTS).map(|i| [i as f64,0.,0.]).collect();
        session.edit(&json!({"operation":"addStroke","points":maximum}).to_string()).unwrap();
        assert_eq!(annotation_lines(&session).len(), MAX_STROKE_POINTS - 1);
        assert!(session.undo());
        assert!(annotation_lines(&session).is_empty());
    }

    #[test]
    fn add_stroke_rejects_locked_annotation_layer() {
        let mut document = fixture(DxfVersion::AC1032);
        document.layers.add(Layer::new(ANNOTATION_LAYER)).unwrap();
        document.layers.get_mut(ANNOTATION_LAYER).unwrap().lock();
        let mut session = CadSession { document, format: "dxf".into(), undo: vec![], redo: vec![] };
        let before = session.inspect(0,500).unwrap();
        assert!(session.edit(r#"{"operation":"addStroke","points":[[0,0,0],[5,0,0]]}"#).is_err());
        assert_eq!(before, session.inspect(0,500).unwrap());
        assert!(!session.undo());
    }

    #[test]
    fn add_stroke_reuses_existing_annotation_layer() {
        let mut document = fixture(DxfVersion::AC1032);
        document.layers.add(Layer::new(ANNOTATION_LAYER)).unwrap();
        let layers_before = document.layers.iter().count();
        let mut session = CadSession { document, format: "dxf".into(), undo: vec![], redo: vec![] };
        session.edit(r#"{"operation":"addStroke","points":[[0,0,0],[5,0,0]]}"#).unwrap();
        session.edit(r#"{"operation":"addStroke","points":[[0,5,0],[5,5,0]]}"#).unwrap();
        assert_eq!(session.document.layers.iter().count(), layers_before);
        assert_eq!(annotation_lines(&session).len(), 2);
        assert!(session.undo());
        assert_eq!(annotation_lines(&session).len(), 1);
        assert!(annotation_lines(&session)[0].common.color == Color::ByLayer);
    }

    #[test]
    fn add_stroke_respects_entity_limit() {
        let mut document = fixture(DxfVersion::AC1032);
        while document.entity_count() < MAX_ENTITIES {
            let mut line = Line::from_coords(0.,0.,0.,1.,0.,0.);
            line.common.layer = "0".into();
            document.add_entity(EntityType::Line(line)).unwrap();
        }
        let mut session = CadSession { document, format: "dxf".into(), undo: vec![], redo: vec![] };
        let before = session.inspect(0,500).unwrap();
        assert!(session.edit(r#"{"operation":"addStroke","points":[[0,0,0],[5,0,0]]}"#).is_err());
        assert_eq!(before, session.inspect(0,500).unwrap());
        assert!(!session.undo());
    }

    #[test]
    fn add_stroke_saves_and_reopens_in_dwg() {
        let input = encode(&fixture(DxfVersion::AC1032),"dwg").unwrap();
        let mut session = CadSession::new(&input,"dwg").unwrap();
        let base = session.document.entity_count();
        session.edit(r#"{"operation":"addStroke","points":[[0,0,0],[10,0,0],[10,10,0]],"color":1,"lineWeight":50}"#).unwrap();
        let output = session.save().unwrap();
        assert_eq!(&output[..6], &input[..6]);
        let reopened = read(&output,"dwg").unwrap();
        assert_eq!(reopened.entity_count(), base + 2);
        assert!(reopened.layers.get(ANNOTATION_LAYER).is_some());
        let lines: Vec<&Line> = reopened.entities().filter_map(|e| match e {
            EntityType::Line(l) if l.common.layer == ANNOTATION_LAYER => Some(l),
            _ => None,
        }).collect();
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0].start, Vector3::new(0.,0.,0.));
        assert_eq!(lines[0].end, Vector3::new(10.,0.,0.));
        assert_eq!(lines[1].end, Vector3::new(10.,10.,0.));
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
                while i + 1 < lines.len()
                    && !(lines[i].trim() == "0" && lines[i + 1].trim() == "ENDSEC") { i += 1; }
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
        // Regression for the diagnosed no-op save failure: a drawing without
        // an OBJECTS section keeps initialize_defaults()-synthesized standard
        // objects, and the acadrust 0.5.5 DXF writer persists two reference
        // fields differently from how they are synthesized
        // (MultiLeaderStyle.line_type_handle, TableStyle row
        // text_style_handle). The gate must accept the writer's own
        // normalization while everything else still round-trips.
        let input = encode(&fixture(DxfVersion::AC1032), "dxf").unwrap();
        let stripped = without_dxf_section(&input, "OBJECTS");
        assert!(!stripped.windows(7).any(|window| window == b"OBJECTS"));
        let mut session = CadSession::new(&stripped, "dxf").unwrap();
        let before = entity_images(&session);
        let output = session.save().expect("no-op save of a drawing without OBJECTS");
        let reopened = CadSession::new(&output, "dxf").unwrap();
        assert_eq!(before, entity_images(&reopened));
        // An annotation stroke must also save and reopen on such drawings.
        session.edit(r#"{"operation":"addStroke","points":[[0,0,0],[4,0,0],[4,4,0]],"color":3,"lineWeight":35}"#).unwrap();
        let output = session.save().expect("stroke save of a drawing without OBJECTS");
        let reopened = read(&output, "dxf").unwrap();
        assert_eq!(reopened.entity_count(), session.document.entity_count());
        assert!(reopened.layers.get(ANNOTATION_LAYER).is_some());
    }

    #[test]
    fn roundtrip_preserves_custom_styles_objects_and_layouts() {
        // Non-default custom table entries and objects must survive a save
        // verbatim and stay referenced: the normalizer compares resolved
        // names, it never drops custom content.
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
                ObjectType::MultiLeaderStyle(style) => {
                    style.line_type_handle = Some(linetype_handle);
                }
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
        let mut session = CadSession { document, format: "dxf".into(), undo: vec![], redo: vec![] };
        let output = session.save().unwrap();
        let reopened = read(&output, "dxf").unwrap();
        let dashed = reopened.line_types.get("Dashed").expect("custom linetype preserved");
        assert!(!dashed.elements.is_empty());
        let custom = reopened.text_styles.get("FLOE_TXT").expect("custom text style preserved");
        assert_eq!(custom.font_file, "MiSans-Regular.ttf");
        let mleader = reopened.objects.values().find_map(|object| match object {
            ObjectType::MultiLeaderStyle(style) => Some(style), _ => None,
        }).unwrap();
        let resolved = reopened.line_types.iter()
            .find(|entry| Some(entry.handle) == mleader.line_type_handle)
            .map(|entry| entry.name.as_str());
        assert_eq!(resolved, Some("Dashed"));
        let table = reopened.objects.values().find_map(|object| match object {
            ObjectType::TableStyle(style) if style.name == "Standard" => Some(style), _ => None,
        }).unwrap();
        assert_eq!(table.data_row_style.text_style_name, "FLOE_TXT");
        assert!((table.data_row_style.text_height - 0.42).abs() < 1e-9);
        // The writer persists the row text style by name only.
        assert!(table.data_row_style.text_style_handle.is_none());
        let layout = reopened.objects.values().find_map(|object| match object {
            ObjectType::Layout(layout) if layout.name == "Layout1" => Some(layout), _ => None,
        }).unwrap();
        assert_eq!(layout.paper_width, 420.0);
        assert_eq!(layout.paper_height, 297.0);
    }

    #[test]
    fn roundtrip_gate_rejects_unpreserved_font_and_paper_units() {
        // CI 35190961896 exposed actual upstream loss, not equivalent reference
        // encoding. These fields must keep failing the gate; never normalize
        // away the missing font family or changed paper-unit meaning.
        for font_case in [true, false] {
            let mut document = fixture(DxfVersion::AC1032);
            if font_case {
                let mut style = TextStyle::with_truetype("FLOE_LOSS", "MiSans-Regular.ttf");
                style.set_handle(document.allocate_handle());
                document.text_styles.add(style).unwrap();
            } else {
                let layout = document.objects.values_mut().find_map(|object| match object {
                    ObjectType::Layout(layout) if layout.name == "Layout1" => Some(layout),
                    _ => None,
                }).unwrap();
                layout.plot_paper_units = 1;
            }
            let mut session = CadSession { document, format: "dxf".into(), undo: vec![], redo: vec![] };
            let before = auxiliary_image(&session.document);
            assert!(session.save().is_err());
            assert_eq!(before, auxiliary_image(&session.document));
        }
    }

    #[test]
    fn roundtrip_gate_still_rejects_missing_objects() {
        // Simulate actual loss after encoding: compare an intact source with
        // a reopened document missing one object, instead of deliberately
        // deleting source content before save (which is a different contract).
        let document = fixture(DxfVersion::AC1032);
        let mut reopened = read(&encode(&document, "dxf").unwrap(), "dxf").unwrap();
        verify(&document, &reopened).unwrap();
        let mut removed = 0;
        reopened.objects.retain(|_, object| {
            let keep = !matches!(object, ObjectType::MultiLeaderStyle(_));
            if !keep { removed += 1; }
            keep
        });
        assert_eq!(removed, 1);
        assert!(verify(&document, &reopened).is_err());
    }

    #[test]
    fn add_stroke_undo_redo_in_dwg() {
        // Existing DWG behavior: a stroke is one undo/redo unit and undoing
        // back to the untouched drawing still saves with the original header.
        let input = encode(&fixture(DxfVersion::AC1032), "dwg").unwrap();
        let mut session = CadSession::new(&input, "dwg").unwrap();
        let base = session.document.entity_count();
        session.edit(r#"{"operation":"addStroke","points":[[1,1,0],[9,1,0],[9,9,0]],"color":5,"lineWeight":70}"#).unwrap();
        assert_eq!(session.document.entity_count(), base + 2);
        assert!(session.undo());
        assert_eq!(session.document.entity_count(), base);
        assert!(annotation_lines(&session).is_empty());
        assert!(session.redo());
        assert_eq!(session.document.entity_count(), base + 2);
        assert_eq!(annotation_lines(&session).len(), 2);
        assert!(session.undo());
        assert_eq!(session.document.entity_count(), base);
        let output = session.save().unwrap();
        assert_eq!(&output[..6], &input[..6]);
    }

    #[test]
    fn inspect_declares_add_stroke_capabilities() {
        let input = encode(&fixture(DxfVersion::AC1032),"dxf").unwrap();
        let session = CadSession::new(&input,"dxf").unwrap();
        let metadata: Value = serde_json::from_str(&session.inspect(0,1).unwrap()).unwrap();
        let stroke = &metadata["capabilities"]["addStroke"];
        assert_eq!(metadata["capabilities"]["version"].as_u64(), Some(1));
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
        assert!(CadSession::new(b"not a DWG","dwg").is_err());
        let mut doc = fixture(DxfVersion::AC1032);
        doc.notifications.notify(acadrust::notification::NotificationType::NotSupported,"unknown entity");
        let session = CadSession { document:doc,format:"dwg".into(),undo:vec![],redo:vec![] };
        assert!(session.save().is_err());
        let mut doc = fixture(DxfVersion::AC1032);
        doc.notifications.notify(acadrust::notification::NotificationType::Warning,"AC18: Invalid compressed size 0 for page 1");
        assert!(blocking_diagnostics(&doc));
    }
}
