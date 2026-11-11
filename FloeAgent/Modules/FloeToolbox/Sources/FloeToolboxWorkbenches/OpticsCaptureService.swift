#if os(iOS)
import AVFoundation
import CoreImage
import UIKit
import FloeToolboxUtilities

/// Opaque camera lease. Releasing a stale lease never disturbs a newer one.
public struct OpticsCaptureLease: Sendable, Hashable {
    public let identifier: UUID
    public init(identifier: UUID = UUID()) { self.identifier = identifier }
}

public enum OpticsCaptureKind: String, Sendable, Hashable {
    case magnifier, scanner, document
}

public enum OpticsCaptureAuthorization: Sendable, Equatable {
    case unknown, authorized, denied, unavailable
}

public enum OpticsCaptureIssue: Sendable, Equatable {
    case none, cameraBusy, interrupted, sessionFailed(String)
}

/// Configuration-time failures, kept distinct from AVError runtime codes
/// (this SDK has no AVError "device not available" code to reuse).
private enum OpticsCaptureConfigurationError: Error {
    case noCamera, cannotAddInput, cannotAddVideoOutput, cannotAddMetadataOutput
}

/// One machine-readable code delivered by the live camera. Payloads are
/// already bounded; the scanner view deduplicates and caps retention.
public struct OpticsCapturedCode: Sendable, Equatable {
    public let payload: String
    public let symbology: String
}

/// Feature-owned camera: the magnifier and scanner windows lease this
/// service so exactly one window holds the camera at a time, and torch,
/// zoom, focus, and interruption handling live in exactly one place. The
/// service never fights another owner for the camera — a busy device
/// surfaces as an explicit state the view presents.
///
/// Session mutations run on a dedicated queue; published state is main-actor.
/// The class is unchecked-Sendable because every mutable property is only
/// touched on one of those two serial contexts.
@MainActor
public final class OpticsCaptureService: NSObject, ObservableObject {
    public static let shared = OpticsCaptureService()

    @Published public private(set) var authorization: OpticsCaptureAuthorization = .unknown
    @Published public private(set) var activeKind: OpticsCaptureKind?
    @Published public private(set) var issue: OpticsCaptureIssue = .none
    @Published public private(set) var running = false
    @Published public private(set) var torchOn = false
    @Published public private(set) var zoomFactor: CGFloat = 1
    @Published public private(set) var maximumZoomFactor: CGFloat = 1
    @Published public private(set) var torchSupported = false
    @Published public private(set) var focusTapSupported = false
    @Published public private(set) var latestCodes: [OpticsCapturedCode] = []

    /// Exposed for AVCaptureVideoPreviewLayer hosting. AVCaptureSession is
    /// thread-safe by design; all configuration still happens on
    /// sessionQueue. unsafe-nonisolated because the capture APIs predate
    /// Sendable conformance.
    public nonisolated(unsafe) let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "floe.optics.session")
    /// Touched only on sessionQueue; unchecked so nonisolated session
    /// closures can manage hardware without main-actor hops.
    private nonisolated(unsafe) var device: AVCaptureDevice?
    private nonisolated(unsafe) var configured = false
    private nonisolated(unsafe) var sessionLeaseID: UUID?
    private var activeLease: OpticsCaptureLease?
    private var permissionGeneration = UUID()
    /// Latest camera frame as a cheap CIImage wrapper; replaced every frame,
    /// rendered only when the user freezes. Touched on sessionQueue only.
    private nonisolated(unsafe) var lastCIImage: CIImage?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                               object: session, queue: .main) { [weak self] note in
            guard let self else { return }
            let reason = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? AVCaptureSession.InterruptionReason
            Task { @MainActor in
                guard self.activeLease != nil else { return }
                switch reason {
                case .videoDeviceInUseByAnotherClient:
                    self.issue = .cameraBusy
                case .videoDeviceNotAvailableInBackground,
                     .videoDeviceNotAvailableWithMultipleForegroundApps,
                     .videoDeviceNotAvailableDueToSystemPressure,
                     .sensitiveContentMitigationActivated:
                    self.issue = .interrupted
                default:
                    self.issue = .interrupted
                }
            }
        }
        NotificationCenter.default.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                               object: session, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.activeLease != nil else { return }
                if self.issue == .interrupted || self.issue == .cameraBusy {
                    self.issue = .none
                }
            }
        }
    }

    // MARK: - Lease

    /// Returns nil while another window holds the camera.
    public func acquire(_ kind: OpticsCaptureKind) -> OpticsCaptureLease? {
        guard activeLease == nil else { return nil }
        let lease = OpticsCaptureLease()
        activeLease = lease
        activeKind = kind
        issue = .none
        sessionQueue.async { [weak self] in self?.sessionLeaseID = lease.identifier }
        return lease
    }

    public func owns(_ lease: OpticsCaptureLease?) -> Bool {
        guard let lease else { return false }
        return activeLease == lease
    }

    /// Reserve the same camera boundary for VisionKit, waiting until this
    /// feature's preceding capture stream and torch have actually stopped.
    public func prepareDocumentCapture(lease: OpticsCaptureLease) async -> Bool {
        guard owns(lease), activeKind == .document else { return false }
        let ready = await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self, self.sessionLeaseID == lease.identifier else {
                    continuation.resume(returning: false)
                    return
                }
                self.torchOffInternal()
                if self.session.isRunning { self.session.stopRunning() }
                self.lastCIImage = nil
                continuation.resume(returning: true)
            }
        }
        return ready && owns(lease) && activeKind == .document
    }

    /// Stops the camera, turns the torch off, and drops buffered frames.
    /// A stale lease is a no-op so a dismissed sheet can never kill the
    /// camera for the window that owns it now.
    public func release(_ lease: OpticsCaptureLease) {
        guard activeLease == lease else { return }
        activeLease = nil
        activeKind = nil
        permissionGeneration = UUID()
        latestCodes = []
        running = false
        torchOn = false
        issue = .none
        sessionQueue.async { [weak self] in
            guard let self, self.sessionLeaseID == lease.identifier else { return }
            self.torchOffInternal()
            if self.session.isRunning { self.session.stopRunning() }
            self.lastCIImage = nil
            self.sessionLeaseID = nil
        }
    }

    // MARK: - Authorization & start

    /// Explicit start gate: authorization first, then session start. A late
    /// permission grant is fenced by a generation token so it can never open
    /// the camera after release() or while the scene is inactive.
    public func requestStart(lease: OpticsCaptureLease) {
        guard activeLease == lease, activeKind != .document else { return }
        refreshAuthorization()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginStart(lease: lease)
        case .notDetermined:
            let token = UUID()
            permissionGeneration = token
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self, self.permissionGeneration == token else { return }
                    self.permissionGeneration = UUID()
                    guard granted else { self.authorization = .denied; return }
                    guard self.activeLease == lease else { return }
                    self.authorization = .authorized
                    self.beginStart(lease: lease)
                }
            }
        case .denied, .restricted:
            authorization = .denied
        @unknown default:
            authorization = .denied
        }
    }

    private func refreshAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorization = .authorized
        case .notDetermined: authorization = .unknown
        case .denied, .restricted: authorization = .denied
        @unknown default: authorization = .denied
        }
    }

    private func beginStart(lease: OpticsCaptureLease) {
        guard owns(lease), activeKind != .document else { return }
        sessionQueue.async { [weak self] in
            guard let self, self.sessionLeaseID == lease.identifier else { return }
            do {
                if !self.configured {
                    try self.configureSession(lease: lease)
                    self.configured = true
                }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
            } catch OpticsCaptureConfigurationError.noCamera {
                Task { @MainActor in
                    guard self.owns(lease) else { return }
                    self.authorization = .unavailable
                }
                return
            } catch let error as AVError {
                Task { @MainActor in
                    guard self.owns(lease) else { return }
                    self.issue = Self.mapIssue(error)
                }
                return
            } catch {
                Task { @MainActor in
                    guard self.owns(lease) else { return }
                    self.issue = .sessionFailed(error.localizedDescription)
                }
                return
            }
            Task { @MainActor in
                guard self.owns(lease) else { return }
                self.running = true
                self.issue = .none
            }
        }
    }

    private nonisolated static func mapIssue(_ error: AVError) -> OpticsCaptureIssue {
        switch error.code {
        case .deviceInUseByAnotherApplication:
            // The system camera or another app owns the device; present a
            // busy state instead of competing with that owner.
            return .cameraBusy
        case .mediaServicesWereReset:
            return .interrupted
        default:
            return .sessionFailed(error.localizedDescription)
        }
    }

    // MARK: - Session configuration

    private nonisolated func configureSession(lease: OpticsCaptureLease) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw OpticsCaptureConfigurationError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw OpticsCaptureConfigurationError.cannotAddInput }
        session.addInput(input)

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(videoOutput) else { throw OpticsCaptureConfigurationError.cannotAddVideoOutput }
        session.addOutput(videoOutput)

        let metadataOutput = AVCaptureMetadataOutput()
        metadataOutput.setMetadataObjectsDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(metadataOutput) else { throw OpticsCaptureConfigurationError.cannotAddMetadataOutput }
        session.addOutput(metadataOutput)
        let wanted: [AVMetadataObject.ObjectType] = [
            .qr, .ean8, .ean13, .upce, .code39, .code93, .code128,
            .pdf417, .aztec, .dataMatrix, .itf14, .interleaved2of5,
        ]
        metadataOutput.metadataObjectTypes = wanted.filter {
            metadataOutput.availableMetadataObjectTypes.contains($0)
        }

        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        device = camera
        let maximum = min(camera.activeFormat.videoMaxZoomFactor, camera.maxAvailableVideoZoomFactor)
        Task { @MainActor in
            guard self.owns(lease) else { return }
            self.maximumZoomFactor = max(1, maximum)
            self.torchSupported = camera.hasTorch && camera.isTorchModeSupported(.on)
            self.focusTapSupported = camera.isFocusPointOfInterestSupported
        }
    }

    // MARK: - Hardware controls

    /// User-driven torch only; never auto-enabled. Unsupported devices ignore
    /// the call so the UI can keep the control disabled.
    public func setTorch(on: Bool, lease: OpticsCaptureLease) {
        guard owns(lease), activeKind != .document else { return }
        sessionQueue.async { [weak self] in
            guard let self, self.sessionLeaseID == lease.identifier,
                  let device = self.device, device.hasTorch else { return }
            let mode: AVCaptureDevice.TorchMode = (on && device.isTorchModeSupported(.on)) ? .on : .off
            do {
                try device.lockForConfiguration()
                device.torchMode = mode
                device.unlockForConfiguration()
            } catch { return }
            Task { @MainActor in
                guard self.owns(lease) else { return }
                self.torchOn = device.torchMode == .on
            }
        }
    }

    private nonisolated func torchOffInternal() {
        guard let device, device.hasTorch, device.torchMode != .off else { return }
        try? device.lockForConfiguration()
        device.torchMode = .off
        device.unlockForConfiguration()
    }

    /// Hardware zoom: clamped by the active format and the device's own
    /// maximum, so the factor always reflects a real device property.
    public func setZoomFactor(_ factor: CGFloat, lease: OpticsCaptureLease) {
        guard owns(lease), activeKind != .document else { return }
        sessionQueue.async { [weak self] in
            guard let self, self.sessionLeaseID == lease.identifier, let device = self.device else { return }
            let clamped = max(1, min(factor, device.activeFormat.videoMaxZoomFactor, device.maxAvailableVideoZoomFactor))
            guard abs(clamped - device.videoZoomFactor) > 0.01 else { return }
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
            } catch { return }
            Task { @MainActor in
                guard self.owns(lease) else { return }
                self.zoomFactor = clamped
            }
        }
    }

    /// Tap-to-focus in preview-layer coordinates; converted with the live
    /// preview layer so the reticle matches the device point of interest.
    public func focus(atPreviewPoint point: CGPoint, previewLayer: AVCaptureVideoPreviewLayer,
                      lease: OpticsCaptureLease) {
        guard owns(lease), activeKind != .document else { return }
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        sessionQueue.async { [weak self] in
            guard let self, self.sessionLeaseID == lease.identifier, let device = self.device,
                  device.isFocusPointOfInterestSupported else { return }
            do {
                try device.lockForConfiguration()
                device.focusPointOfInterest = devicePoint
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    }
                }
                device.unlockForConfiguration()
            } catch { return }
        }
    }

    /// Renders the most recent camera frame for the freeze feature. The
    /// render happens on the session queue so it can never read a frame
    /// that is being replaced; output is bounded to the requested maximum.
    public func renderLastFrame(lease: OpticsCaptureLease, maximumDimension: CGFloat = 4096) async -> UIImage? {
        guard owns(lease), activeKind != .document else { return nil }
        let image: UIImage? = await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self, self.sessionLeaseID == lease.identifier, let ciImage = self.lastCIImage else {
                    continuation.resume(returning: nil)
                    return
                }
                let extent = ciImage.extent
                let scale = min(1, maximumDimension / max(extent.width, extent.height, 1))
                let transformed = scale < 1
                    ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    : ciImage
                let context = CIContext(options: [.useSoftwareRenderer: false])
                guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: UIImage(cgImage: cgImage))
            }
        }
        return owns(lease) ? image : nil
    }

    func resetCodes() {
        latestCodes = []
    }
}

extension OpticsCaptureService: @unchecked Sendable {}

// Callbacks arrive on sessionQueue (set as the delegate queue); they only
// replace the latest frame / forward codes, and hop to the main actor for
// published state.
extension OpticsCaptureService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated public func captureOutput(_ output: AVCaptureOutput,
                                          didOutput sampleBuffer: CMSampleBuffer,
                                          from connection: AVCaptureConnection) {
        guard sessionLeaseID != nil, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastCIImage = CIImage(cvPixelBuffer: pixelBuffer)
    }
}

extension OpticsCaptureService: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated public func metadataOutput(_ output: AVCaptureMetadataOutput,
                                           didOutput metadataObjects: [AVMetadataObject],
                                           from connection: AVCaptureConnection) {
        guard let leaseID = sessionLeaseID else { return }
        let codes: [OpticsCapturedCode] = metadataObjects.compactMap { object in
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  let payload = readable.stringValue,
                  !payload.isEmpty,
                  payload.utf8.count <= 8192 else { return nil }
            return OpticsCapturedCode(payload: payload, symbology: readable.type.rawValue)
        }
        guard !codes.isEmpty else { return }
        Task { @MainActor in
            guard self.activeLease?.identifier == leaseID, self.activeKind == .scanner else { return }
            self.latestCodes = Array(codes.prefix(8))
        }
    }
}
#endif
