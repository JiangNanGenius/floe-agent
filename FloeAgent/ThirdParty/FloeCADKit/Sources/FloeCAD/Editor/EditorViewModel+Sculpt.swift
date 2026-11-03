// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd

nonisolated struct CADSculptPreview:Sendable {
    var render:RenderMesh
    var edges:FeatureEdgeSet
    var maskTriangles:[[SIMD3<Float>]]
}
private actor CADSculptPreviewWorker {
    static let shared=CADSculptPreviewWorker()
    func build(_ definition:CADPolygonMeshDefinition,stroke:CADSculptStroke?,cancel:CADMeshCancellation) throws -> CADSculptPreview {
        let began=Date();let cancelled:@Sendable ()->Bool={ cancel.isCancelled || Date().timeIntervalSince(began)>10 }
        let next=try stroke.map { try CADSculptKernel.apply(.stroke($0),to:definition,cancelled:cancelled) } ?? definition
        let evaluated=try CADPolygonMeshKernel.evaluate(next,cancelled:cancelled)
        guard let state=next.sculpt else { throw CADPolygonFailure.invalid("This mesh has no sculpt levels.") }
        let active=try CADSculptKernel.resolve(state,cancelled:cancelled),faces=Dictionary(uniqueKeysWithValues:active.cage.faces.map { ($0.id,$0) })
        var triangles=Array(repeating:[SIMD3<Float>](),count:4)
        for (index,id) in evaluated.controlFaceIDs.enumerated() {
            if index%64==0 && cancelled() { throw CADPolygonFailure.cancelled }
            guard let face=faces[id] else { continue }
            let weight=face.vertices.map { active.mask[$0] ?? 0 }.reduce(0,+)/Double(face.vertices.count)
            guard weight>0 else { continue };let bucket=min(3,Int(weight*4))
            for corner in 0..<3 { triangles[bucket].append(evaluated.render.positions[Int(evaluated.render.indices[index*3+corner])]) }
        }
        guard !cancelled() else { throw CADPolygonFailure.cancelled }
        return .init(render:evaluated.render,edges:evaluated.edges,maskTriangles:triangles)
    }
}
@MainActor extension EditorViewModel {
    struct SculptDraft {
        var id=UUID()
        var body:BodyID
        var definition:CADPolygonMeshDefinition
        var generation:Int
        var revision:UInt64
        var render:RenderMesh
        var placement:Transform3D
        var brush:CADSculptBrush
        var samples:[CADSculptSample]=[]
        var lastCenter:SIMD3<Double>?
    }
    var sculptHasStroke:Bool { sculptDraft != nil }
    var activeSculptCage:(node:FeatureNode,definition:CADPolygonMeshDefinition,body:Body)? {
        guard let id=sculptEditingBody,let current=CADPolygonMeshService.currentCage(in:session,bodyID:id),current.definition.sculpt != nil else { return nil };return current
    }
    func beginSculptEditing(_ id:BodyID) {
        cancelSculptStroke();endPolygonCageEditing();cancelTransientPicks();cancelTool()
        guard let active=CADPolygonMeshService.currentCage(in:session,bodyID:id),active.definition.sculpt != nil else { return }
        mode = .selected(id);selection=[id];sculptEditingBody=id;sculptMessage=nil;sculptAppliedGeneration=nil;sculptStrokeCount=0
        let bounds=active.body.render.localAABB
        sculptBrush.radius=max(0.001,Double(simd_length(bounds.max-bounds.min))*0.45)
        refreshSculptDisplay()
    }
    func endSculptEditing() {
        cancelSculptStroke();sculptCommitTask?.cancel();sculptCommitTask=nil
        sculptCommitID=nil
        if sculptBusy { sculptCancelHandler?() }
        sculptEditingBody=nil;sculptDisplay=nil;sculptBusy=false
    }
    func cancelSculptStroke() {
        sculptDraft=nil;sculptPreviewTask?.cancel();sculptPreviewTask=nil;sculptDisplay=nil
        sculptPreviewEpoch &+= 1
    }
    func beginSculptStroke(ray:Ray,pressure:Double) -> Bool {
        guard !sculptBusy,let active=activeSculptCage,documentClosedCheck?() != true,session.writeBlock==nil else { return false }
        cancelSculptStroke();sculptAppliedGeneration=nil
        sculptDraft=SculptDraft(body:active.body.id,definition:active.definition,generation:session.changeCount,revision:active.body.meshRevision,
            render:active.body.render,placement:active.body.transform,brush:sculptBrush)
        appendSculptSample(ray:ray,pressure:pressure,force:true)
        if sculptDraft?.samples.isEmpty != false { sculptDraft=nil;return false };return true
    }
    func updateSculptStroke(ray:Ray,pressure:Double) { appendSculptSample(ray:ray,pressure:pressure,force:false) }
    private func appendSculptSample(ray:Ray,pressure:Double,force:Bool) {
        guard var draft=sculptDraft,session.changeCount==draft.generation,documentClosedCheck?() != true,
              let body=session.document.body(with:draft.body),body.meshRevision==draft.revision else { cancelSculptStroke();return }
        guard draft.samples.count<256 else {
            cancelSculptStroke();sculptMessage=FloeCADStrings.text("cad.sculpt.strokeLimit","This stroke is too long. Try shorter strokes.");return
        }
        var pickedScene=scene
        if let index=pickedScene.bodies.firstIndex(where:{ $0.id==draft.body }) {
            pickedScene.bodies[index].renderMesh=draft.render;pickedScene.bodies[index].meshRevision=draft.revision
        }
        guard let hit=HitTester.pickBody(ray:ray,in:pickedScene),hit.bodyID==draft.body,hit.triangleIndex<draft.render.triangleCount else { return }
        let inverse=simd_inverse(draft.placement.matrixFloat),local=inverse*SIMD4(hit.worldPoint,1)
        let p=SIMD3<Double>(Double(local.x),Double(local.y),Double(local.z))
        if !force,let prior=draft.lastCenter,simd_distance(p,prior)<draft.brush.radius*0.15 { return }
        let triangle=(0..<3).map { SIMD3<Double>(draft.render.positions[Int(draft.render.indices[hit.triangleIndex*3+$0])]) }
        let e0=triangle[1]-triangle[0],e1=triangle[2]-triangle[0],v=p-triangle[0]
        let a=simd_dot(e0,e0),b=simd_dot(e0,e1),c=simd_dot(e1,e1),denominator=a*c-b*b
        guard denominator>1e-14 else { return }
        let v1=(c*simd_dot(v,e0)-b*simd_dot(v,e1))/denominator,v2=(a*simd_dot(v,e1)-b*simd_dot(v,e0))/denominator
        var weights=simd_max(SIMD3(1-v1-v2,v1,v2),.zero);weights /= weights.x+weights.y+weights.z
        draft.samples.append(.init(triangle:hit.triangleIndex,barycentric:weights,pressure:min(1,max(0,pressure))))
        draft.lastCenter=p;sculptDraft=draft;scheduleSculptPreview(draft.definition,stroke:.init(brush:draft.brush,samples:draft.samples),generation:draft.generation,body:draft.body)
    }
    func finishSculptStroke() {
        guard let draft=sculptDraft,!draft.samples.isEmpty else { cancelSculptStroke();return }
        sculptDraft=nil;sculptPreviewTask?.cancel();sculptBusy=true
        let stroke=CADSculptStroke(brush:draft.brush,samples:draft.samples)
        let value=(try? JSONSerialization.jsonObject(with:JSONEncoder().encode(stroke))) ?? NSNull()
        let operation=UUID();sculptCommitID=operation
        sculptCommitTask=Task { @MainActor [weak self] in
            guard let self else { return };defer { if self.sculptCommitID==operation { self.sculptBusy=false;self.sculptCommitTask=nil;self.sculptCommitID=nil } }
            guard self.session.changeCount==draft.generation,self.sculptEditingBody==draft.body,!Task.isCancelled else { return }
            let reply=await self.sculptActionHandler?("sculpt.stroke",["bodyID":draft.body.raw.uuidString,"cageDigest":draft.definition.digest,
                "expectedChangeCount":draft.generation,"stroke":value])
            guard !Task.isCancelled,self.sculptCommitID==operation,self.sculptEditingBody==draft.body,self.documentClosedCheck?() != true else { return }
            self.sculptDisplay=nil
            if reply?["ok"] as? Bool != true { self.sculptMessage=FloeCADStrings.text("cad.sculpt.failed","Couldn't apply the stroke. Your mesh is unchanged.") }
            else if reply?["saved"] as? Bool == false { self.sculptMessage=FloeCADStrings.text("cad.sculpt.saveFailed","The mesh changed but couldn't be saved. Try saving again.") }
            else { self.sculptMessage=nil }
            if reply?["ok"] as? Bool == true,reply?["mutated"] as? Bool == true { self.sculptAppliedGeneration=self.session.changeCount;self.sculptStrokeCount+=1 }
            self.refreshSculptDisplay()
        }
    }
    func performSculptAction(_ action:String,extra:[String:Any]=[:]) async -> Bool {
        guard !sculptBusy,let active=activeSculptCage else { return false }
        cancelSculptStroke();sculptBusy=true;let operation=UUID();sculptCommitID=operation
        defer { if sculptCommitID==operation { sculptBusy=false;sculptCommitID=nil } }
        var args=extra;args["bodyID"]=active.body.id.raw.uuidString;args["cageDigest"]=active.definition.digest;args["expectedChangeCount"]=session.changeCount
        let reply=await sculptActionHandler?(action,args)
        guard !Task.isCancelled,sculptCommitID==operation,sculptEditingBody==active.body.id,documentClosedCheck?() != true else { return false }
        let ok=reply?["ok"] as? Bool == true
        sculptMessage=ok ? (reply?["saved"] as? Bool == false ? FloeCADStrings.text("cad.sculpt.saveFailed","The mesh changed but couldn't be saved. Try saving again."):nil):FloeCADStrings.text("cad.sculpt.failed","Couldn't apply the stroke. Your mesh is unchanged.")
        refreshSculptDisplay();return ok
    }
    func refreshSculptDisplay() {
        guard let active=activeSculptCage else { sculptDisplay=nil;return }
        scheduleSculptPreview(active.definition,stroke:nil,generation:session.changeCount,body:active.body.id)
    }
    private func scheduleSculptPreview(_ definition:CADPolygonMeshDefinition,stroke:CADSculptStroke?,generation:Int,body:BodyID) {
        sculptPreviewTask?.cancel();sculptPreviewEpoch &+= 1;let epoch=sculptPreviewEpoch
        let cancellation=CADMeshCancellation()
        sculptPreviewTask=Task { @MainActor [weak self] in
            let result=await withTaskCancellationHandler {
                await Task.detached(priority:.userInitiated) {
                    try? await CADSculptPreviewWorker.shared.build(definition,stroke:stroke,cancel:cancellation)
                }.value
            } onCancel: { cancellation.cancel() }
            guard let self,!Task.isCancelled,!cancellation.isCancelled,self.sculptPreviewEpoch==epoch,
                  self.session.changeCount==generation,self.sculptEditingBody==body,self.documentClosedCheck?() != true else { return }
            self.sculptDisplay=result;self.sculptDisplayGeneration=generation;self.sculptDisplayBody=body
        }
    }
    func sculptPreviewBody(_ body:Body) -> Body? {
        guard sculptEditingBody==body.id,sculptDisplayBody==body.id,sculptDisplayGeneration==session.changeCount,let display=sculptDisplay else { return nil }
        var value=body;value.render=display.render;value.edges=display.edges;value.meshRevision=(1<<59)|sculptPreviewEpoch;return value
    }
    func appendSculptMask(to scene:inout ViewportScene) {
        guard let id=sculptEditingBody,sculptDisplayBody==id,sculptDisplayGeneration==session.changeCount,
              let body=session.document.body(with:id),let display=sculptDisplay else { return }
        for (index,points) in display.maskTriangles.enumerated() where !points.isEmpty {
            let world=points.map { point -> SIMD3<Float> in let p=body.transform.matrixFloat*SIMD4(point,1);return SIMD3(p.x,p.y,p.z) }
            scene.profileFills.append(.init(triangles:world,color:SIMD4(0.65,0.12,0.35,Float(index+1)*0.18)))
        }
    }
}
