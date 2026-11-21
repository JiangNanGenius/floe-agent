// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import SceneKit
import FloePrintCore

/// Sliced-result preview: real per-layer extrusion paths for FDM G-code
/// (including Bambu G2/G3 arcs) and exposure rasters for CTB. A `.3mf` URL
/// (or bytes) opens the embedded plate G-code and offers a plate picker when
/// the slicer wrote more than one plate; a model-only 3MF has no plate
/// streams, so its fallback to the geometry viewer is the caller's job.
struct PrintResultPreview: View {
    let url: URL
    var machine: PrintMachineConfiguration? = nil
    /// Immutable workspace snapshot. When supplied for `.3mf`/`.gcode`,
    /// the disk is never read; the URL is only identity/display name.
    var sourceData: Data? = nil
    @State private var gcode: PrintGCodePreview?
    @State private var resin: PrintCTBPreview?
    @State private var raster: CGImage?
    @State private var plates: [PrintThreeMF.PlateEntry] = []
    @State private var selectedPlate = 1
    @State private var layer = 1.0
    @State private var showLower = true
    @State private var playing = false
    @State private var failed = false
    @State private var showingFullScreen = false
    @State private var camera = PrintPreviewCamera()
    private var count: Int { gcode?.layers.count ?? resin?.header.layerCount ?? 1 }
    private var index: Int { min(max(0, Int(layer) - 1), max(0, count - 1)) }

    var body: some View {
        Group {
            if showingFullScreen {
                Color(uiColor: .systemBackground).accessibilityHidden(true)
            } else {
                preview(expanded: false)
            }
        }
        .fullScreenCover(isPresented: $showingFullScreen) {
            preview(expanded: true)
                .background(Color(uiColor: .systemBackground))
        }
        .id(url.absoluteString)
        .task(id: "load-\(url.absoluteString)-\(selectedPlate)") {
            gcode = nil; resin = nil; raster = nil; failed = false; playing = false
            let ext = url.pathExtension.lowercased()
            // Immutable workspace snapshot: the disk is never read when set.
            let snapshot = (sourceData != nil && (ext == "3mf" || ext == "gcode")) ? sourceData : nil
            let requestedPlate = selectedPlate
            do {
                let work = Task.detached(priority: .userInitiated) { () -> LoadResult in
                    let data: Data
                    if let snapshot {
                        data = snapshot
                    } else {
                        data = try Data(contentsOf: url, options: .mappedIfSafe)
                    }
                    if ext == "gcode" {
                        return .gcode(try PrintGCodePreview.read(data), plates: [])
                    }
                    if ext == "3mf" {
                        let entries = try PrintThreeMF.plateEntries(in: data)
                        guard !entries.isEmpty else { return .noPlates }
                        let chosen = entries.contains(where: { $0.plateID == requestedPlate }) ? requestedPlate : entries[0].plateID
                        guard chosen == requestedPlate else { return .redirect(chosen) }
                        let plate = try PrintThreeMF.plate(chosen, in: data)
                        return .gcode(try PrintGCodePreview.read(plate.data), plates: entries)
                    }
                    return .resin(try PrintCTBPreview(data: data))
                }
                let result = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: { work.cancel() }
                // A late or stale parse (plate switched, file changed, view
                // gone) must never replace the current presentation.
                guard !Task.isCancelled, selectedPlate == requestedPlate else { return }
                switch result {
                case .gcode(let preview, let entries):
                    plates = entries
                    gcode = preview
                case .resin(let preview):
                    resin = preview
                case .redirect(let plateID):
                    selectedPlate = plateID
                    return
                case .noPlates:
                    failed = true
                    return
                }
                layer = 1
            } catch is CancellationError {
            } catch { failed = true }
        }
        .task(id: "resin-\(url.absoluteString):\(index):\(resin != nil)") {
            guard let resin else { return }
            do {
                let selectedIndex = index
                let decoded = try await Task.detached { try resin.layer(selectedIndex) }.value
                guard !Task.isCancelled, let provider = CGDataProvider(data: decoded.pixels as CFData) else { return }
                raster = CGImage(width: decoded.width, height: decoded.height, bitsPerComponent: 8, bitsPerPixel: 8,
                    bytesPerRow: decoded.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            } catch { failed = true }
        }
        .task(id: playing) {
            guard playing else { return }
            while !Task.isCancelled, playing {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                if layer >= Double(count) { playing = false; return }; layer += 1
            }
        }
    }

    private func preview(expanded: Bool) -> some View {
        let pathLayers = gcode.map { preview in
            showLower ? Array(preview.layers.prefix(index + 1)) : Array(preview.layers.dropFirst(index).prefix(1))
        } ?? []
        return VStack(spacing: 0) {
            Group {
                if let gcode, !pathLayers.isEmpty {
                    PrintLayerScene(layers: pathLayers,
                        summary: gcode.summary, identity: sceneIdentity, machine: machine, camera: camera, expanded: expanded)
                        .accessibilityIdentifier("printing.slicedPreview")
                } else if let raster {
                    ZStack { Color.black; Image(decorative: raster, scale: 1).resizable().interpolation(.none).scaledToFit().padding(20) }
                } else if failed {
                    ContentUnavailableView(IDELanguageRunText.t("未能读取切片预览", "Unable to read sliced preview"), systemImage: "square.stack.3d.up")
                } else { ProgressView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if expanded || gcode != nil || raster != nil {
                    Button {
                        camera.capture(identity: sceneIdentity, expanded: expanded)
                        showingFullScreen = !expanded
                    } label: {
                        Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? IDELanguageRunText.t("退出全屏", "Exit full screen") : IDELanguageRunText.t("全屏预览", "Full-screen preview"))
                    .accessibilityIdentifier(expanded ? "printing.preview.collapse" : "printing.preview.expand")
                    .padding(12)
                }
            }
            Divider()
            VStack(spacing: 8) {
                HStack {
                    Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel(playing ? IDELanguageRunText.t("暂停逐层播放", "Pause layer playback") : IDELanguageRunText.t("播放逐层预览", "Play layers"))
                    Button { if layer < Double(count) { layer += 1 } } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                        .accessibilityLabel(IDELanguageRunText.t("下一层", "Next layer"))
                        .accessibilityIdentifier("printing.layer.next")
                        .disabled(layer >= Double(count))
                    Text(IDELanguageRunText.t("层", "Layer") + " \(index + 1) / \(count)").monospacedDigit()
                        .accessibilityIdentifier("printing.layer.current")
                    if plates.count > 1 {
                        Menu {
                            ForEach(plates, id: \.plateID) { entry in
                                Button(entry.plateID == selectedPlate
                                    ? "✓ \(IDELanguageRunText.t("盘", "Plate")) \(entry.plateID)"
                                    : "\(IDELanguageRunText.t("盘", "Plate")) \(entry.plateID)") { selectedPlate = entry.plateID }
                            }
                        } label: {
                            Label(IDELanguageRunText.t("盘", "Plate") + " \(selectedPlate)/\(plates.count)", systemImage: "rectangle.3.group")
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("printing.platePicker")
                    }
                    Spacer()
                    if let layer = pathLayers.last { Text(String(format: "Z %.2f mm", layer.z)).monospacedDigit() }
                }
                Slider(value: $layer, in: 1...Double(max(2, count)), step: 1)
                    .accessibilityLabel(IDELanguageRunText.t("当前切片层", "Current sliced layer"))
                    .accessibilityIdentifier("printing.layerSlider")
                if let gcode {
                    Toggle(IDELanguageRunText.t("显示下层", "Show lower layers"), isOn: $showLower)
                        .font(.subheadline)
                    ScrollView(.horizontal) {
                        HStack {
                            Label(IDELanguageRunText.t("外壁", "Walls"), systemImage: "circle.fill").foregroundStyle(.blue)
                            Label(IDELanguageRunText.t("填充", "Infill"), systemImage: "circle.fill").foregroundStyle(.teal)
                            Label(IDELanguageRunText.t("支撑", "Support"), systemImage: "circle.fill").foregroundStyle(.purple)
                            Text(IDELanguageRunText.t("耗材", "Filament") + String(format: " %.2f m", gcode.summary.filamentMM / 1_000))
                        }.font(.caption)
                    }.scrollIndicators(.hidden)
                    let visibleCount = pathLayers.reduce(0) { $0 + $1.segments.count }
                    if gcode.truncated || visibleCount > 50_000 {
                        Text(IDELanguageRunText.t("当前视图省略了部分路径；导出文件保留完整结果。", "Some paths are omitted from this view; the export retains the complete result.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(.horizontal).padding(.bottom, 8).background(.bar)
        }
    }

    /// Cache identity for the scene: full source URL and plate. Sliding the
    /// layer control never resets the cached layer nodes.
    private var sceneIdentity: String { "\(url.absoluteString)#\(selectedPlate)" }
}

/// One load attempt's outcome, produced off the main actor. `.redirect`
/// resolves an out-of-range plate selection through the state machine.
private enum LoadResult {
    case gcode(PrintGCodePreview, plates: [PrintThreeMF.PlateEntry])
    case resin(PrintCTBPreview)
    case redirect(Int)
    case noPlates
}

/// Holds only the active viewport and the camera at a presentation change.
private final class PrintPreviewCamera {
    private weak var viewport: SCNView?
    private var activeIdentity: String?
    private var activeExpanded = false
    private var saved: (identity: String, transform: SCNMatrix4, target: SCNVector3)?

    func attach(_ view: SCNView, identity: String, expanded: Bool) {
        viewport = view
        activeIdentity = identity
        activeExpanded = expanded
        if let saved, saved.identity == identity {
            view.pointOfView?.transform = saved.transform
            view.defaultCameraController.target = saved.target
        }
        saved = nil
    }

    func capture(identity: String, expanded: Bool) {
        guard activeIdentity == identity, activeExpanded == expanded,
              let viewport, let pointOfView = viewport.pointOfView else { return }
        saved = (identity, pointOfView.transform, viewport.defaultCameraController.target)
    }
}

private struct PrintLayerScene: UIViewRepresentable {
    let layers: [PrintPathLayer]
    let summary: GCodeSummary
    let identity: String
    let machine: PrintMachineConfiguration?
    let camera: PrintPreviewCamera
    let expanded: Bool
    static let maximumRenderedSegments = 50_000

    final class Coordinator {
        var identity: String?
        var nodes: [Int: SCNNode] = [:]
        var segmentCounts: [Int: Int] = [:]
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(); view.allowsCameraControl = true; view.antialiasingMode = .multisampling4X
        view.backgroundColor = .secondarySystemGroupedBackground; return view
    }
    func updateUIView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.identity != identity {
            coordinator.identity = identity; coordinator.nodes = [:]; coordinator.segmentCounts = [:]
            let scene = SCNScene()
            // Only a project with a known printer has an authoritative bed.
            if let machine {
                let plate = SCNNode(geometry: SCNBox(width: machine.bedWidth, height: 0.2, length: machine.bedDepth, chamferRadius: 0))
                plate.position.y = -0.2
                plate.geometry?.firstMaterial?.diffuse.contents = UIColor.tertiarySystemFill
                scene.rootNode.addChildNode(plate)
            }
            let offset = machine?.coordinateOffset ?? [0, 0, 0]
            let mid = zip(summary.minimum, summary.maximum).map { ($0 + $1) * 0.5 }
            let target = SCNVector3(mid[0] - offset[0], mid[2] - offset[2], offset[1] - mid[1])
            let extent = zip(summary.minimum, summary.maximum).map { $1 - $0 }
            let span = max(6, sqrt(extent.reduce(0.0) { $0 + $1 * $1 }))
            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.zNear = 0.1
            camera.camera?.zFar = max(5_000, span * 8)
            camera.position = SCNVector3(Double(target.x) + span * 0.68, Double(target.y) + span * 0.72, Double(target.z) + span * 0.82)
            camera.look(at: target)
            scene.rootNode.addChildNode(camera)
            view.scene = scene
            view.pointOfView = camera
            view.defaultCameraController.target = target
            self.camera.attach(view, identity: identity, expanded: expanded)
        }
        guard let scene = view.scene else { return }
        let visibleIds = layers.map(\.id)

        // Deterministic budget: scan newest → oldest, granting each visible
        // layer min(remaining, its segment count). The selected layer is
        // always satisfied first; oldest layers lose segments last.
        var wanted: [Int: Int] = [:]
        var remaining = Self.maximumRenderedSegments
        for layer in layers.reversed() {
            guard remaining > 0 else { break }
            let take = min(remaining, layer.segments.count)
            guard take > 0 else { continue }
            wanted[layer.id] = take
            remaining -= take
        }
        // Evict anything without an allocation, or whose allocation changed.
        for (id, node) in coordinator.nodes where wanted[id] != coordinator.segmentCounts[id] {
            evict(coordinator, id: id, node: node)
        }
        // Build missing nodes with their exact allocation.
        for layer in layers.reversed() {
            guard let allocation = wanted[layer.id], coordinator.nodes[layer.id] == nil else { continue }
            guard let node = makeLayerNode(layer, limit: allocation, coordinator: coordinator) else { continue }
            coordinator.nodes[layer.id] = node
            scene.rootNode.addChildNode(node)
        }
        // Depth cue: only the top layer is fully opaque.
        if let top = visibleIds.last {
            for (id, node) in coordinator.nodes {
                node.childNodes.forEach { $0.opacity = id == top ? 1 : 0.18 }
            }
        }
    }

    private func evict(_ coordinator: Coordinator, id: Int, node: SCNNode) {
        node.removeFromParentNode()
        coordinator.segmentCounts.removeValue(forKey: id)
        coordinator.nodes.removeValue(forKey: id)
    }

    /// Builds one layer's node consuming at most `limit` segments.
    private func makeLayerNode(_ layer: PrintPathLayer, limit: Int, coordinator: Coordinator) -> SCNNode? {
        guard limit > 0 else { return nil }
        let offset = machine?.coordinateOffset ?? [0, 0, 0]
        var groups: [String: [SCNVector3]] = [:]
        var consumed = 0
        for segment in layer.segments {
            guard consumed < limit else { break }
            groups[segment.kind.rawValue, default: []] += [segment.start, segment.end].map {
                SCNVector3(Double($0[0]) - offset[0], Double($0[2]) - offset[2], -(Double($0[1]) - offset[1]))
            }
            consumed += 1
        }
        guard !groups.isEmpty else { return nil }
        let node = SCNNode()
        for (key, vertices) in groups {
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                elements: [SCNGeometryElement(indices: vertices.indices.map(UInt32.init), primitiveType: .line)])
            geometry.firstMaterial?.diffuse.contents = color(for: key)
            geometry.firstMaterial?.lightingModel = .constant
            node.addChildNode(SCNNode(geometry: geometry))
        }
        coordinator.segmentCounts[layer.id] = consumed
        return node
    }

    private func color(for kind: String) -> UIColor {
        kind.hasPrefix("support") ? .systemPurple : kind.hasPrefix("infill") ? .systemTeal : kind.hasPrefix("travel") ? .secondaryLabel : .systemBlue
    }
}
#endif
