// SPDX-License-Identifier: MIT OR Apache-2.0
// R4 CAM tool library validation (r4/CONTRACT.md + coordinator corrections).
//
// IDs allow UUIDs: non-empty, <= 96 UTF-8 bytes, charset [A-Za-z0-9._-].
// Tool library size cap is 8 tools (a COUNT cap, not an ID length).
use crate::model::CamToolReq;
use crate::upstream_r4::tool_profile::{cutter_radius_at, UpToolKind, UpToolProfile};

pub const MAX_TOOLS: usize = 8;
pub const MAX_ID_BYTES: usize = 96;

/// Validate a CAM id: non-empty, <= 96 bytes, [A-Za-z0-9._-] only.
pub fn validate_id(kind: &str, id: &str) -> Result<(), String> {
    if id.is_empty() {
        return Err(format!("cam {kind}: id must be non-empty"));
    }
    if id.len() > MAX_ID_BYTES {
        return Err(format!(
            "cam {kind}: id '{id}' exceeds {MAX_ID_BYTES} UTF-8 bytes"
        ));
    }
    if !id
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'_' || b == b'-')
    {
        return Err(format!(
            "cam {kind}: id '{id}' must be [A-Za-z0-9._-] (UUIDs allowed)"
        ));
    }
    Ok(())
}

#[derive(Clone, Debug)]
pub struct CamTool {
    pub id: String,
    pub name: String,
    pub profile: UpToolProfile,
    pub gauge_length_mm: Option<f64>,
    /// R2 assembly (validated) when the tool carries one.
    pub assembly: Option<crate::assembly::ToolAssembly>,
    /// Non-fatal observations recorded into the op report `limits`.
    pub notes: Vec<String>,
}

impl CamTool {
    pub fn radius(&self) -> f64 {
        self.profile.diameter * 0.5
    }

    /// Real cutting profile radius at axial height h above the tip.
    pub fn radius_at(&self, h: f64) -> f64 {
        cutter_radius_at(&self.profile, h)
    }

    pub fn validate_many(reqs: &[CamToolReq]) -> Result<Vec<CamTool>, String> {
        if reqs.is_empty() {
            return Err("cam: at least one tool is required".into());
        }
        if reqs.len() > MAX_TOOLS {
            return Err(format!(
                "cam: tool library holds {} tools, exceeding the {MAX_TOOLS} cap",
                reqs.len()
            ));
        }
        let mut out = Vec::with_capacity(reqs.len());
        for t in reqs {
            validate_id("tool", &t.id)?;
            if out.iter().any(|x: &CamTool| x.id == t.id) {
                return Err(format!("cam: duplicate tool id '{}'", t.id));
            }
            out.push(Self::validate_one(t)?);
        }
        Ok(out)
    }

    pub(crate) fn validate_one(t: &CamToolReq) -> Result<CamTool, String> {
        let d = t.diameter_mm;
        let l = t.cutting_length_mm;
        if !d.is_finite() || d <= 0.0 || d > 1000.0 {
            return Err(format!(
                "cam tool '{}': diameterMM must be finite in 0 < d <= 1000",
                t.id
            ));
        }
        if !l.is_finite() || l <= 0.0 || l > 1000.0 {
            return Err(format!(
                "cam tool '{}': cuttingLengthMM must be finite in 0 < l <= 1000",
                t.id
            ));
        }
        let kind = match t.kind.as_str() {
            "flatEndMill" => UpToolKind::FlatEndMill,
            "ballNose" => UpToolKind::BallNose,
            "drill" => UpToolKind::Drill,
            other => {
                return Err(format!(
                    "cam tool '{}': unknown kind '{other}' (expected flatEndMill|ballNose|drill)",
                    t.id
                ))
            }
        };
        let mut notes = Vec::new();
        let tip_angle = match kind {
            UpToolKind::Drill => match t.tip_angle_degrees {
                Some(a) if a.is_finite() && (10.0..=179.0).contains(&a) => a,
                Some(_) => {
                    return Err(format!(
                        "cam tool '{}': tipAngleDegrees must be finite in 10...179 for drill",
                        t.id
                    ))
                }
                None => {
                    return Err(format!(
                        "cam tool '{}': drill requires tipAngleDegrees (10...179)",
                        t.id
                    ))
                }
            },
            _ => {
                if let Some(a) = t.tip_angle_degrees {
                    if !a.is_finite() {
                        return Err(format!(
                            "cam tool '{}': tipAngleDegrees must be finite when supplied",
                            t.id
                        ));
                    }
                    notes.push(format!(
                        "tool '{}': tipAngleDegrees ignored for kind {}",
                        t.id, t.kind
                    ));
                }
                0.0
            }
        };
        let gauge_length_mm = match t.gauge_length_mm {
            Some(g) if g.is_finite() && (0.0..=1000.0).contains(&g) => Some(g),
            Some(_) => {
                return Err(format!(
                    "cam tool '{}': gaugeLengthMM must be finite in 0...1000",
                    t.id
                ))
            }
            None => None,
        };
        let assembly = match &t.assembly {
            Some(a) => {
                // R2 contract validation: shank/holder vs cutting dimensions.
                Some(crate::assembly::ToolAssembly::validate(a, d * 0.5, l).map_err(|e| {
                    format!("cam tool '{}': assembly invalid: {e}", t.id)
                })?)
            }
            None => None,
        };
        Ok(CamTool {
            id: t.id.clone(),
            name: t.name.clone(),
            profile: UpToolProfile {
                kind,
                diameter: d,
                flute_length: l,
                tip_angle_degrees: tip_angle,
            },
            gauge_length_mm,
            assembly,
            notes,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tool(id: &str, kind: &str) -> CamToolReq {
        CamToolReq {
            id: id.into(),
            name: String::new(),
            kind: kind.into(),
            diameter_mm: 6.0,
            cutting_length_mm: 20.0,
            tip_angle_degrees: None,
            gauge_length_mm: None,
            assembly: None,
        }
    }

    #[test]
    fn ids_allow_uuid_charset_and_reject_others() {
        assert!(validate_id("tool", "550E8400-E29B-41D4-A716-446655440000").is_ok());
        assert!(validate_id("tool", "op_1.2-3").is_ok());
        assert!(validate_id("tool", "").is_err());
        assert!(validate_id("tool", "has space").is_err());
        assert!(validate_id("tool", "has/slash").is_err());
        let long = "a".repeat(97);
        assert!(validate_id("tool", &long).is_err());
        assert!(validate_id("tool", &"a".repeat(96)).is_ok());
    }

    #[test]
    fn tool_cap_is_eight_and_duplicates_fail() {
        let tools: Vec<_> = (0..9).map(|i| tool(&format!("t{i}"), "flatEndMill")).collect();
        assert!(CamTool::validate_many(&tools).is_err());
        let tools: Vec<_> = (0..8).map(|i| tool(&format!("t{i}"), "flatEndMill")).collect();
        assert!(CamTool::validate_many(&tools).is_ok());
        let tools = vec![tool("a", "flatEndMill"), tool("a", "drill")];
        assert!(CamTool::validate_many(&tools).is_err());
    }

    #[test]
    fn drill_requires_tip_angle_and_known_kinds_only() {
        assert!(CamTool::validate_one(&tool("d", "drill")).is_err());
        let mut d = tool("d", "drill");
        d.tip_angle_degrees = Some(118.0);
        assert!(CamTool::validate_one(&d).is_ok());
        d.tip_angle_degrees = Some(5.0);
        assert!(CamTool::validate_one(&d).is_err());
        assert!(CamTool::validate_one(&tool("x", "bullNose")).is_err());
    }
}
