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
    /// Detected-plane evidence. Length may also use an explicitly estimated
    /// ARKit raycast; area always requires a detected, geometrically shared plane.
    public let planeID: UUID?
    public let surfaceNormal: SIMD3<Float>?
    public let estimated: Bool
}

@MainActor public final class SpatialMeasurementSession: NSObject, ObservableObject {
    public enum Mode: String, CaseIterable, Sendable { case length, area }

    public enum Phase: Equatable, Sendable {
        case idle, running, paused, denied, unavailable, cameraBusy, failed(String)
    }

    public enum Issue: String, Equatable, Sendable {
        case noSurface, mixedPlanes, notCoplanar, selfIntersecting, degenerate, invalidPoint, pointLimit
    }

    public enum TrackingSummary: Equatable, Sendable {
        case normal, initializing, limited(String), notAvailable
    }

    public enum Target: Equatable, Sendable {
        case unavailable, searching, ready(estimated: Bool), blocked(Issue)
    }

    /// Native boundaries are injectable for state-contract qualification without
    /// opening an ARView, requesting permission, or fabricating raycast results.
    struct Access {
        var supported: @MainActor () -> Bool
        var authorization: @MainActor () -> AVAuthorizationStatus
        var requestPermission: @MainActor (@escaping @Sendable (Bool) -> Void) -> Void
        var active: @MainActor () -> Bool
        var acquire: @MainActor () -> OpticsCaptureLease?
        var owns: @MainActor (OpticsCaptureLease) -> Bool
        var prepare: @MainActor (OpticsCaptureLease) async -> Bool
        var release: @MainActor (OpticsCaptureLease) -> Void

        @MainActor static var live: Access {
            Access(supported: { ARWorldTrackingConfiguration.isSupported },
                   authorization: { AVCaptureDevice.authorizationStatus(for: .video) },
                   requestPermission: { AVCaptureDevice.requestAccess(for: .video, completionHandler: $0) },
                   active: { UIApplication.shared.applicationState == .active },
                   acquire: { OpticsCaptureService.shared.acquire(.spatial) },
                   owns: { OpticsCaptureService.shared.owns($0) },
                   prepare: { await OpticsCaptureService.shared.prepareExternalCapture(lease: $0) },
                   release: { OpticsCaptureService.shared.release($0) })
        }
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
    @Published public private(set) var target: Target = .unavailable
    @Published public private(set) var isStarting = false

    @Published public private(set) var mode: Mode = .length
    /// Unit used for projected labels and readouts; the view owns the picker.
    @Published public var unit: SpatialMeasurementUnit = .meter {
        didSet {
            snapshotRevision = UUID()
            snapshotImage = nil
            updateLabels(force: true)
        }
    }

    private weak var arView: ARView?
    private var session: ARSession? { arView?.session }
    private var measurementRoot: AnchorEntity?
    private var generation = UUID()
    private var startPending = false
    private(set) var pendingPermissionGeneration: UUID?
    private var startDeferredUntilActive = false
    private var lastLabelUpdate = Date.distantPast
    private var wasRunningBeforeInterruption = false
    private let access: Access
    private var captureLease: OpticsCaptureLease?
    private(set) var preparation: Task<Void, Never>?
    private var resuming = false
    private var resetOnNextRun = true
    private var attachedSessionHasRun = false
    private var sceneActive = true
    private var resumeWhenActive = false
    private var lastTargetUpdate = Date.distantPast
    private var snapshotRevision = UUID()
    private let measurementLabelID = UUID()
    private var ownsCamera: Bool { captureLease.map { access.owns($0) } ?? false }

    public override init() {
        access = .live
        super.init()
    }

    init(access: Access) {
        self.access = access
        super.init()
    }

    /// Called by the camera container when its ARView is created. RealityKit
    /// owns the session; the coordinator only configures and observes it.
    public func attach(_ view: ARView) {
        guard arView !== view else { runIfAttached(); return }
        if let previous = arView { detach(previous) }
        arView = view
        attachedSessionHasRun = false
        view.automaticallyConfigureSession = false
        view.session.delegateQueue = .main
        view.session.delegate = self
        if measurementRoot == nil {
            let root = AnchorEntity(world: matrix_identity_float4x4)
            view.scene.addAnchor(root)
            measurementRoot = root
        }
        runIfAttached()
    }

    func detach(_ view: ARView) {
        guard arView === view else { return }
        view.session.delegate = nil
        view.session.pause()
        arView = nil
        attachedSessionHasRun = false
        measurementRoot?.removeFromParent()
        measurementRoot = nil
        startPending = false
        target = .unavailable
        if phase == .running { phase = .paused }
        cancelStart()
        releaseCamera()
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
        guard phase != .running, !isStarting else { return }
        beginPreparation(resuming: false)
    }

    private func beginPreparation(resuming: Bool) {
        guard access.supported() else { failStart(.unavailable); return }
        guard !isStarting else { return }
        self.resuming = resuming
        generation = UUID()
        let token = generation
        guard let lease = captureLease ?? access.acquire() else { failStart(.cameraBusy); return }
        captureLease = lease
        isStarting = true
        if phase != .paused { phase = .idle }
        switch access.authorization() {
        case .authorized:
            prepareCamera(token: token, lease: lease)
        case .notDetermined:
            pendingPermissionGeneration = token
            access.requestPermission(Self.makePermissionHandler(for: self, token: token))
        default:
            failStart(.denied)
        }
    }

    // AVCaptureDevice documents delivery on an arbitrary queue. This entry
    // must not inherit MainActor; only the Bool grant crosses into the task.
    nonisolated static func makePermissionHandler(
        for owner: SpatialMeasurementSession, token: UUID,
        didReceive: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) -> @Sendable (Bool) -> Void {
        { @Sendable [weak owner] granted in
            Task { @MainActor [weak owner] in
                let accepted = owner?.permissionReceived(granted, token: token) ?? false
                didReceive?(accepted)
            }
        }
    }

    private func permissionReceived(_ granted: Bool, token: UUID) -> Bool {
        guard pendingPermissionGeneration == token, generation == token,
              isStarting, let lease = captureLease, access.owns(lease) else { return false }
        pendingPermissionGeneration = nil
        guard granted else { failStart(.denied); return true }
        guard sceneActive, access.active() else { startDeferredUntilActive = true; return true }
        prepareCamera(token: token, lease: lease)
        return true
    }

    private func prepareCamera(token: UUID, lease: OpticsCaptureLease) {
        preparation?.cancel()
        preparation = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, self.generation == token, self.isStarting,
                  self.captureLease == lease else { return }
            guard self.access.owns(lease) else { self.failStart(.cameraBusy); return }
            let ready = await self.access.prepare(lease)
            guard !Task.isCancelled, self.generation == token, self.isStarting,
                  self.captureLease == lease else { return }
            guard self.access.owns(lease) else { self.failStart(.cameraBusy); return }
            guard ready else { self.failStart(.cameraBusy); return }
            guard self.access.authorization() == .authorized else { self.failStart(.denied); return }
            guard self.sceneActive, self.access.active() else { self.startDeferredUntilActive = true; return }
            self.isStarting = false
            self.startDeferredUntilActive = false
            self.start(reset: !self.resuming)
        }
    }

    /// Settings recovery never opens the camera by itself. It restores Start;
    /// only a pending grant or a previously active measurement may resume.
    public func sceneBecameActive() {
        sceneActive = true
        guard access.supported() else { failStart(.unavailable); return }
        let authorization = access.authorization()
        if authorization == .denied || authorization == .restricted { failStart(.denied); return }
        if phase == .denied { phase = .idle }
        if startDeferredUntilActive, isStarting, let lease = captureLease {
            startDeferredUntilActive = false
            prepareCamera(token: generation, lease: lease)
        } else if resumeWhenActive, phase == .paused {
            resumeWhenActive = false
            resume()
        }
    }

    /// A permission sheet makes the scene inactive too. Preserve its explicit
    /// pending start until a real background transition or view teardown.
    public func sceneBecameInactive(fullyBackground: Bool) {
        sceneActive = false
        if fullyBackground {
            cancelStart()
            if phase != .running { releaseCamera() }
        }
        guard phase == .running else { return }
        session?.pause()
        generation = UUID()
        releaseCamera()
        target = .unavailable
        tracking = .notAvailable
        resumeWhenActive = true
        phase = .paused
    }

    private func start(reset: Bool) {
        guard access.supported() else { failStart(.unavailable); return }
        // World tracking resets to a new coordinate frame, so retained
        // samples and entities from any earlier run are cleared rather than
        // silently reinterpreted.
        if reset {
            samples = []
            polygonClosed = false
            snapshotImage = nil
            measurementRoot?.children.forEach { $0.removeFromParent() }
            hasDetectedPlane = false
            readout = Readout()
            labels = []
        }
        snapshotRevision = UUID()
        resumeWhenActive = false
        wasRunningBeforeInterruption = false
        target = .unavailable
        tracking = reset || samples.isEmpty ? .initializing : .limited("relocalizing")
        phase = .running
        resetOnNextRun = reset
        // The camera container may not exist yet (placeholder was showing);
        // the run is applied when the ARView attaches.
        startPending = true
        runIfAttached()
    }

    private func runIfAttached() {
        guard startPending, phase == .running, let session, let lease = captureLease,
              access.owns(lease), sceneActive, access.active(), access.authorization() == .authorized else { return }
        startPending = false
        let configuration = (resetOnNextRun ? nil : session.configuration as? ARWorldTrackingConfiguration)
            ?? ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.isAutoFocusEnabled = true
        session.delegateQueue = .main
        session.delegate = self
        session.run(configuration, options: resetOnNextRun ? [.resetTracking, .removeExistingAnchors] : [])
        attachedSessionHasRun = true
    }

    public func pause() {
        cancelStart()
        generation = UUID()
        resumeWhenActive = false
        wasRunningBeforeInterruption = false
        session?.pause()
        releaseCamera()
        target = .unavailable
        if phase == .running { phase = .paused }
    }

    public func resume() {
        guard phase == .paused, sceneActive, access.active(), !isStarting else { return }
        // A missing ARView means its world frame was destroyed, so retained
        // coordinates cannot safely be reused in the replacement session.
        beginPreparation(resuming: arView != nil && attachedSessionHasRun)
        wasRunningBeforeInterruption = false
    }

    /// Full teardown on view exit: samples and entities are released, the
    /// delegate is detached and late callbacks are fenced by generation.
    public func stop() {
        generation = UUID()
        startPending = false
        cancelStart()
        if let session {
            session.delegate = nil
            session.pause()
        }
        releaseCamera()
        arView = nil
        attachedSessionHasRun = false
        measurementRoot?.removeFromParent()
        measurementRoot = nil
        samples = []
        polygonClosed = false
        readout = Readout()
        labels = []
        snapshotImage = nil
        hasDetectedPlane = false
        tracking = .notAvailable
        target = .unavailable
        phase = .idle
        wasRunningBeforeInterruption = false
        resumeWhenActive = false
    }

    private func cancelStart() {
        generation = UUID()
        preparation?.cancel()
        preparation = nil
        isStarting = false
        pendingPermissionGeneration = nil
        startDeferredUntilActive = false
    }

    private func releaseCamera() {
        if let lease = captureLease {
            captureLease = nil
            access.release(lease)
        }
    }

    private func failStart(_ phase: Phase) {
        cancelStart()
        session?.pause()
        startPending = false
        releaseCamera()
        tracking = .notAvailable
        target = .unavailable
        self.phase = phase
        resumeWhenActive = false
        wasRunningBeforeInterruption = false
    }

    // MARK: - Editing

    public func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        polygonClosed = false
        rebuild()
    }

    public var canPlacePoint: Bool {
        guard phase == .running, ownsCamera, tracking == .normal, !polygonClosed,
              samples.count < Self.maximumSamples else { return false }
        if case .ready = target { return true }
        return false
    }

    /// The button measures at the reticle; a camera tap measures at the actual
    /// tapped screen location. Both always perform a fresh, real ARKit raycast.
    public func placePoint(at location: CGPoint? = nil) {
        guard phase == .running, ownsCamera, tracking == .normal, !polygonClosed else { return }
        guard samples.count < Self.maximumSamples else { readout.issue = .pointLimit; return }
        guard let view = arView else { return }
        let point = location ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard view.bounds.contains(point), let sample = raycast(at: point, in: view) else {
            readout.issue = .noSurface
            return
        }
        _ = record(sample)
    }

    private func raycast(at point: CGPoint, in view: ARView) -> SpatialMeasurementSample? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let detected = view.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .any)
            .first { $0.anchor is ARPlaneAnchor }
        // Estimated plane hits are still ARKit measurements, but are explicitly
        // marked and used only for length. Area never accepts this fallback.
        let hit = detected ?? (mode == .length
            ? view.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first : nil)
        guard let hit else { return nil }
        let transform = hit.worldTransform
        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        guard SpatialMeasurementMath.isFinite(SIMD3<Double>(position)) else { return nil }
        let plane = hit.anchor as? ARPlaneAnchor
        let normal = plane.map { SIMD3<Float>($0.transform.columns.1.x, $0.transform.columns.1.y, $0.transform.columns.1.z) }
        return SpatialMeasurementSample(id: UUID(), position: position, planeID: plane?.identifier,
                                        surfaceNormal: normal, estimated: detected == nil)
    }

    private func placementIssue(for sample: SpatialMeasurementSample) -> Issue? {
        guard SpatialMeasurementMath.isFinite(SIMD3<Double>(sample.position)) else { return .invalidPoint }
        if let previous = samples.last,
           SpatialMeasurementMath.distance(SIMD3<Double>(previous.position), SIMD3<Double>(sample.position))
            < SpatialMeasurementMath.duplicateTolerance { return .degenerate }
        return mode == .area ? areaIssue(for: samples + [sample]) : nil
    }

    /// The production placement boundary, also exercised by synthetic state
    /// contracts. Calling this internally never substitutes for a native raycast.
    @discardableResult func record(_ sample: SpatialMeasurementSample) -> Bool {
        guard phase == .running, ownsCamera, tracking == .normal, !polygonClosed,
              samples.count < Self.maximumSamples else { return false }
        if let issue = placementIssue(for: sample) {
            readout.issue = issue
            return false
        }
        readout.issue = nil
        samples.append(sample)
        rebuild()
        return true
    }

    private func updateTarget(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastTargetUpdate) >= 0.1 else { return }
        lastTargetUpdate = Date()
        let next: Target
        if phase != .running || tracking != .normal || polygonClosed {
            next = .unavailable
        } else if samples.count >= Self.maximumSamples {
            next = .blocked(.pointLimit)
        } else if let view = arView,
                  let sample = raycast(at: CGPoint(x: view.bounds.midX, y: view.bounds.midY), in: view) {
            next = placementIssue(for: sample).map(Target.blocked) ?? .ready(estimated: sample.estimated)
        } else {
            next = .searching
        }
        if target != next { target = next }
    }

    func updateTracking(_ summary: TrackingSummary) {
        guard phase == .running, ownsCamera else { return }
        if tracking != summary { tracking = summary }
        updateTarget(force: true)
    }

    public func undo() {
        guard !samples.isEmpty else { return }
        if polygonClosed { polygonClosed = false }
        else { samples.removeLast() }
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
              areaIssue(for: samples) == nil, readout.area != nil else { return }
        polygonClosed = true
        rebuild()
    }

    // MARK: - Snapshot

    /// Snapshot is fenced by generation: a stop/restart between capture and
    /// delivery discards the stale image instead of publishing it.
    public func captureSnapshot(summary: String = "") async {
        let token = generation
        let revision = snapshotRevision
        guard phase == .running || phase == .paused,
              let view = arView else { return }
        let bytes: Data? = await withCheckedContinuation { continuation in
            view.snapshot(saveToHDR: false, completion: Self.makeSnapshotHandler(continuation))
        }
        guard generation == token, snapshotRevision == revision, access.active(),
              let bytes, let image = UIImage(data: bytes) else { return }
        snapshotImage = snapshot(image, summary: summary)
    }

    nonisolated private static func makeSnapshotHandler(
        _ continuation: CheckedContinuation<Data?, Never>
    ) -> @Sendable (UIImage?) -> Void {
        { @Sendable image in continuation.resume(returning: image?.pngData()) }
    }

    private func snapshot(_ image: UIImage, summary: String) -> UIImage {
        guard !summary.isEmpty else { return image }
        let width = image.size.width
        let font = UIFont.systemFont(ofSize: max(14, width / 35), weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let text = summary as NSString
        let textSize = text.boundingRect(with: CGSize(width: max(1, width - 32), height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin], attributes: attributes, context: nil).size
        let footer = ceil(textSize.height) + 32
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: image.size.height + footer)).image { context in
            image.draw(at: .zero)
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: image.size.height, width: width, height: footer))
            text.draw(in: CGRect(x: 16, y: image.size.height + 16, width: max(1, width - 32), height: textSize.height),
                      withAttributes: attributes)
        }
    }

    // MARK: - Measurement

    private func areaIssue(for points: [SpatialMeasurementSample]) -> Issue? {
        guard let first = points.first else { return nil }
        guard !first.estimated, first.planeID != nil, let referenceNormal = first.surfaceNormal else { return .mixedPlanes }
        for point in points {
            guard !point.estimated, point.planeID != nil, let normal = point.surfaceNormal,
                  SpatialMeasurementMath.isSameSurface(referencePoint: SIMD3<Double>(first.position),
                      referenceNormal: SIMD3<Double>(referenceNormal), point: SIMD3<Double>(point.position),
                      normal: SIMD3<Double>(normal)) else { return .mixedPlanes }
        }
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
        snapshotRevision = UUID()
        snapshotImage = nil
        updateReadout()
        rebuildEntities()
        updateLabels(force: true)
        updateTarget(force: true)
    }

    private func updateReadout() {
        var next = Readout()
        let positions = samples.map { SIMD3<Double>($0.position) }
        next.segmentLengths = SpatialMeasurementMath.segmentLengths(positions, closed: mode == .area && polygonClosed)
        next.totalLength = next.segmentLengths.reduce(0, +)
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
            if let point = view.project(midpoint), point.x.isFinite, point.y.isFinite, view.bounds.contains(point) {
                let length = SpatialMeasurementMath.distance(SIMD3<Double>(positions[index - 1]), SIMD3<Double>(positions[index]))
                next.append(ProjectedLabel(id: samples[index].id, position: point, text: lengthText(length)))
            }
        }
        if mode == .area, polygonClosed, let first = positions.first, let last = positions.last,
           let point = view.project((first + last) / 2), point.x.isFinite, point.y.isFinite, view.bounds.contains(point) {
            let length = SpatialMeasurementMath.distance(SIMD3<Double>(last), SIMD3<Double>(first))
            next.append(ProjectedLabel(id: samples[0].id, position: point, text: lengthText(length)))
        }
        if mode == .area, let area = readout.area, let center = view.project(centroid(of: positions)),
           center.x.isFinite, center.y.isFinite, view.bounds.contains(center) {
            next.append(ProjectedLabel(id: measurementLabelID, position: center, text: unit.areaFormat(area)))
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
                if let segment = cylinderEntity(from: positions[index - 1], to: positions[index], radius: Self.segmentRadius, material: segmentMaterial) {
                    root.addChild(segment)
                }
            }
            if mode == .area, polygonClosed, let first = positions.first, let last = positions.last,
               let segment = cylinderEntity(from: last, to: first, radius: Self.segmentRadius, material: segmentMaterial) {
                root.addChild(segment)
            }
        }
        if mode == .area, polygonClosed, samples.count >= 3, readout.issue == nil, readout.area != nil {
            if let fill = polygonEntity(from: positions) { root.addChild(fill) }
        }
    }

    private func cylinderEntity(from start: SIMD3<Float>, to end: SIMD3<Float>, radius: Float, material: SimpleMaterial) -> ModelEntity? {
        let delta = end - start
        let length = simd_length(delta)
        guard length.isFinite, length >= Float(SpatialMeasurementMath.duplicateTolerance) else { return nil }
        guard let mesh = Self.cylinderMesh(height: length, radius: radius) else { return nil }
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = (start + end) / 2
        entity.orientation = simd_quaternion(SIMD3<Float>(0, 1, 0), delta / length)
        return entity
    }

    private static func cylinderMesh(height: Float, radius: Float, segments: Int = 12) -> MeshResource? {
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
        return try? MeshResource.generate(from: [descriptor])
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
        guard phase == .running || phase == .paused else { return }
        failStart(access.authorization() == .denied || access.authorization() == .restricted
                  ? .denied : .failed(error.localizedDescription))
    }

    public func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        guard session === arView?.session, phase == .running else { return }
        switch camera.trackingState {
        case .notAvailable: updateTracking(.notAvailable)
        case .limited(.initializing): updateTracking(.initializing)
        case .limited(let reason):
            let text: String
            switch reason {
            case .excessiveMotion: text = "excessiveMotion"
            case .insufficientFeatures: text = "insufficientFeatures"
            case .relocalizing: text = "relocalizing"
            case .initializing: text = "initializing"
            @unknown default: text = "limited"
            }
            updateTracking(.limited(text))
        case .normal: updateTracking(.normal)
        @unknown default: updateTracking(.notAvailable)
        }
    }

    public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard session === arView?.session, phase == .running else { return }
        if anchors.contains(where: { $0 is ARPlaneAnchor }) { hasDetectedPlane = true }
    }

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard session === arView?.session, phase == .running, ownsCamera else { return }
        let detected = frame.anchors.contains { $0 is ARPlaneAnchor }
        if hasDetectedPlane != detected { hasDetectedPlane = detected }
        updateTarget()
        updateLabels()
    }

    public func sessionWasInterrupted(_ session: ARSession) {
        guard session === arView?.session, phase == .running else { return }
        wasRunningBeforeInterruption = true
        cancelStart()
        session.pause()
        releaseCamera()
        target = .unavailable
        tracking = .notAvailable
        phase = .paused
    }

    public func sessionInterruptionEnded(_ session: ARSession) {
        guard session === arView?.session, wasRunningBeforeInterruption else { return }
        if sceneActive, access.active() { resume() }
        else { resumeWhenActive = true }
    }

    public func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        session === arView?.session && !samples.isEmpty && (phase == .running || phase == .paused)
    }
}
#endif
