// SPDX-License-Identifier: MPL-2.0
// UV is an authoring part of the existing material service, never a second document.
import Foundation
import CoreFoundation
import simd

nonisolated struct CADUVViewSnapshot: Sendable {
    let record: CADUVRecord
    let source: RenderMesh
    let currentRender: RenderMesh
    let changeCount: Int
    let liveMeshSHA256: String
    let isStale: Bool
    let texture: Data?
    let textureOrientation: MaterialTextureOrientation
    let projectedMaterial: Bool
}

private nonisolated struct CADUVRequest: Sendable {
    let action: String
    let sourceSHA256: String?
    let expectedChangeCount: Int?
    let seams: [CADUVEdge]?
    let islandIDs: Set<UInt32>
    let translate: SIMD2<Float>
    let rotation: Float
    let scale: SIMD2<Float>
    let setID: UUID?
    let name: String?
    let rebase: Bool
    let resolution: UInt32
    let padding: UInt32
    let edgeOffset: Int
    let edgeLimit: Int
}

private nonisolated struct CADUVComputed: Sendable {
    let record: CADUVRecord
    let source: RenderMesh
    let render: RenderMesh
    let data: Data?
    let stale: Bool
    let liveSHA256: String
    let edges: [(CADUVEdge,[Int])]
}

@MainActor
final class CADUVService {
    nonisolated static let actions: [String] = ["uv.read","uv.seams","uv.unwrap","uv.pack","uv.transform",
                                    "uv.createSet","uv.activateSet","uv.removeSet","uv.status","uv.cancel"]
    nonisolated static let mutations: Set<String> = ["uv.seams","uv.unwrap","uv.pack","uv.transform",
                                         "uv.createSet","uv.activateSet","uv.removeSet"]
    private struct Run { let id: UUID; let cancellation: CADUVCancellation }
    private static var runs: [ObjectIdentifier:Run] = [:]
    nonisolated(unsafe) static var testBeforeCommitProbe: (@Sendable () -> Void)?
    private let document: FloeCADDocument
    private let wallClockLimitSeconds: Double
    init(document: FloeCADDocument, wallClockLimitSeconds: Double = CADUVOperationBudget.wallClockLimitSeconds) {
        self.document=document
        self.wallClockLimitSeconds = wallClockLimitSeconds.isFinite && wallClockLimitSeconds > 0
            ? wallClockLimitSeconds : CADUVOperationBudget.wallClockLimitSeconds
    }

    @discardableResult
    static func cancel(for document: FloeCADDocument) -> Bool {
        guard let run=runs[ObjectIdentifier(document)] else { return false }
        run.cancellation.cancel(); return true
    }
    func control(action: String) -> [String:Any] {
        if action == "uv.cancel" { return ["ok":true,"mutated":false,"cancel_requested":Self.cancel(for:document)] }
        return ["ok":true,"mutated":false,"active":Self.runs[ObjectIdentifier(document)] != nil]
    }

    func handle(action: String, args: [String:Any]) async -> [String:Any] {
        if action == "uv.status" || action == "uv.cancel" { return control(action:action) }
        do {
            guard !document.isClosed else { throw CADUVRecord.failure("document_closed", "Reopen the document before editing UVs.") }
            let request=try Self.request(action:action,args:args)
            let body=try resolveBody(args)
            if let raw=args["revision"] ?? args["expected_revision"] {
                guard let value=Self.integer(raw), value == document.revision else { throw CADUVRecord.failure("revision_mismatch", "Read the document again before editing UVs.") }
            }
            if Self.mutations.contains(action), let block=document.session.writeBlock { return Self.fail(CADUVFailure(code:block.code,message:block.message)) }
            let count=document.session.changeCount, revision=body.meshRevision
            let render=body.render, bytes=body.uvData
            if Self.mutations.contains(action) {
                guard request.expectedChangeCount == count else { throw CADUVRecord.failure("revision_mismatch", "Read the UV source again before applying this edit.") }
            }
            let cancellation=try CADUVCancellation(), key=ObjectIdentifier(document), id=UUID()
            if Self.mutations.contains(action) {
                guard Self.runs[key] == nil else { throw CADUVRecord.failure("uv_worker_busy", "A UV edit is already active for this document.") }
                Self.runs[key]=Run(id:id,cancellation:cancellation)
            }
            defer { if Self.runs[key]?.id == id { Self.runs[key]=nil } }
            let probe=Self.testBeforeCommitProbe, budget=self.wallClockLimitSeconds
            let worker=Task.detached(priority:.userInitiated) {
                let result=Result { try Self.compute(request:request,render:render,bytes:bytes,cancellation:cancellation,wallClockLimitSeconds:budget) }
                probe?()
                return result
            }
            let result=await withTaskCancellationHandler { await worker.value } onCancel: { cancellation.cancel(); worker.cancel() }
            let computed=try result.get()
            guard !cancellation.isCancelled, !Task.isCancelled else { throw CADUVRecord.failure("cancelled", "UV editing was cancelled.") }
            guard !document.isClosed else { throw CADUVRecord.failure("document_closed", "The document closed before the UV edit finished.") }
            guard document.session.changeCount == count,
                  let current=document.session.document.body(with:body.id), current.meshRevision == revision,
                  current.render == render, current.uvData == bytes else {
                throw CADUVRecord.failure("document_changed", "The source changed while UVs were being prepared; nothing was applied.")
            }
            var mutated=false
            if Self.mutations.contains(action), computed.data != bytes || computed.render != render {
                guard let block=document.session.writeBlock else {
                    mutated=document.session.performUVEdit(body:body,render:computed.render,data:computed.data)
                    return reply(action:action,bodyID:body.id,computed:computed,mutated:mutated,request:request)
                }
                return Self.fail(CADUVFailure(code:block.code,message:block.message))
            }
            return reply(action:action,bodyID:body.id,computed:computed,mutated:mutated,request:request)
        } catch { return Self.fail(error) }
    }

    /// UI consumes the SAME body record and service snapshot. Decoding, mesh
    /// validation and content hashing stay off the MainActor.
    func snapshot(bodyID: BodyID) async throws -> CADUVViewSnapshot {
        guard !document.isClosed, let body=document.session.document.body(with:bodyID) else { throw CADUVRecord.failure("unknown_body", "Select an existing body.") }
        let render=body.render, bytes=body.uvData, count=document.session.changeCount
        let record=try await Task.detached(priority:.userInitiated) {
            try bytes.map(CADUVRecord.decode) ?? CADUVRecord.make(source:render)
        }.value
        guard !document.isClosed, count == document.session.changeCount else { throw CADUVRecord.failure("document_changed", "The source changed. Refresh the UV editor.") }
        return CADUVViewSnapshot(record:record,source:try MeshBlob.decode(record.sourceMesh),currentRender:render,
            changeCount:count,liveMeshSHA256:CADUVRecord.sha(MeshBlob.encode(render)),isStale:!record.matches(render),texture:body.material?.baseColorTexture,
            textureOrientation:body.material?.textureOrientation(for:.baseColor) ?? .topLeft,
            projectedMaterial:body.material?.usesProjectedUVs == true || body.materialFaceBindings.contains { $0.material.usesProjectedUVs })
    }

    private func resolveBody(_ args: [String:Any]) throws -> Body {
        guard let text=(args["body_id"] ?? args["bodyID"]) as? String, let uuid=UUID(uuidString:text),
              let body=document.session.document.body(with:BodyID(raw:uuid)) else {
            throw CADUVRecord.failure("unknown_body", "body_id must name one existing body.")
        }
        return body
    }

    private nonisolated static func compute(request: CADUVRequest, render: RenderMesh, bytes: Data?,
                                            cancellation: CADUVCancellation, wallClockLimitSeconds: Double) throws -> CADUVComputed {
        if cancellation.isCancelled { throw CADUVRecord.failure("cancelled", "UV editing was cancelled.") }
        var record=try bytes.map(CADUVRecord.decode) ?? CADUVRecord.make(source:render)
        let stale = !record.matches(render)
        try CADUVRecord.validate(render)
        let liveSHA=CADUVRecord.sha(MeshBlob.encode(render))
        if mutations.contains(request.action) {
            let expected=(stale && request.action == "uv.unwrap" && request.rebase) ? liveSHA : record.sourceMeshSHA256
            guard request.sourceSHA256 == expected else { throw CADUVRecord.failure("uv_source_mismatch", "source_sha256 must match the UV source returned by uv.read.") }
            if stale {
                guard request.action == "uv.unwrap", request.rebase else { throw CADUVRecord.failure("uv_source_changed", "Geometry changed. The saved UV record is retained; unwrap the current mesh explicitly with rebase=true and live_mesh_sha256.") }
                record=try CADUVRecord.make(source:render)
            }
        }
        let source=try MeshBlob.decode(record.sourceMesh)
        var mapped=render
        switch request.action {
        case "uv.read": break
        case "uv.seams": record.seams=request.seams ?? []
        case "uv.unwrap","uv.pack":
            let set=try CADUVNative.generate(record:record,repacking:request.action == "uv.pack",
                resolution:request.resolution,padding:request.padding,cancellation:cancellation,wallClockLimitSeconds:wallClockLimitSeconds)
            if let i=record.sets.firstIndex(where: { $0.id == set.id }) { record.sets[i]=set }
            else {
                guard record.sets.count < CADUVRecord.maximumSets else { throw CADUVRecord.failure("uv_set_limit", "A body supports up to eight UV sets.") }
                record.sets.append(set)
            }
            record.activeSetID=set.id
            mapped=try record.render(using:set)
        case "uv.transform":
            let i=try setIndex(record,request.setID)
            record.sets[i]=try CADUVRecord.transformed(record.sets[i],islands:request.islandIDs,
                translate:request.translate,rotationDegrees:request.rotation,scale:request.scale)
            if record.sets[i].id == record.activeSetID { mapped=try record.render(using:record.sets[i]) }
        case "uv.createSet":
            let i=try setIndex(record,request.setID)
            guard record.sets.count < CADUVRecord.maximumSets else { throw CADUVRecord.failure("uv_set_limit", "A body supports up to eight UV sets.") }
            var set=record.sets[i]; set.id=UUID(); set.name=request.name ?? "UV \(record.sets.count+1)"
            record.sets.append(set)
        case "uv.activateSet":
            guard let id=request.setID else { throw CADUVRecord.failure("missing_uv_set", "set_id is required.") }
            let i=try setIndex(record,id); record.activeSetID=id; mapped=try record.render(using:record.sets[i])
        case "uv.removeSet":
            guard record.sets.count > 1, let id=request.setID else { throw CADUVRecord.failure("missing_uv_set", "Keep at least one UV set and name the set_id to remove.") }
            let i=try setIndex(record,id); record.sets.remove(at:i)
            if record.activeSetID == id { record.activeSetID=record.sets[0].id; mapped=try record.render(using:record.sets[0]) }
        default: throw CADUVRecord.failure("unknown_action", "Unknown UV action.")
        }
        if let seams=request.seams {
            let edges=try CADUVRecord.edgeFaces(source)
            guard Set(seams).count == seams.count, seams.allSatisfy({ edges[$0] != nil }) else { throw CADUVRecord.failure("invalid_uv_seam", "Every seam must be an edge of this exact source mesh.") }
        }
        if cancellation.isCancelled { throw CADUVRecord.failure("cancelled", "UV editing was cancelled.") }
        let data=mutations.contains(request.action) ? try record.encoded() : bytes
        return CADUVComputed(record:record,source:source,render:mapped,data:data,
                             stale:!record.matches(mapped),liveSHA256:liveSHA,
                             edges:try CADUVRecord.edgeFaces(source).sorted { $0.key < $1.key }.map { ($0.key,$0.value) })
    }

    private func reply(action: String, bodyID: BodyID, computed: CADUVComputed, mutated: Bool,
                       request: CADUVRequest) -> [String:Any] {
        let record=computed.record, set=record.activeSet
        let edges=computed.edges
        let offset=min(request.edgeOffset,edges.count), end=min(offset+request.edgeLimit,edges.count)
        let rows=edges[offset..<end].map { edge,faces -> [String:Any] in
            let a=computed.source.positions[Int(edge.a)], b=computed.source.positions[Int(edge.b)]
            return ["vertices":[edge.a,edge.b],"start":[a.x,a.y,a.z],"end":[b.x,b.y,b.z],
                    "faces":faces,"seam":record.seams.contains(edge)]
        }
        return ["ok":true,"action":action,"mutated":mutated,"exactness":"preserved",
                "body_id":bodyID.raw.uuidString,"revision":document.revision,"change_count":document.session.changeCount,
                "source_sha256":record.sourceMeshSHA256,"live_mesh_sha256":computed.liveSHA256,
                "source_changed":computed.stale,"needs_unwrap":computed.stale || set == nil || set?.seamSHA256 != record.seamSHA256,
                "active_set_id":record.activeSetID?.uuidString ?? "","seams":record.seams.map { [$0.a,$0.b] },
                "sets":record.sets.map { ["id":$0.id.uuidString,"name":$0.name,"island_count":Set($0.faceCharts).count,
                                         "actual_width":$0.atlasWidth,"actual_height":$0.atlasHeight] as [String:Any] },
                "island_ids":set.map { Array(Set($0.faceCharts)).sorted() } ?? [],
                "edges":rows,"edge_count":edges.count,"next_edge_offset":end < edges.count ? end : -1,
                "uv_export":"The active set is written to existing GLB TEXCOORD_0; all sets and seams remain in the native document.",
                "seam_policy":"Marked edge sides are separated; xatlas may introduce additional automatic cuts.",
                "can_undo":document.session.undoStack.canUndo,"can_redo":document.session.undoStack.canRedo]
    }

    private nonisolated static func setIndex(_ record: CADUVRecord, _ id: UUID?) throws -> Int {
        guard let id=id ?? record.activeSetID, let i=record.sets.firstIndex(where: { $0.id == id }) else { throw CADUVRecord.failure("unknown_uv_set", "Unwrap first, or choose an existing set_id.") }
        return i
    }
    private nonisolated static func request(action: String, args: [String:Any]) throws -> CADUVRequest {
        guard actions.contains(action) else { throw CADUVRecord.failure("unknown_action", "Unknown UV action.") }
        let common: Set<String>=["action","body_id","bodyID","revision","expected_revision","expected_change_count","source_sha256"]
        let fields: [String:Set<String>] = ["uv.read":["edge_offset","edge_limit"],"uv.seams":["seams"],
            "uv.unwrap":["resolution","padding","rebase"],"uv.pack":["resolution","padding"],
            "uv.transform":["set_id","island_ids","translate","rotation_degrees","scale"],
            "uv.createSet":["set_id","name"],"uv.activateSet":["set_id"],"uv.removeSet":["set_id"]]
        guard Set(args.keys).subtracting(common.union(fields[action] ?? [])).isEmpty else { throw CADUVRecord.failure("invalid_uv_args", "This UV action contains unknown fields.") }
        func integerField(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) throws -> Int {
            guard let raw=args[key] else { return fallback }
            guard let i=integer(raw), range.contains(i) else { throw CADUVRecord.failure("invalid_uv_args", "\(key) is outside its supported integer range.") }; return i
        }
        func vector(_ key: String, _ fallback: SIMD2<Float>) throws -> SIMD2<Float> {
            guard let raw=args[key] else { return fallback }
            guard let a=raw as? [Any], a.count == 2, let x=number(a[0]), let y=number(a[1]),
                  Float(x).isFinite, Float(y).isFinite else { throw CADUVRecord.failure("invalid_uv_args", "\(key) must contain two finite numbers.") }
            return SIMD2(Float(x),Float(y))
        }
        var seams: [CADUVEdge]?
        if let raw=args["seams"] {
            guard let pairs=raw as? [[Any]], pairs.count <= CADUVRecord.maximumTriangles*3 else { throw CADUVRecord.failure("invalid_uv_seam", "seams must be an array of source vertex pairs.") }
            seams=try pairs.map { pair in
                guard pair.count == 2, let a=integer(pair[0]), let b=integer(pair[1]), a >= 0, b >= 0,
                      a < CADUVRecord.maximumVertices, b < CADUVRecord.maximumVertices, a != b else { throw CADUVRecord.failure("invalid_uv_seam", "A seam needs two distinct source vertex indices.") }
                return CADUVEdge(UInt32(a),UInt32(b))
            }.sorted()
        } else if action == "uv.seams" { throw CADUVRecord.failure("invalid_uv_seam", "uv.seams requires the full seams array; [] clears it.") }
        var islands=Set<UInt32>()
        if let raw=args["island_ids"] {
            guard let values=raw as? [Any], values.count <= CADUVRecord.maximumTriangles else { throw CADUVRecord.failure("invalid_uv_args", "island_ids must be an array of island integers.") }
            for raw in values { guard let i=integer(raw), i >= 0, i < CADUVRecord.maximumTriangles else { throw CADUVRecord.failure("unknown_uv_island", "Invalid island id.") }; islands.insert(UInt32(i)) }
        }
        let setID: UUID?
        if let raw=args["set_id"] { guard let s=raw as? String, let id=UUID(uuidString:s) else { throw CADUVRecord.failure("unknown_uv_set", "set_id must be a UUID.") }; setID=id } else { setID=nil }
        var name: String?
        if let raw=args["name"] { guard let s=raw as? String, !s.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, s.count <= 64 else { throw CADUVRecord.failure("invalid_uv_args", "UV names need 1 to 64 characters.") }; name=s.trimmingCharacters(in:.whitespacesAndNewlines) }
        let rotation: Float
        if let raw=args["rotation_degrees"] { guard let n=number(raw), abs(n) <= 36000 else { throw CADUVRecord.failure("invalid_uv_transform", "rotation_degrees must be finite and within 36000 degrees.") }; rotation=Float(n) } else { rotation=0 }
        let rebase: Bool
        if let raw=args["rebase"] { guard let n=raw as? NSNumber, CFGetTypeID(n)==CFBooleanGetTypeID() else { throw CADUVRecord.failure("invalid_uv_args", "rebase must be true or false.") }; rebase=n.boolValue } else { rebase=false }
        return CADUVRequest(action:action,sourceSHA256:args["source_sha256"] as? String,
            expectedChangeCount:try args["expected_change_count"].map { raw in guard let n=integer(raw),n>=0 else { throw CADUVRecord.failure("bad_revision", "expected_change_count must be a nonnegative integer.") }; return n },
            seams:seams,islandIDs:islands,translate:try vector("translate",.zero),rotation:rotation,
            scale:try vector("scale",SIMD2(repeating:1)),setID:setID,name:name,rebase:rebase,
            resolution:UInt32(try integerField("resolution",512,64...2048)),padding:UInt32(try integerField("padding",2,0...32)),
            edgeOffset:try integerField("edge_offset",0,0...150000),edgeLimit:try integerField("edge_limit",100,1...200))
    }
    private nonisolated static func number(_ value: Any) -> Double? {
        guard let n=value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }; return n.doubleValue
    }
    private nonisolated static func integer(_ value: Any) -> Int? { number(value).flatMap(Int.init(exactly:)) }
    private static func fail(_ error: Error) -> [String:Any] {
        let failure=error as? CADUVFailure ?? CADUVFailure(code:"invalid_uv_record",message:error.localizedDescription)
        return ["ok":false,"mutated":false,"error":failure.code,"message":failure.message]
    }
}
