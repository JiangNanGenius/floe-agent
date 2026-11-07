#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Real Linux/TeX qualification, independent of App authorization and UI.

Run in a disposable Linux environment with TeX Live, Biber, makeindex,
poppler-utils and Python installed. No host interpreter fallback is allowed.
Each invocation writes a new evidence directory and preserves failed output.
"""
from pathlib import Path
import argparse,base64,gzip,hashlib,json,os,platform,re,signal,subprocess,sys,time,unicodedata,uuid

ARTICLE=r"""\documentclass{article}
\usepackage{amsmath}
\begin{document}
Engine fixture. $E=mc^2$. Year \the\year.
\include{parts/body}
\end{document}
"""
CHINESE=r"""\documentclass[fontset=fandol]{ctexart}
\usepackage{amsmath}
\begin{document}
\section{中文排版验证}
这是本地工具链测试。$x^2+y^2=z^2$。
\end{document}
"""
BIBTEX=r"""\documentclass{article}
\begin{document}
Synthetic citation \cite{fixture}.
\bibliographystyle{plain}
\bibliography{references}
\end{document}
"""
BIBER=r"""\documentclass[fontset=fandol]{ctexart}
\usepackage[backend=biber,style=authoryear]{biblatex}
\addbibresource{references.bib}
\begin{document}
Unicode 文献测试 \textcite{fixture}。
\printbibliography
\end{document}
"""
GLOSSARY=r"""\documentclass{article}
\usepackage{makeidx}
\usepackage[acronym]{glossaries}
\usepackage{nomencl}
\makeindex\makeglossaries\makenomenclature
\newglossaryentry{sample}{name={sample},description={Synthetic glossary term}}
\newacronym{ai}{AI}{Artificial Intelligence}
\begin{document}
Index fixture\index{Zebra}. Glossary \gls{sample}. Acronym \gls{ai}.
\nomenclature{$E$}{Energy symbol}
\printindex\printglossaries\printnomenclature
\end{document}
"""
DIAGRAM=r"""\documentclass{article}
\usepackage{tikz,pgfplots,chemfig,booktabs,longtable}
\usepackage[version=4]{mhchem}
\pgfplotsset{compat=1.18}
\begin{document}
Diagram fixture. \ce{2H2 + O2 -> 2H2O}. \chemfig{H-O-H}
\begin{tikzpicture}\begin{axis}[width=6cm,height=4cm]
\addplot coordinates {(0,0) (1,1) (2,4)};
\end{axis}\end{tikzpicture}
\begin{longtable}{ll}\toprule Name & Value\\\midrule
First & 1\\ Second & 2\\\bottomrule\end{longtable}
\end{document}
"""
BEAMER=r"""\documentclass{beamer}
\usepackage[fontset=fandol]{ctex}
\begin{document}
\begin{frame}{模板验证}第一张幻灯片。$E=mc^2$\end{frame}
\begin{frame}{第二页}Beamer fixture.\end{frame}
\end{document}
"""
BIB="@book{fixture,author={Example Author},title={Synthetic Bibliography Fixture},year={2026},publisher={Example Publisher}}\n"
UNICODE_BIB="@book{fixture,author={张三 and Émile Exemple},title={合成文献条目},date={2026},publisher={Example Publisher}}\n"

def cases():
    nested={"main.tex":ARTICLE,"parts/body.tex":"Included chapter fixture.\\label{chapter}\n"}
    return [
        ("pdflatex","pdfLaTeX",nested,["Engine fixture","Included chapter fixture"],[],False),
        ("xelatex-chinese","xeLaTeX",{"main.tex":CHINESE},["中文排版验证","本地工具链测试"],[],False),
        ("lualatex-chinese","luaLaTeX",{"main.tex":CHINESE},["中文排版验证","本地工具链测试"],[],False),
        ("latex-dvi","latex",nested,["Engine fixture","Included chapter fixture"],["dvipdfmx"],False),
        ("bibtex","pdfLaTeX",{"main.tex":BIBTEX,"references.bib":BIB},["Synthetic Bibliography Fixture"],["bibtex"],False),
        ("biber-unicode","xeLaTeX",{"main.tex":BIBER,"references.bib":UNICODE_BIB},["合成文献条目","2026"],["biber"],False),
        ("index-glossary-nomenclature","pdfLaTeX",{"main.tex":GLOSSARY},["Zebra","Synthetic glossary term","Artificial Intelligence","Energy symbol"],["makeindex"],False),
        ("tikz-chemistry-longtable","pdfLaTeX",{"main.tex":DIAGRAM},["Diagram fixture","First","Second"],[],False),
        ("beamer-chinese","xeLaTeX",{"main.tex":BEAMER},["模板验证","Beamer fixture"],[],False),
        ("offline-chinese","xeLaTeX",{"main.tex":CHINESE},["中文排版验证"],[],True),
        ("offline-biber","xeLaTeX",{"main.tex":BIBER,"references.bib":UNICODE_BIB},["合成文献条目"],["biber"],True),
    ]

def compact(text):
    # DVI font maps may return the ordinary fi/fl ligature code points.
    return re.sub(r"\s+","",unicodedata.normalize("NFKC",text))

def run_worker(worker,request,folder):
    with (folder/"transport.stdout").open("wb") as out,(folder/"transport.stderr").open("wb") as err:
        child=subprocess.Popen([sys.executable,"-B",str(worker),"build","--request",str(request)],stdout=out,stderr=err,start_new_session=True)
        try:return child.wait(timeout=210)
        except BaseException:
            if child.poll() is None:
                os.killpg(child.pid,signal.SIGTERM)
                try:child.wait(timeout=5)
                except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
            raise

def qualify(worker,root,case):
    name,engine,files,expected,phases,offline=case
    project,request_id=str(uuid.uuid4()),str(uuid.uuid4())
    folder=root/name/".floe-latex"/project/request_id
    source=folder/"Source";source.mkdir(parents=True)
    entries=[]
    for relative,text in files.items():
        data=text.encode();path=source/relative;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
        entries.append({"path":relative,"byteCount":len(data),"sha256":hashlib.sha256(data).hexdigest()})
    request=folder/"request.json"
    request.write_text(json.dumps({"protocol":"floe.latex.worker","version":1,"requestID":request_id,"environmentID":"independent-linux-qualification","buildTimestamp":int(time.time()),"timeoutSeconds":180,"offline":offline,"manifest":{"id":project,"revision":0,"engine":engine,"mainFile":"main.tex","files":entries}}))
    result={"case":name,"engine":engine,"offline":offline,"root":str(folder),"started":time.time()}
    try:
        result["workerExitCode"]=run_worker(worker,request,folder)
        receipt=json.loads((folder/"receipt.json").read_text());result["receipt"]=receipt
        assert result["workerExitCode"]==0 and receipt.get("success") and receipt.get("workerStopped"),receipt.get("error","Worker failed")
        for artifact in receipt["artifacts"]:
            path=folder/"Output"/artifact["path"]
            assert path.stat().st_size==artifact["byteCount"] and hashlib.sha256(path.read_bytes()).hexdigest()==artifact["sha256"],"Artifact identity changed"
        pdf=folder/"Output"/receipt["pdf"]
        info=subprocess.check_output(["pdfinfo",str(pdf)],text=True);(folder/"pdfinfo.txt").write_text(info)
        pages=int(re.search(r"(?m)^Pages:\s+(\d+)",info)[1]);assert pages>0
        if name=="beamer-chinese":assert pages==2,"Beamer did not produce both slides"
        text=subprocess.check_output(["pdftotext","-layout",str(pdf),"-"],text=True);(folder/"pdf-text.txt").write_text(text)
        for token in expected:assert compact(token) in compact(text),"Missing rendered text: "+token
        log=(folder/"Output/worker.log").read_text(errors="replace")
        for phase in phases:assert "FLOE PHASE: "+phase in log,"Auxiliary program was not invoked: "+phase
        final_log=(folder/"Output/document.log").read_text(errors="replace")
        assert "There were undefined references" not in final_log,"References did not converge"
        sync=folder/"Output/document.synctex.gz"
        with gzip.open(sync,"rt") as stream:mapping=stream.read(64*1024*1024+1)
        assert len(mapping)<=64*1024*1024 and "Input:" in mapping
        assert str(source)+"/" not in mapping,"Source map retained guest absolute paths"
        result.update(success=True,pages=pages,pdfSHA256=hashlib.sha256(pdf.read_bytes()).hexdigest(),duration=time.time()-result["started"])
    except Exception as error:result.update(success=False,error=str(error),duration=time.time()-result["started"])
    (root/(name+".json")).write_text(json.dumps(result,indent=2,ensure_ascii=False)+"\n")
    print(json.dumps({k:result[k] for k in ["case","success","duration"]}|({"error":result["error"]} if "error" in result else {}),ensure_ascii=False),flush=True)
    return result

def main():
    parser=argparse.ArgumentParser();parser.add_argument("--worker",type=Path,required=True);parser.add_argument("--output",type=Path,required=True);parser.add_argument("--case",action="append")
    args=parser.parse_args()
    if platform.system()!="Linux":parser.error("This qualification must run in Linux, not on the Apple host")
    worker=args.worker.resolve();assert worker.is_file()
    root=args.output.absolute();root.mkdir(parents=True,exist_ok=False)
    selected=[c for c in cases() if not args.case or c[0] in args.case]
    assert selected and (not args.case or set(args.case)=={c[0] for c in selected}),"Unknown case selection"
    profile={"platform":platform.platform(),"architecture":platform.machine(),"workerSHA256":hashlib.sha256(worker.read_bytes()).hexdigest(),"scope":"Independent real Linux engines and PDF output; not App authorization, runtime, Simulator performance or Apple review"}
    (root/"platform.json").write_text(json.dumps(profile,indent=2)+"\n")
    result=subprocess.run([sys.executable,"-B",str(worker),"probe"],capture_output=True,text=True,timeout=120,check=True)
    (root/"probe.txt").write_text(result.stdout)
    package_format="${binary:Package}\t${Version}\t${Architecture}\n"
    (root/"packages.tsv").write_bytes(subprocess.check_output(["dpkg-query","-W","-f="+package_format]))
    results=[qualify(worker,root,c) for c in selected]
    summary={"profile":profile,"cases":[{k:v for k,v in r.items() if k!="receipt"} for r in results],"passed":sum(r["success"] for r in results),"total":len(results)}
    (root/"summary.json").write_text(json.dumps(summary,indent=2,ensure_ascii=False)+"\n")
    return 0 if summary["passed"]==summary["total"] else 1

if __name__=="__main__":raise SystemExit(main())
