#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""One bounded scientific request, one JSON result. Host owns installation/jobs."""
import contextlib
import hashlib
import importlib
import io
import json
import sys
import uuid
from bio_common import strict_json, hex_digest, bounded_integer, WORKSPACE

MAX_BYTES=32*1024*1024
METHODS={
 "Bio":["seq.parse","seq.stats","seq.translate","seq.reverseComplement","seq.export","seq.align.global","seq.align.local","seq.phylogeny"],
 "gemmi":["struct.parse","struct.select","struct.geometry","struct.contacts","struct.rmsd"],
 "skimage":["micro.import","micro.segment","micro.overlay","micro.series","micro.tile"],
 "scanpy":["omics.import","omics.export","omics.qc","omics.normalize","omics.pca","omics.cluster","omics.embedding","omics.diffexp"],
 "scipy":["net.simulate","net.sweep"],
 "libsbml":["net.sbml.import","net.sbml.export"],
 "roadrunner":["net.sbml.simulate","net.sbml.sweep"]
}
def capabilities():
    import importlib.metadata as metadata
    engines={};methods=[];unavailable={}
    requirements={"Bio":["Bio"],"gemmi":["gemmi","numpy","scipy"],"skimage":["skimage","tifffile","zarr","numpy","PIL"],
                  "scanpy":["scanpy","anndata","scipy","numpy","igraph","leidenalg"],"scipy":["scipy","numpy"],"libsbml":["libsbml"],"roadrunner":["roadrunner","libsbml","numpy"]}
    for engine,names in requirements.items():
        try:
            modules=[importlib.import_module(n) for n in names]
            if engine=="scipy":
                from scipy.integrate import solve_ivp
                result=solve_ivp(lambda t,y:-y,(0,0.01),[1.0])
                if not result.success:raise RuntimeError("Solver probe failed")
            elif engine=="Bio":
                from Bio.Seq import Seq
                if str(Seq("ATG").translate())!="M":raise RuntimeError("Sequence probe failed")
            elif engine=="gemmi":
                if not modules[0].cif.read_string("data_probe\n_entry.id probe\n").sole_block():raise RuntimeError("CIF probe failed")
            elif engine=="skimage":
                import numpy as np
                from skimage.measure import label
                if int(label(np.array([[0,1],[0,0]])).max())!=1:raise RuntimeError("Image probe failed")
            elif engine=='roadrunner':
                import libsbml
                doc=libsbml.SBMLDocument(3,2);m=doc.createModel();m.setId('probe')
                c=m.createCompartment();c.setId('cell');c.setSize(1);c.setConstant(True);c.setSpatialDimensions(3)
                s=m.createSpecies();s.setId('S');s.setCompartment('cell');s.setInitialAmount(1);s.setHasOnlySubstanceUnits(True);s.setBoundaryCondition(False);s.setConstant(False)
                rr=modules[0].RoadRunner(libsbml.writeSBMLToString(doc));probe=rr.simulate(0,0.01,2,selections=['time','S'])
                if probe.shape!=(2,2) or abs(float(probe[-1,1])-1)>1e-8:raise RuntimeError('SBML solver probe failed')
            engines[engine]=str(getattr(modules[0],"__version__",getattr(modules[0],"getLibSBMLDottedVersion",lambda:"unknown")()))
            methods.extend(METHODS[engine])
        except Exception as error:unavailable[engine]=str(error)
    return dict(protocol="floe.biology.worker",version=1,methods=sorted(methods),engines=engines,unavailable=unavailable,
                limits=dict(envelopeBytes=MAX_BYTES,imageElements=4000000,tilePixels=1048576,decodeChunkBytes=67108864,denseElements=2000000,sparseNonzeros=2000000,alignmentCells=4000000,atoms=100000,contacts=200000,sbmlSpecies=128,sbmlTimePoints=10001))

def execute(request,workspace=None):
    identity=None;digest=None;token=None
    try:
        if "protocol" in request:
            if set(request)!={"protocol","version","identity","requestJSON","requestDigest"} or request["protocol"]!="floe.biology.worker" or type(request["version"]) is not int or request["version"]!=1:raise ValueError("Invalid worker envelope")
            identity=request["identity"]
            expected={"projectID","runID","objectID","taskID","hostRunID","attemptID","objectRevision","inputDigest","environmentID"}
            if not isinstance(identity,dict) or set(identity)!=expected:raise ValueError("Invalid execution identity")
            for key in ("projectID","runID","objectID","taskID","hostRunID","attemptID"):
                if str(uuid.UUID(identity[key]))!=identity[key]:raise ValueError("Identity UUID must be canonical lowercase")
            bounded_integer(identity["objectRevision"],1,2**64-1,"object revision")
            if not isinstance(identity["environmentID"],str) or not 0<len(identity["environmentID"])<=4096:raise ValueError("Invalid environment identity")
            hex_digest(identity["inputDigest"],"input digest")
            raw=request["requestJSON"]
            if not isinstance(raw,str) or len(raw.encode())>MAX_BYTES:raise ValueError("Worker request exceeds its size limit")
            digest=hashlib.sha256(raw.encode()).hexdigest()
            if digest!=hex_digest(request["requestDigest"],"request digest"):raise ValueError("Request digest mismatch")
            inner=strict_json(raw)
        else:inner=request
        if inner.get("operation")=="capabilities":
            result=capabilities()
            return dict(protocol="floe.biology.worker",version=1,identity=identity,requestDigest=digest,complete=True,success=True,result=result)
        if set(inner)!={"operation","snapshotJSON","options"}:raise ValueError("Invalid operation request")
        snapshot=inner["snapshotJSON"]
        if not isinstance(snapshot,str) or len(snapshot.encode())>MAX_BYTES:raise ValueError("Invalid dataset snapshot")
        asset=strict_json(snapshot)
        if asset.get('fileReference'):
            ref=asset['fileReference']
            if identity is None or ref.get('projectID','').lower()!=identity['projectID'] or ref.get('environmentID')!=identity['environmentID']:
                raise ValueError('Referenced file does not belong to this project and execution environment')
        token=WORKSPACE.set(workspace)
        if identity and (hashlib.sha256(snapshot.encode()).hexdigest()!=identity["inputDigest"] or asset.get("id","").lower()!=identity["objectID"] or asset.get("revision")!=identity["objectRevision"]):raise ValueError("Dataset does not match the execution identity")
        if not isinstance(inner["options"],dict):raise ValueError("Options must be an object")
        operation=inner["operation"]
        with contextlib.redirect_stdout(sys.stderr):
            if operation.startswith("seq."):
                if operation not in METHODS["Bio"]:raise ValueError("Unknown sequence method")
                from bio_sequence_structure import sequence
                result=sequence(asset,operation,inner["options"])
            elif operation.startswith("struct."):
                if operation not in METHODS["gemmi"]:raise ValueError("Unknown structure method")
                from bio_sequence_structure import structure
                result=structure(asset,operation,inner["options"])
            elif operation.startswith("micro."):
                if operation not in METHODS["skimage"]:raise ValueError("Unknown microscopy method")
                from bio_image_omics import microscopy
                result=microscopy(asset,operation,inner["options"])
            elif operation.startswith("omics."):
                if operation not in METHODS["scanpy"]:raise ValueError("Unknown omics method")
                from bio_image_omics import omics
                result=omics(asset,operation,inner["options"])
            elif operation.startswith("net."):
                if operation not in METHODS["scipy"]+METHODS["libsbml"]+METHODS['roadrunner']:raise ValueError("Unknown network method")
                from bio_network import network
                result=network(asset,operation,inner["options"])
            else:raise ValueError("Unknown scientific method")
        # Native Codable output accepts finite numbers only. Scientific undefined
        # values must be explicit nulls in explanatory text, never fabricated zeros.
        encoded=json.dumps(result,allow_nan=False,separators=(",",":"))
        if len(encoded.encode())>MAX_BYTES:raise ValueError("Scientific output exceeds its size budget")
        return dict(protocol="floe.biology.worker",version=1,identity=identity,requestDigest=digest,complete=True,success=True,result=result)
    except Exception as error:
        return dict(protocol="floe.biology.worker",version=1,identity=identity,requestDigest=digest,complete=True,success=False,error=dict(type=type(error).__name__,message=str(error)[:4096]))
    finally:
        if token is not None:WORKSPACE.reset(token)

def main():
    import argparse
    parser=argparse.ArgumentParser()
    parser.add_argument('--workspace',default=None)
    args=parser.parse_args()
    raw=sys.stdin.buffer.read(MAX_BYTES+1)
    if not raw or len(raw)>MAX_BYTES:
        response=dict(protocol="floe.biology.worker",version=1,complete=True,success=False,error=dict(type="ValueError",message="Input exceeds 32 MiB or is empty"))
    else:
        try:response=execute(strict_json(raw),workspace=args.workspace)
        except Exception as error:response=dict(protocol="floe.biology.worker",version=1,complete=True,success=False,error=dict(type=type(error).__name__,message=str(error)[:4096]))
    sys.stdout.write(json.dumps(response,allow_nan=False,separators=(",",":"))+"\n")

if __name__=="__main__":main()
