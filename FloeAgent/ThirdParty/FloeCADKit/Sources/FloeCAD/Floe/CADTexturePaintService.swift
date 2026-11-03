// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation

nonisolated struct CADTexturePaintViewSnapshot:Sendable {
    let mesh:RenderMesh
    let png:Data
    let sourceSHA256:String
    let changeCount:Int
    let width:Int
    let height:Int
    let storedTextureSHA256:String?
}
private actor CADTexturePaintWorker {
    static let shared=CADTexturePaintWorker()
    func compute(_ source:CADTexturePaintSource,request:CADTexturePaintRequest,cancellation:CADMeshCancellation,
                 before:(@Sendable ()->Void)?,after:(@Sendable ()->Void)?)throws->CADTexturePaintComputed {
        before?()
        let value=try CADTexturePaintKernel.compute(source,request:request,budget:CADTexturePaintBudget(cancellation:cancellation))
        after?();return value
    }
}
@MainActor final class CADTexturePaintService {
    nonisolated static let actions=["paint.read","paint.stroke","paint.bakeAO","paint.status","paint.cancel"]
    nonisolated static let mutations:Set<String>=["paint.stroke","paint.bakeAO"]
    private struct Run { let id:UUID;let cancellation:CADMeshCancellation }
    private static var runs:[ObjectIdentifier:Run]=[:]
    #if DEBUG
    static var testBeforeCompute:(@Sendable ()->Void)?
    static var testBeforeCommit:(@Sendable ()->Void)?
    #endif
    private let document:FloeCADDocument
    init(document:FloeCADDocument) { self.document=document }
    static func cancel(for document:FloeCADDocument)->Bool {
        guard let run=runs[ObjectIdentifier(document)] else { return false };run.cancellation.cancel();return true
    }
    func control(action:String)->[String:Any] {
        if action=="paint.cancel" { return ["ok":true,"mutated":false,"cancel_requested":Self.cancel(for:document)] }
        return ["ok":true,"mutated":false,"active":Self.runs[ObjectIdentifier(document)] != nil]
    }
    private func fail(_ error:Error)->[String:Any] {
        let code=(error as? CADTexturePaintFailure)?.code ?? (error as? CADUVFailure)?.code ?? "texture_edit_failed"
        return ["ok":false,"mutated":false,"error":code,
            "message":FloeCADStrings.text("cad.paint.failed","Texture editing didn't finish. Your material is unchanged."),"details":[error.localizedDescription]]
    }
    private static func number(_ raw:Any?)->Double? {
        guard let n=raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else { return nil };return n.doubleValue
    }
    private static func integer(_ raw:Any?)->Int? { number(raw).flatMap { Int(exactly:$0) } }
    private func body(_ args:[String:Any])throws->Body {
        guard let text=args["body_id"] as? String,let uuid=UUID(uuidString:text),let body=document.session.document.body(with:BodyID(raw:uuid)) else {
            throw CADTexturePaintKernel.fail("unknown_body","Choose one existing body_id.")
        }
        guard body.materialFaceBindings.isEmpty else { throw CADTexturePaintKernel.fail("paint_face_materials","Painting currently requires a whole-body material without per-face assignments.") }
        return body
    }
    private func request(_ action:String,_ args:[String:Any])throws->CADTexturePaintRequest {
        let common:Set<String>=["action","body_id","revision","expected_revision","expected_change_count","source_sha256"]
        let specific:[String:Set<String>]=["paint.read":["triangle_offset","triangle_limit","resolution"],
            "paint.stroke":["hits","radius_pixels","color_srgb","opacity","resolution"],
            "paint.bakeAO":["resolution","samples","max_distance_mm","occluder_body_ids"]]
        guard let fields=specific[action],Set(args.keys).subtracting(common.union(fields)).isEmpty else { throw CADTexturePaintKernel.fail("invalid_paint_args","Unknown texture action or unsupported fields.") }
        var value=CADTexturePaintRequest(kind:action=="paint.read" ? .read : (action=="paint.stroke" ? .stroke : .ao))
        if let raw=args["resolution"] {
            guard let r=Self.integer(raw),[64,128,256,512,1024].contains(r),action != "paint.bakeAO" || r<=256 else { throw CADTexturePaintKernel.fail("invalid_paint_resolution","Choose 64, 128, 256, 512 or 1024 pixels; AO supports up to 256.") };value.resolution=r
        }
        if action=="paint.read" {
            if let raw=args["triangle_offset"] { guard let n=Self.integer(raw),n>=0 else { throw CADTexturePaintKernel.fail("invalid_triangle_page","triangle_offset must be a nonnegative integer.") } }
            if let raw=args["triangle_limit"] { guard let n=Self.integer(raw),(1...64).contains(n) else { throw CADTexturePaintKernel.fail("invalid_triangle_page","triangle_limit must be 1–64.") } }
        }
        if action=="paint.stroke" {
            guard let rows=args["hits"] as? [[String:Any]],(1...128).contains(rows.count) else { throw CADTexturePaintKernel.fail("invalid_paint_hits","A stroke needs 1–128 current triangle hits.") }
            value.hits=try rows.map { row in
                guard Set(row.keys)==Set(["triangle","barycentric"]),let triangle=Self.integer(row["triangle"]),let w=row["barycentric"] as? [Any],w.count==3,
                      let x=Self.number(w[0]),let y=Self.number(w[1]),let z=Self.number(w[2]) else { throw CADTexturePaintKernel.fail("invalid_paint_hit","Use {triangle,barycentric:[w0,w1,w2]} hits.") }
                return .init(triangle:triangle,barycentric:SIMD3(x,y,z))
            }
            guard let color=args["color_srgb"] as? [Any],color.count==4,let r=Self.number(color[0]),let g=Self.number(color[1]),let b=Self.number(color[2]),let a=Self.number(color[3]),
                  [r,g,b,a].allSatisfy({(0...1).contains($0)}) else { throw CADTexturePaintKernel.fail("invalid_paint_color","color_srgb needs four values from zero to one.") }
            value.color=SIMD4(r,g,b,a)
            if let raw=args["radius_pixels"] { guard let r=Self.number(raw),(1...64).contains(r) else { throw CADTexturePaintKernel.fail("invalid_brush_radius","Brush radius must be 1–64 pixels.") };value.radius=r }
            if let raw=args["opacity"] { guard let opacity=Self.number(raw),(0...1).contains(opacity) else { throw CADTexturePaintKernel.fail("invalid_brush_opacity","Brush opacity must be zero to one.") };value.opacity=opacity }
        }
        if action=="paint.bakeAO" {
            if let raw=args["samples"] { guard let n=Self.integer(raw),[8,16,32].contains(n) else { throw CADTexturePaintKernel.fail("invalid_bake_samples","AO accepts 8, 16 or 32 hemisphere samples.") };value.samples=n }
            if let raw=args["max_distance_mm"] { guard let d=Self.number(raw),d>0,d<=100000 else { throw CADTexturePaintKernel.fail("invalid_bake_distance","Choose a positive AO distance up to 100000 mm.") };value.maxDistance=d }
        }
        return value
    }
    private func source(_ target:Body,_ args:[String:Any])throws->CADTexturePaintSource {
        var occluders:[CADTexturePaintGeometry]=[]
        if let raw=args["occluder_body_ids"] {
            guard let ids=raw as? [String],ids.count<=31,Set(ids).count==ids.count else { throw CADTexturePaintKernel.fail("invalid_bake_occluders","Use at most 31 unique occluder body IDs.") }
            for text in ids {
                guard let id=UUID(uuidString:text),let body=document.session.document.body(with:BodyID(raw:id)),body.id != target.id else { throw CADTexturePaintKernel.fail("invalid_bake_occluders","Every extra occluder must be a different existing body.") }
                occluders.append(.init(mesh:body.render,transform:body.transform))
            }
        }
        return .init(mesh:target.render,transform:target.transform,material:target.material ?? .default,uvData:target.uvData,occluders:occluders)
    }
    private func calculate(_ target:Body,args:[String:Any],request:CADTexturePaintRequest)async throws->CADTexturePaintComputed {
        let key=ObjectIdentifier(document),id=UUID(),cancellation=CADMeshCancellation()
        guard Self.runs[key]==nil,Self.runs.count<2 else { throw CADTexturePaintKernel.fail("texture_worker_busy","A texture edit is finishing. Try again after it stops.") }
        let source=try source(target,args),count=document.session.changeCount
        let occluderTexts=args["occluder_body_ids"] as? [String] ?? []
        let pinnedOccluders=occluderTexts.compactMap { text->Body? in
            guard let id=UUID(uuidString:text) else { return nil };return document.session.document.body(with:BodyID(raw:id))
        }
        Self.runs[key]=Run(id:id,cancellation:cancellation)
        defer { if Self.runs[key]?.id==id { Self.runs[key]=nil } }
        #if DEBUG
        let before=Self.testBeforeCompute,after=Self.testBeforeCommit
        #else
        let before:(@Sendable ()->Void)?=nil,after:(@Sendable ()->Void)?=nil
        #endif
        let worker=Task.detached(priority:.userInitiated) { try await CADTexturePaintWorker.shared.compute(source,request:request,cancellation:cancellation,before:before,after:after) }
        let result=try await withTaskCancellationHandler { try await worker.value } onCancel: { cancellation.cancel();worker.cancel() }
        guard !cancellation.isCancelled,!Task.isCancelled else { throw CADTexturePaintKernel.fail("cancelled","The cancelled result was discarded.") }
        guard !document.isClosed else { throw CADTexturePaintKernel.fail("document_closed","The document closed. The result was discarded.") }
        guard document.session.changeCount==count,let current=document.session.document.body(with:target.id),
              current.render==target.render,current.meshRevision==target.meshRevision,current.transform==target.transform,current.uvData==target.uvData,
              current.material==target.material,current.materialFaceBindings==target.materialFaceBindings else {
            throw CADTexturePaintKernel.fail("document_changed","The body or material changed during calculation. Nothing was applied.")
        }
        for previous in pinnedOccluders {
            guard let current=document.session.document.body(with:previous.id),current.meshRevision==previous.meshRevision,
                  current.render==previous.render,current.transform==previous.transform else { throw CADTexturePaintKernel.fail("document_changed","An occluder changed during calculation. Nothing was applied.") }
        }
        return result
    }
    func handle(action:String,args:[String:Any])async->[String:Any] {
        if action=="paint.status" || action=="paint.cancel" { return control(action:action) }
        if let refusal=CADServiceOperations.readOnlyRefusal(document:document,kind:"material",action:action) { return refusal }
        do {
            guard !document.isClosed else { throw CADTexturePaintKernel.fail("document_closed","Reopen the document before texture editing.") }
            let request=try request(action,args),body=try body(args),count=document.session.changeCount
            for key in ["revision","expected_revision"] where args[key] != nil {
                guard Self.integer(args[key])==document.revision else { throw CADTexturePaintKernel.fail("revision_mismatch","Read the current document before editing.") }
            }
            if Self.mutations.contains(action) {
                guard Self.integer(args["expected_change_count"])==count,let hash=args["source_sha256"] as? String,
                      hash==CADUVRecord.sha(MeshBlob.encode(body.render)) else { throw CADTexturePaintKernel.fail("paint_source_mismatch","Read paint.read again and use its source_sha256 and change_count.") }
            }
            let result=try await calculate(body,args:args,request:request)
            guard !Task.isCancelled else { throw CADTexturePaintKernel.fail("cancelled","The cancelled result was discarded.") }
            var mutated=false
            if Self.mutations.contains(action),(result.changedPixels>0 || (action=="paint.bakeAO" && body.material?.baseColorTexture==nil)) {
                if let block=document.session.writeBlock { return ["ok":false,"mutated":false,"error":block.code,"message":block.message] }
                let command=SetMaterialAppearanceCommand(title:FloeCADStrings.text(action=="paint.stroke" ? "cad.paint.strokeCommand" : "cad.paint.bakeCommand",action=="paint.stroke" ? "Paint Texture" : "Bake Occlusion"),
                    bodyIDs:[body.id],after:[body.id:.init(material:result.material,faceBindings:body.materialFaceBindings)],document:document.session.document)
                document.session.perform(command);mutated=document.session.changeCount != count
            }
            var reply:[String:Any]=["ok":true,"action":action,"mutated":mutated,"body_id":body.id.raw.uuidString,
                "revision":document.revision,"change_count":document.session.changeCount,"source_sha256":result.sourceSHA256,
                "texture_sha256":CADMaterialTexture.digest(result.png),"width":result.width,"height":result.height,
                "changed_pixels":result.changedPixels,"covered_pixels":result.coveredPixels,"rays":result.rays,"occluded_rays":result.occludedRays,
                "geometry":"preserved","paint_scope":"whole-body baseColor; flattened raster; source triangle hit mapped to its UV island",
                "bake_scope":"current world-space triangle mesh AO, cosine hemisphere rays; multiplied into baseColor in linear space; alpha/other PBR slots preserved",
                "exchange":"GLB baseColor PNG + existing TEXCOORD_0; AO is flattened color, not a separate occlusion channel",
                "unsupported":["texture_layers","normal_bake","high_low_transfer","projected_or_overlapping_uv","face_material_paint"],
                "can_undo":document.session.undoStack.canUndo,"can_redo":document.session.undoStack.canRedo]
            reply["texture_sha256"]=document.session.document.body(with:body.id)?.material?.baseColorTexture.map { CADMaterialTexture.digest($0) as Any } ?? NSNull()
            if action=="paint.read" {
                reply["preview_texture_sha256"]=CADMaterialTexture.digest(result.png)
                let offset=Self.integer(args["triangle_offset"]) ?? 0,limit=Self.integer(args["triangle_limit"]) ?? 32
                guard offset>=0,(1...64).contains(limit) else { throw CADTexturePaintKernel.fail("invalid_triangle_page","Use a nonnegative triangle_offset and triangle_limit from 1 to 64.") }
                let start=min(offset,body.render.triangleCount),end=min(body.render.triangleCount,start+limit)
                reply["triangles"]=(start..<end).map { f -> [String:Any] in
                    let ids=(0..<3).map { Int(body.render.indices[f*3+$0]) }
                    return ["triangle":f,"positions":ids.map { i in let p=body.render.positions[i];return [p.x,p.y,p.z] },
                        "uv":ids.map { i in let uv=body.render.texcoords![i];return [uv.x,uv.y] }]
                }
                reply["triangle_count"]=body.render.triangleCount;reply["next_triangle_offset"]=end<body.render.triangleCount ? end : -1
            }
            return reply
        } catch { return fail(error) }
    }
    func snapshot(bodyID:BodyID,resolution:Int=128)async throws->CADTexturePaintViewSnapshot {
        guard !document.isClosed else { throw CADTexturePaintKernel.fail("document_closed","Reopen the document before texture editing.") }
        let target=try body(["body_id":bodyID.raw.uuidString]),count=document.session.changeCount
        let result=try await calculate(target,args:[:],request:.init(kind:.read,resolution:resolution))
        guard count==document.session.changeCount else { throw CADTexturePaintKernel.fail("document_changed","Refresh after the body change.") }
        return .init(mesh:target.render,png:result.png,sourceSHA256:result.sourceSHA256,changeCount:count,width:result.width,height:result.height,storedTextureSHA256:target.material?.baseColorTexture.map(CADMaterialTexture.digest))
    }
}
