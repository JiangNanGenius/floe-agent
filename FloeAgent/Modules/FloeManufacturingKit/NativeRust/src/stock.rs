// SPDX-License-Identifier: MIT OR Apache-2.0
// Bounded voxel stock for the prototype machining core.
//
// Workpiece frame: machine part Z is the spindle axis; the initial stock is a
// cylinder around Z spanning stock.zMinMM..stock.zMaxMM with radius
// stock.radiusMM. Occupancy lives at voxel centres on a regular grid.
//
// Turning removal semantics (frozen contract 2026-11-04): each supplied cut
// polyline is [radius, z] in the radial-Z half plane; paths are applied in
// order and each path is separate — implicit connecting/rapid moves never
// remove stock. A mostly-longitudinal segment cuts the radial envelope down
// to the interpolated radius over its z-span (tool approaches from outside);
// a mostly-radial (face) segment removes material with z >= the interpolated
// face plane over its radial span (tool approaches from +z).
//
// Tool nose treatment is a clearly bounded geometric approximation: the nose
// radius is not offset into the envelope; corner fillets are represented as
// sharp corners, so local corner deviation is bounded by the nose radius
// while longitudinal envelope cuts are exact to voxel resolution.
use nalgebra::{Point3, Vector3};

use crate::sdf::point_inside_cutter;

/// Initial stock envelope (R4 coordinator addition: optional rectangular
/// stock). Turning is only defined on `Cylinder` stock; box stock rejects
/// turning explicitly at the core level.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum StockShape {
    Cylinder { radius: f64 },
    Box,
}

pub struct Stock {
    pub nx: usize,
    pub ny: usize,
    pub nz: usize,
    pub h: f64,
    pub origin: [f64; 3],
    /// Declared physical upper planes, independent of ceil-rounded grid dimensions.
    pub physical_max: [f64; 3],
    pub shape: StockShape,
    occupied: Vec<bool>,
    removed_count: u64,
}

impl Stock {
    /// Cylinder stock around Z. `max_cells` is the explicit budget.
    pub fn cylinder(
        radius: f64,
        z_min: f64,
        z_max: f64,
        h: f64,
        max_cells: u64,
    ) -> Result<Self, String> {
        if !radius.is_finite()
            || !z_min.is_finite()
            || !z_max.is_finite()
            || radius <= 0.0
            || z_max <= z_min
            || !(0.02..=10.0).contains(&h)
        {
            return Err(
                "invalid stock: finite positive radius, ordered finite z extent and resolutionMM in 0.02...10 required"
                    .into(),
            );
        }
        let span = [2.0 * radius, 2.0 * radius, z_max - z_min];
        let (nx, ny, nz) = Self::grid_dims(&span, h)?;
        let cells = Self::cell_budget(nx, ny, nz, max_cells)?;
        let origin = [-radius, -radius, z_min];
        let mut stock = Stock {
            nx,
            ny,
            nz,
            h,
            origin,
            physical_max: [radius, radius, z_max],
            shape: StockShape::Cylinder { radius },
            occupied: vec![false; cells as usize],
            removed_count: 0,
        };
        let r2 = radius * radius;
        for iz in 0..nz {
            for iy in 0..ny {
                for ix in 0..nx {
                    let c = stock.center(ix, iy, iz);
                    if c[0] * c[0] + c[1] * c[1] <= r2 {
                        *stock.cell_mut(ix, iy, iz) = true;
                    }
                }
            }
        }
        stock.removed_count = 0;
        Ok(stock)
    }

    /// Rectangular stock spanning `min..=max` (closed extents, voxel centres
    /// inside). Z must match the study z extent; enforced by the caller.
    pub fn box_stock(
        min: [f64; 3],
        max: [f64; 3],
        h: f64,
        max_cells: u64,
    ) -> Result<Self, String> {
        if !min.iter().chain(max.iter()).all(|v| v.is_finite())
            || max.iter().zip(min.iter()).any(|(&hi, &lo)| hi <= lo)
            || !(0.02..=10.0).contains(&h)
        {
            return Err(
                "invalid stock: box stock requires finite minMM/maxMM with max > min on every axis and resolutionMM in 0.02...10"
                    .into(),
            );
        }
        let span = [
            max[0] - min[0],
            max[1] - min[1],
            max[2] - min[2],
        ];
        let (nx, ny, nz) = Self::grid_dims(&span, h)?;
        let cells = Self::cell_budget(nx, ny, nz, max_cells)?;
        let mut stock = Stock {
            nx,
            ny,
            nz,
            h,
            origin: min,
            physical_max: max,
            shape: StockShape::Box,
            occupied: vec![true; cells as usize],
            removed_count: 0,
        };
        // Every voxel centre lies inside the closed box by construction.
        stock.removed_count = 0;
        Ok(stock)
    }

    fn grid_dims(span: &[f64; 3], h: f64) -> Result<(usize, usize, usize), String> {
        let nx = (span[0] / h).ceil() as usize;
        let ny = (span[1] / h).ceil() as usize;
        let nz = (span[2] / h).ceil() as usize;
        if nx == 0 || ny == 0 || nz == 0 {
            return Err("invalid stock: zero grid extent".into());
        }
        Ok((nx, ny, nz))
    }

    fn cell_budget(nx: usize, ny: usize, nz: usize, max_cells: u64) -> Result<u64, String> {
        let cells = (nx as u64)
            .checked_mul(ny as u64)
            .and_then(|v| v.checked_mul(nz as u64))
            .ok_or_else(|| "stock grid dimension overflow".to_string())?;
        if cells == 0 || cells > max_cells {
            return Err(format!(
                "budget: stock grid needs {cells} cells, exceeding maxCells budget {max_cells}; increase resolutionMM or the budget explicitly"
            ));
        }
        Ok(cells)
    }

    pub fn is_cylinder(&self) -> bool {
        matches!(self.shape, StockShape::Cylinder { .. })
    }

    /// Analytic initial volume of the stock envelope [mm^3].
    pub fn analytic_volume(&self) -> f64 {
        match self.shape {
            StockShape::Cylinder { radius } => {
                let z_span = self.nz as f64 * self.h;
                std::f64::consts::PI * radius * radius * z_span
            }
            StockShape::Box => {
                (self.nx as f64 * self.h)
                    * (self.ny as f64 * self.h)
                    * (self.nz as f64 * self.h)
            }
        }
    }

    #[inline]
    fn idx(&self, ix: usize, iy: usize, iz: usize) -> usize {
        (iz * self.ny + iy) * self.nx + ix
    }

    #[inline]
    fn cell_mut(&mut self, ix: usize, iy: usize, iz: usize) -> &mut bool {
        let i = self.idx(ix, iy, iz);
        &mut self.occupied[i]
    }

    #[inline]
    pub fn center(&self, ix: usize, iy: usize, iz: usize) -> [f64; 3] {
        [
            self.origin[0] + (ix as f64 + 0.5) * self.h,
            self.origin[1] + (iy as f64 + 0.5) * self.h,
            self.origin[2] + (iz as f64 + 0.5) * self.h,
        ]
    }

    pub fn cell_count(&self) -> u64 {
        (self.nx * self.ny * self.nz) as u64
    }

    pub fn occupied_count(&self) -> u64 {
        self.occupied.iter().filter(|&&v| v).count() as u64
    }

    pub fn removed_count(&self) -> u64 {
        self.removed_count
    }

    pub fn cell_volume(&self) -> f64 {
        self.h * self.h * self.h
    }

    pub fn z_range(&self) -> (f64, f64) {
        (self.origin[2], self.origin[2] + self.nz as f64 * self.h)
    }

    /// Maximum occupied-voxel centre radius in z-slab `iz` (0 when empty).
    pub fn max_radius_in_slab(&self, iz: usize) -> f64 {
        let mut max_r = 0.0;
        for iy in 0..self.ny {
            for ix in 0..self.nx {
                if self.occupied[self.idx(ix, iy, iz)] {
                    let c = self.center(ix, iy, iz);
                    let r = (c[0] * c[0] + c[1] * c[1]).sqrt();
                    if r > max_r {
                        max_r = r;
                    }
                }
            }
        }
        max_r
    }

    /// R2: bounded candidate query for tool-assembly vs remaining-stock
    /// collision. Returns the CENTRES of occupied cells whose closed voxel
    /// cuboid (centre ± h/2) intersects the closed AABB `min..=max`.
    /// Each occupied cell is an exact cuboid solid of side `h`, so a Parry
    /// query against these cuboids is exact w.r.t. the voxel material solid
    /// (the approximation resolution is the voxel size `h`, recorded by the
    /// caller in collision rows). The AABB must be finite and is clamped to
    /// the stock grid; the result is bounded by the total cell count.
    pub fn occupied_centers_in_aabb(&self, min: [f64; 3], max: [f64; 3]) -> Vec<[f64; 3]> {
        if !min.iter().chain(max.iter()).all(|v| v.is_finite())
            || max.iter().zip(min.iter()).any(|(&hi, &lo)| hi < lo)
        {
            return Vec::new();
        }
        // Cell i spans the CLOSED interval [o + i*h, o + (i+1)*h]; it
        // overlaps the closed AABB iff cell_min <= max && cell_max >= min.
        // The index windows below are the exact integer solutions padded
        // inward only (still verified per cell, so the result is exact).
        let ix0 = ((min[0] - self.origin[0]) / self.h - 1.0).floor().max(0.0) as usize;
        let iy0 = ((min[1] - self.origin[1]) / self.h - 1.0).floor().max(0.0) as usize;
        let iz0 = ((min[2] - self.origin[2]) / self.h - 1.0).floor().max(0.0) as usize;
        let ix1 = (((max[0] - self.origin[0]) / self.h + 1.0).ceil() as usize).min(self.nx);
        let iy1 = (((max[1] - self.origin[1]) / self.h + 1.0).ceil() as usize).min(self.ny);
        let iz1 = (((max[2] - self.origin[2]) / self.h + 1.0).ceil() as usize).min(self.nz);
        let mut out = Vec::new();
        for iz in iz0..iz1 {
            for iy in iy0..iy1 {
                for ix in ix0..ix1 {
                    if !self.occupied[self.idx(ix, iy, iz)] {
                        continue;
                    }
                    let c = self.center(ix, iy, iz);
                    let half = self.h * 0.5;
                    let overlaps = (0..3).all(|k| c[k] - half <= max[k] && c[k] + half >= min[k]);
                    if overlaps {
                        out.push(c);
                    }
                }
            }
        }
        out
    }

    /// Apply one turning cut polyline ([radius, z] points) to the stock.
    /// Returns the number of voxels removed by this path.
    ///
    /// `negative_z_face` (R5 dual-spindle backside facing): longitudinal
    /// envelope cuts are unchanged; a mostly-radial (face) segment removes
    /// material with z <= the interpolated face plane (tool approaches from
    /// -z) instead of z >= the plane. The stock grid itself is never
    /// mirrored — only the face-cut direction flips.
    pub fn apply_turning_path(
        &mut self,
        points: &[[f64; 2]],
        negative_z_face: bool,
    ) -> Result<u64, String> {
        if points.len() < 2 {
            return Ok(0); // a point or an empty path sweeps nothing
        }
        let mut removed = 0u64;
        for w in points.windows(2) {
            let (r0, z0) = (w[0][0], w[0][1]);
            let (r1, z1) = (w[1][0], w[1][1]);
            if ![r0, z0, r1, z1].iter().all(|v| v.is_finite()) {
                return Err("turning path contains non-finite [radius, z] point".into());
            }
            if r0 < 0.0 || r1 < 0.0 {
                return Err("turning path radius must be nonnegative".into());
            }
            let dr = r1 - r0;
            let dz = z1 - z0;
            if dz == 0.0 && dr == 0.0 {
                continue;
            }
            if dz.abs() >= dr.abs() {
                // Longitudinal / taper cut: envelope approaches from outside.
                let (za, zb, ra, rb) = if z0 <= z1 {
                    (z0, z1, r0, r1)
                } else {
                    (z1, z0, r1, r0)
                };
                for iz in 0..self.nz {
                    let zc = self.origin[2] + (iz as f64 + 0.5) * self.h;
                    if zc < za || zc > zb {
                        continue;
                    }
                    let t = if zb > za {
                        ((zc - za) / (zb - za)).clamp(0.0, 1.0)
                    } else {
                        0.0
                    };
                    let r_cut = ra + t * (rb - ra);
                    for iy in 0..self.ny {
                        for ix in 0..self.nx {
                            let i = self.idx(ix, iy, iz);
                            if !self.occupied[i] {
                                continue;
                            }
                            let c = self.center(ix, iy, iz);
                            let r = (c[0] * c[0] + c[1] * c[1]).sqrt();
                            if r >= r_cut {
                                self.occupied[i] = false;
                                removed += 1;
                            }
                        }
                    }
                }
            } else {
                // Face cut: approach from +z (positiveZ, default) removes
                // z >= the face plane; approach from -z (negativeZ backside
                // facing, R5) removes z <= the face plane.
                let (ra, rb, za, zb) = if r0 <= r1 {
                    (r0, r1, z0, z1)
                } else {
                    (r1, r0, z1, z0)
                };
                for iz in 0..self.nz {
                    let zc = self.origin[2] + (iz as f64 + 0.5) * self.h;
                    for iy in 0..self.ny {
                        for ix in 0..self.nx {
                            let i = self.idx(ix, iy, iz);
                            if !self.occupied[i] {
                                continue;
                            }
                            let c = self.center(ix, iy, iz);
                            let r = (c[0] * c[0] + c[1] * c[1]).sqrt();
                            if r < ra || r > rb {
                                continue;
                            }
                            let t = if rb > ra {
                                ((r - ra) / (rb - ra)).clamp(0.0, 1.0)
                            } else {
                                0.0
                            };
                            let z_cut = za + t * (zb - za);
                            let remove = if negative_z_face {
                                zc <= z_cut
                            } else {
                                zc >= z_cut
                            };
                            if remove {
                                self.occupied[i] = false;
                                removed += 1;
                            }
                        }
                    }
                }
            }
        }
        self.removed_count += removed;
        Ok(removed)
    }

    /// Remove an oriented tool of revolution at one pose. `radius_at` returns
    /// the cutting radius at axial height `t` in [0, length] above the tip
    /// (R4 real tool profiles: flat / ball-nose / drill cone+barrel). Only
    /// voxels in the tool's expanded AABB are tested; strictly-inside test
    /// (centre inside the closed profile, boundary kept). No target
    /// protection: the tool gouges any material it overlaps.
    pub fn remove_oriented_profile(
        &mut self,
        tip: &Point3<f64>,
        axis: &Vector3<f64>,
        envelope_radius: f64,
        length: f64,
        radius_at: &dyn Fn(f64) -> f64,
    ) -> u64 {
        let end = tip + axis * length;
        let (min_x, max_x) = (tip.x.min(end.x) - envelope_radius, tip.x.max(end.x) + envelope_radius);
        let (min_y, max_y) = (tip.y.min(end.y) - envelope_radius, tip.y.max(end.y) + envelope_radius);
        let (min_z, max_z) = (tip.z.min(end.z) - envelope_radius, tip.z.max(end.z) + envelope_radius);
        let ix0 = ((min_x - self.origin[0]) / self.h).floor().max(0.0) as usize;
        let iy0 = ((min_y - self.origin[1]) / self.h).floor().max(0.0) as usize;
        let iz0 = ((min_z - self.origin[2]) / self.h).floor().max(0.0) as usize;
        let ix1 = (((max_x - self.origin[0]) / self.h).ceil() as usize)
            .min(self.nx.saturating_sub(1));
        let iy1 = (((max_y - self.origin[1]) / self.h).ceil() as usize)
            .min(self.ny.saturating_sub(1));
        let iz1 = (((max_z - self.origin[2]) / self.h).ceil() as usize)
            .min(self.nz.saturating_sub(1));
        let mut removed = 0u64;
        for iz in iz0..=iz1 {
            for iy in iy0..=iy1 {
                for ix in ix0..=ix1 {
                    let i = self.idx(ix, iy, iz);
                    if !self.occupied[i] {
                        continue;
                    }
                    let c = self.center(ix, iy, iz);
                    let p = Point3::new(c[0], c[1], c[2]);
                    let to_voxel = p - tip;
                    let axial = to_voxel.dot(axis);
                    if axial < 0.0 || axial > length {
                        continue;
                    }
                    let radial_vec = to_voxel - axis * axial;
                    let radial = radial_vec.norm();
                    if radial < radius_at(axial) {
                        self.occupied[i] = false;
                        removed += 1;
                    }
                }
            }
        }
        self.removed_count += removed;
        removed
    }

    /// True when the real tool profile (solid of revolution) intersects any
    /// remaining voxel centre in its AABB. Used for rapid-through-stock
    /// feedback: envelope-free, exact w.r.t. the voxel solid.
    pub fn profile_intersects_material(
        &self,
        tip: &Point3<f64>,
        axis: &Vector3<f64>,
        envelope_radius: f64,
        length: f64,
        radius_at: &dyn Fn(f64) -> f64,
    ) -> bool {
        let end = tip + axis * length;
        let (min_x, max_x) = (tip.x.min(end.x) - envelope_radius, tip.x.max(end.x) + envelope_radius);
        let (min_y, max_y) = (tip.y.min(end.y) - envelope_radius, tip.y.max(end.y) + envelope_radius);
        let (min_z, max_z) = (tip.z.min(end.z) - envelope_radius, tip.z.max(end.z) + envelope_radius);
        let ix0 = ((min_x - self.origin[0]) / self.h).floor().max(0.0) as usize;
        let iy0 = ((min_y - self.origin[1]) / self.h).floor().max(0.0) as usize;
        let iz0 = ((min_z - self.origin[2]) / self.h).floor().max(0.0) as usize;
        let ix1 = (((max_x - self.origin[0]) / self.h).ceil() as usize)
            .min(self.nx.saturating_sub(1));
        let iy1 = (((max_y - self.origin[1]) / self.h).ceil() as usize)
            .min(self.ny.saturating_sub(1));
        let iz1 = (((max_z - self.origin[2]) / self.h).ceil() as usize)
            .min(self.nz.saturating_sub(1));
        for iz in iz0..=iz1 {
            for iy in iy0..=iy1 {
                for ix in ix0..=ix1 {
                    if !self.occupied[self.idx(ix, iy, iz)] {
                        continue;
                    }
                    let c = self.center(ix, iy, iz);
                    let to_voxel = Point3::new(c[0], c[1], c[2]) - tip;
                    let axial = to_voxel.dot(axis);
                    if axial < 0.0 || axial > length {
                        continue;
                    }
                    let radial = (to_voxel - axis * axial).norm();
                    if radial < radius_at(axial) {
                        return true;
                    }
                }
            }
        }
        false
    }

    /// Remove the oriented finite-cylinder cutter at one pose. Only voxels in
    /// the cutter's expanded AABB are tested. Returns removed voxel count.
    /// No target protection: the cutter gouges any material it overlaps.
    pub fn remove_oriented_cutter(
        &mut self,
        tip: &Point3<f64>,
        axis: &Vector3<f64>,
        radius: f64,
        length: f64,
    ) -> u64 {
        // AABB of the cutter segment expanded by radius.
        let end = tip + axis * length;
        let (min_x, max_x) = (tip.x.min(end.x) - radius, tip.x.max(end.x) + radius);
        let (min_y, max_y) = (tip.y.min(end.y) - radius, tip.y.max(end.y) + radius);
        let (min_z, max_z) = (tip.z.min(end.z) - radius, tip.z.max(end.z) + radius);
        let ix0 = ((min_x - self.origin[0]) / self.h).floor().max(0.0) as usize;
        let iy0 = ((min_y - self.origin[1]) / self.h).floor().max(0.0) as usize;
        let iz0 = ((min_z - self.origin[2]) / self.h).floor().max(0.0) as usize;
        let ix1 = (((max_x - self.origin[0]) / self.h).ceil() as usize)
            .min(self.nx.saturating_sub(1));
        let iy1 = (((max_y - self.origin[1]) / self.h).ceil() as usize)
            .min(self.ny.saturating_sub(1));
        let iz1 = (((max_z - self.origin[2]) / self.h).ceil() as usize)
            .min(self.nz.saturating_sub(1));
        let mut removed = 0u64;
        for iz in iz0..=iz1 {
            for iy in iy0..=iy1 {
                for ix in ix0..=ix1 {
                    let i = self.idx(ix, iy, iz);
                    if !self.occupied[i] {
                        continue;
                    }
                    let c = self.center(ix, iy, iz);
                    let p = Point3::new(c[0], c[1], c[2]);
                    if point_inside_cutter(&p, tip, axis, radius, length) {
                        self.occupied[i] = false;
                        removed += 1;
                    }
                }
            }
        }
        self.removed_count += removed;
        removed
    }

    /// R5: export the continuation state (INTERFACES.md shared schema).
    /// Indices are emitted sorted/unique by construction; `removedCount`
    /// stays cumulative from the original initial occupancy.
    pub fn export_state(&self) -> crate::model::StockState {
        let (shape, radius_mm) = match self.shape {
            StockShape::Cylinder { radius } => ("cylinder", Some(radius)),
            StockShape::Box => ("box", None),
        };
        let mut occupied_indices = Vec::with_capacity(self.occupied_count() as usize);
        for (i, &occ) in self.occupied.iter().enumerate() {
            if occ {
                occupied_indices.push(i);
            }
        }
        crate::model::StockState {
            format_version: 1,
            dimensions: [self.nx, self.ny, self.nz],
            origin_mm: self.origin,
            resolution_mm: self.h,
            shape: shape.to_string(),
            radius_mm,
            declared_max_mm: Some(self.physical_max),
            occupied_indices,
            removed_count: self.removed_count,
        }
    }

    /// R5: continue from a supplied continuation state instead of the fresh
    /// initial envelope. Called immediately after construction, so the
    /// current occupancy is still the ORIGINAL initial occupancy. Any
    /// inconsistency is an explicit failure — corrupt state is never
    /// silently dropped, clamped or reset.
    pub fn apply_continuation(&mut self, state: &crate::model::StockState) -> Result<(), String> {
        if state.format_version != 1 {
            return Err("initialStockState: formatVersion must be 1".into());
        }
        if state.dimensions != [self.nx, self.ny, self.nz] {
            return Err(format!(
                "initialStockState: dimensions {:?} do not match the requested stock grid {:?}",
                state.dimensions,
                [self.nx, self.ny, self.nz]
            ));
        }
        if !state.origin_mm.iter().all(|v| v.is_finite())
            || state
                .origin_mm
                .iter()
                .zip(self.origin.iter())
                .any(|(&a, &b)| (a - b).abs() > 1e-9)
        {
            return Err("initialStockState: originMM does not match the requested stock origin".into());
        }
        if !state.resolution_mm.is_finite() || (state.resolution_mm - self.h).abs() > 1e-9 {
            return Err(
                "initialStockState: resolutionMM does not match the requested stock resolutionMM"
                    .into(),
            );
        }
        if let Some(maximum)=state.declared_max_mm {
            if maximum.iter().zip(self.physical_max.iter()).any(|(&a,&b)| !a.is_finite() || (a-b).abs()>1e-9) {
                return Err("initialStockState: declaredMaxMM does not match the physical stock envelope".into());
            }
        } else {
            let dimensions=[self.nx,self.ny,self.nz];
            if (0..3).any(|i| (self.origin[i]+dimensions[i] as f64*self.h-self.physical_max[i]).abs()>1e-9) {
                return Err("initialStockState: legacy checkpoint lacks exact end planes; regenerate its non-grid-aligned stock before continuation".into());
            }
        }
        match (state.shape.as_str(), &self.shape) {
            ("cylinder", StockShape::Cylinder { radius }) => {
                let r = state.radius_mm.ok_or_else(|| {
                    "initialStockState: shape cylinder requires radiusMM".to_string()
                })?;
                if !r.is_finite() || r <= 0.0 || (r - *radius).abs() > 1e-9 {
                    return Err(
                        "initialStockState: radiusMM does not match the requested stock radius"
                            .into(),
                    );
                }
            }
            ("box", StockShape::Box) => {
                if let Some(r) = state.radius_mm {
                    if r.is_finite() && r > 0.0 {
                        return Err(
                            "initialStockState: shape box must not carry a positive radiusMM"
                                .into(),
                        );
                    }
                }
            }
            (other, _) => {
                return Err(format!(
                    "initialStockState: shape '{other}' does not match the requested stock shape"
                ))
            }
        }
        // Sorted/unique/in-range, and every claimed cell must be part of the
        // ORIGINAL initial occupancy (no cell outside the envelope, and no
        // removed cell silently restored beyond the original envelope).
        let cells = self.cell_count() as usize;
        let mut prev: Option<usize> = None;
        for &idx in &state.occupied_indices {
            if idx >= cells {
                return Err(format!(
                    "initialStockState: occupied index {idx} out of range for {cells} cells"
                ));
            }
            if let Some(p) = prev {
                if idx <= p {
                    return Err(
                        "initialStockState: occupiedIndices must be sorted and unique".into(),
                    );
                }
            }
            if !self.occupied[idx] {
                return Err(format!(
                    "initialStockState: occupied index {idx} lies outside the original initial occupancy envelope (forged state refused)"
                ));
            }
            prev = Some(idx);
        }
        let initial = self.occupied_count();
        if state.occupied_indices.len() as u64 + state.removed_count != initial {
            return Err(format!(
                "initialStockState: occupancy + removedCount mismatch ({} + {} != original initial occupancy {initial})",
                state.occupied_indices.len(),
                state.removed_count
            ));
        }
        let mut occupied = vec![false; cells];
        for &idx in &state.occupied_indices {
            occupied[idx] = true;
        }
        self.occupied = occupied;
        self.removed_count = state.removed_count;
        Ok(())
    }

    /// A filled disc at every occupied Z layer is rotational stock. Rebuilding
    /// those verified discs as circular rings avoids representing a cylinder
    /// as a radial voxel staircase. Machined radii preserve each layer's voxel
    /// cross-sectional area; every untouched layer uses its declared radius,
    /// even when facing/turning has removed cells from a different layer.
    /// Holes, slots, asymmetric cuts and boxes deliberately use the general
    /// mesher instead. Occupancy, removed cells and reported volume do not change.
    pub fn axisymmetric_mesh(&self, max_triangles: u64) -> Option<(Vec<[f64; 3]>, Vec<[u32; 3]>)> {
        let nominal = match self.shape { StockShape::Cylinder { radius } => radius, StockShape::Box => return None };
        let mut radial = Vec::with_capacity(self.nx * self.ny);
        for iy in 0..self.ny { for ix in 0..self.nx {
            let p = self.center(ix, iy, 0);radial.push(p[0]*p[0]+p[1]*p[1]);
        } }
        let initial_disc_count=radial.iter().filter(|&&r2| r2<=nominal*nominal).count();
        let mut radii = Vec::with_capacity(self.nz);
        for iz in 0..self.nz {
            let mut count = 0usize;let mut outer = 0.0f64;let mut first_air = f64::INFINITY;
            for (xy, &r2) in radial.iter().enumerate() {
                if self.occupied[iz*self.nx*self.ny+xy] { count += 1;outer = outer.max(r2); }
                else { first_air = first_air.min(r2); }
            }
            if count == 0 { radii.push(0.0);continue; }
            // A missing centre or an angular notch cannot masquerade as a disc.
            if outer >= first_air - 1e-10 * nominal.max(1.0).powi(2) { return None; }
            let radius = if count == initial_disc_count { nominal }
                else { ((count as f64)*self.h*self.h/std::f64::consts::PI).sqrt().min(nominal) };
            radii.push(radius);
        }
        if radii.iter().all(|&r| r == 0.0) { return Some((vec![],vec![])); }
        // Runs preserve actual axial shoulders. No rounding of the machining
        // profile, speculative tip compensation or target-CAD substitution.
        let mut runs = Vec::<(usize,usize,f64)>::new();
        let mut iz = 0;
        while iz < self.nz {
            if radii[iz] == 0.0 { iz += 1;continue; }
            let start = iz;let radius = radii[iz];iz += 1;
            while iz < self.nz && (radii[iz]-radius).abs() < 1e-12 { iz += 1; }
            runs.push((start,iz,radius));
        }
        let groups = runs.iter().enumerate().filter(|(i,r)| *i == 0 || runs[*i-1].1 != r.0).count();
        let joins = runs.len()-groups;
        let faces_per_angle = (2*runs.len()+2*joins+2*groups) as u64;
        let angles = (max_triangles / faces_per_angle).min(128) as usize;
        if angles < 24 { return None; }
        let mut vertices = Vec::<[f64;3]>::new();let mut triangles = Vec::<[u32;3]>::new();
        let ring = |radius:f64,z:f64,points:&mut Vec<[f64;3]>| -> u32 {
            let base = points.len() as u32;
            for i in 0..angles {
                let a = 2.0*std::f64::consts::PI*(i as f64)/(angles as f64);
                points.push([radius*a.cos(),radius*a.sin(),z]);
            }
            base
        };
        let connect = |a:u32,b:u32,faces:&mut Vec<[u32;3]>| {
            for i in 0..angles as u32 { let j = (i+1)%(angles as u32);faces.push([a+i,a+j,b+i]);faces.push([a+j,b+j,b+i]); }
        };
        let cap = |base:u32,z:f64,front:bool,points:&mut Vec<[f64;3]>,faces:&mut Vec<[u32;3]>| {
            let centre = points.len() as u32;points.push([0.0,0.0,z]);
            for i in 0..angles as u32 {
                let j = (i+1)%(angles as u32);
                faces.push(if front { [base+i,base+j,centre] } else { [base+j,base+i,centre] });
            }
        };
        let mut previous:Option<(usize,u32)> = None;
        for &(start,end,radius) in &runs {
            let low = (self.origin[2]+(start as f64)*self.h).min(self.physical_max[2]);
            let high = (self.origin[2]+(end as f64)*self.h).min(self.physical_max[2]);
            let lower = ring(radius,low,&mut vertices);
            if let Some((old_end,old_ring)) = previous {
                if old_end == start { connect(old_ring,lower,&mut triangles); }
                else { cap(old_ring,(self.origin[2]+(old_end as f64)*self.h).min(self.physical_max[2]),true,&mut vertices,&mut triangles);cap(lower,low,false,&mut vertices,&mut triangles); }
            } else { cap(lower,low,false,&mut vertices,&mut triangles); }
            let upper = ring(radius,high,&mut vertices);connect(lower,upper,&mut triangles);previous = Some((end,upper));
        }
        if let Some((end,last)) = previous { cap(last,(self.origin[2]+(end as f64)*self.h).min(self.physical_max[2]),true,&mut vertices,&mut triangles); }
        if triangles.len() as u64 > max_triangles { return None; }
        Some((vertices,triangles))
    }

    /// Trilinear occupancy-density samples for the general surface extractor.
    /// Retain fractional incident-cell occupancy instead of quantizing every
    /// surface node to +/-1, which creates an extra half-cell staircase even
    /// on the unaffected cylindrical side of a slotted part. This changes
    /// surface representation only: occupancy/removal/collision cells remain.
    /// Exact half occupancy keeps the historical inside tie with a small,
    /// explicit nonzero value required by the pinned tetrahedra extractor.
    pub fn nodal_field(&self) -> Vec<f64> {
        let mut values = vec![1.0f64; (self.nx + 1) * (self.ny + 1) * (self.nz + 1)];
        for iz in 0..=self.nz {
            for iy in 0..=self.ny {
                for ix in 0..=self.nx {
                    let mut occ = 0u32;
                    let mut total = 0u32;
                    for dz in 0..2usize {
                        for dy in 0..2usize {
                            for dx in 0..2usize {
                                let (cx, cy, cz) = (
                                    ix + dx,
                                    iy + dy,
                                    iz + dz,
                                );
                                if cx == 0 || cy == 0 || cz == 0 {
                                    continue;
                                }
                                let (cx, cy, cz) = (cx - 1, cy - 1, cz - 1);
                                if cx >= self.nx || cy >= self.ny || cz >= self.nz {
                                    continue;
                                }
                                total += 1;
                                if self.occupied[self.idx(cx, cy, cz)] {
                                    occ += 1;
                                }
                            }
                        }
                    }
                    let density = if total > 0 { 1.0 - 2.0 * (occ as f64)/(total as f64) } else { 1.0 };
                    values[(iz * (self.ny + 1) + iy) * (self.nx + 1) + ix] =
                        if density.abs() <= 1e-6 { -1e-4 } else { density };
                }
            }
        }
        values
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f64::consts::PI;

    fn cyl() -> Stock {
        Stock::cylinder(6.0, 0.0, 20.0, 1.0, 1 << 20).unwrap()
    }

    #[test]
    fn axisym_blank_is_a_round_cylinder_not_a_voxel_polygon() {
        let s = Stock::cylinder(12.0,0.0,40.0,1.0,1<<20).unwrap();
        let before = s.occupied_count();let (points,faces) = s.axisymmetric_mesh(80_000).unwrap();
        assert_eq!(s.occupied_count(),before);assert!(faces.len()<=80_000);
        let ring:Vec<_> = points.iter().filter(|p| p[0]*p[0]+p[1]*p[1]>1e-12).collect();
        assert!(ring.len()>=256);
        for p in ring { assert!(((p[0]*p[0]+p[1]*p[1]).sqrt()-12.0).abs()<1e-10); }
        assert!(s.axisymmetric_mesh(8).is_none());
    }
    #[test]
    fn axisym_turned_shoulders_are_closed_and_preserve_layer_area() {
        let mut s = cyl();s.apply_turning_path(&[[4.0,5.0],[4.0,15.0]],false).unwrap();
        let (points,faces) = s.axisymmetric_mesh(80_000).unwrap();
        let mut edges = std::collections::HashMap::<(u32,u32),usize>::new();
        for t in &faces { for i in 0..3 { let a=t[i];let b=t[(i+1)%3];*edges.entry((a.min(b),a.max(b))).or_default()+=1; } }
        assert!(edges.values().all(|&n| n==2));
        let volume:f64 = faces.iter().map(|t| {
            let a=points[t[0] as usize];let b=points[t[1] as usize];let c=points[t[2] as usize];
            (a[0]*(b[1]*c[2]-b[2]*c[1])+a[1]*(b[2]*c[0]-b[0]*c[2])+a[2]*(b[0]*c[1]-b[1]*c[0]))/6.0
        }).sum();
        let occupied = s.occupied_count() as f64*s.cell_volume();
        assert!(volume>0.0 && (volume-occupied).abs()/occupied<0.001);
    }
    #[test]
    fn axisym_never_fills_a_slot_or_a_bore() {
        let mut slot = cyl();let iz=10;
        let (ix,iy)=(slot.nx/2,slot.ny/2);
        *slot.cell_mut(ix,iy,iz)=false;
        assert!(slot.axisymmetric_mesh(80_000).is_none());
        let mut notch = cyl();let x = notch.nx-2;let y = notch.ny/2;
        assert!(notch.occupied[notch.idx(x,y,iz)]);
        *notch.cell_mut(x,y,iz)=false;
        assert!(notch.axisymmetric_mesh(80_000).is_none());
        let boxed = Stock::box_stock([-3.0,-3.0,0.0],[3.0,3.0,6.0],1.0,1<<20).unwrap();
        assert!(boxed.axisymmetric_mesh(80_000).is_none());
    }

    #[test]
    fn initial_volume_matches_cylinder() {
        let s = cyl();
        let exact = PI * 36.0 * 20.0;
        let vox = s.occupied_count() as f64 * s.cell_volume();
        assert!((vox - exact).abs() / exact < 0.02);
    }

    #[test]
    fn longitudinal_cut_reduces_envelope() {
        let mut s = cyl();
        let before = s.occupied_count();
        // Cut radius 4 along z 5..15.
        s.apply_turning_path(&[[4.0, 5.0], [4.0, 15.0]], false).unwrap();
        let after = s.occupied_count();
        assert!(after < before);
        // Slab z=10 must now have max radius just below 4.
        let iz10 = 10usize;
        assert!(s.max_radius_in_slab(iz10) <= 4.0);
        // Uncut slab z=18 still has radius ~6.
        assert!(s.max_radius_in_slab(18) > 5.0);
    }

    #[test]
    fn face_cut_removes_front_cap_only() {
        let mut s = cyl();
        s.apply_turning_path(&[[0.0, 18.0], [6.0, 18.0]], false).unwrap();
        assert!(s.max_radius_in_slab(19) == 0.0); // cap removed
        assert!(s.max_radius_in_slab(17) > 5.0); // body untouched
    }

    #[test]
    fn negative_z_face_cut_removes_lower_cap_without_touching_upper_part() {
        // R5 dual-spindle backside facing: stock z0..40; a lower face cut at
        // z=2 (radius 0..6) with negativeZ removes only z <= 2. The stock
        // grid stays in original coordinates (no mirroring).
        let mut s = Stock::cylinder(6.0, 0.0, 40.0, 1.0, 1 << 20).unwrap();
        s.apply_turning_path(&[[0.0, 2.0], [6.0, 2.0]], true).unwrap();
        assert_eq!(s.max_radius_in_slab(0), 0.0, "lower cap z~0.5 removed");
        assert_eq!(s.max_radius_in_slab(1), 0.0, "lower cap z~1.5 removed");
        assert!(s.max_radius_in_slab(2) > 5.0, "z~2.5 body kept");
        assert!(s.max_radius_in_slab(38) > 5.0, "upper part untouched");
        // Same path with the default positiveZ approach still removes the
        // UPPER side (z >= 2 over the whole radius -> everything above 2).
        let mut p = Stock::cylinder(6.0, 0.0, 40.0, 1.0, 1 << 20).unwrap();
        p.apply_turning_path(&[[0.0, 2.0], [6.0, 2.0]], false).unwrap();
        assert!(p.max_radius_in_slab(1) > 5.0, "z~1.5 is below the positive-Z face");
        assert_eq!(p.max_radius_in_slab(2), 0.0, "z~2.5 upper cap removed");
        assert_eq!(p.max_radius_in_slab(38), 0.0);
        assert!(p.max_radius_in_slab(0) > 5.0);
        // Longitudinal envelope cuts are identical for both approaches.
        let mut n = Stock::cylinder(6.0, 0.0, 40.0, 1.0, 1 << 20).unwrap();
        n.apply_turning_path(&[[3.0, 10.0], [3.0, 30.0]], true).unwrap();
        let mut z = Stock::cylinder(6.0, 0.0, 40.0, 1.0, 1 << 20).unwrap();
        z.apply_turning_path(&[[3.0, 10.0], [3.0, 30.0]], false).unwrap();
        assert_eq!(n.occupied_count(), z.occupied_count());
        assert_eq!(n.max_radius_in_slab(20), z.max_radius_in_slab(20));
    }

    #[test]
    fn example_face_path_at_stock_end_removes_nothing() {
        let mut s = cyl();
        let before = s.occupied_count();
        s.apply_turning_path(&[[6.0, 20.0], [0.0, 20.0]], false).unwrap();
        assert_eq!(s.occupied_count(), before);
    }

    #[test]
    fn cutter_gouges_wherever_it_is_placed() {
        let mut s = cyl();
        // Deep "inside the part" — must still remove (no target protection).
        let before = s.occupied_count();
        s.remove_oriented_cutter(
            &Point3::new(0.0, 0.0, 10.0),
            &Vector3::z(),
            2.0,
            8.0,
        );
        assert!(s.occupied_count() < before);
    }

    #[test]
    fn box_stock_volume_and_shape() {
        let s = Stock::box_stock([-4.0, -3.0, 0.0], [4.0, 3.0, 10.0], 0.5, 1 << 20).unwrap();
        assert!(!s.is_cylinder());
        assert_eq!(s.occupied_count(), s.cell_count());
        let vox = s.occupied_count() as f64 * s.cell_volume();
        let exact = 8.0 * 6.0 * 10.0;
        assert!(
            (vox - exact).abs() / exact < 0.02,
            "voxel {vox} vs analytic {exact}"
        );
        assert!((s.analytic_volume() - exact).abs() < 1e-9);
        // Rejects bad extents and resolution.
        assert!(Stock::box_stock([0.0; 3], [0.0; 3], 0.5, 1 << 20).is_err());
        assert!(Stock::box_stock([0.0, 0.0, 0.0], [1.0, 1.0, 1.0], 0.01, 1 << 20).is_err());
    }

    #[test]
    fn profile_removal_matches_ball_geometry() {
        let mut s = cyl();
        let r = 2.0f64;
        // Ball nose: radius 0 at the tip, full radius at h >= r.
        let radius_at = |h: f64| {
            if h >= r {
                r
            } else {
                (r * r - (r - h) * (r - h)).max(0.0).sqrt()
            }
        };
        let before = s.occupied_count();
        s.remove_oriented_profile(
            &Point3::new(0.0, 0.0, 10.0),
            &Vector3::z(),
            r,
            6.0,
            &radius_at,
        );
        let after = s.occupied_count();
        assert!(after < before);
        // The deepest cut is exactly r below the tip plane: slab z=11 must
        // show material removed near the axis, slab z=8 (tip - 2 = above
        // contact for a ball: contact band is z in [8, 12]).
        let hit = s.occupied_centers_in_aabb([-0.4, -0.4, 10.5], [0.4, 0.4, 11.5]);
        assert!(hit.is_empty(), "ball should have cleared the axis region");
    }

    #[test]
    fn profile_intersects_material_detects_rapid_hits_only() {
        let mut s = cyl();
        let radius_at = |_h: f64| 2.0f64;
        let tip = Point3::new(0.0, 0.0, 10.0);
        assert!(s.profile_intersects_material(&tip, &Vector3::z(), 2.0, 6.0, &radius_at));
        let far = Point3::new(0.0, 0.0, 500.0);
        assert!(!s.profile_intersects_material(&far, &Vector3::z(), 2.0, 6.0, &radius_at));
        // After removal at the tip pose the same query must go quiet.
        s.remove_oriented_profile(&tip, &Vector3::z(), 2.0, 6.0, &radius_at);
        assert!(!s.profile_intersects_material(&tip, &Vector3::z(), 2.0, 6.0, &radius_at));
    }

    #[test]
    fn occupied_centers_in_aabb_is_exact_and_bounded() {
        let s = cyl();
        // Interior box: every returned centre's closed cuboid overlaps the box.
        let min = [-2.0, -2.0, 9.0];
        let max = [2.0, 2.0, 11.0];
        let centres = s.occupied_centers_in_aabb(min, max);
        assert!(!centres.is_empty());
        for c in &centres {
            let half = s.h * 0.5;
            for k in 0..3 {
                assert!(c[k] - half <= max[k] && c[k] + half >= min[k], "centre {c:?}");
            }
            let r = (c[0] * c[0] + c[1] * c[1]).sqrt();
            assert!(r < 6.0, "occupied centre must be inside the r=6 stock");
        }
        // Empty result far outside the stock and for degenerate boxes.
        assert!(s
            .occupied_centers_in_aabb([100.0; 3], [101.0; 3])
            .is_empty());
        assert!(s.occupied_centers_in_aabb([2.0, 2.0, 9.0], [1.0, 1.0, 10.0]).is_empty());
        assert!(s.occupied_centers_in_aabb([f64::NAN; 3], [1.0; 3]).is_empty());
        // Boundary box: cells touching the closed boundary are included.
        let edge = s.occupied_centers_in_aabb([5.9, -0.1, 19.5], [6.5, 0.1, 20.5]);
        assert!(edge.iter().any(|c| c[0] > 5.0));
    }

    // ---- R5 continuation -----------------------------------------------------

    fn cyl_state(radius: f64, z0: f64, z1: f64, h: f64) -> Stock {
        Stock::cylinder(radius, z0, z1, h, 1 << 20).unwrap()
    }

    #[test]
    fn continuation_roundtrip_preserves_occupancy() {
        let mut s = cyl_state(6.0, 0.0, 20.0, 1.0);
        let initial = s.occupied_count();
        s.apply_turning_path(&[[4.0, 5.0], [4.0, 15.0]], false).unwrap();
        let state = s.export_state();
        assert_eq!(state.format_version, 1);
        assert_eq!(state.dimensions, [s.nx, s.ny, s.nz]);
        assert_eq!(state.origin_mm, s.origin);
        assert_eq!(state.resolution_mm, s.h);
        assert_eq!(state.shape, "cylinder");
        assert_eq!(state.radius_mm, Some(6.0));
        // Sorted + unique by construction.
        assert!(state.occupied_indices.windows(2).all(|w| w[0] < w[1]));
        // Cumulative identity: occupied + removed == original initial.
        assert_eq!(
            state.occupied_indices.len() as u64 + state.removed_count,
            initial
        );

        // A fresh stock continued from the exported state is identical.
        let mut s2 = cyl_state(6.0, 0.0, 20.0, 1.0);
        s2.apply_continuation(&state).unwrap();
        assert_eq!(s2.occupied_count(), s.occupied_count());
        assert_eq!(s2.removed_count(), s.removed_count());
        let state2 = s2.export_state();
        assert_eq!(state2.occupied_indices, state.occupied_indices);
        assert_eq!(state2.removed_count, state.removed_count);
    }

    #[test]
    fn continuation_rejects_forged_state_outside_envelope() {
        let mut s = cyl_state(6.0, 0.0, 20.0, 1.0);
        let mut state = s.export_state();
        // Forge: claim a cell outside the cylinder envelope (a grid corner).
        let corner = {
            let mut idx = None;
            for iz in 0..s.nz {
                for iy in 0..s.ny {
                    for ix in 0..s.nx {
                        let i = s.idx(ix, iy, iz);
                        let c = s.center(ix, iy, iz);
                        if c[0] * c[0] + c[1] * c[1] > 36.0 && s.occupied[i] {
                            unreachable!("occupied centre must be inside r=6");
                        }
                        if c[0] * c[0] + c[1] * c[1] > 36.0 && idx.is_none() {
                            idx = Some(i);
                        }
                    }
                }
            }
            idx.expect("cylinder grid has envelope corners")
        };
        // Drop a real cell and add the outside-envelope cell forger-style.
        state.occupied_indices.remove(0);
        state.occupied_indices.push(corner);
        state.occupied_indices.sort_unstable();
        match s.apply_continuation(&state) {
            Err(m) => assert!(m.contains("outside the original initial occupancy")),
            Ok(_) => panic!("forged state must be refused"),
        }
    }

    #[test]
    fn continuation_rejects_unsorted_duplicate_out_of_range_and_mismatch() {
        let mut s = cyl_state(6.0, 0.0, 20.0, 1.0);
        let good = s.export_state();

        // Unsorted.
        let mut bad = good.clone();
        if bad.occupied_indices.len() >= 2 {
            bad.occupied_indices.swap(0, 1);
            // ensure actually unsorted
            bad.occupied_indices[1] = bad.occupied_indices[0];
            assert!(s.apply_continuation(&bad).is_err());
        }

        // Duplicate (sorted but not unique).
        let mut dup = good.clone();
        if let Some(&first) = dup.occupied_indices.first() {
            dup.occupied_indices.insert(0, first);
            assert!(s.apply_continuation(&dup).is_err());
        }

        // Out of range.
        let mut oob = good.clone();
        oob.occupied_indices.push(s.cell_count() as usize);
        assert!(s.apply_continuation(&oob).is_err());

        // Occupancy + removedCount mismatch (a removed cell silently restored
        // while keeping the sum wrong).
        let mut sum = good.clone();
        sum.removed_count += 1;
        assert!(s.apply_continuation(&sum).is_err());

        // Grid identity mismatches.
        let mut dims = good.clone();
        dims.dimensions[0] += 1;
        assert!(s.apply_continuation(&dims).is_err());
        let mut origin = good.clone();
        origin.origin_mm[0] += 1.0;
        assert!(s.apply_continuation(&origin).is_err());
        let mut res = good.clone();
        res.resolution_mm += 0.5;
        assert!(s.apply_continuation(&res).is_err());
        let mut shape = good.clone();
        shape.shape = "box".into();
        assert!(s.apply_continuation(&shape).is_err());
        let mut radius = good.clone();
        radius.radius_mm = Some(5.0);
        assert!(s.apply_continuation(&radius).is_err());
        let mut version = good.clone();
        version.format_version = 2;
        assert!(s.apply_continuation(&version).is_err());
    }

    #[test]
    fn continuation_empty_stock_is_valid_and_never_resets() {
        let mut s = cyl_state(6.0, 0.0, 20.0, 1.0);
        let initial = s.occupied_count();
        // An external envelope cut down to radius zero removes everything.
        s.apply_turning_path(&[[0.0, 0.0], [0.0, 20.0]], false).unwrap();
        assert_eq!(s.occupied_count(), 0);
        let empty = s.export_state();
        assert!(empty.occupied_indices.is_empty());
        assert_eq!(empty.removed_count, initial);

        // Continuing from the empty state yields an empty stock (success, no
        // reset to the fresh envelope).
        let mut s2 = cyl_state(6.0, 0.0, 20.0, 1.0);
        s2.apply_continuation(&empty).unwrap();
        assert_eq!(s2.occupied_count(), 0);
        assert_eq!(s2.removed_count(), initial);
        assert_eq!(s2.export_state().occupied_indices.len(), 0);
    }

    #[test]
    fn sequential_jobs_never_restore_removed_cells() {
        // Job 1: rough; job 2 continues and finishes. The final state must
        // equal one continuous job and removedCount must be cumulative.
        let initial = cyl_state(6.0, 0.0, 20.0, 1.0).occupied_count();
        let mut job1 = cyl_state(6.0, 0.0, 20.0, 1.0);
        job1.apply_turning_path(&[[4.0, 5.0], [4.0, 15.0]], false).unwrap();
        let state1 = job1.export_state();

        let mut job2 = cyl_state(6.0, 0.0, 20.0, 1.0);
        job2.apply_continuation(&state1).unwrap();
        let removed_after_job1 = job2.removed_count();
        assert!(removed_after_job1 > 0);
        job2.apply_turning_path(&[[2.0, 6.0], [2.0, 14.0]], false).unwrap();
        let state2 = job2.export_state();

        // removedCount only grows; occupancy only shrinks.
        assert!(state2.removed_count > state1.removed_count);
        assert!(state2.occupied_indices.len() < state1.occupied_indices.len());
        let occ1: std::collections::HashSet<usize> = state1.occupied_indices.iter().copied().collect();
        let occ2: std::collections::HashSet<usize> = state2.occupied_indices.iter().copied().collect();
        assert!(occ2.is_subset(&occ1), "no removed cell may be restored");
        // Cumulative identity against the ORIGINAL initial occupancy.
        assert_eq!(
            state2.occupied_indices.len() as u64 + state2.removed_count,
            initial
        );

        // Continuous equivalent produces identical final occupancy.
        let mut continuous = cyl_state(6.0, 0.0, 20.0, 1.0);
        continuous.apply_turning_path(&[[4.0, 5.0], [4.0, 15.0]], false).unwrap();
        continuous.apply_turning_path(&[[2.0, 6.0], [2.0, 14.0]], false).unwrap();
        let continuous_state = continuous.export_state();
        assert_eq!(continuous_state.occupied_indices, state2.occupied_indices);
        assert_eq!(continuous_state.removed_count, state2.removed_count);
    }

    #[test]
    fn box_stock_continuation_roundtrip_without_radius() {
        let mut s = Stock::box_stock([-4.0, -3.0, 0.0], [4.0, 3.0, 10.0], 0.5, 1 << 20).unwrap();
        s.remove_oriented_cutter(
            &Point3::new(0.0, 0.0, 5.0),
            &Vector3::z(),
            1.5,
            4.0,
        );
        let state = s.export_state();
        assert_eq!(state.shape, "box");
        assert_eq!(state.radius_mm, None);
        let mut s2 = Stock::box_stock([-4.0, -3.0, 0.0], [4.0, 3.0, 10.0], 0.5, 1 << 20).unwrap();
        s2.apply_continuation(&state).unwrap();
        assert_eq!(s2.export_state().occupied_indices, state.occupied_indices);
        // A box state claiming a positive radius is refused.
        let mut forged = state.clone();
        forged.radius_mm = Some(3.0);
        assert!(s2.apply_continuation(&forged).is_err());
    }

    #[test]
    fn continuation_retains_declared_planes_even_when_grid_dimensions_match() {
        let source=Stock::box_stock([0.0;3],[2.2;3],1.0,1<<20).unwrap();
        let state=source.export_state();
        assert_eq!(state.declared_max_mm,Some([2.2;3]));
        let json=serde_json::to_string(&state).unwrap();
        let decoded:crate::model::StockState=serde_json::from_str(&json).unwrap();
        let mut same=Stock::box_stock([0.0;3],[2.2;3],1.0,1<<20).unwrap();
        same.apply_continuation(&decoded).unwrap();
        let mut changed=Stock::box_stock([0.0;3],[2.4,2.2,2.2],1.0,1<<20).unwrap();
        assert_eq!([source.nx,source.ny,source.nz],[changed.nx,changed.ny,changed.nz]);
        assert!(changed.apply_continuation(&state).is_err());
        let mut legacy=state.clone();legacy.declared_max_mm=None;
        assert!(same.apply_continuation(&legacy).is_err());
        let mut aligned=Stock::box_stock([0.0;3],[3.0;3],1.0,1<<20).unwrap();
        aligned.apply_continuation(&legacy).unwrap();
        assert_eq!(aligned.export_state().declared_max_mm,Some([3.0;3]));
    }
}
