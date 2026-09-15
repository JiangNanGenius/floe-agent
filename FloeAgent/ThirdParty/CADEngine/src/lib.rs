// SPDX-License-Identifier: MPL-2.0
//! Local CAD document engine. Run in a terminable Web Worker, never on the UI thread.
//! Original DWG documents stay native; DXF projection is only for display.
use acadrust::{CadDocument, Circle, DwgReader, DwgWriter, DxfReader, DxfWriter,
              EntityType, Handle, Line, Text, Vector3};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::Cursor;
use wasm_bindgen::prelude::*;

const MAX_BYTES: usize = 10 * 1024 * 1024;
const MAX_ENTITIES: usize = 20_000;
const HISTORY: usize = 8;

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
    if !reopened.notifications.is_empty() || reopened.notifications.omitted_count() > 0 {
        return Err(format!("CAD round-trip diagnostics: {:?}", diagnostics(reopened)));
    }
    for entity in document.entities() {
        let handle = entity.common().handle;
        let other = reopened.get_entity(handle).ok_or("CAD round-trip lost an entity")?;
        if !equivalent(&entity_image(entity), &entity_image(other)) {
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
    Ok(())
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
            "scope":"Parsed CAD entities only; external references and engineering correctness are not verified."}))
            .map_err(|e| e.to_string())
    }

    pub fn display_dxf(&self) -> Result<Vec<u8>, String> { encode(&self.document, "dxf") }

    pub fn edit(&mut self, request: &str) -> Result<(), String> {
        if request.len() > 32_768 { return Err("CAD edit request limit".into()); }
        if !self.document.notifications.is_empty() || self.document.notifications.omitted_count() > 0 {
            return Err("This drawing has unresolved read diagnostics; editing is disabled".into());
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
        if !self.document.notifications.is_empty() { return Err("Unresolved CAD diagnostics".into()); }
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use acadrust::{DxfVersion, Layer};

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
                let line = session.document.entities().find(|e|matches!(e,EntityType::Line(_))).unwrap().common().handle;
                session.edit(&json!({"operation":"move","handle":format!("{line:X}"),"delta":[5,7,0]}).to_string()).unwrap();
                session.edit(r#"{"operation":"addCircle","center":[80,20,0],"radius":3,"layer":"Dimensions"}"#).unwrap();
                assert!(session.undo()); assert!(session.redo());
                let output = session.save().unwrap_or_else(|e|panic!("{format} {version:?}: {e}"));
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

    #[test]
    fn diagnostics_and_corrupt_files_cannot_be_saved() {
        assert!(CadSession::new(b"not a DWG","dwg").is_err());
        let mut doc = fixture(DxfVersion::AC1032);
        doc.notifications.notify(acadrust::notification::NotificationType::NotSupported,"unknown entity");
        let session = CadSession { document:doc,format:"dwg".into(),undo:vec![],redo:vec![] };
        assert!(session.save().is_err());
    }
}
