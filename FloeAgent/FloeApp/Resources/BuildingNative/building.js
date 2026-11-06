// SPDX-License-Identifier: MPL-2.0
// Fixed on-device adapter. Imported model text is data, never executable code.
// IFC4 tessellation preserves the saved geometry; it does not reconstruct BRep.
(function (scope) {
  'use strict';
  const types = {wall:'IFCWALL',slab:'IFCSLAB',roof:'IFCROOF',stair:'IFCSTAIR',column:'IFCCOLUMN',beam:'IFCBEAM',door:'IFCDOOR',window:'IFCWINDOW',space:'IFCSPACE',pipe:'IFCPIPESEGMENT',duct:'IFCDUCTSEGMENT'};
  const alphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_$';
  function guid(value) {
    const hex = String(value).replaceAll('-', '');
    if (!/^[0-9a-fA-F]{32}$/.test(hex)) throw Error('Invalid building identity.');
    let n = BigInt('0x' + hex), out = '';
    for (let i=0;i<22;i++) { out = alphabet[Number(n & 63n)] + out; n >>= 6n; }
    return out;
  }
  function quote(value) {
    let out = '';
    for (let i=0;i<String(value).length;i++) {
      const c = String(value).charCodeAt(i);
      // web-ifc 0.0.75 cannot round-trip non-BMP STEP strings on SaveModel.
      // Fail explicitly rather than silently corrupting the user's names.
      if(c>=0xD800&&c<=0xDFFF)throw Error('IFC export cannot preserve emoji or supplementary characters in names. Rename the project, storey or element and try again. / IFC 导出暂不支持名称中的表情或扩展字符，请修改项目、楼层或构件名称后重试。');
      if (c < 32 || c > 126 || c === 92 || c === 39) out += '\\X2\\' + c.toString(16).padStart(4,'0').toUpperCase() + '\\X0\\';
      else out += String.fromCharCode(c);
    }
    return "'"+out+"'";
  }
  function real(n) {
    if (!Number.isFinite(n)) throw Error('Non-finite building coordinate.');
    const [mantissa,exponent]=String(n).toUpperCase().split('E');
    return (mantissa.includes('.')?mantissa:mantissa+'.')+(exponent===undefined?'':'E'+exponent);
  }
  const tuple = xs => '('+xs.join(',')+')';
  function xml(s) { return String(s).replace(/[&<>"']/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[c])); }
  function createSTEP(input) {
    if (input.schemaVersion!==1 || !input.model || !Array.isArray(input.geometry)) throw Error('Invalid building snapshot.');
    const model=input.model, rows=[], geometries=new Map(), products=new Map(), stores=new Map(); let triangles=0;
    if (!Array.isArray(model.elements) || model.elements.length>10000 || !Array.isArray(model.storeys) || model.storeys.length>1000) throw Error('Building export limit exceeded.');
    const add = (type,args) => { rows.push('#'+(rows.length+1)+'='+type+'('+args.join(',')+');'); return '#'+rows.length; };
    const usedIDs=new Set();
    for(const id of [model.id,...model.storeys.map(s=>s.id),...model.elements.map(e=>e.id)]){
      const key=guid(id);if(usedIDs.has(key))throw Error('Duplicate IFC identity.');usedIDs.add(key);
    }
    let relation=BigInt('0x'+String(model.id).replaceAll('-','')) ^ 0xF1000000000000000000000000000000n;
    const nextGUID=()=>{let key;do{key=guid((relation++).toString(16).padStart(32,'0'));}while(usedIDs.has(key));usedIDs.add(key);return quote(key);};
    const p=add('IFCCARTESIANPOINT',['(0.,0.,0.)']), axis=add('IFCAXIS2PLACEMENT3D',[p,'$','$']);
    const placement=add('IFCLOCALPLACEMENT',['$',axis]);
    const context=add('IFCGEOMETRICREPRESENTATIONCONTEXT',['$',quote('Model'),'3','1.E-7',axis,'$']);
    const unit=add('IFCSIUNIT',['*','.LENGTHUNIT.','$','.METRE.']), units=add('IFCUNITASSIGNMENT',[tuple([unit])]);
    const project=add('IFCPROJECT',[quote(guid(model.id)),'$',quote(model.name),'$','$','$','$',tuple([context]),units]);
    const building=add('IFCBUILDING',[nextGUID(),'$',quote(model.name),'$','$',placement,'$','$','.ELEMENT.','$','$','$']);
    const aggregate=(parent,children)=>{ if(children.length)add('IFCRELAGGREGATES',[nextGUID(),'$','$','$',parent,tuple(children)]); };
    aggregate(project,[building]);
    for (const s of model.storeys) {
      if(stores.has(s.id))throw Error('Duplicate storey.');
      const ref=add('IFCBUILDINGSTOREY',[quote(guid(s.id)),'$',quote(s.name),'$','$',placement,'$','$','.ELEMENT.',real(s.elevationMM/1000)]);
      stores.set(s.id,ref);
    }
    aggregate(building,[...stores.values()]);
    for (const g of input.geometry) {
      if(!Array.isArray(g.verticesM)||!g.verticesM.length||!Array.isArray(g.indices)||!g.indices.length||g.indices.length%3)throw Error('Invalid building mesh.');
      triangles+=g.indices.length/3;if(triangles>500000)throw Error('Building triangle limit exceeded.');
      const vertices=g.verticesM.map(v=>{if(!Array.isArray(v)||v.length!==3)throw Error('Invalid vertex.');return tuple(v.map(real));});
      const faces=[];
      for(let i=0;i<g.indices.length;i+=3)faces.push(tuple(g.indices.slice(i,i+3).map(n=>{if(!Number.isSafeInteger(n)||n<0||n>=vertices.length)throw Error('Invalid triangle index.');return String(n+1);} )));
      const points=add('IFCCARTESIANPOINTLIST3D',[tuple(vertices)]);
      const mesh=add('IFCTRIANGULATEDFACESET',[points,'$','$',tuple(faces),'$']);
      if(!geometries.has(g.elementID))geometries.set(g.elementID,[]);geometries.get(g.elementID).push(mesh);
    }
    for(const e of model.elements){
      const type=types[e.kind];if(!type||!stores.has(e.storeyID)||products.has(e.id))throw Error('Invalid building element.');
      const meshes=geometries.get(e.id)||[];
      if(e.kind!=='space'&&!meshes.length)throw Error('Building geometry is missing.');
      let representation='$';
      if(meshes.length){ const shape=add('IFCSHAPEREPRESENTATION',[context,quote('Body'),quote('Tessellation'),tuple(meshes)]);representation=add('IFCPRODUCTDEFINITIONSHAPE',['$','$',tuple([shape])]); }
      // Snapshot vertices already include every body transform and storey elevation.
      const common=[quote(guid(e.id)),'$',quote(e.name),'$','$',placement,representation];
      let tail=[quote(e.id),'.NOTDEFINED.'];
      if(e.kind==='door'||e.kind==='window') tail=[quote(e.id),real(e.heightMM/1000),real((e.widthMM||e.thicknessMM)/1000),'.NOTDEFINED.','.NOTDEFINED.','$'];
      if(e.kind==='space')tail=['$','.ELEMENT.','.NOTDEFINED.','$'];
      const ref=add(type,[...common,...tail]);products.set(e.id,ref);
    }
    if([...geometries.keys()].some(id=>!products.has(id)))throw Error('Unowned building geometry.');
    for(const s of model.storeys){
      const members=model.elements.filter(e=>e.storeyID===s.id&&e.kind!=='space').map(e=>products.get(e.id));
      if(members.length)add('IFCRELCONTAINEDINSPATIALSTRUCTURE',[nextGUID(),'$','$','$',tuple(members),stores.get(s.id)]);
      aggregate(stores.get(s.id),model.elements.filter(e=>e.storeyID===s.id&&e.kind==='space').map(e=>products.get(e.id)));
    }
    const timestamp = new Date().toISOString();
    const header="ISO-10303-21;\nHEADER;\nFILE_DESCRIPTION(('ViewDefinition [ReferenceView_V1.2]'),'2;1');\nFILE_NAME('model.ifc',"+quote(timestamp)+",('Floe'),('Floe'),'web-ifc 0.0.75','Floe','');\nFILE_SCHEMA(('IFC4'));\nENDSEC;\nDATA;\n";
    return {text:header+rows.join('\n')+'\nENDSEC;\nEND-ISO-10303-21;\n',triangles,meshCount:input.geometry.length};
  }
  function inspect(api,id,input,W){
    const count=t=>{const v=api.GetLineIDsWithType(id,W[t]);return v.size();};
    if(api.GetModelSchema(id)!=='IFC4'||count('IFCPROJECT')!==1||count('IFCBUILDINGSTOREY')!==input.model.storeys.length||count('IFCTRIANGULATEDFACESET')!==input.geometry.length)throw Error('IFC readback does not match its source.');
    const checks=[];
    for(const type of Object.values(types)){
      const elements=input.model.elements.filter(e=>types[e.kind]===type), expectedNames=new Map(elements.map(e=>[guid(e.id),String(e.name)]));
      const ids=api.GetLineIDsWithType(id,W[type]), expected=elements.length;
      if(ids.size()!==expected)throw Error('IFC product readback mismatch: '+type);
      if(!expected)continue;let failed=0;
      for(let i=0;i<ids.size();i++){
        const line=api.GetLine(id,ids.get(i)), name=String(line.Name?.value||''), globalID=line.GlobalId?.value;
        if(!expectedNames.has(globalID)||name!==expectedNames.get(globalID))throw Error('IFC identity or name readback mismatch.');
        if(!name.trim())failed++;
      }
      checks.push({name:type+' Name',passed:failed===0,applicable:expected,failed});
    }
    return {buildingRegulations:false,method:'Floe IFC4 Name presence subset / IDS 1.0',checks};
  }
  function requirements(input){
    const present=[...new Set(input.model.elements.map(e=>types[e.kind]))];
    if(!present.length)throw Error('Add a building element before checking information requirements. / 请先添加建筑构件，再运行信息要求检查。');
    return '<?xml version="1.0" encoding="UTF-8"?>\n<ids:ids xmlns:ids="http://standards.buildingsmart.org/IDS" xmlns:xs="http://www.w3.org/2001/XMLSchema"><ids:info><ids:title>Floe element names</ids:title><ids:description>Name-presence subset only; no building regulation approval.</ids:description></ids:info><ids:specifications>'+present.map(t=>'<ids:specification name="'+xml(t)+' Name" ifcVersion="IFC4"><ids:applicability minOccurs="0" maxOccurs="unbounded"><ids:entity><ids:name><ids:simpleValue>'+t+'</ids:simpleValue></ids:name></ids:entity></ids:applicability><ids:requirements><ids:attribute cardinality="required"><ids:name><ids:simpleValue>Name</ids:simpleValue></ids:name></ids:attribute></ids:requirements></ids:specification>').join('')+'</ids:specifications></ids:ids>\n';
  }
  let outputs=null, busy=false;
  async function run(inputJSON){
    if(busy)throw Error('A building export is already running.');busy=true;
    const input=JSON.parse(inputJSON), W=scope.WebIFC, api=new W.IfcAPI();let id=-1, reopened=-1;
    try{
      const step=createSTEP(input);
      await api.Init((file)=>new URL(file,location.href).href,true);
      id=api.OpenModel(new TextEncoder().encode(step.text));
      if(id<0)throw Error('IFC parser rejected the exported model.');inspect(api,id,input,W);
      const data=api.SaveModel(id);if(!data.length||data.length>128*1024*1024)throw Error('IFC output exceeds the device export limit.');
      reopened=api.OpenModel(data);if(reopened<0)throw Error('Saved IFC could not reopen.');
      const information=inspect(api,reopened,input,W);
      outputs={ifc:data.slice()};
      if(input.action==='information')outputs.ids=new TextEncoder().encode(requirements(input));
      return JSON.stringify({triangles:step.triangles,ifcBytes:data.length,idsBytes:outputs.ids?.length||0,backendVersions:{'web-ifc':'0.0.75','Floe IFC adapter':'1'},information:input.action==='information'?information:null});
    }finally{if(reopened>=0)api.CloseModel(reopened);if(id>=0)api.CloseModel(id);api.Dispose?.();busy=false;}
  }
  function chunk(name,offset){
    const data=outputs?.[name];if(!data||!Number.isSafeInteger(offset)||offset<0||offset>=data.length)throw Error('Invalid output chunk.');
    const bytes=data.subarray(offset,Math.min(offset+49152,data.length));let value='';for(let i=0;i<bytes.length;i++)value+=String.fromCharCode(bytes[i]);return btoa(value);
  }
  scope.FloeBuilding={run,chunk,createSTEP,inspect,requirements,ready:true};
})(globalThis);
