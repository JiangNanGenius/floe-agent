// SPDX-License-Identifier: MPL-2.0
//! In-place native annotations and bounded native DIMASSOC propagation.
//! No relationship is inferred or replaced by Floe metadata.
use super::*;
use acadrust::objects::{AssociativeData, AssocDimensionReference, ObjectType};
use std::collections::HashSet;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct DimensionAnnotationEdit {
    pub text: Option<String>,
    pub text_position: Option<[f64; 3]>,
    pub line_position: Option<[f64; 3]>,
    pub text_rotation_degrees: Option<f64>,
}

fn supported_dimension(d: &Dimension) -> bool {
    matches!(d, Dimension::Linear(_) | Dimension::Aligned(_))
        && d.base().normal.distance(&Vector3::UNIT_Z) <= PLANE_EPSILON
}

pub(super) fn dimension_editable(d: &Dimension) -> bool {
    supported_dimension(d) && cache_name_supported(&d.base().block_name)
}
fn cache_name_supported(name: &str) -> bool {
    name.is_empty() || ["*D", "*U"].iter().any(|prefix| name.strip_prefix(prefix)
        .is_some_and(|v| !v.is_empty() && v.chars().all(|c| c.is_ascii_digit())))
}

pub(super) fn prepare_dimension(document: &CadDocument, id: Handle) -> Result<(), String> {
    let entity = document.get_entity(id).ok_or("The dimension no longer exists")?;
    let EntityType::Dimension(d) = entity else { return Err("Select a dimension".into()); };
    if !dimension_editable(d) || !model_space(document, entity) {
        return Err("This dimension or its custom geometry is read only".into());
    }
    if document.layers.get(&entity.common().layer).is_some_and(|l| l.is_locked()) {
        return Err("CAD layer is locked".into());
    }
    // Context/constraint networks need more than updating the native DIMASSOC.
    for object in document.objects.values() {
        if let ObjectType::Associative(a) = object {
            if a.references_handle(id) && !matches!(&a.data, AssociativeData::DimensionAssociation(v) if v.dimension == id) {
                return Err("This dimension has an unsupported constraint relationship".into());
            }
        }
    }
    if entity.common().xdictionary_handle.is_some()
        || entity.common().graphic_data.as_ref().is_some_and(|v|!v.is_empty())
        || !entity.common().extended_data.is_empty()
        || !entity.common().extended_data.raw_dwg_eed.is_empty()
        || entity.common().reactors.iter().any(|r| !matches!(document.objects.get(r),
            Some(ObjectType::Associative(a)) if matches!(&a.data,AssociativeData::DimensionAssociation(v) if v.dimension==id))) {
        return Err("This dimension has an unsupported annotation context".into());
    }
    Ok(())
}

fn finish_dimension(d: &mut Dimension, format: &str) {
    // Invalidate only the reference to an anonymous display cache. The original
    // block and every owned entity stay intact in the drawing. A native CAD
    // reader regenerates geometry from the dimension definition, rather than
    // displaying stale text/arrows from the old cache (DXF omits group 2).
    d.base_mut().block_name.clear();
    if !(format == "dxf" && matches!(d, Dimension::Radius(_))) {
        let definition = dimension_definition_point(d);
        d.base_mut().definition_point = definition;
    }
    // Both native readers restore text, not the in-memory user_text alias.
    // Persist the exact native field; the strict gate remains unchanged.
    d.base_mut().user_text = None;
    let measurement = d.measurement();
    d.base_mut().actual_measurement = measurement;
}

pub(super) fn update_dimension(document: &mut CadDocument, id: Handle,
    change: DimensionAnnotationEdit, format: &str) -> Result<(), String> {
    prepare_dimension(document, id)?;
    if change.text.is_none() && change.text_position.is_none()
        && change.line_position.is_none() && change.text_rotation_degrees.is_none() {
        return Err("Choose a dimension setting to change".into());
    }
    let EntityType::Dimension(d) = document.get_entity_mut(id).unwrap() else { unreachable!() };
    if let Some(text) = change.text {
        let text = text_value(text)?;
        d.base_mut().set_text_override(if text.is_empty() { None } else { Some(text) });
    }
    if let Some(position) = change.line_position {
        let p = planar_vector(position)?;
        match d {
            Dimension::Linear(v) => v.definition_point = p,
            Dimension::Aligned(v) => v.definition_point = p,
            _ => return Err("Dimension-line placement requires a linear or aligned dimension".into()),
        }
    }
    if let Some(position) = change.text_position {
        let p = planar_vector(position)?;
        let base = d.base_mut();
        base.text_middle_point = p;
        base.text_user_positioned = true;
        if format != "dxf" { base.dwg_flags_byte |= 1; }
    }
    if let Some(degrees) = change.text_rotation_degrees {
        if !degrees.is_finite() || degrees.abs() > 1e6 { return Err("Enter a valid text angle".into()); }
        d.base_mut().text_rotation = degrees.to_radians();
    }
    finish_dimension(d, format);
    Ok(())
}

pub(super) fn leader_editable(v: &Leader) -> bool {
    v.annotation_handle.is_null() && v.common.reactors.is_empty() && v.common.xdictionary_handle.is_none()
        && v.common.extended_data.is_empty() && v.common.extended_data.raw_dwg_eed.is_empty()
        && !v.common.graphic_data.as_ref().is_some_and(|v|!v.is_empty())
        && v.normal.distance(&Vector3::UNIT_Z) <= PLANE_EPSILON
        && v.vertices.iter().all(|p|p.z.abs() <= PLANE_EPSILON)
}

pub(super) fn update_leader(document: &mut CadDocument, id: Handle,
    points: Vec<[f64; 3]>, format: &str) -> Result<(), String> {
    if !(2..=256).contains(&points.len()) { return Err("A leader needs two to 256 points".into()); }
    let vertices = points.into_iter().map(planar_vector).collect::<Result<Vec<_>, _>>()?;
    let entity = document.get_entity(id).ok_or("The leader no longer exists")?;
    if !model_space(document, entity) || document.layers.get(&entity.common().layer).is_some_and(|l| l.is_locked()) {
        return Err("This leader or its layer is read only".into());
    }
    let EntityType::Leader(v) = entity else { return Err("Select a leader".into()); };
    if !leader_editable(v) {
        return Err("This leader has an attached annotation or unsupported drawing plane; its points are read only".into());
    }
    let EntityType::Leader(v) = document.get_entity_mut(id).unwrap() else { unreachable!() };
    v.vertices = vertices;
    if format != "dxf" { v.origin = v.vertices[0]; }
    Ok(())
}

fn geometry_image(e: &EntityType) -> Value {
    match e {
        EntityType::Line(v) => json!([v.start,v.end,v.normal]),
        EntityType::Circle(v) => json!([v.center,v.radius,v.normal]),
        EntityType::Arc(v) => json!([v.center,v.radius,v.start_angle,v.end_angle,v.normal]),
        EntityType::LwPolyline(v) => json!([v.vertices,v.elevation,v.normal,v.is_closed]),
        _ => Value::Null,
    }
}

fn near(a: Vector3, b: Vector3) -> bool { a.distance(&b) <= 1e-7 }

/// Resolve the *old* endpoint uniquely before following the same endpoint in
/// the new geometry. Xrefs/chains/intersections/subentity markers are retained
/// but deliberately not rebound. An ambiguous or stale reference fails closed.
fn resolve(reference: &AssocDimensionReference, before: &CadDocument,
    after: &CadDocument) -> Result<Vector3, String> {
    if reference.class_name != "AcDbOsnapPointRef" || reference.xrefs.len() != 1
        || !reference.xref_paths.is_empty() || !reference.intersection_objects.is_empty()
        || !reference.intersection_xref_paths.is_empty() || reference.has_last_point_reference
        || ![0,1].contains(&reference.main_subent_type) || reference.main_gs_marker != 0
        || reference.intersection_subent_type != 0 || reference.intersection_gs_marker != 0 {
        return Err("This dimension has a chained, external or unsupported reference".into());
    }
    let key = reference.xrefs[0];
    let old = before.get_entity(key).ok_or("The dimension source is missing")?;
    let new = after.get_entity(key).ok_or("A dimension still depends on this geometry; deletion is unavailable")?;
    let p = match (old, new, reference.osnap_type) {
        (EntityType::Line(a), EntityType::Line(b), 1) if planar(old) && planar(new) => {
            match (near(reference.osnap_point, a.start), near(reference.osnap_point, a.end)) {
                (true,false) => b.start,
                (false,true) => b.end,
                _ => return Err("The dimension endpoint reference is ambiguous or stale".into()),
            }
        }
        (EntityType::Line(a), EntityType::Line(b), 2) if planar(old) && planar(new)
            && near(reference.osnap_point, (a.start+a.end)*0.5) => (b.start+b.end)*0.5,
        (EntityType::Circle(a), EntityType::Circle(b), 3) if planar(old) && planar(new)
            && near(reference.osnap_point,a.center) => b.center,
        _ => return Err("This dimension reference cannot follow the requested geometry edit".into()),
    };
    Ok(p)
}

/// Run once over the final cloned candidate, so geometry, annotation, native
/// relationship objects and history commit together, including atomic batches.
pub(super) fn synchronize(before: &CadDocument, after: &mut CadDocument, format: &str) -> Result<(), String> {
    let changed: HashSet<Handle> = before.entities().filter_map(|e| {
        let old = geometry_image(e);
        if old.is_null() { return None; }
        let key = e.common().handle;
        if after.get_entity(key).is_none_or(|v| geometry_image(v) != old) { Some(key) } else { None }
    }).collect();
    if changed.is_empty() { return Ok(()); }
    for id in &changed {
        let common = before.get_entity(*id).unwrap().common();
        if common.xdictionary_handle.is_some() || !common.extended_data.is_empty()
            || !common.extended_data.raw_dwg_eed.is_empty()
            || common.graphic_data.as_ref().is_some_and(|v|!v.is_empty()) || common.reactors.iter().any(|r| !matches!(before.objects.get(r),
            Some(ObjectType::Associative(a)) if matches!(a.data,AssociativeData::DimensionAssociation(_)))) {
            return Err("This geometry has an unsupported attached relationship".into());
        }
    }
    let mut updates = Vec::new();
    let mut dimensions = HashSet::new();
    for (key, object) in &before.objects {
        let ObjectType::Associative(a) = object else { continue; };
        if !changed.iter().any(|h| a.references_handle(*h)) { continue; }
        let AssociativeData::DimensionAssociation(assoc) = &a.data else {
            return Err("This geometry has an unsupported constraint relationship".into());
        };
        if assoc.trans_space || assoc.associativity != 3 || assoc.rotated_type != 0
            || assoc.references[0].len()!=1 || assoc.references[1].len()!=1
            || !assoc.references[2].is_empty() || !assoc.references[3].is_empty()
            || !dimensions.insert(assoc.dimension) {
            return Err("Only unambiguous two-point dimension associations can follow this edit".into());
        }
        prepare_dimension(after, assoc.dimension)?;
        let old_dim = before.get_entity(assoc.dimension).ok_or("The associated dimension is missing")?;
        let EntityType::Dimension(old_dim) = old_dim else { return Err("Invalid dimension reference".into()); };
        let (old_a,old_b) = match old_dim {
            Dimension::Linear(d) => (d.first_point,d.second_point),
            Dimension::Aligned(d) => (d.first_point,d.second_point),
            _ => return Err("Associated geometry editing requires a linear or aligned dimension".into()),
        };
        if !near(old_a,assoc.references[0][0].osnap_point) || !near(old_b,assoc.references[1][0].osnap_point) {
            return Err("The dimension definition disagrees with its native references".into());
        }
        let points = [resolve(&assoc.references[0][0],before,after)?,resolve(&assoc.references[1][0],before,after)?];
        updates.push((*key,assoc.dimension,points));
    }
    for (key,dimension,points) in updates {
        let EntityType::Dimension(d) = after.get_entity_mut(dimension).unwrap() else { unreachable!() };
        match d {
            Dimension::Linear(v) => { v.first_point=points[0]; v.second_point=points[1]; }
            Dimension::Aligned(v) => { v.first_point=points[0]; v.second_point=points[1]; }
            _ => unreachable!(),
        }
        finish_dimension(d,format);
        let Some(ObjectType::Associative(a)) = after.objects.get_mut(&key) else { return Err("The dimension association was removed".into()); };
        let AssociativeData::DimensionAssociation(v) = &mut a.data else { unreachable!() };
        for (slot,p) in points.into_iter().enumerate() { v.references[slot][0].osnap_point=p; }
    }
    Ok(())
}
