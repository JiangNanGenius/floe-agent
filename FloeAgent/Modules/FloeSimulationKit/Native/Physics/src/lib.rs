use rapier3d_f64::prelude::*;
use rapier3d_f64::parry::transformation::vhacd::VHACDParameters;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, ffi::{c_char,c_void}, panic::{catch_unwind,AssertUnwindSafe}};

#[derive(Clone,Copy,Deserialize,Serialize)]
struct V { x:f64,y:f64,z:f64 }
impl V { fn vector(self)->Vector { Vector::new(self.x,self.y,self.z) } }
fn xyz(v:Vector)->V { V{x:v.x,y:v.y,z:v.z} }
#[derive(Clone,Copy,Deserialize,Serialize)]
struct Q {x:f64,y:f64,z:f64,w:f64}
impl Q { fn rotation(self)->Rotation { Rotation::from_xyzw(self.x,self.y,self.z,self.w) } }
#[derive(Deserialize)]
#[serde(rename_all="camelCase")]
struct Shape {kind:String,half_extents:V,radius:f64,half_height:f64,vertices:Vec<V>,triangles:Vec<[u32;3]>}
#[derive(Deserialize)]
#[serde(rename_all="camelCase")]
struct Key {time_seconds:f64,translation:V,rotation:Q}
#[derive(Deserialize)]
#[serde(rename_all="camelCase")]
struct Body {id:String,#[serde(rename="sourceObjectID")] source_object_id:String,motion:String,translation:V,rotation:Q,velocity:V,angular_velocity:V,mass_kg:f64,center_of_mass_meters:V,principal_inertia_kg_square_meters:Option<V>,inertia_orientation:Q,friction:f64,restitution:f64,linear_damping:f64,angular_damping:f64,#[serde(default)] activation_time_seconds:f64,lifetime_seconds:Option<f64>,collider:Shape,kinematic_keys:Vec<Key>}
#[derive(Deserialize)]
#[serde(rename_all="camelCase")]
struct Joint {kind:String,first_body:String,second_body:String,first_anchor:V,second_anchor:V,axis:V,limits:Vec<f64>,motor_velocity:f64,motor_force:f64,rest_length_meters:f64,stiffness:f64,damping:f64}
#[derive(Deserialize)]
#[serde(rename_all="camelCase")]
struct Soft {id:String,#[serde(rename="sourceObjectID")] source_object_id:String,kind:String,origin:V,end:V,du:V,dv:V,half_extents:V,dimensions:[usize;3],pinned_indices:Vec<u32>,particle_mass_kg:f64,particle_radius_meters:f64,natural_frequency_hz:f64,damping_ratio:f64,linear_damping:f64,friction:f64,self_collision:bool,mesh_vertices:Option<Vec<V>>,mesh_triangles:Option<Vec<[u32;3]>>,shape_matching:Option<bool>,preserve_volume:Option<bool>}
#[derive(Deserialize)]
#[serde(rename_all="camelCase")]
struct Time {duration_seconds:f64,step_seconds:f64,output_interval_seconds:f64}
#[derive(Deserialize)]
#[serde(rename_all="camelCase")]
struct ForceField {kind:String,acceleration:V,center:V,axis:V,strength:f64,softening_radius_meters:f64,#[serde(rename="bodyIDs")] body_ids:Vec<String>,affects_soft_bodies:bool}
#[derive(Deserialize)]
#[serde(rename_all="camelCase")]
struct Scene {bodies:Vec<Body>,joints:Vec<Joint>,soft_bodies:Vec<Soft>,#[serde(default)] force_fields:Vec<ForceField>,gravity:V,time:Time,seed:u64}
#[derive(Serialize)]
#[serde(rename_all="camelCase")]
struct BodyPose {id:String,translation:V,rotation:Q,velocity:V,angular_velocity:V,visible:bool}
#[derive(Serialize)]
#[serde(rename_all="camelCase")]
struct SoftPose {id:String,vertices:Vec<V>,topology_version:u32}
#[derive(Serialize)]
struct SoftTopology {id:String,triangles:Vec<[u32;3]>}
#[derive(Serialize)]
#[serde(rename_all="camelCase")]
struct Frame {time_seconds:f64,bodies:Vec<BodyPose>,soft_bodies:Vec<SoftPose>,contacts:Vec<[usize;2]>}
#[derive(Serialize)]
#[serde(rename_all="camelCase")]
struct Output {version:String,seed:u64,soft_topology:Vec<SoftTopology>,frames:Vec<Frame>}

#[repr(C)]
pub struct FloePhysicsBuffer {data:*mut u8,length:usize,status:i32}
type Cancel=Option<extern "C" fn(*mut c_void)->i32>;
type Progress=Option<extern "C" fn(*mut c_void,u32,u32)>;

fn buffer(bytes:Vec<u8>,status:i32)->FloePhysicsBuffer {
    let mut boxed=bytes.into_boxed_slice(); let result=FloePhysicsBuffer{data:boxed.as_mut_ptr(),length:boxed.len(),status};
    std::mem::forget(boxed); result
}
fn error(message:&str,status:i32)->FloePhysicsBuffer { buffer(serde_json::to_vec(&serde_json::json!({"error":message})).unwrap_or_default(),status) }

#[no_mangle]
pub extern "C" fn floe_physics_version()->*const c_char { b"rapier3d-f64/0.36.1/floe-abi3\0".as_ptr().cast() }

/// The caller retains input bytes until return. Output must be freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn floe_physics_buffer_free(value:FloePhysicsBuffer) {
    if !value.data.is_null() { drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(value.data,value.length))); }
}

#[no_mangle]
pub unsafe extern "C" fn floe_physics_run(json:*const u8,length:usize,result_value_budget:usize,cancelled:Cancel,progress:Progress,context:*mut c_void)->FloePhysicsBuffer {
    if json.is_null() || length==0 || length>16_000_000 || result_value_budget==0 || result_value_budget>50_000_000 { return error("Invalid input buffer or result budget",1); }
    match catch_unwind(AssertUnwindSafe(||run(std::slice::from_raw_parts(json,length),result_value_budget,cancelled,progress,context))) {
        Ok(Ok(value))=>match serde_json::to_vec(&value) {Ok(bytes)=>buffer(bytes,0),Err(e)=>error(&e.to_string(),1)},
        Ok(Err(e))=>error(&e,if e=="cancelled" {2} else {1}),
        Err(_)=>error("The native physics engine rejected the scene",1),
    }
}

fn run(bytes:&[u8],budget:usize,cancelled:Cancel,progress:Progress,context:*mut c_void)->Result<Output,String> {
    let scene:Scene=serde_json::from_slice(bytes).map_err(|e|e.to_string())?;
    let time=&scene.time;
    if ![time.duration_seconds,time.step_seconds,time.output_interval_seconds].iter().all(|v|v.is_finite()&&*v>0.0) || time.output_interval_seconds<time.step_seconds || time.duration_seconds/time.step_seconds>100_000.0 || scene.bodies.len()>4096 || scene.joints.len()>8192 || scene.soft_bodies.len()>128 || (scene.bodies.is_empty() && scene.soft_bodies.is_empty()) { return Err("Scene, time or object budget exceeded".into()); }
    let mut world=PhysicsWorld::new(); world.gravity=scene.gravity.vector();
    let mut rigid=Vec::new(); let mut by_id=HashMap::new();
    for (index,body) in scene.bodies.iter().enumerate() {
        if cancelled.map_or(false,|f|f(context)!=0) {return Err("cancelled".into());}
        if by_id.contains_key(&body.id) || body.mass_kg<=0.0 || body.friction<0.0 || !(0.0..=1.0).contains(&body.restitution) || body.source_object_id.is_empty() { return Err("Invalid rigid-body identity or material".into()); }
        let builder=match body.motion.as_str() {"fixed"=>RigidBodyBuilder::fixed(),"dynamic"=>RigidBodyBuilder::dynamic(),"kinematic"=>RigidBodyBuilder::kinematic_position_based(),_=>return Err("Unknown body motion".into())};
        if body.activation_time_seconds<0.0 || body.activation_time_seconds>time.duration_seconds || body.lifetime_seconds.map_or(false,|l|l<=0.0) {return Err("Invalid body activation or lifetime".into());}
        let builder=builder.pose(Pose::from_parts(body.translation.vector(),body.rotation.rotation())).linvel(body.velocity.vector()).angvel(body.angular_velocity.vector()).linear_damping(body.linear_damping).angular_damping(body.angular_damping).ccd_enabled(true).enabled(body.activation_time_seconds<=0.0);
        let shape=&body.collider;
        let mut collider=match shape.kind.as_str() {
            "sphere" if shape.radius>0.0=>ColliderBuilder::ball(shape.radius),
            "box" if shape.half_extents.x>0.0 && shape.half_extents.y>0.0 && shape.half_extents.z>0.0=>ColliderBuilder::cuboid(shape.half_extents.x,shape.half_extents.y,shape.half_extents.z),
            "capsule" if shape.radius>0.0 && shape.half_height>0.0=>ColliderBuilder::capsule_y(shape.half_height,shape.radius),
            "convexHull" if shape.vertices.len()>=4 && shape.vertices.len()<=200_000=>ColliderBuilder::convex_hull(&shape.vertices.iter().map(|p|p.vector()).collect::<Vec<_>>()).ok_or("Degenerate convex hull")?,
            "convexDecomposition" if shape.vertices.len()>=4 && shape.vertices.len()<=200_000 && !shape.triangles.is_empty() && shape.triangles.len()<=50_000=>{
                validate_mesh(&shape.vertices,&shape.triangles)?;
                let params=VHACDParameters {resolution:64,max_convex_hulls:64,concavity:0.0025,..Default::default()};
                let result=ColliderBuilder::convex_decomposition_with_params(&shape.vertices.iter().map(|p|p.vector()).collect::<Vec<_>>(),&shape.triangles,&params);
                if cancelled.map_or(false,|f|f(context)!=0) {return Err("cancelled".into());}
                result
            },
            "triangleMesh" if body.motion!="dynamic" && shape.vertices.len()<=200_000 && shape.triangles.len()<=1_000_000=>{
                validate_mesh(&shape.vertices,&shape.triangles)?;
                ColliderBuilder::trimesh(shape.vertices.iter().map(|p|p.vector()).collect(),shape.triangles.clone()).map_err(|e|e.to_string())?
            },
            _=>return Err("Invalid or unsupported collision shape".into())
        }.mass(body.mass_kg).friction(body.friction).restitution(body.restitution).user_data(index as u128);
        if let Some(inertia)=body.principal_inertia_kg_square_meters {
            if inertia.x<=0.0 || inertia.y<=0.0 || inertia.z<=0.0 || inertia.x+inertia.y<inertia.z || inertia.x+inertia.z<inertia.y || inertia.y+inertia.z<inertia.x {return Err("Invalid principal inertia".into());}
            collider=collider.mass_properties(MassProperties::with_principal_inertia_frame(body.center_of_mass_meters.vector(),body.mass_kg,inertia.vector(),body.inertia_orientation.rotation()));
        } else if body.center_of_mass_meters.vector()!=Vector::ZERO {return Err("Custom center of mass requires explicit inertia".into());}
        let (handle,_)=world.insert(builder,collider); by_id.insert(body.id.clone(),handle); rigid.push(handle);
    }
    for joint in &scene.joints {
        let a=*by_id.get(&joint.first_body).ok_or("Missing first joint body")?;
        let b=*by_id.get(&joint.second_body).ok_or("Missing second joint body")?;
        if a==b || joint.axis.vector().length_squared()==0.0 || joint.motor_force<0.0 || (!joint.limits.is_empty() && (joint.limits.len()!=2 || joint.limits[0]>joint.limits[1])) {return Err("Invalid joint".into());}
        let axis=joint.axis.vector().normalize();
        let data:GenericJoint=match joint.kind.as_str() {
            "fixed"=>FixedJointBuilder::new().local_anchor1(joint.first_anchor.vector()).local_anchor2(joint.second_anchor.vector()).build().into(),
            "spherical"=>SphericalJointBuilder::new().local_anchor1(joint.first_anchor.vector()).local_anchor2(joint.second_anchor.vector()).build().into(),
            "revolute"=>{
                let mut j=RevoluteJointBuilder::new(axis).local_anchor1(joint.first_anchor.vector()).local_anchor2(joint.second_anchor.vector());
                if joint.limits.len()==2 {j=j.limits([joint.limits[0],joint.limits[1]]);}
                if joint.motor_force>0.0 {j=j.motor_velocity(joint.motor_velocity,1.0).motor_max_force(joint.motor_force);}
                j.build().into()
            },
            "prismatic"=>{
                let mut j=PrismaticJointBuilder::new(axis).local_anchor1(joint.first_anchor.vector()).local_anchor2(joint.second_anchor.vector());
                if joint.limits.len()==2 {j=j.limits([joint.limits[0],joint.limits[1]]);}
                if joint.motor_force>0.0 {j=j.motor_velocity(joint.motor_velocity,1.0).motor_max_force(joint.motor_force);}
                j.build().into()
            },
            "spring" if joint.rest_length_meters>=0.0 && joint.stiffness>0.0 && joint.damping>=0.0=>SpringJointBuilder::new(joint.rest_length_meters,joint.stiffness,joint.damping).local_anchor1(joint.first_anchor.vector()).local_anchor2(joint.second_anchor.vector()).build().into(),
            _=>return Err("Unknown or invalid joint model".into())
        };
        world.insert_impulse_joint(a,b,data);
    }
    let mut soft_handles=Vec::new(); let mut particle_count=0usize;
    for soft in &scene.soft_bodies {
        if cancelled.map_or(false,|f|f(context)!=0) {return Err("cancelled".into());}
        if (soft.kind!="mesh" && soft.dimensions.iter().any(|n|*n<2 || *n>256)) || soft.particle_mass_kg<=0.0 || soft.particle_radius_meters<=0.0 || soft.natural_frequency_hz<=0.0 || soft.damping_ratio<0.0 || soft.source_object_id.is_empty() {return Err("Invalid soft-body material or lattice".into());}
        let n=soft.dimensions;
        let expected=match soft.kind.as_str() {"rope"=>n[0],"cloth"=>n[0]*n[1],"volume"=>n[0]*n[1]*n[2],"mesh"=>soft.mesh_vertices.as_ref().map_or(0,|v|v.len()),_=>return Err("Unknown soft-body model".into())};
        if expected>200_000-particle_count {return Err("Soft-body node budget exceeded before allocation".into());}
        let builder=match soft.kind.as_str() {
            "rope"=>SoftBodyBuilder::rope(soft.origin.vector(),soft.end.vector(),n[0]),
            "cloth"=>SoftBodyBuilder::cloth(soft.origin.vector(),soft.du.vector(),soft.dv.vector(),n[0],n[1]),
            "volume"=>SoftBodyBuilder::cuboid(soft.origin.vector(),soft.half_extents.vector(),n[0],n[1],n[2]),
            "mesh"=>{
                let vertices=soft.mesh_vertices.as_ref().ok_or("Missing soft Mesh vertices")?;
                let triangles=soft.mesh_triangles.as_ref().ok_or("Missing soft Mesh triangles")?;
                validate_mesh(vertices,triangles)?;
                SoftBodyBuilder::trimesh(vertices.iter().map(|p|p.vector()).collect(),triangles.clone()).ok_or("Invalid soft Mesh")?
                    .shape_matching(soft.shape_matching.unwrap_or(false)).volume_preservation(soft.preserve_volume.unwrap_or(false))
            },
            _=>return Err("Unknown soft-body model".into())
        };
        let count=builder.particle_positions().len(); particle_count+=count;
        if particle_count>200_000 || soft.pinned_indices.iter().any(|i|*i as usize>=count) {return Err("Soft-body node budget or pinned index invalid".into());}
        let builder=builder.pinned_particles(soft.pinned_indices.iter().copied()).particle_mass(soft.particle_mass_kg).particle_radius(soft.particle_radius_meters).softness(SpringCoefficients::new(soft.natural_frequency_hz,soft.damping_ratio)).linear_damping(soft.linear_damping).self_contacts(soft.self_collision).surface_collider(ColliderBuilder::ball(soft.particle_radius_meters).friction(soft.friction));
        soft_handles.push(world.insert_soft_body(builder));
    }
    for field in &scene.force_fields {
        if field.softening_radius_meters<=0.0 || field.axis.vector().length_squared()==0.0 || !["uniform","pointAttractor","vortex"].contains(&field.kind.as_str()) || field.body_ids.iter().any(|id|!by_id.contains_key(id)) {return Err("Invalid force field".into());}
    }
    let acceleration=|field:&ForceField,position:Vector|->Vector {
        let offset=field.center.vector()-position;
        let distance_squared=offset.length_squared()+field.softening_radius_meters*field.softening_radius_meters;
        match field.kind.as_str() {
            "uniform"=>field.acceleration.vector(),
            "pointAttractor"=>offset*(field.strength/(distance_squared*distance_squared.sqrt())),
            "vortex"=>field.axis.vector().normalize().cross(-offset)*(field.strength/distance_squared.sqrt()),
            _=>Vector::ZERO
        }
    };
    let frame_values=scene.bodies.len()*14 + particle_count*3;
    let sample_count=(time.duration_seconds/time.output_interval_seconds).ceil() as usize+2;
    if frame_values.checked_mul(sample_count).map_or(true,|n|n>budget) {return Err("Result value budget exceeded".into());}
    let steps=(time.duration_seconds/time.step_seconds).ceil() as u32;
    let soft_topology=soft_handles.iter().enumerate().map(|(i,h)|SoftTopology{id:scene.soft_bodies[i].id.clone(),triangles:world.soft_bodies[*h].boundary().to_vec()}).collect();
    let mut frames=Vec::new(); let mut t=0.0; let mut next_output=0.0;
    for step in 0..=steps {
        if cancelled.map_or(false,|f|f(context)!=0) {return Err("cancelled".into());}
        if t+1e-10>=next_output || step==steps {
            let bodies=rigid.iter().enumerate().map(|(i,h)|{let b=&world.bodies[*h];let r=b.rotation();let input=&scene.bodies[i];let visible=t+1e-10>=input.activation_time_seconds && input.lifetime_seconds.map_or(true,|l|t<input.activation_time_seconds+l);BodyPose{id:input.id.clone(),translation:xyz(b.translation()),rotation:Q{x:r.x,y:r.y,z:r.z,w:r.w},velocity:xyz(b.linvel()),angular_velocity:xyz(b.angvel()),visible}}).collect();
            let soft_bodies=soft_handles.iter().enumerate().map(|(i,h)|{let b=&world.soft_bodies[*h];SoftPose{id:scene.soft_bodies[i].id.clone(),vertices:b.particle_positions().map(xyz).collect(),topology_version:b.topology_version()}}).collect();
            let contacts=world.narrow_phase.contact_pairs().filter(|p|p.has_any_active_contact()).filter_map(|p|{let a=world.colliders[p.collider1].parent()?;let b=world.colliders[p.collider2].parent()?;Some([rigid.iter().position(|h|*h==a)?,rigid.iter().position(|h|*h==b)?])}).collect();
            frames.push(Frame{time_seconds:t,bodies,soft_bodies,contacts}); next_output+=time.output_interval_seconds;
        }
        if step==steps {break;}
        let dt=time.step_seconds.min(time.duration_seconds-t); let target=t+dt;
        for (i,body) in scene.bodies.iter().enumerate() {
            let active=t+1e-10>=body.activation_time_seconds && body.lifetime_seconds.map_or(true,|l|t<body.activation_time_seconds+l);
            let b=&mut world.bodies[rigid[i]]; b.set_enabled(active); b.reset_forces(false);
            if active && body.motion=="dynamic" {
                let position=b.translation(); let mut value=Vector::ZERO;
                for field in scene.force_fields.iter().filter(|f|f.body_ids.is_empty() || f.body_ids.contains(&body.id)) {value+=acceleration(field,position);}
                if value.length_squared()>0.0 { b.add_force(value*body.mass_kg,true); }
            }
        }
        for handle in &soft_handles {
            let body=&mut world.soft_bodies[*handle]; body.reset_forces(false);
            for index in 0..body.num_particles() {
                let position=body.particle_position(index); let mass=body.particles()[index].mass(); let mut value=Vector::ZERO;
                for field in scene.force_fields.iter().filter(|f|f.affects_soft_bodies) {value+=acceleration(field,position);}
                if value.length_squared()>0.0 { body.add_particle_force(index,value*mass,true); }
            }
        }
        for (i,body) in scene.bodies.iter().enumerate().filter(|(_,b)|b.motion=="kinematic" && !b.kinematic_keys.is_empty()) {
            let keys=&body.kinematic_keys;
            let upper=keys.partition_point(|k|k.time_seconds<target);
            let first=&keys[upper.saturating_sub(1).min(keys.len()-1)]; let last=&keys[upper.min(keys.len()-1)];
            let alpha=if last.time_seconds>first.time_seconds {((target-first.time_seconds)/(last.time_seconds-first.time_seconds)).clamp(0.0,1.0)} else {0.0};
            world.bodies[rigid[i]].set_next_kinematic_position(Pose::from_parts(first.translation.vector().lerp(last.translation.vector(),alpha),first.rotation.rotation().slerp(last.rotation.rotation(),alpha)));
        }
        world.integration_parameters.dt=dt; world.step(); t=target;
        if step%16==0 || step+1==steps {if let Some(report)=progress {report(context,step+1,steps);}}
    }
    Ok(Output{version:"rapier3d-f64/0.36.1/floe-abi3".into(),seed:scene.seed,soft_topology,frames})
}

fn validate_mesh(vertices:&[V],triangles:&[[u32;3]])->Result<(),String> {
    if vertices.len()<3 || vertices.len()>200_000 || triangles.is_empty() || triangles.len()>1_000_000 || vertices.iter().any(|p|![p.x,p.y,p.z].iter().all(|v|v.is_finite())) {return Err("Invalid Mesh geometry or budget".into());}
    for triangle in triangles {
        if triangle.iter().any(|i|*i as usize>=vertices.len()) {return Err("Invalid Mesh triangle index".into());}
        let a=vertices[triangle[0] as usize].vector();let b=vertices[triangle[1] as usize].vector();let c=vertices[triangle[2] as usize].vector();
        if (b-a).cross(c-a).length_squared()<=1e-36 {return Err("Degenerate Mesh triangle".into());}
    }
    Ok(())
}
