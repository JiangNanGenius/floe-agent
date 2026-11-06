#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Independent G-code state readback and preview; no Kiri reader/encoder imports."""
from pathlib import Path
import json, math, re, sys, hashlib
from PIL import Image, ImageDraw, ImageFont
base=Path(sys.argv[1]);out=Path(sys.argv[2]);out.mkdir(parents=True,exist_ok=True)
reports={};font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',16)
for file in sorted(base.glob('*.gcode')):
 pos=[0.,0.,0.]; e=0.; absolute=True; abs_e=True;segments=[];temps=[]
 for raw in file.read_text().splitlines():
  line=raw.split(';')[0].strip()
  if not line:continue
  if '{' in line or 'NaN' in line or 'Infinity' in line:raise ValueError('unresolved instruction '+line)
  tokens=line.split();cmd=tokens[0];d={m[0]:float(m[1]) for m in re.findall(r'([XYZEFST])(-?\d+(?:\.\d+)?)',line)}
  if cmd=='G90':absolute=True
  if cmd=='G91':absolute=False
  if cmd=='M82':abs_e=True
  if cmd=='M83':abs_e=False
  if cmd in ('M104','M109','M140','M190'):temps.append([cmd,d.get('S')])
  if cmd=='G92':
   for i,k in enumerate('XYZ'):
    if k in d:pos[i]=d[k]
   if 'E' in d:e=d['E']
   continue
  if cmd not in ('G0','G1'):continue
  start=pos[:]
  for i,k in enumerate('XYZ'):
   if k in d:pos[i]=d[k] if absolute else pos[i]+d[k]
  ne=(d['E'] if abs_e else e+d['E']) if 'E' in d else e;de=ne-e;e=ne
  assert all(math.isfinite(v) for v in pos)
  assert -0.01<=pos[0]<=220.01 and -0.01<=pos[1]<=220.01 and -0.01<=pos[2]<=250.01,(file,line,pos)
  if de>1e-7 and start!=pos:segments.append((start,pos[:],de))
 assert segments
 layers=sorted(set(round(s[1][2],4) for s in segments));assert all(abs(z-(i+1)*.2)<.001 for i,z in enumerate(layers)),layers
 pts=[p for a,b,e in segments for p in [a,b]];low=[min(p[i] for p in pts) for i in range(3)];high=[max(p[i] for p in pts) for i in range(3)]
 assert ['M109',200.0] in temps and ['M190',60.0] in temps,temps
 reports[file.name]={'sha256':hashlib.sha256(file.read_bytes()).hexdigest(),'layers':len(layers),'extrusionMoves':len(segments),'filamentMM':sum(s[2] for s in segments),'extrusionBoundsMM':{'minimum':low,'maximum':high},'heaters':temps}
 im=Image.new('RGB',(1260,510),'#f5f6f8');draw=ImageDraw.Draw(im)
 draw.text((20,15),file.name+' / actual extrusion paths',fill='#152139',font=font)
 for column,layer in enumerate([layers[0],layers[len(layers)//2],layers[-1]]):
  chosen=[s for s in segments if round(s[1][2],4)==layer]; pad=20;x0=20+column*415;y0=65;w=395;h=395
  draw.rectangle((x0,y0,x0+w,y0+h),fill='white',outline='#b8c0cc')
  span=max(high[0]-low[0],high[1]-low[1])+4;scale=(w-2*pad)/span
  def screen(p):return(x0+pad+(p[0]-low[0]+2)*scale,y0+h-pad-(p[1]-low[1]+2)*scale)
  for a,b,e in chosen:draw.line([screen(a),screen(b)],fill='#186fa3',width=1)
  draw.text((x0,y0+h+10),f'Z {layer:.2f} mm',fill='#152139',font=font)
 im.save(out/(file.stem+'.png'))
readback=Path(sys.argv[3]);d=json.loads((readback/'readback.json').read_text())
assert d['size']['Layers']==200 and d['size']['X']==960 and d['size']['Y']==544
assert d['exposure']['LightOnTime']==2.5 and d['bottom']['Count']==5 and d['bottom']['LightOnTime']==25
assert abs(d['computedVolumeMM3']-8000)/8000<.01
for layer in d['layers']:
 assert layer['litPixels']==25440 and layer['pixelBounds']==[480,113,639,271],layer
 assert layer['exposure']['LightOnTime']==(25 if layer['index']<5 else 2.5)
 assert abs(layer['z']-(layer['index']+1)*.1)<.0001
sheet=Image.new('RGB',(1260,365),'#f5f6f8');draw=ImageDraw.Draw(sheet);draw.text((20,15),'CTB v3 / independently decoded first, middle and final layer',fill='#152139',font=font)
for col,index in enumerate([0,100,199]):
 im=Image.open(readback/f'layer-{index:03d}.png').convert('RGB');im.thumbnail((395,280));sheet.paste(im,(20+col*415,55));draw.text((20+col*415,305),f'Layer {index+1} / {200} / Z {(index+1)*.1:.1f} mm',fill='#152139',font=font)
sheet.save(out/'ctb-layers.png')
reports['ctb']={'independentDecoder':d['decoder'],'layers':200,'rasterBoundingPixels':[160,159],'volumeMM3':d['computedVolumeMM3'],'rasterTolerance':'one pixel on a 0.125 mm grid','unexpectedLitPixels':0,'exposureAndMotionVerified':True}
(out/'validation.json').write_text(json.dumps(reports,indent=2)+'\n');print(json.dumps(reports,indent=2))
