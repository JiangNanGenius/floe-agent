// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SceneKit
import SwiftUI
import UIKit
import simd
import FloePrintCore

private struct PrintPreviewObject: Sendable {
    let id: UUID, mesh: PrintMesh, name: String, toolID: Int
}
/// Every displayed object reads its exact saved slicing geometry.
struct PrintMeshPreview: View {
    let disk: PrintProjectDisk
    let document: PrintProjectDocument
    var machine: PrintMachineConfiguration? = nil
    var selectedObjectID: UUID? = nil
    var reset: Int = 0
    var selectObject: (UUID) -> Void = { _ in }
    @State private var objects: [PrintPreviewObject] = []
    @State private var diagnostic: String?
    @State private var geometryGeneration = UUID()
    var body: some View {
        Group {
            if let diagnostic {
                ContentUnavailableView { Label(IDELanguageRunText.t("预览未能打开", "Unable to open preview"), systemImage: "cube") } description: { Text(diagnostic) }
            } else {
                PrintMeshScene(objects: objects, identity: "\(document.revision):\(geometryGeneration):\(reset)", preset: document.preset, machine: machine ?? document.machine ?? .generic(for: document.preset), selected: selectedObjectID, selectObject: selectObject)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(IDELanguageRunText.t("打印模型三维预览", "3D print model preview"))
            .task(id: document.revision) {
                do {
                    var loaded = [PrintPreviewObject]()
                    for object in document.objects ?? [] where object.plateID == document.plateID {
                        loaded.append(.init(id: object.id, mesh: try await disk.meshAsset(object.meshAsset), name: object.name, toolID: object.toolID))
                    }
                    if document.objects == nil, document.meshAsset != nil { loaded = [.init(id: document.plateID, mesh: try await disk.mesh(document), name: document.meshName ?? "", toolID: 0)] }
                    try Task.checkCancellation(); objects = loaded; geometryGeneration = UUID(); diagnostic = nil
                } catch { if !Task.isCancelled { diagnostic = error.localizedDescription } }
            }
    }
}

private struct PrintMeshScene: UIViewRepresentable {
    let objects: [PrintPreviewObject]
    let identity: String
    let preset: PrintPreset
    let machine: PrintMachineConfiguration
    let selected: UUID?
    var selectObject: (UUID) -> Void
    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var identity: String?
        var machine: PrintMachineConfiguration?
        var selected: UUID?
        var reset: String?
        var selectObject: (UUID) -> Void = { _ in }
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }
            let hits = view.hitTest(gesture.location(in: view), options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            if let id = hits.compactMap({ $0.node.name.flatMap(UUID.init(uuidString:)) }).first { selectObject(id) }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(); view.scene = SCNScene(); view.allowsCameraControl = true; view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X; view.backgroundColor = .secondarySystemGroupedBackground
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:))); tap.delegate = context.coordinator; view.addGestureRecognizer(tap)
        return view
    }
    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.selectObject = selectObject
        guard context.coordinator.identity != identity || context.coordinator.machine != machine || context.coordinator.selected != selected else { return }
        let oldIdentity = context.coordinator.identity
        context.coordinator.identity = identity; context.coordinator.machine = machine; context.coordinator.selected = selected
        let scene = SCNScene(), sign: Float = preset == .genericCTBV3 && machine.resin.invertedPlatform ? -1 : 1
        for object in objects {
            let p = object.mesh.positions
            let vertices = stride(from: 0, to: p.count, by: 3).map { SCNVector3(p[$0], p[$0 + 2] * sign, -p[$0 + 1]) }
            var normals = [SCNVector3](); normals.reserveCapacity(vertices.count)
            for i in stride(from: 0, to: vertices.count, by: 3) {
                let a = SIMD3<Float>(vertices[i].x, vertices[i].y, vertices[i].z), b = SIMD3<Float>(vertices[i + 1].x, vertices[i + 1].y, vertices[i + 1].z), c = SIMD3<Float>(vertices[i + 2].x, vertices[i + 2].y, vertices[i + 2].z)
                let cross = simd_cross(b - a, c - a), normal = simd_length_squared(cross) > 0 ? simd_normalize(cross) : SIMD3<Float>(0, sign, 0)
                normals += Array(repeating: SCNVector3(normal.x, normal.y, normal.z), count: 3)
            }
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)], elements: [SCNGeometryElement(indices: vertices.indices.map(UInt32.init), primitiveType: .triangles)])
            let material = SCNMaterial(); material.diffuse.contents = preset == .genericCTBV3 ? UIColor.systemPurple : object.toolID == 0 ? UIColor.systemTeal : UIColor.systemOrange
            material.lightingModel = .physicallyBased; material.roughness.contents = 0.7; material.isDoubleSided = true
            if object.id == selected { material.emission.contents = UIColor.systemTeal.withAlphaComponent(0.15) }
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry); node.name = object.id.uuidString; scene.rootNode.addChildNode(node)
        }
        let width = machine.bedWidth, depth = machine.bedDepth
        let plate = SCNNode(geometry: SCNBox(width: width, height: 0.35, length: depth, chamferRadius: 0))
        plate.position.y = sign > 0 ? -0.3 : 0.3; plate.geometry?.firstMaterial?.diffuse.contents = UIColor.tertiarySystemFill; plate.geometry?.firstMaterial?.transparency = 0.65
        scene.rootNode.addChildNode(plate)
        var lines = [SCNVector3]()
        let surface = sign * -0.1
        for x in stride(from: -width / 2, through: width / 2, by: 10) { lines += [SCNVector3(x, Double(surface), -depth / 2), SCNVector3(x, Double(surface), depth / 2)] }
        for y in stride(from: -depth / 2, through: depth / 2, by: 10) { lines += [SCNVector3(-width / 2, Double(surface), y), SCNVector3(width / 2, Double(surface), y)] }
        let grid = SCNGeometry(sources: [SCNGeometrySource(vertices: lines)], elements: [SCNGeometryElement(indices: lines.indices.map(UInt32.init), primitiveType: .line)])
        grid.firstMaterial?.diffuse.contents = UIColor.separator; grid.firstMaterial?.lightingModel = .constant; scene.rootNode.addChildNode(SCNNode(geometry: grid))
        let origin = SCNNode(geometry: SCNSphere(radius: 1.4)); origin.geometry?.firstMaterial?.diffuse.contents = UIColor.systemRed
        let originX = machine.origin == .frontLeft || machine.origin == .rearLeft ? -width / 2 : 0
        let originY = machine.origin == .frontLeft ? -depth / 2 : machine.origin == .rearLeft ? depth / 2 : 0
        origin.position = SCNVector3(originX, Double(sign) * 0.5, -originY); scene.rootNode.addChildNode(origin)
        let keepCamera = oldIdentity?.split(separator: ":").last == identity.split(separator: ":").last
        let camera = keepCamera ? view.pointOfView ?? SCNNode() : SCNNode()
        if camera.camera == nil {
            let radius = max(width, depth)
            camera.camera = SCNCamera(); camera.camera?.zNear = 0.1; camera.camera?.zFar = max(5_000, radius * 20)
            camera.position = SCNVector3(radius * 0.65, Double(sign) * radius * 0.7, radius * 0.9); camera.look(at: SCNVector3(0, sign * 12, 0))
        }
        camera.removeFromParentNode(); scene.rootNode.addChildNode(camera); view.scene = scene; view.pointOfView = camera; view.defaultCameraController.target = SCNVector3(0, sign * 12, 0)
    }
}
#endif
