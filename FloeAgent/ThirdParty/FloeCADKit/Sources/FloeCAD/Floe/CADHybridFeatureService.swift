// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation
import simd

@MainActor
final class CADHybridFeatureService {
    nonisolated static let actions=["hybrid.catalog","hybrid.add","hybrid.update","hybrid.remove","hybrid.inspect"]
    nonisolated static let mutations:Set<String>=["hybrid.add","hybrid.update","hybrid.remove"]
    private static var active:[ObjectIdentifier:CADMeshCancellation]=[:]
    static func cancelActiveOperation(for document:FloeCADDocument)->Bool {
        guard let token=active[ObjectIdentifier(document)] else { return false };token.cancel();return true
    }
    static func activeOperationStatus(for document:FloeCADDocument)->[String:Any]? {
        guard let token=active[ObjectIdentifier(document)] else { return nil }
        return ["ok":true,"active":true,"action":"hybrid","mutated":false,"cancelRequested":token.isCancelled]
    }
    private let document:FloeCADDocument
    init(document:FloeCADDocument) { self.document=document }
    private nonisolated struct Plan:Sendable {
        let action:String,node:FeatureNode,bodyID:BodyID,definition:CADHybridFeatureDefinition,placement:Transform3D
        let creating:Bool,original:CADHybridFeatureDefinition?,existingRender:RenderMesh?
        let watched:[BodyID:UInt64],changeCount:Int,hideSources:[BodyID]
    }
    func handle(action:String,args:[String:Any])->[String:Any] {
        if action=="hybrid.catalog" { return Self.catalog }
        // User-facing heavy operations always use the joined off-main path.
        // Synchronous tool callers receive a concrete scheduling requirement.
        return Self.failure(CADHybridFailure.unsupported("Use asynchronous execution for hybrid modeling."))
    }
    func handleAsync(action:String,args:[String:Any]) async -> [String:Any] {
        if action=="hybrid.catalog" { return Self.catalog }
        do {
            let plan=try prepare(action,args),token=CADMeshCancellation(),owner=ObjectIdentifier(document)
            _=CADMeshService.cancelActiveOperation(for:document)
            Self.active[owner]=token
            defer { if Self.active[owner] === token { Self.active[owner]=nil } }
            let worker=Task.detached(priority:.userInitiated) { () -> Result<CADHybridMeshKernel.Evaluation,CADHybridFailure> in
                do {
                    if let original=plan.original,let expected=plan.existingRender {
                        let current=try CADHybridMeshKernel.evaluate(original,cancellation:token)
                        guard current.render==expected else { throw CADHybridFailure.unsupported("The derived mesh was edited directly. Its stored source cannot overwrite those edits.") }
                    }
                    return .success(try CADHybridMeshKernel.evaluate(plan.definition,cancellation:token))
                } catch let error as CADHybridFailure { return .failure(error) }
                catch { return .failure(.kernel(error.localizedDescription)) }
            }
            let result=await withTaskCancellationHandler { await worker.value } onCancel:{ token.cancel();worker.cancel() }
            return try finish(plan,result.get(),args,token)
        } catch { return Self.failure(error) }
    }
    private func prepare(_ action:String,_ args:[String:Any]) throws -> Plan {
        guard !document.isClosed else { throw CADHybridFailure.invalid("The document is closed.") }
        let session=document.session
        if Self.mutations.contains(action),let block=session.writeBlock { throw CADHybridFailure.invalid(block.message) }
        guard session.document.features.rollbackIndex==nil else { throw CADHybridFailure.unsupported("Return the feature history to its end before hybrid editing.") }
        if args["expectedChangeCount"] != nil,try Self.number(args,"expectedChangeCount") != Double(session.changeCount) {
            throw CADHybridFailure.invalid("The document changed after preview. Preview again.")
        }
        if args["expectedRevision"] != nil,try Self.number(args,"expectedRevision") != Double(document.store.revision) {
            throw CADHybridFailure.invalid("The saved document changed after preview. Preview again.")
        }
        _=try Self.flag(args,"preview",fallback:false)
        let requested=BodyID(raw:try Self.uuid(args,"bodyID"))
        guard let body=session.document.body(with:requested) else { throw CADHybridFailure.invalid("Select an existing mesh or solid.") }
        guard body.surfaceBRep==nil else { throw CADHybridFailure.unsupported(ExactSurfaceBoundary.refusal("Hybrid modeling",bodyName:body.name)) }
        let graph=session.document.features
        let writer=session.lastBodyWriters[requested]
        let candidate=writer.flatMap { id in graph.nodes.last { $0.id==id && !$0.suppressed } }
            ?? graph.nodes.last { !$0.suppressed && $0.outputBodyIDs.contains(requested) }
        let original:CADHybridFeatureDefinition?,placement:Transform3D,node:FeatureNode,output:BodyID,creating:Bool
        var definition:CADHybridFeatureDefinition
        if let candidate,case let .hybrid(stored,storedPlacement)=candidate.kind {
            guard candidate.outputBodyIDs==[requested],body.brep==nil,body.transform==storedPlacement else { throw CADHybridFailure.unsupported("Select the latest unchanged hybrid result.") }
            if action != "hybrid.inspect",args["definitionDigest"] as? String != stored.digest { throw CADHybridFailure.invalid("Inspect the current hybrid history before editing it.") }
            definition=stored;original=stored;placement=storedPlacement;node=candidate;output=requested;creating=false
        } else {
            guard action=="hybrid.add" else { throw CADHybridFailure.unsupported("Select a hybrid result to inspect or edit its features.") }
            try Self.checkOutputLoss(body,args)
            if body.brep != nil,!(try Self.flag(args,"allowMeshResult",fallback:false)) {
                throw CADHybridFailure.unsupported("This mixed operation creates a derived mesh. Explicitly allow a mesh result; the exact solid is kept.")
            }
            definition=CADHybridFeatureDefinition(source:try CADHybridMeshSource(capturing:body),operations:[],
                discardOutputUV:try Self.flag(args,"discardOutputUV",fallback:false))
            placement = .identity;original=nil;output=BodyID();creating=true
            node=FeatureNode(name:FloeCADStrings.text("cad.mesh.hybrid.result","Hybrid result"),
                kind:.hybrid(definition:definition,placement:placement),outputBodyIDs:[output])
        }
        var watched=[requested:body.meshRevision],hideSources:[BodyID]=[]
        switch action {
        case "hybrid.add","hybrid.update":
            let operation=try makeOperation(args,watched:&watched)
            if action=="hybrid.update" {
                let id=try Self.uuid(args,"operationID")
                guard let index=definition.operations.firstIndex(where:{$0.id==id}) else { throw CADHybridFailure.invalid("Select an existing hybrid feature.") }
                var edited=operation;edited.id=id;definition.operations[index]=edited
            } else { definition.operations.append(operation) }
            if creating,try Self.flag(args,"hideSource",fallback:true),!body.isHidden { hideSources.append(requested) }
            if case let .body(tool)=operation.tool,try Self.flag(args,"hideTool",fallback:true),
               let live=session.document.body(with:tool.sourceBodyID),!live.isHidden { hideSources.append(live.id) }
        case "hybrid.remove":
            let id=try Self.uuid(args,"operationID")
            guard definition.operations.count>1,definition.operations.contains(where:{$0.id==id}) else {
                throw CADHybridFailure.invalid("Keep at least one feature, or remove the complete hybrid history from the feature panel.")
            }
            definition.operations.removeAll { $0.id==id }
        case "hybrid.inspect":break
        default:throw CADHybridFailure.invalid("Unknown hybrid action.")
        }
        if let original,definition==original,action != "hybrid.inspect" { throw CADHybridFailure.invalid("The hybrid parameters did not change.") }
        return .init(action:action,node:node,bodyID:output,definition:definition,placement:placement,creating:creating,
            original:original,existingRender:original == nil ? nil : body.render,watched:watched,changeCount:session.changeCount,hideSources:hideSources)
    }
    private func makeOperation(_ args:[String:Any],watched:inout [BodyID:UInt64]) throws -> CADHybridOperation {
        guard let raw=args["kind"] as? String,let kind=CADHybridOperation.Kind(rawValue:raw) else { throw CADHybridFailure.invalid("Choose Hole, Cut, Boss or a Boolean operation.") }
        let tool:CADHybridOperation.Tool
        if args["toolBodyID"] != nil {
            let id=BodyID(raw:try Self.uuid(args,"toolBodyID"))
            guard let body=document.session.document.body(with:id),body.surfaceBRep==nil else { throw CADHybridFailure.unsupported("The mixed tool must be a closed solid or a closed mesh.") }
            guard watched[id]==nil else { throw CADHybridFailure.invalid("The target cannot also be its own tool.") }
            try Self.checkOutputLoss(body,args)
            if body.brep != nil,!(try Self.flag(args,"allowMeshResult",fallback:false)) { throw CADHybridFailure.unsupported("Explicitly allow a derived mesh for the mixed Boolean; the exact tool is kept.") }
            watched[id]=body.meshRevision;tool = .body(try CADHybridMeshSource(capturing:body))
        } else if args["shape"] as? String == "box" {
            tool = .box(size:try Self.vector(args,"size"),center:try Self.vector(args,"center"))
        } else {
            let segments=try Self.number(args,"segments",fallback:64)
            guard segments.rounded()==segments,(12...256).contains(segments) else { throw CADHybridFailure.invalid("Use 12–256 cylinder segments.") }
            tool = .cylinder(radius:try Self.number(args,"radius"),height:try Self.number(args,"depth"),
                center:try Self.vector(args,"center"),axis:try Self.vector(args,"axis",fallback:SIMD3(0,0,1)),segments:Int(segments))
        }
        let operation=CADHybridOperation(kind:kind,tool:tool);try operation.validate();return operation
    }
    private func fence(_ plan:Plan,_ token:CADMeshCancellation) throws {
        guard !token.isCancelled,!Task.isCancelled else { throw CADHybridFailure.cancelled }
        guard !document.isClosed,document.session.changeCount==plan.changeCount,
              plan.watched.allSatisfy({ document.session.document.body(with:$0.key)?.meshRevision==$0.value }) else {
            throw CADHybridFailure.invalid("The document changed while modeling. The result was discarded.")
        }
        if Self.mutations.contains(plan.action),let block=document.session.writeBlock { throw CADHybridFailure.invalid(block.message) }
    }
    private func finish(_ plan:Plan,_ value:CADHybridMeshKernel.Evaluation,_ args:[String:Any],_ token:CADMeshCancellation) throws -> [String:Any] {
        try fence(plan,token)
        guard let hash=CADTransientMeshPreview.hash(of:[value.render]) else { throw CADHybridFailure.invalid("The hybrid result has no valid preview.") }
        var reply=value.payload
        let definitionJSON=try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan.definition))
        reply.merge(["ok":true,"mutated":false,"action":plan.action,"bodyID":plan.bodyID.raw.uuidString,
            "featureID":plan.node.id.raw.uuidString,"sourceBodyID":plan.definition.source.sourceBodyID.raw.uuidString,
            "sourceSHA256":plan.definition.source.sha256,"sourceBodyPresent":document.session.document.body(with:plan.definition.source.sourceBodyID) != nil,
            "definitionDigest":plan.definition.digest,"definition":definitionJSON,"featureCount":plan.definition.operations.count]) { _,new in new }
        if plan.action=="hybrid.inspect" { return reply }
        if let expected=args["expectedPreviewHash"] as? String {
            guard expected==hash,try Self.number(args,"expectedChangeCount")==Double(plan.changeCount),
                  try Self.number(args,"expectedRevision")==Double(document.store.revision) else { throw CADHybridFailure.invalid("The preview is stale. Preview this operation again.") }
        }
        if try Self.flag(args,"preview",fallback:false) {
            guard let snapshot=CADTransientMeshPreview.snapshot(of:[value.render]) else { throw CADHybridFailure.invalid("The hybrid preview is empty.") }
            reply.merge(["preview":true,"previewHash":hash,"previewRevision":document.store.revision,
                "previewChangeCount":plan.changeCount,"mesh":CADTransientMeshPreview.payload(snapshot)]) { _,new in new }
            if plan.creating { reply.removeValue(forKey:"bodyID");reply.removeValue(forKey:"featureID") }
            return reply
        }
        try fence(plan,token)
        let session=document.session,checkpoint=document.captureEditCheckpoint(),beforeErrors=session.lastEvalErrors
        let sources=Dictionary(uniqueKeysWithValues:plan.watched.keys.compactMap { id in session.document.body(with:id).map { (id,$0) } })
        let kind=FeatureKind.hybrid(definition:plan.definition,placement:plan.placement)
        if plan.creating {
            var node=plan.node;node.kind=kind
            session.recordAndRebuild([node],extra:plan.hideSources.map { SetItemVisibilityCommand(item:.body($0),isHidden:true) },
                title:FloeCADStrings.text("cad.mesh.hybrid.addUndo","Add hybrid feature"))
        } else { session.editFeature(plan.node.id,to:kind,title:FloeCADStrings.text("cad.mesh.hybrid.editUndo","Edit hybrid feature")) }
        let introduced=session.lastEvalErrors.contains { id,error in beforeErrors[id] != error }
        let preserved=sources.allSatisfy { id,source in
            if id==plan.bodyID { return true }
            guard let after=session.document.body(with:id) else { return false }
            return source.render==after.render && source.transform==after.transform && (source.brep != nil)==(after.brep != nil)
                && source.uvData==after.uvData && source.materialFaceBindings==after.materialFaceBindings
        }
        guard !introduced,preserved,session.lastRebuildRejection.isEmpty,
              let body=session.document.body(with:plan.bodyID),body.brep==nil,body.surfaceBRep==nil,body.render==value.render,
              !token.isCancelled,!Task.isCancelled else {
            document.restoreEditCheckpoint(checkpoint);throw CADHybridFailure.kernel("The hybrid feature could not rebuild. The model and redo were kept.")
        }
        session.save();reply["mutated"]=true;reply["undoSteps"]=1;return reply
    }
    private static func checkOutputLoss(_ body:Body,_ args:[String:Any]) throws {
        if body.uvData != nil || body.render.texcoords != nil || !body.materialFaceBindings.isEmpty {
            guard try flag(args,"discardOutputUV",fallback:false) else { throw CADHybridFailure.unsupported("Explicitly allow an untextured derived mesh before changing textured topology. The original UVs and face materials are kept.") }
        }
    }
    private static var catalog:[String:Any] { ["ok":true,"mutated":false,"algorithm":CADHybridFeatureDefinition.algorithmV1,
        "operations":["hole","cut","boss","union","subtract","intersect"],"maxInputTriangles":500_000,"maxFeatures":32,
        "sourceRetained":true,"parameterReplay":true,"exactness":"mesh","supportsMixedSolidTools":true,"wallClockSeconds":30] }
    private static func uuid(_ args:[String:Any],_ key:String) throws -> UUID {
        guard let raw=args[key] as? String,let id=UUID(uuidString:raw) else { throw CADHybridFailure.invalid("Select an existing \(key).") };return id
    }
    private static func flag(_ args:[String:Any],_ key:String,fallback:Bool) throws -> Bool {
        guard let value=args[key] else { return fallback }
        guard let number=value as? NSNumber,CFGetTypeID(number)==CFBooleanGetTypeID() else { throw CADHybridFailure.invalid("\(key) must be a Boolean.") };return number.boolValue
    }
    private static func number(_ args:[String:Any],_ key:String,fallback:Double?=nil) throws -> Double {
        if args[key]==nil,let fallback {return fallback}
        guard let value=args[key] as? NSNumber,CFGetTypeID(value) != CFBooleanGetTypeID(),value.doubleValue.isFinite else { throw CADHybridFailure.invalid("\(key) must be a finite number.") };return value.doubleValue
    }
    private static func vector(_ args:[String:Any],_ key:String,fallback:SIMD3<Double>?=nil) throws -> SIMD3<Double> {
        if args[key]==nil,let fallback {return fallback}
        guard let values=args[key] as? [Any],values.count==3 else { throw CADHybridFailure.invalid("\(key) must contain three numbers.") }
        return SIMD3(try number(["v":values[0]],"v"),try number(["v":values[1]],"v"),try number(["v":values[2]],"v"))
    }
    private static func failure(_ error:Error)->[String:Any] {
        ["ok":false,"mutated":false,"error":(error as? CADHybridFailure)?.code ?? "invalid_hybrid_request","message":error.localizedDescription]
    }
}
