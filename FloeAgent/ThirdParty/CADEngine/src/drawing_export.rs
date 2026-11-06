// SPDX-License-Identifier: MPL-2.0
//! Separate new-file conversion profile for Floe's native engineering sheets.
//! Arbitrary CAD saves/conversions retain the full, unchanged strict verifier.
use super::*;

/// Pure ASCII R12 export with only the exact header/table/entity vocabulary
/// emitted by CADDrawingService. Anything else stays on the strict CAD path.
pub(crate) fn is_profile(bytes: &[u8], format: &str) -> bool {
    if format != "dxf" || !bytes.is_ascii() {
        return false;
    }
    let Ok(text) = std::str::from_utf8(bytes) else {
        return false;
    };
    let mut lines = text.lines();
    let mut section = "";
    let mut record = "";
    let mut expect_section = false;
    let mut marker = false;
    let mut units = false;
    let mut version = false;
    let mut header = "";
    while let Some(code) = lines.next() {
        let Some(value) = lines.next() else {
            return false;
        };
        let Ok(code) = code.trim().parse::<i32>() else {
            return false;
        };
        let value = value.trim();
        if code == 999 {
            if value == "FloeCAD drawing export (units: mm)" {
                marker = true;
            } else {
                return false;
            }
            continue;
        }
        if code == 0 {
            record = value;
            match value {
                "SECTION" => {
                    expect_section = true;
                }
                "ENDSEC" => section = "",
                "EOF" => {}
                "TABLE" | "ENDTAB" if section == "TABLES" => {}
                "LTYPE" | "LAYER" if section == "TABLES" => {}
                "LINE" | "CIRCLE" | "ARC" | "POLYLINE" | "VERTEX" | "SEQEND" | "TEXT"
                    if section == "ENTITIES" => {}
                _ => return false,
            };
            continue;
        }
        if expect_section {
            if code != 2 || !matches!(value, "HEADER" | "TABLES" | "ENTITIES") {
                return false;
            }
            section = value;
            expect_section = false;
            continue;
        }
        match section {
            "HEADER" => {
                if code == 9 {
                    if !matches!(
                        value,
                        "$ACADVER" | "$DWGCODEPAGE" | "$INSUNITS" | "$MEASUREMENT"
                    ) {
                        return false;
                    }
                    header = value;
                } else {
                    match (header, code, value) {
                        ("$ACADVER", 1, "AC1009") => version = true,
                        ("$INSUNITS", 70, "4") => units = true,
                        ("$DWGCODEPAGE", 3, "ANSI_1252") | ("$MEASUREMENT", 70, "1") => {}
                        _ => return false,
                    }
                }
            }
            "TABLES" => {
                let allowed = match record {
                    "TABLE" => code == 2 && matches!(value, "LTYPE" | "LAYER") || code == 70,
                    "LTYPE" => matches!(code, 2 | 3 | 70 | 72 | 73 | 40 | 49),
                    "LAYER" => matches!(code, 2 | 70 | 62 | 6),
                    _ => false,
                };
                if !allowed {
                    return false;
                }
            }
            "ENTITIES" => {
                let allowed = match record {
                    "LINE" => matches!(code, 8 | 10 | 20 | 30 | 11 | 21 | 31),
                    "CIRCLE" => matches!(code, 8 | 10 | 20 | 30 | 40),
                    "ARC" => matches!(code, 8 | 10 | 20 | 30 | 40 | 50 | 51),
                    "POLYLINE" => matches!(code, 8 | 66 | 70),
                    "VERTEX" => matches!(code, 8 | 10 | 20 | 30),
                    "SEQEND" => code == 8,
                    "TEXT" => matches!(code, 8 | 10 | 20 | 30 | 40 | 1),
                    _ => false,
                };
                if !allowed {
                    return false;
                }
            }
            _ => return false,
        }
    }
    marker && units && version && section.is_empty() && record == "EOF"
}
fn image(entity: &EntityType) -> Value {
    let mut image = entity_image(entity);
    if let Some(object) = image.as_object_mut() {
        for value in object.values_mut() {
            if let Some(common) = value.get_mut("common").and_then(Value::as_object_mut) {
                common.remove("handle");
            }
        }
    }
    image
}

// The R12 profile uses ASCII MIF escapes. Decode exactly once when writing
// the new UTF-16 DWG. A literal \U+0041 encoded as \U+005CU+0041 stays literal.
fn decoded_text(text: &str) -> Result<String, String> {
    let bytes = text.as_bytes();
    let mut i = 0;
    let unit = |at: usize| -> Option<u16> {
        if at + 7 <= bytes.len() && &bytes[at..at + 3] == b"\\U+" {
            u16::from_str_radix(std::str::from_utf8(&bytes[at + 3..at + 7]).ok()?, 16).ok()
        } else {
            None
        }
    };
    while i < bytes.len() {
        if let Some(value) = unit(i) {
            i += 7;
            if (0xD800..=0xDBFF).contains(&value) {
                let low = unit(i).ok_or("Invalid surrogate in drawing text")?;
                if !(0xDC00..=0xDFFF).contains(&low) {
                    return Err("Invalid surrogate in drawing text".into());
                }
                i += 7;
            } else if (0xDC00..=0xDFFF).contains(&value) {
                return Err("Invalid surrogate in drawing text".into());
            }
        } else {
            i += 1;
        }
    }
    Ok(acadrust::io::dxf::code_page::decode_mif_escapes(text))
}

pub(crate) fn dwg(source: &CadDocument) -> Result<Vec<u8>, String> {
    if blocking_diagnostics(source) || source.header.insertion_units != 4 {
        return Err("Invalid engineering drawing diagnostics or units".into());
    }
    // Bootstrap the writer's DWG defaults once, before any source data enters
    // the candidate. These synthetic defaults were absent in the exchange DXF.
    let mut target = read(&encode(&CadDocument::new(), "dwg")?, "dwg")?;
    target.header.insertion_units = source.header.insertion_units;
    target.header.measurement = source.header.measurement;
    for original in source.line_types.iter() {
        let name = original.name.clone();
        let mut item = original.clone();
        if let Some(existing) = target.line_types.get_mut(&name) {
            item.handle = existing.handle;
            *existing = item;
        } else {
            item.handle = target.allocate_handle();
            target.line_types.add(item).map_err(|e| e.to_string())?;
        }
    }
    for original in source.layers.iter() {
        let name = original.name.clone();
        let mut item = original.clone();
        if let Some(line_type) = target
            .line_types
            .iter()
            .find(|entry| entry.name.eq_ignore_ascii_case(&item.line_type))
        {
            item.line_type = line_type.name.clone();
        }
        if let Some(existing) = target.layers.get_mut(&name) {
            item.handle = existing.handle;
            *existing = item;
        } else {
            item.handle = target.allocate_handle();
            target.layers.add(item).map_err(|e| e.to_string())?;
        }
    }
    let mut pairs = Vec::new();
    for original in source.entities() {
        if !model_space(source, original)
            || !matches!(
                original,
                EntityType::Line(_)
                    | EntityType::Circle(_)
                    | EntityType::Arc(_)
                    | EntityType::Polyline2D(_)
                    | EntityType::Text(_)
            )
        {
            return Err("The engineering profile contains unsupported entities".into());
        }
        let mut expected = original.clone();
        if let EntityType::Text(text) = &mut expected {
            text.value = decoded_text(&text.value)?;
        }
        let mut entity = expected.clone();
        let common = entity.common_mut();
        if !common.reactors.is_empty()
            || common.xdictionary_handle.is_some()
            || !common.extended_data.is_empty()
            || common.graphic_data.is_some()
        {
            return Err("Engineering entities have attached source data".into());
        }
        common.handle = Handle::NULL;
        common.owner_handle = Handle::NULL;
        let handle = target.add_entity(entity).map_err(|e| e.to_string())?;
        if !equivalent(
            &image(&expected),
            &image(
                target
                    .get_entity(handle)
                    .ok_or("Missing engineering curve")?,
            ),
        ) {
            return Err("Engineering source geometry changed during conversion".into());
        }
        pairs.push((expected, handle));
    }
    let bytes = encode(&target, "dwg")?;
    let reopened = read(&bytes, "dwg")?;
    verify(&target, &reopened)?;
    if reopened.header.insertion_units != 4 || pairs.len() != reopened.entity_count() {
        return Err("Engineering conversion changed units or entity count".into());
    }
    for (source, handle) in pairs {
        if !equivalent(
            &image(&source),
            &image(
                reopened
                    .get_entity(handle)
                    .ok_or("Engineering output lost geometry")?,
            ),
        ) {
            return Err("Engineering output changed source geometry or text".into());
        }
    }
    // The source-authored layers and line types must retain every semantic
    // property; allocated database handles legitimately differ in a new file.
    for original in source.layers.iter() {
        let mut a = serde_json::to_value(original).map_err(|e| e.to_string())?;
        let mut b = serde_json::to_value(
            reopened
                .layers
                .get(&original.name)
                .ok_or("Output lost a layer")?,
        )
        .map_err(|e| e.to_string())?;
        strip_table_handles(&mut a);
        strip_table_handles(&mut b);
        for v in [&mut a, &mut b] {
            if let Some(name) = v.get("line_type").and_then(Value::as_str) {
                v["line_type"] = json!(name.to_ascii_uppercase());
            }
        }
        if !equivalent(&a, &b) {
            return Err("Output changed a source layer".into());
        }
    }
    for original in source.line_types.iter() {
        let mut a = serde_json::to_value(original).map_err(|e| e.to_string())?;
        let mut b = serde_json::to_value(
            reopened
                .line_types
                .get(&original.name)
                .ok_or("Output lost a line type")?,
        )
        .map_err(|e| e.to_string())?;
        strip_table_handles(&mut a);
        strip_table_handles(&mut b);
        if !equivalent(&a, &b) {
            return Err("Output changed a source line type".into());
        }
    }
    Ok(bytes)
}

#[cfg(test)]
pub(crate) fn fixture() -> Vec<u8> {
    include_bytes!("fixtures/e23-native-engineering-sheet.dxf").to_vec()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn engineering_profile_rejects_unknown_source_content() {
        let bytes = fixture();
        assert!(is_profile(&bytes, "dxf"));
        assert_eq!(decoded_text(r"Floe \U+5DE5\U+7A0B").unwrap(), "Floe 工程");
        assert_eq!(
            decoded_text(r"literal \U+005CU+0041").unwrap(),
            r"literal \U+0041"
        );
        assert_eq!(decoded_text(r"\U+D83D\U+DE00").unwrap(), "😀");
        assert!(decoded_text(r"\U+D800").is_err());
        let source = String::from_utf8(bytes).unwrap();
        for extra in [
            "0\nSECTION\n2\nOBJECTS\n0\nENDSEC\n",
            "0\nSECTION\n2\nENTITIES\n0\nINSERT\n2\nBlock\n0\nENDSEC\n",
        ] {
            assert!(!is_profile(
                source
                    .replace("0\nEOF", &format!("{extra}0\nEOF"))
                    .as_bytes(),
                "dxf"
            ));
        }
        assert!(!is_profile(
            source.replace("9\n$MEASUREMENT", "9\n$UNKNOWN").as_bytes(),
            "dxf"
        ));
        let session = CadSession::new(source.as_bytes(), "dxf").unwrap();
        let before = session.inspect(0, 500).unwrap();
        // Ordinary conversion retains its existing strict full-content gate.
        assert!(session.export_as("dwg").is_err());
        assert_eq!(before, session.inspect(0, 500).unwrap());
        assert!(!session.export_drawing_dwg().unwrap().is_empty());
        assert_eq!(before, session.inspect(0, 500).unwrap());
    }
}
