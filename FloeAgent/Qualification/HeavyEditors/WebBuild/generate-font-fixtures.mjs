// SPDX-License-Identifier: MPL-2.0
import fs from 'node:fs';
import path from 'node:path';
import { createFont,glyph,point } from '../../../Modules/FloeFontKit/Web/model.js';
import { makeDesignspaceArchive } from '../../../Modules/FloeFontKit/Web/ufo.js';
import { unzipSync,zipSync,strToU8 } from 'fflate';
const root=process.argv[2];if(!root)throw new Error('Explicit fixture directory required');fs.mkdirSync(root,{recursive:true});
const font=createFont();font.title=font.info.familyName='Floe Fixture';font.glyphs=[];
for(const [name,code,advance]of [['.notdef',null,500],['A',65,600],['V',86,600],['f',102,350],['i',105,250],['fi',64257,500],['space',32,300]])font.glyphs.push(glyph(name,code===null?[]:[code],name==='space'?[]:[[point(50,0),point(50,700),point(advance-50,700),point(advance-50,0)]],advance));
font.features='languagesystem DFLT dflt;\nlanguagesystem latn dflt;\nfeature liga { sub f i by fi; } liga;\n';font.kerning={A:{V:-80}};
font.axes=[{tag:'wght',name:'Weight',min:400,default:400,max:700}];font.masters=[{id:'bold',name:'Bold',location:{wght:700},glyphs:structuredClone(font.glyphs)}];
for(const g of font.masters[0].glyphs){g.advance+=100;for(const contour of g.contours)for(const p of contour)if(p.x>100)p.x+=100;}
font.instances=[{name:'Regular',location:{wght:400}},{name:'Bold',location:{wght:700}}];
const archive=makeDesignspaceArchive(font);fs.writeFileSync(path.join(root,'variable-ligature.zip'),archive);
const bad=unzipSync(archive);bad['master0.ufo/features.fea']=strToU8('feature liga { sub MissingGlyph by A; } liga;');bad['master1.ufo/features.fea']=bad['master0.ufo/features.fea'];fs.writeFileSync(path.join(root,'invalid-feature.zip'),zipSync(bad));
const include=unzipSync(archive);include['master0.ufo/features.fea']=strToU8('include(../../outside.fea);');fs.writeFileSync(path.join(root,'external-include.zip'),zipSync(include));
fs.writeFileSync(path.join(root,'README.md'),'# Font compiler fixtures\n\nOriginal synthetic outlines and source programs, authored for Floe under MPL-2.0. No system or third-party font is copied. Regenerate with the pinned WebBuild toolchain and generate-font-fixtures.mjs.\n');
console.log('Created synthetic variable, OpenType and rejection fixtures.');
