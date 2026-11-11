#if os(iOS)
@preconcurrency import ARKit
import RealityKit
import simd
import UIKit
import AVFoundation
import FloeToolboxUtilities

/// One real raycast-derived sample. Points are only ever created from actual
/// plane raycasts, never synthesized.
public struct SpatialMeasurementSample: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let position: SIMD3<Float>
    /// The detected plane this sample belongs to; area mode requires one
    /// shared plane so area is never computed across unrelated surfaces.
    public let planeID: UUID?
}

@MainActor public final class SpatialMeasurementSession: NSObject, ObservableObject {
    public enum Mode: String, CaseIterable, Sendable { case length, area }

    public enum Phase: Equatable, Sendable {
        case idle, running, paused, denied, unavailable, failed(String)
    }

    public enum Issue: String, Equatable, Sendable {
        case noSurface, mixedPlanes, notCoplanar, selfIntersecting, degenerate
    }

    public enum TrackingSummary: Equatable, Sendable {
        case normal, initializing, limited(String), notAvailable
    }

    public struct ProjectedLabel: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let position: CGPoint
        public let text: String
    }

    public struct Readout: Equatable, Sendable {
        public var segmentLengths: [Double] = []
        public var totalLength: Double = 0
        public var area: Double? = nil
        public var issue: Issue? = nil
        public var canClose: Bool = false
    }

    private static let maximumSamples = 64
    private static let pointRadius: Float = 0.016
    private static let segmentRadius: Float = 0.008

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var tracking: TrackingSummary = .notAvailable
    @Published public private(set) var samples: [SpatialMeasurementSample] = []
    @Published public private(set) var hasDetectedPlane = false
    @Published public private(set) var polygonClosed = false
    @Published public private(set) var readout = Readout()
    @Published public private(set) var labels: [ProjectedLabel] = []
    @Published public private(set) var snapshotImage: UIImage?

    @Published public private(set) var mode: Mode = .length
    /// Unit used for projected labels and readouts; the view owns the picker.
    @Published public var unit: SpatialMeasurementUnit = .meter {
        didSet { updateLabels(force: true) }
    }

    private weak var arView: ARView?
    private var session: ARSession? { arView?.session }
    private var measurementRoot: AnchorEntity?
    private var generation = UUID()
    private var startPending = false
    private var pendingPermissionGeneration: UUID?
    private var startDeferredUntilActive = false
    private var lastLabelUpdate = Date.distantPast
    private var wasRunningBeforeInterruption = false

    public override init() {
        super.init()
    }

    /// Called by the camera container when its ARView is created. RealityKit
    /// owns the session; the coordinator only configures and observes it.
    public func attach(_ view: ARView) {
        arView = view
        view.automaticallyConfigureSession = false
        view.session.delegate = self
        view.session.delegateQueue = .main
        if measurementRoot == nil {
            let root = AnchorEntity(world: matrix_identity_float4x4)
            view.scene.addAnchor(root)
            measurementRoot = root
        }
        runIfAttached()
    }

    // MARK: - Lifecycle

    /// Availability is checked before any camera access; callers show the
    /// truthful unavailable state instead of starting a doomed session.
    public static var isWorldTrackingSupported: Bool {
        ARWorldTrackingConfiguration.isSupported
    }

    /// Explicit user start: checks support and camera permission first. The
    /// permission callback is fenced by a generation token so a late grant
    /// can never open the camera after pause/stop or while the scene is
    /// inactive.
    public func requestStart() {
        guard Self.isWorldTrackingSupported else { phase = .unavailable; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            start()
        case .notDetermined:
            let token = UUID()
            pendingPermissionGeneration = token
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.pendingPermissionGeneration == token else { return }
                    self.pendingPermissionGeneration = nil
                    guard granted else { self.phase = .denied; return }
                    guard self.phase == .idle else { return }
                    guard UIApplication.shared.applicationState == .active else {
                        // Keep the user's explicit intent; resume only when
                        // the scene is back in the foreground.
                        self.startDeferredUntilActive = true
                        return
                    }
                    self.start()
                }
            }
        default:
            phase = .denied
        }
    }

    /// Called by the view when the scene becomes active again; only a
    /// previously deferred explicit start resumes here.
    public func sceneBecameActive() {
        guard startDeferredUntilActive else { return }
        startDeferredUntilActive = false
        guard phase == .idle,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        start()
    }

    /// A permission sheet makes the scene inactive too. Preserve its explicit
    /// pending start until a real background transition or view teardown.
    public func sceneBecameInactive(fullyBackground: Bool) {
        if fullyBackground {
            pendingPermissionGeneration = nil
            startDeferredUntilActive = false
        }
        wasRunningBeforeInterruption = false
        guard phase == .running else { return }
        session?.pause()
        phase = .paused
    }

    private func start() {
        guard Self.isWorldTrackingSupported else { phase = .unavailable; return }
        generation = UUID()
        // World tracking resets to a new coordinate frame, so retained
        // samples and entities from any earlier run are cleared rather than
        // silently reinterpreted.
        samples = []
        polygonClosed = false
        snapshotImage = nil
        measurementRoot?.children.forEach { $0.removeFromParent() }
        hasDetectedPlane = false
        tracking = .initializing
        phase = .running
        readout = Readout()
        labels = []
        // The camera container may not exist yet (placeholder was showing);
        // the run is applied when the ARView attaches.
        startPending = true
        runIfAttached()
    }

    private func runIfAttached() {
        guard startPending, let session else { return }
        startPending = false
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.isAutoFocusEnabled = true
        session.delegate = self
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    public func pause() {
        pendingPermissionGeneration = nil
        startDeferredUntilActive = false
        wasRunningBeforeInterruption = false
        guard phase == .running, let session else { return }
        session.pause()
        phase = .paused
    }

    public func resume() {
        guard phase == .paused, UIApplication.shared.applicationState == .active, let session else { return }
        guard Self.isWorldTrackingSupported else { phase = .unavailable; return }
        session.run(session.configuration ?? ARWorldTrackingConfiguration(), options: [])
        phase = .running
        wasRunningBeforeInterruption = false
    }

    /// Full teardown on view exit: samples and entities are released, the
    /// delegate is detached and late callbacks are fenced by generation.
    public func stop() {
        generation = UUID()
        startPending = false
        pendingPermissionGeneration = nil
        startDeferredUntilActive = false
        if let session {
            session.delegate = nil
            session.pause()
        }
        arView = nil
        measurementRoot?.removeFromParent()
        measurementRoot = nil
        samples = []
        polygonClosed = false
        readout = Readout()
        labels = []
        snapshotImage = nil
        hasDetectedPlane = false
        tracking = .notAvailable
        phase = .idle
        wasRunningBeforeInterruption = false
    }

    // MARK: - Editing

    public func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        polygonClosed = false
        rebuild()
    }

    /// Raycasts through the reticle at the view center and anchors a sample
    /// on the detected plane there.
    public func placePoint() {
        guard phase == .running, !polygonClosed,
              samples.count < Self.maximumSamples else { return }
        guard let view = arView else { return }
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let results = view.raycast(from: center, allowing: .existingPlaneGeometry, alignment: .any)
        guard let hit = results.first else {
            readout.issue = .noSurface
            return
        }
        let planeID = (hit.anchor as? ARPlaneAnchor)?.identifier
        let position = SIMD3<Float>(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y, hit.worldTransform.columns.3.z)
        let sample = SpatialMeasurementSample(id: UUID(), position: position, planeID: planeID)
        if mode == .area, let issue = areaIssue(for: samples + [sample]) {
            readout.issue = issue
            return
        }
        readout.issue = nil
        samples.append(sample)
        rebuild()
    }

    public func undo() {
        guard !polygonClosed, !samples.isEmpty else { return }
        samples.removeLast()
        readout.issue = nil
        rebuild()
    }

    public func clear() {
        guard !samples.isEmpty else { return }
        samples.removeAll()
        polygonClosed = false
        readout.issue = nil
        rebuild()
    }

    public func closePolygon() {
        guard mode == .area, samples.count >= 3, !polygonClosed,
              readout.issue == nil, readout.area != nil else { return }
        polygonClosed = true
        rebuild()
    }

    // MARK: - Snapshot

    /// Snapshot is fenced by generation: a stop/restart between capture and
    /// delivery discards the stale image instead of publishing it.
    public func captureSnapshot() async {
        let token = generation
        guard phase == .running || phase == .paused,
              let view = arView else { return }
        let image: UIImage? = await withCheckedContinuation { continuation in
            view.snapshot(saveToHDR: false) { snapshot in
                continuation.resume(returning: snapshot)
            }
        }
        guard generation == token, UIApplication.shared.applicationState == .active else { return }
        snapshotImage = image
    }

    // MARK: - Measurement

    private func areaIssue(for points: [SpatialMeasurementSample]) -> Issue? {
        guard points.count >= 2 else { return nil }
        let known = points.compactMap(\.planeID)
        if known.count != points.count || Set(known).count > 1 { return .mixedPlanes }
        guard points.count >= 3 else { return nil }
        let positions = points.map { SIMD3<Double>($0.position) }
        do {
            _ = try SpatialMeasurementMath.polygonArea(positions)
            return nil
        } catch SpatialMeasurementMathError.notCoplanar {
            return .notCoplanar
        } catch SpatialMeasurementMathError.selfIntersecting {
            return .selfIntersecting
        } catch {
            return .degenerate
        }
    }

    private func rebuild() {
        updateReadout()
        rebuildEntities()
        updateLabels(force: true)
    }

    private func updateReadout() {
        var next = Readout()
        let positions = samples.map { SIMD3<Double>($0.position) }
        next.segmentLengths = (1..<positions.count).map { SpatialMeasurementMath.distance(positions[$0 - 1], positions[$0]) }
        next.totalLength = SpatialMeasurementMath.polylineLength(positions)
        if mode == .area {
            if let issue = areaIssue(for: samples) {
                next.issue = issue
            } else if samples.count >= 3, let area = try? SpatialMeasurementMath.polygonArea(positions) {
                next.area = area
                next.canClose = !polygonClosed
            }
        }
        readout = next
    }

    private func updateLabels(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastLabelUpdate) > 0.25 else { return }
        lastLabelUpdate = Date()
        guard let view = arView, samples.count >= 2 else {
            if !labels.isEmpty { labels = [] }
            return
        }
        var next: [ProjectedLabel] = []
        let positions = samples.map(\.position)
        for index in 1..<positions.count {
            let midpoint = (positions[index - 1] + positions[index]) / 2
            if let point = view.project(midpoint) {
                let length = SpatialMeasurementMath.distance(SIMD3<Double>(positions[index - 1]), SIMD3<Double>(positions[index]))
                next.append(ProjectedLabel(id: samples[index].id, position: point, text: lengthText(length)))
            }
        }
        if mode == .area, let area = readout.area, let center = view.project(centroid(of: positions)) {
            next.append(ProjectedLabel(id: samples[0].id, position: center, text: unit.areaFormat(area)))
        }
        labels = next
    }

    private func centroid(of positions: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !positions.isEmpty else { return .zero }
        var sum = SIMD3<Float>(0, 0, 0)
        for position in positions { sum += position }
        return sum / Float(positions.count)
    }

    private func lengthText(_ meters: Double) -> String { unit.format(meters) }

    // MARK: - Entities

    private func rebuildEntities() {
        guard let root = measurementRoot else { return }
        for child in root.children { child.removeFromParent() }
        guard !samples.isEmpty else { return }
        let pointMaterial = SimpleMaterial(color: UIColor(red: 0.05, green: 0.75, blue: 0.95, alpha: 1), isMetallic: false)
        for sample in samples {
            let sphere = ModelEntity(mesh: .generateSphere(radius: Self.pointRadius), materials: [pointMaterial])
            sphere.position = sample.position
            sphere.generateCollisionShapes(recursive: false)
            root.addChild(sphere)
        }
        let positions = samples.map(\.position)
        if positions.count > 1 {
            let segmentMaterial = SimpleMaterial(color: UIColor(red: 0.05, green: 0.75, blue: 0.95, alpha: 1), isMetallic: false)
            for index in 1..<positions.count {
                let segment = cylinderEntity(from: positions[index - 1], to: positions[index], radius: Self.segmentRadius, material: segmentMaterial)
                root.addChild(segment)
            }
        }
        if mode == .area, samples.count >= 3, readout.issue == nil, readout.area != nil {
            if let fill = polygonEntity(from: positions) { root.addChild(fill) }
        }
    }

    private func cylinderEntity(from start: SIMD3<Float>, to end: SIMD3<Float>, radius: Float, material: SimpleMaterial) -> ModelEntity {
        let delta = end - start
        let length = simd_length(delta)
        let mesh = Self.cylinderMesh(height: length, radius: radius)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = (start + end) / 2
        entity.orientation = simd_quaternion(delta, SIMD3<Float>(0, 1, 0))
        return entity
    }

    private static func cylinderMesh(height: Float, radius: Float, segments: Int = 12) -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for index in 0...segments {
            let angle = Float(index) / Float(segments) * 2 * .pi
            let x = cos(angle) * radius
            let z = sin(angle) * radius
            positions.append(SIMD3<Float>(x, -height / 2, z))
            positions.append(SIMD3<Float>(x, height / 2, z))
            let normal = simd_normalize(SIMD3<Float>(x, 0, z))
            normals.append(normal)
            normals.append(normal)
        }
        for index in 0..<segments {
            let base = UInt32(index * 2)
            indices.append(contentsOf: [base, base + 1, base + 2, base + 1, base + 3, base + 2])
        }
        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor])) ?? MeshResource.generateBox(size: radius)
    }

    private func polygonEntity(from positions: [SIMD3<Float>]) -> ModelEntity? {
        guard positions.count >= 3,
              let basis = SpatialMeasurementMath.planeBasis(for: positions.map({ SIMD3<Double>($0) })) else { return nil }
        let projected = positions.map { SpatialMeasurementMath.project(SIMD3<Double>($0), onto: basis) }
        // Area fill only exists for validated simple polygons; triangulation
        // returns nil for anything else and the overlay is skipped honestly.
        guard let triangles = SpatialMeasurementMath.triangulate(projected) else { return nil }
        let normal = SIMD3<Float>(basis.normal)
        let lift = normal * 0.002 // avoid z-fighting with the real surface
        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(positions.count)
        for point in projected {
            let position = basis.origin + basis.u * point.x + basis.v * point.y
            vertices.append(SIMD3<Float>(position) + lift)
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(triangles.count * 3)
        for ear in triangles {
            indices.append(contentsOf: [ear.x, ear.y, ear.z])
        }
        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffers.Positions(vertices)
        descriptor.primitives = .triangles(indices)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return nil }
        let material = SimpleMaterial(color: UIColor(red: 0.05, green: 0.75, blue: 0.95, alpha: 0.28), isMetallic: false)
        return ModelEntity(mesh: mesh, materials: [material])
    }
}

// delegateQueue is .main, so every callback is delivered on the main actor
// already; the identity check fences callbacks in flight before stop().
extension SpatialMeasurementSession: @preconcurrency ARSessionDelegate {
    public func session(_ session: ARSession, didFailWithError error: Error) {
        guard session === arView?.session else { return }
        phase = .failed(error.localizedDescription)
    }

    public func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        guard session === arView?.session else { return }
        switch camera.trackingState {
        case .notAvailable: tracking = .notAvailable
        case .limited(.initializing): tracking = .initializing
        case .limited(let reason):
            let text: String
            switch reason {
            case .excessiveMotion: text = "excessiveMotion"
            case .insufficientFeatures: text = "insufficientFeatures"
            case .relocalizing: text = "relocalizing"
            case .initializing: text = "initializing"
            @unknown default: text = "limited"
            }
            tracking = .limited(text)
        case .normal: tracking = .normal
        @unknown default: tracking = .notAvailable
        }
    }

    public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard session === arView?.session else { return }
        if anchors.contains(where: { $0 is ARPlaneAnchor }) { hasDetectedPlane = true }
    }

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard session === arView?.session else { return }
        updateLabels()
    }

    public func sessionWasInterrupted(_ session: ARSession) {
        guard session === arView?.session else { return }
        wasRunningBeforeInterruption = phase == .running
        session.pause()
        phase = .paused
    }

    public func sessionInterruptionEnded(_ session: ARSession) {
        guard session === arView?.session, wasRunningBeforeInterruption else { return }
        resume()
    }
}
#endif
