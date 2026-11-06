// SPDX-License-Identifier: MPL-2.0
use super::*;
use acadrust::{DxfVersion, TextStyle, TableEntry};
use acadrust::objects::{AssociativeData, AssociativeObject, AssocDimensionAssociation, AssocDimensionReference, ObjectType};
fn associated(format: &str) -> (CadSession,Handle,Handle,Handle) {
    let mut document=CadDocument::new(); document.version=DxfVersion::AC1032;
    let source=document.add_entity(EntityType::Line(Line::from_coords(0.,0.,0.,10.,0.,0.))).unwrap();
    let dim=document.add_entity(build_dimension("linear",&[[0.,0.,0.],[10.,0.,0.]],Some(5.),None,format).unwrap()).unwrap();
    let relation=document.allocate_handle();
    let mut a=AssociativeObject::new("DIMASSOC","AcDbDimAssoc"); a.handle=relation; a.owner=dim;
    let mut v=AssocDimensionAssociation { associativity:3, dimension:dim, ..Default::default() };
    for (slot,p) in [Vector3::ZERO,Vector3::new(10.,0.,0.)].into_iter().enumerate() {
        v.references[slot].push(AssocDimensionReference { class_name:"AcDbOsnapPointRef".into(),
            osnap_type:1, xrefs:vec![source], osnap_point:p, ..Default::default() });
    }
    a.data=AssociativeData::DimensionAssociation(v); document.objects.insert(relation,ObjectType::Associative(a));
    document.get_entity_mut(source).unwrap().common_mut().reactors.push(relation);
    let input=encode(&document,format).unwrap(); (CadSession::new(&input,format).unwrap(),source,dim,relation)
}
fn edit(s:&mut CadSession,v:Value) { s.edit(&v.to_string()).unwrap(); }
fn dimension(s:&CadSession,key:Handle)->&Dimension { match s.document.get_entity(key).unwrap() { EntityType::Dimension(d)=>d,_=>panic!() } }
#[test]
fn annotation_native_association_geometry_text_position_save_reopen_undo() {
    for format in ["dxf","dwg"] {
        let (mut s,source,dim,relation)=associated(format); let original=s.save().unwrap();
        edit(&mut s,json!({"operation":"batch","operations":[
            {"operation":"setLineEndpoints","handle":format!("{source:X}"),"start":[0,0,0],"end":[25,0,0]},
            {"operation":"updateDimension","handle":format!("{dim:X}"),"text":"Length <> mm","textPosition":[12,8,0],"linePosition":[0,7,0],"textRotationDegrees":15}]}));
        assert_eq!(dimension(&s,dim).measurement(),25.); assert_eq!(dimension(&s,dim).base().actual_measurement,25.);
        assert_eq!(dimension(&s,dim).base().text,"Length <> mm");
        assert!(s.undo()); assert_eq!(dimension(&s,dim).measurement(),10.); assert!(!s.undo()); assert!(s.redo());
        let output=s.save().unwrap_or_else(|e|panic!("{format}: {e}"));
        let mut reopened=CadSession::new(&output,format).unwrap(); assert_eq!(dimension(&reopened,dim).measurement(),25.);
        assert_eq!(dimension(&reopened,dim).base().text_middle_point,Vector3::new(12.,8.,0.));
        let ObjectType::Associative(a)=reopened.document.objects.get(&relation).unwrap() else { panic!() };
        let AssociativeData::DimensionAssociation(v)=&a.data else { panic!() };
        assert_eq!(v.references[1][0].xrefs,vec![source]); assert_eq!(v.references[1][0].osnap_point,Vector3::new(25.,0.,0.));
        edit(&mut reopened,json!({"operation":"setLineEndpoints","handle":format!("{source:X}"),"start":[0,0,0],"end":[30,0,0]}));
        assert_eq!(dimension(&reopened,dim).measurement(),30.); reopened.save().unwrap();
        if let Some(dir)=std::env::var_os("FLOE_CAD_FIXTURE_OUTPUT") {
            let dir=std::path::PathBuf::from(dir); std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(dir.join(format!("e22-assoc-original.{format}")),original).unwrap();
            std::fs::write(dir.join(format!("e22-assoc-edited.{format}")),output).unwrap();
        }
    }
}
#[test]
fn annotation_unsupported_associations_reject_atomically_without_history() {
    for kind in ["xref","chain","intersection","stale","delete","unknownReactor"] {
        let (mut s,source,_dim,relation)=associated("dxf");
        if let ObjectType::Associative(a)=s.document.objects.get_mut(&relation).unwrap() {
            if let AssociativeData::DimensionAssociation(v)=&mut a.data {
                match kind {
                    "xref"=>v.references[1][0].xref_paths.push("external.dwg".into()),
                    "chain"=>{let r=v.references[1][0].clone();v.references[1].push(r);},
                    "intersection"=>v.references[1][0].intersection_objects.push(source),
                    "stale"=>v.references[1][0].osnap_point.x=9., _=>{}
                }
            }
        }
        if kind=="unknownReactor" {s.document.get_entity_mut(source).unwrap().common_mut().reactors.push(Handle::new(0xBAD));}
        let before=s.inspect(0,500).unwrap(); let aux=auxiliary_image(&s.document);
        let request=if kind=="delete" {json!({"operation":"delete","handle":format!("{source:X}")})}
            else {json!({"operation":"move","handle":format!("{source:X}"),"delta":[1,0,0]})};
        assert!(s.edit(&request.to_string()).is_err(),"{kind}"); assert_eq!(before,s.inspect(0,500).unwrap(),"{kind}");
        assert_eq!(aux,auxiliary_image(&s.document)); assert!(!s.undo());
    }
}
#[test]
fn annotation_dimension_fields_and_operation_capabilities() {
    for format in ["dxf","dwg"] {
        let (mut s,source,dim,_)=associated(format);
        let rows:Value=serde_json::from_str(&s.inspect(0,500).unwrap()).unwrap();
        let row=rows["entities"].as_array().unwrap().iter().find(|r|r["handle"]==format!("{dim:X}")).unwrap();
        assert_eq!(row["operations"],json!(["updateDimension"]));
        assert!(s.edit(&json!({"operation":"move","handle":format!("{dim:X}"),"delta":[1,0,0]}).to_string()).is_err());
        assert!(s.edit(&json!({"operation":"copy","handle":format!("{source:X}"),"delta":[1,0,0]}).to_string()).is_err());
        edit(&mut s,json!({"operation":"updateDimension","handle":format!("{dim:X}"),"text":""}));
        assert!(dimension(&s,dim).base().user_text.is_none()); s.save().unwrap();
        let before=s.inspect(0,500).unwrap();
        for invalid in [json!({"textPosition":[1,2,3]}),json!({"unrecognized":1})] {
            let mut op=invalid;op["operation"]=json!("updateDimension");op["handle"]=json!(format!("{dim:X}"));
            assert!(s.edit(&op.to_string()).is_err());assert_eq!(before,s.inspect(0,500).unwrap());
        }
    }
}
#[test]
fn annotation_failed_same_format_save_preserves_editable_draft() {
    let (mut s,source,dim,_)=associated("dxf"); let input=s.save().unwrap();
    let mut style=TextStyle::with_truetype("UNPRESERVED","MiSans-Regular.ttf");style.set_handle(s.document.allocate_handle());s.document.text_styles.add(style).unwrap();
    edit(&mut s,json!({"operation":"setLineEndpoints","handle":format!("{source:X}"),"start":[0,0,0],"end":[20,0,0]}));
    let before=s.inspect(0,500).unwrap(); assert!(s.save().is_err());assert_eq!(before,s.inspect(0,500).unwrap());
    assert_eq!(dimension(&s,dim).measurement(),20.); assert_eq!(read(&input,"dxf").unwrap().entity_count(),2);
    assert!(s.undo());assert_eq!(dimension(&s,dim).measurement(),10.);
}

#[test]
fn annotation_linear_aligned_update_other_dimension_types_readonly_and_leader_persist() {
    for format in ["dxf","dwg"] {
        let input=encode(&CadDocument::new(),format).unwrap();let mut s=CadSession::new(&input,format).unwrap();
        for (kind,points) in [("linear",vec![[0.,0.,0.],[10.,0.,0.]]),("aligned",vec![[0.,0.,0.],[8.,6.,0.]]),
            ("angular",vec![[0.,0.,0.],[10.,0.,0.],[0.,10.,0.]]),("radius",vec![[0.,0.,0.],[5.,0.,0.]]),("diameter",vec![[-5.,0.,0.],[5.,0.,0.]])] {
            let entity=build_dimension(kind,&points,None,None,format).unwrap();let id=s.document.add_entity(entity).unwrap();
            let request=json!({"operation":"updateDimension","handle":format!("{id:X}"),"text":format!("{kind} <>"),"textPosition":[3,4,0],"textRotationDegrees":20});
            if ["linear","aligned"].contains(&kind){edit(&mut s,request);}else{assert!(s.edit(&request.to_string()).is_err());assert!(entity_operations(&s.document,s.document.get_entity(id).unwrap()).is_empty());}
        }
        let result:Value=serde_json::from_str(&s.edit(r#"{"operation":"addLeader","points":[[0,0,0],[3,3,0]],"layer":"0"}"#).unwrap()).unwrap();
        let id=result["created"][0].as_str().unwrap();edit(&mut s,json!({"operation":"updateLeader","handle":id,"points":[[1,1,0],[4,5,0],[8,5,0]]}));
        let output=s.save().unwrap_or_else(|e|panic!("{format}: {e}"));let reopened=read(&output,format).unwrap();assert_eq!(reopened.entity_count(),6);
    }
}

#[test]
fn annotation_custom_dimension_cache_is_readonly_and_anonymous_cache_is_retained() {
    for format in ["dxf","dwg"] {
        let (mut s,_,dim,_)=associated(format);
        let mut br=acadrust::tables::BlockRecord::new("*D1");br.set_handle(s.document.allocate_handle());let block=br.handle;
        s.document.block_records.add(br).unwrap();
        let mut line=Line::from_coords(1.,7.,0.,8.,7.,0.);line.common.owner_handle=block;let content=s.document.add_entity(EntityType::Line(line)).unwrap();
        let cache=entity_image(s.document.get_entity(content).unwrap());
        let EntityType::Dimension(d)=s.document.get_entity_mut(dim).unwrap() else {panic!()};d.base_mut().block_name="*D1".into();
        edit(&mut s,json!({"operation":"updateDimension","handle":format!("{dim:X}"),"text":"new <>"}));
        assert!(dimension(&s,dim).base().block_name.is_empty());assert_eq!(cache,entity_image(s.document.get_entity(content).unwrap()));
        assert!(s.document.block_records.get("*D1").is_some());
        let EntityType::Dimension(d)=s.document.get_entity_mut(dim).unwrap() else {panic!()};d.base_mut().block_name="UserGeometry".into();
        assert!(s.edit(&json!({"operation":"updateDimension","handle":format!("{dim:X}"),"text":"rejected"}).to_string()).is_err());
    }
}

#[test]
fn annotation_mixed_drawing_readonly_entities_survive_supported_dxf_edit() {
    use acadrust::entities::{Spline,Hatch,BoundaryPath,BoundaryEdge,PolylineEdge,Insert,Block,BlockEnd};
    let mut document=CadDocument::new();document.version=DxfVersion::AC1032;
    let line=document.add_entity(EntityType::Line(Line::from_coords(0.,0.,0.,10.,0.,0.))).unwrap();
    let spline=Spline::from_control_points(2,vec![Vector3::ZERO,Vector3::new(4.,6.,0.),Vector3::new(10.,0.,0.)]);
    document.add_entity(EntityType::Spline(spline)).unwrap();
    let mut hatch=Hatch::solid();let mut path=BoundaryPath::external();
    path.add_edge(BoundaryEdge::Polyline(PolylineEdge::new(vec![Vector2::new(0.,0.),Vector2::new(5.,0.),Vector2::new(5.,5.),Vector2::new(0.,5.)],true)));
    hatch.add_path(path);document.add_entity(EntityType::Hatch(hatch)).unwrap();
    for (name,xref) in [("DRAWING_BLOCK",false),("EXTERNAL_REFERENCE",true)] {
        let mut br=acadrust::tables::BlockRecord::new(name);br.set_handle(document.allocate_handle());
        br.block_entity_handle=document.allocate_handle();br.block_end_handle=document.allocate_handle();br.flags.is_xref=xref;
        if xref {br.xref_path="external-reference.dwg".into();}
        let (owner,start,end)=(br.handle,br.block_entity_handle,br.block_end_handle);document.block_records.add(br).unwrap();
        let mut block=Block::new(name,Vector3::ZERO);block.common.handle=start;block.common.owner_handle=owner;if xref{block.xref_path="external-reference.dwg".into();}
        document.add_entity(EntityType::Block(block)).unwrap();
        if !xref {let mut e=Line::from_coords(1.,1.,0.,2.,2.,0.);e.common.owner_handle=owner;document.add_entity(EntityType::Line(e)).unwrap();}
        let mut e=BlockEnd::new();e.common.handle=end;e.common.owner_handle=owner;document.add_entity(EntityType::BlockEnd(e)).unwrap();
        document.add_entity(EntityType::Insert(Insert::new(name,Vector3::new(20.,0.,0.)))).unwrap();
    }
    let source=encode(&document,"dxf").unwrap();let mut s=CadSession::new(&source,"dxf").unwrap();
    let unchanged:Vec<_>=s.document.entities().filter(|e|e.common().handle!=line).map(|e|(e.common().handle,entity_image(e))).collect();
    let aux=auxiliary_image(&s.document);
    edit(&mut s,json!({"operation":"move","handle":format!("{line:X}"),"delta":[1,2,0]}));
    for (id,image) in &unchanged{assert_eq!(*image,entity_image(s.document.get_entity(*id).unwrap()));assert!(entity_operations(&s.document,s.document.get_entity(*id).unwrap()).is_empty());}
    assert_eq!(aux,auxiliary_image(&s.document));let output=s.save().unwrap();
    let reopened=read(&output,"dxf").unwrap();for (id,image) in &unchanged {assert!(equivalent(image,&entity_image(reopened.get_entity(*id).unwrap())));}
    assert_eq!(reopened.block_records.get("EXTERNAL_REFERENCE").unwrap().xref_path,"external-reference.dwg");
    if let Some(dir)=std::env::var_os("FLOE_CAD_FIXTURE_OUTPUT"){let dir=std::path::PathBuf::from(dir);std::fs::write(dir.join("e20-mixed-original.dxf"),source).unwrap();std::fs::write(dir.join("e20-mixed-edited.dxf"),output).unwrap();}
}

#[test]
#[ignore = "requires an explicitly supplied external CAD corpus file"]
fn annotation_external_fixture_strict_gate() {
    let source=std::env::var("FLOE_CAD_COMPAT_INPUT").expect("supply a real external fixture path");
    let output=std::path::PathBuf::from(std::env::var("FLOE_CAD_FIXTURE_OUTPUT").unwrap());
    let format=std::path::Path::new(&source).extension().unwrap().to_str().unwrap();
    let bytes=std::fs::read(&source).unwrap();let mut s=CadSession::new(&bytes,format).unwrap();
    let candidate=encode(&s.document,format).unwrap();let other=read(&candidate,format).unwrap();
    std::fs::write(output.join("compat-before.json"),serde_json::to_string_pretty(&json!({"aux":auxiliary_image(&s.document),"entities":s.document.entities().map(entity_image).collect::<Vec<_>>()})).unwrap()).unwrap();
    std::fs::write(output.join("compat-after.json"),serde_json::to_string_pretty(&json!({"aux":auxiliary_image(&other),"entities":other.entities().map(entity_image).collect::<Vec<_>>()})).unwrap()).unwrap();
    let edit_id=s.document.entities().find(|e| matches!(e,EntityType::Line(_)) && model_space(&s.document,e)).map(|e|e.common().handle);
    if let Some(id)=edit_id {
        edit(&mut s,json!({"operation":"move","handle":format!("{id:X}"),"delta":[0.1,0,0]}));
    }
    if edit_id.is_none() {
        let text=s.document.entities().find_map(|e|match e {EntityType::Text(t) if model_space(&s.document,e)=>Some((t.common.handle,t.value.clone())),_=>None});
        if let Some((id,text))=text {edit(&mut s,json!({"operation":"setText","handle":format!("{id:X}"),"text":text+" [Floe]"}));}
        else {edit(&mut s,json!({"operation":"addStroke","points":[[0,0,0],[5,2,0],[10,0,0]]}));}
    }
    let saved=s.save().expect("external same-format strict save must preserve the drawing");
    std::fs::write(output.join(format!("compat-saved.{format}")),saved).unwrap();
}

#[test]
fn annotation_attached_or_nonplanar_leaders_are_readonly() {
    for attached in [true,false] {
        let mut doc=CadDocument::new();let mut v=Leader::new();v.vertices=vec![Vector3::ZERO,Vector3::new(1.,1.,0.)];
        if attached {v.annotation_handle=Handle::new(0xBAD);}else{v.normal=Vector3::UNIT_X;}
        let id=doc.add_entity(EntityType::Leader(v)).unwrap();let mut s=CadSession{document:doc,format:"dxf".into(),undo:vec![],redo:vec![],active_layer:"0".into(),revision:0,engineering_profile:false};
        assert!(entity_operations(&s.document,s.document.get_entity(id).unwrap()).is_empty());
        assert!(s.edit(&json!({"operation":"updateLeader","handle":format!("{id:X}"),"points":[[1,1,0],[2,2,0]]}).to_string()).is_err());assert!(!s.undo());
    }
}
