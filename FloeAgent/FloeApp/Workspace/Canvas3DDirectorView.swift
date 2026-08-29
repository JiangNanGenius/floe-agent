// FloeApp — Native RealityKit canvas director.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit) && canImport(RealityKit)
import SwiftUI
import UIKit
import RealityKit
import simd
import FloeCore

struct Canvas3DDirectorPresentation: Identifiable, Hashable {
    let nodeID: UUID
    var id: UUID { nodeID }
}

struct Canvas3DDirectorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var scene: CanvasScene3D
    @State private var selectedObjectID: UUID?
    @State private var undoStack: [CanvasScene3D] = []
    @State private var redoStack: [CanvasScene3D] = []
    @State private var showsInspector = false
    @State private var lastOrbitTranslation: CGSize = .zero
    @State private var magnificationStartDistance: Double?

    let onSave: (CanvasScene3D) -> Void
    var onCancel: (() -> Void)?

    init(
        initialScene: CanvasScene3D,
        onSave: @escaping (CanvasScene3D) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        _scene = State(initialValue: initialScene)
        _selectedObjectID = State(initialValue: initialScene.objects.first?.id)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationSplitView {
            objectSidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 310)
        } detail: {
            HStack(spacing: 0) {
                stage
                if horizontalSizeClass == .regular {
                    Divider()
                    inspector
                        .frame(width: 330)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(scene.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { directorToolbar }
        .sheet(isPresented: $showsInspector) {
            NavigationStack {
                inspector
                    .navigationTitle("场景属性")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showsInspector = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var objectSidebar: some View {
        List(selection: $selectedObjectID) {
            Section {
                ForEach(scene.objects) { object in
                    Label(object.name, systemImage: icon(for: object.kind))
                        .tag(object.id)
                        .contextMenu {
                            Button("复制", systemImage: "doc.on.doc") { duplicate(object.id) }
                            Button("删除", systemImage: "trash", role: .destructive) {
                                delete(object.id)
                            }
                        }
                }
            } header: {
                Text("场景对象")
            } footer: {
                Text("选择对象后在属性栏调整位置、旋转、尺寸与材质。")
            }

            Section("舞台") {
                Picker("背景", selection: Binding(
                    get: { scene.background },
                    set: { value in mutateScene { $0.background = value } }
                )) {
                    ForEach(CanvasSceneBackground.allCases, id: \.self) { background in
                        Text(title(for: background)).tag(background)
                    }
                }
                Toggle("显示地面网格", isOn: Binding(
                    get: { scene.showsGrid },
                    set: { value in mutateScene { $0.showsGrid = value } }
                ))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(CanvasSceneObjectKind.allCases, id: \.self) { kind in
                        Button {
                            add(kind)
                        } label: {
                            Label(title(for: kind), systemImage: icon(for: kind))
                        }
                    }
                } label: {
                    Label("添加对象", systemImage: "plus")
                }
            }
        }
    }

    private var stage: some View {
        ZStack(alignment: .bottom) {
            Canvas3DScenePreview(
                scene: scene,
                selectedObjectID: selectedObjectID,
                onSelect: { selectedObjectID = $0 }
            )
            .ignoresSafeArea(edges: .bottom)

            HStack(spacing: 8) {
                Label("拖动旋转视角", systemImage: "rotate.3d")
                Divider().frame(height: 14)
                Label("双指缩放", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 18)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let deltaWidth = value.translation.width - lastOrbitTranslation.width
                    let deltaHeight = value.translation.height - lastOrbitTranslation.height
                    lastOrbitTranslation = value.translation
                    scene.camera.orbitYaw += Double(deltaWidth) * 0.18
                    scene.camera.orbitPitch = min(
                        75,
                        max(-75, scene.camera.orbitPitch - Double(deltaHeight) * 0.18)
                    )
                }
                .onEnded { _ in
                    lastOrbitTranslation = .zero
                    scene.updatedAt = Date()
                }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    if magnificationStartDistance == nil {
                        magnificationStartDistance = scene.camera.distance
                    }
                    let startingDistance = magnificationStartDistance ?? scene.camera.distance
                    scene.camera.distance = min(
                        20,
                        max(2.2, startingDistance / Double(value.magnification))
                    )
                }
                .onEnded { _ in
                    magnificationStartDistance = nil
                    scene.updatedAt = Date()
                }
        )
    }

    @ViewBuilder
    private var inspector: some View {
        if let index = selectedObjectIndex {
            Form {
                Section("对象") {
                    TextField("名称", text: objectBinding(index, \.name))
                    Toggle("隐藏", isOn: objectBinding(index, \.isHidden))
                }
                vectorSection("位置", index: index, keyPath: \.position, range: -10...10, step: 0.05)
                vectorSection("旋转", index: index, keyPath: \.rotation, range: -180...180, step: 1)
                vectorSection("缩放", index: index, keyPath: \.scale, range: 0.05...8, step: 0.05)

                Section("材质") {
                    HStack {
                        ForEach(Self.palette, id: \.self) { hex in
                            Button {
                                scene.objects[index].colorHex = hex
                                scene.updatedAt = Date()
                            } label: {
                                Circle()
                                    .fill(Color(uiColor: UIColor(floeHex: hex)))
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if scene.objects[index].colorHex == hex {
                                            Image(systemName: "checkmark")
                                                .font(.caption.bold())
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("材质颜色 \(hex)")
                        }
                    }
                    LabeledContent("粗糙度", value: scene.objects[index].roughness.formatted(.number.precision(.fractionLength(2))))
                    Slider(value: objectBinding(index, \.roughness), in: 0...1)
                    Toggle("金属材质", isOn: objectBinding(index, \.metallic))
                }

                Section {
                    Button("复制对象", systemImage: "doc.on.doc") {
                        duplicate(scene.objects[index].id)
                    }
                    Button("删除对象", systemImage: "trash", role: .destructive) {
                        delete(scene.objects[index].id)
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "选择一个对象",
                systemImage: "cube.transparent",
                description: Text("从左侧选择对象，或添加新的几何体。")
            )
        }
    }

    @ToolbarContentBuilder
    private var directorToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button("取消") {
                onCancel?()
                dismiss()
            }
            Button("撤销", systemImage: "arrow.uturn.backward") { undo() }
                .disabled(undoStack.isEmpty)
                .keyboardShortcut("z", modifiers: .command)
            Button("重做", systemImage: "arrow.uturn.forward") { redo() }
                .disabled(redoStack.isEmpty)
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("重置视角", systemImage: "viewfinder") {
                checkpoint()
                scene.camera = .init()
                scene.updatedAt = Date()
            }
            if horizontalSizeClass != .regular {
                Button("属性", systemImage: "slider.horizontal.3") { showsInspector = true }
            }
            Button("保存") {
                scene.updatedAt = Date()
                onSave(scene)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
        }
    }

    private var selectedObjectIndex: Int? {
        guard let selectedObjectID else { return nil }
        return scene.objects.firstIndex { $0.id == selectedObjectID }
    }

    private func add(_ kind: CanvasSceneObjectKind) {
        checkpoint()
        let object = CanvasSceneObject(
            name: "\(title(for: kind)) \(scene.objects.count + 1)",
            kind: kind,
            position: CanvasVector3(x: 0, y: kind == .plane ? 0.02 : 0.6, z: 0)
        )
        scene.objects.append(object)
        scene.updatedAt = Date()
        selectedObjectID = object.id
    }

    private func duplicate(_ id: UUID) {
        guard let original = scene.objects.first(where: { $0.id == id }) else { return }
        checkpoint()
        var copy = original
        copy.id = UUID()
        copy.name += " 副本"
        copy.position.x += 0.45
        copy.position.z += 0.35
        scene.objects.append(copy)
        scene.updatedAt = Date()
        selectedObjectID = copy.id
    }

    private func delete(_ id: UUID) {
        checkpoint()
        scene.objects.removeAll { $0.id == id }
        scene.updatedAt = Date()
        selectedObjectID = scene.objects.first?.id
    }

    private func checkpoint() {
        undoStack.append(scene)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func mutateScene(_ mutation: (inout CanvasScene3D) -> Void) {
        checkpoint()
        mutation(&scene)
        scene.updatedAt = Date()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(scene)
        scene = previous
        if !scene.objects.contains(where: { $0.id == selectedObjectID }) {
            selectedObjectID = scene.objects.first?.id
        }
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(scene)
        scene = next
        if !scene.objects.contains(where: { $0.id == selectedObjectID }) {
            selectedObjectID = scene.objects.first?.id
        }
    }

    private func objectBinding<Value>(
        _ index: Int,
        _ keyPath: WritableKeyPath<CanvasSceneObject, Value>
    ) -> Binding<Value> {
        Binding(
            get: { scene.objects[index][keyPath: keyPath] },
            set: { value in
                scene.objects[index][keyPath: keyPath] = value
                scene.updatedAt = Date()
            }
        )
    }

    private func vectorSection(
        _ title: String,
        index: Int,
        keyPath: WritableKeyPath<CanvasSceneObject, CanvasVector3>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        Section(title) {
            axisControl("X", index: index, keyPath: keyPath, axis: \.x, range: range, step: step)
            axisControl("Y", index: index, keyPath: keyPath, axis: \.y, range: range, step: step)
            axisControl("Z", index: index, keyPath: keyPath, axis: \.z, range: range, step: step)
        }
    }

    private func axisControl(
        _ label: String,
        index: Int,
        keyPath: WritableKeyPath<CanvasSceneObject, CanvasVector3>,
        axis: WritableKeyPath<CanvasVector3, Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        let binding = Binding<Double>(
            get: { scene.objects[index][keyPath: keyPath][keyPath: axis] },
            set: { value in
                scene.objects[index][keyPath: keyPath][keyPath: axis] = value
                scene.updatedAt = Date()
            }
        )
        return HStack {
            Text(label).font(.caption.monospaced()).frame(width: 18)
            Slider(value: binding, in: range, step: step)
            TextField(label, value: binding, format: .number.precision(.fractionLength(2)))
                .multilineTextAlignment(.trailing)
                .frame(width: 66)
        }
    }

    private func title(for kind: CanvasSceneObjectKind) -> String {
        switch kind {
        case .box: "立方体"
        case .sphere: "球体"
        case .cylinder: "圆柱体"
        case .cone: "圆锥体"
        case .plane: "平面"
        }
    }

    private func icon(for kind: CanvasSceneObjectKind) -> String {
        switch kind {
        case .box: "cube"
        case .sphere: "circle"
        case .cylinder: "cylinder"
        case .cone: "triangle"
        case .plane: "square"
        }
    }

    private func title(for background: CanvasSceneBackground) -> String {
        switch background {
        case .studio: "摄影棚"
        case .graphite: "石墨灰"
        case .midnight: "午夜蓝"
        case .chromaGreen: "绿幕"
        }
    }

    private static let palette = [
        "#5B8DEF", "#7C5CFC", "#EB5757", "#F2994A", "#27AE60", "#56CCF2", "#F2F2F2", "#22252B"
    ]
}

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
