// SPDX-License-Identifier: MIT OR Apache-2.0
// Original Floe stock-domain reconstruction. No change to the pinned tetra table.
use std::collections::{BTreeSet, HashMap};
use crate::stock::{Stock, StockShape};

type Mesh = (Vec<[f64; 3]>, Vec<[u32; 3]>);
type Edge = (u32, u32);
fn edge(a: u32, b: u32) -> Edge { (a.min(b), a.max(b)) }
fn sub(a: [f64;3], b: [f64;3]) -> [f64;3] { [a[0]-b[0], a[1]-b[1], a[2]-b[2]] }
fn dot(a: [f64;3], b: [f64;3]) -> f64 { a[0]*b[0]+a[1]*b[1]+a[2]*b[2] }
fn area_squared(a: [f64;3], b: [f64;3], c: [f64;3]) -> f64 {
    let u=sub(b,a);let v=sub(c,a);
    let n=[u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0]];
    dot(n,n)
}
fn incidence(faces: &[[u32;3]]) -> HashMap<Edge, (u32, i32)> {
    let mut counts=HashMap::new();
    for t in faces { for i in 0..3 {
        let a=t[i];let b=t[(i+1)%3];let item=counts.entry(edge(a,b)).or_insert((0,0));
        item.0+=1;item.1+=if a<b { 1 } else { -1 };
    } }
    counts
}

/// A pristine rectangular blank is known geometry, not an isosurface estimate.
pub fn blank_box(stock: &Stock, max_triangles: u64) -> Result<Option<Mesh>, String> {
    if stock.shape != StockShape::Box || stock.occupied_count() != stock.cell_count() { return Ok(None); }
    if max_triangles < 12 { return Err("budget: exact stock box requires 12 triangles".into()); }
    let a=stock.origin;let b=stock.physical_max;
    let points=vec![[a[0],a[1],a[2]],[b[0],a[1],a[2]],[b[0],b[1],a[2]],[a[0],b[1],a[2]],
                    [a[0],a[1],b[2]],[b[0],a[1],b[2]],[b[0],b[1],b[2]],[a[0],b[1],b[2]]];
    let faces=vec![[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],
                   [1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]];
    Ok(Some((points,faces)))
}

/// Never allow a reconstructed surface outside the original convex stock domain.
/// No fairing is applied; welding is limited to numerically coincident vertices.
/// This does not improve voxel cut accuracy.
pub fn constrain(stock: &Stock, input: Mesh, max_triangles: u64) -> Result<Mesh, String> {
    let (raw, triangles)=input;
    if triangles.is_empty() { return Ok((vec![],vec![])); }
    let epsilon=stock.h*1e-9;
    let mut points=Vec::<[f64;3]>::new();
    let mut welded=HashMap::<[i64;3],u32>::new();
    let mut remap=Vec::with_capacity(raw.len());
    for mut p in raw {
        p[2]=p[2].clamp(stock.origin[2],stock.physical_max[2]);
        match stock.shape {
            StockShape::Box => { for i in 0..2 { p[i]=p[i].clamp(stock.origin[i],stock.physical_max[i]); } }
            StockShape::Cylinder { radius } => {
                let r=p[0].hypot(p[1]);
                if r>radius { p[0]*=radius/r;p[1]*=radius/r; }
            }
        }
        let key=[((p[0]-stock.origin[0])/epsilon).round() as i64,
                 ((p[1]-stock.origin[1])/epsilon).round() as i64,
                 ((p[2]-stock.origin[2])/epsilon).round() as i64];
        let id=*welded.entry(key).or_insert_with(|| { let id=points.len() as u32;points.push(p);id });
        remap.push(id);
    }
    let minimum_area_squared=stock.h.powi(4)*1e-24;
    let mut faces=Vec::with_capacity(triangles.len());
    for t in triangles {
        let t=[remap[t[0] as usize],remap[t[1] as usize],remap[t[2] as usize]];
        if t[0]!=t[1] && t[1]!=t[2] && t[2]!=t[0] &&
           area_squared(points[t[0] as usize],points[t[1] as usize],points[t[2] as usize])>minimum_area_squared { faces.push(t); }
    }
    if faces.is_empty() {
        return Err("mesh: declared stock boundary collapsed all reconstructed triangles".into());
    }
    // Projection can collapse an outside halo triangle onto a straight stock edge.
    // Remove its zero area, then split neighbouring edges at the existing collinear
    // vertices. This repairs T junctions without capping holes or moving a cut face.
    let mut checks=0usize;
    for _ in 0..4 {
        let counts=incidence(&faces);
        if counts.values().all(|&(count,orientation)| count==2 && orientation==0) { break; }
        if counts.values().any(|&(count,orientation)| count>2 || (count==2 && orientation!=0)) {
            return Err("mesh: stock-boundary reconstruction is non-manifold or inconsistently oriented".into());
        }
        let mut border:Vec<Edge>=counts.iter().filter(|(_,v)| v.0==1).map(|(&k,_)| k).collect();border.sort_unstable();
        let border_ids:BTreeSet<u32>=border.iter().flat_map(|&(a,b)| [a,b]).collect();
        let bucket=|p: [f64;3]| -> [i64;3] {
            [((p[0]-stock.origin[0])/stock.h).floor() as i64,
             ((p[1]-stock.origin[1])/stock.h).floor() as i64,
             ((p[2]-stock.origin[2])/stock.h).floor() as i64]
        };
        let mut buckets=HashMap::<[i64;3],Vec<u32>>::new();
        for id in border_ids { buckets.entry(bucket(points[id as usize])).or_default().push(id); }
        let mut splits=HashMap::<Edge,Vec<u32>>::new();
        for &(a,b) in &border {
            let p=points[a as usize];let q=points[b as usize];let d=sub(q,p);let length_squared=dot(d,d);
            if length_squared<=epsilon*epsilon { continue; }
            let low=bucket([p[0].min(q[0])-epsilon*4.0,p[1].min(q[1])-epsilon*4.0,p[2].min(q[2])-epsilon*4.0]);
            let high=bucket([p[0].max(q[0])+epsilon*4.0,p[1].max(q[1])+epsilon*4.0,p[2].max(q[2])+epsilon*4.0]);
            if (0..3).any(|i| high[i]-low[i]>4) { return Err("budget: stock boundary edge spans too many grid cells".into()); }
            let mut candidates=Vec::<(f64,u32)>::new();
            for x in low[0]..=high[0] { for y in low[1]..=high[1] { for z in low[2]..=high[2] {
                if let Some(ids)=buckets.get(&[x,y,z]) { for &id in ids {
                    checks+=1;
                    if checks>8_000_000 { return Err("budget: stock boundary repair candidate budget exceeded".into()); }
                    if id==a || id==b { continue; }
                    let delta=sub(points[id as usize],p);let t=dot(delta,d)/length_squared;
                    if !(1e-9..(1.0-1e-9)).contains(&t) { continue; }
                    let residual=[delta[0]-t*d[0],delta[1]-t*d[1],delta[2]-t*d[2]];
                    if dot(residual,residual)<=epsilon*epsilon*16.0 { candidates.push((t,id)); }
                } }
            } } }
            candidates.sort_by(|a,b| a.0.total_cmp(&b.0).then(a.1.cmp(&b.1)));
            candidates.dedup_by_key(|x| x.1);
            if !candidates.is_empty() { splits.insert((a,b),candidates.into_iter().map(|x| x.1).collect()); }
        }
        if splits.is_empty() { return Err("mesh: stock boundary has an unresolved open edge; no unclosed mesh returned".into()); }
        let mut repaired=Vec::with_capacity(faces.len());
        for t in faces {
            let mut polygon=Vec::new();let mut changed=false;
            for i in 0..3 {
                let a=t[i];let b=t[(i+1)%3];polygon.push(a);
                if let Some(ids)=splits.get(&edge(a,b)) {
                    changed=true;
                    if a<b { polygon.extend(ids.iter().copied()); } else { polygon.extend(ids.iter().rev().copied()); }
                }
            }
            if !changed { repaired.push(t); }
            else {
                let a=points[t[0] as usize];let b=points[t[1] as usize];let c=points[t[2] as usize];
                let center=[a[0]+((b[0]-a[0])+(c[0]-a[0]))/3.0,
                            a[1]+((b[1]-a[1])+(c[1]-a[1]))/3.0,
                            a[2]+((b[2]-a[2])+(c[2]-a[2]))/3.0];
                let id=points.len() as u32;points.push(center);
                for i in 0..polygon.len() { repaired.push([id,polygon[i],polygon[(i+1)%polygon.len()]]); }
            }
            if repaired.len() as u64>max_triangles || points.len() as u64>max_triangles.saturating_mul(3) {
                return Err("budget: constrained stock mesh exceeded output budget".into());
            }
        }
        faces=repaired;
    }
    if !incidence(&faces).values().all(|&(count,orientation)| count==2 && orientation==0) {
        return Err("mesh: stock-boundary closure repair did not converge".into());
    }
    // Remove unused collapsed halo vertices; returned extrema describe actual faces.
    let mut used=vec![false;points.len()];for t in &faces { for &id in t { used[id as usize]=true; } }
    let mut compact=Vec::new();let mut mapping=vec![0u32;points.len()];
    for (i,p) in points.into_iter().enumerate() { if used[i] { mapping[i]=compact.len() as u32;compact.push(p); } }
    for t in &mut faces { for id in t { *id=mapping[*id as usize]; } }
    Ok((compact,faces))
}
