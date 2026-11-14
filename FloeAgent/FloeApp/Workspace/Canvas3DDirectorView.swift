// FloeApp — Native RealityKit canvas scene preview.
//
// SPDX-License-Identifier: MPL-2.0
//
// The interactive 3D Director was retired: editing a canvas scene now happens
// through the current Canvas surfaces and legacy scenes are migrated by
// LegacySceneMigrationService. This file keeps the read/select preview used by
// the existing scene3D canvas node.

#if canImport(SwiftUI) && canImport(UIKit) && canImport(RealityKit)
import SwiftUI
import UIKit
import RealityKit
import simd
import FloeCore

struct Canvas3DScenePreview: UIViewRepresentable {
    let scene: CanvasScene3D
    var selectedObjectID: UUID?
    var onSelect: ((UUID) -> Void)?

    init(
        scene: CanvasScene3D,
        selectedObjectID: UUID? = nil,
        onSelect: ((UUID) -> Void)? = nil
    ) {
        self.scene = scene
        self.selectedObjectID = selectedObjectID
        self.onSelect = onSelect
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(
            frame: .zero,
            cameraMode: .nonAR,
            automaticallyConfigureSession: false
        )
        view.renderOptions.insert(.disableMotionBlur)
        view.isUserInteractionEnabled = onSelect != nil
        if onSelect != nil {
            let tap = UITapGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleTap(_:))
            )
            view.addGestureRecognizer(tap)
        }
        context.coordinator.view = view
        context.coordinator.render(scene, selectedObjectID: selectedObjectID)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.render(scene, selectedObjectID: selectedObjectID)
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var view: ARView?
        var onSelect: ((UUID) -> Void)?
        private var renderedScene: CanvasScene3D?
        private var renderedSelection: UUID?

        init(onSelect: ((UUID) -> Void)?) {
            self.onSelect = onSelect
        }

        func render(_ scene: CanvasScene3D, selectedObjectID: UUID?) {
            guard renderedScene != scene || renderedSelection != selectedObjectID,
                  let view else { return }
            renderedScene = scene
            renderedSelection = selectedObjectID
            view.scene.anchors.removeAll()
            view.environment.background = .color(UIColor(sceneBackground: scene.background))

            let root = AnchorEntity(world: .zero)
            view.scene.addAnchor(root)

            addFloor(to: root, scene: scene)
            for object in scene.objects where !object.isHidden {
                let entity = makeEntity(object, isSelected: object.id == selectedObjectID)
                root.addChild(entity)
            }
            addLights(to: root, lighting: scene.lighting)
            addCamera(to: root, camera: scene.camera)
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view,
                  let entity = view.entity(at: recognizer.location(in: view)) else { return }
            var candidate: Entity? = entity
            while let current = candidate {
                if let id = UUID(uuidString: current.name) {
                    onSelect?(id)
                    return
                }
                candidate = current.parent
            }
        }

        private func makeEntity(_ object: CanvasSceneObject, isSelected: Bool) -> ModelEntity {
            let mesh: MeshResource
            switch object.kind {
            case .box:
                mesh = .generateBox(size: 1, cornerRadius: 0.08)
            case .sphere:
                mesh = .generateSphere(radius: 0.5)
            case .cylinder:
                mesh = .generateCylinder(height: 1, radius: 0.5)
            case .cone:
                mesh = .generateCone(height: 1, radius: 0.5)
            case .plane:
                mesh = .generateBox(size: SIMD3<Float>(1, 0.04, 1), cornerRadius: 0.02)
            }
            var color = UIColor(floeHex: object.colorHex)
            if isSelected { color = color.withAlphaComponent(0.9) }
            let material = SimpleMaterial(
                color: color,
                roughness: .float(Float(min(1, max(0, object.roughness)))),
                isMetallic: object.metallic
            )
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.name = object.id.uuidString
            entity.position = object.position.simd
            entity.scale = object.scale.simd
            entity.orientation = object.rotation.quaternion
            entity.generateCollisionShapes(recursive: false)
            return entity
        }

        private func addFloor(to root: Entity, scene: CanvasScene3D) {
            let floorMaterial = SimpleMaterial(
                color: UIColor(sceneBackground: scene.background).mixed(with: .white, amount: 0.08),
                roughness: 0.9,
                isMetallic: false
            )
            let floor = ModelEntity(
                mesh: .generateBox(size: SIMD3<Float>(12, 0.025, 12), cornerRadius: 0),
                materials: [floorMaterial]
            )
            floor.position.y = -0.025
            root.addChild(floor)

            guard scene.showsGrid else { return }
            let lineMaterial = UnlitMaterial(color: UIColor.white.withAlphaComponent(0.12))
            for index in -10...10 {
                let offset = Float(index) * 0.5
                let horizontal = ModelEntity(
                    mesh: .generateBox(size: SIMD3<Float>(10, 0.006, 0.008)),
                    materials: [lineMaterial]
                )
                horizontal.position = [0, 0.006, offset]
                root.addChild(horizontal)
                let vertical = ModelEntity(
                    mesh: .generateBox(size: SIMD3<Float>(0.008, 0.006, 10)),
                    materials: [lineMaterial]
                )
                vertical.position = [offset, 0.006, 0]
                root.addChild(vertical)
            }
        }

        private func addLights(to root: Entity, lighting: CanvasSceneLighting) {
            let key = DirectionalLight()
            key.light.intensity = Float(lighting.keyIntensity)
            key.light.color = .white
            key.shadow = lighting.castsShadows ? DirectionalLightComponent.Shadow() : nil
            key.look(at: .zero, from: [3.5, 5, 4], relativeTo: root)
            root.addChild(key)

            let fill = PointLight()
            fill.light.intensity = Float(lighting.fillIntensity)
            fill.light.attenuationRadius = 12
            fill.position = [-3, 2.5, 2]
            root.addChild(fill)
        }

        private func addCamera(to root: Entity, camera: CanvasSceneCamera) {
            let cameraEntity = PerspectiveCamera()
            cameraEntity.camera.fieldOfViewInDegrees = Float(camera.fieldOfView)
            let yaw = Float(camera.orbitYaw * .pi / 180)
            let pitch = Float(camera.orbitPitch * .pi / 180)
            let distance = Float(camera.distance)
            let target = camera.target.simd
            let position = SIMD3<Float>(
                target.x + distance * cos(pitch) * sin(yaw),
                target.y - distance * sin(pitch),
                target.z + distance * cos(pitch) * cos(yaw)
            )
            cameraEntity.look(at: target, from: position, relativeTo: root)
            root.addChild(cameraEntity)
        }
    }
}

private extension CanvasVector3 {
    var simd: SIMD3<Float> { SIMD3(Float(x), Float(y), Float(z)) }

    var quaternion: simd_quatf {
        let xRotation = simd_quatf(angle: Float(x * .pi / 180), axis: [1, 0, 0])
        let yRotation = simd_quatf(angle: Float(y * .pi / 180), axis: [0, 1, 0])
        let zRotation = simd_quatf(angle: Float(z * .pi / 180), axis: [0, 0, 1])
        return zRotation * yRotation * xRotation
    }
}

private extension UIColor {
    convenience init(floeHex: String) {
        let cleaned = floeHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(cleaned, radix: 16) ?? 0x5B8DEF
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }

    convenience init(sceneBackground: CanvasSceneBackground) {
        switch sceneBackground {
        case .studio: self.init(red: 0.12, green: 0.14, blue: 0.18, alpha: 1)
        case .graphite: self.init(white: 0.08, alpha: 1)
        case .midnight: self.init(red: 0.025, green: 0.055, blue: 0.12, alpha: 1)
        case .chromaGreen: self.init(red: 0.02, green: 0.42, blue: 0.17, alpha: 1)
        }
    }

    func mixed(with other: UIColor, amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0; var g1: CGFloat = 0; var b1: CGFloat = 0; var a1: CGFloat = 0
        var r2: CGFloat = 0; var g2: CGFloat = 0; var b2: CGFloat = 0; var a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let clamped = min(1, max(0, amount))
        return UIColor(
            red: r1 + (r2 - r1) * clamped,
            green: g1 + (g2 - g1) * clamped,
            blue: b1 + (b2 - b1) * clamped,
            alpha: a1 + (a2 - a1) * clamped
        )
    }
}
#endif
