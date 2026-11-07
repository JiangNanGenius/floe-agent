// SPDX-License-Identifier: MIT OR Apache-2.0
//! Source path replay, sharing the production Stock/profile/mesher kernels.
//! Material is evaluated at the same cursor as the displayed TCP. No final mesh
//! substitution, target-CAD interpolation or implicit linking moves are used.
use nalgebra::{Point3, Unit, Vector3};
use serde::{Deserialize, Serialize};
use crate::{Fail, Progress};
use crate::assembly::AssemblyChecker;
use crate::cam::tools::CamTool;
use crate::collision::{FixtureBox, QueryBudget};
use crate::model::{BudgetReq, CamToolReq, CollisionOut, FixtureReq, StockReq, StockState};
use crate::stock::Stock;

#[derive(Deserialize)]
#[serde(rename_all="camelCase")]
struct Path {
    kind: String,
    points: Vec<[f64;3]>,
    #[serde(rename="toolAxes",default)] tool_axes: Option<Vec<[f64;3]>>,
    #[serde(default)] tool: Option<CamToolReq>,
}
#[derive(Deserialize)]
#[serde(rename_all="camelCase")]
struct Request {
    format_version: u32,
    stock: StockReq,
    budget: BudgetReq,
    paths: Vec<Path>,
    path_index: usize,
    point_index: usize,
    fraction: f64,
    #[serde(default)] from_path_index: usize,
    #[serde(default)] initial_stock_state: Option<StockState>,
    #[serde(default)] turning_approach: Option<String>,
    #[serde(default)] fixtures: Vec<FixtureReq>,
    #[serde(rename="turningNoseRadiusMM",default)] turning_nose_radius_mm: Option<f64>,
}
#[derive(Serialize)]
#[serde(rename_all="camelCase")]
pub(crate) struct Reply {
    ok: bool,
    vertices: Vec<[f64;3]>,
    triangles: Vec<[u32;3]>,
    stock_state: StockState,
    checkpoint_state: StockState,
    checkpoint_collisions: Vec<CollisionOut>,
    collisions: Vec<CollisionOut>,
    warnings: Vec<String>,
    sampled_poses: u64,
}

pub(crate) fn run(json:&str, progress:&Progress)->Result<Reply,Fail> {
    if json.len()>128_000_000 { return Err("preview: request byte budget".into()); }
    let r:Request=serde_json::from_str(json).map_err(|e| Fail::Message(format!("preview request: {e}")))?;
    crate::core::validate_budget(&r.budget)?;
    if r.format_version!=1 || r.paths.is_empty() || r.paths.len()>12_000 ||
        r.path_index>=r.paths.len() || r.from_path_index>r.path_index ||
        (r.from_path_index>0 && r.initial_stock_state.is_none()) ||
        !r.fraction.is_finite() || !(0.0..=1.0).contains(&r.fraction) ||
        r.paths.iter().map(|p|p.points.len()).sum::<usize>()>1_000_000 {
        return Err("preview: invalid cursor/path budget".into());
    }
    let negative=match r.turning_approach.as_deref().unwrap_or("positiveZ") {
        "positiveZ"=>false,"negativeZ"=>true,_=>return Err("preview: turning approach".into())
    };
    let mut stock=match r.stock.shape.as_deref().unwrap_or("cylinder") {
        "cylinder"=>Stock::cylinder(r.stock.radius_mm,r.stock.z_min_mm,r.stock.z_max_mm,r.stock.resolution_mm,r.budget.max_cells)?,
        "box"=>{
            let lo=r.stock.min_mm.ok_or("preview: box minimum missing")?;
            let hi=r.stock.max_mm.ok_or("preview: box maximum missing")?;
            if lo[2]!=r.stock.z_min_mm || hi[2]!=r.stock.z_max_mm { return Err("preview: box end planes disagree".into()); }
            Stock::box_stock(lo,hi,r.stock.resolution_mm,r.budget.max_cells)?
        }, _=>return Err("preview: unknown stock shape".into())
    };
    if let Some(state)=&r.initial_stock_state { stock.apply_continuation(state)?; }
    let fixtures=r.fixtures.iter().map(|f| {
        let value=FixtureBox{id:f.id.clone(),min:f.min_mm,max:f.max_mm};value.cuboid()?;Ok(value)
    }).collect::<Result<Vec<_>,String>>()?;
    if fixtures.len()>128 { return Err("preview: fixture budget".into()); }
    let mut collisions=vec![];let mut poses=0u64;
    let mut queries=QueryBudget::new(r.budget.max_collision_queries);
    let mut checkpoint=stock.export_state();
    let mut checkpoint_collisions=vec![];
    let mut warnings=vec!["Sampled cutter, supplied holder/shank and fixture checks only; unspecified machine bodies and continuous collision sweeps remain uncovered.".to_string()];
    for (pi,path) in r.paths.iter().enumerate().take(r.path_index+1).skip(r.from_path_index) {
        progress.report((pi-r.from_path_index) as f64/(r.path_index-r.from_path_index+1) as f64,"preview-removal")?;
        if path.points.is_empty() || path.points.iter().any(|p|p.iter().any(|v|!v.is_finite() || v.abs()>100_000.0)) {
            return Err("preview: invalid path coordinates".into());
        }
        if let Some(axes)=&path.tool_axes {
            if axes.len()!=path.points.len() || axes.iter().any(|a|a.iter().any(|v|!v.is_finite()) || (a.iter().map(|v|v*v).sum::<f64>()-1.0).abs()>1e-5) {
                return Err("preview: invalid tool axes".into());
            }
        }
        let current=pi==r.path_index;
        if current { checkpoint=stock.export_state();checkpoint_collisions=collisions.clone(); }
        let point=if current { r.point_index } else { path.points.len()-1 };
        if point>=path.points.len() || (point==path.points.len()-1 && current && r.fraction>0.0) {
            return Err("preview: point cursor outside path".into());
        }
        if path.kind.starts_with("turning-") {
            if !stock.is_cylinder() { return Err("preview: turning needs cylindrical stock".into()); }
            let mut points=path.points[..=point].iter().map(|p|[p[0],p[2]]).collect::<Vec<_>>();
            if current && r.fraction>0.0 {
                let a=path.points[point];let b=path.points[point+1];
                points.push([a[0]+(b[0]-a[0])*r.fraction,a[2]+(b[2]-a[2])*r.fraction]);
            }
            for segment in points.windows(2) {
                stock.apply_turning_path(segment,negative)?;poses+=1;
                if poses>r.budget.max_poses { return Err("preview: pose budget".into()); }
                progress.report(0.5,"preview-turning")?;
            }
            if !fixtures.is_empty() && !points.is_empty() {
                let nose=r.turning_nose_radius_mm.unwrap_or(0.4);
                if !nose.is_finite() || nose<=0.0 || nose>1000.0 { return Err("preview: nose radius".into()); }
                let mut tips=vec![Point3::new(points[0][0],0.0,points[0][1])];
                for w in points.windows(2) {
                    let a=Point3::new(w[0][0],0.0,w[0][1]);let b=Point3::new(w[1][0],0.0,w[1][1]);
                    let count=((b-a).norm()/(stock.h*0.5).min(nose*0.5)).ceil().max(1.0) as u64;
                    if poses+count>r.budget.max_poses { return Err("preview: turning collision sample budget".into()); }
                    for k in 1..=count { tips.push(a+(b-a)*(k as f64/count as f64)); }
                    poses+=count;progress.report(0.6,"preview-turning-collision")?;
                }
                collisions.extend(crate::core::collision_out(crate::collision::check_turning_nose_against_fixtures(&fixtures,&tips,nose,progress)?));
            }
            if !warnings.iter().any(|w|w.starts_with("Turning")) { warnings.push("Turning holder/body geometry is not supplied; only the nose against fixtures is checked. Native radial-envelope removal retains its declared voxel/nose approximation.".into()); }
            continue;
        }
        if path.kind=="cam-dwell" { continue; }
        let tool=CamTool::validate_one(path.tool.as_ref().ok_or("preview: cutting tool definition missing")?)?;
        let removes=matches!(path.kind.as_str(),"cam-cut"|"cam-plunge"|"milling-slot"|"ac");
        if !removes && !matches!(path.kind.as_str(),"cam-rapid"|"cam-retract") { return Err("preview: unsupported move kind".into()); }
        let mut checker=match &tool.assembly { Some(a)=>Some(AssemblyChecker::new(a,&fixtures,&mut queries)?),None=>None };
        if checker.is_none() && !warnings.iter().any(|w|w.starts_with("No configured")) { warnings.push("No configured shank/holder model; those parts are not collision-checked.".into()); }
        let axis_at=|i:usize|->Unit<Vector3<f64>> {
            Unit::new_normalize(Vector3::from(path.tool_axes.as_ref().map(|a|a[i]).unwrap_or([0.0,0.0,1.0])))
        };
        let mut samples=Vec::new();let mut rapid_hit=false;
        let segment_count=point+usize::from(current && r.fraction>0.0);
        // Legacy slot/AC execution samples explicit poses; CAM uses adaptive
        // profile samples. Preserve those distinct source contracts.
        if path.kind=="milling-slot" || path.kind=="ac" {
            for i in 0..=point {
                let tip=Point3::from(path.points[i]);let axis=axis_at(i);
                samples.push((tip,axis,true));
            }
        } else {
            samples.push((Point3::from(path.points[0]),axis_at(0),false));
            for i in 0..segment_count {
                let fraction=if current && i==point { r.fraction } else {1.0};
                if fraction<=0.0 { continue; }
                let a=Point3::from(path.points[i]);let b=Point3::from(path.points[i+1]);let aa=axis_at(i);let bb=axis_at(i+1);
                let count=(((b-a).norm()/(stock.h*0.5).min(tool.radius()*0.5)).ceil() as u64)
                    .max((aa.dot(&bb).clamp(-1.0,1.0).acos().to_degrees()/15.0).ceil() as u64).max(1);
                if count>r.budget.max_poses { return Err("preview: segment pose budget".into()); }
                let full=(count as f64*fraction).floor() as u64;
                if samples.len() as u64+full+1>r.budget.max_poses { return Err("preview: sampled pose budget".into()); }
                for k in 1..=full {
                    let f=k as f64/count as f64;let tip=a+(b-a)*f;
                    let axis=crate::cam::exec::interpolate_axis(&aa,&bb,f)?;
                    samples.push((tip,axis,true));
                }
                // The last partial sample follows the exact TCP, never a future
                // endpoint. It is not persisted as a completed-path checkpoint.
                if fraction<1.0 && fraction>full as f64/count as f64 {
                    samples.push((a+(b-a)*fraction,crate::cam::exec::interpolate_axis(&aa,&bb,fraction)?,true));
                }
            }
        }
        for (index,(tip,axis,advance)) in samples.iter().enumerate() {
            poses+=1;if poses>r.budget.max_poses { return Err("preview: pose budget".into()); }
            if index%32==0 { progress.report(0.7,"preview-profile")?; }
            if removes && *advance { stock.remove_oriented_profile(tip,axis,tool.radius(),tool.profile.flute_length,&|h|tool.radius_at(h)); }
            if !removes && stock.profile_intersects_material(tip,axis,tool.radius(),tool.profile.flute_length,&|h|tool.radius_at(h)) { rapid_hit=true; }
            if let Some(ch)=checker.as_mut() { ch.check_step(index,samples.len(),tip,axis,&stock,progress,0.0,0.9)?; }
        }
        if let Some(ch)=checker { collisions.extend(ch.into_rows(&format!("preview-path-{pi}"),stock.h)); }
        if rapid_hit { collisions.push(CollisionOut{component:"remaining-stock".into(),state:"intersecting".into(),message:"Rapid/retract cutter intersects remaining stock; non-cutting moves do not remove material".into(),tool_part:Some("cutter".into()),target_kind:Some("stock".into()),operation:Some(format!("preview-path-{pi}")),first_pose_index:None,minimum_gap_lower_bound_mm:None,geometry_error_mm:Some(stock.h)}); }
        if !fixtures.is_empty() && !samples.is_empty() {
            let tips=samples.iter().map(|(p,_,_)|*p).collect::<Vec<_>>();let axes=samples.iter().map(|(_,a,_)|*a).collect::<Vec<_>>();
            let mut rows=crate::core::collision_out(crate::collision::check_cutter_against_fixtures(&fixtures,&tips,&axes,tool.radius(),tool.profile.flute_length,&format!("preview-path-{pi}"),&mut queries,progress,0.0,0.9)?);
            if tool.profile.kind!=crate::upstream_r4::tool_profile::UpToolKind::FlatEndMill {
                for row in &mut rows { if row.state=="intersecting" { row.state="uncertain".into();row.message="Cutting-profile outer envelope intersects fixture; exact ball/drill contact is uncertain".into(); } }
            }
            collisions.extend(rows);
        }
    }
    progress.report(0.95,"preview-mesh")?;
    let mut mesh_budget=r.budget.max_triangles;
    let (vertices,triangles)=crate::core::mesh_stock(&stock,r.budget.max_triangles,&mut mesh_budget)?;
    progress.report(1.0,"preview-ready")?;
    Ok(Reply{ok:true,vertices,triangles,stock_state:stock.export_state(),checkpoint_state:checkpoint,checkpoint_collisions,collisions,warnings,sampled_poses:poses})
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json,Value};
    fn request()->Value { json!({"formatVersion":1,"stock":{"shape":"box","radiusMM":4,"zMinMM":0,"zMaxMM":4,"resolutionMM":0.5,"minMM":[-4,-4,0],"maxMM":[4,4,4]},"budget":{},"paths":[{"kind":"cam-cut","points":[[-3,0,1],[3,0,1]],"tool":{"id":"mill","name":"mill","kind":"flatEndMill","diameterMM":2,"cuttingLengthMM":4}}],"pathIndex":0,"pointIndex":0,"fraction":0.0}) }
    #[test]
    fn material_follows_actual_prefix_and_rewind_is_deterministic() {
        let mut r=request();let a=run(&r.to_string(),&Progress::quiet()).unwrap();
        r["fraction"]=json!(0.5);let b=run(&r.to_string(),&Progress::quiet()).unwrap();
        r["pointIndex"]=json!(1);r["fraction"]=json!(0.0);let c=run(&r.to_string(),&Progress::quiet()).unwrap();
        assert!(a.stock_state.occupied_indices.len()>b.stock_state.occupied_indices.len());
        assert!(b.stock_state.occupied_indices.len()>c.stock_state.occupied_indices.len());
        let nx=b.stock_state.dimensions[0];let ny=b.stock_state.dimensions[1];
        let untouched=b.stock_state.occupied_indices.iter().filter(|&&i| i%nx>=12 && (i/nx)%ny>=7 && (i/nx)%ny<=8).count();
        assert!(untouched>0,"material beyond the current cutter must remain");
        r["pointIndex"]=json!(0);r["fraction"]=json!(0.5);
        assert_eq!(b.stock_state.occupied_indices,run(&r.to_string(),&Progress::quiet()).unwrap().stock_state.occupied_indices);
        assert_ne!(a.vertices,b.vertices);assert_ne!(b.vertices,c.vertices);
    }
    #[test]
    fn rapid_never_removes_stock_and_reports_real_stock_interference() {
        let mut r=request();r["paths"][0]["kind"]=json!("cam-rapid");r["fraction"]=json!(0.8);
        let value=run(&r.to_string(),&Progress::quiet()).unwrap();
        assert_eq!(value.stock_state.removed_count,0);
        assert!(value.collisions.iter().any(|c|c.component=="remaining-stock" && c.state=="intersecting"));
    }
    #[test]
    fn turning_prefix_changes_axial_stock_before_operation_finishes() {
        let mut r=request();r["stock"]=json!({"radiusMM":4,"zMinMM":0,"zMaxMM":4,"resolutionMM":0.5});
        r["paths"]=json!([{"kind":"turning-rough","points":[[2,0,0],[2,0,4]]}]);
        let initial=run(&r.to_string(),&Progress::quiet()).unwrap();
        r["fraction"]=json!(0.5);let half=run(&r.to_string(),&Progress::quiet()).unwrap();
        r["pointIndex"]=json!(1);r["fraction"]=json!(0.0);let end=run(&r.to_string(),&Progress::quiet()).unwrap();
        assert!(half.stock_state.removed_count>0);assert!(end.stock_state.removed_count>half.stock_state.removed_count);
        assert!(initial.stock_state.occupied_indices.len()>half.stock_state.occupied_indices.len());
    }
    #[test]
    fn checkpoint_continuation_matches_full_prefix_without_regrowth() {
        let mut r=request();let mut second=r["paths"][0].clone();second["points"]=json!([[-3,2,1],[3,2,1]]);
        r["paths"].as_array_mut().unwrap().push(second);r["pathIndex"]=json!(1);r["fraction"]=json!(0.7);
        let full=run(&r.to_string(),&Progress::quiet()).unwrap();
        r["initialStockState"]=serde_json::to_value(&full.checkpoint_state).unwrap();r["fromPathIndex"]=json!(1);
        let cached=run(&r.to_string(),&Progress::quiet()).unwrap();
        assert_eq!(full.stock_state.occupied_indices,cached.stock_state.occupied_indices);
        assert_eq!(full.vertices,cached.vertices);
    }
    #[test]
    fn intermediate_turning_fixture_and_configured_holder_are_checked() {
        let mut r=request();r["stock"]=json!({"radiusMM":4,"zMinMM":0,"zMaxMM":4,"resolutionMM":0.5});
        r["paths"]=json!([{"kind":"turning-rough","points":[[2,0,0],[2,0,4]]}]);
        r["fixtures"]=json!([{"id":"middle","minMM":[1.9,-0.1,1.9],"maxMM":[2.1,0.1,2.1]}]);
        r["pointIndex"]=json!(1);
        let v=run(&r.to_string(),&Progress::quiet()).unwrap();
        assert!(v.collisions.iter().any(|c|c.component=="middle" && c.state=="intersecting"),"clean endpoints must not hide a middle collision");
        let mut r=request();r["fraction"]=json!(1.0);
        r["paths"][0]["tool"]["assembly"]=json!({"formatVersion":1,"name":"holder","shankDiameterMM":2,"holderProfile":[[4,2],[8,2]],"clearanceMM":0.0});
        r["fixtures"]=json!([{"id":"holder-only","minMM":[-0.2,-0.2,7.0],"maxMM":[0.2,0.2,7.5]}]);
        let v=run(&r.to_string(),&Progress::quiet()).unwrap();
        assert!(v.collisions.iter().any(|c|c.component=="holder-only" && c.tool_part.as_deref()==Some("holder") && c.state=="intersecting"));
        assert!(!v.collisions.iter().any(|c|c.component=="remaining-stock" && c.tool_part.as_deref()==Some("cutter")),"normal cutting contact is intentional removal");
    }
    extern "C" fn cancelled(_: *mut std::ffi::c_void,_:f64,_:*const std::ffi::c_char)->i32 {1}
    #[test]
    fn cancellation_and_budgets_never_yield_a_finished_mesh() {
        let r=request();assert!(matches!(run(&r.to_string(),&Progress::new(Some(cancelled),std::ptr::null_mut())),Err(Fail::Cancelled)));
        let mut r=request();r["fraction"]=json!(1.0);r["budget"]["maxPoses"]=json!(1);
        assert!(run(&r.to_string(),&Progress::quiet()).is_err());
    }
}
