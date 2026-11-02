// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import Observation
import UIKit
import simd

@MainActor @Observable
final class CADUVEditorModel {
    let document: FloeCADDocument
    let bodyID: BodyID
    var snapshot: CADUVViewSnapshot?
    var edges: [CADUVEdge] = []
    var uv: [SIMD2<Float>] = []
    var selectedEdge: CADUVEdge?
    var selectedIslands: Set<UInt32> = []
    var yaw: Double = 0.6
    var pitch: Double = -0.4
    var moveU: Double = 0, moveV: Double = 0, rotation: Double = 0
    var scaleU: Double = 1, scaleV: Double = 1
    var resolution = 512
    var isBusy = false
    var errorMessage: String?
    var diagnostic: String?
    var preview: UIImage?
    var textureImage: UIImage?
    private var previewCount: Int?
    @ObservationIgnored private var operation: Task<Void,Never>?
    @ObservationIgnored private var refreshID=UUID()

    init(document: FloeCADDocument, bodyID: BodyID) { self.document=document; self.bodyID=bodyID }
    func refresh() async {
        let id=UUID(); refreshID=id
        do {
            let state=try await CADUVService(document:document).snapshot(bodyID:bodyID)
            let source=state.source, set=state.record.activeSet
            let prepared=try await Task.detached(priority:.userInitiated) {
                (try CADUVRecord.edgeFaces(source).keys.sorted(),try set.map { try CADUVRecord.unpack($0.cornerUVData) } ?? [])
            }.value
            guard refreshID == id, !Task.isCancelled else { return }
            snapshot=state; edges=prepared.0; uv=prepared.1
            if let data=state.texture, case .success(let decoded)=CADExportImage.decode(data) {
                textureImage=UIImage(cgImage:decoded.image)
            } else { textureImage=nil }
            let available=Set(set?.faceCharts ?? [])
            selectedIslands.formIntersection(available)
            if selectedIslands.isEmpty, let first=available.min() { selectedIslands=[first] }
            if let edge=selectedEdge, !edges.contains(edge) { selectedEdge=nil }
            if previewCount != state.changeCount { preview=nil; previewCount=nil }
        } catch {
            guard refreshID == id, !Task.isCancelled else { return }
            show(error)
        }
    }
    func run(_ action: String, extra: [String:Any] = [:]) {
        guard !isBusy, let state=snapshot else { return }
        isBusy=true; errorMessage=nil; diagnostic=nil
        var args: [String:Any]=["body_id":bodyID.raw.uuidString,
            "source_sha256":state.record.sourceMeshSHA256,"expected_change_count":state.changeCount]
        for (key,value) in extra { args[key]=value }
        if action == "uv.unwrap", state.isStale {
            args["rebase"]=true; args["source_sha256"]=state.liveMeshSHA256
        }
        operation=Task { [weak self] in
            guard let self else { return }
            let reply=await CADMaterialService(document:self.document).handleAsync(action:action,args:args)
            if reply["ok"] as? Bool != true, !Task.isCancelled {
                self.show(CADUVFailure(code:reply["error"] as? String ?? "uv_failed",message:reply["message"] as? String ?? "UV editing failed."))
            }
            if !Task.isCancelled { await self.refresh() }
            self.isBusy=false; self.operation=nil
        }
    }
    func toggleSeam() {
        guard let state=snapshot, let edge=selectedEdge else { return }
        var seams=Set(state.record.seams)
        if seams.contains(edge) { seams.remove(edge) } else { seams.insert(edge) }
        run("uv.seams",extra:["seams":seams.sorted().map { [$0.a,$0.b] }])
    }
    func transform() {
        run("uv.transform",extra:["island_ids":selectedIslands.sorted(),"translate":[moveU,moveV],
            "rotation_degrees":rotation,"scale":[scaleU,scaleV]])
    }
    func history(redo: Bool) {
        guard !isBusy else { return }
        let reply=CADMaterialService(document:document).handle(action:redo ? "redo" : "undo",args:[:])
        if reply["ok"] as? Bool != true { diagnostic=reply["message"] as? String }
        Task { await refresh() }
    }
    func capture() {
        do {
            let capture=try document.captureViewportPNG(width:768,height:512)
            guard capture.changeCount == snapshot?.changeCount else { throw CADUVRecord.failure("document_changed", "Refresh after the source change.") }
            guard let image=UIImage(data:capture.pngData) else { throw CADUVRecord.failure("viewport_unavailable", "The viewport returned unreadable image bytes.") }
            preview=image; previewCount=capture.changeCount
        } catch { show(error) }
    }
    func stop() { refreshID=UUID(); operation?.cancel(); operation=nil }
    private func show(_ error: Error) {
        let code=(error as? CADUVFailure)?.code ?? "uv_failed"
        switch code {
        case "document_changed","revision_mismatch","uv_source_changed","uv_source_mismatch":
            errorMessage=FloeCADStrings.text("cad.uv.error.changed","The source changed. Refresh and unwrap again.")
        case "cancelled": errorMessage=FloeCADStrings.text("cad.uv.error.cancelled","UV editing stopped. Your model is unchanged.")
        case "uv_worker_busy": errorMessage=FloeCADStrings.text("cad.uv.error.busy","Another UV edit is running. Try again when it finishes.")
        case "viewport_unavailable": errorMessage=FloeCADStrings.text("cad.uv.error.preview","The 3D preview is unavailable. Check the model in the canvas.")
        default: errorMessage=FloeCADStrings.text("cad.uv.error.refused","The UV edit could not be applied.")
        }
        diagnostic=error.localizedDescription
    }
}

struct CADUVEditorView: View {
    @State private var model: CADUVEditorModel
    @Environment(\.dismiss) private var dismiss
    init(document: FloeCADDocument, bodyID: BodyID) {
        _model=State(initialValue:CADUVEditorModel(document:document,bodyID:bodyID))
    }
    var body: some View {
        NavigationStack {
            Form {
                if let state=model.snapshot {
                    if state.isStale {
                        Section { Text(FloeCADStrings.text("cad.uv.stale","Geometry changed. Saved UV edits are kept; unwrap the current mesh to continue.")) }
                    }
                    seamSection(state)
                    setSection(state)
                    if state.record.activeSet != nil { islandSection(state) }
                    previewSection(state)
                    Section {
                        HStack {
                            Button(FloeCADStrings.text("cad.ui.common.undo","Undo")) { model.history(redo:false) }
                                .disabled(!model.document.session.undoStack.canUndo)
                            Spacer()
                            Button(FloeCADStrings.text("cad.ui.common.redo","Redo")) { model.history(redo:true) }
                                .disabled(!model.document.session.undoStack.canRedo)
                        }
                        Text(FloeCADStrings.text("cad.uv.undoNote","Each edit uses the document’s undo history."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }.disabled(model.isBusy)
                } else { ProgressView() }
                if let error=model.errorMessage { Section { Text(error).foregroundStyle(.red) } }
                if let detail=model.diagnostic {
                    DisclosureGroup(FloeCADStrings.text("cad.ui.common.details","Details")) { Text(detail).font(.caption).textSelection(.enabled) }
                }
            }
            .navigationTitle(FloeCADStrings.text("cad.uv.title","UV Editor"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.confirmationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.done","Done")) { model.stop(); dismiss() }
                        .accessibilityIdentifier("CADUVDone")
                }
                ToolbarItem(placement:.cancellationAction) {
                    if model.isBusy {
                        Button(FloeCADStrings.text("cad.ui.common.cancel","Cancel")) { model.stop() }
                    }
                }
            }
            .task(id:model.document.liveChangeCount) { await model.refresh() }
            .onDisappear { model.stop() }
        }
    }
    private func seamSection(_ state: CADUVViewSnapshot) -> some View {
        Section(FloeCADStrings.text("cad.uv.seams","Seams")) {
            CADUVSeamCanvas(source:state.source,edges:model.edges,seams:Set(state.record.seams),
                            selected:$model.selectedEdge,yaw:model.yaw,pitch:model.pitch)
                .frame(height:260).accessibilityIdentifier("CADUVSeamCanvas")
            Text(FloeCADStrings.text("cad.uv.pickEdge","Rotate the view, then tap an edge to mark or clear a seam."))
                .font(.footnote).foregroundStyle(.secondary)
            Slider(value:$model.yaw,in:(-.pi)...(.pi)) {
                Text(FloeCADStrings.text("cad.uv.turn","Turn"))
            }.accessibilityLabel(FloeCADStrings.text("cad.uv.turn","Turn"))
            Slider(value:$model.pitch,in:(-.pi/2)...(.pi/2)) {
                Text(FloeCADStrings.text("cad.uv.tilt","Tilt"))
            }.accessibilityLabel(FloeCADStrings.text("cad.uv.tilt","Tilt"))
            Button(model.selectedEdge.map { state.record.seams.contains($0) } == true
                   ? FloeCADStrings.text("cad.uv.clearSeam","Clear Seam")
                   : FloeCADStrings.text("cad.uv.markSeam","Mark Seam")) { model.toggleSeam() }
                .disabled(model.selectedEdge == nil || model.isBusy || state.isStale)
                .frame(minHeight:44).accessibilityIdentifier("CADUVToggleSeam")
            Text(FloeCADStrings.format("cad.uv.seamCount","%d seams",state.record.seams.count))
            Text(FloeCADStrings.text("cad.uv.extraCuts","Unwrapping respects marked seams and may add cuts."))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func setSection(_ state: CADUVViewSnapshot) -> some View {
        Section(FloeCADStrings.text("cad.uv.sets","UV Sets")) {
            Menu {
                ForEach(state.record.sets) { set in
                    Button(set.name,systemImage:set.id == state.record.activeSetID ? "checkmark" : "square") {
                        model.run("uv.activateSet",extra:["set_id":set.id.uuidString])
                    }
                }
            } label: {
                LabeledContent(FloeCADStrings.text("cad.uv.activeSet","Active Set"),value:state.record.activeSet?.name ?? "—")
            }.disabled(model.isBusy || state.isStale || state.record.sets.isEmpty)
            Picker(FloeCADStrings.text("cad.uv.resolution","Target Size"),selection:$model.resolution) {
                ForEach([256,512,1024,2048],id:\.self) { size in Text("\(size)").tag(size) }
            }
            Button(state.isStale ? FloeCADStrings.text("cad.uv.reunwrap","Unwrap Current Mesh") : FloeCADStrings.text("cad.uv.unwrap","Unwrap")) {
                model.run("uv.unwrap",extra:["resolution":model.resolution])
            }.disabled(model.isBusy).frame(minHeight:44).accessibilityIdentifier("CADUVUnwrap")
            if let set=state.record.activeSet {
                HStack {
                    Button(FloeCADStrings.text("cad.uv.pack","Pack Islands")) {
                        model.run("uv.pack",extra:["resolution":model.resolution])
                    }
                    Spacer()
                    Menu(FloeCADStrings.text("cad.uv.manageSets","Manage Sets")) {
                        Button(FloeCADStrings.text("cad.uv.copySet","Duplicate Set")) { model.run("uv.createSet") }
                            .disabled(state.record.sets.count >= CADUVRecord.maximumSets)
                        Button(FloeCADStrings.text("cad.uv.removeSet","Remove Set"),role:.destructive) {
                            model.run("uv.removeSet",extra:["set_id":set.id.uuidString])
                        }.disabled(state.record.sets.count <= 1)
                    }
                }.disabled(model.isBusy || state.isStale)
                if set.atlasWidth > 0 {
                    Text(FloeCADStrings.format("cad.uv.actualSize","Packed size: %d × %d",set.atlasWidth,set.atlasHeight))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if set.seamSHA256 != state.record.seamSHA256 {
                    Text(FloeCADStrings.text("cad.uv.pendingSeams","Seams changed. Unwrap to update the islands."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func islandSection(_ state: CADUVViewSnapshot) -> some View {
        Section(FloeCADStrings.text("cad.uv.islands","Islands")) {
            CADUVIslandCanvas(uv:model.uv,faceCharts:state.record.activeSet?.faceCharts ?? [],
                selected:$model.selectedIslands,texture:model.textureImage,orientation:state.textureOrientation)
                .frame(height:300).accessibilityIdentifier("CADUVIslandCanvas")
            Text(FloeCADStrings.text("cad.uv.pickIsland","Tap islands to select them, then apply a move, rotation or scale."))
                .font(.footnote).foregroundStyle(.secondary)
            HStack { scalar("cad.uv.moveU","Move U",value:$model.moveU); scalar("cad.uv.moveV","Move V",value:$model.moveV) }
            scalar("cad.uv.rotation","Rotation (°)",value:$model.rotation)
            HStack { scalar("cad.uv.scaleU","Scale U",value:$model.scaleU); scalar("cad.uv.scaleV","Scale V",value:$model.scaleV) }
            Button(FloeCADStrings.text("cad.uv.applyTransform","Apply Transform")) { model.transform() }
                .frame(minHeight:44).accessibilityIdentifier("CADUVApplyTransform")
                .disabled(model.selectedIslands.isEmpty || model.isBusy || state.isStale)
        }
    }
    private func scalar(_ key: String, _ title: String, value: Binding<Double>) -> some View {
        VStack(alignment:.leading) {
            Text(FloeCADStrings.text(key,title)).font(.caption).foregroundStyle(.secondary)
            TextField(FloeCADStrings.text(key,title),value:value,format:.number.precision(.fractionLength(0...4)))
                .textFieldStyle(.roundedBorder).keyboardType(.numbersAndPunctuation)
        }
    }
    private func previewSection(_ state: CADUVViewSnapshot) -> some View {
        Section(FloeCADStrings.text("cad.uv.preview","Texture Check")) {
            if let image=model.preview { Image(uiImage:image).resizable().scaledToFit().accessibilityIdentifier("CADUVActual3DPreview") }
            Button(FloeCADStrings.text("cad.uv.refreshPreview","Refresh 3D Preview")) { model.capture() }
                .disabled(model.isBusy || state.isStale).frame(minHeight:44)
            if state.projectedMaterial {
                Text(FloeCADStrings.text("cad.uv.projectionNote","Some materials use a projection. Choose Mesh UVs in Material to use this UV set."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if state.texture == nil {
                Text(FloeCADStrings.text("cad.uv.textureNote","Add a texture in Material to inspect it on the surface."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CADUVSeamCanvas: View {
    let source: RenderMesh
    let edges: [CADUVEdge]
    let seams: Set<CADUVEdge>
    @Binding var selected: CADUVEdge?
    let yaw: Double
    let pitch: Double
    private func points(_ size: CGSize) -> [(point:CGPoint,depth:Float)] {
        let c=Float(cos(yaw)), s=Float(sin(yaw)), cp=Float(cos(pitch)), sp=Float(sin(pitch))
        let rotated=source.positions.map { p -> SIMD3<Float> in
            let x=c*p.x+s*p.z, z = -s*p.x+c*p.z
            return SIMD3(x,cp*p.y-sp*z,sp*p.y+cp*z)
        }
        let lo=rotated.reduce(SIMD3<Float>(repeating:.greatestFiniteMagnitude)) { simd_min($0,$1) }
        let hi=rotated.reduce(SIMD3<Float>(repeating:-Float.greatestFiniteMagnitude)) { simd_max($0,$1) }
        let middle=(lo+hi)/2
        let scale=min(Float(size.width-24)/max(hi.x-lo.x,1e-6),Float(size.height-24)/max(hi.y-lo.y,1e-6))
        return rotated.map { (CGPoint(x:Double(($0.x-middle.x)*scale)+size.width/2,
                                        y:Double(-($0.y-middle.y)*scale)+size.height/2),$0.z) }
    }
    var body: some View {
        GeometryReader { geometry in
            Canvas { context,size in
                let p=points(size)
                for edge in edges {
                    var path=Path(); path.move(to:p[Int(edge.a)].point); path.addLine(to:p[Int(edge.b)].point)
                    let color: Color=selected == edge ? .yellow : (seams.contains(edge) ? .red : .secondary.opacity(0.35))
                    context.stroke(path,with:.color(color),lineWidth:selected == edge ? 3 : (seams.contains(edge) ? 2 : 0.65))
                }
            }
            .background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius:10))
            .contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onEnded { value in
                let p=points(geometry.size), tap=value.location
                let candidates=edges.compactMap { edge -> (CADUVEdge,CGFloat,Float)? in
                    let a=p[Int(edge.a)].point,b=p[Int(edge.b)].point
                    let dx=b.x-a.x,dy=b.y-a.y,len=dx*dx+dy*dy
                    guard len > 1e-6 else { return nil }
                    let t=min(max(((tap.x-a.x)*dx+(tap.y-a.y)*dy)/len,0),1)
                    let distance=hypot(tap.x-(a.x+t*dx),tap.y-(a.y+t*dy))
                    return distance <= 12 ? (edge,distance,(p[Int(edge.a)].depth+p[Int(edge.b)].depth)/2) : nil
                }.sorted { abs($0.1-$1.1) > 1 ? $0.1 < $1.1 : $0.2 > $1.2 }
                selected=candidates.first?.0
            })
        }
    }
}

private struct CADUVIslandCanvas: View {
    let uv: [SIMD2<Float>]
    let faceCharts: [UInt32]
    @Binding var selected: Set<UInt32>
    let texture: UIImage?
    let orientation: MaterialTextureOrientation
    private func projection(_ size: CGSize) -> (vertices: [CGPoint],zero: CGPoint,one: CGPoint) {
        let lo=uv.reduce(SIMD2<Float>(repeating:0)) { simd_min($0,$1) }
        let hi=uv.reduce(SIMD2<Float>(repeating:1)) { simd_max($0,$1) }
        func point(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x:Double((p.x-lo.x)/max(hi.x-lo.x,1e-6))*size.width,
                    y:Double((p.y-lo.y)/max(hi.y-lo.y,1e-6))*size.height)
        }
        return (uv.map(point),point(.zero),point(SIMD2(1,1)))
    }
    var body: some View {
        GeometryReader { geometry in
            Canvas { context,size in
                for x in 0..<12 { for y in 0..<12 {
                    let cell=CGRect(x:CGFloat(x)*size.width/12,y:CGFloat(y)*size.height/12,width:size.width/12,height:size.height/12)
                    context.fill(Path(cell),with:.color((x+y)%2 == 0 ? .gray.opacity(0.15) : .gray.opacity(0.3)))
                } }
                let projected=projection(size)
                let a=projected.zero,b=projected.one
                let tile=CGRect(x:a.x,y:a.y,width:b.x-a.x,height:b.y-a.y)
                if let image=texture {
                    var imageContext=context
                    if orientation == .bottomLeft { imageContext.translateBy(x:0,y:tile.minY+tile.maxY); imageContext.scaleBy(x:1,y:-1) }
                    imageContext.draw(Image(uiImage:image),in:tile)
                }
                context.stroke(Path(tile),with:.color(.secondary),lineWidth:1)
                guard uv.count == faceCharts.count*3 else { return }
                for f in faceCharts.indices {
                    var path=Path(); path.move(to:projected.vertices[f*3]); path.addLine(to:projected.vertices[f*3+1]); path.addLine(to:projected.vertices[f*3+2]); path.closeSubpath()
                    if selected.contains(faceCharts[f]) { context.fill(path,with:.color(.accentColor.opacity(0.18))) }
                    context.stroke(path,with:.color(selected.contains(faceCharts[f]) ? .accentColor : .primary.opacity(0.5)),lineWidth:0.8)
                }
            }
            .clipped().contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onEnded { value in
                guard uv.count == faceCharts.count*3 else { return }
                let tap=value.location, projected=projection(geometry.size)
                for f in faceCharts.indices {
                    let a=projected.vertices[f*3],b=projected.vertices[f*3+1],c=projected.vertices[f*3+2]
                    func side(_ p:CGPoint,_ q:CGPoint) -> CGFloat { (tap.x-q.x)*(p.y-q.y)-(p.x-q.x)*(tap.y-q.y) }
                    let signs=[side(a,b),side(b,c),side(c,a)]
                    if !signs.contains(where: { $0 < 0 }) || !signs.contains(where: { $0 > 0 }) {
                        let id=faceCharts[f]; if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }; return
                    }
                }
            })
        }
    }
}
#endif
