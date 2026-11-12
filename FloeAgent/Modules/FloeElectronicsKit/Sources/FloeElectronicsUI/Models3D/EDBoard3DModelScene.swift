// SPDX-License-Identifier: MPL-2.0
import Foundation
import Observation
import SceneKit
import simd
import FloeElectronicsCore
#if canImport(UIKit)
import UIKit
private typealias EDB3BezierPath = UIBezierPath
#elseif canImport(AppKit)
import AppKit
private typealias EDB3BezierPath = NSBezierPath
#endif

/// Immutable validated CPU mesh values in source millimetres. This is the only
/// geometry that crosses the injected loader boundary; no CAD document or
/// kernel handle is retained by the UI.
public struct EDBoard3DModelPart: Sendable {
    public let name: String
    public let positions: [SIMD3<Float>]
    public let normals: [SIMD3<Float>]
    public let indices: [UInt32]
    public init(name: String, positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]) {
        self.name = name; self.positions = positions; self.normals = normals; self.indices = indices
    }
    public var cpuBytes: Int {
        positions.count * MemoryLayout<SIMD3<Float>>.stride * 2 + indices.count * MemoryLayout<UInt32>.stride
    }
    public var sceneKitBytes: Int {
        positions.count * MemoryLayout<SCNVector3>.stride * 2 + indices.count * MemoryLayout<UInt32>.stride
    }
    public var retainedBytes: Int { cpuBytes + sceneKitBytes }
}

public struct EDBoard3DModelGeometry: Sendable {
    public let parts: [EDBoard3DModelPart]
    public let triangleCount: Int
    public let bufferBytes: Int
    public init(parts: [EDBoard3DModelPart], triangleCount: Int, bufferBytes: Int) {
        self.parts = parts; self.triangleCount = triangleCount; self.bufferBytes = bufferBytes
    }
    /// CPU arrays plus the SceneKit geometry source/index data derived from
    /// them. Callers admit both before retaining a model in a scene.
    public var cpuBytes: Int { parts.reduce(0) { $0 + $1.cpuBytes } }
    public var sceneKitBytes: Int { parts.reduce(0) { $0 + $1.sceneKitBytes } }
    public var retainedBytes: Int { cpuBytes + sceneKitBytes }
    public static let empty = EDBoard3DModelGeometry(parts: [], triangleCount: 0, bufferBytes: 0)
}

public enum EDBoard3DModelLoadError: Error, Equatable, LocalizedError, Sendable {
    case notDownloaded
    case unsupportedFormat(String)
    case integrity
    case invalidGeometry
    case cancelled
    public var errorDescription: String? {
        switch self {
        case .notDownloaded: "The verified 3D model bytes are not cached. Download the model from the online library first."
        case .unsupportedFormat(let format): "The \(format.uppercased()) 3D model format is retained but is not rendered by this view."
        case .integrity: "The cached 3D model failed its source/digest verification."
        case .invalidGeometry: "The 3D model produced no supported triangle geometry."
        case .cancelled: "3D model loading was cancelled."
        }
    }
}

public protocol EDBoard3DModelLoading: Sendable {
    func loadModel(_ reference: EDAFootprintModelReference,
                   cancellation: EDBoard3DModelCancellation) async throws -> EDBoard3DModelGeometry
}

public final class EDBoard3DModelCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Scene-owned, bounded model cache and renderer. It deliberately does not use
/// a global model cache: leaving the 3D tab, switching boards, or changing the
/// project revision cancels and releases owned geometry.
@MainActor @Observable public final class EDBoard3DRenderer {
    public enum State: Equatable, Sendable {
        case idle
        case loading
        case ready
        case unavailable(String)
        public var text: String {
            switch self {
            case .idle: ""
            case .loading: edText("正在校验并加载元件三维模型…", "Verifying and loading component 3D models…")
            case .ready: ""
            case .unavailable(let detail): detail
            }
        }
    }

    public static let maximumUniqueModels = 48
    public static let maximumPlacements = 256
    public static let maximumTriangles = 1_000_000
    /// CPU mesh arrays plus SceneKit source/index copies, measured from actual
    /// retained counts. Per-model bridge limits alone cannot bound a PCB.
    public static let maximumAggregateBytes = 48 * 1_024 * 1_024
    public static let maximumConcurrentLoads = 2

    public let scene = SCNScene()
    public private(set) var state = State.idle
    public private(set) var status: String = edText("三维显示实际板形、开孔与厚度。", "3D shows the actual board outline, holes and thickness.")
    public private(set) var renderedModelCount = 0
    public private(set) var totalPlacementCount = 0
    public private(set) var skippedModelCount = 0
    public private(set) var retainedBytes = 0
    public private(set) var sceneGeometryBytes = 0
    public private(set) var uniqueSceneGeometryCount = 0
    public private(set) var failureDetail: String?

    private let boardRoot = SCNNode()
    private let modelRoot = SCNNode()
    private let camera = SCNNode()
    private let keyLight = SCNNode()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var activeTokens: [EDBoard3DModelCancellation] = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var activeOwnerID: UUID?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var geometryCache: [String: EDBoard3DModelGeometry] = [:]
    @ObservationIgnored private var sceneGeometryCache: [String: [(name: String, geometry: SCNGeometry)]] = [:]
    @ObservationIgnored private var loadedKeys = Set<String>()
    @ObservationIgnored private var skippedKeys = Set<String>()
    @ObservationIgnored private var currentBoardThickness: Double = 1.6

    public init() {
        scene.rootNode.addChildNode(boardRoot)
        scene.rootNode.addChildNode(modelRoot)
        scene.rootNode.addChildNode(camera)
        camera.name = "electronics.3d.camera"
        camera.camera = SCNCamera()
        camera.camera?.zFar = 100_000
        let light = SCNLight(); light.type = .directional; light.intensity = 1_000
        keyLight.light = light
        keyLight.eulerAngles = SCNVector3(-0.8, 0.5, 0)
        scene.rootNode.addChildNode(keyLight)
        let ambient = SCNLight(); ambient.type = .ambient; ambient.intensity = 350
        let ambientNode = SCNNode(); ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)
    }

    /// Cancels and joins any previous board worker before publishing a new
    /// generation. The stable SCNScene object is never replaced.
    public func load(project: EDAProject, boardID: UUID?, loader: (any EDBoard3DModelLoading)?,
                     ownerID: UUID? = nil) async {
        guard !closed, !Task.isCancelled else { return }
        // Capture this request before the join await. A second load or stop
        // invalidates it, and only this request may publish a new generation.
        let request = UUID()
        activeOwnerID = ownerID
        generation = request
        let previous = work
        previous?.cancel()
        for token in activeTokens { token.cancel() }
        activeTokens = []
        await previous?.value
        guard generation == request, !closed, !Task.isCancelled else { return }
        geometryCache = [:]; sceneGeometryCache = [:]; loadedKeys = []; skippedKeys = []
        modelRoot.childNodes.forEach { $0.removeFromParentNode() }
        renderedModelCount = 0; skippedModelCount = 0; retainedBytes = 0
        sceneGeometryBytes = 0; uniqueSceneGeometryCount = 0
        totalPlacementCount = 0; failureDetail = nil
        guard let board = project.boards.first(where: { $0.id == boardID }) ?? project.boards.first,
              !board.outline.isEmpty else {
            state = .unavailable(edText("此工程没有可显示的三维板形。", "This design has no 3D board outline."))
            return
        }
        let thickness = board.layers.reduce(0) { $0 + $1.thickness }
        currentBoardThickness = max(0.01, thickness)
        buildBoard(project: project, board: board, thickness: currentBoardThickness)
        guard let loader else {
            state = .unavailable(edText("三维元件显示不可用；板形仍按实际尺寸显示。", "Component 3D display is unavailable; the actual board shape is still shown."))
            return
        }
        let placements = Self.modelPlacements(project: project, board: board)
        totalPlacementCount = placements.count
        guard !placements.isEmpty else {
            state = .ready
            status = edText("此板没有带三维模型引用的元件。可在在线元件库中安装并下载模型。",
                            "No placed footprint has a 3D model reference. Install and download a model from the online library.")
            return
        }
        let unique = Self.uniqueModels(placements)
        let toLoad = unique.prefix(Self.maximumUniqueModels)
        skippedModelCount += max(0, unique.count - toLoad.count)
        state = .loading
        status = edText("正在校验并加载元件三维模型…", "Verifying and loading component 3D models…")
        guard generation == request else { return }
        let task = Task { @MainActor [weak self] in
            guard let self, self.generation == request else { return }
            await self.loadModels(Array(toLoad), allPlacements: placements,
                                  loader: loader, generation: request, thickness: self.currentBoardThickness)
        }
        work = task
    }

    /// Cancels and immediately releases owned scene/cache data, but keeps the
    /// cancelled task handle until it is joined so a following load cannot
    /// start a second parse group on top of a still-running one.
    public func stop(ownerID: UUID? = nil) {
        guard ownerID == nil || activeOwnerID == ownerID else { return }
        activeOwnerID = nil
        work?.cancel()
        for token in activeTokens { token.cancel() }
        generation = UUID()
        releaseSceneGraph()
        state = .idle
        status = edText("三维显示已关闭。", "3D display stopped.")
    }

    /// Test/serialization helper: joins the current owned worker without
    /// changing its generation. UI uses task/disappear fencing, not polling.
    public func waitUntilIdle() async {
        await work?.value
    }

    public func stopAndJoin(ownerID: UUID? = nil) async {
        guard ownerID == nil || activeOwnerID == ownerID else { return }
        activeOwnerID = nil
        let previous = work
        let token = UUID(); generation = token
        previous?.cancel()
        for value in activeTokens { value.cancel() }
        releaseSceneGraph()
        state = .idle
        await previous?.value
        if generation == token { work = nil }
    }

    /// A closed workbench cannot start another load through a late view task.
    public func close() async {
        closed = true
        await stopAndJoin()
    }

    private func releaseSceneGraph() {
        activeTokens = []
        geometryCache = [:]; sceneGeometryCache = [:]; loadedKeys = []; skippedKeys = []
        modelRoot.childNodes.forEach { $0.removeFromParentNode() }
        boardRoot.childNodes.forEach { $0.removeFromParentNode() }
        retainedBytes = 0; sceneGeometryBytes = 0; uniqueSceneGeometryCount = 0
        renderedModelCount = 0; skippedModelCount = 0
    }

    private func loadModels(_ models: [(key: String, reference: EDAFootprintModelReference)],
                            allPlacements: [Placement], loader: any EDBoard3DModelLoading,
                            generation: UUID, thickness: Double) async {
        guard generation == self.generation else { return }
        var failedKeys: [String] = []
        var failures: [String] = []
        var triangles = 0
        var aggregate = 0
        let workItems = models.map { model in
            (key: model.key, reference: model.reference, token: EDBoard3DModelCancellation())
        }
        activeTokens = workItems.map(\.token)
        await withTaskGroup(of: (String, EDAFootprintModelReference, Result<EDBoard3DModelGeometry, Error>).self) { group in
            var pending = workItems[...]
            var running = 0
            func startNext() {
                guard let next = pending.popFirst() else { return }
                running += 1
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let geometry = try await loader.loadModel(next.reference, cancellation: next.token)
                        try Task.checkCancellation()
                        return (next.key, next.reference, .success(geometry))
                    } catch {
                        return (next.key, next.reference, .failure(error))
                    }
                }
            }
            while running < Self.maximumConcurrentLoads, !pending.isEmpty { startNext() }
            while let result = await group.next() {
                running -= 1
                if Task.isCancelled { group.cancelAll(); return }
                switch result.2 {
                case .success(let geometry):
                    let decision = await MainActor.run {
                        self.admitOne(key: result.0, geometry: geometry, generation: generation,
                                      remainingBytes: Self.maximumAggregateBytes - aggregate)
                    }
                    guard decision.admitted else {
                        failedKeys.append(result.0)
                        failures.append(decision.reason ?? edText("部分模型超过三维显示预算。", "Some models exceed the 3D display budget."))
                        break
                    }
                    triangles += geometry.triangleCount
                    aggregate += decision.bytes
                case .failure(let error):
                    failedKeys.append(result.0)
                    if error is CancellationError || (error as? EDBoard3DModelLoadError) == .cancelled { break }
                    failures.append((error as? LocalizedError)?.errorDescription ?? String(describing: error))
                }
                if !pending.isEmpty, running < Self.maximumConcurrentLoads { startNext() }
            }
        }
        guard generation == self.generation else { return }
        activeTokens = []
        loadedKeys = Set(sceneGeometryCache.keys)
        skippedKeys = Set(failedKeys)
        sceneGeometryBytes = sceneGeometryCache.values.reduce(0) { total, prototypes in
            total + prototypes.reduce(0) { $0 + Self.sceneBytes($1.geometry) }
        }
        uniqueSceneGeometryCount = sceneGeometryCache.count
        skippedModelCount += failedKeys.count
        // Publish all placements for admitted unique models. Placement count is
        // capped independently of unique model count.
        var published = 0
        var submittedTriangles = 0
        for placement in allPlacements {
            guard published < Self.maximumPlacements else { skippedModelCount += 1; continue }
            guard let prototypes = sceneGeometryCache[placement.key],
                  let geometry = geometryCache[placement.key] else { continue }
            guard geometry.triangleCount <= Self.maximumTriangles - submittedTriangles else {
                skippedModelCount += 1
                failures.append(edText("部分放置实例超过三维显示预算。", "Some placements exceed the 3D display budget."))
                continue
            }
            addPlacement(placement, prototypes: prototypes, thickness: thickness)
            submittedTriangles += geometry.triangleCount
            published += 1
        }
        renderedModelCount = published
        retainedBytes = aggregate
        if published == 0 {
            state = .unavailable(failures.first ?? edText(
                "元件三维模型尚未下载或不受支持；引用仍保留。请在在线元件库中下载模型。",
                "Component 3D models are not downloaded or not supported; references are retained. Download them in the online library."))
        } else {
            state = .ready
            if skippedModelCount > 0 {
                status = edText("显示 \(published) 个元件三维模型；\(skippedModelCount) 个模型未显示（预算或格式限制）。",
                                "Showing \(published) component 3D models; \(skippedModelCount) were not shown (budget or format limits).")
                failureDetail = Array(Set(failures)).prefix(4).joined(separator: "\n")
            } else {
                status = edText("显示 \(published) 个元件的已验证三维模型。", "Showing \(published) verified component 3D models.")
            }
        }
    }

    private func addPlacement(_ placement: Placement, prototypes: [(name: String, geometry: SCNGeometry)],
                              thickness: Double) {
        guard placement.definition != nil else { return }
        let root = SCNNode()
        root.name = "electronics.3d.model." + placement.footprint.id.uuidString
        root.simdTransform = Self.modelMatrix(reference: placement.reference,
            footprint: placement.footprint, boardThickness: thickness)
        for prototype in prototypes {
            // Every placement deliberately shares the same SCNGeometry object;
            // a 256-placement board must not allocate 256 copies of one model.
            let node = SCNNode(geometry: prototype.geometry)
            node.name = "electronics.3d.mesh." + prototype.name
            root.addChildNode(node)
        }
        root.opacity = 0.95
        modelRoot.addChildNode(root)
    }

    private struct Admission: Sendable {
        let admitted: Bool
        let bytes: Int
        let reason: String?
    }

    /// Builds the one prototype set for this source on the main actor, measures
    /// the actual SceneKit source/index Data, then admits it against both the
    /// retained CPU arrays and those native buffers. Rejected prototypes are
    /// released immediately and never attached to a placement.
    private func admitOne(key: String, geometry: EDBoard3DModelGeometry,
                          generation: UUID, remainingBytes: Int) -> Admission {
        guard generation == self.generation else { return .init(admitted: false, bytes: 0, reason: nil) }
        guard geometry.triangleCount > 0, geometry.triangleCount <= Self.maximumTriangles,
              geometry.parts.allSatisfy({ !$0.positions.isEmpty && $0.normals.count == $0.positions.count
                  && !$0.indices.isEmpty && $0.indices.count % 3 == 0 }) else {
            return .init(admitted: false, bytes: 0,
                reason: edText("模型几何为空或无效。", "The model geometry is empty or invalid."))
        }
        let prototypes = buildSceneGeometries(geometry)
        guard !prototypes.isEmpty else {
            return .init(admitted: false, bytes: 0,
                reason: edText("模型未能生成三维几何。", "The model produced no scene geometry."))
        }
        let nativeBytes = prototypes.reduce(0) { $0 + Self.sceneBytes($1.geometry) }
        let total = geometry.cpuBytes + nativeBytes
        guard total > 0, total <= remainingBytes else {
            return .init(admitted: false, bytes: 0,
                reason: edText("部分模型超过三维显示预算。", "Some models exceed the 3D display budget."))
        }
        guard sceneGeometryCache.count < Self.maximumUniqueModels else {
            return .init(admitted: false, bytes: 0,
                reason: edText("三维模型数量超过显示上限。", "The number of 3D models exceeds the display limit."))
        }
        geometryCache[key] = geometry
        sceneGeometryCache[key] = prototypes
        return .init(admitted: true, bytes: total, reason: nil)
    }

    private static func sceneBytes(_ geometry: SCNGeometry) -> Int {
        geometry.sources.reduce(0) { $0 + $1.data.count }
            + geometry.elements.reduce(0) { $0 + $1.data.count }
    }

    private func buildSceneGeometries(_ geometry: EDBoard3DModelGeometry)
        -> [(name: String, geometry: SCNGeometry)] {
        let material = SCNMaterial()
#if canImport(UIKit)
        material.diffuse.contents = UIColor.systemGray
#elseif canImport(AppKit)
        material.diffuse.contents = NSColor.systemGray
#endif
        material.lightingModel = .physicallyBased
        material.isDoubleSided = true
        var prototypes: [(String, SCNGeometry)] = []
        for part in geometry.parts {
            let vertices = part.positions.map { SCNVector3($0.x, $0.y, $0.z) }
            let normals = part.normals.map { SCNVector3($0.x, $0.y, $0.z) }
            let source = SCNGeometrySource(vertices: vertices)
            let normalSource = SCNGeometrySource(normals: normals)
            let element = SCNGeometryElement(indices: part.indices, primitiveType: .triangles)
            let value = SCNGeometry(sources: [source, normalSource], elements: [element])
            value.firstMaterial = material
            prototypes.append((part.name, value))
        }
        return prototypes
    }

    private func buildBoard(project: EDAProject, board: EDABoard, thickness: Double) {
        boardRoot.childNodes.forEach { $0.removeFromParentNode() }
        let path = EDB3BezierPath()
        func polygon(_ points: [EDAPoint]) {
            guard let first = points.first else { return }
            path.move(to: .init(x: first.x, y: first.y))
            for point in points.dropFirst() {
#if canImport(UIKit)
                path.addLine(to: .init(x: point.x, y: point.y))
#else
                path.line(to: .init(x: point.x, y: point.y))
#endif
            }
            path.close()
        }
        polygon(board.outline)
        for points in board.cutouts { polygon(Array(points.reversed())) }
        let holes = board.holes.filter { $0.endPosition == nil }.map { ($0.position, $0.diameter) }
            + board.vias.map { ($0.position, $0.drill) }
            + board.footprints.flatMap { footprint -> [(EDAPoint, Double)] in
                (project.footprints.first { $0.id == footprint.definitionID }?.pads ?? []).compactMap { pad in
                    pad.drill.map { (footprint.point(pad.position), $0) }
                }
            }
        for (center, diameter) in holes {
            polygon((0..<48).reversed().map {
                let angle = Double($0) * 2 * Double.pi / 48
                return center + .init(cos(angle) * diameter / 2, sin(angle) * diameter / 2)
            })
        }
        for hole in board.holes {
            guard let end = hole.endPosition else { continue }
            let angle = atan2(end.y - hole.position.y, end.x - hole.position.x), radius = hole.diameter / 2
            var contour: [EDAPoint] = []
            for index in 0...24 { let a = angle - Double.pi / 2 + Double(index) * Double.pi / 24; contour.append(end + EDAPoint(cos(a) * radius, sin(a) * radius)) }
            for index in 0...24 { let a = angle + Double.pi / 2 + Double(index) * Double.pi / 24; contour.append(hole.position + EDAPoint(cos(a) * radius, sin(a) * radius)) }
            polygon(Array(contour.reversed()))
        }
        let shape = SCNShape(path: path, extrusionDepth: CGFloat(max(0.01, thickness)))
#if canImport(UIKit)
        shape.firstMaterial?.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.78)
#elseif canImport(AppKit)
        shape.firstMaterial?.diffuse.contents = NSColor.systemGreen.withAlphaComponent(0.78)
#endif
        let node = SCNNode(geometry: shape)
        node.name = "electronics.3d.board"
        boardRoot.addChildNode(node)
        let center = EDAPoint(board.outline.map(\.x).reduce(0, +) / Double(board.outline.count),
                              board.outline.map(\.y).reduce(0, +) / Double(board.outline.count))
        let bounds = EDAGeometry.bounds(board.outline)
        let span = bounds.map { max($0.max.x - $0.min.x, $0.max.y - $0.min.y) } ?? 0
        camera.position = SCNVector3(Float(center.x), Float(center.y - max(40, span * 1.25)), Float(28 + thickness * 8))
        camera.look(at: SCNVector3(Float(center.x), Float(center.y), 0))
    }

    private struct Placement {
        let footprint: EDAFootprint
        let definition: EDAFootprintDefinition?
        let reference: EDAFootprintModelReference
        let key: String
        let bottom: Bool
    }

    private static func modelPlacements(project: EDAProject, board: EDABoard) -> [Placement] {
        let definitions = Dictionary(uniqueKeysWithValues: project.footprints.map { ($0.id, $0) })
        var result: [Placement] = []
        for footprint in board.footprints {
            guard let definition = definitions[footprint.definitionID] else { continue }
            let references = definition.modelReferences ?? []
            guard let reference = references.first(where: { $0.isExactRenderable })
                    ?? references.first(where: { ["wrl", "wrz", "glb", "gltf", "obj", "stl"].contains($0.format.lowercased()) })
                    ?? references.first else { continue }
            let key = reference.renderKey
            // A source model is parsed once and shared by every placement.
            result.append(.init(footprint: footprint, definition: definition, reference: reference,
                key: key, bottom: footprint.side == "B.Cu"))
        }
        return result
    }

    private static func uniqueModels(_ placements: [Placement]) -> [(key: String, reference: EDAFootprintModelReference)] {
        var seen = Set<String>()
        var result: [(String, EDAFootprintModelReference)] = []
        for placement in placements where seen.insert(placement.key).inserted {
            result.append((placement.key, placement.reference))
        }
        return result
    }

    /// Pure, tested transform from source millimetres into board millimetres.
    /// Authored model rotation is applied in XYZ order (negated as in the
    /// official KiCad exporter), then footprint Z rotation. Native bottom-side
    /// footprints mirror local X; rotating around Y matches their pad frame
    /// while reversing model Z and the authored outward offset exactly once.
    public static func modelMatrix(reference: EDAFootprintModelReference, footprint: EDAFootprint,
                                   boardThickness: Double) -> simd_float4x4 {
        let scale = reference.scale ?? [1, 1, 1]
        let rotation = reference.rotationDegrees ?? [0, 0, 0]
        let offset = reference.offsetMillimetres ?? [0, 0, 0]
        let bottom = footprint.side == "B.Cu"
        let scaleMatrix = simd_float4x4(diagonal: SIMD4<Float>(Float(scale[0]), Float(scale[1]), Float(scale[2]), 1))
        let rx = Float(-rotation[0] * .pi / 180)
        let ry = Float(-rotation[1] * .pi / 180)
        let rz = Float(-rotation[2] * .pi / 180)
        let authored = matrixRotationZ(rz) * matrixRotationY(ry) * matrixRotationX(rx)
        // The authored Z offset is negated exactly once by the bottom-side
        // X180 flip below (official exporter convention), never twice here.
        let offsetMatrix = matrixTranslation(SIMD3<Float>(Float(offset[0]), Float(offset[1]), Float(offset[2])))
        let local = offsetMatrix * authored * scaleMatrix
        let flip = bottom ? matrixRotationY(.pi) : matrix_identity_float4x4
        let footprintRotation = matrixRotationZ(Float(footprint.angle * .pi / 180))
        // SCNShape with extrusionDepth is centred on z=0, so the physical
        // board spans -thickness/2...+thickness/2. Component models sit on the
        // actual surface, not at an assumed 0...thickness edge.
        let half = Float(max(0.01, boardThickness)) / 2
        let translation = matrixTranslation(SIMD3<Float>(Float(footprint.position.x), Float(footprint.position.y),
            bottom ? -half : half))
        return translation * footprintRotation * flip * local
    }

    private static func matrixRotationX(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, c, s, 0),
                             SIMD4<Float>(0, -s, c, 0), SIMD4<Float>(0, 0, 0, 1))
    }
    private static func matrixRotationY(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(SIMD4<Float>(c, 0, -s, 0), SIMD4<Float>(0, 1, 0, 0),
                             SIMD4<Float>(s, 0, c, 0), SIMD4<Float>(0, 0, 0, 1))
    }
    private static func matrixRotationZ(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(SIMD4<Float>(c, s, 0, 0), SIMD4<Float>(-s, c, 0, 0),
                             SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(0, 0, 0, 1))
    }
    private static func matrixTranslation(_ value: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0),
                      SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(value.x, value.y, value.z, 1))
    }
}
