# SPDX-License-Identifier: MPL-2.0
import base64
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import uuid
import numpy as np
from biology_worker import execute
from bio_common import strict_json

SAMPLES=Path(__file__).resolve().parents[1]/"Samples"
def asset(kind,payload,fmt,raw):
    return dict(id=str(uuid.uuid4()).upper(),title="Qualification",revision=1,payload={kind:{"_0":payload}},originalData=base64.b64encode(raw).decode(),originalFormat=fmt,warnings=[],provenance={})
def request(a,method,options=None):
    snapshot=json.dumps(a,sort_keys=True,separators=(",",":"))
    inner=json.dumps(dict(operation=method,snapshotJSON=snapshot,options=options or {}),sort_keys=True,separators=(",",":"))
    identity={k:str(uuid.uuid4()) for k in ["projectID","runID","taskID","hostRunID","attemptID"]}
    identity.update(objectID=a["id"].lower(),objectRevision=a["revision"],inputDigest=hashlib.sha256(snapshot.encode()).hexdigest(),environmentID="qualification")
    return dict(protocol="floe.biology.worker",version=1,identity=identity,requestJSON=inner,requestDigest=hashlib.sha256(inner.encode()).hexdigest())
def run(a,method,options=None):
    req=request(a,method,options);reply=execute(req)
    if not reply.get("success"):raise AssertionError(reply.get("error"))
    assert reply["identity"]==req["identity"] and reply["requestDigest"]==req["requestDigest"]
    return reply["result"]

class ScienceTests(unittest.TestCase):
    def sequence(self):
        raw=(SAMPLES/"synthetic-dna.fasta").read_bytes()
        from Bio import SeqIO
        import io
        records=[dict(id=str(uuid.uuid4()),name=r.id,sequence=str(r.seq),alphabet="dna",annotations=[]) for r in SeqIO.parse(io.StringIO(raw.decode()),"fasta")]
        return asset("sequence",records,"fasta",raw)
    def matrix(self):
        import csv,io
        raw=(SAMPLES/"synthetic-counts.csv").read_bytes();rows=list(csv.reader(io.StringIO(raw.decode())))
        p=dict(geneIDs=[r[0] for r in rows[1:]],cellIDs=rows[0][1:],values=[float(x) for r in rows[1:] for x in r[1:]])
        return asset("expressionMatrix",p,"csv",raw)
    def image(self):
        raw=(SAMPLES/"synthetic-microscopy.json").read_bytes();p=json.loads(raw)
        p=dict(width=p["width"],height=p["height"],channels=1,slices=1,frames=1,bitDepth=16,samples=p["pixels"],pixelSizeX=0.5,pixelSizeY=0.5,calibrationUnit="µm")
        return asset("microscopyImage",p,"json",raw)
    def network(self):
        raw=(SAMPLES/"synthetic-network.json").read_bytes();return asset("biochemicalNetwork",json.loads(raw),"network.json",raw)
    def test_sequence_translation_alignment_and_phylogeny(self):
        a=self.sequence()
        self.assertEqual(run(a,"seq.translate")["text"],"MADEFYGAK*")
        self.assertEqual(run(a,"seq.align.global")["metrics"]["score"],57)
        p=a["payload"]["sequence"]["_0"];p.append({**p[0],"id":str(uuid.uuid4()),"name":"Third","sequence":"ATGGCTGATGAATTCTACGGTGCTAAATAG"})
        self.assertIn("Third",run(a,"seq.phylogeny")["text"])
    def test_rich_genbank_roundtrip(self):
        from Bio.Seq import Seq
        from Bio.SeqRecord import SeqRecord
        from Bio.SeqFeature import SeqFeature,CompoundLocation,SimpleLocation
        from Bio import SeqIO
        import io
        r=SeqRecord(Seq("ATGGCTGATGAATTCTACGGTGCTAAATAA"),id="SYNTHETIC.1",description="Synthetic rich record")
        r.annotations["molecule_type"]="DNA"
        r.features=[SeqFeature(CompoundLocation([SimpleLocation(0,6),SimpleLocation(12,18)]),type="misc_feature",qualifiers={"note":["first","second"]})]
        s=io.StringIO();SeqIO.write([r],s,"genbank");raw=s.getvalue().encode()
        a=asset("externalDataset","genbank","genbank",raw)
        parsed=json.loads(run(a,"seq.parse")["text"])
        self.assertEqual(parsed[0]["features"][0]["qualifiers"]["note"],["first","second"])
        exported=run(a,"seq.export",{"format":"genbank"})["text"]
        rr=SeqIO.read(io.StringIO(exported),"genbank")
        self.assertEqual(len(rr.features[0].location.parts),2)
    def test_real_structure_pdb_cif_and_contacts(self):
        for fmt in ["pdb","cif"]:
            a=asset("externalDataset",fmt,fmt,(SAMPLES/("1ubq."+fmt)).read_bytes())
            r=run(a,"struct.geometry")
            self.assertEqual(r["metrics"]["atoms"],660)
            contacts=run(a,"struct.contacts",{"atomNames":["CA"],"cutoff":4.1})
            self.assertGreater(contacts["metrics"]["contacts"],50)
            zero=run(a,"struct.rmsd",{"atomNames":["CA"],"reference":(SAMPLES/"1ubq.pdb").read_text(),"referenceFormat":"pdb"})
            self.assertLess(zero["metrics"]["rmsd_A"],1e-10)
    def test_segmentation_units_and_overlay(self):
        a=self.image();r=run(a,"micro.segment",{"threshold":10})
        self.assertEqual(r["metrics"]["objects"],2)
        self.assertEqual(sorted(v[1] for v in r["rows"]),[37.25,63.25])
        overlay=run(a,"micro.overlay",{"threshold":10})
        self.assertTrue(base64.b64decode(overlay["text"]).startswith(b"\x89PNG"))
    def test_tiff_16bit_decode_and_axis_bounds(self):
        import tifffile,io
        image=np.array([[0,1000],[45000,65535]],dtype=np.uint16)
        stream=io.BytesIO();tifffile.imwrite(stream,image)
        a=asset("externalDataset","tiff","tiff",stream.getvalue())
        r=run(a,"micro.import")
        self.assertEqual(r["metrics"]["maximum"],65535)
        self.assertEqual(r["metrics"]["mean"],float(image.mean()))
        self.assertEqual(json.loads(r["text"])["samples"],image.reshape(-1).tolist())
        self.assertEqual(json.loads(r["text"])["bitDepth"],16)
    def test_edited_sequence_semantics_and_multiaxis_native_conversion(self):
        from Bio import SeqIO
        import io
        a=self.sequence();a["originalFormat"]="fastq";a["originalData"]=base64.b64encode(b"@old\nATGC\n+\nIIII\n").decode();a["revision"]=2
        a["payload"]["sequence"]["_0"]=[dict(id=str(uuid.uuid4()),name="current",sequence="AGCC",alphabet="protein",annotations=[])]
        self.assertNotIn("GC_percent",run(a,"seq.stats")["metrics"])
        self.assertFalse(execute(request(a,"seq.translate"))["success"])
        self.assertFalse(execute(request(a,"seq.reverseComplement"))["success"])
        exported=run(a,"seq.export",{"format":"genbank"})
        self.assertEqual(str(SeqIO.read(io.StringIO(exported["text"]),"genbank").seq),"AGCC")
        self.assertIn("current records",exported["details"]["source"])
        a=self.image();p=a["payload"]["microscopyImage"]["_0"]
        p.update(width=2,height=1,frames=2,slices=2,channels=2,samples=list(range(16)))
        image=run(a,"micro.import",dict(frame=1,slice=0,channel=1))
        self.assertEqual(image["metrics"]["mean"],10.5)
        decoded=json.loads(image["text"]);self.assertEqual(decoded["samples"],list(range(16)));self.assertEqual(decoded["channels"],2)
        matrix=json.loads(run(self.matrix(),"omics.import")["text"])
        self.assertEqual(matrix["geneIDs"][0],"GENE_A");self.assertEqual(len(matrix["values"]),48)
    def test_unsupported_image_precision_is_rejected(self):
        import io,tifffile
        for image in [np.array([[2**54,2**54+1]],dtype=np.uint64),np.array([[1+2j]],dtype=np.complex64)]:
            stream=io.BytesIO();tifffile.imwrite(stream,image)
            reply=execute(request(asset("externalDataset","tiff","tiff",stream.getvalue()),"micro.import"))
            self.assertFalse(reply["success"])
            self.assertIn("precision",reply["error"]["message"])
    def test_omics_qc_normalize_pca_leiden_umap_and_diffexp(self):
        a=self.matrix()
        self.assertEqual(run(a,"omics.qc")["metrics"]["cells"],8)
        normalized=run(a,"omics.normalize")
        for j in range(8):self.assertAlmostEqual(sum(row[j] for row in normalized["rows"]),10000,places=3)
        pca=run(a,"omics.pca",{"nComps":2})
        self.assertEqual(len(pca["rows"]),8)
        self.assertEqual(len(pca["columns"]),2)
        clustered=run(a,"omics.cluster",{"nComps":2,"nNeighbors":3})
        self.assertGreaterEqual(clustered["metrics"]["clusters"],2)
        embedded=run(a,"omics.embedding",{"nComps":2,"nNeighbors":3})
        self.assertEqual(len(embedded["rows"]),8)
        diff=run(a,"omics.diffexp",{"groupA":["Cell_A1","Cell_A2","Cell_A3","Cell_A4"],"groupB":["Cell_B1","Cell_B2","Cell_B3","Cell_B4"]})
        self.assertTrue(any(name=="GENE_A" for name in diff["rowNames"]))
        self.assertEqual(int(diff["details"]["undefinedTests"]),2)
    def test_h5ad_and_sparse_mtx(self):
        import anndata as ad,io
        a=self.matrix();p=a["payload"]["expressionMatrix"]["_0"]
        import pandas as pd
        data=ad.AnnData(np.array(p["values"]).reshape(6,8).T,obs=pd.DataFrame(index=p["cellIDs"]),var=pd.DataFrame(index=p["geneIDs"]))
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/"sample.h5ad";data.write_h5ad(path)
            r=run(asset("externalDataset","h5ad","h5ad",path.read_bytes()),"omics.qc")
            self.assertEqual(r["metrics"]["cells"],8)
        mtx=b"%%MatrixMarket matrix coordinate real general\n2 3 3\n1 1 2\n1 2 4\n2 3 7\n"
        r=run(asset("externalDataset","mtx","mtx",mtx),"omics.qc")
        self.assertEqual(r["metrics"]["cells"],3)
        self.assertEqual(r["metrics"]["genes"],2)
    def test_network_analytical_conservation_sweep_sbml(self):
        a=self.network();r=run(a,"net.simulate")
        self.assertAlmostEqual(r["metrics"]["final_A"],100*np.exp(-3),places=6)
        for row in r["rows"]:self.assertAlmostEqual(row[1]+row[2],100,places=9)
        self.assertLess(max(v["maximumDrift"] for v in json.loads(r["text"])),1e-10)
        self.assertEqual(len(run(a,"net.sweep",{"values":[0.05,0.1,0.2]})["rows"]),3)
        xml=run(a,"net.sbml.export")["text"]
        imported=run(asset("externalDataset","sbml","sbml",xml.encode()),"net.sbml.import")
        self.assertEqual(imported["metrics"]["species"],2)
    def test_digest_foreign_identity_and_nonfinite_rejected(self):
        req=request(self.sequence(),"seq.stats")
        req["requestDigest"]="0"*64
        self.assertFalse(execute(req)["success"])
        req=request(self.sequence(),"seq.stats");req["identity"]["objectID"]=str(uuid.uuid4())
        self.assertFalse(execute(req)["success"])
        with self.assertRaises(ValueError):strict_json('{"a":NaN}')
        with self.assertRaises(ValueError):strict_json('{"a":1,"a":2}')
    def test_resource_and_unsupported_requests(self):
        a=self.sequence();p=a["payload"]["sequence"]["_0"]
        p[0]["sequence"]="A"*3000;p[1]["sequence"]="A"*3000
        self.assertFalse(execute(request(a,"seq.align.global"))["success"])
        a=self.image();a["payload"]["microscopyImage"]["_0"]["width"]=999999999
        self.assertFalse(execute(request(a,"micro.segment"))["success"])
        self.assertFalse(execute(request(self.sequence(),"seq.fake"))["success"])

if __name__=="__main__":unittest.main()
