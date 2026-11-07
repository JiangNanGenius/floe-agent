// SPDX-License-Identifier: MPL-2.0
import { zipSync,unzipSync,strToU8,strFromU8 } from 'fflate';
import { clone,uid,t,required,parseXML,escapeXML,from64,bytes64 } from '../../FloeHeavyEditorSupport/Web/runtime.js';
import { createFont,normalizeFont,glyph,point,compatible } from './model.js';
import { mapCoordinate } from './variation.js';
export function plist(value){
  const item=v=>v===true?'<true/>':v===false?'<false/>':typeof v==='number'?`<${Number.isInteger(v)?'integer':'real'}>${v}</${Number.isInteger(v)?'integer':'real'}>`:typeof v==='string'?`<string>${escapeXML(v)}</string>`:Array.isArray(v)?'<array>'+v.map(item).join('')+'</array>':v&&typeof v==='object'?'<dict>'+Object.entries(v).filter(([,v])=>v!==undefined&&v!==null).map(([k,v])=>`<key>${escapeXML(k)}</key>${item(v)}`).join('')+'</dict>':'<string></string>';
  return '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0">'+item(value)+'</plist>';
}
export function readPlist(source){
  // Property-list DOCTYPE only names the public format; it is never fetched.
  const stripped=source.replace(/<!DOCTYPE\s+plist\s+PUBLIC\s+"[^"]*"\s+"[^"]*"\s*>/gi,'');
  const doc=parseXML(stripped),read=node=>{if(!node)return null;const children=[...node.children];switch(node.tagName){case'plist':return read(children[0]);case'dict':{const result={};for(let i=0;i<children.length;i+=2){if(children[i].tagName!=='key')throw new Error('Invalid property list dictionary');result[children[i].textContent]=read(children[i+1]);}return result;}case'array':return children.map(read);case'integer':case'real':return Number(node.textContent);case'true':return true;case'false':return false;case'data':return {base64:node.textContent.trim()};default:return node.textContent;}};return read(doc.documentElement);
}
export function glif(g){
  let body=`<advance width="${g.advance}"${g.advanceHeight!==undefined?` height="${g.advanceHeight}"`:""}/>`+g.unicodes.map(code=>`<unicode hex="${code.toString(16).toUpperCase().padStart(4,'0')}"/>`).join('');
  for(const guide of g.guidelines??[])body+=`<guideline x="${guide.x}" y="${guide.y}" angle="${guide.angle??0}" name="${escapeXML(guide.name??'')}"/>`;
  for(const anchor of g.anchors??[])body+=`<anchor x="${anchor.x}" y="${anchor.y}" name="${escapeXML(anchor.name)}"/>`;
  body+='<outline>';
  for(const contour of g.contours)body+='<contour>'+contour.map(p=>`<point x="${p.x}" y="${p.y}"${p.type==='offcurve'?'':` type="${p.type}"`}${p.smooth?' smooth="yes"':''}/>`).join('')+'</contour>';
  for(const component of g.components??[]){const m=component.matrix??[1,0,0,1,0,0];body+=`<component base="${escapeXML(component.base)}" xScale="${m[0]}" xyScale="${m[1]}" yxScale="${m[2]}" yScale="${m[3]}" xOffset="${m[4]}" yOffset="${m[5]}"/>`;}
  if(g.verticalOrigin!==undefined)body+='</outline><lib>'+plist({'public.verticalOrigin':g.verticalOrigin}).replace(/^.*?<plist[^>]*>|<\/plist>$/g,'')+'</lib>';else body+='</outline>';
  return `<?xml version="1.0" encoding="UTF-8"?><glyph name="${escapeXML(g.name)}" format="2">${body}</glyph>`;
}
export function readGlif(source,name){
  const root=parseXML(source).documentElement;if(root.tagName!=='glyph')throw new Error('Invalid GLIF');const g=glyph(root.getAttribute('name')||name,[...root.querySelectorAll(':scope > unicode')].map(n=>parseInt(n.getAttribute('hex'),16)),[],Number(root.querySelector('advance')?.getAttribute('width')??600));
  const height=root.querySelector('advance')?.getAttribute('height');if(height!==null&&height!==undefined)g.advanceHeight=Number(height);const lib=root.querySelector(':scope > lib > dict');if(lib){const values=readPlist('<plist>'+new XMLSerializer().serializeToString(lib)+'</plist>');if(values['public.verticalOrigin']!==undefined)g.verticalOrigin=Number(values['public.verticalOrigin']);}
  for(const contour of root.querySelectorAll('outline > contour'))g.contours.push([...contour.children].filter(n=>n.tagName==='point').map(n=>point(Number(n.getAttribute('x')),Number(n.getAttribute('y')),n.getAttribute('type')||'offcurve',n.getAttribute('smooth')==='yes')));
  for(const node of root.querySelectorAll('outline > component'))g.components.push({id:uid(),base:node.getAttribute('base'),matrix:['xScale','xyScale','yxScale','yScale','xOffset','yOffset'].map((key,i)=>Number(node.getAttribute(key)??(i===0||i===3?1:0)))});
  for(const node of root.querySelectorAll(':scope > anchor'))g.anchors.push({name:node.getAttribute('name'),x:Number(node.getAttribute('x')),y:Number(node.getAttribute('y'))});
  for(const node of root.querySelectorAll(':scope > guideline'))g.guidelines.push({id:uid(),name:node.getAttribute('name'),x:Number(node.getAttribute('x')),y:Number(node.getAttribute('y')),angle:Number(node.getAttribute('angle')??0)});
  return g;
}
export function makeUFOFiles(font,glyphs=font.glyphs,styleName=font.info.styleName,source=font){
  const files={},contents={},info={...clone(font.info),...clone(source.info??{}),styleName};if(font.guidelines?.length)info.guidelines=clone(font.guidelines).map(({id,...guide})=>guide);delete info.name;delete info.original;
  if(info.license){info.openTypeNameLicense=info.license;delete info.license;}
  files['metainfo.plist']=strToU8(plist({creator:'com.floeagent.font',formatVersion:3}));
  files['fontinfo.plist']=strToU8(plist(info));files['layercontents.plist']=strToU8(plist([['public.default','glyphs']]));
  for(let i=0;i<glyphs.length;i++){const g=glyphs[i],filename=`g${String(i).padStart(6,'0')}.glif`;contents[g.name]=filename;files['glyphs/'+filename]=strToU8(glif(g));}
  files['glyphs/contents.plist']=strToU8(plist(contents));files['groups.plist']=strToU8(plist(font.groups??{}));files['kerning.plist']=strToU8(plist(source.kerning??font.kerning??{}));
  files['features.fea']=strToU8(font.features??'');files['lib.plist']=strToU8(plist({'public.glyphOrder':glyphs.map(g=>g.name),'public.openTypeCategories':Object.fromEntries(glyphs.filter(g=>g.anchors?.some(a=>a.name.startsWith('_'))).map(g=>[g.name,'mark']))}));return files;
}
export function makeDesignspaceArchive(font){
  const issues=compatible(font);if(issues.length)throw new Error(t('母版轮廓不兼容，请先检查并修正。','Master outlines are incompatible. Check and correct them first.'));
  if(!font.glyphs.length)throw new Error('Font requires glyphs');
  const files={},axes=font.axes??[],masters=[{name:font.info.styleName||'Regular',location:Object.fromEntries(axes.map(a=>[a.tag,a.default])),glyphs:font.glyphs,kerning:font.kerning,info:font.info},...(axes.length?font.masters:[])];
  let xml='<?xml version="1.0" encoding="UTF-8"?><designspace format="4.1"><axes>';
  for(const axis of axes)xml+=`<axis tag="${escapeXML(axis.tag)}" name="${escapeXML(axis.name||axis.tag)}" minimum="${axis.min}" maximum="${axis.max}" default="${axis.default}">${(axis.mapping??[]).map(([input,output])=>`<map input="${input}" output="${output}"/>`).join('')}</axis>`;
  xml+='</axes><sources>';
  masters.forEach((master,index)=>{const filename=`master${index}.ufo`;for(const [path,data]of Object.entries(makeUFOFiles(font,master.glyphs,master.name,master)))files[filename+'/'+path]=data;
    xml+=`<source filename="${filename}" name="master${index}" familyname="${escapeXML(font.info.familyName)}" stylename="${escapeXML(master.name)}">${index===0?'<info copy="1"/><lib copy="1"/><features copy="1"/>':''}<location>${axes.map(axis=>`<dimension name="${escapeXML(axis.name||axis.tag)}" xvalue="${mapCoordinate(axis,master.location[axis.tag]??axis.default)}"/>`).join('')}</location></source>`;
  });xml+='</sources>';if(font.instances?.length)xml+='<instances>';
  for(const instance of font.instances??[])xml+=`<instance familyname="${escapeXML(font.info.familyName)}" stylename="${escapeXML(instance.name)}"><location>${axes.map(axis=>`<dimension name="${escapeXML(axis.name||axis.tag)}" xvalue="${mapCoordinate(axis,instance.location[axis.tag]??axis.default)}"/>`).join('')}</location></instance>`;
  if(font.instances?.length)xml+='</instances>';xml+='</designspace>';files['font.designspace']=strToU8(xml);return zipSync(files,{level:6});
}
export function readUFOFiles(files,prefix=''){
  const read=name=>required(files[prefix+name],'Missing UFO file '+name),font=createFont();font.info={...font.info,...readPlist(strFromU8(read('fontinfo.plist')))};font.title=font.info.familyName;font.info.license=font.info.openTypeNameLicense??font.info.license??'';font.guidelines=clone(font.info.guidelines??[]).map(g=>({id:uid(),...g}));
  const layers=files[prefix+'layercontents.plist']?readPlist(strFromU8(files[prefix+'layercontents.plist'])):[['public.default','glyphs']],directory=(layers.find(layer=>layer[0]==='public.default')??layers[0])[1];
  if(directory.includes('..')||directory.includes('\\')||directory.startsWith('/'))throw new Error('Invalid UFO layer path');
  const contents=readPlist(strFromU8(read(directory+'/contents.plist')));font.glyphs=[];
  for(const [name,filename]of Object.entries(contents)){if(filename.includes('..')||filename.includes('\\')||filename.startsWith('/'))throw new Error('Invalid GLIF path');font.glyphs.push(readGlif(strFromU8(read(directory+'/'+filename)),name));}
  if(files[prefix+'lib.plist']){const lib=readPlist(strFromU8(files[prefix+'lib.plist'])),order=lib['public.glyphOrder'];if(order)font.glyphs.sort((a,b)=>{const ai=order.indexOf(a.name),bi=order.indexOf(b.name);return (ai<0?1e9:ai)-(bi<0?1e9:bi);});}
  font.groups=files[prefix+'groups.plist']?readPlist(strFromU8(files[prefix+'groups.plist'])):{};font.kerning=files[prefix+'kerning.plist']?readPlist(strFromU8(files[prefix+'kerning.plist'])):{};font.features=files[prefix+'features.fea']?strFromU8(files[prefix+'features.fea']):'';normalizeFont(font);return font;
}
export function readFontArchive(bytes){
  const files=unzipSync(bytes),paths=Object.keys(files);for(const path of paths)if(path.startsWith('/')||path.split('/').includes('..')||path.includes('\\'))throw new Error('Unsafe font archive path');
  const designspace=paths.find(path=>path.endsWith('.designspace'));
  if(!designspace){const metainfo=paths.find(path=>path.endsWith('metainfo.plist'));if(!metainfo)throw new Error('No UFO font in archive');return readUFOFiles(files,metainfo.slice(0,-'metainfo.plist'.length));}
  const root=parseXML(strFromU8(files[designspace])).documentElement,base=designspace.includes('/')?designspace.slice(0,designspace.lastIndexOf('/')+1):'',axes=[...root.querySelectorAll('axes > axis')].map(a=>({tag:a.getAttribute('tag'),name:a.getAttribute('name'),min:Number(a.getAttribute('minimum')),default:Number(a.getAttribute('default')),max:Number(a.getAttribute('maximum')),mapping:[...a.querySelectorAll('map')].map(m=>[Number(m.getAttribute('input')),Number(m.getAttribute('output'))])}));
  const sources=[...root.querySelectorAll('sources > source')].map(source=>{const name=source.getAttribute('filename');if(!name||name.includes('..')||name.startsWith('/'))throw new Error('Unsafe designspace source');const location={};for(const d of source.querySelectorAll('location > dimension')){const axis=axes.find(a=>a.name===d.getAttribute('name'));if(axis)location[axis.tag]=mapCoordinate(axis,Number(d.getAttribute('xvalue')),true);}return {name:source.getAttribute('stylename')??source.getAttribute('name')??'Master',location,font:readUFOFiles(files,base+name.replace(/\/$/,'')+'/')};});
  if(!sources.length)throw new Error('Designspace has no sources');const initial=sources.find(s=>axes.every(a=>(s.location[a.tag]??a.default)===a.default));if(!initial)throw new Error('Designspace must contain a source at the default location');const font=initial.font;font.axes=axes;font.masters=sources.filter(s=>s!==initial).map(s=>({id:uid(),name:s.name,location:s.location,glyphs:s.font.glyphs,kerning:s.font.kerning,info:s.font.info}));font.instances=[...root.querySelectorAll('instances > instance')].map(node=>{const location={};for(const d of node.querySelectorAll('location > dimension')){const axis=axes.find(a=>a.name===d.getAttribute('name'));if(axis)location[axis.tag]=mapCoordinate(axis,Number(d.getAttribute('xvalue')),true);}return {name:node.getAttribute('stylename')||'Instance',location};});normalizeFont(font);return font;
}
