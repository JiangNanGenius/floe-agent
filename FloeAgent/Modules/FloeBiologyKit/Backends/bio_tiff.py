# SPDX-License-Identifier: MPL-2.0
"""Bounded TIFF/OME series and pyramid tiles, without expanding a whole plane."""
import json
import math
from bio_common import source_file, bounded_integer
from bio_sequence_structure import output

def calibration(tif,index):
    if not tif.ome_metadata:return None
    import xml.etree.ElementTree as ET
    xml=tif.ome_metadata
    if '<!DOCTYPE' in xml.upper() or '<!ENTITY' in xml.upper():raise ValueError('Unsupported OME XML declarations')
    pixels=[e for e in ET.fromstring(xml).iter() if e.tag.split('}')[-1]=='Pixels']
    if index>=len(pixels):return None
    attrs=pixels[index].attrib
    if 'PhysicalSizeX' not in attrs or 'PhysicalSizeY' not in attrs:return None
    x,y=float(attrs['PhysicalSizeX']),float(attrs['PhysicalSizeY'])
    unit=attrs.get('PhysicalSizeXUnit','µm')
    if not math.isfinite(x) or not math.isfinite(y) or x<=0 or y<=0 or attrs.get('PhysicalSizeYUnit',unit)!=unit:
        raise ValueError('Invalid or inconsistent OME physical pixel sizes')
    return x,y,unit

def tile(asset,options,series_only=False):
    import numpy as np
    import tifffile
    import zarr
    with source_file(asset) as source,tifffile.TiffFile(source) as tif:
        if len(tif.series)>1024:raise ValueError('TIFF series budget exceeded')
        if series_only:
            info=[]
            for i,s in enumerate(tif.series):
                info.append(dict(index=i,name=s.name,axes=s.axes,shape=list(s.shape),dtype=str(s.dtype),calibration=calibration(tif,i),levels=[dict(index=j,shape=list(v.shape),axes=v.axes) for j,v in enumerate(s.levels)]))
            return output('Microscopy series and pyramid levels',{'series':len(info)},text=json.dumps(info),details={'reader':'tifffile; no image plane expanded'})
        si=bounded_integer(options.get('series',0),0,len(tif.series)-1,'series')
        series=tif.series[si]
        li=bounded_integer(options.get('level',0),0,len(series.levels)-1,'pyramid level')
        level=series.levels[li];axes=level.axes.replace('S','C')
        if len(set(axes))!=len(axes) or any(a not in 'TZCYX' for a in axes) or 'Y' not in axes or 'X' not in axes:
            raise ValueError('Unsupported TIFF axis semantics; a canonical TZCYX dataset is required')
        shape=dict(zip(axes,level.shape));dtype=np.dtype(level.dtype)
        if dtype.kind not in 'buif' or dtype.itemsize>8:raise ValueError('Unsupported microscopy sample type')
        w,h=shape['X'],shape['Y']
        region=options.get('region',[0,0,min(512,w),min(512,h)])
        if not isinstance(region,list) or len(region)!=4:raise ValueError('Region is [x,y,width,height] in the selected level')
        x,y,rw,rh=[bounded_integer(v,0,100000000,'region coordinate') for v in region]
        if not rw or not rh or x+rw>w or y+rh>h or rw*rh>1048576:raise ValueError('Tile must be inside the image and contain at most 1,048,576 pixels')
        selection=[]
        for a in axes:
            if a=='X':selection.append(slice(x,x+rw))
            elif a=='Y':selection.append(slice(y,y+rh))
            else:selection.append(bounded_integer(options.get({'C':'channel','T':'frame','Z':'slice'}[a],0),0,shape[a]-1,a+' index'))
        store=series.aszarr(level=li)
        try:
            array=zarr.open(store,mode='r')
            if math.prod(array.chunks)*dtype.itemsize>64*1024*1024:raise ValueError('A compressed image chunk exceeds the 64 MiB decode budget')
            values=np.asarray(array[tuple(selection)])
        finally:store.close()
        if axes.index('X')<axes.index('Y'):values=values.T
        if values.shape!=(rh,rw) or not np.isfinite(values).all():raise ValueError('Invalid tile dimensions or samples')
        if dtype.kind in 'ui' and (values.max()>2**53 or values.min()<-(2**53)):raise ValueError('Sample values cannot be represented exactly as Double')
        base_axes=series.axes.replace('S','C');base_shape=dict(zip(base_axes,series.shape))
        scale_x,scale_y=base_shape['X']/w,base_shape['Y']/h
        cal=calibration(tif,si)
        native=dict(width=rw,height=rh,channels=1,slices=1,frames=1,bitDepth=dtype.itemsize*8,samples=values.astype(float).reshape(-1).tolist(),calibrationUnit=cal[2] if cal else 'µm')
        if dtype.kind=='b':native['bitDepth']=8
        if cal:native.update(pixelSizeX=cal[0]*scale_x,pixelSizeY=cal[1]*scale_y)
        details=dict(series=si,level=li,axes=axes,region=json.dumps(region),levelWidth=w,levelHeight=h,baseWidth=base_shape['X'],baseHeight=base_shape['Y'],baseScaleX=scale_x,baseScaleY=scale_y,globalOriginX=x*scale_x,globalOriginY=y*scale_y,coordinateConvention='centroids in level-0 pixel coordinates; physical values use OME units',reader='tifffile+Zarr bounded region')
        return native,details,cal

def microscopy_region(asset,operation,options):
    if operation=='micro.series':return tile(asset,options,True)
    native,details,cal=tile(asset,options)
    if operation=='micro.tile':
        return output('Microscopy region',{'width':native['width'],'height':native['height'],'minimum':min(native['samples']),'maximum':max(native['samples'])},text=json.dumps(native),details=details)
    # The quantitative engine consumes only the bounded tile. Global level-0
    # coordinates and physical calibration are restored in the returned table.
    from bio_image_omics import microscopy
    bounded=dict(asset,payload={'microscopyImage':{'_0':native}})
    local={k:v for k,v in options.items() if k not in {'series','level','region','channel','slice','frame'}}
    result=microscopy(bounded,operation,local)
    for row in result['rows']:
        row[3]=(row[3]+json.loads(details['region'])[0])*float(details['baseScaleX'])
        row[4]=(row[4]+json.loads(details['region'])[1])*float(details['baseScaleY'])
        if cal:row.extend([row[3]*cal[0],row[4]*cal[1]])
    if cal:result['columns'].extend(['centroidX_physical','centroidY_physical'])
    result['details'].update({str(k):str(v) for k,v in details.items()})
    return result
