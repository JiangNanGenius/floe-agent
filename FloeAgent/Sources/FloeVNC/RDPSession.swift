// SPDX-License-Identifier: MPL-2.0
#if canImport(FloeRDPNative) && canImport(CoreGraphics) && canImport(ImageIO)
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FloeCore
import FloeRDPNative

/// Service-owned RDP connection. Views subscribe to coalesced notifications;
/// dismissing a view does not dispose of its connection or callback context.
public final class RDPSession: RemoteDesktopSession, @unchecked Sendable {
    private let lock = NSLock()
    private let host: String
    private let port: UInt16
    private let certificateHostname: String
    private let approvedFingerprint: String?
    private var worker: RDPWorker?
    private var state: VNCSessionState = .disconnected
    private var frame: CGImage?
    private var revision: UInt64 = 0
    private var capturedAt = Date.distantPast
    private var visualEvidence: VNCVisualEvidence?
    private var structuredEvidence: VNCStructuredEvidence?
    private var challenge: RDPCertificateTrust.Evaluation?
    private var changeHandler: (@MainActor @Sendable () -> Void)?
    private var notificationPending = false

    public static var runtimeVersion: String { String(cString: floe_rdp_version()) }
    public init(host: String, port: UInt16 = 3389, certificateHostname: String? = nil,
                approvedFingerprint: String? = nil) {
        self.host = host
        self.port = port
        self.certificateHostname = certificateHostname ?? host
        self.approvedFingerprint = approvedFingerprint
    }

    public var isConnected: Bool { lock.withLock { state == .connected } }
    public var currentState: VNCSessionState { lock.withLock { state } }
    public var currentFrameRevision: UInt64 { lock.withLock { revision } }
    public var currentVisualEvidence: VNCVisualEvidence? { lock.withLock { visualEvidence } }
    public var currentStructuredEvidence: VNCStructuredEvidence? { lock.withLock { structuredEvidence } }
    public var currentImage: CGImage? { lock.withLock { frame } }
    public var certificateChallenge: RDPCertificateTrust.Evaluation? { lock.withLock { challenge } }
    public func rememberVisualEvidence(_ evidence: VNCVisualEvidence) { lock.withLock { visualEvidence = evidence } }
    public func rememberStructuredEvidence(_ evidence: VNCStructuredEvidence) { lock.withLock { structuredEvidence = evidence } }

    public func setChangeHandler(_ handler: (@MainActor @Sendable () -> Void)?) {
        lock.withLock { changeHandler = handler }
        notifyChange()
    }
    private func notifyChange() {
        let schedule = lock.withLock {
            guard changeHandler != nil, !notificationPending else { return false }
            notificationPending = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let handler = self.lock.withLock {
                self.notificationPending = false
                return self.changeHandler
            }
            handler?()
        }
    }

    /// A bounded wait does not release a still-running worker. Both failure
    /// and cancellation await shutdown before returning to the owner.
    public func connect(username: String, password: String, domain: String = "",
                        width: UInt32 = 1440, height: UInt32 = 900) async throws {
        guard !username.isEmpty, username.utf8.count <= 1024, password.utf8.count <= 16_384,
              domain.utf8.count <= 1024, host.utf8.count <= 1024,
              ![host, username, password, domain].contains(where: { $0.contains("\0") }) else {
            throw FloeError.validationFailed("Invalid RDP connection fields")
        }
        let box = RDPCallbackBox(owner: self)
        let native = try RDPWorker(host: host, port: port, username: username, password: password,
                                   domain: domain, width: width, height: height, box: box)
        let admitted = lock.withLock {
            guard worker == nil else { return false }
            worker = native
            state = .connecting
            frame = nil
            visualEvidence = nil
            structuredEvidence = nil
            challenge = nil
            return true
        }
        guard admitted else { await native.shutdown(); throw FloeError.validationFailed("RDP session is already active") }
        notifyChange()
        do {
            try native.start()
            try await withTaskCancellationHandler {
                let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    switch currentState {
                    case .connected: return
                    case .failed(let error): throw error
                    case .disconnected: throw FloeError.validationFailed("RDP connection was closed")
                    case .connecting: break
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                throw VNCConnectionFailure(category: .timedOut, stage: .handshake,
                    retryable: true, host: host, port: Int(port), message: "RDP connection timed out")
            } onCancel: { native.requestStop() }
        } catch {
            await disconnect(preserveFailure: true)
            lock.withLock {
                guard worker == nil else { return }
                if error is CancellationError { state = .disconnected }
                else if let failure = error as? VNCConnectionFailure { state = .failed(failure) }
                else if case .failed = state { /* Keep the native failure and certificate challenge. */ }
                else {
                    state = .failed(.init(category: .handshakeFailed, stage: .handshake,
                        retryable: true, host: host, port: Int(port), message: "RDP connection could not be established"))
                }
            }
            notifyChange()
            throw error
        }
    }

    public func disconnect() async { await disconnect(preserveFailure: false) }
    private func disconnect(preserveFailure: Bool) async {
        // Keep the worker registered while joining so another connect cannot
        // overlap callbacks from the previous connection.
        let old = lock.withLock { worker }
        await old?.shutdown()
        lock.withLock {
            guard worker === old else { return }
            worker = nil
            if !preserveFailure { state = .disconnected }
            frame = nil
            visualEvidence = nil
            structuredEvidence = nil
        }
        notifyChange()
    }

    fileprivate func receivedState(_ native: FloeRDPState, code: UInt32) {
        lock.withLock {
            switch native {
            case FLOE_RDP_CONNECTING: state = .connecting
            case FLOE_RDP_CONNECTED: state = .connected
            case FLOE_RDP_FAILED:
                state = .failed(.init(category: .handshakeFailed, stage: .handshake,
                    retryable: challenge == nil, host: host, port: Int(port),
                    message: challenge == nil ? "RDP connection failed" : "Confirm the RDP server certificate before connecting",
                    underlyingCode: String(format: "0x%08X", code)))
            default: state = .disconnected
            }
        }
        notifyChange()
    }
    fileprivate func receivedFrame(_ bytes: UnsafePointer<UInt8>, width: UInt32, height: UInt32, stride: UInt32) {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              stride >= width * 4, UInt64(stride) * UInt64(height) <= 32 * 1024 * 1024 else { return }
        let data = Data(bytes: bytes, count: Int(stride) * Int(height))
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: Int(stride), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        lock.withLock { frame = image; revision &+= 1; capturedAt = Date() }
        notifyChange()
    }
    fileprivate func checkCertificate(_ pem: Data) -> Bool {
        let result = RDPCertificateTrust.evaluate(pem: pem, hostname: certificateHostname, pinnedSHA256: approvedFingerprint)
        lock.withLock { challenge = result.accepted ? nil : result }
        notifyChange()
        return result.accepted
    }

    public func captureJPEG(compressionQuality: Double = 0.78) throws -> VNCFrameCapture {
        let snapshot = lock.withLock { (state, frame, revision, capturedAt) }
        guard snapshot.0 == .connected, let image = snapshot.1 else {
            throw FloeError.validationFailed("RDP has not received a connected desktop frame")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw FloeError.internalError("Could not create RDP screenshot encoder")
        }
        CGImageDestinationAddImage(destination, image,
            [kCGImageDestinationLossyCompressionQuality: max(0.2, min(0.95, compressionQuality))] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length > 0, data.length <= 8 * 1024 * 1024 else {
            throw FloeError.validationFailed("RDP screenshot could not be encoded within 8 MiB")
        }
        let encoded = data as Data
        return VNCFrameCapture(data: encoded, sha256: FloeDigest.sha256Hex(encoded),
            pixelWidth: image.width, pixelHeight: image.height, revision: snapshot.2, capturedAt: snapshot.3)
    }

    private func enqueue(_ events: [FloeRDPInput]) throws {
        guard let native = lock.withLock({ state == .connected ? worker : nil }) else {
            throw FloeError.validationFailed("RDP session is not connected")
        }
        try native.enqueue(events)
    }
    private func mouse(_ flags: UInt16, x: UInt16, y: UInt16) -> FloeRDPInput {
        FloeRDPInput(kind: 0, flags: flags, code: 0, x: x, y: y)
    }
    public func mouseMove(x: UInt16, y: UInt16) throws { try enqueue([mouse(0x0800, x: x, y: y)]) }
    public func mouseDown(x: UInt16, y: UInt16) throws { try enqueue([mouse(0x9000, x: x, y: y)]) }
    public func mouseUp(x: UInt16, y: UInt16) throws { try enqueue([mouse(0x1000, x: x, y: y)]) }
    public func click(x: UInt16, y: UInt16) throws {
        try enqueue([mouse(0x0800, x: x, y: y), mouse(0x9000, x: x, y: y), mouse(0x1000, x: x, y: y)])
    }
    public func scroll(up: Bool, x: UInt16, y: UInt16, steps: UInt32 = 1) throws {
        guard steps > 0, steps <= 100 else { throw FloeError.validationFailed("RDP scroll steps must be 1–100") }
        let flags: UInt16 = up ? 0x0278 : 0x0388 // wheel / signed 9-bit delta ±120
        try enqueue(Array(repeating: mouse(flags, x: x, y: y), count: Int(steps)))
    }
    public func send(text: String) throws { try send(text: text, submit: false) }
    public func send(text: String, submit: Bool) throws {
        guard text.utf8.count <= 4096 else { throw FloeError.validationFailed("RDP text exceeds 4096 UTF-8 bytes") }
        var events: [FloeRDPInput] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for unit in normalized.utf16 {
            if unit == 10 || unit == 13 { events += try keyEvents("return") }
            else if unit == 9 { events += try keyEvents("tab") }
            else { events += [FloeRDPInput(kind: 2, flags: 0x4000, code: unit, x: 0, y: 0), FloeRDPInput(kind: 2, flags: 0x8000, code: unit, x: 0, y: 0)] }
        }
        if submit { events += try keyEvents("return") }
        guard !events.isEmpty else { return }
        try enqueue(events)
    }
    public func send(namedKey: String) throws { try enqueue(keyEvents(namedKey)) }
    private func keyEvents(_ name: String) throws -> [FloeRDPInput] {
        let keys: [String: UInt16] = ["return": 0x1C, "enter": 0x1C, "tab": 0x0F, "escape": 0x01, "esc": 0x01,
            "space": 0x39, "backspace": 0x0E, "delete": 0x0E, "forwarddelete": 0x153,
            "left": 0x14B, "right": 0x14D, "up": 0x148, "down": 0x150, "pageup": 0x149,
            "pagedown": 0x151, "home": 0x147, "end": 0x14F, "insert": 0x152,
            "f1": 0x3B, "f2": 0x3C, "f3": 0x3D, "f4": 0x3E, "f5": 0x3F, "f6": 0x40,
            "f7": 0x41, "f8": 0x42, "f9": 0x43, "f10": 0x44, "f11": 0x57, "f12": 0x58]
        guard let code = keys[name.lowercased()] else { throw FloeError.validationFailed("Unsupported RDP key") }
        let extended: UInt16 = code > 255 ? 0x0100 : 0
        return [FloeRDPInput(kind: 1, flags: extended | 0x4000, code: code & 255, x: 0, y: 0),
                FloeRDPInput(kind: 1, flags: extended | 0x8000, code: code & 255, x: 0, y: 0)]
    }
}

private final class RDPCallbackBox: @unchecked Sendable {
    weak var owner: RDPSession?
    init(owner: RDPSession) { self.owner = owner }
}

/// The callback box belongs to this native lease, not the Swift view/session.
/// Its final release is scheduled only after native destruction joins.
private final class RDPWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var pointer: OpaquePointer?
    private var callback: UnsafeMutableRawPointer?
    private var shutdownTask: Task<Void, Never>?
    init(host: String, port: UInt16, username: String, password: String, domain: String,
         width: UInt32, height: UInt32, box: RDPCallbackBox) throws {
        let user = Unmanaged.passRetained(box).toOpaque()
        let callbacks = FloeRDPCallbacks(user: user, state: { user, state, error in
            guard let user else { return }
            Unmanaged<RDPCallbackBox>.fromOpaque(user).takeUnretainedValue().owner?.receivedState(state, code: error)
        }, frame: { user, bytes, width, height, stride in
            guard let user, let bytes else { return }
            autoreleasepool {
                Unmanaged<RDPCallbackBox>.fromOpaque(user).takeUnretainedValue().owner?.receivedFrame(bytes, width: width, height: height, stride: stride)
            }
        }, certificate: { user, pem, count, _, _ in
            guard let user, let pem, count > 0, count <= 256 * 1024 else { return 0 }
            return autoreleasepool {
                Unmanaged<RDPCallbackBox>.fromOpaque(user).takeUnretainedValue().owner?.checkCertificate(Data(bytes: pem, count: count)) == true ? 1 : 0
            }
        })
        let result = host.withCString { host in username.withCString { username in password.withCString { password in domain.withCString { domain in
            var options = FloeRDPOptions(host: host, port: port, username: username, password: password,
                domain: domain, width: width, height: height)
            return floe_rdp_create(&options, callbacks)
        } } } }
        guard let result else { Unmanaged<RDPCallbackBox>.fromOpaque(user).release(); throw FloeError.invalidConfiguration("Could not create the RDP runtime") }
        pointer = result
        callback = user
    }
    func start() throws {
        let started: Bool = lock.withLock {
            guard let pointer else { return false }
            return floe_rdp_start(pointer) == 1
        }
        guard started else { throw FloeError.validationFailed("Could not start the RDP worker") }
    }
    func requestStop() { lock.withLock { if let pointer { floe_rdp_stop(pointer) } } }
    func enqueue(_ events: [FloeRDPInput]) throws {
        let accepted = lock.withLock {
            guard let pointer else { return false }
            return events.withUnsafeBufferPointer { floe_rdp_input(pointer, $0.baseAddress, $0.count) == 1 }
        }
        guard accepted else {
            // A previous drag may have sent button-down. Close this transport
            // rather than leaving that remote button held after queue failure.
            requestStop()
            throw FloeError.validationFailed("RDP input was not queued; the session was closed because it stopped or its input queue was full")
        }
    }
    func shutdown() async {
        let task = lock.withLock { () -> Task<Void, Never> in
            if let shutdownTask { return shutdownTask }
            let lease = takeLease()
            let task = Task.detached { if let lease { lease.destroy() } }
            shutdownTask = task
            return task
        }
        await task.value
    }
    /// Caller holds lock, or is deinitializing with no other references.
    private func takeLease() -> RDPNativeLease? {
        guard let pointer, let callback else { return nil }
        self.pointer = nil; self.callback = nil
        floe_rdp_stop(pointer)
        return RDPNativeLease(pointer: pointer, callback: callback)
    }
    deinit {
        if let lease = takeLease() { DispatchQueue.global(qos: .utility).async { lease.destroy() } }
    }
}
private struct RDPNativeLease: @unchecked Sendable {
    let pointer: OpaquePointer
    let callback: UnsafeMutableRawPointer
    func destroy() {
        // A failed join must retain the callback and native memory. Never
        // release an address still reachable by the native worker.
        if floe_rdp_destroy(pointer) == 1 { Unmanaged<RDPCallbackBox>.fromOpaque(callback).release() }
    }
}
#endif
