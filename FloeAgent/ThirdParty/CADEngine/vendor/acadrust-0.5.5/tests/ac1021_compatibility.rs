//! AC1021 stored-page encoding and optional validation with AutoCAD itself.

use std::io::Cursor;

use acadrust::document::{Preview, PreviewFormat};
use acadrust::entities::{EntityType, Line};
use acadrust::types::DxfVersion;
use acadrust::{CadDocument, DwgReader, DwgWriter};

fn drawing(lines: usize) -> CadDocument {
    let mut document = CadDocument::with_version(DxfVersion::AC1021);
    for index in 0..lines {
        let x = index as f64;
        document
            .add_entity(EntityType::Line(Line::from_coords(
                x,
                0.,
                0.,
                x + 1.,
                2.,
                0.,
            )))
            .unwrap();
    }
    document
}

fn preview() -> Preview {
    let mut dib = vec![0u8; 40 + 64 * 64 * 3];
    dib[..4].copy_from_slice(&40u32.to_le_bytes());
    dib[4..8].copy_from_slice(&64i32.to_le_bytes());
    dib[8..12].copy_from_slice(&64i32.to_le_bytes());
    dib[12..14].copy_from_slice(&1u16.to_le_bytes());
    dib[14..16].copy_from_slice(&24u16.to_le_bytes());
    dib[20..24].copy_from_slice(&(64u32 * 64 * 3).to_le_bytes());
    for (index, pixel) in dib[40..].chunks_exact_mut(3).enumerate() {
        pixel.copy_from_slice(&[(index % 64 * 4) as u8, (index / 64 * 4) as u8, 96]);
    }
    Preview {
        format: PreviewFormat::Bmp,
        data: dib,
    }
}

#[test]
fn large_preview_remains_contiguous_before_parity() {
    let mut document = drawing(1);
    document.preview = Some(preview());
    let bytes = DwgWriter::write_to_vec(&document).unwrap();
    let mut reader = DwgReader::from_stream(Cursor::new(bytes.clone()));
    let info = reader.read_file_header().unwrap();
    let section = info
        .section_descriptors
        .iter()
        .find(|s| s.name == "AcDb:Preview")
        .unwrap();
    assert_eq!(section.page_count, 1);
    let expected = acadrust::io::dwg::preview::build_preview(
        document.preview.as_ref(),
        info.preview_address as u64,
    );
    let start = info.preview_address as usize;
    assert_eq!(&bytes[start..start + expected.len()], expected);
    assert_eq!(
        reader.get_section_buffer("AcDb:Preview", &info).unwrap(),
        expected
    );
    let loaded = DwgReader::from_stream(Cursor::new(bytes)).read().unwrap();
    assert_eq!(loaded.preview, document.preview);
}

#[test]
fn multi_page_objects_survive_with_stored_page_parity() {
    let document = drawing(5000);
    let bytes = DwgWriter::write_to_vec(&document).unwrap();
    assert_eq!(DwgWriter::write_to_vec(&document).unwrap(), bytes);
    let mut reader = DwgReader::from_stream(Cursor::new(bytes.clone()));
    let info = reader.read_file_header().unwrap();
    let objects = info
        .section_descriptors
        .iter()
        .find(|s| s.name == "AcDb:AcDbObjects")
        .unwrap();
    assert!(objects.page_count > 1);
    let loaded = DwgReader::from_stream(Cursor::new(bytes)).read().unwrap();
    assert_eq!(loaded.entity_count(), 5000);
}

/// Set ACAD_CORE_CONSOLE to accoreconsole.exe, then run:
/// cargo test --test ac1021_compatibility -- --ignored --nocapture
#[test]
#[cfg(windows)]
#[ignore = "requires a licensed AutoCAD installation and ACAD_CORE_CONSOLE"]
fn autocad_opens_ac1021_without_recovery() {
    use acadrust::entities::{Circle, Text};
    use acadrust::types::Vector3;
    use std::fs::{self, File};
    use std::os::windows::process::CommandExt;
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    let executable = std::env::var_os("ACAD_CORE_CONSOLE").expect("set ACAD_CORE_CONSOLE");
    let run = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let directory = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("target")
        .join("ac1021-autocad")
        .join(format!("{}-{run}", std::process::id()));
    fs::create_dir_all(&directory).unwrap();
    let script = directory.join("audit.scr");
    fs::write(&script, concat!(
        "_.AUDIT\n_N\n",
        "(setq ac1021_selection (ssget \"_X\" '((410 . \"Model\"))))\n",
        "(princ (strcat \"\\nAC1021_MODEL_COUNT=\" (itoa (if ac1021_selection (sslength ac1021_selection) 0))))\n",
        "_.QUIT\n_Y\n",
    )).unwrap();

    let mut mixed = drawing(1);
    mixed
        .add_entity(EntityType::Circle(Circle::from_coords(5., 5., 0., 2.)))
        .unwrap();
    mixed
        .add_entity(EntityType::Text(Text::with_value("AC1021", Vector3::ZERO)))
        .unwrap();
    let mut with_preview = drawing(1);
    with_preview.preview = Some(preview());
    for (name, document) in [
        ("empty", drawing(0)),
        ("mixed", mixed),
        ("preview", with_preview),
        ("multi_page", drawing(5000)),
        ("r2013_line", {
            let mut doc = drawing(1);
            doc.version = DxfVersion::AC1027;
            doc
        }),
        ("r2018_line", {
            let mut doc = drawing(1);
            doc.version = DxfVersion::AC1032;
            doc
        }),
        ("r2010_table", {
            let mut doc = CadDocument::with_version(DxfVersion::AC1024);
            let mut table = acadrust::entities::Table::new(Vector3::ZERO, 2, 2);
            table.rows[0].cells[0] = acadrust::entities::TableCell::text("R2010");
            table.rows[1].cells[1] = acadrust::entities::TableCell::text("Native table");
            doc.add_entity(EntityType::Table(table)).unwrap();
            doc
        }),
        ("r2013_multiple_solids", {
            let mut doc = CadDocument::with_version(DxfVersion::AC1027);
            for index in 0..7 {
                let sat = acadrust::entities::acis::primitives::build_box(
                    [index as f64 * 20., 0., 0.],
                    5. + index as f64,
                    6.,
                    7.,
                );
                doc.add_entity(EntityType::Solid3D(
                    acadrust::entities::Solid3D::from_sat(&sat.to_sat_string()),
                ))
                .unwrap();
            }
            doc
        }),
        ("r2018_multiple_surfaces", {
            let source = DwgReader::from_stream(std::io::Cursor::new(include_bytes!(
                "../examples/entity_atlas_assets/native_surfaces.dwg"
            )))
            .read()
            .unwrap();
            let mut doc = CadDocument::with_version(DxfVersion::AC1032);
            for entity in source.entities() {
                if let EntityType::Surface(surface) = entity {
                    let mut surface = surface.clone();
                    surface.common = acadrust::entities::EntityCommon::default();
                    surface.history_handle = None;
                    doc.add_entity(EntityType::Surface(surface)).unwrap();
                }
            }
            doc
        }),
    ] {
        let path = directory.join(format!("{name}.dwg"));
        DwgWriter::write_to_file(&path, &document).unwrap();
        let before = fs::read(&path).unwrap();
        let stdout = directory.join(format!("{name}.log"));
        let stderr = directory.join(format!("{name}.stderr.log"));
        let mut process = Command::new(&executable)
            .args(["/i"])
            .arg(&path)
            .args(["/s"])
            .arg(&script)
            .arg("/readonly")
            .current_dir(&directory)
            .creation_flags(0x08000000)
            .stdin(Stdio::null())
            .stdout(File::create(&stdout).unwrap())
            .stderr(File::create(&stderr).unwrap())
            .spawn()
            .unwrap();
        let started = Instant::now();
        let status = loop {
            if let Some(status) = process.try_wait().unwrap() {
                break status;
            }
            if started.elapsed() > Duration::from_secs(60) {
                process.kill().unwrap();
                process.wait().unwrap();
                panic!("AutoCAD timed out; see {}", stdout.display());
            }
            std::thread::sleep(Duration::from_millis(100));
        };
        let output = fs::read(&stdout).unwrap();
        let log = if output.contains(&0) {
            let words: Vec<_> = output
                .chunks_exact(2)
                .map(|b| u16::from_le_bytes([b[0], b[1]]))
                .collect();
            String::from_utf16_lossy(&words)
        } else {
            String::from_utf8_lossy(&output).into_owned()
        };
        assert!(status.success(), "{name}: {status}\n{log}");
        assert!(
            log.contains("Total errors found 0 fixed 0"),
            "{name}: {log}"
        );
        assert!(
            log.contains(&format!("AC1021_MODEL_COUNT={}", document.entity_count())),
            "{name}: {log}"
        );
        assert_eq!(
            fs::read(&path).unwrap(),
            before,
            "AutoCAD changed the input"
        );
        println!(
            "{name}: AutoCAD opened directly, zero audit errors; {}",
            stdout.display()
        );
    }
}
