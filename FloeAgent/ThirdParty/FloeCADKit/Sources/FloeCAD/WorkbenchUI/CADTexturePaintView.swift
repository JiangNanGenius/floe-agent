// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import Observation
import UIKit
import simd

@MainActor @Observable final class CADTexturePaintModel {
    let document:FloeCADDocument
    let bodyID:BodyID
    var snapshot:CADTexturePaintViewSnapshot?
    var image:UIImage?
    var canEdit:Bool { !document.isClosed && document.session.writeBlock==nil }
    var busy=false
    var error:String?
    var details:String?
    var color=Color.red
    var radius=12.0
    var opacity=1.0
    var yaw=0.35
    var pitch = -0.45
    var samples=16
    var distance=50.0
    var includeOthers=false
    @ObservationIgnored private var operation:Task<Void,Never>?
    @ObservationIgnored private var generation=UUID()
    init(document:FloeCADDocument,bodyID:BodyID) { self.document=document;self.bodyID=bodyID }
    func refresh() async {
        let token=UUID();generation=token
        do {
            let state=try await CADTexturePaintService(document:document).snapshot(bodyID:bodyID)
            guard !Task.isCancelled,generation==token else { return }
            snapshot=state;image=UIImage(data:state.png);error=nil;details=nil
        } catch { if !Task.isCancelled,generation==token { show(error) } }
    }
    func stroke(_ hits:[CADTexturePaintHit]) {
        guard !hits.isEmpty else { return }
        var r:CGFloat=0,g:CGFloat=0,b:CGFloat=0,a:CGFloat=0
        guard UIColor(color).getRed(&r,green:&g,blue:&b,alpha:&a) else { return }
        run("paint.stroke",extra:["hits":hits.map { ["triangle":$0.triangle,"barycentric":[$0.barycentric.x,$0.barycentric.y,$0.barycentric.z]] as [String:Any] },
            "color_srgb":[Double(r),Double(g),Double(b),Double(a)],"radius_pixels":radius,"opacity":opacity])
    }
    func bake() {
        var args:[String:Any]=["samples":samples,"max_distance_mm":distance]
        if includeOthers { args["occluder_body_ids"]=document.session.document.bodies.filter { $0.id != bodyID && !$0.isHidden }.map { $0.id.raw.uuidString } }
        run("paint.bakeAO",extra:args)
    }
    private func run(_ action:String,extra:[String:Any]) {
        guard !busy,let state=snapshot else { return }
        var args:[String:Any]=["body_id":bodyID.raw.uuidString,"source_sha256":state.sourceSHA256,"expected_change_count":state.changeCount]
        for (key,value) in extra { args[key]=value }
        busy=true;error=nil;details=nil
        operation=Task { @MainActor [weak self] in
            guard let self else { return }
            let reply=await CADMaterialService(document:self.document).handleAsync(action:action,args:args)
            guard !Task.isCancelled else { self.busy=false;self.operation=nil;return }
            if reply["ok"] as? Bool != true {
                self.error=reply["message"] as? String;self.details=(reply["details"] as? [String] ?? []).joined(separator:"\n")
            } else {
                var saveFailure:String?
                if reply["mutated"] as? Bool == true {
                    let saved=await self.document.save()
                    if !saved.succeeded { saveFailure=saved.error ?? "Save failed." }
                }
                await self.refresh()
                if let saveFailure { self.error=FloeCADStrings.text("cad.paint.saveFailed","The edit is kept. Save the document again.");self.details=saveFailure }
            }
            self.busy=false;self.operation=nil
        }
    }
    func history(redo:Bool) {
        guard !busy else { return }
        _=CADMaterialService(document:document).handle(action:redo ? "redo" : "undo",args:[:])
        Task { @MainActor in _=await document.save();await refresh() }
    }
    func stop() { generation=UUID();operation?.cancel();CADTexturePaintService.cancel(for:document) }
    private func show(_ failure:Error) {
        error=FloeCADStrings.text("cad.paint.failed","Texture editing didn't finish. Your material is unchanged.");details=failure.localizedDescription
    }
}
struct CADTexturePaintView:View {
    @State private var model:CADTexturePaintModel
    @State private var showUV=false
    @Environment(\.dismiss) private var dismiss
    init(document:FloeCADDocument,bodyID:BodyID) { _model=State(initialValue:CADTexturePaintModel(document:document,bodyID:bodyID)) }
    private func text(_ suffix:String,_ fallback:String)->String { FloeCADStrings.text("cad.paint."+suffix,fallback) }
    var body:some View {
        @Bindable var editor = model.document.viewModel()
        NavigationStack {
            Form {
                if let state=model.snapshot,let image=model.image {
                    Section(text("surface","Paint on the surface")) {
                        if state.mesh.triangleCount<=10000 {
                            CADTexturePaintCanvas(mesh:state.mesh,image:image,yaw:model.yaw,pitch:model.pitch,enabled:!model.busy && model.canEdit,fingerDrawingEnabled:editor.fingerDrawingEnabled,onStroke:model.stroke)
                                .frame(height:310)
                                .accessibilityElement(children:.ignore)
                                .accessibilityLabel(text("title","Texture painting"))
                                .accessibilityIdentifier("CADTexturePaintCanvas")
                        } else { Text(text("previewBudget","The painting preview supports up to 10,000 triangles. Simplify a copy first.")) }
                        Toggle(FloeCADStrings.text("cad.ui.tool.fingerDrawing", "Touch drawing"), isOn: $editor.fingerDrawingEnabled)
                            .accessibilityIdentifier("CADTexturePaintFingerDrawingToggle")
                        Text(text("strokeHelp","Draw on the surface. Each stroke is one undoable edit. The brush stays inside the touched UV island."))
                            .font(.footnote).foregroundStyle(.secondary)
                        Slider(value:$model.yaw,in:(-.pi)...(.pi)) { Text(text("turn","Turn")) }.accessibilityLabel(text("turn","Turn"))
                        Slider(value:$model.pitch,in:(-.pi/2)...(.pi/2)) { Text(text("tilt","Tilt")) }.accessibilityLabel(text("tilt","Tilt"))
                        ColorPicker(text("color","Brush color"),selection:$model.color,supportsOpacity:false).accessibilityIdentifier("CADTexturePaintColor")
                        Slider(value:$model.radius,in:1...64,step:1) { Text(text("radius","Brush radius (pixels)")) }.accessibilityIdentifier("CADTexturePaintRadius")
                        Slider(value:$model.opacity,in:0.05...1) { Text(text("opacity","Brush opacity")) }
                    }.disabled(model.busy || !model.canEdit)
                    DisclosureGroup {
                        LabeledContent(text("storedTexture","Stored texture"),value:state.storedTextureSHA256 ?? text("noTexture","None"))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(text("storedTexture","Stored texture"))
                            .accessibilityValue(state.storedTextureSHA256 ?? "none")
                            .accessibilityIdentifier("CADTexturePaintStoredDigest")
                    } label: {
                        Text(FloeCADStrings.text("cad.ui.common.details","Details"))
                            .accessibilityIdentifier("CADTexturePaintDetails")
                    }
                    Section(text("texture","Base color texture")) {
                        Image(uiImage:image).resizable().interpolation(.none).scaledToFit().frame(maxHeight:250)
                            .accessibilityIdentifier("CADTexturePaintImage")
                    }
                    Section(text("bake","Bake occlusion into color")) {
                        Picker(text("samples","Samples"),selection:$model.samples) { ForEach([8,16,32],id:\.self) { Text("\($0)").tag($0) } }
                        LabeledContent(text("distance","Distance (mm)")) { TextField(text("distance","Distance (mm)"),value:$model.distance,format:.number).keyboardType(.decimalPad).accessibilityIdentifier("CADTextureBakeDistance") }
                        Toggle(text("otherBodies","Include other visible bodies"),isOn:$model.includeOthers).accessibilityIdentifier("CADTextureBakeOtherBodies")
                        Text(text("bakeHelp","Computes mesh occlusion with hemisphere rays and multiplies it into the current color texture. GLB carries the resulting color image. Repeating the bake darkens the existing result."))
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(text("bake","Bake occlusion into color"),action:model.bake)
                            .disabled(model.busy || !model.canEdit || state.width>256 || state.height>256 || !model.distance.isFinite || model.distance<=0 || model.distance>100000)
                            .frame(minHeight:44).accessibilityIdentifier("CADTextureBakeAO")
                        if state.width>256 || state.height>256 { Text(text("bakeBudget","AO baking supports textures up to 256 × 256 pixels.")) }
                    }.disabled(model.busy)
                    Section {
                        HStack {
                            Button(FloeCADStrings.text("cad.ui.common.undo","Undo")) { model.history(redo:false) }.disabled(!model.document.session.undoStack.canUndo || model.busy).accessibilityIdentifier("CADTexturePaintUndo")
                            Spacer()
                            Button(FloeCADStrings.text("cad.ui.common.redo","Redo")) { model.history(redo:true) }.disabled(!model.document.session.undoStack.canRedo || model.busy).accessibilityIdentifier("CADTexturePaintRedo")
                        }.buttonStyle(.borderless)
                    }
                } else if model.error==nil { ProgressView() }
                if model.busy { ProgressView(text("working","Updating texture…")).accessibilityIdentifier("CADTexturePaintBusy") }
                if let error=model.error { Section { Text(error).foregroundStyle(.orange).accessibilityIdentifier("CADTexturePaintError") } }
                if let details=model.details { DisclosureGroup(FloeCADStrings.text("cad.ui.common.details","Details")) { Text(details).font(.caption).textSelection(.enabled) } }
                Section {
                    Button(FloeCADStrings.text("cad.paint.refresh","Refresh")) { Task { await model.refresh() } }.disabled(model.busy).accessibilityIdentifier("CADTexturePaintRefresh")
                    Button(FloeCADStrings.text("cad.uv.title","UV Editor")) { showUV=true }.disabled(model.busy).accessibilityIdentifier("CADTexturePaintOpenUV") }
            }
            .accessibilityIdentifier("CADTexturePaintForm")
            .navigationTitle(text("title","Texture painting"))
            .toolbar {
                ToolbarItem(placement:.confirmationAction) { Button(FloeCADStrings.text("cad.ui.common.done","Done")) { model.stop();dismiss() }.accessibilityIdentifier("CADTexturePaintDone") }
                ToolbarItem(placement:.cancellationAction) { if model.busy { Button(FloeCADStrings.text("cad.ui.common.cancel","Cancel"),action:model.stop).accessibilityIdentifier("CADTexturePaintCancel") } }
            }
            .task { await model.refresh() }
            .sheet(isPresented:$showUV,onDismiss:{ Task { await model.refresh() } }) { CADUVEditorView(document:model.document,bodyID:model.bodyID) }
            .onDisappear { model.stop() }
        }
    }
}

/// Orthographic interaction preview over the same indexed mesh/UVs as the
/// editor. Texture triangles use an exact affine UV-to-projection map. This
/// UI preview is never a bake input or a saved texture screenshot.
private struct CADTexturePaintCanvas:View {
    let mesh:RenderMesh
    let image:UIImage
    let yaw:Double
    let pitch:Double
    let enabled:Bool
    let fingerDrawingEnabled:Bool
    let onStroke:([CADTexturePaintHit])->Void
    @State private var hits:[CADTexturePaintHit]=[]
    @State private var trail:[CGPoint]=[]
    private func projected(_ size:CGSize)->[SIMD3<Double>] {
        let c=cos(yaw),s=sin(yaw),cp=cos(pitch),sp=sin(pitch)
        let points=mesh.positions.map { p->SIMD3<Double> in
            let x=c*Double(p.x)+s*Double(p.z),z = -s*Double(p.x)+c*Double(p.z)
            return SIMD3(x,cp*Double(p.y)-sp*z,sp*Double(p.y)+cp*z)
        }
        let lo=points.reduce(SIMD3<Double>(repeating:.greatestFiniteMagnitude)){simd_min($0,$1)},hi=points.reduce(SIMD3<Double>(repeating:-Double.greatestFiniteMagnitude)){simd_max($0,$1)}
        let center=(lo+hi)/2,scale=min(Double(size.width-24)/max(hi.x-lo.x,1e-9),Double(size.height-24)/max(hi.y-lo.y,1e-9))
        return points.map { SIMD3(($0.x-center.x)*scale+Double(size.width)/2,-($0.y-center.y)*scale+Double(size.height)/2,$0.z) }
    }
    private func hit(_ point:CGPoint,size:CGSize)->CADTexturePaintHit? {
        let points=projected(size),tap=SIMD2(Double(point.x),Double(point.y));var nearest:CADTexturePaintHit?,depth = -Double.greatestFiniteMagnitude
        for f in 0..<mesh.triangleCount {
            let p=(0..<3).map{points[Int(mesh.indices[f*3+$0])]}
            guard let w=CADTexturePaintKernel.barycentric(tap,SIMD2(p[0].x,p[0].y),SIMD2(p[1].x,p[1].y),SIMD2(p[2].x,p[2].y)),min(w.x,min(w.y,w.z))>=0 else { continue }
            let z=p[0].z*w.x+p[1].z*w.y+p[2].z*w.z
            if z>depth { depth=z;nearest = .init(triangle:f,barycentric:w) }
        }
        return nearest
    }
    var body:some View {
        GeometryReader { geometry in
            Canvas { context,size in
                let points=projected(size)
                guard let uv=mesh.texcoords else { return }
                let order=(0..<mesh.triangleCount).sorted { a,b in
                    (0..<3).reduce(0.0){$0+points[Int(mesh.indices[a*3+$1])].z} < (0..<3).reduce(0.0){$0+points[Int(mesh.indices[b*3+$1])].z}
                }
                for f in order {
                    let ids=(0..<3).map{Int(mesh.indices[f*3+$0])},a=points[ids[0]],b=points[ids[1]],c=points[ids[2]]
                    let u=SIMD2<Double>(Double(uv[ids[0]].x),Double(uv[ids[0]].y)),v=SIMD2<Double>(Double(uv[ids[1]].x),Double(uv[ids[1]].y)),w=SIMD2<Double>(Double(uv[ids[2]].x),Double(uv[ids[2]].y))
                    let d=v-u,e=w-u,det=d.x*e.y-d.y*e.x
                    guard abs(det)>1e-14 else { continue }
                    let aa=((b.x-a.x)*e.y-(c.x-a.x)*d.y)/det,cc=(d.x*(c.x-a.x)-e.x*(b.x-a.x))/det
                    let bb=((b.y-a.y)*e.y-(c.y-a.y)*d.y)/det,dd=(d.x*(c.y-a.y)-e.x*(b.y-a.y))/det
                    var path=Path();path.move(to:CGPoint(x:a.x,y:a.y));path.addLine(to:CGPoint(x:b.x,y:b.y));path.addLine(to:CGPoint(x:c.x,y:c.y));path.closeSubpath()
                    var layer=context;layer.clip(to:path)
                    layer.concatenate(CGAffineTransform(a:aa,b:bb,c:cc,d:dd,tx:a.x-aa*u.x-cc*u.y,ty:a.y-bb*u.x-dd*u.y))
                    layer.draw(Image(uiImage:image),in:CGRect(x:0,y:0,width:1,height:1))
                }
                if let first=trail.first { var path=Path();path.move(to:first);for p in trail.dropFirst(){path.addLine(to:p)};context.stroke(path,with:.color(.accentColor),lineWidth:2) }
            }
            .background(.quaternary.opacity(0.3)).clipped().contentShape(Rectangle())
            .overlay {
                CADTexturePaintInputSurface(enabled: enabled, fingerDrawingEnabled: fingerDrawingEnabled, onSample: { point in
                    guard enabled,hits.count<128 else { return }
                    if let previous=trail.last,hypot(previous.x-point.x,previous.y-point.y)<2 { return }
                    if let hit=hit(point,size:geometry.size) { hits.append(hit);trail.append(point) }
                }, onEnded: {
                    let submitted=hits;hits=[];trail=[];if enabled { onStroke(submitted) }
                }, onCancelled: { hits=[];trail=[] })
            }
            .onDisappear { hits=[];trail=[] }
        }
    }
}

/// Input-only admission state. It uses the viewport's source classifier and
/// latches a revoked stroke until lift; it never routes paint into camera drags.
struct CADTexturePaintStrokeGate {
    private(set) var source: CADViewportInputSource?
    private(set) var permitsSamples = false
    mutating func begin(_ source: CADViewportInputSource, enabled: Bool, fingerDrawingEnabled: Bool) -> Bool {
        guard self.source == nil, enabled, source.editsDrawing(fingerDrawingEnabled: fingerDrawingEnabled) else { return false }
        self.source = source; permitsSamples = true
        return true
    }
    mutating func update(enabled: Bool, fingerDrawingEnabled: Bool) {
        if !enabled || source?.editsDrawing(fingerDrawingEnabled: fingerDrawingEnabled) == false { permitsSamples = false }
    }
    mutating func finish() -> Bool { defer { cancel() }; return source != nil && permitsSamples }
    mutating func cancel() { source = nil; permitsSamples = false }
}

@MainActor final class CADTexturePaintStrokeRecognizer: UIGestureRecognizer {
    var onSample: ((CGPoint) -> Void)?
    var onEnded: (() -> Void)?
    var onCancelled: (() -> Void)?
    private var activeTouch: UITouch?
    private var input = CADTexturePaintStrokeGate()
    private var paintingEnabled = false
    private var fingerDrawingEnabled = false

    func configure(enabled: Bool, fingerDrawingEnabled: Bool) {
        paintingEnabled = enabled; self.fingerDrawingEnabled = fingerDrawingEnabled
        input.update(enabled: enabled, fingerDrawingEnabled: fingerDrawingEnabled)
        let types: [UITouch.TouchType] = [.pencil, .indirect, .indirectPointer, .direct]
        let allowed = types.filter { CADViewportInputSource($0).editsDrawing(fingerDrawingEnabled: fingerDrawingEnabled) }
            .map { NSNumber(value: $0.rawValue) }
        if allowedTouchTypes != allowed { allowedTouchTypes = allowed }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard activeTouch == nil, let touch = touches.first,
              input.begin(CADViewportInputSource(touch.type), enabled: paintingEnabled, fingerDrawingEnabled: fingerDrawingEnabled) else {
            if activeTouch == nil { state = .failed }; return
        }
        activeTouch = touch
        state = .began
        onSample?(touch.location(in: view))
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        guard input.permitsSamples else { cancelStroke(); return }
        state = .changed
        emit(touch, event: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        guard input.permitsSamples else { cancelStroke(); return }
        emit(touch, event: event)
        // Preserve tap dots and the last sample before the existing paint call.
        activeTouch = nil
        let commit = input.finish()
        state = .ended
        if commit { onEnded?() }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        cancelStroke()
    }
    override func reset() {
        let discarded = input.source != nil
        super.reset(); activeTouch = nil; input.cancel()
        // UIKit can interrupt recognition without a normal lift.
        if discarded { onCancelled?() }
    }
    private func emit(_ touch: UITouch, event: UIEvent) {
        if let samples = event.coalescedTouches(for: touch), !samples.isEmpty {
            for sample in samples { onSample?(sample.location(in: view)) }
        }
        onSample?(touch.location(in: view))
    }
    private func cancelStroke() {
        activeTouch = nil; input.cancel(); state = .cancelled; onCancelled?()
    }
}

private struct CADTexturePaintInputSurface: UIViewRepresentable {
    let enabled: Bool
    let fingerDrawingEnabled: Bool
    let onSample: (CGPoint) -> Void
    let onEnded: () -> Void
    let onCancelled: () -> Void
    func makeUIView(context: Context) -> CADTexturePaintInputView {
        let view = CADTexturePaintInputView(frame: .zero)
        configure(view)
        return view
    }
    func updateUIView(_ view: CADTexturePaintInputView, context: Context) { configure(view) }
    private func configure(_ view: CADTexturePaintInputView) {
        view.input.onSample = onSample; view.input.onEnded = onEnded; view.input.onCancelled = onCancelled
        view.input.configure(enabled: enabled, fingerDrawingEnabled: fingerDrawingEnabled)
    }
    static func dismantleUIView(_ view: CADTexturePaintInputView, coordinator: ()) {
        view.input.onSample = nil; view.input.onEnded = nil; view.input.onCancelled = nil
        view.input.isEnabled = false
    }
}
private final class CADTexturePaintInputView: UIView {
    let input = CADTexturePaintStrokeRecognizer(target: nil, action: nil)
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isMultipleTouchEnabled = false
        // Immediate ownership keeps an accepted paint stroke out of the Form's
        // scroll gesture. Rejected finger touches remain ordinary navigation.
        input.cancelsTouchesInView = true; input.delaysTouchesBegan = false
        addGestureRecognizer(input)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
#endif
