# SPDX-License-Identifier: MPL-2.0
"""Typed biochemical kinetics. Arbitrary SBML formulas are never evaluated."""
import json
import math
from bio_common import bounded_integer, finite_number
from bio_sequence_structure import output, original, native_payload

def network_model(asset):
    if "biochemicalNetwork" in asset["payload"]:return native_payload(asset)
    return json.loads(original(asset).decode())

def validate(model):
    species=model["species"];reactions=model["reactions"]
    if not 1<=len(species)<=128 or len(reactions)>512:raise ValueError("Network size budget exceeded")
    ids=[s["id"] for s in species]
    if len(set(ids))!=len(ids) or any(not isinstance(i,str) or not i or len(i)>128 for i in ids):raise ValueError("Invalid species identifiers")
    initial=[finite_number(s["initialAmount"],0,1e15,"initial amount") for s in species]
    for r in reactions:
        finite_number(r["rateConstant"],0,1e12,"rate constant")
        if not r["reactants"]:raise ValueError("Mass-action reaction needs a reactant")
        for key,value in list(r["reactants"].items())+list(r["products"].items()):
            if key not in ids:raise ValueError("Reaction refers to an unknown species")
            bounded_integer(value,1,8,"stoichiometry")
    return ids,initial

def simulate(model,options):
    import numpy as np
    from scipy.integrate import solve_ivp
    from scipy.linalg import null_space
    ids,initial=validate(model);index={s:i for i,s in enumerate(ids)}
    end=finite_number(options.get("timeEnd",30),1e-9,1e6,"simulation duration")
    points=bounded_integer(options.get("points",301),2,10001,"time points")
    method=options.get("solver","DOP853")
    if method not in {"DOP853","RK45","LSODA","BDF","Radau"}:raise ValueError("Unsupported adaptive solver")
    stoich=np.zeros((len(ids),len(model["reactions"])))
    for j,r in enumerate(model["reactions"]):
        for s,n in r["reactants"].items():stoich[index[s],j]-=n
        for s,n in r["products"].items():stoich[index[s],j]+=n
    calls=[0]
    def rhs(t,y):
        calls[0]+=1
        if calls[0]>200000:raise ValueError("Solver evaluation budget exceeded; use a better-conditioned model")
        rates=[]
        for r in model["reactions"]:
            rate=r["rateConstant"]
            for s,n in r["reactants"].items():rate*=y[index[s]]**n
            rates.append(rate)
        return stoich@rates
    result=solve_ivp(rhs,(0,end),initial,method=method,t_eval=np.linspace(0,end,points),rtol=1e-9,atol=1e-12)
    if not result.success:raise ValueError("Solver did not converge: "+result.message)
    if not np.isfinite(result.y).all() or result.y.min() < -1e-10:raise ValueError("Solver reached invalid species amounts")
    conservation=[]
    for v in null_space(stoich.T).T:
        curve=v@result.y
        conservation.append(dict(coefficients=v.tolist(),initial=float(curve[0]),final=float(curve[-1]),maximumDrift=float(np.max(np.abs(curve-curve[0])))))
    metrics={"stepsReturned":len(result.t),"evaluations":calls[0]}
    metrics.update({"final_"+s:float(result.y[i,-1]) for i,s in enumerate(ids)})
    details=dict(solver=method,rtol="1e-9",atol="1e-12",amountUnit=model.get("amountUnit","arbitrary amount"),timeUnit=model.get("timeUnit","s"),negativePolicy="Fail below -1e-10; no clipping")
    return output("Adaptive biochemical time course",metrics,["time"]+ids,np.column_stack((result.t,result.y.T)).tolist(),text=json.dumps(conservation),details=details)

def sbml(asset,operation,options):
    import libsbml
    if operation=="net.sbml.import":
        raw=original(asset).decode()
        if "<!DOCTYPE" in raw.upper() or "<!ENTITY" in raw.upper():raise ValueError("External XML declarations are not accepted")
        document=libsbml.readSBMLFromString(raw)
        if document.getNumErrors(libsbml.LIBSBML_SEV_ERROR)>0 or document.getModel() is None:raise ValueError("SBML validation failed")
        model=document.getModel()
        species=[dict(id=s.getId(),initialAmount=s.getInitialAmount() if s.isSetInitialAmount() else None,initialConcentration=s.getInitialConcentration() if s.isSetInitialConcentration() else None,compartment=s.getCompartment()) for s in model.getListOfSpecies()]
        reactions=[]
        for r in model.getListOfReactions():
            law=r.getKineticLaw()
            reactions.append(dict(id=r.getId(),reactants=[dict(id=s.getSpecies(),stoichiometry=s.getStoichiometry()) for s in r.getListOfReactants()],products=[dict(id=s.getSpecies(),stoichiometry=s.getStoichiometry()) for s in r.getListOfProducts()],formula=libsbml.formulaToL3String(law.getMath()) if law and law.isSetMath() else None))
        return output("SBML model and kinetic expressions",{"species":len(species),"reactions":len(reactions)},text=json.dumps(dict(species=species,reactions=reactions)),details={"engine":"libSBML "+libsbml.getLibSBMLDottedVersion(),"execution":"Parsed expressions only; arbitrary formulas are not executed."})
    model=network_model(asset);ids,initial=validate(model)
    doc=libsbml.SBMLDocument(3,2);m=doc.createModel();m.setId("FloeBiology")
    compartment=m.createCompartment();compartment.setId("cell");compartment.setSize(1);compartment.setConstant(True);compartment.setSpatialDimensions(3)
    for s,v in zip(ids,initial):
        item=m.createSpecies();item.setId(s);item.setCompartment("cell");item.setInitialAmount(v);item.setHasOnlySubstanceUnits(True);item.setBoundaryCondition(False);item.setConstant(False)
    for i,r in enumerate(model["reactions"]):
        item=m.createReaction();item.setId(r["id"]);item.setReversible(False)
        for kind in ("reactants","products"):
            for s,n in r[kind].items():
                ref=item.createReactant() if kind=="reactants" else item.createProduct()
                ref.setSpecies(s);ref.setStoichiometry(n);ref.setConstant(True)
        law=item.createKineticLaw();param=law.createLocalParameter();param.setId("k");param.setValue(r["rateConstant"])
        expression="k"+"".join("*"+s+("^"+str(n) if n!=1 else "") for s,n in r["reactants"].items())
        law.setMath(libsbml.parseL3Formula(expression))
    if doc.checkInternalConsistency()>0:
        errors=[doc.getError(i).getMessage() for i in range(doc.getNumErrors()) if doc.getError(i).getSeverity()>=libsbml.LIBSBML_SEV_ERROR]
        if errors:raise ValueError("SBML export consistency: "+"; ".join(errors))
    return output("SBML model export",{"species":len(ids),"reactions":len(model["reactions"])},text=libsbml.writeSBMLToString(doc),details={"engine":"libSBML "+libsbml.getLibSBMLDottedVersion(),"units":"Original unit labels are retained in the project. SBML export uses amount variables in one unit-volume compartment."})

def network(asset,operation,options):
    import scipy
    if operation in {'net.sbml.simulate','net.sbml.sweep'}:
        from bio_sbml import sbml_simulate
        return sbml_simulate(asset,operation,options)
    if operation.startswith("net.sbml."):return sbml(asset,operation,options)
    model=network_model(asset)
    if operation=="net.sweep":
        values=options.get("values",[])
        if not 1<=len(values)<=32:raise ValueError("A sweep needs 1 to 32 parameter values")
        i=bounded_integer(options.get("reaction",0),0,len(model["reactions"])-1,"reaction")
        rows=[]
        for value in values:
            value=finite_number(value,0,1e12,"sweep rate")
            changed=json.loads(json.dumps(model));changed["reactions"][i]["rateConstant"]=value
            r=simulate(changed,options);rows.append([value]+[r["metrics"]["final_"+s["id"]] for s in model["species"]])
        return output("Reaction-rate parameter sweep",columns=["rate"]+[s["id"] for s in model["species"]],rows=rows,details={"engine":"SciPy "+scipy.__version__})
    r=simulate(model,options);r["details"]["engine"]="SciPy "+scipy.__version__;return r
