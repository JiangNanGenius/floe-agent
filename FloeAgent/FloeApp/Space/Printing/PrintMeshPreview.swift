// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SceneKit
import SwiftUI
import UIKit
import simd
import FloePrintCore

/// Displays the exact immutable mesh used by the slicer, in millimetres.
/// It has no second mesh parser or unsaved substitute geometry.
struct PrintMeshPreview: View {
    let disk: PrintProjectDisk
    let document: PrintProjectDocument
    @State private var mesh: PrintMesh?
    @State private var diagnostic: String?

    var body: some View {
        Group {
            if let mesh {
                PrintMeshScene(mesh: mesh, identity: document.meshAsset ?? "", preset: document.preset)
            } else if let diagnostic {
                ContentUnavailableView {
                    Label(IDELanguageRunText.t("预览未能打开", "Unable to open preview"), systemImage: "cube")
                } description: { Text(diagnostic) }
            } else { ProgressView() }
        }
        .frame(minHeight: 280, idealHeight: 340)
        .accessibilityLabel(IDELanguageRunText.t("打印模型三维预览", "3D print model preview"))
        .task(id: document.meshAsset) {
            do { mesh = try await disk.mesh(document); diagnostic = nil }
            catch { diagnostic = error.localizedDescription }
        }
    }
}

private struct PrintMeshScene: UIViewRepresentable {
    let mesh: PrintMesh
    let identity: String
    let preset: PrintPreset

    final class Coordinator { var identity: String?; var preset: PrintPreset? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene(); view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .secondarySystemGroupedBackground
        return view
    }
    func updateUIView(_ view: SCNView, context: Context) {
        guard context.coordinator.identity != identity || context.coordinator.preset != preset else { return }
        context.coordinator.identity = identity; context.coordinator.preset = preset
        let scene = SCNScene()
        let vertices = stride(from: 0, to: mesh.positions.count, by: 3).map {
            SCNVector3(mesh.positions[$0], mesh.positions[$0 + 2], -mesh.positions[$0 + 1])
        }
        let indices = (0..<vertices.count).map(UInt32.init)
        let source = SCNGeometrySource(vertices: vertices)
        var normals = [SCNVector3](); normals.reserveCapacity(vertices.count)
        for index in stride(from: 0, to: vertices.count, by: 3) {
            let a = SIMD3<Float>(vertices[index].x, vertices[index].y, vertices[index].z)
            let b = SIMD3<Float>(vertices[index + 1].x, vertices[index + 1].y, vertices[index + 1].z)
            let c = SIMD3<Float>(vertices[index + 2].x, vertices[index + 2].y, vertices[index + 2].z)
            let cross = simd_cross(b - a, c - a)
            let normal = simd_length_squared(cross) > 0 ? simd_normalize(cross) : SIMD3<Float>(0, 1, 0)
            normals.append(contentsOf: Array(repeating: SCNVector3(normal.x, normal.y, normal.z), count: 3))
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [source, SCNGeometrySource(normals: normals)], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemTeal
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.7
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        scene.rootNode.addChildNode(node)
        let bed = preset.bed
        let plate = SCNNode(geometry: SCNBox(width: bed.width, height: 0.2, length: bed.depth, chamferRadius: 0))
        plate.position.y = -0.1
        plate.geometry?.firstMaterial?.diffuse.contents = UIColor.tertiarySystemFill
        plate.geometry?.firstMaterial?.transparency = 0.45
        scene.rootNode.addChildNode(plate)
        let bounds = node.boundingBox
        let center = SCNVector3((bounds.min.x + bounds.max.x) / 2,
            (bounds.min.y + bounds.max.y) / 2, (bounds.min.z + bounds.max.z) / 2)
        let radius = max(15, max(bounds.max.x - bounds.min.x, max(bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z)))
        let camera = SCNNode(); camera.camera = SCNCamera()
        camera.camera?.zNear = 0.1; camera.camera?.zFar = Double(max(2_000, radius * 20))
        camera.position = SCNVector3(center.x + radius, center.y + radius * 0.8, center.z + radius * 1.8)
        camera.look(at: center)
        scene.rootNode.addChildNode(camera)
        view.scene = scene; view.pointOfView = camera
        view.defaultCameraController.target = center
    }
}
#endif
