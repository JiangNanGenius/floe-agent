// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation

private actor CADMaterialGraphWorker {
    static let shared=CADMaterialGraphWorker()
    func compute(_ graph:CADMaterialNodeGraph,cancellation:CADMeshCancellation,external:(any MeshImportCancellationChecking)?,before:(@Sendable ()->Void)?,after:(@Sendable ()->Void)?) throws -> CADMaterialGraphComputed {
        before?();let result=try CADMaterialGraphKernel.compute(graph,cancellation:cancellation,external:external);after?();return result
    }
}
@MainActor final class CADMaterialGraphService {
    nonisolated static let stateDidChange=Notification.Name("FloeCADMaterialGraphStateDidChange")
    static let actions=["graph.get","graph.bake","graph.clear","graph.status","graph.cancel"]
    static let mutations:Set<String>=["graph.bake","graph.clear"]
    struct Run { let id:UUID;let cancellation:CADMeshCancellation }
    private static var runs:[ObjectIdentifier:Run]=[:]
    #if DEBUG
    static var testBeforeCompute:(@Sendable ()->Void)?
    static var testBeforeCommit:(@Sendable ()->Void)?
    #endif
    let document:FloeCADDocument
    init(document:FloeCADDocument) { self.document=document }
    static func cancel(for document:FloeCADDocument) { runs[ObjectIdentifier(document)]?.cancellation.cancel() }
    func control(_ action:String,_ args:[String:Any]) -> [String:Any] {
        guard Self.actions.contains(action),!document.isClosed else { return failure(CADMaterialGraphError.stale) }
        do { try pins(args) } catch { return failure(error) }
        let run=Self.runs[ObjectIdentifier(document)]
        if action=="graph.status" { return ["ok":true,"mutated":false,"active":run != nil,"run_id":run?.id.uuidString ?? "","cancel_requested":run?.cancellation.isCancelled ?? false] }
        if action=="graph.cancel" {
            guard let run else { return ["ok":true,"mutated":false,"cancel_requested":false] }
            guard args["run_id"] as? String==run.id.uuidString else { return failure(CADMaterialGraphError.stale) }
            run.cancellation.cancel();return ["ok":true,"mutated":false,"cancel_requested":true]
        }
        do { let body=try body(args),definition=CADMaterialDefinition(spec:body.material ?? .default)
            var row:[String:Any]=["ok":true,"mutated":false,"inputs":inputs(definition).map { ["id":$0.id.raw.uuidString,"slot":$0.slot.rawValue,"name":$0.name,"sha256":$0.sha256] as [String:Any] },"change_count":document.liveChangeCount]
            if let graph=definition.nodeGraph {
                var recipe=try JSONSerialization.jsonObject(with:JSONEncoder().encode(graph)) as! [String:Any]
                for key in ["images","recipeSHA256","bakedSHA256"] { recipe[key]=nil }
                row["graph"]=recipe;row["graph_id"]=graph.id.uuidString
            }
            return row
        } catch { return failure(error) }
    }
    func handle(_ action:String,_ args:[String:Any],external:(any MeshImportCancellationChecking)?) async -> [String:Any] {
        if !Self.mutations.contains(action) { return control(action,args) }
        do {
            guard !document.isClosed,!document.isReadOnly,document.session.writeBlock==nil,external?.isCancelled != true,!Task.isCancelled else { throw CADMaterialGraphError.cancelled }
            try pins(args)
            let key=ObjectIdentifier(document);guard Self.runs[key]==nil,Self.runs.count<2 else { throw CADMaterialGraphError.busy }
            let source=try body(args),count=document.liveChangeCount,original=source.material ?? .default
            if let raw=args["expected_change_count"] { guard let pin=raw as? NSNumber,CFGetTypeID(pin) != CFBooleanGetTypeID(),pin.doubleValue.isFinite,pin.doubleValue==Double(count) else { throw CADMaterialGraphError.stale } }
            var definition=CADMaterialDefinition(spec:original)
            if action=="graph.clear" {
                guard definition.nodeGraph != nil else { return ["ok":true,"mutated":false] }
                definition.nodeGraph=nil;var material=definition.bodyMaterialSpec();material.materialID=nil;try commit(source,material,external:external);return ["ok":true,"mutated":true]
            }
            guard let raw=args["graph"] as? [String:Any],Set(raw.keys).isSubset(of:["version","id","nodes","outputs","resolution"]) else { throw CADMaterialGraphError.invalid }
            guard let rows=raw["nodes"] as? [[String:Any]],(1...32).contains(rows.count),
                  let outputs=raw["outputs"] as? [String:Any],(1...3).contains(outputs.count),
                  try JSONSerialization.data(withJSONObject:raw).count<=128*1024 else { throw CADMaterialGraphError.budget }
            let available = inputs(definition)
            let used=Set(rows.compactMap { ($0["imageID"] as? String).flatMap(UUID.init(uuidString:)) })
            var graphRaw=raw;graphRaw["images"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(available.filter { used.contains($0.id.raw) }))
            let graph=try JSONDecoder().decode(CADMaterialNodeGraph.self,from:JSONSerialization.data(withJSONObject:graphRaw));try graph.validate()
            let runID=UUID(),cancellation=CADMeshCancellation();Self.runs[key]=Run(id:runID,cancellation:cancellation)
            NotificationCenter.default.post(name:Self.stateDidChange,object:document)
            defer { if Self.runs[key]?.id==runID { Self.runs[key]=nil;NotificationCenter.default.post(name:Self.stateDidChange,object:document) } }
            #if DEBUG
            let before=Self.testBeforeCompute,after=Self.testBeforeCommit
            #else
            let before:(@Sendable ()->Void)?=nil,after:(@Sendable ()->Void)?=nil
            #endif
            let captured=graph
            let worker=Task.detached(priority:.userInitiated) { try await CADMaterialGraphWorker.shared.compute(captured,cancellation:cancellation,external:external,before:before,after:after) }
            let result=try await withTaskCancellationHandler { try await worker.value } onCancel:{ cancellation.cancel();worker.cancel() }
            guard !cancellation.isCancelled,!Task.isCancelled,external?.isCancelled != true else { throw CADMaterialGraphError.cancelled }
            guard !document.isClosed,document.liveChangeCount==count,Self.runs[key]?.id==runID,
                  let current=document.session.document.body(with:source.id),current.material==source.material,current.uvData==source.uvData,current.meshRevision==source.meshRevision else { throw CADMaterialGraphError.stale }
            definition=result.applying(to:definition)
            var material=definition.bodyMaterialSpec();material.materialID=nil // edited snapshot detaches; library remains unchanged
            try commit(source,material,external:external)
            return ["ok":true,"mutated":true,"graph_id":result.graph.id.uuidString,"recipe_sha256":result.graph.recipeSHA256 ?? "","outputs_sha256":result.graph.bakedSHA256 ?? [:],"resolution":result.graph.resolution,"change_count":document.liveChangeCount]
        } catch { return failure(error) }
    }
    private func pins(_ args:[String:Any]) throws {
        for key in ["revision","expected_revision","expected_change_count"] {
            guard let raw=args[key] else { continue }
            guard let n=raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,n.doubleValue.rounded()==n.doubleValue,
                  n.doubleValue==Double(key=="expected_change_count" ? document.liveChangeCount:document.revision) else { throw CADMaterialGraphError.stale }
        }
    }
    private func inputs(_ definition:CADMaterialDefinition) -> [CADMaterialTexture] {
        var seen=Set<MaterialTextureID>()
        return (definition.textures + (definition.nodeGraph?.images ?? [])).filter { seen.insert($0.id).inserted }
    }
    private func body(_ args:[String:Any]) throws -> Body {
        guard let text=args["body_id"] as? String,let id=UUID(uuidString:text),let body=document.session.document.body(with:BodyID(raw:id)),body.materialFaceBindings.isEmpty else { throw CADMaterialGraphError.invalid };return body
    }
    private func commit(_ body:Body,_ material:BodyMaterialSpec,external:(any MeshImportCancellationChecking)?) throws {
        guard !document.isClosed,!document.isReadOnly,document.session.writeBlock==nil,!Task.isCancelled,external?.isCancelled != true else { throw CADMaterialGraphError.cancelled }
        document.session.perform(SetMaterialCommand(bodyIDs:[body.id],material:material,document:document.session.document))
        guard document.session.document.body(with:body.id)?.material==material else { throw CADMaterialGraphError.stale }
    }
    private func failure(_ error:Error) -> [String:Any] { ["ok":false,"mutated":false,"error":(error as? CADMaterialGraphError)?.rawValue ?? "invalid_material_graph","message":error.localizedDescription] }
}
