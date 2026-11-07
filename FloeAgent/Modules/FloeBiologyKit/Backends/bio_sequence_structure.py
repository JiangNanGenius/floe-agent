# SPDX-License-Identifier: MPL-2.0
"""Mature sequence/structure engines. No interpreter, command or network access."""
import base64
import io
import json
import math
from bio_common import bounded_integer, finite_number, source_file

def output(summary, metrics=None, columns=None, rows=None, names=None, text="", details=None, labels=None):
    return dict(summary=summary, metrics=metrics or {}, columns=columns or [], rows=rows or [],
                rowNames=names or [], labels=labels or [], text=text,
                details={str(k):str(v) for k,v in (details or {}).items()})

def native_payload(asset):
    payload=asset["payload"]
    if len(payload)!=1:
        raise ValueError("Invalid typed dataset")
    return next(iter(payload.values()))["_0"]

def original(asset):
    with source_file(asset) as stream:
        raw=stream.read(16*1024*1024+1)
        if len(raw)>16*1024*1024:raise ValueError("This operation needs a bounded file-backed parser rather than expanding the complete input")
        return raw

def sequence(asset, operation, options):
    import Bio
    from Bio import SeqIO, Align, Phylo
    from Bio.Seq import Seq
    from Bio.SeqRecord import SeqRecord
    from Bio.Phylo.TreeConstruction import DistanceMatrix, DistanceTreeConstructor
    if "sequence" in asset["payload"]:
        records=[SeqRecord(Seq(r["sequence"]),id=r["name"],description="") for r in native_payload(asset)]
    else:
        fmt={"gb":"genbank","gbk":"genbank","fa":"fasta","fq":"fastq"}.get(asset["originalFormat"],asset["originalFormat"])
        records=list(SeqIO.parse(io.StringIO(original(asset).decode()),fmt))
    if not records or len(records)>256 or any(len(r)>200000 for r in records):
        raise ValueError("Sequence record/length budget exceeded")
    engine={"engine":"Biopython "+Bio.__version__}
    if operation=="seq.parse":
        # Parse original rich records, preserving compound locations and repeated qualifiers.
        fmt={"gb":"genbank","gbk":"genbank","fa":"fasta","fq":"fastq"}.get(asset["originalFormat"],asset["originalFormat"])
        rich=list(SeqIO.parse(io.StringIO(original(asset).decode()),fmt))
        data=[dict(id=r.id,name=r.name,description=r.description,annotations=r.annotations,
                   features=[dict(type=f.type,location=str(f.location),qualifiers=f.qualifiers) for f in r.features])
              for r in rich]
        return output("Sequence records and annotations",{"records":len(rich)},text=json.dumps(data,default=str),details=engine)
    i=bounded_integer(options.get("record",0),0,len(records)-1,"record")
    r=records[i]
    alphabet=native_payload(asset)[i].get("alphabet","dna") if "sequence" in asset["payload"] else r.annotations.get("molecule_type","DNA").lower()
    protein=alphabet.lower() in {"protein","amino acid"}
    if operation=="seq.stats":
        from Bio.SeqUtils import gc_fraction
        from collections import Counter
        counts=Counter(str(r.seq))
        metrics={"length":len(r)}
        if not protein:metrics["GC_percent"]=100*gc_fraction(r.seq,ambiguous="remove")
        return output("Sequence statistics",metrics,
                      ["count"],[[v] for k,v in sorted(counts.items())],[k for k,v in sorted(counts.items())],details=engine)
    if operation=="seq.translate":
        if protein:raise ValueError("Translation requires a nucleotide sequence")
        code=bounded_integer(options.get("code",1),1,33,"genetic code")
        frame=bounded_integer(options.get("frame",1),-3,3,"frame")
        if frame==0: raise ValueError("Reading frame cannot be zero")
        s=r.seq.reverse_complement() if frame<0 else r.seq
        s=s[abs(frame)-1:];s=s[:len(s)//3*3]
        text=str(s.translate(table=code))
        return output("Protein translation",{"aminoAcids":len(text),"stops":text.count("*")},text=text,details={**engine,"geneticCode":code,"frame":frame})
    if operation=="seq.reverseComplement":
        if protein:raise ValueError("A protein has no nucleotide complement")
        complemented=r.seq.reverse_complement_rna() if alphabet.lower()=="rna" else r.seq.reverse_complement()
        return output("Reverse complement",text=str(complemented),details=engine)
    if operation=="seq.export":
        fmt=options.get("format","genbank")
        if fmt not in {"genbank","fasta","fastq"}: raise ValueError("Unsupported sequence export")
        rich_source=asset["originalFormat"] in {"genbank","gb","gbk","fastq","fq"} and (asset.get("revision",1)==1 or options.get("source")=="original")
        if rich_source:
            source_fmt={"gb":"genbank","gbk":"genbank","fq":"fastq"}.get(asset["originalFormat"],asset["originalFormat"])
            records=list(SeqIO.parse(io.StringIO(original(asset).decode()),source_fmt))
        elif "sequence" in asset["payload"]:
            from Bio.SeqFeature import SeqFeature, SimpleLocation
            for record,p in zip(records,native_payload(asset)):
                record.annotations["molecule_type"]={"protein":"protein","rna":"RNA"}.get(p.get("alphabet"),"DNA")
                record.features=[SeqFeature(SimpleLocation(a["start"],a["end"],strand=a.get("strand") or None),type=a["name"],qualifiers=a.get("qualifiers",{})) for a in p.get("annotations",[])]
                if p.get("quality") is not None:record.letter_annotations["phred_quality"]=[ord(c)-33 for c in p["quality"]]
        for record in records: record.annotations.setdefault("molecule_type","DNA")
        stream=io.StringIO();SeqIO.write(records,stream,fmt)
        return output("Sequence file export",text=stream.getvalue(),details={**engine,"format":fmt,"source":"original rich records" if rich_source else "current records; exact original retained separately"})
    aligner=Align.PairwiseAligner()
    aligner.mode="local" if operation=="seq.align.local" else "global"
    aligner.match_score=finite_number(options.get("match",2),-100,100,"match score")
    aligner.mismatch_score=finite_number(options.get("mismatch",-1),-100,100,"mismatch score")
    aligner.open_gap_score=finite_number(options.get("gapOpen",-2),-100,0,"gap open")
    aligner.extend_gap_score=finite_number(options.get("gapExtend",-2),-100,0,"gap extension")
    if operation=="seq.phylogeny":
        if not 3<=len(records)<=64: raise ValueError("Tree requires 3 to 64 sequences")
        total=sum(len(a)*len(b) for i,a in enumerate(records) for b in records[:i])
        if total>8000000: raise ValueError("Phylogeny pairwise-work budget exceeded")
        names=[r.id for r in records]
        if len(set(names))!=len(names): raise ValueError("Tree requires unique record identifiers")
        distance=[]
        for i,a in enumerate(records):
            row=[]
            for b in records[:i]:
                alignment=aligner.align(a.seq,b.seq)[0]
                coords=alignment.indices
                keep=(coords[0]>=0)&(coords[1]>=0)
                matched=sum(a.seq[int(x)]==b.seq[int(y)] for x,y in coords[:,keep].T)
                row.append(1-matched/max(int(keep.sum()),1))
            row.append(0);distance.append(row)
        tree=DistanceTreeConstructor().nj(DistanceMatrix(names,distance))
        stream=io.StringIO();Phylo.write(tree,stream,"newick")
        return output("Neighbor-joining sequence tree",{"sequences":len(records)},text=stream.getvalue(),details={**engine,"distance":"Pairwise global identity over overlapping nongap columns"})
    j=bounded_integer(options.get("query",1),0,len(records)-1,"query")
    if i==j or len(r)*len(records[j])>4000000: raise ValueError("Choose two distinct records within the 4-million-cell alignment budget")
    alignment=aligner.align(r.seq,records[j].seq)[0]
    a,b=str(alignment[0]),str(alignment[1])
    return output("Pairwise sequence alignment",{"score":float(alignment.score),"alignedColumns":len(a),"identity_percent":100*sum(x==y for x,y in zip(a,b))/max(len(a),1)},text=a+"\n"+b,details={**engine,"method":aligner.mode,"gapOpen":aligner.open_gap_score,"gapExtend":aligner.extend_gap_score})

def structure(asset, operation, options):
    import gemmi
    import numpy as np
    from scipy.spatial import cKDTree
    raw=original(asset).decode()
    def read(text,fmt):
        return gemmi.read_pdb_string(text) if fmt=="pdb" else gemmi.make_structure_from_block(gemmi.cif.read_string(text).sole_block())
    st=read(raw,asset["originalFormat"])
    if "proteinStructure" in asset["payload"]:
        # Native edits are authoritative. Rebuild Gemmi's hierarchy from
        # current typed coordinates, preserving exact original bytes separately.
        st=gemmi.Structure();p=native_payload(asset);models={}
        for a in p["atoms"]:
            key=a.get("model",1)
            if key not in models:models[key]=[]
            models[key].append(a)
        for key,values in models.items():
            model=gemmi.Model(str(key));chains={};residues={}
            for a in values:
                c=a["chain"]
                if c not in chains:chains[c]=gemmi.Chain(c)
                rk=(c,a["residueNumber"],a.get("insertionCode", ""))
                if rk not in residues:
                    r=gemmi.Residue();r.name=a["residue"];r.seqid=gemmi.SeqId(a["residueNumber"],a.get("insertionCode") or ' ');r.het_flag='H' if a["hetero"] else 'A';residues[rk]=r
                atom=gemmi.Atom();atom.name=a["name"];atom.element=gemmi.Element(a["element"]);atom.pos=gemmi.Position(a["x"],a["y"],a["z"]);atom.occ=a["occupancy"];residues[rk].add_atom(atom)
            for (c,_,_),r in residues.items():chains[c].add_residue(r)
            for chain in chains.values():model.add_chain(chain)
            st.add_model(model)
    model=bounded_integer(options.get("model",0),0,len(st)-1,"model")
    def atoms_for(structure,model_index):
        atoms=[]
        for chain in structure[model_index]:
            if options.get("chain") is not None and chain.name!=options["chain"]:continue
            for residue in chain:
                if options.get("kind")=="polymer" and residue.het_flag!="A":continue
                if options.get("kind")=="water" and not residue.is_water():continue
                best={}
                for atom in residue:
                    if options.get("atomNames") and atom.name not in options["atomNames"]:continue
                    if atom.name not in best or atom.occ>best[atom.name].occ:best[atom.name]=atom
                for atom in best.values():
                    atoms.append(dict(chain=chain.name,residue=residue.name,residueNumber=residue.seqid.num,
                                      insertionCode=residue.seqid.icode.strip(),name=atom.name,element=atom.element.name,
                                      x=atom.pos.x,y=atom.pos.y,z=atom.pos.z,occupancy=atom.occ,hetero=residue.het_flag!="A"))
        if not 0<len(atoms)<=100000:raise ValueError("Invalid selection or atom budget exceeded")
        return atoms
    atoms=atoms_for(st,model)
    xyz=np.asarray([[a["x"],a["y"],a["z"]] for a in atoms])
    if not np.isfinite(xyz).all():raise ValueError("Non-finite structure coordinates")
    details={"engine":"Gemmi "+gemmi.__version__,"coordinates":"Å","altloc":"Highest occupancy per atom identity"}
    center=xyz.mean(axis=0)
    metrics=dict(atoms=len(atoms),geometricGyration_A=float(np.sqrt(((xyz-center)**2).sum(axis=1).mean())))
    if operation in {"struct.parse","struct.select"}:
        return output("Biomolecular hierarchy and selection",metrics,text=json.dumps(atoms),details=details)
    if operation=="struct.contacts":
        cutoff=finite_number(options.get("cutoff",4),0.1,20,"contact cutoff")
        tree=cKDTree(xyz)
        count=(int(tree.count_neighbors(tree,cutoff))-len(atoms))//2
        if count>200000:raise ValueError("Contact output budget exceeded; select a smaller region")
        pairs=tree.query_pairs(cutoff,output_type="ndarray")
        rows=[[int(i),int(j),float(np.linalg.norm(xyz[i]-xyz[j]))] for i,j in pairs]
        return output("Atomic contacts",{**metrics,"contacts":count},["atomA","atomB","distance_A"],rows,details=details)
    if operation=="struct.rmsd":
        reference=options.get("reference")
        other=read(reference,options.get("referenceFormat","pdb")) if reference is not None else st
        other_model=bounded_integer(options.get("referenceModel",0 if reference is not None else 1),0,len(other)-1,"reference model")
        bb=atoms_for(other,other_model)
        key=lambda a:(a["chain"],a["residueNumber"],a["insertionCode"],a["name"])
        a_map={key(a):a for a in atoms};b_map={key(a):a for a in bb}
        if set(a_map)!=set(b_map):raise ValueError("Structure atom identities do not match; choose matching selections")
        keys=sorted(a_map)
        a=np.array([[a_map[k][axis] for axis in ("x","y","z")] for k in keys])
        b=np.array([[b_map[k][axis] for axis in ("x","y","z")] for k in keys])
        ca=a.mean(0);cb=b.mean(0);u,s,vt=np.linalg.svd((b-cb).T@(a-ca));rotation=u@vt
        if np.linalg.det(rotation)<0:u[:,-1]*=-1;rotation=u@vt
        moved=(b-cb)@rotation+ca
        metrics["rmsd_A"]=float(np.sqrt(np.mean(np.sum((a-moved)**2,axis=1))))
        return output("Kabsch structure superposition",metrics,text=json.dumps({"rotation":rotation.tolist(),"translation":(ca-cb@rotation).tolist()}),details=details)
    return output("Structure geometry",metrics,["x_A","y_A","z_A"],[center.tolist(),xyz.min(0).tolist(),xyz.max(0).tolist()],["geometric center","minimum","maximum"],details=details)
