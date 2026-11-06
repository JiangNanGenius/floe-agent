// SPDX-License-Identifier: MPL-2.0
//! Read-only exact curve extraction from the retained native document.
use super::*;
use acadrust::types::Matrix3;
use serde::Deserialize;
use std::collections::HashSet;
use std::f64::consts::TAU;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    #[serde(default)]
    handles: Vec<String>,
    #[serde(default)]
    layers: Vec<String>,
    expected_revision: Option<u64>,
}

#[derive(Clone, Copy)]
struct Frame {
    x: Vector3,
    y: Vector3,
    n: Vector3,
    elevation: f64,
}
fn xyz(v: Vector3) -> [f64; 3] {
    [v.x, v.y, v.z]
}
impl Frame {
    fn new(normal: Vector3, point: Vector3) -> Result<Self, String> {
        let length = normal.length();
        if !length.is_finite() || length <= 1e-9 {
            return Err("Invalid OCS normal".into());
        }
        let n = normal * (1.0 / length);
        let basis = Matrix3::arbitrary_axis(n);
        Ok(Self {
            x: basis * Vector3::UNIT_X,
            y: basis * Vector3::UNIT_Y,
            n,
            elevation: n.dot(&point),
        })
    }
    fn point(self, p: Vector3) -> Result<[f64; 2], String> {
        vector(xyz(p))?;
        let tolerance = 1e-7_f64.max(64.0 * f64::EPSILON * (1.0 + p.length()));
        if (self.n.dot(&p) - self.elevation).abs() > tolerance {
            return Err("Entity is not on the selected source plane".into());
        }
        Ok([self.x.dot(&p), self.y.dot(&p)])
    }
    fn basis(self, normal: Vector3) -> Result<f64, String> {
        let dot = self.n.dot(&normal) / normal.length();
        if !dot.is_finite() || (dot.abs() - 1.0).abs() > 1e-7 {
            return Err("Entity OCS is not coplanar".into());
        }
        Ok(dot.signum())
    }
}
fn entity_frame(e: &EntityType) -> Result<Frame, String> {
    match e {
        EntityType::Line(v) => Frame::new(v.normal, v.start),
        EntityType::Circle(v) => Frame::new(v.normal, v.center_wcs()),
        EntityType::Arc(v) => Frame::new(v.normal, v.center_wcs()),
        EntityType::LwPolyline(v) => {
            Frame::new(v.normal, v.normal * (v.elevation / v.normal.length()))
        }
        EntityType::Polyline2D(v) => {
            Frame::new(v.normal, v.normal * (v.elevation / v.normal.length()))
        }
        _ => Err("This entity has no supported exact sketch curve".into()),
    }
}
fn segment(frame: Frame, a: Vector3, b: Vector3) -> Result<Value, String> {
    let start = frame.point(a)?;
    let end = frame.point(b)?;
    if a.distance(&b) <= 1e-9 {
        return Err("Zero-length line".into());
    }
    Ok(json!({"kind":"line", "start":start, "end":end}))
}
fn circular(
    frame: Frame,
    center: Vector3,
    normal: Vector3,
    radius: f64,
    start: Option<Vector3>,
    sweep: f64,
) -> Result<Value, String> {
    positive(radius)?;
    let c = frame.point(center)?;
    let sign = frame.basis(normal)?;
    if let Some(start) = start {
        let a = frame.point(start)?;
        if !sweep.is_finite() || sweep.abs() <= 1e-10 || sweep.abs() >= TAU - 1e-10 {
            return Err("Invalid or full-circle arc".into());
        }
        Ok(
            json!({"kind":"arc", "center":c,"radius":radius,"startAngle":(a[1]-c[1]).atan2(a[0]-c[0]),"sweepAngle":sweep*sign}),
        )
    } else {
        Ok(json!({"kind":"circle", "center":c,"radius":radius}))
    }
}
fn polyline(
    frame: Frame,
    normal: Vector3,
    elevation: f64,
    points: &[(f64, f64, f64)],
    closed: bool,
) -> Result<Vec<Value>, String> {
    if points.len() < 2 || points.len() > MAX_ENTITIES {
        return Err("Polyline vertex limit".into());
    }
    let basis = Matrix3::arbitrary_axis(normal * (1.0 / normal.length()));
    let world = |x: f64, y: f64| basis * Vector3::new(x, y, elevation);
    let mut curves = Vec::new();
    for i in 0..points.len() - usize::from(!closed) {
        let (ax, ay, bulge) = points[i];
        let (bx, by, _) = points[(i + 1) % points.len()];
        let a = world(ax, ay);
        let b = world(bx, by);
        if !bulge.is_finite() {
            return Err("Invalid bulge".into());
        }
        if bulge == 0.0 {
            curves.push(segment(frame, a, b)?);
        } else {
            let chord_x = bx - ax;
            let chord_y = by - ay;
            let k = (1.0 - bulge * bulge) / (4.0 * bulge);
            let c = world((ax + bx) * 0.5 - chord_y * k, (ay + by) * 0.5 + chord_x * k);
            curves.push(circular(
                frame,
                c,
                normal,
                a.distance(&c),
                Some(a),
                4.0 * bulge.atan(),
            )?);
        }
    }
    Ok(curves)
}
fn extract(frame: Frame, e: &EntityType) -> Result<Vec<Value>, String> {
    match e {
        EntityType::Line(v) if v.thickness == 0.0 => Ok(vec![segment(frame, v.start, v.end)?]),
        EntityType::Circle(v) if v.thickness == 0.0 => Ok(vec![circular(
            frame,
            v.center_wcs(),
            v.normal,
            v.radius,
            None,
            TAU,
        )?]),
        EntityType::Arc(v) if v.thickness == 0.0 => Ok(vec![circular(
            frame,
            v.center_wcs(),
            v.normal,
            v.radius,
            Some(v.start_point_wcs()),
            v.sweep_angle(),
        )?]),
        EntityType::LwPolyline(v)
            if v.thickness == 0.0
                && v.constant_width == 0.0
                && v.vertices
                    .iter()
                    .all(|p| p.start_width == 0.0 && p.end_width == 0.0) =>
        {
            polyline(
                frame,
                v.normal,
                v.elevation,
                &v.vertices
                    .iter()
                    .map(|p| (p.location.x, p.location.y, p.bulge))
                    .collect::<Vec<_>>(),
                v.is_closed,
            )
        }
        EntityType::Polyline2D(v)
            if v.thickness == 0.0
                && v.start_width == 0.0
                && v.end_width == 0.0
                && v.flags.bits() & !129 == 0
                && v.vertices.iter().all(|p| {
                    p.start_width == 0.0
                        && p.end_width == 0.0
                        && p.flags.bits() == 0
                        && p.location.z.abs() <= 1e-9
                }) =>
        {
            polyline(
                frame,
                v.normal,
                v.elevation,
                &v.vertices
                    .iter()
                    .map(|p| (p.location.x, p.location.y, p.bulge))
                    .collect::<Vec<_>>(),
                v.flags.is_closed(),
            )
        }
        _ => Err(
            "Unsupported entity, fitted/width polyline, or nonzero thickness; original retained"
                .into(),
        ),
    }
}
pub(crate) fn transfer(
    document: &CadDocument,
    format: &str,
    revision: u64,
    request: &str,
) -> Result<String, String> {
    if request.len() > 256 * 1024 {
        return Err("Sketch transfer request limit".into());
    }
    let request: Request = serde_json::from_str(request).map_err(|e| e.to_string())?;
    if request.expected_revision.is_some_and(|r| r != revision) {
        return Err("Drawing draft changed; select the geometry again".into());
    }
    if blocking_diagnostics(document) {
        return Err("Resolve drawing diagnostics before transferring geometry".into());
    }
    if request.handles.len() > MAX_ENTITIES || request.layers.len() > 256 {
        return Err("Sketch selection limit".into());
    }
    let requested: HashSet<_> = request
        .handles
        .iter()
        .map(|h| handle(h))
        .collect::<Result<_, _>>()?;
    if requested.len() != request.handles.len() {
        return Err("Duplicate selection handle".into());
    }
    for h in &requested {
        if document.get_entity(*h).is_none() {
            return Err("Selected entity no longer exists".into());
        }
    }
    for layer in &request.layers {
        if canonical_layer(document, layer).is_none() {
            return Err("Unknown selected layer".into());
        }
    }
    let selected: Vec<_> = document
        .entities()
        .filter(|e| {
            (requested.is_empty() || requested.contains(&e.common().handle))
                && (request.layers.is_empty()
                    || request
                        .layers
                        .iter()
                        .any(|l| l.eq_ignore_ascii_case(&e.common().layer)))
        })
        .collect();
    let frame = selected
        .iter()
        .filter(|e| model_space(document, e))
        .find_map(|e| entity_frame(e).ok())
        .ok_or("No supported source sketch plane in this selection")?;
    let mut curves = Vec::new();
    let mut omissions = Vec::new();
    let mut handles = Vec::new();
    let mut layers = Vec::new();
    for e in selected {
        let h = format!("{:X}", e.common().handle);
        handles.push(h.clone());
        if !layers.contains(&e.common().layer) {
            layers.push(e.common().layer.clone());
        }
        let result = if model_space(document, e) {
            extract(frame, e)
        } else {
            Err("Block/layout content is not model-space sketch geometry".into())
        };
        match result {
            Ok(mut items)=> {for item in &mut items {item["handle"]=json!(h);item["layer"]=json!(e.common().layer);item["sourceEntityType"]=json!(entity_kind(e));item["ocs"]=json!({"normal":xyz(entity_frame(e)?.n),"elevation":entity_frame(e)?.elevation});} curves.extend(items);},
            Err(reason)=> omissions.push(json!({"handle":h,"entityType":entity_kind(e),"layer":e.common().layer,"reason":reason})),
        }
        if curves.len() > 40_000 {
            return Err("Sketch primitive limit".into());
        }
    }
    if curves.is_empty() {
        return Err("No supported coplanar curves in this selection".into());
    }
    let scale = match document.header.insertion_units {
        1 => Some(25.4),
        2 => Some(304.8),
        3 => Some(1609344.0),
        4 => Some(1.0),
        5 => Some(10.0),
        6 => Some(1000.0),
        7 => Some(1e6),
        8 => Some(0.0000254),
        9 => Some(0.0254),
        10 => Some(914.4),
        11 => Some(1e-7),
        12 => Some(1e-6),
        13 => Some(0.001),
        14 => Some(100.0),
        15 => Some(10000.0),
        16 => Some(100000.0),
        17 => Some(1e12),
        _ => None,
    };
    serde_json::to_string(&json!({"schemaVersion":1,"format":format,"drawingVersion":format!("{:?}",document.version),"draftRevision":revision,"insertionUnits":document.header.insertion_units,"unitName":unit_name(document),"unitScaleMM":scale,"selectedHandles":handles,"selectedLayers":layers,"sourcePlane":{"origin":xyz(frame.n*frame.elevation),"xAxis":xyz(frame.x),"yAxis":xyz(frame.y)},"curves":curves,"omissions":omissions})).map_err(|e|e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn session(doc: CadDocument) -> CadSession {
        CadSession {
            document: doc,
            format: "dxf".into(),
            undo: vec![],
            redo: vec![],
            active_layer: "0".into(),
            revision: 0,
            engineering_profile: false,
        }
    }
    #[test]
    fn sketch_transfer_ocs_bulge_units_and_omissions() {
        let mut doc = CadDocument::new();
        doc.header.insertion_units = 1;
        let mut poly = LwPolyline::new();
        poly.normal = Vector3::new(0., 1., 0.);
        poly.elevation = 7.;
        poly.vertices = vec![
            LwVertex::with_bulge(Vector2::new(0., 0.), 0.5),
            LwVertex::new(Vector2::new(10., 0.)),
        ];
        doc.add_entity(EntityType::LwPolyline(poly)).unwrap();
        doc.add_entity(EntityType::Text(Text::with_value(
            "retain original",
            Vector3::ZERO,
        )))
        .unwrap();
        let session = session(doc);
        let before = session.inspect(0, 100).unwrap();
        let value: Value = serde_json::from_str(&session.transfer_sketch("{}").unwrap()).unwrap();
        assert_eq!(value["unitScaleMM"], 25.4);
        assert_eq!(value["curves"][0]["kind"], "arc");
        assert!(
            (value["curves"][0]["sweepAngle"].as_f64().unwrap() - 4. * 0.5_f64.atan()).abs()
                < 1e-12
        );
        assert_eq!(value["sourcePlane"]["origin"], json!([0., 7., 0.]));
        assert_eq!(value["omissions"].as_array().unwrap().len(), 1);
        assert_eq!(before, session.inspect(0, 100).unwrap());
    }
    #[test]
    fn sketch_transfer_stale_or_missing_selection_is_atomic() {
        let mut doc = CadDocument::new();
        doc.add_entity(EntityType::Line(Line::from_coords(0., 0., 0., 5., 0., 0.)))
            .unwrap();
        let mut s = session(doc);
        assert!(s.transfer_sketch(r#"{"handles":["FFFFFFFF"]}"#).is_err());
        s.edit(r#"{"operation":"addLine","start":[0,0,0],"end":[0,5,0],"layer":"0"}"#)
            .unwrap();
        assert!(s.transfer_sketch(r#"{"expectedRevision":0}"#).is_err());
        assert!(s.undo());
        assert!(s.transfer_sketch(r#"{"expectedRevision":1}"#).is_err());
        let result: Value = serde_json::from_str(&s.transfer_sketch("{}").unwrap()).unwrap();
        assert!(result["unitScaleMM"].is_null());
    }
    #[test]
    fn sketch_transfer_native_drawing_dwg_export_edit_reopen() {
        let bytes = crate::drawing_export::fixture();
        let source = CadSession::new(&bytes, "dxf").unwrap();
        let before = source.inspect(0, 100).unwrap();
        assert!(source.engineering_profile);
        let dwg = source.export_drawing_dwg().unwrap();
        assert!(dwg.starts_with(b"AC1032"));
        assert_eq!(before, source.inspect(0, 100).unwrap());
        let mut target = CadSession::new(&dwg, "dwg").unwrap();
        let h = format!(
            "{:X}",
            target
                .document
                .entities()
                .find(|e| matches!(e, EntityType::Line(_)))
                .unwrap()
                .common()
                .handle
        );
        target
            .edit(&json!({"operation":"move","handle":h,"delta":[3,4,0]}).to_string())
            .unwrap();
        assert!(target.undo());
        assert!(target.redo());
        let saved = target.save().unwrap();
        let reopened = CadSession::new(&saved, "dwg").unwrap();
        assert_eq!(reopened.document.header.insertion_units, 4);
        let transfer: Value = serde_json::from_str(
            &reopened
                .transfer_sketch(&json!({"handles":[h]}).to_string())
                .unwrap(),
        )
        .unwrap();
        assert_eq!(transfer["curves"][0]["start"], json!([3., 4.]));
        let out = std::env::var("FLOE_CAD_TRANSFER_EVIDENCE").ok();
        if let Some(out) = out {
            std::fs::create_dir_all(&out).unwrap();
            std::fs::write(format!("{out}/drawing-original.dxf"), bytes).unwrap();
            std::fs::write(format!("{out}/drawing-converted.dwg"), dwg).unwrap();
            std::fs::write(format!("{out}/drawing-edited.dwg"), saved).unwrap();
        }
    }
}
