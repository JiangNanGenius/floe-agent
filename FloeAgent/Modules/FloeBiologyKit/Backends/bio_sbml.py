# SPDX-License-Identifier: MPL-2.0
"""General SBML kinetics, rules and events through libRoadRunner/CVODE.

No Python expression evaluator is used. Unsupported SBML semantics fail before
simulation, and every sweep starts from an independently loaded model.
"""
import json
import math
from bio_common import bounded_integer, finite_number
from bio_sequence_structure import original, output

def validated_model(asset):
    import libsbml
    raw = original(asset).decode('utf-8')
    if '<!DOCTYPE' in raw.upper() or '<!ENTITY' in raw.upper():
        raise ValueError('External XML declarations are not accepted')
    doc = libsbml.readSBMLFromString(raw)
    if doc.getNumErrors(libsbml.LIBSBML_SEV_ERROR) or doc.getModel() is None:
        raise ValueError('SBML validation failed')
    model = doc.getModel()
    if model.getNumSpecies()>128 or model.getNumReactions()>512 or model.getNumRules()>128 or model.getNumEvents()>128 or model.getNumFunctionDefinitions()>128:
        raise ValueError('SBML model exceeds the interactive computation budget')
    for name in ('comp','fbc','qual','multi','distrib','spatial','dyn','arrays'):
        if doc.isPackageEnabled(name):
            raise ValueError('Unsupported SBML package: '+name)
    if any(rule.isAlgebraic() for rule in model.getListOfRules()):
        raise ValueError('Algebraic SBML rules require a DAE engine and are not supported by this solver')
    total = [0]
    def check(node, depth=0):
        if node is None:return
        total[0]+=1
        if total[0]>20000 or depth>64:raise ValueError('SBML expression budget exceeded')
        if node.getType()==libsbml.AST_FUNCTION_DELAY:raise ValueError('Delay differential expressions require another solver')
        for i in range(node.getNumChildren()):check(node.getChild(i),depth+1)
    for element in model.getListOfAllElements():
        if hasattr(element,'isSetMath') and element.isSetMath():check(element.getMath())
    # Recursive function definitions cannot be lowered safely into finite LLVM
    # expressions. Reject them before handing a document to the native engine.
    functions={f.getId():f for f in model.getListOfFunctionDefinitions()}
    def names(node):
        if node is None:return set()
        return ({node.getName()} if node.isFunction() and node.getName() in functions else set()).union(*(names(node.getChild(i)) for i in range(node.getNumChildren())))
    edges={name:names(f.getMath()) for name,f in functions.items()}
    visited=set()
    def visit(name, stack):
        if name in stack:raise ValueError('Recursive SBML function definitions are unsupported')
        if name in visited:return
        for child in edges[name]:visit(child,stack|{name})
        visited.add(name)
    for name in edges:visit(name,set())
    return raw,model

def sbml_simulate(asset,operation,options):
    import roadrunner
    import numpy as np
    raw,model=validated_model(asset)
    end=finite_number(options.get('timeEnd',30),1e-9,1e6,'duration')
    points=bounded_integer(options.get('points',301),2,10001,'time points')
    if options.get('solver','cvode')!='cvode':raise ValueError('General SBML uses the CVODE solver')
    ids=[s.getId() for s in model.getListOfSpecies()]
    # Bare species selections are amounts in RoadRunner. Bracketed selections
    # would instead request concentrations; never silently mix the two.
    selections=['time']+ids
    units={s.getId():s.getSubstanceUnits() or model.getSubstanceUnits() or 'unspecified amount unit' for s in model.getListOfSpecies()}
    def calculate(parameter=None,value=None):
        rr=roadrunner.RoadRunner(raw)
        rr.setIntegrator('cvode')
        rr.integrator.relative_tolerance=1e-9
        rr.integrator.absolute_tolerance=1e-12
        rr.integrator.maximum_num_steps=20000
        if parameter is not None:rr[parameter]=value
        result=rr.simulate(0,end,points,selections=selections)
        array=np.asarray(result)
        if array.shape!=(points,len(selections)) or not np.isfinite(array).all():raise ValueError('SBML solver returned invalid or incomplete output')
        return array
    details=dict(engine='libRoadRunner '+roadrunner.__version__,solver='CVODE',timeUnit=model.getTimeUnits() or 'unspecified time unit',quantity='species amounts',speciesUnits=json.dumps(units),rules=str(model.getNumRules()),events=str(model.getNumEvents()),unsupported='algebraic rules, delay differential expressions and semantic extension packages')
    if operation=='net.sbml.sweep':
        parameter=options.get('parameter')
        if parameter not in {p.getId() for p in model.getListOfParameters()} or parameter in {r.getVariable() for r in model.getListOfRules() if r.isAssignment()}:
            raise ValueError('Choose a global parameter without an assignment rule')
        values=options.get('values',[])
        if not isinstance(values,list) or not 1<=len(values)<=32:raise ValueError('Sweep needs 1 to 32 parameter values')
        rows=[]
        for value in values:
            value=finite_number(value,0,1e12,'parameter value')
            data=calculate(parameter,value);rows.append([value]+data[-1,1:].tolist())
        return output('SBML parameter sweep',columns=[parameter]+ids,rows=rows,details=details)
    data=calculate()
    metrics={'points':points,**{'final_'+name:float(data[-1,i+1]) for i,name in enumerate(ids)}}
    return output('SBML time course',metrics,columns=selections,rows=data.tolist(),details=details)
