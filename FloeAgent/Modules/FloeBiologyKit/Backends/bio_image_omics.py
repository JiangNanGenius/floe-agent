# SPDX-License-Identifier: MPL-2.0
"""Quantitative microscopy and expression-matrix methods using mature engines."""
import io
import json
import math
import base64
from bio_common import bounded_integer, finite_number
from bio_sequence_structure import output, original, native_payload

MAX_ELEMENTS=4000000
MAX_DENSE_ELEMENTS=2000000

def microscopy(asset,operation,options):
    import numpy as np
    import tifffile
    import skimage
    from skimage import filters, measure, morphology, segmentation, color
    calibration=None
    bit_depth=64
    if "microscopyImage" in asset["payload"]:
        p=native_payload(asset)
        shape=(p.get("frames",1),p.get("slices",1),p.get("channels",1),p["height"],p["width"])
        if math.prod(shape)>MAX_ELEMENTS or len(p["samples"])!=math.prod(shape):raise ValueError("Image axis/sample budget mismatch")
        cube=np.asarray(p["samples"],dtype=float).reshape(shape)
        bit_depth=p.get("bitDepth",64)
        if p.get("pixelSizeX") is not None and p.get("pixelSizeY") is not None:
            calibration=(finite_number(p["pixelSizeX"],1e-12,1e9,"pixel size"),finite_number(p["pixelSizeY"],1e-12,1e9,"pixel size"),p.get("calibrationUnit","µm"))
    else:
        raw=original(asset)
        with tifffile.TiffFile(io.BytesIO(raw)) as tif:
            series=tif.series[0]
            if math.prod(series.shape)>MAX_ELEMENTS or np.dtype(series.dtype).itemsize>8:raise ValueError("Expanded image exceeds its native worker budget")
            axes=series.axes.replace("S","C")
            if len(set(axes))!=len(axes) or any(a not in "TZCYX" for a in axes):raise ValueError("Unsupported TIFF axes; provide a canonical TZCYX dataset")
            pixels=series.asarray()
            if pixels.dtype.kind not in "buif" or (pixels.dtype.kind in "ui" and (pixels.max()>2**53 or (pixels.dtype.kind=="i" and pixels.min()<-(2**53)))):
                raise ValueError("This sample type cannot be converted to native Double values without losing precision")
            bit_depth=pixels.dtype.itemsize*8
            for axis in "TZCYX":
                if axis not in axes:pixels=np.expand_dims(pixels,0);axes=axis+axes
            cube=pixels.transpose([axes.index(a) for a in "TZCYX"]).astype(float)
            if tif.ome_metadata:
                import xml.etree.ElementTree as ET
                xml=tif.ome_metadata
                if "<!DOCTYPE" in xml.upper() or "<!ENTITY" in xml.upper():raise ValueError("Unsupported XML declarations in OME metadata")
                for element in ET.fromstring(xml).iter():
                    if element.tag.endswith("Pixels") and "PhysicalSizeX" in element.attrib and "PhysicalSizeY" in element.attrib:
                        calibration=(float(element.attrib["PhysicalSizeX"]),float(element.attrib["PhysicalSizeY"]),element.attrib.get("PhysicalSizeXUnit","µm"))
                        if any(not math.isfinite(v) or v<=0 for v in calibration[:2]):raise ValueError("Invalid OME calibration")
                        if element.attrib.get("PhysicalSizeYUnit",calibration[2])!=calibration[2]:raise ValueError("OME pixel axes use different units")
                        break
    if not np.isfinite(cube).all():raise ValueError("Non-finite image samples")
    t=bounded_integer(options.get("frame",0),0,cube.shape[0]-1,"frame")
    z=bounded_integer(options.get("slice",0),0,cube.shape[1]-1,"slice")
    c=bounded_integer(options.get("channel",0),0,cube.shape[2]-1,"channel")
    image=cube[t,z,c]
    details=dict(engine="scikit-image "+skimage.__version__+"; tifffile "+tifffile.__version__,axes="TZCYX",frame=t,slice=z,channel=c)
    metrics=dict(width=image.shape[1],height=image.shape[0],minimum=float(image.min()),maximum=float(image.max()),mean=float(image.mean()),frames=cube.shape[0],slices=cube.shape[1],channels=cube.shape[2])
    if operation=="micro.import":
        dataset=dict(width=cube.shape[4],height=cube.shape[3],channels=cube.shape[2],slices=cube.shape[1],frames=cube.shape[0],bitDepth=bit_depth,samples=cube.reshape(-1).tolist(),calibrationUnit=calibration[2] if calibration else "µm")
        if calibration:dataset.update(pixelSizeX=calibration[0],pixelSizeY=calibration[1])
        return output("Image axes and calibration",metrics,text=json.dumps(dataset),details={**details,"pixelCalibration":calibration,"derivedFormat":"image.json"})
    threshold=options.get("threshold")
    threshold=float(filters.threshold_otsu(image)) if threshold is None else finite_number(threshold,-1e15,1e15,"threshold")
    mask=image>threshold
    radius=bounded_integer(options.get("radius",0),0,16,"morphology radius")
    if radius:
        mask=morphology.binary_opening(mask,morphology.disk(radius))
    labels=measure.label(mask,connectivity=bounded_integer(options.get("connectivity",2),1,2,"connectivity"))
    minimum=bounded_integer(options.get("minArea",1),1,image.size,"minimum object area")
    if minimum>1:
        labels=morphology.remove_small_objects(labels,min_size=minimum)
        labels=measure.label(labels>0,connectivity=2)
    regions=measure.regionprops(labels,intensity_image=image)
    if len(regions)>100000:raise ValueError("Region table budget exceeded")
    scale=calibration[0]*calibration[1] if calibration else 1
    details["areaUnit"]=(calibration[2]+"²") if calibration else "px²"
    metrics.update(objects=len(regions),threshold=float(threshold))
    rows=[[int(r.area),float(r.area*scale),float(r.intensity_mean),float(r.centroid[1]),float(r.centroid[0])] for r in regions]
    text=""
    if operation=="micro.overlay":
        from PIL import Image
        span=max(float(image.max()-image.min()),1e-12)
        rgb=color.label2rgb(labels,image=(image-image.min())/span,bg_label=0,alpha=0.35)
        stream=io.BytesIO();Image.fromarray(np.uint8(np.clip(rgb*255,0,255))).save(stream,format="PNG")
        text=base64.b64encode(stream.getvalue()).decode();details["textEncoding"]="base64 PNG"
    return output("Microscopy object measurements",metrics,["pixels","area","meanIntensity","centroidX","centroidY"],rows,["Object "+str(r.label) for r in regions],text,details,labels.reshape(-1).tolist())

def read_matrix(asset):
    import numpy as np
    import scipy.sparse as sparse
    import anndata as ad
    from scipy.io import mmread
    if "expressionMatrix" in asset["payload"]:
        p=native_payload(asset);g=p["geneIDs"];c=p["cellIDs"]
        if len(g)*len(c)>MAX_DENSE_ELEMENTS or len(p["values"])!=len(g)*len(c):raise ValueError("Dense matrix budget/dimensions exceeded")
        x=np.asarray(p["values"],dtype=float).reshape(len(g),len(c)).T
    elif asset["originalFormat"] in {"mtx"}:
        raw=original(asset);lines=raw.decode().splitlines()
        if not lines or not lines[0].lower().startswith("%%matrixmarket matrix coordinate"):raise ValueError("A sparse coordinate Matrix Market file is required")
        header=next((l for l in lines[1:] if l.strip() and not l.startswith("%")),None)
        dims=[int(v) for v in header.split()] if header else []
        if len(dims)!=3 or any(v<=0 for v in dims[:2]) or max(dims[:2])>1000000 or not 0<=dims[2]<=2000000:raise ValueError("Sparse matrix dimensions/nnz budget exceeded")
        x=mmread(io.BytesIO(raw)).tocsr().T
        g=["Gene_"+str(i+1) for i in range(dims[0])];c=["Cell_"+str(i+1) for i in range(dims[1])]
    elif asset["originalFormat"]=="h5ad":
        import h5py
        with h5py.File(io.BytesIO(original(asset)),"r") as file:
            total=[0];visited=set()
            def check(group,depth=0):
                if depth>32:raise ValueError("HDF5 nesting limit exceeded")
                for key in group.keys():
                    link=group.get(key,getlink=True)
                    if isinstance(link,(h5py.ExternalLink,h5py.SoftLink)):raise ValueError("HDF5 links are not accepted")
                    node=group[key]
                    token=hash(node.id)
                    if token in visited:continue
                    visited.add(token)
                    if isinstance(node,h5py.Dataset):
                        total[0]+=node.size*max(node.dtype.itemsize,8)
                        if total[0]>128*1024*1024 or node.size>2000000:raise ValueError("Expanded HDF5 dataset budget exceeded")
                    else:check(node,depth+1)
            check(file)
            data=ad.io.read_elem(file)
        x=data.X;g=list(map(str,data.var_names));c=list(map(str,data.obs_names))
    else:raise ValueError("A typed count matrix, sparse MTX or H5AD input is required")
    if sparse.issparse(x):
        if x.nnz>2000000 or not np.isfinite(x.data).all() or (x.data<0).any():raise ValueError("Invalid or oversized sparse count matrix")
    elif x.size>MAX_DENSE_ELEMENTS or not np.isfinite(x).all() or (x<0).any():raise ValueError("Invalid or oversized count matrix")
    if len(set(g))!=len(g) or len(set(c))!=len(c) or not g or not c:raise ValueError("Gene/cell identifiers must be nonempty and unique")
    return ad.AnnData(x,obs=__import__("pandas").DataFrame(index=c),var=__import__("pandas").DataFrame(index=g))

def omics(asset,operation,options):
    import numpy as np
    import scipy
    import scanpy as sc
    import scipy.sparse as sparse
    from scipy.stats import ttest_ind
    data=read_matrix(asset)
    from importlib.metadata import version
    details=dict(engine="Scanpy "+version("scanpy")+"; SciPy "+scipy.__version__,orientation="cells × genes internally; gene/cell identifiers retained")
    if asset["originalFormat"]=="mtx":details["identifiers"]="Matrix Market has no gene/cell names; explicit Gene_n and Cell_n placeholders were generated."
    metrics=dict(cells=data.n_obs,genes=data.n_vars)
    if operation=="omics.import":
        if data.n_obs*data.n_vars>MAX_DENSE_ELEMENTS:raise ValueError("Native matrix conversion exceeds its dense budget; analyze this sparse dataset in the configured environment")
        x=data.X.toarray() if sparse.issparse(data.X) else data.X
        payload=dict(geneIDs=list(data.var_names),cellIDs=list(data.obs_names),values=x.T.reshape(-1).tolist())
        return output("Expression dataset",metrics,text=json.dumps(payload),details={**details,"derivedFormat":"matrix.json"})
    if operation=="omics.export":
        fmt=options.get("format","csv")
        if fmt not in {"csv","tsv"}:raise ValueError("Choose CSV or TSV export")
        if data.n_obs*data.n_vars>MAX_DENSE_ELEMENTS:raise ValueError("Dense export budget exceeded")
        stream=io.StringIO();data.to_df().T.to_csv(stream,sep="," if fmt=="csv" else "\t")
        return output("Expression matrix export",metrics,text=stream.getvalue(),details={**details,"format":fmt})
    if operation=="omics.qc":
        sc.pp.calculate_qc_metrics(data,percent_top=None,log1p=False,inplace=True)
        return output("Per-cell quality control",metrics,["totalCounts","detectedGenes"],data.obs[["total_counts","n_genes_by_counts"]].to_numpy().tolist(),list(data.obs_names),details=details)
    if operation=="omics.diffexp":
        a=options.get("groupA",[]);b=options.get("groupB",[])
        if len(set(a))<2 or len(set(b))<2 or set(a)&set(b) or not (set(a)|set(b))<=set(data.obs_names):raise ValueError("Select disjoint groups with at least two cells each")
        if data.n_obs*data.n_vars>MAX_DENSE_ELEMENTS:raise ValueError("Dense differential-analysis budget exceeded")
        x=data.X.toarray() if sparse.issparse(data.X) else data.X
        aa=x[data.obs_names.get_indexer(a)];bb=x[data.obs_names.get_indexer(b)]
        stat,p=ttest_ind(aa,bb,axis=0,equal_var=False)
        valid=np.isfinite(p);q=np.full(p.shape,np.nan)
        order=np.argsort(p[valid]);ordered=p[valid][order];adjusted=np.minimum.accumulate((ordered*len(ordered)/(np.arange(len(ordered))+1))[::-1])[::-1]
        remap=np.empty_like(adjusted);remap[order]=np.minimum(adjusted,1);q[valid]=remap
        rows=[];names=[];undefined=[]
        for i,gene in enumerate(data.var_names):
            if valid[i]:
                rows.append([float(aa[:,i].mean()),float(bb[:,i].mean()),float(np.log2((aa[:,i].mean()+1e-9)/(bb[:,i].mean()+1e-9))),float(p[i]),float(q[i])]);names.append(str(gene))
            else:undefined.append(dict(gene=str(gene),pValue=None,qValue=None,reason="Welch test is undefined for this variance/sample design"))
        details.update(test="Welch t-test, independent cells; no covariates or replicate model",multipleTesting="Benjamini-Hochberg",undefinedTests=len(undefined))
        return output("Two-group expression comparison",metrics,["meanA","meanB","log2FoldChange","pValue","qValue"],rows,names,text=json.dumps(undefined),details=details)
    target=finite_number(options.get("targetSum",10000),1,1e9,"normalization target")
    sc.pp.normalize_total(data,target_sum=target)
    if operation=="omics.normalize":
        if data.n_obs*data.n_vars>MAX_DENSE_ELEMENTS:raise ValueError("Dense normalized output budget exceeded")
        x=data.X.toarray() if sparse.issparse(data.X) else data.X
        return output("Library-size normalized matrix",metrics,list(data.obs_names),x.T.tolist(),list(data.var_names),details={**details,"targetSum":target,"inputCountsRetained":True})
    sc.pp.log1p(data)
    if min(data.n_obs,data.n_vars)<3:raise ValueError("At least three cells and genes are required for PCA")
    n=bounded_integer(options.get("nComps",min(20,data.n_obs-1,data.n_vars-1)),1,min(100,data.n_obs-1,data.n_vars-1),"PCA components")
    sc.pp.pca(data,n_comps=n,zero_center=True,svd_solver="arpack",random_state=0)
    if operation=="omics.pca":
        coordinates=data.obsm["X_pca"]
        return output("Principal-component projection",metrics,["PC"+str(i+1) for i in range(n)],coordinates.tolist(),list(data.obs_names),text=json.dumps({"explainedVarianceRatio":data.uns["pca"]["variance_ratio"].tolist()}),details=details)
    if data.n_obs>10000:raise ValueError("Embedding/clustering exceeds this environment's cell budget")
    neighbors=bounded_integer(options.get("nNeighbors",min(10,data.n_obs-1)),2,max(2,data.n_obs-1),"neighbor count")
    sc.pp.neighbors(data,n_neighbors=neighbors,n_pcs=n,random_state=0)
    if operation=="omics.cluster":
        sc.tl.leiden(data,resolution=finite_number(options.get("resolution",1),0.01,10,"resolution"),random_state=0,flavor="igraph",n_iterations=2)
        labels=[int(x) for x in data.obs["leiden"]]
        return output("Leiden cell clusters",{**metrics,"clusters":len(set(labels))},["cluster"],[[v] for v in labels],list(data.obs_names),details={**details,"method":"Leiden; log-normalized PCA neighbor graph"})
    sc.tl.umap(data,random_state=0)
    return output("UMAP cell embedding",metrics,["UMAP1","UMAP2"],data.obsm["X_umap"].astype(float).tolist(),list(data.obs_names),details={**details,"seed":0,"inputCountsRetained":True})
