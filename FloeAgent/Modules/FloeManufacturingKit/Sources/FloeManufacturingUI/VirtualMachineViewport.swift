// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
@preconcurrency import SceneKit
import simd
import FloeManufacturingCore

@MainActor private final class CAMSceneView:SCNView {
    var onViewportLayout:(()->Void)?
    override func layoutSubviews() { super.layoutSubviews();onViewportLayout?() }
}

@MainActor private final class CAMPathAccessibilityElement:UIAccessibilityElement {
    var screenFrame:(()->CGRect)?
    var activate:(()->Void)?
    override var accessibilityFrameInContainerSpace:CGRect {
        get { screenFrame?() ?? .zero }
        set {}
    }
    override func accessibilityActivate()->Bool { guard let activate else { return false };activate();return true }
}

struct VirtualMachineViewport:UIViewRepresentable {
    let scene:VirtualScene
    let revision:UUID
    let smooth:Bool
    let cellSize:Double
    let warningBodies:Set<String>
    var preview:CAMPreviewFrame? = nil
    var settings = CAMPreviewSettings()
    var onSelectChapter:((String)->Void)? = nil
    var chapterNames:[String:String] = [:]
    var onSelectionBudget:(()->Void)? = nil
    private var vertical:Bool { preview?.machine.map { $0.kind != .lathe } ?? false }
    @MainActor final class Coordinator:NSObject,SCNSceneRendererDelegate {
        var revision:UUID?
        var nodes:[String:SCNNode] = [:]
        var geometryKeys:[String:String] = [:]
        let root = SCNNode()
        let pathRoot = SCNNode(),headRoot = SCNNode()
        var pathNodes:[String:SCNNode] = [:]
        var pathKeys:[String:String] = [:]
        var headNodes:[String:SCNNode] = [:]
        let schematicSpindle = SCNNode()
        let millingMachine = SCNNode()
        var schematicKey = ""
        var millingKey = ""
        var vertical = false
        var fitCenter = SCNVector3Zero
        var fitSpan = 80.0
        var cameraPreset = CAMCameraPreset.isometric
        var orthographic = false
        var needsFit = false
        var fittedSize = CGSize.zero
        weak var view:SCNView?
        var pickPaths:[CAMPreviewPath] = []
        var onSelectChapter:((String)->Void)?
        var chapterNames:[String:String] = [:]
        var summary:UIAccessibilityElement?
        var needsInitialRender = true
        var onSelectionBudget:(()->Void)?
        nonisolated func renderer(_ renderer:any SCNSceneRenderer,didRenderScene scene:SCNScene,atTime time:TimeInterval) {
            // SceneKit prepares its projection on the render thread. Initial
            // layout alone can precede that first frame and return empty picks.
            Task { @MainActor [weak self] in
                guard let self,let view = self.view,view.bounds.width>1,!self.nodes.isEmpty else { return }
                self.refreshAccessibility()
                if self.needsInitialRender { self.needsInitialRender = false;view.isPlaying = false }
            }
        }
        func refreshAccessibility() {
            guard let view,let summary else { return }
            summary.accessibilityFrameInContainerSpace = view.bounds
            var items:[UIAccessibilityElement] = [summary],seen = Set<String>(),probes = 0
            for path in pickPaths where seen.count<32 {
                guard probes<512 else { break }
                guard pathNodes[path.id]?.isHidden == false,!seen.contains(path.chapterID),path.pointsMM.count>1,let node = pathNodes[path.id] else { continue }
                let stride = max(1,(path.pointsMM.count-1)/24)
                for i in Swift.stride(from:1,to:path.pointsMM.count,by:stride) {
                    probes += 1;guard probes<=512 else { break }
                    let p = zip(path.pointsMM[i-1],path.pointsMM[i]).map { ($0+$1)/2 }
                    let local = vertical ? MillingMachineGeometry.point(p):SCNVector3(p[2],p[0],p[1])
                    let frame:()->CGRect = { [weak view,weak node] in
                        guard let view,let node,!node.isHidden else { return .zero }
                        let q = view.projectPoint(node.convertPosition(local,to:nil))
                        guard q.x.isFinite,q.y.isFinite,q.z.isFinite,q.z>=0,q.z<=1,view.bounds.insetBy(dx:24,dy:24).contains(CGPoint(x:CGFloat(q.x),y:CGFloat(q.y))) else { return .zero }
                        return CGRect(x:CGFloat(q.x)-9,y:CGFloat(q.y)-9,width:18,height:18)
                    }
                    guard !frame().isEmpty else { continue }
                    let element = CAMPathAccessibilityElement(accessibilityContainer:view)
                    element.accessibilityIdentifier = "cam.preview.path."+path.id
                    element.accessibilityLabel = L("选择工序：","Select operation: ")+(chapterNames[path.chapterID] ?? path.kind)
                    element.accessibilityTraits = .button;element.screenFrame = frame
                    element.activate = { [weak self] in self?.onSelectChapter?(path.chapterID) }
                    items.append(element);seen.insert(path.chapterID);break
                }
            }
            view.accessibilityElements = items
        }
        @objc func tapped(_ gesture:UITapGestureRecognizer) {
            guard gesture.state == .ended,let view,onSelectChapter != nil else { return }
            let visible = pickPaths.filter { pathNodes[$0.id]?.isHidden == false }
            guard visible.reduce(0,{ $0+max(0,$1.pointsMM.count-1) })<=200_000 else { onSelectionBudget?();return }
            let projected = visible.compactMap { path->CAMPathSelection.Path? in
                guard let node = pathNodes[path.id] else { return nil }
                let points = path.pointsMM.map { p->SIMD3<Double>? in
                    let local = vertical ? MillingMachineGeometry.point(p):SCNVector3(p[2],p[0],p[1])
                    let q = view.projectPoint(node.convertPosition(local,to:nil))
                    return SIMD3(Double(q.x),Double(q.y),Double(q.z))
                }
                return .init(id:path.id,chapterID:path.chapterID,points:points)
            }
            let p = gesture.location(in:view)
            if let hit = CAMPathSelection.nearest(to:.init(Double(p.x),Double(p.y)),paths:projected) { onSelectChapter?(hit.chapterID) }
        }
    }
    func makeCoordinator()->Coordinator { .init() }
    func makeUIView(context:Context)->SCNView {
        let view = CAMSceneView();view.scene = SCNScene();view.scene!.rootNode.addChildNode(context.coordinator.root)
        let c = context.coordinator
        view.onViewportLayout = { [weak view,weak c] in
            guard let view,let c else { return }
            if c.fittedSize != view.bounds.size { c.needsFit = true }
            Self.fitCamera(view,coordinator:c)
            c.refreshAccessibility()
        }
        view.backgroundColor = CAMPreviewMaterials.background;view.allowsCameraControl = true;view.antialiasingMode = .multisampling4X
        CAMPreviewMaterials.configureLighting(view.scene!)
        c.view = view
        view.delegate = c;view.preferredFramesPerSecond = 30;view.isPlaying = true
        let tap = UITapGestureRecognizer(target:c,action:#selector(Coordinator.tapped(_:)));tap.cancelsTouchesInView = false
        for old in view.gestureRecognizers ?? [] { if let doubleTap = old as? UITapGestureRecognizer,doubleTap.numberOfTapsRequired>1 { tap.require(toFail:doubleTap) } }
        view.addGestureRecognizer(tap)
        context.coordinator.root.addChildNode(context.coordinator.pathRoot)
        context.coordinator.root.addChildNode(context.coordinator.headRoot)
        context.coordinator.root.addChildNode(context.coordinator.schematicSpindle)
        context.coordinator.root.addChildNode(context.coordinator.millingMachine)
        let camera = SCNNode();camera.camera = SCNCamera();camera.camera?.zNear = 0.1;camera.camera?.zFar = 100_000
        view.scene!.rootNode.addChildNode(camera);view.pointOfView = camera
        view.isAccessibilityElement = false
        let summary = UIAccessibilityElement(accessibilityContainer:view)
        summary.accessibilityIdentifier = "manufacturing.virtual-spindles.viewport"
        summary.accessibilityLabel = L("加工仿真，可旋转和缩放","Machining simulation; rotate and zoom")
        c.summary = summary;view.accessibilityElements = [summary]
        return view
    }
    func updateUIView(_ view:SCNView,context:Context) {
        let c = context.coordinator
        c.vertical = vertical
        c.pickPaths = preview?.paths ?? [];c.onSelectChapter = onSelectChapter
        c.chapterNames = chapterNames
        c.onSelectionBudget = onSelectionBudget
        let reset = c.revision != revision
        if reset {
            c.needsInitialRender = true;view.isPlaying = true
            c.nodes.values.forEach { $0.removeFromParentNode() };c.nodes = [:];c.geometryKeys = [:];c.revision = revision
            c.pathRoot.childNodes.forEach { $0.removeFromParentNode() };c.pathNodes = [:];c.pathKeys = [:]
            c.headNodes.values.forEach { $0.removeFromParentNode() };c.headNodes = [:]
        }
        let active = Set(scene.bodies.map(\.id))
        for id in c.nodes.keys.filter({ !active.contains($0) }) { c.nodes.removeValue(forKey:id)?.removeFromParentNode();c.geometryKeys.removeValue(forKey:id) }
        SCNTransaction.begin();SCNTransaction.animationDuration = 0;SCNTransaction.disableActions = true
        for body in scene.bodies {
            let node:SCNNode
            if let existing = c.nodes[body.id] { node = existing }
            else { node = SCNNode();c.nodes[body.id] = node;c.root.addChildNode(node) }
            let key = body.geometryKey+":"+String(smooth && body.role == "stock")+":"+String(vertical)
            if c.geometryKeys[body.id] != key {
                node.childNodes.forEach { $0.removeFromParentNode() };node.geometry = nil
                let geometryNode = geometry(body)
                node.addChildNode(geometryNode);c.geometryKeys[body.id] = key
            }
            let placed = vertical && ["stock","fixture"].contains(body.role) ? preview!.machine!.worldFromWorkpiece.composed(with:body.frame) : body.frame
            node.simdTransform = transform(placed)
            if preview != nil {
                let detailedTool = preview?.tools.contains { "tool:"+$0.id == body.groupID } ?? false
                node.isHidden = body.role == "stock" ? !settings.showStock : ["cutter","shank","holder"].contains(body.role) ? (!settings.showTools || detailedTool) : body.role == "fixture" ? !settings.showFixtures : false
                node.opacity = body.role == "stock" && settings.translucentStock ? 0.35 : 1
            }
            if preview != nil,body.role != "stock" {
                let component:CAMSceneDisplay.Component = ["holder","shank"].contains(body.role) ? .holder : ["chuck","jaw","fixture"].contains(body.role) ? .workholding : body.role == "cutter" ? .cutting : .structure
                CAMSceneDisplay.apply(node,default:component,settings:settings)
            }
            for child in node.childNodes { child.geometry?.firstMaterial?.emission.contents = warningBodies.contains(body.id) ? UIColor.systemOrange.withAlphaComponent(0.6) : UIColor.black }
        }
        if let preview { updatePaths(preview,coordinator:c);updateHeads(preview,coordinator:c);updateSchematicSpindle(preview,coordinator:c);updateMillingMachine(preview,coordinator:c) }
        else { c.schematicSpindle.isHidden = true;c.millingMachine.isHidden = true }
        SCNTransaction.commit()
        if reset && !scene.bodies.isEmpty {
            var points:[SCNVector3]
            if preview != nil { points = CAMSceneDisplay.fittingPoints(c.root) }
            else {
                points = scene.bodies.map { coordinate($0.frame.translationMM) }
                for body in scene.bodies where body.role == "stock" { for p in body.shape.vertices ?? [] where points.count<150_000 { points.append(coordinate(body.frame.applied(to:p))) } }
            }
            if points.isEmpty { points = scene.bodies.map { coordinate($0.frame.translationMM) } }
            let x = points.map { Double($0.x) },y = points.map { Double($0.y) },z = points.map { Double($0.z) }
            let centre = SCNVector3((x.min()!+x.max()!)/2,(y.min()!+y.max()!)/2,(z.min()!+z.max()!)/2)
            let span = max(30,[(x.max()!-x.min()!),(y.max()!-y.min()!),(z.max()!-z.min()!)].max() ?? 80)
            c.fitCenter = centre;c.fitSpan = span;c.cameraPreset = settings.camera
            c.orthographic = preview != nil || settings.camera != .isometric;c.needsFit = true
            Self.fitCamera(view,coordinator:c)
        }
        if let preview {
            let tcp = preview.tools.first.map { $0.tipMM.map { String(format:"%.3f",$0) }.joined(separator:", ") } ?? L("无活动刀具","No active tool")
            let assembly = settings.showTools && scene.bodies.contains { ["holder","shank"].contains($0.role) }
            c.summary?.accessibilityValue = "machine \(preview.machine?.kind.rawValue ?? "cell"); TCP: \(tcp); \(preview.paths.count) "+L("条独立轨迹","separate paths")+"; assembly \(assembly ? "shown" : "hidden"); stock \(smooth ? "smoothed" : "raw"); scope \(settings.displayScope.rawValue); structure \(settings.structureDisplay.rawValue); spindle \(settings.spindleDisplay.rawValue); transparency \(String(format:"%.2f",settings.transparency))"
        } else { c.summary?.accessibilityValue = String(format:L("%.2f秒，%d个形体","%.2f seconds, %d bodies"),scene.seconds,scene.bodies.count) }
        c.refreshAccessibility()
        view.setNeedsDisplay()
    }
    @MainActor private static func fitCamera(_ view:SCNView,coordinator c:Coordinator) {
        // updateUIView can arrive before UIKit has assigned a viewport. Fitting
        // against a zero-size view produced an extreme zoom-out on first open.
        guard c.needsFit,view.bounds.width>1,view.bounds.height>1 else { return }
        let centre = c.fitCenter,span = c.fitSpan,offset:[Double]
        switch c.cameraPreset { case .isometric:offset = c.vertical ? [1.1,0.9,1.3] : [0.35,0.6,1.5];case .top:offset = [0,1.8,0.001];case .front:offset = [0,0,1.8];case .right:offset = [1.8,0,0] }
        view.pointOfView?.position = .init(Double(centre.x)+span*offset[0],Double(centre.y)+span*offset[1],Double(centre.z)+span*offset[2])
        view.pointOfView?.camera?.usesOrthographicProjection = c.orthographic
        let aspect = Double(view.bounds.width/view.bounds.height)
        view.pointOfView?.camera?.orthographicScale = span*0.65*max(1,1/aspect)
        view.defaultCameraController.target = centre;view.pointOfView?.look(at:centre)
        c.fittedSize = view.bounds.size;c.needsFit = false
    }
    private func transform(_ frame:CellRigidTransform)->simd_float4x4 {
        if vertical { return MillingMachineGeometry.frame(frame) }
        let r = frame.rotation,t = frame.translationMM
        return .init(columns:(.init(Float(r[8]),Float(r[2]),Float(r[5]),0),.init(Float(r[6]),Float(r[0]),Float(r[3]),0),
            .init(Float(r[7]),Float(r[1]),Float(r[4]),0),.init(Float(t[2]),Float(t[0]),Float(t[1]),1)))
    }
    private func pathFrame(_ frame:CellRigidTransform)->CellRigidTransform {
        vertical ? preview!.machine!.worldFromWorkpiece.composed(with:frame) : frame
    }
    private func updatePaths(_ frame:CAMPreviewFrame,coordinator c:Coordinator) {
        let active = Set(frame.paths.map(\.id))
        for id in c.pathNodes.keys.filter({ !active.contains($0) }) { c.pathNodes.removeValue(forKey:id)?.removeFromParentNode();c.pathKeys.removeValue(forKey:id) }
        for path in frame.paths {
            let node:SCNNode
            if let prior = c.pathNodes[path.id] { node = prior }
            else { node = SCNNode();c.pathNodes[path.id] = node;c.pathRoot.addChildNode(node) }
            let selection = settings.selectedChapterID.map { [$0] } ?? frame.activeChapterIDs
            node.isHidden = settings.paths == .hidden || (settings.paths == .selected && !selection.contains(path.chapterID))
            node.simdTransform = transform(pathFrame(path.frame))
            let done = path.end.map { $0<=frame.position } ?? false
            let tool = frame.tools.first { $0.pathID == path.id }
            let selected = settings.selectedChapterID == path.chapterID
            let key = "\(path.id):\(done):\(selected):\(tool?.pointIndex ?? -1):\(tool?.tipMM.description ?? "")"
            guard c.pathKeys[path.id] != key else { continue };c.pathKeys[path.id] = key
            node.childNodes.forEach { $0.removeFromParentNode() }
            let rapid = ["rapid","retract"].contains(path.moveType ?? "")
            let color:UIColor = rapid ? .systemOrange : selected ? .systemBlue : done ? .systemGreen : .systemTeal
            node.addChildNode(line(path.pointsMM,color:color,opacity:selected || done ? 1 : 0.4))
            if let tool,path.pointsMM.indices.contains(tool.pointIndex) {
                let localTip = path.frame.inverse.applied(to:tool.tipMM)
                let partial = Array(path.pointsMM.prefix(tool.pointIndex+1))+[localTip]
                node.addChildNode(line(partial,color:rapid ? .systemOrange : .systemGreen,opacity:1))
                let i = min(tool.pointIndex,max(0,path.pointsMM.count-2))
                if path.pointsMM.indices.contains(i+1) {
                    node.addChildNode(directionArrow(at:localTip,from:path.pointsMM[i],to:path.pointsMM[i+1],color:rapid ? .systemOrange : .systemGreen))
                }
            }
        }
    }
    private func directionArrow(at tip:[Double],from a:[Double],to b:[Double],color:UIColor)->SCNNode {
        let first = coordinate(a),last = coordinate(b)
        let delta = SIMD3<Float>(last.x-first.x,last.y-first.y,last.z-first.z)
        guard simd_length_squared(delta)>1e-12 else { return SCNNode() }
        let direction = simd_normalize(delta),length = max(1.2,min(4,cellSize*3))
        let cone = SCNCone(topRadius:0,bottomRadius:length*0.22,height:length)
        cone.radialSegmentCount = 20
        let material = SCNMaterial();material.diffuse.contents = color;material.lightingModel = .constant
        material.readsFromDepthBuffer = false;material.writesToDepthBuffer = false;cone.materials = [material]
        let node = SCNNode(geometry:cone),point = coordinate(tip)
        node.simdPosition = SIMD3(point.x,point.y,point.z)+direction*Float(length*0.5)
        node.simdOrientation = simd_quatf(from:SIMD3<Float>(0,1,0),to:direction)
        node.renderingOrder = 25;return node
    }
    private func line(_ points:[[Double]],color:UIColor,opacity:Double)->SCNNode {
        guard points.count>1 else { return SCNNode() }
        let source = SCNGeometrySource(vertices:points.map(coordinate))
        let indices = (1..<points.count).flatMap { [Int32($0-1),Int32($0)] }
        let geometry = SCNGeometry(sources:[source],elements:[SCNGeometryElement(indices:indices,primitiveType:.line)])
        let m = SCNMaterial();m.diffuse.contents = color;m.lightingModel = .constant;m.readsFromDepthBuffer = false;m.writesToDepthBuffer = false
        geometry.materials = [m];let node = SCNNode(geometry:geometry);node.opacity = opacity;node.renderingOrder = 20;return node
    }
    private func updateHeads(_ frame:CAMPreviewFrame,coordinator c:Coordinator) {
        let ids = Set(frame.tools.map(\.id))
        for id in c.headNodes.keys.filter({ !ids.contains($0) }) { c.headNodes.removeValue(forKey:id)?.removeFromParentNode() }
        for tool in frame.tools {
            let key = LathePreviewGeometry.signature(tool)
            if let old = c.headNodes[tool.id],old.name != key { old.removeFromParentNode();c.headNodes.removeValue(forKey:tool.id) }
            let node:SCNNode
            if let old = c.headNodes[tool.id] { node = old }
            else {
                node = SCNNode();let visual = LathePreviewGeometry.tool(tool)
                if vertical { visual.simdTransform = .init(columns:(.init(0,1,0,0),.init(1,0,0,0),.init(0,0,-1,0),.init(0,0,0,1))) }
                node.addChildNode(visual);node.name = key;c.headNodes[tool.id] = node;c.headRoot.addChildNode(node)
            }
            node.isHidden = !settings.showTools
            let risks = frame.collisions.filter { ["intersecting","clearance","uncertain","incomplete"].contains($0.state) }
            var warningParts = Set<CAMSceneDisplay.Component>()
            if risks.contains(where:{ $0.toolPart == "cutter" }) { warningParts.insert(.cutting) }
            if risks.contains(where:{ ["holder","shank"].contains($0.toolPart ?? "") }) { warningParts.insert(.holder) }
            CAMSceneDisplay.apply(node,default:.cutting,settings:settings,warningParts:warningParts)
            let actual:CellRigidTransform?
            if let machine = frame.machine,let tip = machine.machineToolTipMM,let axis = machine.machineToolAxis {
                actual = try? VirtualMachineSceneBuilder.alignedFrame(tip:tip,axis:axis)
            } else { actual = tool.displayFrame ?? (try? VirtualMachineSceneBuilder.alignedFrame(tip:tool.tipMM,axis:tool.axis)) }
            if let actual { node.simdTransform = transform(actual) }
            if let phase = tool.phaseDegrees,!tool.turning { node.childNode(withName:"cutter-rotor",recursively:true)?.eulerAngles.x = Float(phase.truncatingRemainder(dividingBy:360)*Double.pi/180) }
        }
    }
    private func updateMillingMachine(_ frame:CAMPreviewFrame,coordinator c:Coordinator) {
        c.millingMachine.isHidden = !vertical
        guard vertical,let machine = frame.machine else { return }
        let fixtureZ = frame.scene.bodies.filter { $0.role == "fixture" && $0.shape.type == .box }.map { $0.frame.translationMM[2]-($0.shape.halfExtentsMM?[2] ?? 0) }.min() ?? machine.stockMinMM[2]
        let supportZ = min(machine.stockMinMM[2],fixtureZ)
        let key = "\(machine.kind):\(machine.stockMinMM):\(machine.stockMaxMM):\(machine.gaugeLengthMM ?? 0):\(supportZ)"
        if c.millingKey != key { MillingMachineGeometry.install(machine,fixtureBaseZ:supportZ,on:c.millingMachine);c.millingKey = key }
        MillingMachineGeometry.update(machine,tools:frame.tools,on:c.millingMachine)
        CAMSceneDisplay.apply(c.millingMachine,default:.structure,settings:settings)
    }
    private func updateSchematicSpindle(_ frame:CAMPreviewFrame,coordinator c:Coordinator) {
        c.schematicSpindle.isHidden = !frame.latheStock || frame.scene.bodies.contains { $0.role == "chuck" }
        guard !c.schematicSpindle.isHidden,let stock = frame.scene.bodies.first(where:{ $0.role == "stock" }),let r = frame.latheStockRadiusMM,let z = frame.latheDatumZMM else { return }
        let key = "solid-lathe:\(r)"
        if c.schematicKey != key {
            c.schematicKey = key;c.schematicSpindle.childNodes.forEach { $0.removeFromParentNode() }
            c.schematicSpindle.addChildNode(LathePreviewGeometry.spindle(stockRadius:r))
        }
        // Housing remains fixed. Only the spindle/chuck/jaws follow the
        // workpiece's commanded phase, rather than rotating the whole housing.
        c.schematicSpindle.position = coordinate(stock.frame.applied(to:[0,0,z]))
        let phase = atan2(stock.frame.rotation[3],stock.frame.rotation[0])
        c.schematicSpindle.childNode(withName:"spindle-rotor",recursively:true)?.eulerAngles.x = Float(phase)
        CAMSceneDisplay.apply(c.schematicSpindle,default:.spindle,settings:settings)
    }
    private func coordinate(_ value:[Double])->SCNVector3 { vertical ? MillingMachineGeometry.point(value) : .init(value[2],value[0],value[1]) }
    private func geometry(_ body:VirtualSceneBody)->SCNNode {
        let node = SCNNode(),shape = body.shape
        switch shape.type {
        case .box:
            let d = shape.halfExtentsMM!
            node.geometry = SCNBox(width:(vertical ? d[0]:d[2])*2,height:(vertical ? d[2]:d[0])*2,length:d[1]*2,chamferRadius:0)
            if preview?.latheStock == true,body.role == "fixture" {
                let h = vertical ? [d[0],d[2],d[1]]:[d[2],d[0],d[1]]
                let corners = (0..<8).map { i in SCNVector3((i&1 == 0 ? -1:1)*h[0],(i&2 == 0 ? -1:1)*h[1],(i&4 == 0 ? -1:1)*h[2]) }
                let edges = (0..<8).flatMap { i in [1,2,4].filter { i & $0 == 0 }.flatMap { [Int32(i),Int32(i|$0)] } }
                node.geometry = SCNGeometry(sources:[SCNGeometrySource(vertices:corners)],elements:[SCNGeometryElement(indices:edges,primitiveType:.line)])
            }
        case .cylinder:
            let cylinder = SCNCylinder(radius:shape.radiusMM!,height:shape.lengthMM!);cylinder.radialSegmentCount = 96
            node.geometry = cylinder;if !vertical { node.eulerAngles.z = -.pi/2 }
        case .capsule:
            node.geometry = SCNCapsule(capRadius:shape.radiusMM!,height:shape.lengthMM!+2*shape.radiusMM!);if !vertical { node.eulerAngles.z = -.pi/2 }
        case .mesh:
            node.geometry = CAMSurfaceGeometry.make(shape.vertices!,triangles:shape.triangles!,smooth:smooth && body.role == "stock",cellSize:cellSize,coordinate:coordinate)
        }
        let material = CAMPreviewMaterials.make(role:body.role)
        if preview?.latheStock == true,body.role == "fixture",shape.type == .box { material.lightingModel = .constant;material.diffuse.contents = UIColor.gray;material.transparency = 0.6 }
        if body.role == "stock" && body.geometryClass == .outerEnvelope { material.fillMode = .lines;material.transparency = 0.45 }
        material.isDoubleSided = true;material.transparencyMode = .dualLayer;node.geometry?.materials = [material];return node
    }
}
#endif
