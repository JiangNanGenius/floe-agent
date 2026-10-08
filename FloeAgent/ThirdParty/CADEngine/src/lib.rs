// SPDX-License-Identifier: MPL-2.0
//! Local CAD document engine. Run in a terminable Web Worker, never on the UI thread.
//! Original DWG documents stay native; DXF projection is only for display.
//!
//! Source: `FloeAgent/ThirdParty/CADEngine/src/lib.rs` (Floe-owned MPL-2.0 binding
//! over acadrust 0.5.5). DWG is read and written natively; DXF shares the same
//! save round-trip guard. Coordinate units: values are unitless drawing units;
//! pencil strokes use the drawing's own world coordinates `[x, y, z]` with Z
//! preserved.
//!
//! Every edit is atomic and takes exactly one undo snapshot. Supported editing:
//! line/circle/arc/LWPolyline/text creation (including rectangle LWPolylines),
//! move/copy/rotate/uniform scale/mirror/delete/property changes, layer
//! create/rename/update/delete, trim/extend for coplanar lines and arcs,
//! offset for lines/circles/arcs/open polylines, native dimensions and leaders,
//! and one atomic pencil stroke. Read-only queries cover capabilities, drawing
//! header, layers, paginated filtered entities, object snap candidates,
//! geometric measurements and a consistency check. Splines, blocks, xrefs,
//! proxy graphics, 3D and non-default OCS edits are retained and reported as
//! unsupported, never flattened.
mod geometry;

use acadrust::entities::Entity;
use acadrust::entities::{
    Dimension, DimensionAligned, DimensionAngular2Ln, DimensionDiameter, DimensionLinear,
    DimensionRadius, Leader, LwVertex,
};
use acadrust::types::{Transform, Vector2};
use acadrust::{
    Arc, CadDocument, Circle, Color, DwgReader, DwgWriter, DxfReader, DxfWriter, EntityType, Handle,
    Layer, Line, LineWeight, LwPolyline, Text, Vector3,
};
use geometry::{
    intersections, line_arc_intersections_infinite, line_circle_intersections_infinite,
    line_line_intersection, norm_angle, offset_open_polyline, polyline_length,
    polyline_signed_area, primitive_distance, Primitive, P,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::Cursor;
use wasm_bindgen::prelude::*;

const MAX_BYTES: usize = 10 * 1024 * 1024;
const MAX_ENTITIES: usize = 20_000;
const HISTORY: usize = 8;
/// One request may carry at most this many batch operations; the whole batch
/// is validated and applied atomically or rejected as a whole.
const MAX_BATCH_OPERATIONS: usize = 64;
const MAX_POLYLINE_POINTS: usize = 256;
const MAX_SNAP_ENTITIES: usize = 64;
const MAX_SNAP_RESULTS: usize = 32;
const MAX_QUERY_ROWS: usize = 500;
/// Cross-entity duplicate/dangling checks stay bounded; above this entity
/// count the check reports the work as skipped instead of stalling.
const MAX_PAIRWISE_ENTITIES: usize = 4_000;

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
    if bytes.is_empty() || bytes.len() > MAX_BYTES {
        return Err("CAD file size limit".into());
    }
    let document = match format {
        "dxf" => DxfReader::from_reader(Cursor::new(bytes.to_vec())).and_then(|reader| reader.read()),
        "dwg" => DwgReader::from_stream(Cursor::new(bytes)).read(),
        _ => return Err("Expected DXF or DWG".into()),
    }
    .map_err(|e| e.to_string())?;
    if document.entity_count() > MAX_ENTITIES {
        return Err("CAD entity limit".into());
    }
    Ok(document)
}

fn encode(document: &CadDocument, format: &str) -> Result<Vec<u8>, String> {
    let bytes = match format {
        "dwg" => DwgWriter::write_to_vec(document),
        "dxf" => DxfWriter::new(document).write_to_vec(),
        _ => return Err("Expected DXF or DWG".into()),
    }
    .map_err(|e| e.to_string())?;
    if bytes.len() > MAX_BYTES {
        return Err("CAD output size limit".into());
    }
    Ok(bytes)
}

fn diagnostics(document: &CadDocument) -> Vec<String> {
    document.notifications.iter().map(ToString::to_string).collect()
}

/// Human-readable drawing unit for the header's INSUNITS value. Undefined (0)
/// and unknown values stay drawing units and are never assumed to be mm.
fn unit_name(document: &CadDocument) -> String {
    match document.header.insertion_units {
        0 => "unitless drawing units".to_string(),
        1 => "inches".to_string(),
        2 => "feet".to_string(),
        3 => "miles".to_string(),
        4 => "millimeters".to_string(),
        5 => "centimeters".to_string(),
        6 => "meters".to_string(),
        7 => "kilometers".to_string(),
        8 => "microinches".to_string(),
        9 => "mils".to_string(),
        10 => "yards".to_string(),
        11 => "angstroms".to_string(),
        12 => "nanometers".to_string(),
        13 => "microns".to_string(),
        14 => "decimeters".to_string(),
        15 => "decameters".to_string(),
        16 => "hectometers".to_string(),
        17 => "gigameters".to_string(),
        18 => "astronomical units".to_string(),
        19 => "light years".to_string(),
        20 => "parsecs".to_string(),
        other => format!("unit code {other}"),
    }
}

/// Versioned, exact description of the typed edit and query surface. Callers
/// must gate UI controls on these fields instead of assuming capabilities.
fn capabilities() -> Value {
    json!({
        "version": 2,
        "coordinateUnits": "unitless drawing units; coordinates are world/OCS values [x,y,z] with Z preserved",
        "operations": [
            "addLine", "addCircle", "addArc", "addLwPolyline", "addText", "addLeader",
            "addDimension", "move", "copy", "rotate", "scale", "mirror", "setText",
            "setRadius", "setLayer", "setColor", "setLineWeight", "delete",
            "trim", "extend", "offset", "addStroke", "addLayer", "updateLayer",
            "renameLayer", "deleteLayer", "batch"
        ],
        "editableEntityTypes": ["Line", "Circle", "Arc", "LwPolyline", "Text"],
        "entityCreation": {
            "line": true, "circle": true, "arc": true,
            "lwPolyline": {"pointCount": {"min": 2, "max": MAX_POLYLINE_POINTS}, "closed": true, "rectangle": "closed 4-point LWPolyline"},
            "text": true,
            "leader": {"vertices": {"min": 2, "max": 256}, "annotationText": false},
            "dimensions": ["linear", "aligned", "angular", "radius", "diameter"],
            "rasterOrSplineCreation": false
        },
        "modify": {
            "move": ["Line", "Circle", "Arc", "LwPolyline", "Text"],
            "copy": ["Line", "Circle", "Arc", "LwPolyline", "Text"],
            "rotate": ["Line", "Circle", "Arc", "LwPolyline", "Text"],
            "scaleUniform": ["Line", "Circle", "Arc", "LwPolyline", "Text"],
            "mirror": ["Line", "Circle", "Arc", "LwPolyline", "Text"],
            "trim": {"targets": ["Line", "Arc"], "boundaries": ["Line", "Circle", "Arc", "LwPolyline"], "bulgePolylines": false, "splittingPicks": "rejected"},
            "extend": {"targets": ["Line"], "boundaries": ["Line", "Circle", "Arc", "LwPolyline"]},
            "offset": {"line": true, "circle": true, "arc": true, "openLwPolyline": true, "closedLwPolyline": false, "spline": false},
            "nonDefaultOCS": false,
            "lockedLayers": "all edits rejected on locked entities/layers"
        },
        "layers": {
            "create": true, "rename": true, "update": true,
            "delete": "only when no entity references the layer",
            "properties": ["color (ACI 1..=255 or ByLayer)", "lineType (existing table entry, ByLayer, ByBlock)", "lineWeight (canonical widths or ByLayer)", "locked", "visible"],
            "layer0": "cannot be renamed or deleted"
        },
        "queries": ["capabilities", "drawing", "layers", "entities", "text", "snap", "measure", "check", "locate"],
        "snap": {"kinds": ["endpoint", "midpoint", "center", "intersection"], "tolerance": "drawing units"},
        "measure": {"kinds": ["distance", "angle", "radius", "perimeter", "area"], "units": "drawing units / degrees / square drawing units"},
        "check": {"kinds": ["zeroLength", "duplicate", "layerUsage", "openContour", "danglingEndpoint"], "note": "geometric consistency at the stated tolerance, not engineering certification"},
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
        },
        "batch": {"maxOperations": MAX_BATCH_OPERATIONS, "atomicity": "all operations applied or none; one undo snapshot", "strokeAllowed": false},
        "limits": {"bytes": MAX_BYTES, "entities": MAX_ENTITIES, "history": HISTORY, "requestBytes": 32768, "textBytes": 16384, "polylinePoints": MAX_POLYLINE_POINTS},
        "unsupported": ["splines", "block and xref editing", "proxy graphics editing", "3D solid editing", "non-default OCS flattening", "bulge trim/offset", "closed polyline offset"]
    })
}

fn blocking_diagnostics(document: &CadDocument) -> bool {
    use acadrust::notification::NotificationType;
    document.notifications.omitted_count() > 0
        || document.notifications.iter().any(|n| {
            // acadrust 0.5.5 uses Warning for these four successful header/map
            // progress reports (dwg_reader.rs:1258,1550,1630,1745). Preserve them in
            // inspection, but do not mistake them for lost/unsupported content.
            let informational = n.notification_type == NotificationType::Warning
                && (n.message.starts_with("Reading DWG file version: AC")
                    || n.message.starts_with("AC18 inner header: page_map_address=")
                    || (n.message.starts_with("AC18: Read ")
                        && (n.message.ends_with(" page records from page map")
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
        // The pinned reader synthesizes an anonymous block name for a DWG
        // dimension whose block reference is empty (`*U<handle>`,
        // dwg_document_builder.rs:338). That generated identity is not user
        // data; compare it as one token. Explicit non-generated names are
        // still compared verbatim.
        if let Some(inner) = body.as_object_mut().and_then(|m| m.values_mut().next()) {
            if let Some(base) = inner.get_mut("base").and_then(Value::as_object_mut) {
                if let Some(Value::String(name)) = base.get_mut("block_name") {
                    if name.is_empty() || generated_block_name(name) {
                        *name = String::from("<generated>");
                    }
                }
            }
        }
    }
    value
}

/// `*U<digits>` names are anonymous dimension blocks generated by the
/// acadrust DWG reader; they carry no user-authored reference.
fn generated_block_name(name: &str) -> bool {
    name.strip_prefix("*U").is_some_and(|rest| !rest.is_empty() && rest.chars().all(|c| c.is_ascii_digit()))
}

fn equivalent(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(a), Value::Number(b)) => {
            if let (Some(a), Some(b)) = (a.as_f64(), b.as_f64()) {
                (a - b).abs() <= 1e-9 * a.abs().max(b.abs()).max(1.0)
            } else {
                a == b
            }
        }
        (Value::Array(a), Value::Array(b)) => a.len() == b.len() && a.iter().zip(b).all(|(a, b)| equivalent(a, b)),
        (Value::Object(a), Value::Object(b)) => a.len() == b.len() && a.iter().all(|(key, a)| b.get(key).is_some_and(|b| equivalent(a, b))),
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
            #[cfg(test)]
            eprintln!("Entity before: {}\nEntity after: {}", entity_image(entity), entity_image(other));
            return Err(format!("CAD round-trip changed entity {handle}; original preserved"));
        }
        let a = entity.common();
        let b = other.common();
        if a.graphic_data != b.graphic_data
            || a.material_handle != b.material_handle
            || a.color_book_handle != b.color_book_handle
            || a.face_visual_style_handle != b.face_visual_style_handle
            || a.edge_visual_style_handle != b.edge_visual_style_handle
        {
            return Err(format!("CAD round-trip changed references for {handle}"));
        }
    }
    // Table entries are compared by semantic values, excluding allocated handles.
    let mut before = serde_json::to_value(&document.layers).map_err(|e| e.to_string())?;
    let mut after = serde_json::to_value(&reopened.layers).map_err(|e| e.to_string())?;
    strip_table_handles(&mut before);
    strip_table_handles(&mut after);
    if !equivalent(&before, &after) {
        return Err("CAD round-trip changed layers".into());
    }
    // Preserve nongraphical content too: annotations may rely on styles,
    // named dictionaries, layouts, reactors and custom application data.
    // Reference handles inside objects are compared by resolved table name
    // where the acadrust 0.5.5 writer demonstrably persists only a name or
    // substitutes a documented default (see `normalize_auxiliary`).
    let before = auxiliary_image(document);
    let after = auxiliary_image(reopened);
    if !equivalent(&before, &after) {
        #[cfg(test)]
        eprintln!("Auxiliary before: {}\nAuxiliary after: {}", before, after);
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
    let line_type_names: HashMap<u64, &str> = document.line_types.iter().map(|entry| (entry.handle.value(), entry.name.as_str())).collect();
    let text_style_names: HashMap<u64, &str> = document.text_styles.iter().map(|entry| (entry.handle.value(), entry.name.as_str())).collect();
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
            map.remove("handle");
            map.remove("owner_handle");
            for value in map.values_mut() {
                strip_table_handles(value);
            }
        }
        Value::Array(values) => {
            for value in values {
                strip_table_handles(value);
            }
        }
        _ => {}
    }
}

#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "camelCase", deny_unknown_fields)]
enum Edit {
    AddLine { start: [f64; 3], end: [f64; 3], layer: String },
    AddCircle { center: [f64; 3], radius: f64, layer: String },
    AddArc {
        center: [f64; 3],
        radius: f64,
        #[serde(rename = "startAngle")]
        start_angle: f64,
        #[serde(rename = "endAngle")]
        end_angle: f64,
        layer: String,
    },
    AddLwPolyline {
        points: Vec<[f64; 2]>,
        #[serde(default)]
        closed: bool,
        layer: String,
    },
    AddText {
        position: [f64; 3],
        text: String,
        height: f64,
        layer: String,
    },
    Move { handle: String, delta: [f64; 3] },
    Copy { handle: String, delta: [f64; 3] },
    Rotate { handle: String, center: [f64; 3], angle: f64 },
    Scale { handle: String, center: [f64; 3], factor: f64 },
    Mirror { handle: String, axis: [[f64; 3]; 2] },
    SetText { handle: String, text: String },
    SetRadius { handle: String, radius: f64 },
    SetLayer { handle: String, layer: String },
    SetColor { handle: String, color: Option<i32> },
    SetLineWeight {
        handle: String,
        #[serde(rename = "lineWeight")]
        line_weight: Option<i32>,
    },
    Delete { handle: String },
    /// Trim a Line or Arc at its intersections with one boundary entity. The
    /// pick point selects the portion to remove; an interior pick that would
    /// split the entity is rejected.
    Trim { handle: String, boundary: String, pick: [f64; 3] },
    /// Extend a Line to the boundary intersection beyond the nearer endpoint.
    Extend { handle: String, boundary: String, pick: [f64; 3] },
    /// Offset a Line/Circle/Arc/open LWPolyline, creating a new entity.
    Offset { handle: String, distance: f64, side: [f64; 3] },
    AddDimension {
        kind: String,
        points: Vec<[f64; 3]>,
        layer: String,
        #[serde(default)]
        offset: Option<f64>,
        #[serde(default)]
        rotation: Option<f64>,
    },
    /// A native Leader polyline. Annotation text is deliberately not created;
    /// the engine does not fabricate text content.
    AddLeader { points: Vec<[f64; 3]>, layer: String },
    AddLayer {
        name: String,
        #[serde(default)]
        color: Option<i32>,
        #[serde(default, rename = "lineType")]
        line_type: Option<String>,
        #[serde(default, rename = "lineWeight")]
        line_weight: Option<i32>,
    },
    UpdateLayer {
        name: String,
        #[serde(default)]
        locked: Option<bool>,
        #[serde(default)]
        visible: Option<bool>,
        #[serde(default)]
        color: Option<i32>,
        #[serde(default, rename = "lineType")]
        line_type: Option<String>,
        #[serde(default, rename = "lineWeight")]
        line_weight: Option<i32>,
    },
    RenameLayer { from: String, to: String },
    DeleteLayer { name: String },
    /// One atomic pencil/ink stroke: all points become consecutive LINE
    /// segments on `FLOE_ANNOTATION` in a single document mutation and a single
    /// undo snapshot. No batch nesting is accepted, so the request cannot
    /// recurse or amplify work.
    AddStroke {
        points: Vec<[f64; 3]>,
        #[serde(default)]
        color: Option<i32>,
        #[serde(default, rename = "lineWeight")]
        line_weight: Option<i32>,
    },
    /// All-or-nothing bundle of edit operations; nested batches are rejected.
    Batch { operations: Vec<Edit> },
}

fn vector(value: [f64; 3]) -> Result<Vector3, String> {
    if !value.iter().all(|v| v.is_finite() && v.abs() <= 1e12) {
        return Err("Invalid CAD coordinate".into());
    }
    Ok(Vector3::new(value[0], value[1], value[2]))
}
fn point2(value: [f64; 3]) -> Result<P, String> {
    if !value[0].is_finite() || !value[1].is_finite() || value[0].abs() > 1e12 || value[1].abs() > 1e12 {
        return Err("Invalid CAD coordinate".into());
    }
    Ok(P::new(value[0], value[1]))
}
fn vector2(value: [f64; 2]) -> Result<Vector2, String> {
    if !value.iter().all(|v| v.is_finite() && v.abs() <= 1e12) {
        return Err("Invalid CAD coordinate".into());
    }
    Ok(Vector2::new(value[0], value[1]))
}
fn positive(value: f64) -> Result<f64, String> {
    if value.is_finite() && value > 0.0 && value <= 1e12 {
        Ok(value)
    } else {
        Err("Expected positive CAD dimension".into())
    }
}
fn fraction(value: f64) -> Result<f64, String> {
    if value.is_finite() && (1e-6..=1e6).contains(&value) {
        Ok(value)
    } else {
        Err("Expected a scale factor between 1e-6 and 1e6".into())
    }
}
fn text_value(value: String) -> Result<String, String> {
    if value.len() > 16_384 || value.contains('\0') {
        Err("CAD text limit".into())
    } else {
        Ok(value)
    }
}
fn handle(value: &str) -> Result<Handle, String> {
    u64::from_str_radix(value.trim_start_matches("0x").trim_start_matches("0X"), 16)
        .map(Handle::new)
        .map_err(|_| "Invalid CAD handle".into())
}
/// Entity types the editor claims to modify. Everything else is retained and
/// reported as read-only.
fn editable(entity: &EntityType) -> bool {
    matches!(
        entity,
        EntityType::Line(_) | EntityType::Circle(_) | EntityType::Arc(_) | EntityType::LwPolyline(_) | EntityType::Text(_)
    )
}

/// +Z extrusion on the Z=0 XY plane. Every geometry routine here reasons in
/// that plane, so a non-default OCS or a raised/sloped entity is refused
/// instead of silently projected onto Z=0.
const PLANE_EPSILON: f64 = 1e-9;

fn planar(entity: &EntityType) -> bool {
    fn is_z(normal: Vector3) -> bool {
        (normal.x.abs() <= PLANE_EPSILON) && (normal.y.abs() <= PLANE_EPSILON) && (normal.z - 1.0).abs() <= PLANE_EPSILON
    }
    fn at_zero(value: f64) -> bool {
        value.abs() <= PLANE_EPSILON
    }
    match entity {
        EntityType::Line(e) => is_z(e.normal) && at_zero(e.start.z) && at_zero(e.end.z),
        EntityType::Circle(e) => is_z(e.normal) && at_zero(e.center.z),
        EntityType::Arc(e) => is_z(e.normal) && at_zero(e.center.z),
        EntityType::Text(e) => {
            is_z(e.normal)
                && at_zero(e.insertion_point.z)
                && e.alignment_point.map_or(true, |p| at_zero(p.z))
        }
        EntityType::LwPolyline(e) => is_z(e.normal) && at_zero(e.elevation),
        _ => false,
    }
}

/// Model space only: paper-space or block-owned entities stay read-only, so
/// layout content is never edited as if it were the model.
fn model_space(document: &CadDocument, entity: &EntityType) -> bool {
    let common = entity.common();
    if common.entity_mode == Some(1) {
        return false;
    }
    common.owner_handle.is_null() || common.owner_handle == document.header.model_space_block_handle
}

/// A 2D XY coordinate for creation operations: finite and on the Z=0 plane.
fn planar_vector(value: [f64; 3]) -> Result<Vector3, String> {
    let point = vector(value)?;
    if point.z.abs() > PLANE_EPSILON {
        return Err("Only 2D XY (Z=0) coordinates are supported for this operation".into());
    }
    Ok(point)
}

fn finite_entity(entity: &EntityType) -> bool {
    fn vf(v: Vector3) -> bool {
        v.x.is_finite() && v.y.is_finite() && v.z.is_finite()
    }
    match entity {
        EntityType::Line(e) => vf(e.start) && vf(e.end),
        EntityType::Circle(e) => vf(e.center) && e.radius.is_finite(),
        EntityType::Arc(e) => vf(e.center) && e.radius.is_finite() && e.start_angle.is_finite() && e.end_angle.is_finite(),
        EntityType::LwPolyline(e) => e.vertices.iter().all(|v| v.location.x.is_finite() && v.location.y.is_finite()),
        EntityType::Text(e) => vf(e.insertion_point) && e.height.is_finite(),
        _ => true,
    }
}

/// ACI 1..=255 only. These carry an explicit index through DXF (code 62) and
/// DWG. ByLayer/ByBlock/None (0/256/257) and negative/out-of-range values are
/// not offered: omit `color` to inherit the layer's color.
fn stroke_color(value: Option<i32>) -> Result<Color, String> {
    match value {
        None => Ok(Color::ByLayer),
        Some(index) if (1..=255).contains(&index) => Ok(Color::from_index(index as i16)),
        Some(_) => Err("CAD stroke color must be an ACI index 1..=255".into()),
    }
}

fn aci_color(value: i32) -> Result<Color, String> {
    if (1..=255).contains(&value) {
        Ok(Color::from_index(value as i16))
    } else {
        Err("CAD color must be an ACI index 1..=255".into())
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

fn line_weight_value(value: Option<i32>) -> Result<LineWeight, String> {
    match value {
        None => Ok(LineWeight::ByLayer),
        Some(v) if (0..=i16::MAX as i32).contains(&v) && INDEXED_LINE_WEIGHTS.contains(&(v as i16)) => Ok(LineWeight::Value(v as i16)),
        Some(_) => Err("CAD lineWeight must be a canonical width in 1/100 mm".into()),
    }
}

fn valid_layer_name(name: &str) -> bool {
    !name.is_empty() && name.len() <= 255 && !name.contains('\0')
}

fn layer_exists(document: &CadDocument, name: &str) -> bool {
    document.layers.get(name).is_some()
}

/// The table's lookup is case-insensitive; return the stored spelling.
fn canonical_layer(document: &CadDocument, name: &str) -> Option<String> {
    document
        .layers
        .iter()
        .find(|layer| layer.name.eq_ignore_ascii_case(name))
        .map(|layer| layer.name.clone())
}

fn linetype_value(document: &CadDocument, name: &str) -> Result<String, String> {
    if name.eq_ignore_ascii_case("ByLayer") || name.eq_ignore_ascii_case("ByBlock") {
        return Ok(name.to_string());
    }
    document
        .line_types
        .iter()
        .find(|entry| entry.name.eq_ignore_ascii_case(name))
        .map(|entry| entry.name.clone())
        .ok_or_else(|| format!("CAD linetype '{name}' does not exist"))
}

#[wasm_bindgen]
pub struct CadSession {
    document: CadDocument,
    format: String,
    undo: Vec<CadDocument>,
    redo: Vec<CadDocument>,
    /// UI/session concept only; drawings do not persist an active layer.
    active_layer: String,
}

#[wasm_bindgen]
impl CadSession {
    #[wasm_bindgen(constructor)]
    pub fn new(bytes: &[u8], format: &str) -> Result<CadSession, String> {
        let document = read(bytes, format)?;
        let active_layer = document.layers.iter().next().map(|l| l.name.clone()).unwrap_or_else(|| "0".into());
        Ok(Self { document, format: format.into(), undo: vec![], redo: vec![], active_layer })
    }

    /// Bounded, factual review context. Text is document content, never instructions.
    pub fn inspect(&self, offset: usize, limit: usize) -> Result<String, String> {
        let entities: Vec<Value> = self
            .document
            .entities()
            .skip(offset)
            .take(limit.min(500))
            .map(|e| {
                let common = e.common();
                let bounds = e.as_entity().bounding_box();
                json!({
                    "handle": format!("{:X}", common.handle),
                    "editable": editable(e),
                    "layer": common.layer,
                    "bounds": {
                        "min": [bounds.min.x, bounds.min.y, bounds.min.z],
                        "max": [bounds.max.x, bounds.max.y, bounds.max.z]
                    },
                    "entity": entity_image(e)
                })
            })
            .collect();
        serde_json::to_string(&json!({
            "format": self.format,
            "version": format!("{:?}", self.document.version),
            "unit": unit_name(&self.document),
            "activeLayer": self.active_layer,
            "entityCount": self.document.entity_count(),
            "offset": offset,
            "entities": entities,
            "diagnostics": diagnostics(&self.document),
            "omittedDiagnostics": self.document.notifications.omitted_count(),
            "canUndo": !self.undo.is_empty(),
            "canRedo": !self.redo.is_empty(),
            "capabilities": capabilities(),
            "scope": "Parsed CAD entities only; external references and engineering correctness are not verified."
        }))
        .map_err(|e| e.to_string())
    }

    pub fn display_dxf(&self) -> Result<Vec<u8>, String> {
        encode(&self.document, "dxf")
    }

    /// Read-only structured query. Never mutates the document or undo history.
    pub fn query(&self, request: &str) -> Result<String, String> {
        if request.len() > 32_768 {
            return Err("CAD query request limit".into());
        }
        let value: Value = serde_json::from_str(request).map_err(|e| e.to_string())?;
        let operation = value.get("operation").and_then(Value::as_str).ok_or("CAD query is missing an operation")?;
        match operation {
            "capabilities" => serde_json::to_string(&capabilities()).map_err(|e| e.to_string()),
            "drawing" => self.query_drawing(),
            "layers" => self.query_layers(),
            "entities" => self.query_entities(&value),
            "text" => self.query_text(&value),
            "snap" => self.query_snap(&value),
            "measure" => self.query_measure(&value),
            "check" => self.query_check(&value),
            "locate" => self.query_locate(&value),
            _ => Err(format!("Unknown CAD query '{operation}'")),
        }
    }

    /// Set the session's active layer (not persisted to the drawing file).
    pub fn set_active_layer(&mut self, name: &str) -> Result<(), String> {
        let canonical = canonical_layer(&self.document, name).ok_or("Unknown CAD layer")?;
        self.active_layer = canonical;
        Ok(())
    }

    /// Apply one typed edit (or an atomic batch) to a clone of the document.
    /// Returns the JSON summary with handles created by the request. A failed
    /// operation leaves document, undo and redo untouched.
    pub fn edit(&mut self, request: &str) -> Result<String, String> {
        if request.len() > 32_768 {
            return Err("CAD edit request limit".into());
        }
        if blocking_diagnostics(&self.document) {
            return Err(format!(
                "This drawing has unresolved read diagnostics; editing is disabled: {:?}",
                diagnostics(&self.document)
            ));
        }
        let edit: Edit = serde_json::from_str(request).map_err(|e| e.to_string())?;
        let mut next = self.document.clone();
        let mut created = Vec::new();
        Self::apply(&mut next, edit, 0, &mut created, &self.format)?;
        if self.undo.len() == HISTORY {
            self.undo.remove(0);
        }
        self.undo.push(std::mem::replace(&mut self.document, next));
        self.redo.clear();
        serde_json::to_string(&json!({ "created": created })).map_err(|e| e.to_string())
    }

    pub fn undo(&mut self) -> bool {
        if let Some(previous) = self.undo.pop() {
            self.redo.push(std::mem::replace(&mut self.document, previous));
            true
        } else {
            false
        }
    }
    pub fn redo(&mut self) -> bool {
        if let Some(next) = self.redo.pop() {
            self.undo.push(std::mem::replace(&mut self.document, next));
            true
        } else {
            false
        }
    }

    /// Must succeed before offering bytes to the native compare-and-swap writer.
    pub fn save(&self) -> Result<Vec<u8>, String> {
        if blocking_diagnostics(&self.document) {
            return Err("Unresolved CAD diagnostics".into());
        }
        let bytes = encode(&self.document, &self.format)?;
        verify(&self.document, &read(&bytes, &self.format)?)?;
        Ok(bytes)
    }
}

impl CadSession {
    // ---------------------------------------------------------------- edits

    fn apply(document: &mut CadDocument, edit: Edit, depth: usize, created: &mut Vec<String>, format: &str) -> Result<(), String> {
        match edit {
            Edit::AddLine { start, end, layer } => {
                let mut e = Line::from_points(planar_vector(start)?, planar_vector(end)?);
                e.common.layer = layer;
                Self::add(document, EntityType::Line(e), created)?;
            }
            Edit::AddCircle { center, radius, layer } => {
                let mut e = Circle::from_center_radius(planar_vector(center)?, positive(radius)?);
                e.common.layer = layer;
                Self::add(document, EntityType::Circle(e), created)?;
            }
            Edit::AddArc { center, radius, start_angle, end_angle, layer } => {
                if !start_angle.is_finite() || !end_angle.is_finite() {
                    return Err("Invalid CAD arc angle".into());
                }
                let mut e = Arc::from_center_radius_angles(planar_vector(center)?, positive(radius)?, start_angle, end_angle);
                e.common.layer = layer;
                Self::add(document, EntityType::Arc(e), created)?;
            }
            Edit::AddLwPolyline { points, closed, layer } => {
                if !(2..=MAX_POLYLINE_POINTS).contains(&points.len()) {
                    return Err(format!("CAD polyline needs 2..={MAX_POLYLINE_POINTS} points"));
                }
                let mut e = LwPolyline::from_points(points.iter().map(|p| vector2(*p)).collect::<Result<Vec<_>, _>>()?);
                e.is_closed = closed;
                e.common.layer = layer;
                Self::add(document, EntityType::LwPolyline(e), created)?;
            }
            Edit::AddText { position, text, height, layer } => {
                let mut e = Text::with_value(text_value(text)?, planar_vector(position)?).with_height(positive(height)?);
                e.common.layer = layer;
                Self::add(document, EntityType::Text(e), created)?;
            }
            Edit::Move { handle: id, delta } => {
                let delta = vector(delta)?;
                let entity = Self::mutable(document, &id)?;
                if !editable(entity) {
                    return Err("Moving this entity is not supported".into());
                }
                entity.translate(delta);
                if !finite_entity(entity) {
                    return Err("CAD transform produced invalid geometry".into());
                }
            }
            Edit::Copy { handle: id, delta } => {
                let delta = vector(delta)?;
                let source = Self::mutable(document, &id)?.clone();
                if !editable(&source) {
                    return Err("Copying this entity is not supported".into());
                }
                let mut copy = source;
                copy.as_entity_mut().translate(delta);
                if !finite_entity(&copy) {
                    return Err("CAD transform produced invalid geometry".into());
                }
                Self::add(document, copy, created)?;
            }
            Edit::Rotate { handle: id, center, angle } => {
                if !angle.is_finite() || angle.abs() > 1e6 {
                    return Err("Invalid CAD rotation angle".into());
                }
                let center = vector(center)?;
                let entity = Self::mutable(document, &id)?;
                if !editable(entity) || !planar(entity) {
                    return Err("Rotating this entity or coordinate system is not supported".into());
                }
                entity.apply_transform(
                    &Transform::from_translation(-center)
                        .then(&Transform::from_rotation(Vector3::UNIT_Z, angle))
                        .then(&Transform::from_translation(center)),
                );
                if !finite_entity(entity) {
                    return Err("CAD transform produced invalid geometry".into());
                }
            }
            Edit::Scale { handle: id, center, factor } => {
                let factor = fraction(factor)?;
                let center = vector(center)?;
                let entity = Self::mutable(document, &id)?;
                if !editable(entity) || !planar(entity) {
                    return Err("Scaling this entity or coordinate system is not supported".into());
                }
                entity.apply_scaling_with_origin(Vector3::new(factor, factor, factor), center);
                if !finite_entity(entity) {
                    return Err("CAD transform produced invalid geometry".into());
                }
            }
            Edit::Mirror { handle: id, axis } => {
                let a = vector(axis[0])?;
                let b = vector(axis[1])?;
                if a.distance(&b) <= 1e-12 {
                    return Err("CAD mirror axis needs two distinct points".into());
                }
                let entity = Self::mutable(document, &id)?;
                if !editable(entity) || !planar(entity) {
                    return Err("Mirroring this entity or coordinate system is not supported".into());
                }
                entity.apply_mirror(&Transform::from_mirror_line(a, b));
                if !finite_entity(entity) {
                    return Err("CAD transform produced invalid geometry".into());
                }
            }
            Edit::SetText { handle: id, text } => match Self::mutable(document, &id)? {
                EntityType::Text(e) => e.value = text_value(text)?,
                _ => return Err("Select a text entity".into()),
            },
            Edit::SetRadius { handle: id, radius } => match Self::mutable(document, &id)? {
                EntityType::Circle(e) => e.radius = positive(radius)?,
                EntityType::Arc(e) => e.radius = positive(radius)?,
                _ => return Err("Select a circle or arc".into()),
            },
            Edit::SetLayer { handle: id, layer } => {
                let target = canonical_layer(document, &layer).ok_or("Unknown CAD layer")?;
                if document.layers.get(&target).is_some_and(|l| l.is_locked()) {
                    return Err("CAD layer is locked".into());
                }
                let entity = Self::mutable(document, &id)?;
                entity.as_entity_mut().set_layer(target.clone());
            }
            Edit::SetColor { handle: id, color } => {
                let color = match color {
                    None => Color::ByLayer,
                    Some(index) => aci_color(index)?,
                };
                let entity = Self::mutable(document, &id)?;
                entity.as_entity_mut().set_color(color);
            }
            Edit::SetLineWeight { handle: id, line_weight } => {
                let weight = line_weight_value(line_weight)?;
                let entity = Self::mutable(document, &id)?;
                entity.as_entity_mut().set_line_weight(weight);
            }
            Edit::Delete { handle: id } => {
                let key = handle(&id)?;
                if !editable(Self::mutable(document, &id)?) {
                    return Err("Deleting this entity is not supported".into());
                }
                document.remove_entity(key);
            }
            Edit::Trim { handle: id, boundary, pick } => {
                let boundary_primitives = {
                    let boundary_entity = Self::read_only(document, &boundary)?;
                    if !model_space(document, boundary_entity) {
                        return Err("Only model-space boundaries are supported".into());
                    }
                    primitives_of(boundary_entity)?
                };
                let pick = point2(pick)?;
                let target = Self::mutable(document, &id)?;
                if !planar(target) {
                    return Err("Trimming this coordinate system is not supported".into());
                }
                trim_entity(target, &boundary_primitives, pick)?;
            }
            Edit::Extend { handle: id, boundary, pick } => {
                let boundary_primitives = {
                    let boundary_entity = Self::read_only(document, &boundary)?;
                    if !model_space(document, boundary_entity) {
                        return Err("Only model-space boundaries are supported".into());
                    }
                    primitives_of(boundary_entity)?
                };
                let pick = point2(pick)?;
                let target = Self::mutable(document, &id)?;
                if !planar(target) {
                    return Err("Extending this coordinate system is not supported".into());
                }
                extend_entity(target, &boundary_primitives, pick)?;
            }
            Edit::Offset { handle: id, distance, side } => {
                let distance = positive(distance)?;
                let side = point2(side)?;
                let source = Self::read_only(document, &id)?.clone();
                if !editable(&source) || !planar(&source) || !model_space(document, &source) {
                    return Err("Offsetting this entity or coordinate system is not supported".into());
                }
                let mut copy = offset_entity(&source, distance, side)?;
                copy.as_entity_mut().set_handle(Handle::NULL);
                Self::add(document, copy, created)?;
            }
            Edit::AddDimension { kind, points, layer, offset, rotation } => {
                let mut entity = build_dimension(&kind, &points, offset, rotation, format)?;
                entity.as_entity_mut().set_layer(layer.clone());
                Self::add(document, entity, created)?;
            }
            Edit::AddLeader { points, layer } => {
                if !(2..=256).contains(&points.len()) {
                    return Err("CAD leader needs 2..=256 vertices".into());
                }
                let vertices: Vec<Vector3> = points.iter().map(|p| planar_vector(*p)).collect::<Result<Vec<_>, _>>()?;
                let mut leader = Leader::from_vertices(vertices.clone());
                // DWG stores a dedicated origin: the pinned writer substitutes
                // the first vertex when the field is zero and the DWG reader
                // restores the stored point, so mirror the first vertex here.
                // DXF has no origin field and the pinned DXF reader leaves
                // `Leader::new()`'s zero; keeping that zero is what the strict
                // save gate re-reads, and the first vertex always remains the
                // semantic arrow/origin point of the path.
                if format != "dxf" {
                    leader.origin = vertices[0];
                }
                leader.common.layer = layer;
                Self::add(document, EntityType::Leader(leader), created)?;
            }
            Edit::AddLayer { name, color, line_type, line_weight } => {
                if !valid_layer_name(&name) {
                    return Err("Invalid CAD layer name".into());
                }
                if layer_exists(document, &name) {
                    return Err(format!("CAD layer '{name}' already exists"));
                }
                let color = match color {
                    None => Color::ByLayer,
                    Some(index) => aci_color(index)?,
                };
                let line_type = match line_type {
                    Some(value) => linetype_value(document, &value)?,
                    None => "Continuous".to_string(),
                };
                let line_weight = line_weight_value(line_weight)?;
                let mut layer = Layer::new(name);
                layer.color = color;
                layer.line_type = line_type;
                layer.line_weight = line_weight;
                document.layers.add(layer).map_err(|e| e.to_string())?;
            }
            Edit::UpdateLayer { name, locked, visible, color, line_type, line_weight } => {
                if locked.is_none() && visible.is_none() && color.is_none() && line_type.is_none() && line_weight.is_none() {
                    return Err("No CAD layer property to update".into());
                }
                let canonical = canonical_layer(document, &name).ok_or("Unknown CAD layer")?;
                let line_type = match line_type {
                    Some(value) => Some(linetype_value(document, &value)?),
                    None => None,
                };
                let color = match color {
                    Some(index) => Some(aci_color(index)?),
                    None => None,
                };
                let line_weight = match line_weight {
                    Some(value) => Some(line_weight_value(Some(value))?),
                    None => None,
                };
                let layer = document.layers.get_mut(&canonical).ok_or("Unknown CAD layer")?;
                if let Some(locked) = locked {
                    if locked {
                        layer.lock();
                    } else {
                        layer.unlock();
                    }
                }
                if let Some(visible) = visible {
                    if visible {
                        layer.turn_on();
                    } else {
                        layer.turn_off();
                    }
                }
                if let Some(color) = color {
                    layer.color = color;
                }
                if let Some(line_type) = line_type {
                    layer.line_type = line_type;
                }
                if let Some(line_weight) = line_weight {
                    layer.line_weight = line_weight;
                }
            }
            Edit::RenameLayer { from, to } => {
                if !valid_layer_name(&to) {
                    return Err("Invalid CAD layer name".into());
                }
                let canonical = canonical_layer(document, &from).ok_or("Unknown CAD layer")?;
                if canonical.eq_ignore_ascii_case("0") {
                    return Err("CAD layer 0 cannot be renamed".into());
                }
                if layer_exists(document, &to) {
                    return Err(format!("CAD layer '{to}' already exists"));
                }
                document.layers.rename(&canonical, to.clone()).map_err(|e| e.to_string())?;
                for entity in document.entities_mut() {
                    if entity.common().layer.eq_ignore_ascii_case(&canonical) {
                        entity.as_entity_mut().set_layer(to.clone());
                    }
                }
            }
            Edit::DeleteLayer { name } => {
                let canonical = canonical_layer(document, &name).ok_or("Unknown CAD layer")?;
                if canonical.eq_ignore_ascii_case("0") {
                    return Err("CAD layer 0 cannot be deleted".into());
                }
                if let Some(entity) = document.entities().find(|e| e.common().layer.eq_ignore_ascii_case(&canonical)) {
                    return Err(format!("CAD layer '{canonical}' is referenced by entity {:X}", entity.common().handle));
                }
                document.layers.remove(&canonical);
            }
            Edit::AddStroke { points, color, line_weight } => {
                Self::add_stroke(document, &points, color, line_weight)?;
                for entity in document.entities().filter(|e| e.common().layer == ANNOTATION_LAYER) {
                    created.push(format!("{:X}", entity.common().handle));
                }
            }
            Edit::Batch { operations } => {
                if depth > 0 {
                    return Err("Nested CAD batches are not supported".into());
                }
                if operations.is_empty() {
                    return Err("Empty CAD batch".into());
                }
                if operations.len() > MAX_BATCH_OPERATIONS {
                    return Err(format!("CAD batch limit is {MAX_BATCH_OPERATIONS} operations"));
                }
                if operations.iter().any(|op| matches!(op, Edit::AddStroke { .. } | Edit::Batch { .. })) {
                    return Err("CAD batches cannot contain addStroke or nested batches".into());
                }
                for operation in operations {
                    Self::apply(document, operation, depth + 1, created, format)?;
                }
            }
        }
        Ok(())
    }

    fn add(document: &mut CadDocument, mut entity: EntityType, created: &mut Vec<String>) -> Result<(), String> {
        if document.entity_count() >= MAX_ENTITIES {
            return Err("CAD entity limit".into());
        }
        let layer = document.layers.get(&entity.common().layer).ok_or("Unknown CAD layer")?;
        if layer.is_locked() {
            return Err("CAD layer is locked".into());
        }
        // Always allocate a fresh handle: clone-based adds (copy/offset) carry
        // the source handle and would otherwise collide in the document map.
        entity.as_entity_mut().set_handle(Handle::NULL);
        let handle = document.add_entity(entity).map_err(|e| e.to_string())?;
        created.push(format!("{handle:X}"));
        Ok(())
    }
    fn read_only<'a>(document: &'a CadDocument, id: &str) -> Result<&'a EntityType, String> {
        let key = handle(id)?;
        document.get_entity(key).ok_or_else(|| "CAD entity no longer exists".into())
    }
    fn mutable<'a>(document: &'a mut CadDocument, id: &str) -> Result<&'a mut EntityType, String> {
        let key = handle(id)?;
        let entity = document.get_entity(key).ok_or("CAD entity no longer exists")?;
        if !editable(entity) {
            return Err("This entity type is read-only in this engine".into());
        }
        if !model_space(document, entity) {
            return Err("Only model-space entities can be edited".into());
        }
        if document.layers.get(&entity.common().layer).is_some_and(|l| l.is_locked()) {
            return Err("CAD layer is locked".into());
        }
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
            document.layers.add(Layer::new(ANNOTATION_LAYER)).map_err(|e| format!("CAD annotation layer: {e}"))?;
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

    // --------------------------------------------------------------- queries

    fn query_drawing(&self) -> Result<String, String> {
        serde_json::to_string(&json!({
            "format": self.format,
            "version": format!("{:?}", self.document.version),
            "unit": unit_name(&self.document),
            "insertionUnits": self.document.header.insertion_units,
            "activeLayer": self.active_layer,
            "entityCount": self.document.entity_count(),
            "layerCount": self.document.layers.iter().count(),
            "blockCount": self.document.block_records.iter().count(),
            "diagnostics": diagnostics(&self.document),
            "omittedDiagnostics": self.document.notifications.omitted_count(),
            "editable": !blocking_diagnostics(&self.document),
            "scope": "Parsed model/paper entities only; external references are not resolved."
        }))
        .map_err(|e| e.to_string())
    }

    fn layer_rows(&self) -> Vec<Value> {
        let mut counts: HashMap<&str, usize> = HashMap::new();
        for entity in self.document.entities() {
            *counts.entry(entity.common().layer.as_str()).or_insert(0) += 1;
        }
        self.document
            .layers
            .iter()
            .map(|layer| {
                let color = match layer.color {
                    Color::ByLayer => "ByLayer".to_string(),
                    Color::None => "None".to_string(),
                    Color::ByBlock => "ByBlock".to_string(),
                    Color::Index(index) => format!("{index}"),
                    _ => format!("{:?}", layer.color),
                };
                let line_weight = match layer.line_weight {
                    LineWeight::ByLayer => "ByLayer".to_string(),
                    LineWeight::ByBlock => "ByBlock".to_string(),
                    LineWeight::Default => "Default".to_string(),
                    LineWeight::Value(value) => format!("{value}"),
                };
                json!({
                    "name": layer.name,
                    "color": color,
                    "lineType": layer.line_type,
                    "lineWeight": line_weight,
                    "locked": layer.is_locked(),
                    "visible": layer.is_visible(),
                    "frozen": layer.is_frozen(),
                    "entityCount": counts.get(layer.name.as_str()).copied().unwrap_or(0),
                    "active": layer.name.eq_ignore_ascii_case(&self.active_layer)
                })
            })
            .collect()
    }

    fn query_layers(&self) -> Result<String, String> {
        serde_json::to_string(&json!({"layers": self.layer_rows(), "activeLayer": self.active_layer})).map_err(|e| e.to_string())
    }

    fn filtered_rows(&self, value: &Value) -> Vec<Value> {
        let type_filter = value.get("type").and_then(Value::as_str);
        let layer_filter = value.get("layer").and_then(Value::as_str);
        let text_filter = value.get("text").and_then(Value::as_str).map(str::to_lowercase);
        let handle_filter: Option<Vec<String>> = value.get("handles").and_then(Value::as_array).and_then(|rows| {
            let names: Vec<String> = rows
                .iter()
                .filter_map(Value::as_str)
                .map(|s| s.trim_start_matches("0x").trim_start_matches("0X").to_ascii_uppercase())
                .collect();
            (!names.is_empty()).then_some(names)
        });
        let offset = value.get("offset").and_then(Value::as_u64).unwrap_or(0) as usize;
        let limit = value.get("limit").and_then(Value::as_u64).unwrap_or(100).min(MAX_QUERY_ROWS as u64) as usize;
        self.document
            .entities()
            .filter(|entity| {
                let common = entity.common();
                if let Some(kind) = type_filter {
                    if entity_kind(entity) != kind {
                        return false;
                    }
                }
                if let Some(layer) = layer_filter {
                    if !common.layer.eq_ignore_ascii_case(layer) {
                        return false;
                    }
                }
                if let Some(handles) = &handle_filter {
                    if !handles.contains(&format!("{:X}", common.handle)) {
                        return false;
                    }
                }
                if let Some(text) = &text_filter {
                    let value = match entity {
                        EntityType::Text(t) => t.value.to_lowercase(),
                        _ => String::new(),
                    };
                    if !value.contains(text) {
                        return false;
                    }
                }
                true
            })
            .skip(offset)
            .take(limit)
            .map(|e| {
                let common = e.common();
                let bounds = e.as_entity().bounding_box();
                json!({
                    "handle": format!("{:X}", common.handle),
                    "type": entity_kind(e),
                    "layer": common.layer,
                    "editable": editable(e),
                    "bounds": {"min": [bounds.min.x, bounds.min.y], "max": [bounds.max.x, bounds.max.y]},
                    "image": entity_image(e)
                })
            })
            .collect()
    }

    fn query_entities(&self, value: &Value) -> Result<String, String> {
        let rows = self.filtered_rows(value);
        let offset = value.get("offset").and_then(Value::as_u64).unwrap_or(0);
        let limit = value.get("limit").and_then(Value::as_u64).unwrap_or(100);
        let truncated = rows.len() as u64 >= limit && (offset + rows.len() as u64) < self.document.entity_count() as u64;
        serde_json::to_string(&json!({
            "entityCount": self.document.entity_count(),
            "offset": offset,
            "entities": rows,
            "truncated": truncated,
            "scope": "Paginated parsed entities; geometry JSON is the engine's entity image."
        }))
        .map_err(|e| e.to_string())
    }

    fn query_text(&self, value: &Value) -> Result<String, String> {
        let mut request = value.clone();
        if request.get("type").is_none() {
            request["type"] = Value::String("Text".into());
        }
        self.query_entities(&request)
    }

    fn query_snap(&self, value: &Value) -> Result<String, String> {
        let point = point2(
            value
                .get("point")
                .and_then(Value::as_array)
                .and_then(|row| {
                    if row.len() >= 2 {
                        Some([
                            row[0].as_f64().unwrap_or(f64::NAN),
                            row[1].as_f64().unwrap_or(f64::NAN),
                            row.get(2).and_then(Value::as_f64).unwrap_or(0.0),
                        ])
                    } else {
                        None
                    }
                })
                .ok_or("CAD snap needs a point")?,
        )?;
        let tolerance = value.get("tolerance").and_then(Value::as_f64).unwrap_or(0.0);
        let tolerance = if tolerance.is_finite() && tolerance > 0.0 { tolerance.min(1e9) } else { 1.0 };
        let kinds: Vec<String> = value
            .get("kinds")
            .and_then(Value::as_array)
            .map(|rows| rows.iter().filter_map(Value::as_str).map(str::to_string).collect())
            .unwrap_or_default();
        let wanted = |kind: &str| kinds.is_empty() || kinds.iter().any(|k| k.eq_ignore_ascii_case(kind));
        let mut candidates: Vec<Value> = Vec::new();
        let mut primitives: Vec<(String, Primitive)> = Vec::new();
        let mut scanned = 0usize;
        let mut non_planar_skipped = 0usize;
        for entity in self.document.entities() {
            if scanned >= MAX_SNAP_ENTITIES {
                break;
            }
            // Snapping must not offer a projected point for raised/sloped or
            // non-default OCS geometry.
            if !planar(entity) {
                non_planar_skipped += 1;
                continue;
            }
            let bounds = entity.as_entity().bounding_box();
            let near = point.x >= bounds.min.x - tolerance
                && point.x <= bounds.max.x + tolerance
                && point.y >= bounds.min.y - tolerance
                && point.y <= bounds.max.y + tolerance;
            if !near {
                continue;
            }
            scanned += 1;
            let handle_name = format!("{:X}", entity.common().handle);
            let layer = entity.common().layer.clone();
            let mut push = |kind: &str, p: P| {
                if wanted(kind) && p.distance(point) <= tolerance {
                    candidates.push(json!({
                        "kind": kind,
                        "point": [p.x, p.y],
                        "distance": p.distance(point),
                        "handle": handle_name,
                        "layer": layer
                    }));
                }
            };
            match entity {
                EntityType::Line(e) => {
                    let a = P::new(e.start.x, e.start.y);
                    let b = P::new(e.end.x, e.end.y);
                    push("endpoint", a);
                    push("endpoint", b);
                    push("midpoint", P::new((a.x + b.x) / 2.0, (a.y + b.y) / 2.0));
                    primitives.push((handle_name.clone(), Primitive::Segment { a, b }));
                }
                EntityType::Circle(e) => {
                    let c = P::new(e.center.x, e.center.y);
                    push("center", c);
                    primitives.push((handle_name.clone(), Primitive::Circle { c, r: e.radius }));
                }
                EntityType::Arc(e) => {
                    let c = P::new(e.center.x, e.center.y);
                    push("center", c);
                    let start = P::new(c.x + e.radius * e.start_angle.cos(), c.y + e.radius * e.start_angle.sin());
                    let end = P::new(c.x + e.radius * e.end_angle.cos(), c.y + e.radius * e.end_angle.sin());
                    let mid_angle = e.start_angle + norm_angle(e.end_angle - e.start_angle) / 2.0;
                    push("endpoint", start);
                    push("endpoint", end);
                    push("midpoint", P::new(c.x + e.radius * mid_angle.cos(), c.y + e.radius * mid_angle.sin()));
                    primitives.push((handle_name.clone(), Primitive::Arc { c, r: e.radius, start: e.start_angle, end: e.end_angle }));
                }
                EntityType::LwPolyline(e) => {
                    if e.vertices.iter().any(|v| v.bulge.abs() > 1e-12) {
                        continue;
                    }
                    let points: Vec<P> = e.vertices.iter().map(|v| P::new(v.location.x, v.location.y)).collect();
                    for p in &points {
                        push("endpoint", *p);
                    }
                    let count = if e.is_closed { points.len() } else { points.len().saturating_sub(1) };
                    for i in 0..count {
                        let a = points[i];
                        let b = points[(i + 1) % points.len()];
                        push("midpoint", P::new((a.x + b.x) / 2.0, (a.y + b.y) / 2.0));
                        primitives.push((handle_name.clone(), Primitive::Segment { a, b }));
                    }
                }
                EntityType::Text(e) => {
                    push("endpoint", P::new(e.insertion_point.x, e.insertion_point.y));
                }
                _ => {}
            }
        }
        if wanted("intersection") {
            let pairs = primitives.len().min(MAX_SNAP_ENTITIES);
            'outer: for i in 0..pairs {
                for j in (i + 1)..pairs {
                    for hit in intersections(&primitives[i].1, &primitives[j].1) {
                        if hit.distance(point) <= tolerance {
                            candidates.push(json!({
                                "kind": "intersection",
                                "point": [hit.x, hit.y],
                                "distance": hit.distance(point),
                                "handle": primitives[i].0,
                                "secondHandle": primitives[j].0,
                                "layer": ""
                            }));
                            if candidates.len() >= MAX_SNAP_RESULTS * 4 {
                                break 'outer;
                            }
                        }
                    }
                }
            }
        }
        candidates.sort_by(|a, b| {
            let da = a["distance"].as_f64().unwrap_or(f64::INFINITY);
            let db = b["distance"].as_f64().unwrap_or(f64::INFINITY);
            da.partial_cmp(&db)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a["kind"].as_str().unwrap_or("").cmp(b["kind"].as_str().unwrap_or("")))
                .then_with(|| a["handle"].as_str().unwrap_or("").cmp(b["handle"].as_str().unwrap_or("")))
        });
        candidates.truncate(MAX_SNAP_RESULTS);
        serde_json::to_string(&json!({"point": [point.x, point.y], "tolerance": tolerance, "candidates": candidates, "nonPlanarSkipped": non_planar_skipped})).map_err(|e| e.to_string())
    }

    fn query_measure(&self, value: &Value) -> Result<String, String> {
        let kind = value.get("kind").and_then(Value::as_str).ok_or("CAD measure needs a kind")?;
        let points: Vec<P> = value
            .get("points")
            .and_then(Value::as_array)
            .map(|rows| {
                rows.iter()
                    .map(|row| {
                        row.as_array()
                            .and_then(|coords| {
                                if coords.len() >= 2 {
                                    Some([coords[0].as_f64().unwrap_or(f64::NAN), coords[1].as_f64().unwrap_or(f64::NAN), 0.0])
                                } else {
                                    None
                                }
                            })
                            .map(point2)
                            .unwrap_or_else(|| Err("Invalid CAD measure point".into()))
                    })
                    .collect::<Result<Vec<_>, _>>()
            })
            .unwrap_or(Ok(vec![]))?;
        let handles: Vec<String> = value
            .get("handles")
            .and_then(Value::as_array)
            .map(|rows| rows.iter().filter_map(Value::as_str).map(str::to_string).collect())
            .unwrap_or_default();
        match kind {
            "distance" => {
                if points.len() == 2 {
                    let distance = points[0].distance(points[1]);
                    return serde_json::to_string(&json!({"kind": kind, "value": distance, "unit": unit_name(&self.document)})).map_err(|e| e.to_string());
                }
                if handles.len() == 2 {
                    let a = self.measure_primitive(&handles[0])?;
                    let b = self.measure_primitive(&handles[1])?;
                    let distance = primitive_distance(&a, &b).max(0.0);
                    return serde_json::to_string(&json!({"kind": kind, "value": distance, "unit": unit_name(&self.document), "entities": handles, "note": "minimum distance between the two entities"})).map_err(|e| e.to_string());
                }
                Err("CAD distance needs two points or two handles".into())
            }
            "angle" => {
                if points.len() == 3 {
                    let v = points[0];
                    let a = points[1].sub(v);
                    let b = points[2].sub(v);
                    let denominator = a.length() * b.length();
                    if denominator <= 1e-12 {
                        return Err("CAD angle needs distinct points".into());
                    }
                    let degrees = (a.dot(b) / denominator).clamp(-1.0, 1.0).acos().to_degrees();
                    return serde_json::to_string(&json!({"kind": kind, "value": degrees, "unit": "degrees"})).map_err(|e| e.to_string());
                }
                if handles.len() == 2 {
                    let direction = |id: &str| -> Result<P, String> {
                        let entity = CadSession::read_only(&self.document, id)?;
                        match entity {
                            EntityType::Line(e) => P::new(e.end.x - e.start.x, e.end.y - e.start.y)
                                .normalized()
                                .ok_or_else(|| "CAD line has zero length".into()),
                            _ => Err("CAD angle between handles needs two lines".into()),
                        }
                    };
                    let a = direction(&handles[0])?;
                    let b = direction(&handles[1])?;
                    let degrees = a.dot(b).clamp(-1.0, 1.0).acos().to_degrees();
                    return serde_json::to_string(&json!({"kind": kind, "value": degrees, "unit": "degrees", "entities": handles, "note": "angle between line directions"})).map_err(|e| e.to_string());
                }
                Err("CAD angle needs three points or two line handles".into())
            }
            "radius" => {
                if handles.len() != 1 {
                    return Err("CAD radius needs one circle or arc handle".into());
                }
                let entity = CadSession::read_only(&self.document, &handles[0])?;
                let radius = match entity {
                    EntityType::Circle(e) => e.radius,
                    EntityType::Arc(e) => e.radius,
                    _ => return Err("CAD radius needs a circle or arc".into()),
                };
                serde_json::to_string(&json!({"kind": kind, "value": radius, "unit": unit_name(&self.document), "entities": handles})).map_err(|e| e.to_string())
            }
            "perimeter" => {
                if handles.is_empty() {
                    return Err("CAD perimeter needs at least one handle".into());
                }
                let mut total = 0.0;
                for id in &handles {
                    let entity = CadSession::read_only(&self.document, id)?;
                    total += entity_length(entity)?;
                }
                serde_json::to_string(&json!({"kind": kind, "value": total, "unit": unit_name(&self.document), "entities": handles})).map_err(|e| e.to_string())
            }
            "area" => {
                if let Some(handle) = handles.first() {
                    let entity = CadSession::read_only(&self.document, handle)?;
                    let area = match entity {
                        EntityType::LwPolyline(e) if e.is_closed && planar(entity) => {
                            let points: Vec<P> = e.vertices.iter().map(|v| P::new(v.location.x, v.location.y)).collect();
                            let bulges: Vec<f64> = e.vertices.iter().map(|v| v.bulge).collect();
                            polyline_signed_area(&points, &bulges, true).abs()
                        }
                        EntityType::Circle(e) => std::f64::consts::PI * e.radius * e.radius,
                        _ => return Err("CAD area needs a closed LWPolyline, a circle or 3+ points".into()),
                    };
                    return serde_json::to_string(&json!({"kind": kind, "value": area, "unit": format!("square {}", unit_name(&self.document)), "entities": handles})).map_err(|e| e.to_string());
                }
                if points.len() >= 3 {
                    let mut area = 0.0;
                    for i in 0..points.len() {
                        let a = points[i];
                        let b = points[(i + 1) % points.len()];
                        area += a.cross(b);
                    }
                    return serde_json::to_string(&json!({"kind": kind, "value": area.abs() / 2.0, "unit": format!("square {}", unit_name(&self.document)), "note": "polygon through the given points"})).map_err(|e| e.to_string());
                }
                Err("CAD area needs one closed entity handle or 3+ points".into())
            }
            _ => Err(format!("Unknown CAD measure kind '{kind}'")),
        }
    }

    fn measure_primitive(&self, id: &str) -> Result<Primitive, String> {
        let entity = CadSession::read_only(&self.document, id)?;
        primitives_of(entity)?
            .into_iter()
            .next()
            .ok_or_else(|| "CAD entity has no measurable geometry".into())
    }

    fn query_check(&self, value: &Value) -> Result<String, String> {
        let tolerance = value.get("tolerance").and_then(Value::as_f64).unwrap_or(1e-6);
        let tolerance = if tolerance.is_finite() && tolerance > 0.0 { tolerance.min(1e6) } else { 1e-6 };
        let mut zero_length: Vec<String> = Vec::new();
        let mut open_contours: Vec<String> = Vec::new();
        let mut layer_usage: HashMap<String, usize> = HashMap::new();
        let mut lines: Vec<(String, P, P)> = Vec::new();
        let mut non_planar = 0usize;
        for entity in self.document.entities() {
            let common = entity.common();
            let id = format!("{:X}", common.handle);
            *layer_usage.entry(common.layer.clone()).or_insert(0) += 1;
            if !planar(entity) {
                non_planar += 1;
                continue;
            }
            match entity {
                EntityType::Line(e) => {
                    let a = P::new(e.start.x, e.start.y);
                    let b = P::new(e.end.x, e.end.y);
                    if a.distance(b) <= tolerance {
                        zero_length.push(id.clone());
                    }
                    lines.push((id, a, b));
                }
                EntityType::LwPolyline(e) => {
                    if !e.is_closed {
                        open_contours.push(id.clone());
                    }
                    let points: Vec<P> = e.vertices.iter().map(|v| P::new(v.location.x, v.location.y)).collect();
                    let count = if e.is_closed { points.len() } else { points.len().saturating_sub(1) };
                    for i in 0..count {
                        if points[i].distance(points[(i + 1) % points.len()]) <= tolerance && e.vertices[i].bulge.abs() <= 1e-12 {
                            zero_length.push(id.clone());
                            break;
                        }
                    }
                    for i in 0..count {
                        let a = points[i];
                        let b = points[(i + 1) % points.len()];
                        lines.push((id.clone(), a, b));
                    }
                }
                EntityType::Circle(e) => {
                    if e.radius <= tolerance {
                        zero_length.push(id.clone());
                    }
                }
                EntityType::Arc(e) => {
                    if e.radius <= tolerance {
                        zero_length.push(id.clone());
                    }
                }
                _ => {}
            }
        }
        let pairwise = self.document.entity_count() <= MAX_PAIRWISE_ENTITIES;
        let mut duplicates: Vec<Value> = Vec::new();
        let mut dangling: Vec<String> = Vec::new();
        if pairwise {
            // Dangling line endpoints: an endpoint not shared by another line
            // endpoint within tolerance. Chains that close are matched.
            for (id, a, b) in &lines {
                let matched = |p: P| lines.iter().any(|(other, c, d)| other != id && (p.distance(*c) <= tolerance || p.distance(*d) <= tolerance));
                if !matched(*a) || !matched(*b) {
                    dangling.push(id.clone());
                }
            }
            // Exact duplicates among simple entity types.
            let mut simple: Vec<(String, String)> = Vec::new();
            for entity in self.document.entities() {
                let id = format!("{:X}", entity.common().handle);
                let signature = match entity {
                    EntityType::Line(e) => {
                        let mut a = [e.start.x, e.start.y, e.start.z];
                        let mut b = [e.end.x, e.end.y, e.end.z];
                        let key = |v: [f64; 3]| {
                            let r = |x: f64| (x / tolerance.max(1e-9)).round() as i64;
                            (r(v[0]), r(v[1]), r(v[2]))
                        };
                        if key(a) > key(b) {
                            std::mem::swap(&mut a, &mut b);
                        }
                        format!("line:{:?}:{:?}", key(a), key(b))
                    }
                    EntityType::Circle(e) => {
                        let r = (e.radius / tolerance.max(1e-9)).round() as i64;
                        let cx = (e.center.x / tolerance.max(1e-9)).round() as i64;
                        let cy = (e.center.y / tolerance.max(1e-9)).round() as i64;
                        format!("circle:{cx}:{cy}:{r}")
                    }
                    EntityType::Text(e) => format!(
                        "text:{}:{}",
                        (e.insertion_point.x / tolerance.max(1e-9)).round() as i64,
                        e.value
                    ),
                    _ => continue,
                };
                simple.push((signature, id));
            }
            simple.sort();
            for pair in simple.windows(2) {
                if pair[0].0 == pair[1].0 && pair[0].1 != pair[1].1 {
                    duplicates.push(json!({"first": pair[0].1, "second": pair[1].1}));
                    if duplicates.len() >= 200 {
                        break;
                    }
                }
            }
        }
        serde_json::to_string(&json!({
            "tolerance": tolerance,
            "zeroLength": zero_length,
            "duplicates": duplicates,
            "layerUsage": layer_usage,
            "openContours": open_contours,
            "danglingEndpoints": dangling,
            "pairwiseChecks": pairwise,
            "nonPlanarSkipped": non_planar,
            "note": "Geometric consistency at the stated tolerance; not engineering certification."
        }))
        .map_err(|e| e.to_string())
    }

    fn query_locate(&self, value: &Value) -> Result<String, String> {
        let id = value.get("handle").and_then(Value::as_str).ok_or("CAD locate needs a handle")?;
        let entity = CadSession::read_only(&self.document, id)?;
        let bounds = entity.as_entity().bounding_box();
        let point = [(bounds.min.x + bounds.max.x) / 2.0, (bounds.min.y + bounds.max.y) / 2.0];
        serde_json::to_string(&json!({
            "handle": format!("{:X}", entity.common().handle),
            "type": entity_kind(entity),
            "layer": entity.common().layer,
            "point": point,
            "bounds": {"min": [bounds.min.x, bounds.min.y], "max": [bounds.max.x, bounds.max.y]},
            "editable": editable(entity)
        }))
        .map_err(|e| e.to_string())
    }
}

// --------------------------------------------------------------------- helpers

fn entity_kind(entity: &EntityType) -> &'static str {
    match entity {
        EntityType::Line(_) => "Line",
        EntityType::Circle(_) => "Circle",
        EntityType::Arc(_) => "Arc",
        EntityType::LwPolyline(_) => "LwPolyline",
        EntityType::Text(_) => "Text",
        EntityType::Leader(_) => "Leader",
        EntityType::Dimension(_) => "Dimension",
        EntityType::Point(_) => "Point",
        other => other.as_entity().entity_type(),
    }
}

fn entity_length(entity: &EntityType) -> Result<f64, String> {
    match entity {
        EntityType::Line(e) => Ok(e.start.distance(&e.end)),
        EntityType::Circle(e) => Ok(std::f64::consts::TAU * e.radius),
        EntityType::Arc(e) => {
            let sweep = norm_angle(e.end_angle - e.start_angle);
            Ok(sweep * e.radius)
        }
        EntityType::LwPolyline(e) => {
            if !planar(entity) {
                return Err("Only 2D XY (Z=0) polylines have a supported perimeter".into());
            }
            let points: Vec<P> = e.vertices.iter().map(|v| P::new(v.location.x, v.location.y)).collect();
            let bulges: Vec<f64> = e.vertices.iter().map(|v| v.bulge).collect();
            Ok(polyline_length(&points, &bulges, e.is_closed))
        }
        _ => Err("CAD entity has no supported length".into()),
    }
}

/// Convert editable entities into 2D primitives for intersection work.
/// LWPolylines with bulges are refused: trimming against an approximated arc
/// would silently change the drawing.
fn primitives_of(entity: &EntityType) -> Result<Vec<Primitive>, String> {
    if !planar(entity) {
        return Err("Only coplanar (+Z) entities are supported for this operation".into());
    }
    match entity {
        EntityType::Line(e) => Ok(vec![Primitive::Segment { a: P::new(e.start.x, e.start.y), b: P::new(e.end.x, e.end.y) }]),
        EntityType::Circle(e) => Ok(vec![Primitive::Circle { c: P::new(e.center.x, e.center.y), r: e.radius }]),
        EntityType::Arc(e) => Ok(vec![Primitive::Arc {
            c: P::new(e.center.x, e.center.y),
            r: e.radius,
            start: e.start_angle,
            end: e.end_angle,
        }]),
        EntityType::LwPolyline(e) => {
            if e.vertices.iter().any(|v| v.bulge.abs() > 1e-12) {
                return Err("Polylines with arc segments (bulges) are not supported for this operation".into());
            }
            let points: Vec<P> = e.vertices.iter().map(|v| P::new(v.location.x, v.location.y)).collect();
            let count = if e.is_closed { points.len() } else { points.len().saturating_sub(1) };
            Ok((0..count)
                .map(|i| Primitive::Segment { a: points[i], b: points[(i + 1) % points.len()] })
                .collect())
        }
        _ => Err("This entity type has no supported planar geometry".into()),
    }
}

/// Intersections of a target primitive with boundary primitives, expressed as
/// a parameter along the target (0..1 for lines, arc sweep parameter for arcs).
fn hit_points(target: &Primitive, boundaries: &[Primitive]) -> Vec<(f64, P)> {
    match target {
        Primitive::Segment { a, b } => {
            let mut hits: Vec<(f64, P)> = Vec::new();
            for boundary in boundaries {
                for point in intersections(target, boundary) {
                    if let Some(t) = geometry::projection_t(point, *a, *b) {
                        if (-1e-9..=1.0 + 1e-9).contains(&t) && !hits.iter().any(|(_, p)| p.distance(point) <= 1e-9) {
                            hits.push((t, point));
                        }
                    }
                }
            }
            hits.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
            hits
        }
        Primitive::Arc { c, start, end, .. } => {
            let sweep = norm_angle(*end - *start);
            let mut hits: Vec<(f64, P)> = Vec::new();
            for boundary in boundaries {
                for point in intersections(target, boundary) {
                    let angle = point.sub(*c).angle();
                    let t = norm_angle(angle - *start) / if sweep <= 1e-12 { 1.0 } else { sweep };
                    if (0.0..=1.0).contains(&t) && !hits.iter().any(|(_, p)| p.distance(point) <= 1e-9) {
                        hits.push((t, point));
                    }
                }
            }
            hits.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
            hits
        }
        _ => vec![],
    }
}

fn trim_entity(target: &mut EntityType, boundaries: &[Primitive], pick: P) -> Result<(), String> {
    match target {
        EntityType::Line(line) => {
            let a = P::new(line.start.x, line.start.y);
            let b = P::new(line.end.x, line.end.y);
            let hits = hit_points(&Primitive::Segment { a, b }, boundaries);
            if hits.is_empty() {
                return Err("No intersection between the entity and the boundary".into());
            }
            let pick_t = geometry::projection_t(pick, a, b).ok_or("CAD line has zero length")?;
            let lower = hits.iter().rev().find(|(t, _)| *t <= pick_t + 1e-9).cloned();
            let upper = hits.iter().find(|(t, _)| *t >= pick_t - 1e-9).cloned();
            match (lower, upper) {
                (Some((tl, _)), Some((tu, _))) if (tl - tu).abs() <= 1e-9 => {
                    return Err("Pick is on the boundary intersection; nothing to trim".into());
                }
                (Some(_), Some(_)) => {
                    // The pick lies between two intersections: trimming would
                    // split the line in two, which this engine does not do.
                    return Err("Trimming here would split the line; use two separate trims".into());
                }
                // The pick lies in the end segment: remove it.
                (Some((_, p)), None) => {
                    line.end = Vector3::new(p.x, p.y, line.end.z);
                }
                // The pick lies in the start segment: remove it.
                (None, Some((_, p))) => {
                    line.start = Vector3::new(p.x, p.y, line.start.z);
                }
                (None, None) => return Err("No usable intersection for trim".into()),
            }
            if line.start.distance(&line.end) <= 1e-9 {
                return Err("Trim would remove the entire line".into());
            }
            Ok(())
        }
        EntityType::Arc(arc) => {
            let c = P::new(arc.center.x, arc.center.y);
            let target = Primitive::Arc { c, r: arc.radius, start: arc.start_angle, end: arc.end_angle };
            let hits = hit_points(&target, boundaries);
            if hits.is_empty() {
                return Err("No intersection between the arc and the boundary".into());
            }
            let pick_angle = pick.sub(c).angle();
            let sweep = norm_angle(arc.end_angle - arc.start_angle);
            let pick_t = norm_angle(pick_angle - arc.start_angle) / if sweep <= 1e-12 { 1.0 } else { sweep };
            let lower = hits.iter().rev().find(|(t, _)| *t <= pick_t + 1e-9).cloned();
            let upper = hits.iter().find(|(t, _)| *t >= pick_t - 1e-9).cloned();
            match (lower, upper) {
                (Some((tl, _)), Some((tu, _))) if (tl - tu).abs() <= 1e-9 => {
                    return Err("Pick is on the boundary intersection; nothing to trim".into());
                }
                (Some(_), Some(_)) => {
                    return Err("Trimming here would split the arc; use two separate trims".into());
                }
                (Some((_, p)), None) => {
                    arc.end_angle = p.sub(c).angle();
                }
                (None, Some((_, p))) => {
                    arc.start_angle = p.sub(c).angle();
                }
                (None, None) => return Err("No usable intersection for trim".into()),
            }
            if norm_angle(arc.end_angle - arc.start_angle) <= 1e-9 {
                return Err("Trim would remove the entire arc".into());
            }
            Ok(())
        }
        _ => Err("Trim supports lines and arcs".into()),
    }
}

fn extend_entity(target: &mut EntityType, boundaries: &[Primitive], pick: P) -> Result<(), String> {
    let EntityType::Line(line) = target else {
        return Err("Extend supports lines".into());
    };
    let a = P::new(line.start.x, line.start.y);
    let b = P::new(line.end.x, line.end.y);
    let mut hits: Vec<(f64, P)> = Vec::new();
    for boundary in boundaries {
        match boundary {
            Primitive::Segment { a: c, b: d } => {
                if let Some(point) = line_line_intersection(a, b, *c, *d) {
                    let u = geometry::projection_t(point, *c, *d).unwrap_or(f64::NAN);
                    if u.is_finite() && (-1e-9..=1.0 + 1e-9).contains(&u) {
                        if let Some(t) = geometry::projection_t(point, a, b) {
                            hits.push((t, point));
                        }
                    }
                }
            }
            Primitive::Circle { c, r } => {
                for (t, point) in line_circle_intersections_infinite(a, b, *c, *r) {
                    hits.push((t, point));
                }
            }
            Primitive::Arc { c, r, start, end } => {
                for (t, point) in line_arc_intersections_infinite(a, b, *c, *r, *start, *end) {
                    hits.push((t, point));
                }
            }
        }
    }
    if hits.is_empty() {
        return Err("No intersection between the extended line and the boundary".into());
    }
    let pick_t = geometry::projection_t(pick, a, b).unwrap_or(0.5);
    let extend_start = pick_t <= 0.5;
    let candidate = if extend_start {
        hits.iter().filter(|(t, _)| *t < -1e-9).max_by(|x, y| x.0.partial_cmp(&y.0).unwrap_or(std::cmp::Ordering::Equal))
    } else {
        hits.iter().filter(|(t, _)| *t > 1.0 + 1e-9).min_by(|x, y| x.0.partial_cmp(&y.0).unwrap_or(std::cmp::Ordering::Equal))
    };
    let (_, point) = candidate.ok_or("No boundary intersection beyond that endpoint")?;
    if extend_start {
        line.start = Vector3::new(point.x, point.y, line.start.z);
    } else {
        line.end = Vector3::new(point.x, point.y, line.end.z);
    }
    Ok(())
}

fn offset_entity(source: &EntityType, distance: f64, side: P) -> Result<EntityType, String> {
    match source {
        EntityType::Line(e) => {
            let a = P::new(e.start.x, e.start.y);
            let b = P::new(e.end.x, e.end.y);
            let dir = b.sub(a).normalized().ok_or("CAD line has zero length")?;
            let normal = P::new(-dir.y, dir.x);
            let sign = if side.sub(a).dot(normal) >= 0.0 { 1.0 } else { -1.0 };
            let offset = normal.scale(distance * sign);
            let mut copy = e.clone();
            let start = a.add(offset);
            let end = b.add(offset);
            copy.start = Vector3::new(start.x, start.y, copy.start.z);
            copy.end = Vector3::new(end.x, end.y, copy.end.z);
            Ok(EntityType::Line(copy))
        }
        EntityType::Circle(e) => {
            let c = P::new(e.center.x, e.center.y);
            let outward = side.distance(c) >= e.radius;
            let radius = if outward { e.radius + distance } else { e.radius - distance };
            if radius <= 1e-9 {
                return Err("Offset collapses the circle".into());
            }
            let mut copy = e.clone();
            copy.radius = radius;
            Ok(EntityType::Circle(copy))
        }
        EntityType::Arc(e) => {
            let c = P::new(e.center.x, e.center.y);
            let outward = side.distance(c) >= e.radius;
            let radius = if outward { e.radius + distance } else { e.radius - distance };
            if radius <= 1e-9 {
                return Err("Offset collapses the arc".into());
            }
            let mut copy = e.clone();
            copy.radius = radius;
            Ok(EntityType::Arc(copy))
        }
        EntityType::LwPolyline(e) => {
            if e.is_closed {
                return Err("Offset of closed polylines is not supported yet".into());
            }
            if e.vertices.iter().any(|v| v.bulge.abs() > 1e-12) {
                return Err("Offset of polylines with arc segments is not supported yet".into());
            }
            let points: Vec<P> = e.vertices.iter().map(|v| P::new(v.location.x, v.location.y)).collect();
            let offset = offset_open_polyline(&points, distance, side).ok_or("Offset folds the polyline; reduce the distance")?;
            let mut copy = e.clone();
            copy.vertices = offset
                .iter()
                .map(|p| LwVertex::new(Vector2::new(p.x, p.y)))
                .collect();
            Ok(EntityType::LwPolyline(copy))
        }
        _ => Err("Offset supports lines, circles, arcs and open polylines".into()),
    }
}

fn build_dimension(kind: &str, points: &[[f64; 3]], offset: Option<f64>, rotation: Option<f64>, format: &str) -> Result<EntityType, String> {
    let p: Vec<Vector3> = points.iter().map(|v| planar_vector(*v)).collect::<Result<_, _>>()?;
    let offset_value = match offset {
        Some(value) if value.is_finite() && value.abs() <= 1e12 => Some(value),
        Some(_) => return Err("Invalid CAD dimension offset".into()),
        None => None,
    };
    let mut dimension = match (kind, p.as_slice()) {
        ("linear", [a, b]) => {
            let rotation = match rotation {
                Some(value) if value.is_finite() => value,
                Some(_) => return Err("Invalid CAD dimension rotation".into()),
                None => 0.0,
            };
            let mut dim = DimensionLinear::rotated(*a, *b, rotation);
            if let Some(offset) = offset_value {
                dim.set_offset(offset);
            }
            Dimension::Linear(dim)
        }
        ("aligned", [a, b]) => {
            let mut dim = DimensionAligned::new(*a, *b);
            if let Some(offset) = offset_value {
                dim.set_offset(offset);
            }
            Dimension::Aligned(dim)
        }
        ("angular", [v, a, b]) => Dimension::Angular2Ln(DimensionAngular2Ln::new(*v, *a, *b)),
        ("radius", [c, a]) => Dimension::Radius(DimensionRadius::new(*c, *a)),
        ("diameter", [a, b]) => Dimension::Diameter(DimensionDiameter::new(*a, *b)),
        ("linear" | "aligned", _) => return Err("CAD linear/aligned dimension needs two points".into()),
        ("angular", _) => return Err("CAD angular dimension needs a vertex and two points".into()),
        ("radius" | "diameter", _) => return Err("CAD radial dimension needs two points".into()),
        _ => return Err(format!("Unsupported CAD dimension kind '{kind}'")),
    };
    // The DWG writer persists the subtype's own definition point through the
    // common dimension data and the DWG reader restores it into both the
    // subtype and the base. The DXF reader calls `set_definition_point` for
    // the group-10 point for every kind except Radius, whose group 10 is the
    // centre, not the chord (`section_reader.rs`), and the DXF writer never
    // persists the base field separately. Mirror the subtype definition point
    // into the base only where the same-format reader reconstructs it, so the
    // strict round-trip gate compares equal values instead of the reader's
    // default.
    let dxf_radius = format == "dxf" && matches!(dimension, Dimension::Radius(_));
    if !dxf_radius {
        let definition = dimension_definition_point(&dimension);
        if let Some(base) = dimension_base_mut(&mut dimension) {
            base.definition_point = definition;
        }
    }
    Ok(EntityType::Dimension(dimension))
}

fn dimension_base_mut(dimension: &mut Dimension) -> Option<&mut acadrust::entities::DimensionBase> {
    Some(match dimension {
        Dimension::Aligned(dim) => &mut dim.base,
        Dimension::Linear(dim) => &mut dim.base,
        Dimension::Radius(dim) => &mut dim.base,
        Dimension::Diameter(dim) => &mut dim.base,
        Dimension::Angular2Ln(dim) => &mut dim.base,
        _ => return None,
    })
}

fn dimension_definition_point(dimension: &Dimension) -> Vector3 {
    match dimension {
        Dimension::Aligned(dim) => dim.definition_point,
        Dimension::Linear(dim) => dim.definition_point,
        Dimension::Radius(dim) => dim.definition_point,
        Dimension::Diameter(dim) => dim.definition_point,
        Dimension::Angular2Ln(dim) => dim.definition_point,
        other => other.base().definition_point,
    }
}

#[cfg(test)]
mod tests;



