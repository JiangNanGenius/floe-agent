// SPDX-License-Identifier: MPL-2.0
//! Exact TeX metrics and a non-executing subset of TeX font maps/encodings.
use std::collections::BTreeMap;
use tectonic_errors::{prelude::*, Result};

pub(super) struct Tfm {
    pub checksum: u32,
    widths: [Option<i32>; 256],
}
impl Tfm {
    pub fn parse(data: &[u8], scale: u32, expected_checksum: u32, design: u32) -> Result<Self> {
        if data.len() < 32 || data.len() > 1024 * 1024 || scale == 0 || scale > i32::MAX as u32 {
            bail!("Invalid bounded TFM input")
        }
        let word = |i: usize| u16::from_be_bytes([data[i * 2], data[i * 2 + 1]]) as usize;
        let h: Vec<_> = (0..12).map(word).collect();
        let (lf, lh, bc, ec, nw) = (h[0], h[1], h[2], h[3], h[4]);
        if lh < 2
            || bc > ec + 1
            || ec > 255
            || nw == 0
            || nw > 256
            || h[5..8].contains(&0)
            || lf * 4 != data.len()
            || lf != 6 + lh + (ec + 1 - bc) + h[4..].iter().sum::<usize>()
        {
            bail!("Malformed TFM tables")
        }
        let checksum = u32::from_be_bytes(data[24..28].try_into()?);
        if expected_checksum != 0 && checksum != 0 && expected_checksum != checksum {
            bail!("XDV/TFM checksum mismatch")
        }
        let tfm_design = u32::from_be_bytes(data[28..32].try_into()?) >> 4;
        if tfm_design < 65536 || (design != 0 && design != tfm_design) {
            bail!("XDV/TFM design size mismatch")
        }
        let chars = (6 + lh) * 4;
        let widths = chars + (ec + 1 - bc) * 4;
        // This is XeTeX's integer TFM scaling, including its truncation order,
        // xetex-xetex0.c read_font_info; a floating point multiply drifts.
        let mut z = i64::from(scale);
        let mut alpha = 16i64;
        while z >= 0x800000 {
            z /= 2;
            alpha *= 2;
        }
        let beta = 256 / alpha;
        if beta == 0 {
            bail!("TFM scale exceeds exact TeX metric range")
        }
        alpha *= z;
        let mut scaled = Vec::with_capacity(nw);
        for i in 0..nw {
            let d = &data[widths + i * 4..widths + i * 4 + 4];
            let mut value = (((i64::from(d[3]) * z / 256) + i64::from(d[2]) * z) / 256
                + i64::from(d[1]) * z)
                / beta;
            match d[0] {
                0 => {}
                255 => value -= alpha,
                _ => bail!("Invalid TFM fixed word"),
            }
            scaled.push(i32::try_from(value)?);
        }
        if scaled[0] != 0 {
            bail!("TFM missing-character width must be zero")
        }
        let mut result = Self {
            checksum,
            widths: [None; 256],
        };
        for c in bc..=ec {
            let record = &data[chars + (c - bc) * 4..chars + (c - bc) * 4 + 4];
            let index = usize::from(record[0]);
            if index >= nw
                || usize::from(record[1] >> 4) >= h[5]
                || usize::from(record[1] & 15) >= h[6]
                || usize::from(record[2] >> 2) >= h[7]
            {
                bail!("Invalid TFM character record")
            }
            if index != 0 {
                result.widths[c] = Some(scaled[index]);
            }
        }
        Ok(result)
    }
    pub fn advance(&self, character: i32) -> Result<i32> {
        usize::try_from(character)
            .ok()
            .and_then(|c| self.widths.get(c))
            .copied()
            .flatten()
            .ok_or_else(|| {
                tectonic_errors::Error::msg("XDV character is absent from its exact TFM")
            })
    }
}

#[derive(Clone)]
pub(super) struct MapRecord {
    pub font: String,
    pub postscript: Option<String>,
    pub encoding: Option<String>,
    pub encoding_name: Option<String>,
    pub extend: f64,
    pub slant: f64,
}
pub(super) struct MapTable {
    lines: BTreeMap<String, String>,
}
impl MapTable {
    pub fn parse(data: &[u8]) -> Result<Self> {
        if data.len() > 16 * 1024 * 1024 {
            bail!("Font map exceeds limit")
        }
        let text = std::str::from_utf8(data)?;
        let mut lines = BTreeMap::new();
        for line in text.lines() {
            let name = line.split_whitespace().next().unwrap_or("");
            if name.is_empty()
                || name
                    .chars()
                    .next()
                    .map(|c| matches!(c, '%' | '#' | ';' | '*'))
                    .unwrap_or(false)
            {
                continue;
            }
            if name.len() > 256 || lines.len() >= 100000 {
                bail!("Font map record limit")
            }
            if let Some(prior) = lines.insert(name.to_owned(), line.to_owned()) {
                if prior != line {
                    bail!("Ambiguous duplicate TeX font map entry: {}", name)
                }
            }
        }
        Ok(Self { lines })
    }
    pub fn get(&self, name: &str) -> Result<MapRecord> {
        let line = self.lines.get(name).ok_or_else(|| {
            tectonic_errors::Error::msg(format!("No exact outline map for TeX font {name}"))
        })?;
        let tokens = tokenize(line)?;
        let mut font = None;
        let mut encoding = None;
        let mut postscript = None;
        let mut encoding_name = None;
        let mut extend = 1.0;
        let mut slant = 0.0;
        for (index, (token, quoted)) in tokens.iter().enumerate().skip(1) {
            if *quoted {
                let commands: Vec<_> = token.split_whitespace().collect();
                if commands.len() % 2 != 0 {
                    bail!("Unsupported TeX map expression")
                }
                for pair in commands.chunks_exact(2) {
                    match pair[1] {
                        "SlantFont" => {
                            slant = pair[0].parse::<f64>()?;
                            if !slant.is_finite() || slant.abs() > 10.0 {
                                bail!("Invalid font slant")
                            }
                        }
                        "ExtendFont" => {
                            extend = pair[0].parse::<f64>()?;
                            if !extend.is_finite() || extend <= 0.0 || extend > 10.0 {
                                bail!("Invalid font extension")
                            }
                        }
                        "ReEncodeFont" => {
                            encoding_name = Some(pair[0].to_owned());
                        }
                        _ => bail!("Unsupported TeX font map operation: {}", pair[1]),
                    }
                }
            } else if token.starts_with('<') {
                let resource = token.trim_start_matches('<').trim_start_matches('[');
                validate_name(resource)?;
                if resource.ends_with(".enc") {
                    if encoding.replace(resource.to_owned()).is_some() {
                        bail!("Multiple font encodings")
                    }
                } else if [".pfb", ".pfa", ".ttf", ".otf"]
                    .iter()
                    .any(|s| resource.ends_with(s))
                {
                    if font.replace(resource.to_owned()).is_some() {
                        bail!("Multiple outline font resources")
                    }
                } else {
                    bail!("Unsupported TeX map resource")
                }
            } else if index == 1 {
                validate_name(token)?;
                postscript = Some(token.clone());
            } else if token.parse::<u32>().is_err() {
                bail!("Unsupported TeX map field")
            }
        }
        if encoding_name.is_some() != encoding.is_some() {
            bail!("TeX map reencoding has no exact encoding resource")
        }
        Ok(MapRecord {
            font: font.ok_or_else(|| {
                tectonic_errors::Error::msg("TeX font has no embedded outline resource")
            })?,
            postscript,
            encoding,
            encoding_name,
            extend,
            slant,
        })
    }
}
fn tokenize(line: &str) -> Result<Vec<(String, bool)>> {
    let mut result = Vec::new();
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c.is_whitespace() {
            continue;
        }
        if c == '%' {
            break;
        }
        if c == '"' {
            let mut word = String::new();
            let mut closed = false;
            for c in chars.by_ref() {
                if c == '"' {
                    closed = true;
                    break;
                }
                word.push(c);
            }
            if !closed {
                bail!("Unterminated TeX map expression")
            }
            result.push((word, true));
        } else {
            let mut word = c.to_string();
            while let Some(c) = chars.peek() {
                if c.is_whitespace() || *c == '%' {
                    break;
                }
                word.push(chars.next().unwrap());
            }
            result.push((word, false));
        }
        if result.len() > 64 {
            bail!("TeX font map expression limit")
        }
    }
    Ok(result)
}
pub(super) fn validate_name(name: &str) -> Result<()> {
    let path = std::path::Path::new(name);
    if name.is_empty()
        || name.len() > 4096
        || name.chars().any(char::is_control)
        || path.is_absolute()
        || path
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        bail!("Font resource name is outside the authorized snapshot/bundle")
    }
    Ok(())
}

pub(super) struct Encoding {
    pub name: String,
    pub glyphs: Vec<String>,
}
impl Encoding {
    pub fn parse(data: &[u8]) -> Result<Self> {
        if data.len() > 1024 * 1024 {
            bail!("Encoding resource exceeds limit")
        }
        let text = std::str::from_utf8(data)?;
        let text = text
            .lines()
            .map(|l| l.split('%').next().unwrap_or(""))
            .collect::<Vec<_>>()
            .join("\n");
        let start = text
            .find('[')
            .ok_or_else(|| tectonic_errors::Error::msg("Missing literal encoding array"))?;
        let end = text[start..]
            .find(']')
            .map(|n| n + start)
            .ok_or_else(|| tectonic_errors::Error::msg("Unclosed encoding array"))?;
        let prefix: Vec<_> = text[..start].split_whitespace().collect();
        if prefix.len() != 1 || !prefix[0].starts_with('/') {
            bail!("Unsupported encoding program")
        }
        let name = prefix[0][1..].to_owned();
        if text[end + 1..]
            .split_whitespace()
            .any(|s| s != "def" && s != "readonly")
        {
            bail!("Unsupported encoding mutation")
        }
        let mut glyphs = Vec::new();
        for token in text[start + 1..end].split_whitespace() {
            let raw = token.strip_prefix('/').ok_or_else(|| {
                tectonic_errors::Error::msg("Encoding contains executable content")
            })?;
            if raw.is_empty() || raw.len() > 256 {
                bail!("Invalid glyph name")
            }
            let mut bytes = Vec::new();
            let mut i = 0;
            while i < raw.len() {
                let byte = raw.as_bytes()[i];
                if byte == b'#' {
                    let hex = raw.get(i + 1..i + 3).ok_or_else(|| {
                        tectonic_errors::Error::msg("Invalid PostScript name escape")
                    })?;
                    bytes.push(u8::from_str_radix(hex, 16)?);
                    i += 3;
                } else {
                    bytes.push(byte);
                    i += 1;
                }
            }
            if bytes.iter().any(|b| !(33..=126).contains(b)) {
                bail!("Non-ASCII or control glyph name")
            }
            glyphs.push(String::from_utf8(bytes)?);
        }
        if glyphs.len() != 256 {
            bail!("Encoding must define all 256 character slots")
        }
        Ok(Self { name, glyphs })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn tfm_uses_tex_integer_advances_and_rejects_wrong_binding() {
        let mut tfm = Vec::new();
        for word in [14u16, 2, 65, 65, 2, 1, 1, 1, 0, 0, 0, 0] {
            tfm.extend(word.to_be_bytes());
        }
        tfm.extend(0x12345678u32.to_be_bytes());
        tfm.extend((10u32 << 20).to_be_bytes());
        tfm.extend([1, 0, 0, 0]);
        tfm.extend(0u32.to_be_bytes());
        tfm.extend(0x00080000u32.to_be_bytes());
        tfm.extend([0; 12]);
        let metrics = Tfm::parse(&tfm, 655361, 0x12345678, 655360).unwrap();
        assert_eq!(metrics.advance(65).unwrap(), 327680);
        assert!(metrics.advance(64).is_err());
        assert!(Tfm::parse(&tfm, 655361, 0x99999999, 655360).is_err());
        assert!(Tfm::parse(&tfm, 655361, 0x12345678, 720896).is_err());
        tfm[40..44].copy_from_slice(&0xfff80000u32.to_be_bytes());
        assert_eq!(
            Tfm::parse(&tfm, 655360, 0x12345678, 655360)
                .unwrap()
                .advance(65)
                .unwrap(),
            -327680
        );
    }
    #[test]
    fn exact_map_never_executes_or_substitutes() {
        let map = MapTable::parse(b"cmr10 CMR10 <cmr10.pfb\ntext FontName \"0.8 ExtendFont 0.167 SlantFont TestEncoding ReEncodeFont\" <test.enc <font.pfb\n").unwrap();
        assert_eq!(map.get("cmr10").unwrap().font, "cmr10.pfb");
        let text = map.get("text").unwrap();
        assert_eq!(text.extend, 0.8);
        assert_eq!(text.slant, 0.167);
        assert_eq!(text.encoding_name.as_deref(), Some("TestEncoding"));
        assert!(map.get("unmapped").is_err());
        assert!(MapTable::parse(b"bad Font \"1 system\" <font.pfb")
            .unwrap()
            .get("bad")
            .is_err());
        assert!(MapTable::parse(b"bad Font <../font.pfb")
            .unwrap()
            .get("bad")
            .is_err());
    }
    #[test]
    fn encoding_is_literal_exact_and_bounded() {
        let literal = format!(
            "/Exact [{}] readonly def",
            (0..256)
                .map(|n| format!("/g{n}"))
                .collect::<Vec<_>>()
                .join(" ")
        );
        let encoding = Encoding::parse(literal.as_bytes()).unwrap();
        assert_eq!(encoding.glyphs[80], "g80");
        assert!(Encoding::parse(format!("{literal} dup 80 /wrong put").as_bytes()).is_err());
        assert!(Encoding::parse(b"/Short [/A] def").is_err());
    }
}
