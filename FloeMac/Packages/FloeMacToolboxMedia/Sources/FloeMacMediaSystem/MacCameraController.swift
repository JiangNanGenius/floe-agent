import Foundation
import Observation
import AVFoundation
import CoreImage
import FloeMacMediaCore

enum MacCameraLimits {
    /// Digital magnification ceiling; macOS has no device zoom factor.
    static let maximumDigitalZoom: CGFloat = 8
}

/// One-way, thread-safe delivery of live codes from the capture queue to the
/// main-actor controller. Avoids capturing an uninitialized controller in the
/// hardware initializer.
final class MacCodeRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (UInt64, [MacCapturedCode]) -> Void)?

    func set(_ handler: @escaping @Sendable (UInt64, [MacCapturedCode]) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func send(_ token: UInt64, _ codes: [MacCapturedCode]) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(token, codes)
    }
}

/// Frame + metadata sink for one capture session. Delegate callbacks run on the
/// hardware session queue; the latest frame is guarded by a lock.
public final class MacCameraIO: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                                AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CIImage?
    private var activeToken: UInt64?
    private let onCodes: @Sendable (UInt64, [MacCapturedCode]) -> Void

    init(onCodes: @escaping @Sendable (UInt64, [MacCapturedCode]) -> Void) {
        self.onCodes = onCodes
        super.init()
    }

    func begin(token: UInt64) {
        lock.lock()
        activeToken = token
        frame = nil
        lock.unlock()
    }

    func end() {
        lock.lock()
        activeToken = nil
        frame = nil
        lock.unlock()
    }

    func takeFrame() -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        lock.lock()
        if activeToken != nil { frame = image }
        lock.unlock()
    }

    public func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let codes: [MacCapturedCode] = metadataObjects.compactMap { object in
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  let payload = readable.stringValue, !payload.isEmpty,
                  payload.utf8.count <= 8_192 else { return nil }
            return MacCapturedCode(payload: payload, symbology: readable.type.rawValue)
        }
        guard !codes.isEmpty else { return }
        let token = lock.withLock { activeToken }
        guard let token else { return }
        onCodes(token, Array(codes.prefix(8)))
    }
}

/// Submitted delegates belong to the process until the system's final capture
/// callback. A bounded table avoids unbounded growth if callbacks never arrive.
final class MacPhotoCaptureLifetime: @unchecked Sendable {
    static let shared = MacPhotoCaptureLifetime(maximum: 8)
    private let lock = NSLock()
    private let maximum: Int
    private var active: [ObjectIdentifier: MacPhotoCaptureBroker] = [:]

    init(maximum: Int) { self.maximum = maximum }
    var count: Int { lock.withLock { active.count } }
    func retain(_ broker: MacPhotoCaptureBroker) -> Bool {
        lock.withLock {
            guard active.count < maximum else { return false }
            active[ObjectIdentifier(broker)] = broker
            return true
        }
    }
    func release(_ broker: MacPhotoCaptureBroker) {
        _ = lock.withLock { active.removeValue(forKey: ObjectIdentifier(broker)) }
    }
}

/// User completion and the system delegate lifetime are independent: a
/// cancelled or processed request remains retained until the final callback.
public final class MacPhotoCaptureBroker: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let lifetime: MacPhotoCaptureLifetime
    private var continuation: CheckedContinuation<Data, Error>?
    private var cancelled = false
    private var submissionClaimed = false
    private var terminal = false
    private var processingResult: Result<Data, Error>?

    init(lifetime: MacPhotoCaptureLifetime = .shared) {
        self.lifetime = lifetime
        super.init()
    }

    func capture(submit: @escaping @Sendable (MacPhotoCaptureBroker) -> Void) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let accepted = lock.withLock {
                guard !cancelled else { return false }
                self.continuation = continuation
                return true
            }
            guard accepted else {
                continuation.resume(throwing: MacMediaFailure.captureFailed("cancelled"))
                return
            }
            submit(self)
        }
    }

    /// Called on the device queue. Do not hold the state lock while entering
    /// AVFoundation: cancel must remain prompt even if submission blocks.
    func submitIfPending(_ submit: () -> Void) {
        let claimed = lock.withLock {
            guard !cancelled, continuation != nil, !submissionClaimed else { return false }
            submissionClaimed = true
            return true
        }
        guard claimed else { return }
        guard lifetime.retain(self) else {
            resolveUnsubmitted(.failure(MacMediaFailure.captureFailed("photo-capacity")))
            return
        }
        guard lock.withLock({ !cancelled && continuation != nil }) else {
            lifetime.release(self)
            return
        }
        submit()
    }

    /// Resumes a pending capture with a stable failure; used when the window
    /// closes before the camera answers.
    func cancel() {
        lock.lock()
        cancelled = true
        processingResult = nil
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: MacMediaFailure.captureFailed("cancelled"))
    }

    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            recordProcessing(.failure(MacMediaFailure.captureFailed(String(String(describing: error).prefix(160)))))
            return
        }
        guard let data = photo.fileDataRepresentation(), !data.isEmpty else {
            recordProcessing(.failure(MacMediaFailure.captureFailed("empty-photo")))
            return
        }
        recordProcessing(.success(data))
    }

    public func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        finishCapture(error: error)
    }

    /// The terminal callback also resolves requests that never produced a
    /// processing callback. Releasing the delegate happens only here.
    func finishCapture(error: Error?) {
        let completed: (CheckedContinuation<Data, Error>?, Result<Data, Error>) = lock.withLock {
            guard !terminal else { return (nil, .failure(MacMediaFailure.captureFailed("cancelled"))) }
            terminal = true
            let result: Result<Data, Error>
            if let error {
                result = .failure(MacMediaFailure.captureFailed(String(String(describing: error).prefix(160))))
            } else {
                result = processingResult ?? .failure(MacMediaFailure.captureFailed("empty-photo"))
            }
            processingResult = nil
            let value = continuation
            continuation = nil
            return (value, result)
        }
        completed.0?.resume(with: completed.1)
        lifetime.release(self)
    }

    func recordProcessing(_ result: Result<Data, Error>) {
        lock.withLock {
            guard !cancelled, !terminal else { return }
            if case .none = processingResult { processingResult = result }
        }
    }

    private func resolveUnsubmitted(_ result: Result<Data, Error>) {
        let continuation = lock.withLock {
            terminal = true
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.resume(with: result)
    }
}

/// AVFoundation state for one camera lease. Deliberately outside the observable
/// controller: all session/device access is serialized on `queue`, and the
/// observable class only keeps UI state. This avoids mixing actor-isolated
/// observation with non-Sendable AVFoundation objects.
protocol MacCameraHardwareControlling: Sendable {
    var session: AVCaptureSession { get }
    /// Read after the serialized stop operation returns.
    var captureIsRunning: Bool { get }
    var queue: DispatchQueue { get }
    func begin(token: UInt64)
    func end()
    func startOnQueue(token: UInt64) -> Result<MacCameraHardware.Capabilities, MacMediaFailure>
    func stopAndWait() async
    func latestFrame() -> CIImage?
    func setTorch(on: Bool) -> Bool
    func setFocus(devicePoint: CGPoint)
    func capturePage(token: UInt64) async throws -> Data
    func cancelPendingPhotos()
}

extension MacCameraHardwareControlling {
    var captureIsRunning: Bool { session.isRunning }
}

/// A single lock owns generation admission and the set drained by stop.
final class MacPhotoAdmission: @unchecked Sendable {
    private let stateLock = NSLock()
    private var token: UInt64?
    private var enabled = false
    private var brokers: [MacPhotoCaptureBroker] = []

    func begin(token: UInt64) { stateLock.withLock { self.token = token } }
    func enable() { stateLock.withLock { enabled = true } }
    func register(_ broker: MacPhotoCaptureBroker, token: UInt64) -> Bool {
        stateLock.withLock {
            guard self.token == token, enabled else { return false }
            brokers.append(broker)
            return true
        }
    }
    func contains(_ broker: MacPhotoCaptureBroker, token: UInt64) -> Bool {
        stateLock.withLock { self.token == token && brokers.contains { $0 === broker } }
    }
    func remove(_ broker: MacPhotoCaptureBroker) {
        stateLock.withLock { brokers.removeAll { $0 === broker } }
    }
    func end() {
        let pending = stateLock.withLock {
            token = nil
            let pending = brokers
            brokers.removeAll()
            return pending
        }
        for broker in pending { broker.cancel() }
    }
    func cancelPending() {
        let pending = stateLock.withLock {
            let pending = brokers
            brokers.removeAll()
            return pending
        }
        for broker in pending { broker.cancel() }
    }
}

/// Short critical sections fence stale queued work without holding a lock
/// across the synchronous system start call. Stop never waits for that call.
/// The final check and the underlying API call cannot be made atomic.
final class MacCameraStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeToken: UInt64?

    func begin(token: UInt64) { lock.withLock { activeToken = token } }
    func end() { lock.withLock { activeToken = nil } }
    func isActive(token: UInt64) -> Bool { lock.withLock { activeToken == token } }
    func startIfActive(token: UInt64, _ start: () -> Void) -> Bool {
        guard isActive(token: token) else { return false }
        start()
        return true
    }
}

public final class MacCameraHardware: MacCameraHardwareControlling, @unchecked Sendable {
    public let session = AVCaptureSession()
    let queue = DispatchQueue(label: "org.floe.mac.toolbox.camera")

    private let videoOutput = AVCaptureVideoDataOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let io: MacCameraIO
    private let relay: MacCodeRelay
    private let photoAdmission = MacPhotoAdmission()
    private let startGate = MacCameraStartGate()
    private var configured = false
    private var device: AVCaptureDevice?

    struct Capabilities: Sendable {
        let name: String
        let maximumZoom: CGFloat
        let supportsTorch: Bool
        let supportsFocus: Bool
        let supportsQRCode: Bool
    }

    init(relay: MacCodeRelay) {
        self.relay = relay
        io = MacCameraIO(onCodes: { relay.send($0, $1) })
    }

    func begin(token: UInt64) {
        startGate.begin(token: token)
        photoAdmission.begin(token: token)
        io.begin(token: token)
    }
    func end() {
        photoAdmission.end()
        startGate.end()
        io.end()
    }
    func latestFrame() -> CIImage? { io.takeFrame() }

    /// Must run on `queue`.
    func startOnQueue(token: UInt64) -> Result<Capabilities, MacMediaFailure> {
        do {
            guard startGate.isActive(token: token) else {
                return .failure(.captureFailed("cancelled"))
            }
            try configureIfNeeded()
            // stop() may have won while AVFoundation was configuring the
            // session. Do not start the camera after that stop intent.
            guard startGate.startIfActive(token: token, {
                if !session.isRunning { session.startRunning() }
            }) else {
                return .failure(.captureFailed("cancelled"))
            }
            guard startGate.isActive(token: token) else {
                return .failure(.captureFailed("cancelled"))
            }
            guard session.isRunning else { return .failure(.engine("session-not-running")) }
            guard let device else { return .failure(.noDevice) }
            return .success(Capabilities(
                name: device.localizedName,
                maximumZoom: MacCameraLimits.maximumDigitalZoom,
                supportsTorch: device.hasTorch && device.isTorchModeSupported(.on),
                supportsFocus: device.isFocusPointOfInterestSupported,
                supportsQRCode: session.outputs.contains(where: { $0 === metadataOutput }) &&
                    metadataOutput.metadataObjectTypes.contains(.qr)
            ))
        } catch let failure as MacMediaFailure {
            return .failure(failure)
        } catch {
            return .failure(.engine(String(String(describing: error).prefix(200))))
        }
    }

    /// Must run on `queue`.
    func configureIfNeeded() throws {
        guard !configured else { return }
        guard let camera = AVCaptureDevice.default(for: .video) else { throw MacMediaFailure.noDevice }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: camera)
        } catch {
            throw MacMediaFailure.engine("camera-input")
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { throw MacMediaFailure.engine("camera-input") }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(io, queue: queue)
        guard session.canAddOutput(videoOutput) else {
            // Leave the session as it was so a later retry can configure it.
            session.removeInput(input)
            throw MacMediaFailure.engine("video-output")
        }
        session.addOutput(videoOutput)

        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(io, queue: queue)
            let wanted: [AVMetadataObject.ObjectType] = [
                .qr, .ean8, .ean13, .upce, .code39, .code93, .code128,
                .pdf417, .aztec, .dataMatrix, .itf14, .interleaved2of5,
            ]
            metadataOutput.metadataObjectTypes = wanted.filter {
                metadataOutput.availableMetadataObjectTypes.contains($0)
            }
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoAdmission.enable()
        }
        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        device = camera
        configured = true
    }

    /// The lease must remain held until the hardware queue has actually
    /// stopped the capture session. A strong capture keeps teardown alive even
    /// if its window has already disappeared.
    func stopAndWait() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                applyTorchOff()
                if session.isRunning { session.stopRunning() }
                continuation.resume()
            }
        }
    }

    /// Must run on `queue`.
    func setTorch(on: Bool) -> Bool {
        guard let device, device.hasTorch else { return false }
        do {
            try device.lockForConfiguration()
            device.torchMode = (on && device.isTorchModeSupported(.on)) ? .on : .off
            device.unlockForConfiguration()
            return device.torchMode == .on
        } catch {
            return false
        }
    }

    /// Must run on `queue`.
    func applyTorchOff() {
        guard let device, device.hasTorch, device.torchMode != .off else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.torchMode = .off
        } catch {
            // Do not mutate or unlock an unheld configuration lock.
        }
    }

    /// Must run on `queue`.
    func setFocus(devicePoint: CGPoint) {
        guard let device, device.isFocusPointOfInterestSupported else { return }
        do {
            try device.lockForConfiguration()
            device.focusPointOfInterest = devicePoint
            if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
                if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
            }
            device.unlockForConfiguration()
        } catch {
            return
        }
    }

    func capturePage(token: UInt64) async throws -> Data {
        let broker = MacPhotoCaptureBroker()
        guard photoAdmission.register(broker, token: token) else {
            throw MacMediaFailure.captureFailed("not-running")
        }
        defer { photoAdmission.remove(broker) }
        return try await broker.capture { [self] broker in
            queue.async { [self] in
                guard photoAdmission.contains(broker, token: token) else { broker.cancel(); return }
                broker.submitIfPending {
                    photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: broker)
                }
            }
        }
    }

    func cancelPendingPhotos() {
        photoAdmission.cancelPending()
    }
}

/// Native macOS camera owner for the magnifier and scanner. One window holds
/// the device lease; every failure (permission, no device, another client,
/// interruption, runtime error) maps to an explicit surface instead of a
/// fabricated preview. Capture only starts from an explicit user action.
@MainActor
@Observable
public final class MacCameraController {
    public private(set) var authorization: MacMediaAuthorization
    public private(set) var running = false
    public private(set) var issue: MacCameraIssue = .none
    public private(set) var frozenImage: CGImage?
    public private(set) var torchOn = false
    public private(set) var supportsTorch = false
    public private(set) var supportsFocus = false
    /// Whether this running capture session actually configured QR metadata.
    public private(set) var supportsQRCode = false
    public private(set) var zoom: CGFloat = 1
    public private(set) var maximumZoom: CGFloat = MacCameraLimits.maximumDigitalZoom
    public private(set) var deviceName: String?
    public private(set) var deviceAvailable: Bool
    public private(set) var lease: MacDeviceLease?
    /// A start attempt lost the single lease to another window.
    public private(set) var leaseConflict = false
    /// A start attempt completed authorization but found no camera.
    public private(set) var deviceProbeFailed = false
    public private(set) var awaitingPermissionPrompt = false
    public private(set) var lastFailure: MacMediaFailure?
    /// Live barcode/QR codes; the scanner decides when to consume them.
    public var onLiveCodes: (([MacCapturedCode]) -> Void)?

    @ObservationIgnored private let authorizer: any MacMediaAuthorizing
    @ObservationIgnored private let broker: MacDeviceLeaseBroker
    @ObservationIgnored private let ownerID: UUID
    @ObservationIgnored private let hardware: any MacCameraHardwareControlling
    @ObservationIgnored private let deviceProbe: @Sendable () -> Bool
    @ObservationIgnored private var captureAvailability: @MainActor () -> Bool
    @ObservationIgnored private var permanentlyClosed = false
    @ObservationIgnored private var registryAdmission: (@MainActor (MacCameraController) -> Bool)?
    @ObservationIgnored private var registryInactive: (@MainActor (MacCameraController) -> Void)?
    @ObservationIgnored private var registryRetirement: (@MainActor (MacCameraController) -> Void)?
    @ObservationIgnored private var runToken: UInt64 = 0
    @ObservationIgnored private var startingToken: UInt64?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    public convenience init(
        authorizer: any MacMediaAuthorizing,
        broker: MacDeviceLeaseBroker,
        ownerID: UUID = UUID(),
        captureAvailability: @escaping @MainActor () -> Bool = { false }
    ) {
        let relay = MacCodeRelay()
        self.init(authorizer: authorizer, broker: broker, ownerID: ownerID,
                  hardware: MacCameraHardware(relay: relay), relay: relay,
                  deviceProbe: { AVCaptureDevice.default(for: .video) != nil },
                  captureAvailability: captureAvailability)
    }

    /// Internal seam for deterministic ordering tests; the app always uses
    /// the public initializer and the real AVFoundation hardware owner.
    init(authorizer: any MacMediaAuthorizing, broker: MacDeviceLeaseBroker,
         ownerID: UUID = UUID(), hardware: any MacCameraHardwareControlling,
         relay: MacCodeRelay, deviceProbe: @escaping @Sendable () -> Bool,
         captureAvailability: @escaping @MainActor () -> Bool = { true }) {
        self.authorizer = authorizer
        self.broker = broker
        self.ownerID = ownerID
        self.deviceProbe = deviceProbe
        self.captureAvailability = captureAvailability
        self.authorization = authorizer.authorization(for: .camera)
        self.deviceAvailable = deviceProbe()
        self.hardware = hardware
        relay.set { [weak self] token, codes in
            Task { @MainActor [weak self] in
                guard let self, self.runToken == token, self.running, self.lease != nil else { return }
                self.onLiveCodes?(codes)
            }
        }
    }

    /// Installed by the app-owned factory before the controller escapes.
    func attachRegistry(_ registry: MacCameraRegistry) {
        registryAdmission = { [weak registry] camera in registry?.admit(camera) ?? false }
        registryInactive = { [weak registry] camera in registry?.confirmedInactive(camera) }
        registryRetirement = { [weak registry] camera in registry?.retire(camera) }
    }

    public var isWindowClosed: Bool { permanentlyClosed }

    /// The capture session for the preview layer. Main-actor access only.
    public var session: AVCaptureSession { hardware.session }

    /// Surface for the current state; views observe this instead of inventing
    /// their own precedence.
    public var surface: MacCameraSurface {
        MacCameraSurfaceResolver.surface(for: MacCameraInputs(
            holdsLease: lease != nil,
            leaseConflict: leaseConflict,
            authorization: authorization,
            deviceAvailable: deviceAvailable,
            deviceProbeFailed: deviceProbeFailed,
            running: running,
            issue: issue,
            frozen: frozenImage != nil
        ))
    }

    public var hasLease: Bool { lease != nil }

    /// The owning surface supplies its app/activity and window visibility
    /// state. Denying access also fences pending authorization/start work.
    public func setCaptureAvailability(_ predicate: @escaping @MainActor () -> Bool) {
        guard !permanentlyClosed else {
            captureAvailability = { false }
            return
        }
        captureAvailability = predicate
        if !predicate() { stop() }
    }

    /// Terminal per-window fence. Queued starts or a stale view cannot
    /// reactivate this controller, even when a new window is already open.
    public func closeForWindow() {
        guard !permanentlyClosed else { return }
        permanentlyClosed = true
        captureAvailability = { false }
        stop()
        registryRetirement?(self)
    }

    /// Completes when this owner's already-requested hardware stop returns.
    /// Synchronous hardware APIs may delay this indefinitely; the caller must
    /// not treat a cancellation request as proof that capture has stopped.
    public func waitUntilStopped() async -> Bool {
        if let stopping = stopTask { await stopping.value }
        // Retry a completed but unconfirmed stop. The retained lease prevents
        // another owner from acquiring the camera while this retry drains.
        if lease != nil || hardware.captureIsRunning {
            stop()
            if let stopping = stopTask { await stopping.value }
        }
        return permanentlyClosed && lease == nil && !running && !hardware.captureIsRunning
    }

    /// Explicit user action. Permission is requested here only when
    /// undetermined; no preview is created before the lease is held.
    @discardableResult
    public func start() async -> Bool {
        guard !permanentlyClosed, !Task.isCancelled, captureAvailability(), lease == nil, startingToken == nil, stopTask == nil else { return false }
        guard registryAdmission?(self) ?? true else { return false }
        runToken &+= 1
        let token = runToken
        startingToken = token
        defer {
            if startingToken == token { startingToken = nil }
            if startingToken == nil, lease == nil, stopTask == nil, !hardware.captureIsRunning {
                registryInactive?(self)
            }
        }
        lastFailure = nil
        issue = .none
        leaseConflict = false
        deviceProbeFailed = false
        authorization = authorizer.authorization(for: .camera)
        deviceAvailable = deviceProbe()

        if authorization.canRequest {
            awaitingPermissionPrompt = true
            let result = await authorizer.requestAuthorization(for: .camera)
            guard token == runToken else { return false }
            awaitingPermissionPrompt = false
            guard !Task.isCancelled, captureAvailability() else { return false }
            authorization = result
        }
        guard authorization.isAuthorized else {
            lastFailure = .notAuthorized
            return false
        }
        guard !Task.isCancelled, captureAvailability() else { return false }
        deviceAvailable = deviceProbe()
        guard deviceAvailable else {
            lastFailure = .noDevice
            deviceProbeFailed = true
            return false
        }
        guard let acquired = broker.acquire(.camera, owner: ownerID) else {
            issue = .inUseByAnotherApplication
            leaseConflict = true
            lastFailure = .deviceBusy
            return false
        }
        guard token == runToken, !Task.isCancelled, captureAvailability() else {
            broker.release(acquired)
            return false
        }
        lease = acquired
        hardware.begin(token: token)

        let hardware = self.hardware
        let queue = hardware.queue
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<MacCameraHardware.Capabilities, MacMediaFailure>, Never>) in
            queue.async {
                continuation.resume(returning: hardware.startOnQueue(token: token))
            }
        }

        // stop() owns teardown once this generation is invalidated. A late
        // result must never stop or release a newer generation's resources.
        guard token == runToken else { return false }
        guard !Task.isCancelled, captureAvailability() else {
            stop()
            return false
        }
        switch result {
        case .success(let capabilities):
            running = true
            issue = .none
            deviceName = capabilities.name
            maximumZoom = capabilities.maximumZoom
            supportsTorch = capabilities.supportsTorch
            supportsFocus = capabilities.supportsFocus
            supportsQRCode = capabilities.supportsQRCode
            observeInterruptions(token: token)
            return true
        case .failure(let failure):
            stop()
            lastFailure = failure
            leaseConflict = failure == .deviceBusy
            deviceProbeFailed = failure == .noDevice
            issue = failure == .deviceBusy ? .inUseByAnotherApplication : .failed(failure.diagnosticCode)
            return false
        }
    }

    /// Stops capture and returns the lease. Safe on window close, app
    /// background, tool switch and Start failure; stale work is fenced by the
    /// run token.
    public func stop() {
        let wasCapturing = lease != nil || running || startingToken != nil || hardware.captureIsRunning
        runToken &+= 1
        startingToken = nil
        awaitingPermissionPrompt = false
        removeObservers()
        hardware.end()
        hardware.cancelPendingPhotos()
        running = false
        supportsQRCode = false
        if wasCapturing {
            issue = .none
            leaseConflict = false
            deviceProbeFailed = false
            lastFailure = nil
        }
        frozenImage = nil
        torchOn = false
        zoom = 1
        guard stopTask == nil, wasCapturing else { return }
        let heldLease = lease
        stopTask = Task { @MainActor [self] in
            await hardware.stopAndWait()
            // The lease remains ours unless the hardware reports it stopped.
            // A subsequent waitUntilStopped() can safely retry on the same owner.
            if !hardware.captureIsRunning, let heldLease {
                broker.release(heldLease)
                if lease == heldLease { lease = nil }
            }
            stopTask = nil
            if lease == nil, !hardware.captureIsRunning {
                registryInactive?(self)
            } else {
                // Do not call an unconfirmed stop "starting" forever. Keep
                // the lease, expose Retry, and let this owner stop it again.
                issue = .failed("camera-stop-unconfirmed")
                lastFailure = .engine("camera-stop-unconfirmed")
            }
        }
    }

    public func restart() async -> Bool {
        guard !permanentlyClosed else { return false }
        stop()
        var token = runToken
        if let stopTask { await stopTask.value }
        guard token == runToken, !permanentlyClosed, !Task.isCancelled, captureAvailability() else { return false }
        // If the previous stop completed without hardware confirmation, only
        // this same controller may retry it; the broker lease remains held.
        if lease != nil || hardware.captureIsRunning {
            stop()
            token = runToken
            if let stopTask { await stopTask.value }
            guard token == runToken, !permanentlyClosed, !Task.isCancelled,
                  captureAvailability(), lease == nil, !hardware.captureIsRunning else { return false }
        }
        return await start()
    }

    // MARK: - Magnifier controls

    /// Renders the most recent frame for the freeze control. The frame is copied
    /// under a lock; rendering happens off the main actor and is bounded.
    @discardableResult
    public func freeze(maximumDimension: CGFloat = 4_096) async -> CGImage? {
        guard lease != nil, running, let snapshot = hardware.latestFrame() else { return nil }
        let token = runToken
        let cropFactor = max(1, zoom)
        let boxed = SendableCIImage(image: snapshot)
        let image: CGImage? = await Task.detached(priority: .userInitiated) {
            let snapshot = boxed.image
            let extent = snapshot.extent
            guard extent.width > 0, extent.height > 0 else { return nil }
            let cropWidth = extent.width / cropFactor
            let cropHeight = extent.height / cropFactor
            let cropRect = CGRect(x: extent.midX - cropWidth / 2,
                                  y: extent.midY - cropHeight / 2,
                                  width: cropWidth, height: cropHeight)
            let cropped = snapshot.cropped(to: cropRect)
            let scale = min(1, maximumDimension / max(cropWidth, cropHeight))
            let transformed = scale < 1
                ? cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                : cropped
            let context = CIContext(options: [.useSoftwareRenderer: false])
            return context.createCGImage(transformed, from: transformed.extent)
        }.value
        guard token == runToken, lease != nil, running else { return nil }
        frozenImage = image
        return image
    }

    public func unfreeze() {
        frozenImage = nil
    }

    /// Digital magnification. macOS exposes no `videoZoomFactor` device
    /// control, so zoom is applied to the preview layer and to the cropped
    /// freeze frame; it is never presented as optical/hardware zoom.
    public func setZoom(_ factor: CGFloat) {
        guard lease != nil, factor.isFinite else { return }
        zoom = max(1, min(factor, maximumZoom))
    }

    /// Torch is optional on Macs; unsupported hardware keeps the control
    /// disabled and never fakes a light.
    public func setTorch(on: Bool) {
        guard lease != nil, supportsTorch else { return }
        let token = runToken
        let hardware = self.hardware
        hardware.queue.async { [weak self] in
            let applied = hardware.setTorch(on: on)
            Task { @MainActor [weak self] in
                guard let self, self.runToken == token, self.lease != nil else { return }
                self.torchOn = applied
            }
        }
    }

    /// Tap-to-focus in device coordinates (already converted by the preview
    /// layer). Cameras without focus support ignore the call.
    public func focus(devicePoint: CGPoint) {
        guard lease != nil, supportsFocus else { return }
        let hardware = self.hardware
        hardware.queue.async {
            hardware.setFocus(devicePoint: devicePoint)
        }
    }

    // MARK: - Scanner page capture

    /// Captures one still photo as encoded bytes for the shared bounded decoder.
    public func capturePage() async throws -> Data {
        guard lease != nil, running else { throw MacMediaFailure.captureFailed("not-running") }
        let token = runToken
        let result = try await hardware.capturePage(token: token)
        guard token == runToken, lease != nil, running else {
            throw MacMediaFailure.captureFailed("cancelled")
        }
        return result
    }

    // MARK: - Interruptions

    private func observeInterruptions(token: UInt64) {
        removeObservers()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: hardware.session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleInterruption(token: token)
            }
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: hardware.session,
            queue: .main
        ) { [weak self] note in
            let code = (note.userInfo?[AVCaptureSessionErrorKey] as? AVError)?.code.rawValue
            Task { @MainActor [weak self] in
                self?.handleRuntimeError(code: code, token: token)
            }
        })
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
        observers = []
    }

    private func handleInterruption(token: UInt64) {
        guard token == runToken, lease != nil else { return }
        // macOS does not expose an interruption reason; present the generic
        // interrupted state and require an explicit Resume.
        stop()
        issue = .interrupted
    }

    private func handleRuntimeError(code: Int?, token: UInt64) {
        guard token == runToken, lease != nil else { return }
        stop()
        let detail = code.map { String($0) } ?? "runtime"
        issue = .failed(detail)
        lastFailure = .engine("camera-runtime-\(detail)")
    }
}

/// CIImage is a CoreImage reference type without a Sendable conformance the
/// compiler can verify; the value is treated as immutable after capture.
private struct SendableCIImage: @unchecked Sendable {
    let image: CIImage
}
