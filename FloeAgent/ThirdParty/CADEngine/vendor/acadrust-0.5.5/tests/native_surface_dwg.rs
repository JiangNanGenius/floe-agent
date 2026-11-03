use acadrust::entities::{EntityCommon, EntityType, Surface, SurfaceData, SurfaceKind};
use acadrust::{CadDocument, DwgReader, DwgWriter, DxfReader, DxfVersion, DxfWriter, Vector3};
use std::io::Cursor;

fn native_surfaces() -> Vec<Surface> {
    let doc = DwgReader::from_stream(Cursor::new(include_bytes!(
        "../examples/entity_atlas_assets/native_surfaces.dwg"
    )))
    .read()
    .unwrap();
    let surfaces: Vec<_> = doc
        .entities()
        .filter_map(|entity| match entity {
            EntityType::Surface(surface) => Some(surface.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(surfaces.len(), 4);
    surfaces
}

#[test]
fn native_surface_parameters_are_decoded_without_offset_drift() {
    for surface in native_surfaces() {
        assert_eq!((surface.u_isolines, surface.v_isolines), (6, 6));
        match surface.surface_data {
            SurfaceData::Extruded {
                sweep_entity,
                sweep_vector,
                options,
                ..
            } => {
                assert!(sweep_entity.is_some());
                assert_eq!(sweep_vector, Vector3::new(0., 0., 40.));
                assert_eq!(options.scale_factor, 1.);
            }
            SurfaceData::Lofted {
                cross_section_entities,
                guide_entities,
                loft_transform,
                start_draft_angle,
                ..
            } => {
                assert_eq!(cross_section_entities.len(), 2);
                assert!(guide_entities.is_empty());
                assert_eq!(loft_transform[15], 1.);
                assert_eq!(loft_transform[11], 0.);
                assert!((start_draft_angle - std::f64::consts::FRAC_PI_2).abs() < 1e-12);
            }
            SurfaceData::Revolved {
                revolve_entity,
                axis_point,
                axis_vector,
                revolve_angle,
                ..
            } => {
                assert!(revolve_entity.is_some());
                assert_eq!(axis_point, Vector3::new(40., 40., 20.));
                assert_eq!(axis_vector, Vector3::UNIT_Z);
                assert!((revolve_angle - std::f64::consts::PI).abs() < 1e-12);
            }
            SurfaceData::Swept {
                sweep_entity,
                path_entity,
                options,
                ..
            } => {
                assert!(sweep_entity.is_some());
                assert!(path_entity.is_some());
                assert_eq!(options.scale_factor, 1.);
                assert_eq!(options.sweep_alignment_flags, 1);
            }
            _ => panic!("unexpected native subtype"),
        }
    }
}

#[test]
fn native_surface_construction_data_roundtrips_ac1021_through_ac1032() {
    for version in [
        DxfVersion::AC1021,
        DxfVersion::AC1024,
        DxfVersion::AC1027,
        DxfVersion::AC1032,
    ] {
        let mut doc = CadDocument::with_version(version);
        let mut expected = Vec::new();
        for mut surface in native_surfaces() {
            surface.common = EntityCommon::default();
            surface.history_handle = None;
            expected.push(surface.clone());
            doc.add_entity(EntityType::Surface(surface)).unwrap();
        }
        let bytes = DwgWriter::write_to_vec(&doc).unwrap();
        let loaded = DwgReader::from_stream(Cursor::new(bytes)).read().unwrap();
        for source in expected {
            let result = loaded
                .entities()
                .find_map(|entity| match entity {
                    EntityType::Surface(surface) if surface.kind == source.kind => Some(surface),
                    _ => None,
                })
                .expect("subtype retained");
            assert_eq!(
                result.surface_data, source.surface_data,
                "{version:?} {:?}",
                source.kind
            );
            assert_eq!(result.u_isolines, 6);
            assert!(
                result.acis_data.has_data(),
                "{version:?} {:?} lost modeler data",
                source.kind
            );
            assert_eq!(
                result.acis_data.sab_data, source.acis_data.sab_data,
                "modeler bytes {version:?} {:?}",
                source.kind
            );
            if source.kind == SurfaceKind::Lofted {
                let SurfaceData::Lofted {
                    cross_section_entities,
                    ..
                } = &result.surface_data
                else {
                    unreachable!()
                };
                assert_eq!(cross_section_entities.len(), 2);
            }
        }
    }
}

#[test]
fn loft_database_references_supply_profiles_and_retain_handle_roles() {
    for version in [
        DxfVersion::AC1021,
        DxfVersion::AC1024,
        DxfVersion::AC1027,
        DxfVersion::AC1032,
    ] {
        let mut doc = CadDocument::with_version(version);
        let sections: Vec<_> = [0., 20.]
            .into_iter()
            .map(|z| {
                doc.add_entity(EntityType::Line(acadrust::entities::Line::from_points(
                    Vector3::new(0., 0., z),
                    Vector3::new(10., 0., z),
                )))
                .unwrap()
            })
            .collect();
        let mut surface = Surface::new(SurfaceKind::Lofted);
        if let SurfaceData::Lofted { cross_sections, .. } = &mut surface.surface_data {
            *cross_sections = sections.clone();
        }
        let handle = doc.add_entity(EntityType::Surface(surface)).unwrap();
        let loaded = DwgReader::from_stream(Cursor::new(DwgWriter::write_to_vec(&doc).unwrap()))
            .read()
            .unwrap();
        let Some(EntityType::Surface(surface)) = loaded.get_entity(handle) else {
            panic!()
        };
        let SurfaceData::Lofted {
            cross_sections,
            cross_section_entities,
            ..
        } = &surface.surface_data
        else {
            panic!()
        };
        assert_eq!(cross_sections, &sections);
        assert_eq!(cross_section_entities.len(), 2);
        assert!(doc
            .get_entity(handle)
            .unwrap()
            .common()
            .xdictionary_handle
            .is_none());
    }
}

#[test]
fn translating_native_surfaces_preserves_binary_types_and_wire_metadata() {
    use acadrust::entities::Entity;
    for mut surface in native_surfaces() {
        let original = surface.acis_data.clone();
        let geometry = original.parse().unwrap();
        surface.translate(Vector3::new(150., -200., 0.));
        assert!(surface.acis_data.is_binary);
        assert_eq!(
            surface.acis_data.wireframe_isolines,
            original.wireframe_isolines
        );
        assert_eq!(
            surface.acis_data.wireframe_data_present,
            original.wireframe_data_present
        );
        let translated = surface.acis_data.parse().unwrap();
        for source in geometry
            .records
            .iter()
            .filter(|record| record.entity_type.ends_with("-surface"))
        {
            let target = translated
                .records
                .iter()
                .find(|record| record.index == source.index)
                .unwrap();
            assert_eq!(
                source.tokens, target.tokens,
                "{:?} {}",
                surface.kind, source.entity_type
            );
        }
    }
}

#[test]
fn native_modeler_header_flags_survive_sat_and_sab_conversions() {
    use acadrust::entities::acis::{SabReader, SabWriter, SatDocument};
    for surface in native_surfaces() {
        let native = surface.acis_data.parse().unwrap();
        assert_eq!(native.header.raw_history_flags, Some(26));
        let sat = SatDocument::parse(&native.to_sat_string()).unwrap();
        assert_eq!(sat.header.raw_history_flags, Some(26));
        let binary = SabWriter::write(&native);
        assert_eq!(&binary[27..31], &26u32.to_le_bytes());
        let rewritten = SabReader::read(&binary).unwrap();
        assert_eq!(rewritten.records, native.records);
        let mut edited = native;
        edited.header.has_history = false;
        assert_eq!(&SabWriter::write(&edited)[27..31], &0u32.to_le_bytes());
    }
}

#[test]
fn native_surface_sat_is_not_declared_empty() {
    for surface in native_surfaces() {
        let document = surface.acis_data.parse().unwrap();
        let text = document.to_sat_string();
        let count: usize = text
            .lines()
            .next()
            .unwrap()
            .split_whitespace()
            .nth(1)
            .unwrap()
            .parse()
            .unwrap();
        assert_eq!(count, document.records.len());
        for face in document
            .records
            .iter()
            .filter(|record| record.entity_type == "face")
        {
            let roles: Vec<_> = face
                .tokens
                .iter()
                .filter_map(|token| match token.as_ident() {
                    Some(name)
                        if matches!(
                            name,
                            "forward" | "reversed" | "single" | "double" | "in" | "out"
                        ) =>
                    {
                        Some(name)
                    }
                    _ => None,
                })
                .collect();
            assert!(matches!(
                roles.as_slice(),
                ["forward" | "reversed", "single" | "double"]
                    | ["forward" | "reversed", "single" | "double", "in" | "out"]
            ));
        }
        assert!(!text.lines().any(|line| {
            (line.starts_with("face ") || line.starts_with("transform "))
                && line
                    .split_whitespace()
                    .any(|word| word == "T" || word == "F")
        }));
    }
}

#[test]
fn translated_native_surface_dxf_streams_are_nonempty_in_both_encodings() {
    use acadrust::entities::Entity;

    for version in [DxfVersion::AC1021, DxfVersion::AC1024] {
        let mut source = CadDocument::with_version(version);
        for (index, mut surface) in native_surfaces().into_iter().enumerate() {
            surface.common = EntityCommon::default();
            surface.history_handle = None;
            surface.translate(Vector3::new(index as f64 * 150., -700., 0.));
            source.add_entity(EntityType::Surface(surface)).unwrap();
        }
        for binary in [false, true] {
            let mut writer = DxfWriter::new(&source);
            writer.binary = binary;
            let loaded = DxfReader::from_reader(Cursor::new(writer.write_to_vec().unwrap()))
                .unwrap()
                .read()
                .unwrap();
            let surfaces: Vec<_> = loaded
                .entities()
                .filter_map(|entity| match entity {
                    EntityType::Surface(surface) => Some(surface),
                    _ => None,
                })
                .collect();
            assert_eq!(surfaces.len(), 4, "{version:?}, binary={binary}");
            for surface in surfaces {
                let lines: Vec<_> = surface.acis_data.sat_data.lines().collect();
                let count: usize = lines[0].split_whitespace().nth(1).unwrap().parse().unwrap();
                assert!(
                    count > 0,
                    "{version:?}, binary={binary}, {:?}",
                    surface.kind
                );
                assert!(!lines.iter().any(|line| {
                    (line.starts_with("face ") || line.starts_with("transform "))
                        && line
                            .split_whitespace()
                            .any(|word| word == "T" || word == "F")
                }));
                assert!(lines.iter().any(|line| line.starts_with("transform ")
                    && line.contains("no_rotate no_reflect no_shear")));
            }
        }
    }
}
