// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import SceneKit
import FloePrintCore

struct PrintResultPreview: View {
    let url: URL
    let preset: PrintPreset
    var machine: PrintMachineConfiguration? = nil
    @State private var gcode: PrintGCodePreview?
    @State private var resin: PrintCTBPreview?
    @State private var raster: CGImage?
    @State private var layer = 1.0
    @State private var showLower = true
    @State private var playing = false
    @State private var failed = false
    private var count: Int { gcode?.layers.count ?? resin?.header.layerCount ?? 1 }
    private var index: Int { min(max(0, Int(layer) - 1), max(0, count - 1)) }
    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let gcode, !gcode.layers.isEmpty {
                    PrintLayerScene(layers: showLower ? Array(gcode.layers.prefix(index + 1)) : [gcode.layers[index]], preset: preset,
                        identity: url.lastPathComponent + ":\(index):\(showLower)", machine: machine ?? .generic(for: preset))
                } else if let raster {
                    ZStack { Color.black; Image(decorative: raster, scale: 1).resizable().interpolation(.none).scaledToFit().padding(20) }
                } else if failed {
                    ContentUnavailableView(IDELanguageRunText.t("未能读取切片预览", "Unable to read sliced preview"), systemImage: "square.stack.3d.up")
                } else { ProgressView() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(spacing: 8) {
                HStack {
                    Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel(playing ? IDELanguageRunText.t("暂停逐层播放", "Pause layer playback") : IDELanguageRunText.t("播放逐层预览", "Play layers"))
                    Text(IDELanguageRunText.t("层", "Layer") + " \(index + 1) / \(count)").monospacedDigit()
                    Spacer()
                    if let gcode { Text(String(format: "Z %.2f mm", gcode.layers[index].z)).monospacedDigit() }
                    if gcode != nil { Toggle(IDELanguageRunText.t("显示下层", "Show lower layers"), isOn: $showLower).fixedSize() }
                }
                Slider(value: $layer, in: 1...Double(max(2, count)), step: 1)
                    .accessibilityLabel(IDELanguageRunText.t("当前切片层", "Current sliced layer"))
                    .accessibilityIdentifier("printing.layerSlider")
                if let gcode {
                    HStack {
                        Label(IDELanguageRunText.t("外壁", "Walls"), systemImage: "circle.fill").foregroundStyle(.blue)
                        Label(IDELanguageRunText.t("填充", "Infill"), systemImage: "circle.fill").foregroundStyle(.teal)
                        Label(IDELanguageRunText.t("支撑", "Support"), systemImage: "circle.fill").foregroundStyle(.purple)
                        Spacer()
                        Text(IDELanguageRunText.t("耗材", "Filament") + String(format: " %.2f m", gcode.summary.filamentMM / 1_000))
                    }.font(.caption)
                    let visibleCount = (showLower ? Array(gcode.layers.prefix(index + 1)) : [gcode.layers[index]]).reduce(0) { $0 + $1.segments.count }
                    if gcode.truncated || visibleCount > 50_000 {
                        Text(IDELanguageRunText.t("当前视图省略了部分路径；导出文件保留完整结果。", "Some paths are omitted from this view; the export retains the complete result.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(.horizontal).padding(.bottom, 8).background(.bar)
        }
        .task(id: url) {
            gcode = nil; resin = nil; raster = nil; failed = false; playing = false
            do {
                let data = try await Task.detached { try Data(contentsOf: url, options: .mappedIfSafe) }.value
                if url.pathExtension == "gcode" { gcode = try await Task.detached { try PrintGCodePreview.read(data) }.value }
                else { resin = try PrintCTBPreview(data: data) }
                layer = 1
            } catch { failed = true }
        }
        .task(id: "\(url.lastPathComponent):\(index):\(resin != nil)") {
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
}

private struct PrintLayerScene: UIViewRepresentable {
    let layers: [PrintPathLayer]
    let preset: PrintPreset
    let identity: String
    let machine: PrintMachineConfiguration
    final class Coordinator { var identity: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(); view.allowsCameraControl = true; view.antialiasingMode = .multisampling4X
        view.backgroundColor = .secondarySystemGroupedBackground; return view
    }
    func updateUIView(_ view: SCNView, context: Context) {
        guard context.coordinator.identity != identity else { return }; context.coordinator.identity = identity
        let scene = SCNScene(), bed = (width: machine.bedWidth, depth: machine.bedDepth), offset = machine.coordinateOffset
        let plate = SCNNode(geometry: SCNBox(width: bed.width, height: 0.2, length: bed.depth, chamferRadius: 0))
        plate.position.y = -0.2; plate.geometry?.firstMaterial?.diffuse.contents = UIColor.tertiarySystemFill
        scene.rootNode.addChildNode(plate)
        var groups: [String: [SCNVector3]] = [:], rendered = 0
        for layer in layers.reversed() {
            for segment in layer.segments where rendered < 50_000 {
                let key = segment.kind.rawValue + (layer.id == layers.last?.id ? ":current" : ":lower")
                groups[key, default: []] += [segment.start, segment.end].map {
                    SCNVector3(Double($0[0]) - offset[0], Double($0[2]) - offset[2], -(Double($0[1]) - offset[1]))
                }; rendered += 1
            }
        }
        for (key, vertices) in groups {
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                elements: [SCNGeometryElement(indices: vertices.indices.map(UInt32.init), primitiveType: .line)])
            let color: UIColor = key.hasPrefix("support") ? .systemPurple : key.hasPrefix("infill") ? .systemTeal : key.hasPrefix("travel") ? .secondaryLabel : .systemBlue
            geometry.firstMaterial?.diffuse.contents = color.withAlphaComponent(key.hasSuffix("lower") ? 0.18 : 1)
            geometry.firstMaterial?.lightingModel = .constant
            scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        }
        let camera = view.pointOfView ?? SCNNode()
        if camera.camera == nil {
            camera.camera = SCNCamera(); camera.camera?.zNear = 0.1; camera.camera?.zFar = 5_000
            let span = max(bed.width, bed.depth); camera.position = SCNVector3(span * 0.75, span * 0.8, span * 0.9)
            camera.look(at: SCNVector3Zero)
        }
        camera.removeFromParentNode(); scene.rootNode.addChildNode(camera)
        view.scene = scene; view.pointOfView = camera; view.defaultCameraController.target = SCNVector3Zero
    }
}
#endif
