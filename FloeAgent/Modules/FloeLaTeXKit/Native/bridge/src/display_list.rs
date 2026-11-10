// SPDX-License-Identifier: MPL-2.0
//! Bounded physical display list from the pinned MIT XDV parser, not a PDF shim.
use crate::legacy::{Encoding, MapTable, Tfm};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    fs,
    io::Read,
    path::{Path, PathBuf},
};
use tectonic::{
    io::{IoProvider, OpenResult},
    status::StatusBackend,
};
use tectonic_bridge_core::FileFormat;
use tectonic_errors::{prelude::*, Result};
use tectonic_xdv::{FileType, XdvEvents, XdvParser};

const SCALE: f64 = 72.0 / (72.27 * 65536.0);
const MAX_RESOURCE: u64 = 64 * 1024 * 1024;
const MAX_OPS: usize = 500_000;
const MAX_GLYPHS: usize = 2_000_000;
fn bp(v: i32) -> f64 {
    72.0 + f64::from(v) * SCALE
}
fn b64(data: &[u8]) -> String {
    const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for c in data.chunks(3) {
        let n = (u32::from(c[0]) << 16)
            | (u32::from(*c.get(1).unwrap_or(&0)) << 8)
            | u32::from(*c.get(2).unwrap_or(&0));
        out.push(T[((n >> 18) & 63) as usize] as char);
        out.push(T[((n >> 12) & 63) as usize] as char);
        out.push(if c.len() > 1 {
            T[((n >> 6) & 63) as usize] as char
        } else {
            '='
        });
        out.push(if c.len() > 2 {
            T[(n & 63) as usize] as char
        } else {
            '='
        });
    }
    out
}
fn dimension(s: &str) -> Result<f64> {
    let s = s.trim();
    let units = [
        ("bp", 1.0),
        ("pt", 72.0 / 72.27),
        ("in", 72.0),
        ("cm", 72.0 / 2.54),
        ("mm", 72.0 / 25.4),
    ];
    for (unit, scale) in units {
        if let Some(v) = s.strip_suffix(unit) {
            let value = v.trim().parse::<f64>()? * scale;
            if value.is_finite() && value > 0.0 && value < 100_000.0 {
                return Ok(value);
            }
        }
    }
    bail!("Unsupported or invalid XDV page dimension")
}
struct Resources<'a> {
    source: &'a Path,
    folder: PathBuf,
    bundle: &'a mut dyn tectonic_bundles::Bundle,
    status: &'a mut dyn StatusBackend,
    total: usize,
    map: Option<MapTable>,
}
impl Resources<'_> {
    fn read(&mut self, name: &str) -> Result<Vec<u8>> {
        read_resource(name, self.source, self.bundle, self.status)
    }
    fn read_native_font(&mut self, name: &str) -> Result<(String, Vec<u8>)> {
        if let Some(bytes) = read_resource_optional(name, self.source, self.bundle, self.status)? {
            return Ok((name.to_owned(), bytes));
        }
        // Old XDV records can contain the unresolved TeX request. Follow the
        // engine's exact FileFormat suffix order, never a family/PS-name guess.
        for format in [
            FileFormat::OpenType,
            FileFormat::TrueType,
            FileFormat::Type1,
        ] {
            for suffix in format.extensions() {
                let resolved = format!("{name}.{suffix}");
                if let Some(bytes) =
                    read_resource_optional(&resolved, self.source, self.bundle, self.status)?
                {
                    return Ok((resolved, bytes));
                }
            }
        }
        bail!("Used native font resource is unavailable: {name}")
    }
    fn save(&mut self, name: &str, bytes: &[u8]) -> Result<PathBuf> {
        self.total = self
            .total
            .checked_add(bytes.len())
            .ok_or_else(|| tectonic_errors::Error::msg("Font resource size overflow"))?;
        if self.total > 256 * 1024 * 1024 {
            bail!("Native font assets exceed total limit")
        }
        let path = self.folder.join(name);
        if path.exists() {
            bail!("Native font asset output already exists")
        }
        fs::write(&path, bytes)?;
        Ok(path)
    }
    fn map_record(&mut self, name: &str) -> Result<crate::legacy::MapRecord> {
        if self.map.is_none() {
            let bytes = if let Some(bytes) =
                read_resource_optional("pdftex.map", self.source, self.bundle, self.status)?
            {
                bytes
            } else {
                self.read("psfonts.map")?
            };
            self.map = Some(MapTable::parse(&bytes)?);
            self.save("used-font-map.map", &bytes)?;
        }
        self.map.as_ref().unwrap().get(name)
    }
}
struct LegacyFont {
    metrics: Tfm,
    encoding: Option<Vec<String>>,
}
struct Builder<'a> {
    resources: Resources<'a>,
    legacy: BTreeMap<i32, LegacyFont>,
    definitions: BTreeMap<i32, (String, String, u32, u32, u32)>,
    fonts: BTreeMap<i32, Value>,
    pages: Vec<Value>,
    ops: usize,
    glyphs: usize,
    page_width: f64,
    page_height: f64,
}
impl<'a> Builder<'a> {
    fn new(
        source: &'a Path,
        output: &Path,
        bundle: &'a mut dyn tectonic_bundles::Bundle,
        status: &'a mut dyn StatusBackend,
    ) -> Result<Self> {
        let folder = output.join("NativeAssets/fonts");
        fs::create_dir_all(&folder)?;
        Ok(Self {
            resources: Resources {
                source,
                folder,
                bundle,
                status,
                total: 0,
                map: None,
            },
            legacy: BTreeMap::new(),
            definitions: BTreeMap::new(),
            fonts: BTreeMap::new(),
            pages: Vec::new(),
            ops: 0,
            glyphs: 0,
            page_width: 612.0,
            page_height: 792.0,
        })
    }

    fn push(&mut self, op: Value) -> Result<()> {
        self.ops += 1;
        if self.ops > MAX_OPS {
            bail!("XDV operation limit exceeded")
        }
        self.pages
            .last_mut()
            .and_then(|p| p["ops"].as_array_mut())
            .ok_or_else(|| tectonic_errors::Error::msg("XDV draw outside a page"))?
            .push(op);
        Ok(())
    }
    fn glyph(
        &mut self,
        font: i32,
        ids: &[u16],
        x: &[i32],
        y: &[i32],
        text: Option<&str>,
    ) -> Result<()> {
        if ids.len() != x.len() || ids.len() != y.len() || !self.fonts.contains_key(&font) {
            bail!("XDV glyph/font binding mismatch")
        }
        self.glyphs += ids.len();
        if self.glyphs > MAX_GLYPHS {
            bail!("XDV glyph limit exceeded")
        }
        let xs: Vec<_> = x.iter().map(|n| bp(*n)).collect();
        let ys: Vec<_> = y.iter().map(|n| bp(*n)).collect();
        self.push(json!({"kind":"glyphRun","fontID":font,"glyphs":ids,"x":xs,"y":ys,"text":text}))
    }
}
impl XdvEvents for Builder<'_> {
    type Error = tectonic_errors::Error;
    fn handle_header(&mut self, kind: FileType, _comment: &[u8]) -> Result<()> {
        if kind != FileType::Xdv {
            bail!("SPX is not a paginated native PDF input")
        }
        Ok(())
    }
    fn handle_begin_page(&mut self, _counters: &[i32], _previous: i32) -> Result<()> {
        if self.pages.len() >= 1000 {
            bail!("XDV page limit exceeded")
        }
        self.pages
            .push(json!({"width":self.page_width,"height":self.page_height,"ops":[]}));
        Ok(())
    }
    fn handle_define_font(
        &mut self,
        name: &str,
        area: &str,
        id: i32,
        checksum: u32,
        scale: u32,
        design: u32,
    ) -> Result<()> {
        let definition = (name.to_owned(), area.to_owned(), checksum, scale, design);
        if let Some(prior) = self.definitions.get(&id) {
            if prior != &definition {
                bail!("Conflicting traditional XDV font definition")
            }
            return Ok(());
        }
        if self.fonts.contains_key(&id) || self.fonts.len() >= 4096 {
            bail!("XDV font identifier conflict or font limit")
        }
        crate::legacy::validate_name(name)?;
        let metric_name = format!("{area}{name}.tfm");
        crate::legacy::validate_name(&metric_name)?;
        let metric_data = self.resources.read(&metric_name)?;
        let metrics = Tfm::parse(&metric_data, scale, checksum, design)?;
        let map = self.resources.map_record(name)?;
        let outline_data = self.resources.read(&map.font)?;
        let path = self
            .resources
            .save(&format!("font-{id}.font"), &outline_data)?;
        let metric_path = self
            .resources
            .save(&format!("font-{id}.tfm"), &metric_data)?;
        let (encoding, encoding_path) = if let Some(name) = &map.encoding {
            let bytes = self.resources.read(name)?;
            let encoding = Encoding::parse(&bytes)?;
            if Some(&encoding.name) != map.encoding_name.as_ref() {
                bail!("Font map and encoding array name disagree")
            }
            let path = self.resources.save(&format!("font-{id}.enc"), &bytes)?;
            (Some(encoding), Some(path))
        } else {
            (None, None)
        };
        let font = json!({"id":id,"kind":"legacy","name":name,"path":path,
            "size":f64::from(scale)*SCALE,"faceIndex":0,"postScriptName":map.postscript,
            "extend":map.extend,"slant":map.slant,"embolden":0.0,"encodingPath":encoding_path,
            "encoding":encoding.as_ref().map(|e| e.name.as_str()).unwrap_or("builtin"),
            "tfmPath":metric_path,"tfmChecksum":metrics.checksum});
        self.fonts.insert(id, font);
        self.legacy.insert(
            id,
            LegacyFont {
                metrics,
                encoding: encoding.map(|e| e.glyphs),
            },
        );
        self.definitions.insert(id, definition);
        Ok(())
    }
    fn handle_character(&mut self, id: i32, character: i32, x: i32, y: i32) -> Result<i32> {
        if crate::floe_tex_checkpoint() != 0 {
            bail!("Native display list cancelled or timed out")
        }
        let font = self.legacy.get(&id).ok_or_else(|| {
            tectonic_errors::Error::msg("Traditional glyph has no exact TFM/font binding")
        })?;
        let advance = font.metrics.advance(character)?;
        let name = font
            .encoding
            .as_ref()
            .and_then(|e| e.get(character as usize))
            .cloned();
        if name.as_deref() == Some(".notdef") {
            bail!("Used TeX character maps to .notdef")
        }
        self.glyphs += 1;
        if self.glyphs > MAX_GLYPHS {
            bail!("XDV glyph limit exceeded")
        }
        self.push(
            json!({"kind":"legacyGlyph","fontID":id,"character":character,
            "glyphName":name,"x":bp(x),"y":bp(y)}),
        )?;
        Ok(advance)
    }
    fn handle_define_native_font(
        &mut self,
        name: &str,
        id: i32,
        size: i32,
        face: u32,
        color: Option<u32>,
        extend: Option<u32>,
        slant: Option<u32>,
        embolden: Option<u32>,
    ) -> Result<()> {
        if name.len() > 4096 || self.fonts.len() >= 4096 || size <= 0 {
            bail!("Invalid native font definition")
        }
        let mut value = json!({"id":id,"kind":"native","name":name,"path":null,
            "resourceName":null,"size":f64::from(size)*SCALE,"faceIndex":face,"postScriptName":null,
            "colorRGBA":color,"extend":f64::from(extend.unwrap_or(65536)as i32)/65536.0,
            "slant":f64::from(slant.unwrap_or(0)as i32)/65536.0,
            "embolden":f64::from(embolden.unwrap_or(0)as i32)*SCALE});
        if let Some(old) = self.fonts.get(&id) {
            let mut comparable = old.clone();
            comparable["path"] = Value::Null;
            comparable["postScriptName"] = Value::Null;
            comparable["resourceName"] = Value::Null;
            if comparable != value {
                bail!("Conflicting XDV font definition")
            }
            return Ok(());
        }
        let (resource_name, bytes) = self.resources.read_native_font(name)?;
        let path = self.resources.save(&format!("font-{id}.font"), &bytes)?;
        value["path"] = json!(path);
        value["resourceName"] = json!(resource_name);
        value["postScriptName"] = json!(postscript_name(&bytes, face));
        self.fonts.insert(id, value);
        Ok(())
    }
    fn handle_glyph_run(&mut self, font: i32, ids: &[u16], x: &[i32], y: &[i32]) -> Result<()> {
        self.glyph(font, ids, x, y, None)
    }
    fn handle_text_and_glyphs(
        &mut self,
        font: i32,
        text: &str,
        _width: i32,
        ids: &[u16],
        x: &[i32],
        y: &[i32],
    ) -> Result<()> {
        self.glyph(font, ids, x, y, Some(text))
    }
    // The physical-character callback already emitted exact glyph locations.
    fn handle_char_run(&mut self, _font: i32, _chars: &[i32]) -> Result<()> {
        Ok(())
    }
    fn handle_rule(&mut self, x: i32, y: i32, height: i32, width: i32) -> Result<()> {
        if height > 0 && width > 0 {
            self.push(json!({"kind":"rule","x":bp(x),"y":bp(y)-f64::from(height)*SCALE,"width":f64::from(width)*SCALE,"height":f64::from(height)*SCALE}))?;
        }
        Ok(())
    }
    fn handle_special(&mut self, x: i32, y: i32, data: &[u8]) -> Result<()> {
        if data.len() > 65536 {
            bail!("XDV special limit exceeded")
        }
        if let Ok(s) = std::str::from_utf8(data) {
            if let Some(size) = s.trim().strip_prefix("papersize=") {
                let pair: Vec<_> = size.split(',').collect();
                if pair.len() != 2 {
                    bail!("Invalid XDV paper size")
                }
                let width = dimension(pair[0])?;
                let height = dimension(pair[1])?;
                let page = self
                    .pages
                    .last_mut()
                    .ok_or_else(|| tectonic_errors::Error::msg("Paper size outside page"))?;
                page["width"] = json!(width);
                page["height"] = json!(height);
                self.page_width = width;
                self.page_height = height;
            } else if let Some(size) = s.trim().strip_prefix("pdf:pagesize ") {
                let fields: Vec<_> = size.split_whitespace().collect();
                if fields.len() != 4 || fields[0] != "width" || fields[2] != "height" {
                    bail!("Unsupported XDV page size special")
                }
                let page = self
                    .pages
                    .last_mut()
                    .ok_or_else(|| tectonic_errors::Error::msg("Paper size outside page"))?;
                let width = dimension(fields[1])?;
                let height = dimension(fields[3])?;
                page["width"] = json!(width);
                page["height"] = json!(height);
                self.page_width = width;
                self.page_height = height;
            }
        }
        // Every special reaches the Apple allowlist. Unknown specials must fail there.
        self.push(json!({"kind":"special","x":bp(x),"y":bp(y),"dataBase64":b64(data)}))
    }
}
fn read_resource(
    name: &str,
    source: &Path,
    bundle: &mut dyn tectonic_bundles::Bundle,
    status: &mut dyn StatusBackend,
) -> Result<Vec<u8>> {
    read_resource_optional(name, source, bundle, status)?.ok_or_else(|| {
        tectonic_errors::Error::msg(format!("Used font resource is unavailable: {name}"))
    })
}
fn read_resource_optional(
    name: &str,
    source: &Path,
    bundle: &mut dyn tectonic_bundles::Bundle,
    status: &mut dyn StatusBackend,
) -> Result<Option<Vec<u8>>> {
    if crate::floe_tex_checkpoint() != 0 {
        bail!("Native font resource resolution cancelled or timed out")
    }
    let path = Path::new(name);
    if !path.is_absolute() {
        crate::legacy::validate_name(name)?;
        let p = source.join(path);
        if p.is_file() {
            let canonical = p.canonicalize()?;
            if !canonical.starts_with(source) {
                bail!("Font resource escapes source snapshot")
            }
            return Ok(Some(read_file(&canonical)?));
        }
    } else {
        let canonical = path.canonicalize()?;
        if canonical.starts_with(source)
            || canonical.starts_with("/System/Library/Fonts")
            || canonical.starts_with("/System/Library/AssetsV2")
        {
            return Ok(Some(read_file(&canonical)?));
        }
        bail!("Native font URL outside the authorized source/system font roots")
    }
    match bundle.input_open_name(name, status) {
        OpenResult::Ok(input) => {
            let mut data = Vec::new();
            input.take(MAX_RESOURCE + 1).read_to_end(&mut data)?;
            if data.len() as u64 > MAX_RESOURCE {
                bail!("Font resource exceeds limit")
            }
            Ok(Some(data))
        }
        OpenResult::Err(e) => Err(e),
        OpenResult::NotAvailable => Ok(None),
    }
}
fn read_file(p: &Path) -> Result<Vec<u8>> {
    if fs::metadata(p)?.len() > MAX_RESOURCE {
        bail!("Font resource exceeds limit")
    }
    Ok(fs::read(p)?)
}
// Read the actual SFNT face's nameID6; never infer a TTC face from array ordering.
fn postscript_name(data: &[u8], face: u32) -> Option<String> {
    fn u16at(d: &[u8], o: usize) -> Option<u16> {
        Some(u16::from_be_bytes(d.get(o..o + 2)?.try_into().ok()?))
    }
    fn u32at(d: &[u8], o: usize) -> Option<u32> {
        Some(u32::from_be_bytes(d.get(o..o + 4)?.try_into().ok()?))
    }
    let offset = if data.get(..4)? == b"ttcf" {
        let n = u32at(data, 8)?;
        if face >= n {
            return None;
        }
        u32at(data, 12 + face as usize * 4)? as usize
    } else {
        if face != 0 {
            return None;
        }
        0
    };
    let count = u16at(data, offset + 4)? as usize;
    if count > 256 {
        return None;
    }
    for i in 0..count {
        let o = offset + 12 + i * 16;
        if data.get(o..o + 4)? != b"name" {
            continue;
        }
        let table = u32at(data, o + 8)? as usize;
        let n = u16at(data, table + 2)? as usize;
        let strings = table + u16at(data, table + 4)? as usize;
        if n > 8192 {
            return None;
        }
        for j in 0..n {
            let r = table + 6 + j * 12;
            if u16at(data, r + 6)? != 6 {
                continue;
            }
            let platform = u16at(data, r)?;
            let length = u16at(data, r + 8)? as usize;
            let start = strings + u16at(data, r + 10)? as usize;
            let raw = data.get(start..start + length)?;
            if length > 1024 {
                continue;
            }
            let text = if platform == 0 || platform == 3 {
                if length % 2 != 0 {
                    continue;
                }
                String::from_utf16(
                    &raw.chunks_exact(2)
                        .map(|b| u16::from_be_bytes([b[0], b[1]]))
                        .collect::<Vec<_>>(),
                )
                .ok()?
            } else if platform == 1 {
                String::from_utf8(raw.to_vec()).ok()?
            } else {
                continue;
            };
            if !text.is_empty() {
                return Some(text);
            }
        }
    }
    None
}
pub(super) fn write(
    xdv: &Path,
    output: &Path,
    source: &Path,
    bundle: &mut dyn tectonic_bundles::Bundle,
    status: &mut dyn StatusBackend,
) -> Result<PathBuf> {
    if fs::metadata(xdv)?.len() > 64 * 1024 * 1024 {
        bail!("XDV size limit exceeded")
    }
    let list = XdvParser::process_with_seeks(
        fs::File::open(xdv)?,
        Builder::new(source, output, bundle, status)?,
    )?;
    if list.pages.is_empty() {
        bail!("Native engine produced no paginated XDV")
    }
    let assets = crate::active()
        .and_then(|job| {
            job.assets
                .lock()
                .ok()
                .map(|a| a.values().cloned().collect::<Vec<_>>())
        })
        .unwrap_or_default();
    let root = json!({"protocol":"floe.tex.display-list","version":1,"units":"bp","origin":"top-left","xdvPath":xdv,"fonts":list.fonts.into_values().collect::<Vec<_>>(),"assets":assets,"pages":list.pages});
    let bytes = serde_json::to_vec(&root)?;
    if bytes.len() > 128 * 1024 * 1024 {
        bail!("Native display list exceeds limit")
    }
    let path = output.join("floe-display-list.json");
    if path.exists() {
        bail!("Display list output already exists")
    };
    fs::write(&path, bytes)?;
    Ok(path)
}
