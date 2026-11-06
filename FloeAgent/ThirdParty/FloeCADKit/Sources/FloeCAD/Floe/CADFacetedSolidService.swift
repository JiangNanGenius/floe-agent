// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation

@MainActor
final class CADFacetedSolidService {
    nonisolated static let actions=["faceted.catalog","faceted.convert","recognition.inspect","recognition.create"]
    nonisolated static let mutations:Set<String>=["faceted.convert","recognition.create"]
    private static var active:[ObjectIdentifier:CADMeshCancellation]=[:]
    static func cancelActiveOperation(for document:FloeCADDocument)->Bool {
        guard let token=active[ObjectIdentifier(document)] else {return false};token.cancel();return true
    }
    static func activeOperationStatus(for document:FloeCADDocument)->[String:Any]? {
        guard let token=active[ObjectIdentifier(document)] else {return nil}
        return ["ok":true,"active":true,"action":"faceted","cancelRequested":token.isCancelled,"mutated":false]
    }
    private let document:FloeCADDocument
    init(document:FloeCADDocument){self.document=document}
    private nonisolated struct Plan:Sendable {
        let action:String,mesh:CADHybridMeshSource?,sheets:[CADFacetedSolidKernel.Sheet],tolerance:Double
        let watched:[BodyID:UInt64],changeCount:Int,hideSources:[BodyID]
    }
    private nonisolated struct Work:Sendable {
        let converted:CADFacetedSolidKernel.Result?
        let box:CADFacetedSolidKernel.BoxRecognition?
        let render:RenderMesh?
    }
    func handle(action:String,args:[String:Any])->[String:Any] {
        if action=="faceted.catalog" {return Self.catalog}
        return Self.failure(CADHybridFailure.unsupported("Use asynchronous execution for solid conversion and recognition."))
    }
    func handleAsync(action:String,args:[String:Any]) async -> [String:Any] {
        if action=="faceted.catalog" {return Self.catalog}
        do {
            let plan=try prepare(action,args),token=CADMeshCancellation(),owner=ObjectIdentifier(document)
            _=CADMeshService.cancelActiveOperation(for:document);Self.active[owner]=token
            defer {if Self.active[owner] === token {Self.active[owner]=nil}}
            let worker=Task.detached(priority:.userInitiated) { () -> Result<Work,CADHybridFailure> in
                do {
                    if plan.action=="faceted.convert" {
                        let value=try CADFacetedSolidKernel.convert(mesh:plan.mesh,sheets:plan.sheets,tolerance:plan.tolerance,cancellation:token)
                        return .success(.init(converted:value,box:nil,render:value.render))
                    }
                    guard let mesh=plan.mesh else {throw CADHybridFailure.unsupported("Recognition accepts a closed mesh or a solid.")}
                    let box=try CADFacetedSolidKernel.recognizeBox(mesh,cancellation:token)
                    let render:RenderMesh?
                    if let box,let handle=OCCTKernel.primitiveShape(box.spec,placement:box.placement) {
                        let buffers=OCCTKernel.renderMesh(from:handle)
                        render = .init(positions:buffers.positions,normals:buffers.normals,indices:buffers.indices)
                    } else { render=nil }
                    return .success(.init(converted:nil,box:box,render:render))
                } catch let error as CADHybridFailure {return .failure(error)}
                catch {return .failure(.kernel(error.localizedDescription))}
            }
            let result=await withTaskCancellationHandler {await worker.value} onCancel:{token.cancel();worker.cancel()}
            return try finish(plan,result.get(),args,token)
        } catch {return Self.failure(error)}
    }
    private func prepare(_ action:String,_ args:[String:Any]) throws -> Plan {
        guard !document.isClosed else {throw CADHybridFailure.invalid("The document is closed.")}
        let session=document.session
        if Self.mutations.contains(action),let block=session.writeBlock {throw CADHybridFailure.invalid(block.message)}
        guard session.document.features.rollbackIndex==nil else {throw CADHybridFailure.unsupported("Return the feature history to its end before conversion.")}
        var ids:[UUID]
        if let values=args["bodyIDs"] as? [String] {
            ids=try values.map {guard let id=UUID(uuidString:$0) else {throw CADHybridFailure.invalid("Select existing source bodies.")};return id}
        } else if let raw=args["bodyID"] as? String,let id=UUID(uuidString:raw) {ids=[id]}
        else {throw CADHybridFailure.invalid("Select a mesh or exact surface bodies.")}
        guard !ids.isEmpty,ids.count<=64,Set(ids).count==ids.count else {throw CADHybridFailure.invalid("Select one mesh or up to 64 exact surface bodies.")}
        let bodies=try ids.map {id -> Body in guard let body=session.document.body(with:BodyID(raw:id)) else {throw CADHybridFailure.invalid("A selected body no longer exists.")};return body}
        if Self.mutations.contains(action),bodies.contains(where:{$0.uvData != nil || $0.render.texcoords != nil || !$0.materialFaceBindings.isEmpty}),
           !(try Self.flag(args,"discardOutputUV",fallback:false)) {
            throw CADHybridFailure.unsupported("Explicitly allow an untextured derived solid. The original UVs and face materials are kept.")
        }
        let tolerance=try Self.number(args,"tolerance",fallback:0.00001)
        var mesh:CADHybridMeshSource?,sheets:[CADFacetedSolidKernel.Sheet]=[]
        if bodies.count==1,bodies[0].surfaceBRep==nil {
            let body=bodies[0]
            if action=="faceted.convert",body.brep != nil {throw CADHybridFailure.unsupported("This body is already a solid. Use its exact editing tools.")}
            mesh=try CADHybridMeshSource(capturing:body)
        } else {
            guard action=="faceted.convert",bodies.allSatisfy({$0.surfaceBRep != nil && $0.brep==nil}) else {throw CADHybridFailure.unsupported("Use one mesh, or select only exact surface bodies for sewing.")}
            for body in bodies {
                guard let handle=body.surfaceBRep,let fresh=OCCTKernel.independentSnapshot(handle),let data=OCCTKernel.serialize(fresh) else {throw CADHybridFailure.invalid("An exact surface could not be preserved for conversion.")}
                sheets.append(.init(id:body.id,data:data,placement:body.transform))
            }
        }
        if let mesh,args["sourceSHA256"] != nil,args["sourceSHA256"] as? String != mesh.sha256 {throw CADHybridFailure.invalid("The source changed after recognition. Inspect it again.")}
        if args["expectedChangeCount"] != nil,try Self.number(args,"expectedChangeCount") != Double(session.changeCount) {throw CADHybridFailure.invalid("The conversion preview is stale.")}
        if args["expectedRevision"] != nil,try Self.number(args,"expectedRevision") != Double(document.store.revision) {throw CADHybridFailure.invalid("The saved document changed after preview.")}
        if action=="recognition.create",args["candidate"] as? String != "axis-aligned-box" {throw CADHybridFailure.unsupported("The native recognition tool currently creates only a verified axis-aligned box.")}
        let hide=try Self.flag(args,"hideSource",fallback:true)
        return .init(action:action,mesh:mesh,sheets:sheets,tolerance:tolerance,
            watched:Dictionary(uniqueKeysWithValues:bodies.map{($0.id,$0.meshRevision)}),changeCount:session.changeCount,
            hideSources:hide ? bodies.filter{!$0.isHidden}.map(\.id):[])
    }
    private func finish(_ plan:Plan,_ value:Work,_ args:[String:Any],_ token:CADMeshCancellation) throws -> [String:Any] {
        try fence(plan,token)
        var reply:[String:Any]=["ok":true,"mutated":false,"action":plan.action,"sourceRetained":true,
            "sourceBodyIDs":plan.watched.keys.map{$0.raw.uuidString}.sorted(),"sourceSHA256":plan.mesh?.sha256 ?? "",
            "scope":"faceted boundary conversion; bounded box recognition; no automatic freeform reconstruction"]
        if let converted=value.converted {
            reply["representation"]=converted.representation;reply["exactness"]="solid";reply["faces"]=converted.faces;reply["toleranceMM"]=plan.tolerance
            reply["curvedSurfacesRecovered"]=false
        }
        if plan.action=="recognition.inspect" {
            if let box=value.box {
                reply["candidates"]=[["kind":"axis-aligned-box","sizeMM":[box.size.x,box.size.y,box.size.z],
                    "centerMM":[box.center.x,box.center.y,box.center.z],"verifiedVolumeMM3":box.sourceVolume]]
            } else {reply["candidates"]=[];reply["message"]="No supported primitive was recognized. The mesh is kept; use faceted conversion or manual reconstruction."}
            reply["recognitionComplete"]=false;return reply
        }
        guard let render=value.render,let hash=CADTransientMeshPreview.hash(of:[render]) else {throw CADHybridFailure.unsupported("No supported closed solid was recognized. The source was kept.")}
        if let expected=args["expectedPreviewHash"] as? String {
            guard expected==hash,try Self.number(args,"expectedChangeCount")==Double(plan.changeCount),
                  try Self.number(args,"expectedRevision")==Double(document.store.revision) else {throw CADHybridFailure.invalid("The conversion preview is stale.")}
        }
        if try Self.flag(args,"preview",fallback:false) {
            guard let snapshot=CADTransientMeshPreview.snapshot(of:[render]) else {throw CADHybridFailure.invalid("The solid preview is empty.")}
            reply.merge(["preview":true,"previewHash":hash,"previewChangeCount":plan.changeCount,
                "previewRevision":document.store.revision,"mesh":CADTransientMeshPreview.payload(snapshot)]) {_,new in new};return reply
        }
        let kind:FeatureKind,name:String
        if let converted=value.converted {
            kind = .baseSolid(source:converted.source);name=FloeCADStrings.text("cad.mesh.faceted.result","Converted solid")
        } else if let box=value.box {
            kind = .primitive(spec:box.spec,placement:box.placement);name=FloeCADStrings.text("cad.mesh.recognition.box","Recognized box")
        } else {throw CADHybridFailure.unsupported("No supported primitive was recognized.")}
        try fence(plan,token)
        let session=document.session,checkpoint=document.captureEditCheckpoint(),before=session.lastEvalErrors,id=BodyID()
        let sources=Dictionary(uniqueKeysWithValues:plan.watched.keys.compactMap {id in session.document.body(with:id).map{(id,$0)}})
        let node=FeatureNode(name:name,kind:kind,outputBodyIDs:[id])
        session.recordAndRebuild([node],extra:plan.hideSources.map{SetItemVisibilityCommand(item:.body($0),isHidden:true)},title:name)
        let preserved=sources.allSatisfy {id,source in
            guard let after=session.document.body(with:id) else {return false}
            return source.render==after.render && source.transform==after.transform && source.uvData==after.uvData
                && (source.brep != nil)==(after.brep != nil) && (source.surfaceBRep != nil)==(after.surfaceBRep != nil)
        }
        guard preserved,!session.lastEvalErrors.contains(where:{before[$0.key] != $0.value}),session.lastRebuildRejection.isEmpty,
              let body=session.document.body(with:id),body.brep?.containsSolid==true,!token.isCancelled,!Task.isCancelled else {
            document.restoreEditCheckpoint(checkpoint);throw CADHybridFailure.kernel("The solid could not rebuild. The original model and redo were kept.")
        }
        session.save();reply["mutated"]=true;reply["undoSteps"]=1;reply["bodyID"]=id.raw.uuidString;reply["featureID"]=node.id.raw.uuidString;return reply
    }
    private func fence(_ plan:Plan,_ token:CADMeshCancellation) throws {
        guard !token.isCancelled,!Task.isCancelled else {throw CADHybridFailure.cancelled}
        guard !document.isClosed,document.session.changeCount==plan.changeCount,
              plan.watched.allSatisfy({document.session.document.body(with:$0.key)?.meshRevision==$0.value}) else {throw CADHybridFailure.invalid("The document changed during conversion. The result was discarded.")}
        if Self.mutations.contains(plan.action),let block=document.session.writeBlock {throw CADHybridFailure.invalid(block.message)}
    }
    private static var catalog:[String:Any] { ["ok":true,"mutated":false,"backend":"OCCT 7.8.1 Sewing/MakeSolid/UnifySameDomain",
        "maxFacets":8192,"maxSheets":64,"requiresClosedBoundary":true,"fillsHoles":false,"sourceRetained":true,
        "recognitionCandidates":["axis-aligned-box"],"automaticFreeformRecovery":false] }
    private static func number(_ args:[String:Any],_ key:String,fallback:Double?=nil) throws -> Double {
        if args[key]==nil,let fallback {return fallback}
        guard let n=args[key] as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else {throw CADHybridFailure.invalid("\(key) must be a finite number.")};return n.doubleValue
    }
    private static func flag(_ args:[String:Any],_ key:String,fallback:Bool) throws -> Bool {
        guard let raw=args[key] else {return fallback}
        guard let n=raw as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else {throw CADHybridFailure.invalid("\(key) must be a Boolean.")};return n.boolValue
    }
    private static func failure(_ error:Error)->[String:Any] { ["ok":false,"mutated":false,"error":(error as? CADHybridFailure)?.code ?? "solid_conversion_failed","message":error.localizedDescription] }
}
