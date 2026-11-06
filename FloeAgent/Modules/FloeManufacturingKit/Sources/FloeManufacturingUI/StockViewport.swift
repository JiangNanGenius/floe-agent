// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import SceneKit
import FloeManufacturingCore
import simd

struct StockViewport: UIViewRepresentable {
    var study: ManufacturingStudy
    var inputRevision: UUID
    var artifact: ManufacturingArtifact?
    var replay: Double
    var showPaths: Bool
    var showFixtures: Bool
    var smoothStock: Bool
    var showAssembly: Bool
    var showReference: Bool
    final class Coordinator {
        var signature = ""
        var studyID: UUID?
        var hadAssembly = false
        var cameraSpan: Float = 0
        let stock = SCNNode(), paths = SCNNode(), fixtures = SCNNode(), tool = SCNNode(), axis = SCNNode(), assembly = SCNNode(), reference = SCNNode()
        var activeToolSignature = ""
        var pathIndices:[Int] = []
        var pointIndices:[Int] = []
        var samples: [SCNVector3] = []
    }
    func makeCoordinator() -> Coordinator { .init() }
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene(); view.backgroundColor = .secondarySystemGroupedBackground
        view.antialiasingMode = .multisampling4X; view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        let scene = view.scene!, c = context.coordinator
        for node in [c.stock,c.paths,c.fixtures,c.tool,c.reference] { scene.rootNode.addChildNode(node) }
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 180
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .directional; key.light?.intensity = 1000; key.eulerAngles = .init(-Double.pi/4,-Double.pi/4,0)
        scene.rootNode.addChildNode(key)
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera?.zNear = 0.1; camera.camera?.zFar = 2000
        camera.position = SCNVector3(65,40,65); camera.look(at:SCNVector3(20,0,0))
        scene.rootNode.addChildNode(camera); view.pointOfView = camera
        c.tool.geometry = SCNSphere(radius:0.9); c.tool.geometry?.firstMaterial?.diffuse.contents = UIColor.systemTeal
        c.tool.addChildNode(c.axis)
        c.tool.addChildNode(c.assembly)
        view.accessibilityIdentifier = "manufacturing.viewport"
        view.isAccessibilityElement = true
        view.accessibilityLabel = L("三维去料预览，可旋转和缩放","3D stock preview; rotate and zoom")
        return view
    }
    func updateUIView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        let bounds = study.stock.bounds
        guard bounds.min.count == 3, bounds.max.count == 3, (bounds.min+bounds.max).allSatisfy(\.isFinite),
              zip(bounds.min,bounds.max).allSatisfy({ $0.0 < $0.1 }), study.stock.radiusMM.isFinite, study.stock.radiusMM > 0,
              study.stock.resolutionMM.isFinite, study.stock.resolutionMM > 0 else {
            c.stock.geometry = nil; c.stock.childNodes.forEach { $0.removeFromParentNode() }; c.tool.isHidden = true
            view.accessibilityValue = "invalid stock dimensions"; return
        }
        let stockSpan = zip(bounds.min,bounds.max).map { $1-$0 }.max() ?? 40
        let holderSpan = max(study.millingAssembly?.holderProfile.last?.axialMM ?? 0,study.cam?.tools.compactMap { $0.assembly?.holderProfile.last?.axialMM }.max() ?? 0)
        let span = Float(max(stockSpan,holderSpan*1.5))
        if c.studyID != study.id || c.hadAssembly != (study.millingAssembly != nil) || c.cameraSpan != span {
            c.studyID = study.id
            c.hadAssembly = study.millingAssembly != nil
            c.cameraSpan = span
            let center = coordinate(zip(bounds.min,bounds.max).map { ($0+$1)/2 })
            view.pointOfView?.position = SCNVector3(center.x+span*1.5,center.y+span,center.z+span*1.5)
            view.pointOfView?.look(at:center)
            view.pointOfView?.camera?.zFar = max(2000,Double(span)*12)
        }
        let frames = artifact?.result.frames ?? []
        let timeline = study.acMotion == nil ? artifact?.result.cuttingTimeline : nil
        let sample: CuttingTimeline.Sample?
        if let timeline, timeline.excludedPathIndices.isEmpty {
            sample = try? timeline.sample(atSeconds:replay*timeline.totalSeconds)
        } else { sample = nil }
        let timedPath:ManufacturingResult.Path? = sample.flatMap { sample in
            guard let paths = artifact?.result.paths, paths.indices.contains(sample.pathIndex) else { return nil }
            return paths[sample.pathIndex]
        }
        let timedKind = timedPath?.kind
        let timedFrameName = timedPath?.operationID.map { "cam-"+$0 } ?? (timedKind == "milling-slot" ? "milling" : timedKind)
        let frameIndex: Int
        if frames.isEmpty || replay >= 1 { frameIndex = -1 }
        else if let name = timedFrameName, let stages = artifact?.result.stages,
                let current = stages.firstIndex(where:{ $0.name == name }) {
            let completed = Set(["initial"]+stages.prefix(current).map(\.name))
            frameIndex = frames.lastIndex(where:{ completed.contains($0.name) }) ?? 0
        } else { frameIndex = min(frames.count-1,Int(Double(frames.count)*replay)) }
        let signature = "\(inputRevision)-\(artifact?.inputSHA256 ?? "blank")-\(artifact?.elapsedSeconds ?? 0)-\(frameIndex)-\(smoothStock)"
        if signature != c.signature {
            c.signature = signature
            for node in [c.stock,c.paths,c.fixtures,c.reference] { node.childNodes.forEach { $0.removeFromParentNode() } }
            c.stock.geometry = nil; c.reference.geometry = nil; c.samples = []; c.pathIndices = []; c.pointIndices = []; c.activeToolSignature = ""
            c.assembly.childNodes.forEach { $0.removeFromParentNode() }
            c.axis.geometry = nil
            if let reference = study.cam?.partMesh {
                let geometry = mesh(vertices:reference.vertices,triangles:reference.triangles,smoothing:false)
                geometry.firstMaterial?.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.35)
                geometry.firstMaterial?.fillMode = .lines
                c.reference.geometry = geometry
            }
            if let result = artifact?.result {
                c.stock.geometry = frameIndex >= 0 ? mesh(vertices:frames[frameIndex].vertices,triangles:frames[frameIndex].triangles) : mesh(vertices:result.vertices,triangles:result.triangles)
                for (pathIndex,path) in result.paths.enumerated() {
                    let points = path.points.map(coordinate)
                    c.samples.append(contentsOf:points)
                    c.pathIndices.append(contentsOf:Array(repeating:pathIndex,count:points.count))
                    c.pointIndices.append(contentsOf:points.indices)
                    guard points.count >= 2 else { continue }
                    let source = SCNGeometrySource(vertices:points)
                    var indices = [Int32](); for i in 1..<points.count { indices += [Int32(i-1),Int32(i)] }
                    let geometry = SCNGeometry(sources:[source],elements:[SCNGeometryElement(indices:indices,primitiveType:.line)])
                    geometry.firstMaterial?.diffuse.contents = ["rapid","retract"].contains(path.moveType ?? "") ? UIColor.systemOrange : UIColor.systemTeal
                    geometry.firstMaterial?.lightingModel = .constant
                    c.paths.addChildNode(SCNNode(geometry:geometry))
                }
                if let ac = result.acPoses, !ac.isEmpty { c.samples = ac.map { coordinate($0.tipMM) } }
            } else {
                let blank:SCNGeometry
                let node:SCNNode
                if study.stock.isBox {
                    blank = SCNBox(width:bounds.max[2]-bounds.min[2],height:bounds.max[0]-bounds.min[0],length:bounds.max[1]-bounds.min[1],chamferRadius:0)
                    node = SCNNode(geometry:blank)
                    node.position = coordinate(zip(bounds.min,bounds.max).map { ($0+$1)/2 })
                } else {
                    blank = SCNCylinder(radius:study.stock.radiusMM,height:study.stock.zMaxMM-study.stock.zMinMM)
                    node = SCNNode(geometry:blank); node.eulerAngles.z = -.pi/2
                    node.position.x = Float((study.stock.zMaxMM+study.stock.zMinMM)/2)
                }
                c.stock.addChildNode(node)
                blank.firstMaterial?.diffuse.contents = UIColor.systemGray3
                blank.firstMaterial?.metalness.contents = 0.5
            }
            for fixture in study.fixtures {
                let lo = fixture.minMM, hi = fixture.maxMM
                let box = SCNBox(width:hi[2]-lo[2],height:hi[0]-lo[0],length:hi[1]-lo[1],chamferRadius:0)
                let node = SCNNode(geometry:box)
                node.position = coordinate(zip(lo,hi).map { ($0.0+$0.1)/2 })
                box.firstMaterial?.diffuse.contents = UIColor.systemGray.withAlphaComponent(0.4)
                c.fixtures.addChildNode(node)
            }
        }
        c.paths.isHidden = !showPaths; c.fixtures.isHidden = !showFixtures; c.reference.isHidden = !showReference
        c.tool.isHidden = c.samples.isEmpty || artifact == nil
        if !c.samples.isEmpty { c.tool.position = c.samples[min(c.samples.count-1,Int(Double(c.samples.count-1)*replay))] }
        if let sample { c.tool.position = coordinate(sample.pointMM) }
        let phase = frameIndex >= 0 ? frames[frameIndex].name : ""
        let localProgress = frames.isEmpty ? replay : min(1,max(0,replay*Double(frames.count)-Double(frameIndex)))
        var powerAxis: SIMD3<Float>?
        var activeCAMPath = timedPath
        var activePointIndex = sample.flatMap { artifact?.result.cuttingTimeline?.segments[$0.segmentIndex].startPointIndex } ?? 0
        if sample == nil, !c.pathIndices.isEmpty, study.acMotion == nil {
            let i = min(c.pathIndices.count-1,Int(Double(c.pathIndices.count-1)*replay))
            activeCAMPath = artifact?.result.paths[c.pathIndices[i]]; activePointIndex = c.pointIndices[i]
        }
        var cutterKind = "flatEndMill", cutterRadius = study.milling.toolRadiusMM, cutterLength = study.milling.toolLengthMM
        var tipAngle:Double?, activeAssembly = study.millingAssembly
        if let path = activeCAMPath, let id = path.toolID, let tool = study.cam?.tools.first(where:{ $0.id == id }),
           let axes = path.toolAxes, axes.indices.contains(activePointIndex) {
            var axis = SIMD3<Double>(axes[activePointIndex][0],axes[activePointIndex][1],axes[activePointIndex][2])
            if let sample, path.points.indices.contains(activePointIndex+1), axes.indices.contains(activePointIndex+1) {
                let a = path.points[activePointIndex], b = path.points[activePointIndex+1]
                let delta = SIMD3(b[0]-a[0],b[1]-a[1],b[2]-a[2]), v = SIMD3(sample.pointMM[0]-a[0],sample.pointMM[1]-a[1],sample.pointMM[2]-a[2])
                let tau = simd_length_squared(delta) > 1e-16 ? max(0,min(1,simd_dot(v,delta)/simd_length_squared(delta))) : 0
                if let interpolated = try? ToolAxisInterpolation.interpolate(axes[activePointIndex],axes[activePointIndex+1],fraction:tau) {
                    axis = SIMD3(interpolated[0],interpolated[1],interpolated[2])
                }
            }
            powerAxis = SIMD3(Float(axis.z),Float(axis.x),Float(axis.y))
            cutterKind = tool.kind; cutterRadius = tool.diameterMM/2; cutterLength = tool.cuttingLengthMM
            tipAngle = tool.tipAngleDegrees; activeAssembly = tool.assembly
        }
        if powerAxis != nil {
            // The current CAM path owns its exact cutter and assembly.
        } else if timedKind == "milling-slot" {
            let angle = study.milling.angleDegrees * .pi/180
            powerAxis = SIMD3<Float>(0,Float(cos(angle)),Float(sin(angle)))
        } else if sample != nil {
            // Turning has no validated non-cutting-body orientation in this prototype.
            powerAxis = nil
        } else if phase == "ac", let poses = artifact?.result.acPoses, !poses.isEmpty {
            let pose = poses[min(poses.count-1,Int((Double(poses.count-1)*localProgress).rounded()))]
            c.tool.position = coordinate(pose.tipMM)
            powerAxis = SIMD3<Float>(Float(pose.axis[2]),Float(pose.axis[0]),Float(pose.axis[1]))
        } else if phase == "milling", let path = artifact?.result.paths.first(where:{ $0.kind == "milling-slot" }), !path.points.isEmpty {
            let point = path.points[min(path.points.count-1,Int((Double(path.points.count-1)*localProgress).rounded()))]
            c.tool.position = coordinate(point)
            let angle = study.milling.angleDegrees * .pi/180
            powerAxis = SIMD3<Float>(0,Float(cos(angle)),Float(sin(angle)))
        }
        if let direction = powerAxis {
            c.tool.geometry = nil
            let toolSignature = "\(cutterKind):\(cutterRadius):\(cutterLength):\(tipAngle ?? 0):\(activeAssembly.map { String(decoding:(try? ManufacturingStudy.encoder.encode($0)) ?? Data(),as:UTF8.self) } ?? "")"
            if c.activeToolSignature != toolSignature {
                c.activeToolSignature = toolSignature
                CutterGeometry.install(kind:cutterKind,radius:cutterRadius,length:cutterLength,tipAngle:tipAngle,on:c.axis)
                c.assembly.childNodes.forEach { $0.removeFromParentNode() }
                if let activeAssembly { ToolAssemblyGeometry.install(activeAssembly,cuttingLengthMM:cutterLength,on:c.assembly) }
            }
            c.tool.simdOrientation = simd_quatf(from:SIMD3<Float>(0,1,0),to:simd_normalize(direction))
            c.axis.position = SCNVector3Zero; c.axis.simdOrientation = simd_quatf(real:1,imag:.zero)
            c.axis.isHidden = false; c.assembly.simdOrientation = simd_quatf(real:1,imag:.zero)
            c.assembly.isHidden = !showAssembly || activeAssembly == nil
        } else {
            c.axis.isHidden = true; c.assembly.isHidden = true; c.tool.simdOrientation = simd_quatf(real:1,imag:.zero)
            if c.tool.geometry == nil { c.tool.geometry = SCNSphere(radius:0.9); c.tool.geometry?.firstMaterial?.diffuse.contents = UIColor.systemTeal }
        }
        let faces = artifact?.result.triangles.count ?? 0
        view.accessibilityValue = faces > 0 ? "\(faces) triangles; assembly \(c.assembly.isHidden ? "hidden" : "shown")" : "blank stock"
    }
    private func coordinate(_ p: [Double]) -> SCNVector3 { SCNVector3(Float(p[2]),Float(p[0]),Float(p[1])) }
    private func mesh(vertices inputVertices: [[Double]], triangles: [[Int]],smoothing:Bool = true) -> SCNGeometry {
        let geometry = CAMSurfaceGeometry.make(inputVertices,triangles:triangles,smooth:smoothStock && smoothing,cellSize:study.stock.resolutionMM,coordinate:coordinate)
        let material = SCNMaterial(); material.diffuse.contents = UIColor.systemGray3
        material.lightingModel = .physicallyBased; material.metalness.contents = 0.35; material.roughness.contents = 0.65
        geometry.materials = [material]; return geometry
    }
}
#endif
