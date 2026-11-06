// SPDX-License-Identifier: MIT
// Extracted from charlatanshost/OpenMill@0432a8c540d1187dc6cb9383ce1b4f2dd97287f6
// (openmill-core/src/strategies/pocket_clearing.rs, raster core ~lines 155-228),
// carried under the upstream MIT license option (see ../LICENSE-MIT).
//
// Change map (Floe adaptations):
//  * Coordinates are frame-local (u, v) pairs with the layer depth handled by
//    the caller; upstream worked in world XYZ with Z layers inline.
//  * The hard-coded 1.0 mm row chord step became the caller-supplied
//    `chord_mm` parameter.
//  * The upstream "pocket smaller than tool -> silently continue" defect is
//    NOT carried: callers must pre-check the inset and fail explicitly.
//  * Row endpoints alternate direction (zigzag) exactly like upstream; the
//    plunge at row start and retract at row end are the CALLER's job
//    (explicit moves, r4 contract), this only yields the row polylines.
//  * Workload guards (Root review 2026-11-04): generation-time caps on the
//    row count and per-row subdivision with finiteness checks, so a hostile
//    stepOver/chord cannot loop or allocate without bound BEFORE the runtime
//    pose budget ever sees the moves.

/// One raster row: ordered (u, v) points at a constant depth.
pub struct UpRow {
    pub points: Vec<(f64, f64)>,
}

const MAX_ROWS: usize = 4096;
const MAX_STEPS_PER_ROW: usize = 100_000;

/// Zigzag rows over a circle footprint. `inset` is tool radius + wall skin;
/// rows are clipped to radius `r - inset` around `centre`. Returns rows in
/// scan order (alternating direction); empty when the footprint is empty.
pub fn circle_rows(
    centre: (f64, f64),
    r: f64,
    inset: f64,
    step_over: f64,
    chord_mm: f64,
) -> Result<Vec<UpRow>, String> {
    let max_r = (r - inset).max(0.0);
    let x_min = centre.0 - max_r;
    let x_max = centre.0 + max_r;
    let y_min = centre.1 - max_r;
    let y_max = centre.1 + max_r;
    zigzag(
        x_min,
        x_max,
        y_min,
        y_max,
        step_over,
        chord_mm,
        &|x, y| {
            let dx = x - centre.0;
            let dy = y - centre.1;
            dx * dx + dy * dy <= max_r * max_r
        },
    )
}

/// Zigzag rows over the full rectangle [x_min, x_max] x [y_min, y_max].
pub fn rect_rows(
    x_min: f64,
    x_max: f64,
    y_min: f64,
    y_max: f64,
    step_over: f64,
    chord_mm: f64,
) -> Result<Vec<UpRow>, String> {
    zigzag(x_min, x_max, y_min, y_max, step_over, chord_mm, &|_, _| true)
}

fn zigzag(
    x_min: f64,
    x_max: f64,
    y_min: f64,
    y_max: f64,
    step_over: f64,
    chord_mm: f64,
    include: &dyn Fn(f64, f64) -> bool,
) -> Result<Vec<UpRow>, String> {
    if x_min >= x_max || y_min >= y_max {
        return Ok(Vec::new());
    }
    if !step_over.is_finite() || step_over <= 0.0 {
        return Err("raster: stepOverMM must be finite and > 0".into());
    }
    if !chord_mm.is_finite() || chord_mm <= 0.0 {
        return Err("raster: row chord must be finite and > 0".into());
    }
    // Generation workload guard (before any allocation).
    let row_count = ((y_max - y_min) / step_over + 1.0).ceil();
    if !row_count.is_finite() || row_count as u64 > MAX_ROWS as u64 {
        return Err(format!(
            "raster: row count {row_count} exceeds the generation cap {MAX_ROWS}; increase stepOverMM"
        ));
    }
    let step_count = ((x_max - x_min) / chord_mm).ceil();
    if !step_count.is_finite() || step_count as u64 > MAX_STEPS_PER_ROW as u64 {
        return Err(format!(
            "raster: per-row subdivision {step_count} exceeds the generation cap {MAX_STEPS_PER_ROW}; increase the row chord"
        ));
    }
    let chord = chord_mm.max(0.05);
    let mut rows = Vec::new();
    let mut y = y_min;
    let mut forward = true;
    let mut guard = 0usize;
    loop {
        if y > y_max + 1e-12 {
            break;
        }
        guard += 1;
        if guard > MAX_ROWS {
            return Err("raster: row loop did not converge (workload guard)".into());
        }
        let (xa, xb) = if forward { (x_min, x_max) } else { (x_max, x_min) };
        let dist = (xb - xa).abs();
        let steps = (dist / chord).ceil().max(1.0) as usize;
        if steps == 0 || steps > MAX_STEPS_PER_ROW {
            return Err("raster: row subdivision guard tripped".into());
        }
        let mut row: Vec<(f64, f64)> = Vec::new();
        for i in 0..=steps {
            let t = i as f64 / steps as f64;
            let x = xa + (xb - xa) * t;
            if include(x, y) {
                row.push((x, y));
            }
        }
        // Drop consecutive duplicates (can occur at tight clip boundaries).
        row.dedup();
        if row.len() >= 2 {
            rows.push(UpRow { points: row });
        }
        let y_next = y + step_over;
        if !y_next.is_finite() {
            return Err("raster: non-finite row advance".into());
        }
        y = y_next;
        forward = !forward;
    }
    Ok(rows)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn circle_rows_clip_to_inset_disc() {
        let rows = circle_rows((0.0, 0.0), 10.0, 3.0, 2.0, 1.0).unwrap();
        assert!(!rows.is_empty());
        for row in &rows {
            for &(x, y) in &row.points {
                let d = (x * x + y * y).sqrt();
                assert!(d <= 7.0 + 1e-9, "point outside inset disc: {d}");
            }
        }
        // Too small a footprint yields no rows (caller turns this into a
        // failure — the upstream silent-continue defect is not carried).
        assert!(circle_rows((0.0, 0.0), 2.0, 3.0, 2.0, 1.0).unwrap().is_empty());
    }

    #[test]
    fn rect_rows_alternate_direction() {
        let rows = rect_rows(0.0, 10.0, 0.0, 6.0, 2.0, 1.0).unwrap();
        assert_eq!(rows.len(), 4);
        let first_x: Vec<f64> = rows.iter().map(|r| r.points[0].0).collect();
        assert_eq!(first_x, vec![0.0, 10.0, 0.0, 10.0]);
        for row in &rows {
            assert!(row.points.len() >= 2);
        }
    }

    #[test]
    fn hostile_steps_are_rejected_before_allocation() {
        // Tiny stepOver against a huge span: would be billions of rows.
        assert!(rect_rows(0.0, 10.0, 0.0, 1.0e9, 1.0e-300, 1.0).is_err());
        // Tiny chord against a huge span: would be billions of points per row.
        assert!(rect_rows(0.0, 1.0e9, 0.0, 1.0, 1.0, 1.0e-300).is_err());
        // Non-finite step.
        assert!(rect_rows(0.0, 1.0, 0.0, 1.0, f64::NAN, 1.0).is_err());
        assert!(rect_rows(0.0, 1.0, 0.0, 1.0, 1.0, f64::INFINITY).is_err());
    }
}
