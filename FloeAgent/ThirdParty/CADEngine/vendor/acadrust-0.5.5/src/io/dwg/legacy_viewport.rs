//! R13/R14 view parameters live in ACAD/MVIEW extended data.
use crate::document::CadDocument;
use crate::entities::Viewport;
use crate::types::Vector3;
use crate::xdata::{ExtendedDataRecord, XDataValue as X};

fn mview_range(values: &[X]) -> Option<std::ops::Range<usize>> {
    for start in 0..values.len().saturating_sub(1) {
        if !matches!(&values[start], X::String(name) if name == "MVIEW")
            || !matches!(&values[start + 1], X::ControlString(s) if s == "{")
        {
            continue;
        }
        let mut depth = 0;
        for (index, value) in values.iter().enumerate().skip(start + 1) {
            match value {
                X::ControlString(s) if s == "{" => depth += 1,
                X::ControlString(s) if s == "}" => {
                    depth -= 1;
                    if depth == 0 {
                        return Some(start..index + 1);
                    }
                }
                _ => {}
            }
        }
    }
    None
}

pub(crate) fn record(v: &Viewport, document: &CadDocument) -> ExtendedDataRecord {
    let mut values = vec![
        X::String("MVIEW".into()),
        X::ControlString("{".into()),
        X::Integer16(16),
        X::Point3D(v.view_target),
        X::Point3D(v.view_direction),
        X::Real(v.twist_angle.to_degrees()),
        X::Real(v.view_height),
        X::Real(v.view_center.x),
        X::Real(v.view_center.y),
        X::Real(v.lens_length),
        X::Real(v.front_clip_z),
        X::Real(v.back_clip_z),
        X::Integer16((v.status.to_bits() & 0x1F) as i16),
        X::Integer16(v.circle_sides),
        X::Integer16(v.status.fast_zoom as i16),
        X::Integer16(v.ucs_icon_visible as i16 | ((v.ucs_at_origin as i16) << 1)),
        X::Integer16(v.status.snap_on as i16),
        X::Integer16(v.status.grid_on as i16),
        X::Integer16(v.status.isometric_snap as i16),
        X::Integer16(if v.status.iso_pair_right {
            2
        } else if v.status.iso_pair_top {
            1
        } else {
            0
        }),
        X::Real(v.snap_angle.to_degrees()),
        X::Real(v.snap_base.x),
        X::Real(v.snap_base.y),
        X::Real(v.snap_spacing.x),
        X::Real(v.snap_spacing.y),
        X::Real(v.grid_spacing.x),
        X::Real(v.grid_spacing.y),
        X::Integer16(v.status.hide_plot as i16),
        X::ControlString("{".into()),
    ];
    for layer in document
        .layers
        .iter()
        .filter(|layer| v.frozen_layers.contains(&layer.handle))
    {
        values.push(X::LayerName(layer.name.clone()));
    }
    values.extend([X::ControlString("}".into()), X::ControlString("}".into())]);
    let mut record = v
        .common
        .extended_data
        .records()
        .iter()
        .find(|record| record.application_name.eq_ignore_ascii_case("ACAD"))
        .cloned()
        .unwrap_or_else(|| ExtendedDataRecord::new("ACAD"));
    if let Some(range) = mview_range(&record.values) {
        record.values.splice(range, values);
    } else {
        record.values.extend(values);
    }
    record
}

pub(crate) fn restore(v: &mut Viewport, layer_handle: impl Fn(&str) -> Option<crate::Handle>) {
    let Some(record) = v
        .common
        .extended_data
        .records()
        .iter()
        .find(|record| record.application_name.eq_ignore_ascii_case("ACAD"))
    else {
        return;
    };
    let Some(range) = mview_range(&record.values) else {
        return;
    };
    let values = &record.values[range.start + 1..range.end];
    if values.len() < 30
        || !matches!(&values[0], X::ControlString(s) if s == "{")
        || !matches!(&values[1], X::Integer16(16))
        || !matches!(&values[2], X::Point3D(_))
        || !matches!(&values[3], X::Point3D(_))
        || !matches!(&values[27], X::ControlString(s) if s == "{")
        || !values[4..11]
            .iter()
            .all(|value| matches!(value, X::Real(_)))
        || !values[11..19]
            .iter()
            .all(|value| matches!(value, X::Integer16(_)))
        || !values[19..26]
            .iter()
            .all(|value| matches!(value, X::Real(_)))
        || !matches!(&values[26], X::Integer16(_))
    {
        return;
    }
    let real = |i: usize| {
        if let X::Real(v) = values[i + 2] {
            v
        } else {
            0.0
        }
    };
    let int = |i: usize| {
        if let X::Integer16(v) = values[i + 2] {
            v
        } else {
            0
        }
    };
    let point = |i: usize| {
        if let X::Point3D(v) = values[i + 2] {
            v
        } else {
            Vector3::ZERO
        }
    };
    v.view_target = point(0);
    v.view_direction = point(1);
    v.twist_angle = real(2).to_radians();
    v.view_height = real(3);
    v.view_center = Vector3::new(real(4), real(5), 0.0);
    v.lens_length = real(6);
    v.front_clip_z = real(7);
    v.back_clip_z = real(8);
    v.status = crate::entities::ViewportStatusFlags::from_bits(int(9) as i32 | 0x8000);
    v.circle_sides = int(10);
    v.status.fast_zoom = int(11) != 0;
    v.ucs_icon_visible = int(12) & 1 != 0;
    v.ucs_at_origin = int(12) & 2 != 0;
    v.status.snap_on = int(13) != 0;
    v.status.grid_on = int(14) != 0;
    v.status.isometric_snap = int(15) != 0;
    v.snap_angle = real(17).to_radians();
    v.status.iso_pair_top = int(16) == 1;
    v.status.iso_pair_right = int(16) == 2;
    v.snap_base = Vector3::new(real(18), real(19), 0.0);
    v.snap_spacing = Vector3::new(real(20), real(21), 0.0);
    v.grid_spacing = Vector3::new(real(22), real(23), 0.0);
    v.status.hide_plot = int(24) != 0;
    v.frozen_layers = values[28..]
        .iter()
        .take_while(|value| !matches!(value, X::ControlString(s) if s == "}"))
        .filter_map(|value| {
            if let X::LayerName(name) = value {
                layer_handle(name)
            } else {
                None
            }
        })
        .collect();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mview_update_preserves_unrelated_application_values() {
        let doc = CadDocument::new();
        let mut viewport = Viewport::new();
        let mut original = record(&viewport, &doc);
        original.values.insert(0, X::Integer32(123));
        original.values.push(X::String("OTHER".into()));
        viewport.common.extended_data.add_record(original);
        viewport.view_height = 77.;
        let updated = record(&viewport, &doc);
        assert_eq!(updated.values.first(), Some(&X::Integer32(123)));
        assert_eq!(updated.values.last(), Some(&X::String("OTHER".into())));
        assert_eq!(
            updated
                .values
                .iter()
                .filter(|v| matches!(v,X::String(s) if s=="MVIEW"))
                .count(),
            1
        );
        viewport.common.extended_data.upsert_record(updated);
        viewport.view_height = 0.;
        restore(&mut viewport, |_| None);
        assert_eq!(viewport.view_height, 77.);
    }

    #[test]
    fn truncated_mview_does_not_change_viewport() {
        let mut viewport = Viewport::new();
        let mut data = ExtendedDataRecord::new("ACAD");
        data.values = vec![X::String("MVIEW".into()), X::ControlString("{".into())];
        viewport.common.extended_data.add_record(data);
        let expected = viewport.clone();
        restore(&mut viewport, |_| None);
        assert_eq!(viewport, expected);
    }

    #[test]
    fn plain_mview_string_does_not_consume_unrelated_data() {
        let doc = CadDocument::new();
        let mut viewport = Viewport::new();
        let mut data = ExtendedDataRecord::new("ACAD");
        data.values = vec![X::String("MVIEW".into()), X::Integer32(123)];
        viewport.common.extended_data.add_record(data.clone());
        let updated = record(&viewport, &doc);
        assert_eq!(updated.values[..2], data.values);
        viewport.common.extended_data.upsert_record(updated);
        viewport.view_height = 0.;
        restore(&mut viewport, |_| None);
        assert_eq!(viewport.view_height, Viewport::new().view_height);
    }

    #[test]
    fn malformed_mview_scalar_does_not_reset_view_parameters() {
        let doc = CadDocument::new();
        let mut viewport = Viewport::new();
        let mut data = record(&viewport, &doc);
        data.values[7] = X::Integer32(123);
        viewport.common.extended_data.add_record(data);
        let expected = viewport.clone();
        restore(&mut viewport, |_| None);
        assert_eq!(viewport, expected);
    }
}
