//! Resolve loft database references into native embedded profiles and retain
//! application-level reference roles separately from the native curve bodies.

use super::dwg::dwg_version::DwgVersion;
use super::dwg::embedded_entity::{decode_embedded_entity, encode_embedded_entity};
use super::loft_parameters::{has_record, remove_record, writable_dictionary};
use crate::entities::{EmbeddedEntity, SurfaceData};
use crate::objects::{ObjectType, XRecord, XRecordEntry, XRecordValue};
use crate::types::DxfVersion;
use crate::{CadDocument, EntityType};

const KEY: &str = "CADCODEC_LOFT_CURVES_V1";
const REFERENCE_KEY: &str = "CADCODEC_LOFT_REFERENCES_V1";

pub(crate) fn has_inputs(document: &CadDocument) -> bool {
    document.entities().any(|entity| matches!(entity, EntityType::Surface(surface)
        if matches!(&surface.surface_data, SurfaceData::Lofted {
            cross_section_entities, guide_entities, path_entity, cross_sections, guide_curves, path_curve, ..
        } if !cross_section_entities.is_empty() || !guide_entities.is_empty() || path_entity.is_some()
            || !cross_sections.is_empty() || !guide_curves.is_empty() || path_curve.is_some()
            || has_record(document, surface.common.xdictionary_handle, KEY)
            || has_record(document, surface.common.xdictionary_handle, REFERENCE_KEY))))
}

pub(crate) fn store(document: &mut CadDocument) {
    store_references(document);
    let inputs = document
        .entities()
        .filter_map(|entity| {
            let EntityType::Surface(surface) = entity else {
                return None;
            };
            let SurfaceData::Lofted {
                cross_section_entities,
                guide_entities,
                path_entity,
                ..
            } = &surface.surface_data
            else {
                return None;
            };
            if cross_section_entities.is_empty()
                && guide_entities.is_empty()
                && path_entity.is_none()
                && !has_record(document, surface.common.xdictionary_handle, KEY)
            {
                return None;
            }
            Some((
                surface.common.handle,
                surface.common.xdictionary_handle,
                cross_section_entities.clone(),
                guide_entities.clone(),
                path_entity.clone(),
            ))
        })
        .collect::<Vec<_>>();
    for (handle, previous, sections, guides, path) in inputs {
        let mut dictionary = writable_dictionary(document, handle, previous);
        if let Some(entity) = document.get_entity_mut(handle) {
            entity.common_mut().xdictionary_handle = Some(dictionary.handle);
        }
        document.xdic_by_handle.insert(handle, dictionary.handle);
        if sections.is_empty() && guides.is_empty() && path.is_none() {
            remove_record(document, &mut dictionary, KEY);
            document
                .objects
                .insert(dictionary.handle, ObjectType::Dictionary(dictionary));
            continue;
        }
        let record_handle = dictionary
            .get(KEY)
            .filter(|handle| {
                matches!(document.objects.get(handle), Some(ObjectType::XRecord(record))
                if record.owner == dictionary.handle)
            })
            .unwrap_or_else(|| document.allocate_handle());
        let mut record = XRecord::named(KEY);
        record.handle = record_handle;
        record.owner = dictionary.handle;
        record.add_int32(90, 1);
        for (role, entity) in sections
            .iter()
            .map(|entity| (0, entity))
            .chain(guides.iter().map(|entity| (1, entity)))
            .chain(path.iter().map(|entity| (2, entity)))
        {
            let version =
                DwgVersion::from_dxf_version(DxfVersion::AC1032).expect("supported version");
            let body = encode_embedded_entity(entity, version, DxfVersion::AC1032);
            record.add_int16(70, role);
            record.add_int32(91, body.type_code);
            record.add_int32(92, body.bit_length as i32);
            for bytes in body.bytes.chunks(127) {
                record.add_entry(XRecordEntry::new(310, XRecordValue::Chunk(bytes.to_vec())));
            }
        }
        dictionary
            .entries
            .retain(|(key, _)| !key.eq_ignore_ascii_case(KEY));
        dictionary.add_entry(KEY, record_handle);
        dictionary.set_entry_hard_owner(KEY, true);
        document
            .objects
            .insert(record_handle, ObjectType::XRecord(record));
        document
            .objects
            .insert(dictionary.handle, ObjectType::Dictionary(dictionary));
    }
}

pub(crate) fn restore(document: &mut CadDocument) {
    restore_references(document);
    let inputs = document
        .entities()
        .filter_map(|entity| {
            let EntityType::Surface(surface) = entity else {
                return None;
            };
            let SurfaceData::Lofted {
                cross_section_entities,
                guide_entities,
                path_entity,
                ..
            } = &surface.surface_data
            else {
                return None;
            };
            // The native input group is authoritative when present. Mixing a stale
            // fallback with a modified native group can resurrect removed guides.
            if !cross_section_entities.is_empty()
                || !guide_entities.is_empty()
                || path_entity.is_some()
            {
                return None;
            }
            let ObjectType::Dictionary(dictionary) =
                document.objects.get(&surface.common.xdictionary_handle?)?
            else {
                return None;
            };
            let handle = dictionary.get(KEY)?;
            let ObjectType::XRecord(record) = document.objects.get(&handle)? else {
                return None;
            };
            Some((surface.common.handle, decode(record)?))
        })
        .collect::<Vec<_>>();
    for (handle, (sections, guides, path)) in inputs {
        if let Some(EntityType::Surface(surface)) = document.get_entity_mut(handle) {
            if let SurfaceData::Lofted {
                cross_section_entities,
                guide_entities,
                path_entity,
                ..
            } = &mut surface.surface_data
            {
                *cross_section_entities = sections;
                *guide_entities = guides;
                *path_entity = path;
            }
        }
    }
}

fn embedded_from_handle(document: &CadDocument, handle: crate::Handle) -> Option<EmbeddedEntity> {
    Some(match document.get_entity(handle)? {
        EntityType::Point(v) => EmbeddedEntity::Point(v.clone()),
        EntityType::Line(v) => EmbeddedEntity::Line(v.clone()),
        EntityType::Arc(v) => EmbeddedEntity::Arc(v.clone()),
        EntityType::Circle(v) => EmbeddedEntity::Circle(v.clone()),
        EntityType::Ellipse(v) => EmbeddedEntity::Ellipse(v.clone()),
        EntityType::Spline(v) => EmbeddedEntity::Spline(v.clone()),
        EntityType::LwPolyline(v) => EmbeddedEntity::LwPolyline(v.clone()),
        EntityType::Region(v) => EmbeddedEntity::Region(v.clone()),
        EntityType::Ray(v) => EmbeddedEntity::Ray(v.clone()),
        EntityType::XLine(v) => EmbeddedEntity::XLine(v.clone()),
        _ => return None,
    })
}

fn store_references(document: &mut CadDocument) {
    let surfaces: Vec<_> = document
        .entities()
        .filter_map(|entity| match entity {
            EntityType::Surface(surface)
                if matches!(surface.surface_data, SurfaceData::Lofted { .. }) =>
            {
                Some(surface.clone())
            }
            _ => None,
        })
        .collect();
    for surface in surfaces {
        let SurfaceData::Lofted {
            cross_sections,
            guide_curves,
            path_curve,
            ..
        } = &surface.surface_data
        else {
            unreachable!()
        };
        let owner = surface.common.handle;
        let previous = document.extension_dictionary_handle(owner);
        let has_references =
            !cross_sections.is_empty() || !guide_curves.is_empty() || path_curve.is_some();
        if !has_references && !has_record(document, previous, REFERENCE_KEY) {
            continue;
        }
        let sections = cross_sections
            .iter()
            .map(|h| embedded_from_handle(document, *h))
            .collect::<Option<Vec<_>>>();
        let guides = guide_curves
            .iter()
            .map(|h| embedded_from_handle(document, *h))
            .collect::<Option<Vec<_>>>();
        let path = path_curve.and_then(|h| embedded_from_handle(document, h));
        let mut dictionary = writable_dictionary(document, owner, previous);
        if let Some(EntityType::Surface(output)) = document.get_entity_mut(owner) {
            output.common.xdictionary_handle = Some(dictionary.handle);
            if let SurfaceData::Lofted {
                cross_section_entities,
                guide_entities,
                path_entity,
                ..
            } = &mut output.surface_data
            {
                if cross_section_entities.is_empty() {
                    *cross_section_entities = sections.unwrap_or_default();
                }
                if guide_entities.is_empty() {
                    *guide_entities = guides.unwrap_or_default();
                }
                if path_entity.is_none() {
                    *path_entity = path;
                }
            }
        }
        document.xdic_by_handle.insert(owner, dictionary.handle);
        if has_references {
            let mut record = XRecord::named(REFERENCE_KEY);
            record.handle = dictionary
                .get(REFERENCE_KEY)
                .filter(|h| {
                    matches!(document.objects.get(h), Some(ObjectType::XRecord(r)) if r.owner == dictionary.handle)
                })
                .unwrap_or_else(|| document.allocate_handle());
            record.owner = dictionary.handle;
            record.add_int32(90, 1);
            record.add_int32(91, cross_sections.len() as i32);
            record.add_int32(92, guide_curves.len() as i32);
            record.add_int32(93, i32::from(path_curve.is_some()));
            for handle in cross_sections
                .iter()
                .chain(guide_curves)
                .chain(path_curve.iter())
            {
                record.add_handle(330, *handle);
            }
            dictionary
                .entries
                .retain(|(name, _)| !name.eq_ignore_ascii_case(REFERENCE_KEY));
            dictionary.add_entry(REFERENCE_KEY, record.handle);
            dictionary.set_entry_hard_owner(REFERENCE_KEY, true);
            document
                .objects
                .insert(record.handle, ObjectType::XRecord(record));
        } else {
            remove_record(document, &mut dictionary, REFERENCE_KEY);
        }
        document
            .objects
            .insert(dictionary.handle, ObjectType::Dictionary(dictionary));
    }
}

fn restore_references(document: &mut CadDocument) {
    let references: Vec<_> = document
        .entities()
        .filter_map(|entity| {
            let EntityType::Surface(surface) = entity else {
                return None;
            };
            let SurfaceData::Lofted {
                cross_sections,
                guide_curves,
                path_curve,
                ..
            } = &surface.surface_data
            else {
                return None;
            };
            if !cross_sections.is_empty() || !guide_curves.is_empty() || path_curve.is_some() {
                return None;
            }
            let record = document.xrecord(surface.common.handle, REFERENCE_KEY)?;
            if record.get_first_by_code(90)?.value.as_i32()? != 1 {
                return None;
            }
            let sections = usize::try_from(record.get_first_by_code(91)?.value.as_i32()?).ok()?;
            let guides = usize::try_from(record.get_first_by_code(92)?.value.as_i32()?).ok()?;
            let path = usize::try_from(record.get_first_by_code(93)?.value.as_i32()?).ok()?;
            let handles: Vec<_> = record
                .entries
                .iter()
                .filter_map(|entry| match entry.value {
                    XRecordValue::Handle(h) if entry.code == 330 => Some(h),
                    _ => None,
                })
                .collect();
            if path > 1 || sections.checked_add(guides)?.checked_add(path)? != handles.len() {
                return None;
            }
            Some((
                surface.common.handle,
                handles[..sections].to_vec(),
                handles[sections..sections + guides].to_vec(),
                (path == 1).then(|| handles[sections + guides]),
            ))
        })
        .collect();
    for (handle, sections, guides, path) in references {
        if let Some(EntityType::Surface(surface)) = document.get_entity_mut(handle) {
            if let SurfaceData::Lofted {
                cross_sections,
                guide_curves,
                path_curve,
                ..
            } = &mut surface.surface_data
            {
                *cross_sections = sections;
                *guide_curves = guides;
                *path_curve = path;
            }
        }
    }
}

type Inputs = (
    Vec<EmbeddedEntity>,
    Vec<EmbeddedEntity>,
    Option<EmbeddedEntity>,
);
fn decode(record: &XRecord) -> Option<Inputs> {
    let entries = &record.entries;
    if entries.first()?.code != 90 || entries[0].value.as_i32()? != 1 {
        return None;
    }
    let mut result = (Vec::new(), Vec::new(), None);
    let mut index = 1;
    while index < entries.len() {
        if entries.get(index)?.code != 70
            || entries.get(index + 1)?.code != 91
            || entries.get(index + 2)?.code != 92
        {
            return None;
        }
        let role = entries[index].value.as_i32()?;
        let entity_type = entries[index + 1].value.as_i32()?;
        let bits = usize::try_from(entries[index + 2].value.as_i32()?).ok()?;
        if bits == 0 || bits > 64 * 1024 * 1024 {
            return None;
        }
        index += 3;
        let mut bytes = Vec::new();
        while entries.get(index).is_some_and(|entry| entry.code == 310) {
            let XRecordValue::Chunk(chunk) = &entries[index].value else {
                return None;
            };
            if bytes.len() + chunk.len() > bits.div_ceil(8) {
                return None;
            }
            bytes.extend_from_slice(chunk);
            index += 1;
        }
        if bytes.len() != bits.div_ceil(8) {
            return None;
        }
        let version = DwgVersion::from_dxf_version(DxfVersion::AC1032).ok()?;
        let entity = decode_embedded_entity(entity_type, bits, bytes, version, DxfVersion::AC1032)?;
        match role {
            0 => result.0.push(entity),
            1 => result.1.push(entity),
            2 if result.2.is_none() => result.2 = Some(entity),
            _ => return None,
        }
    }
    Some(result)
}
