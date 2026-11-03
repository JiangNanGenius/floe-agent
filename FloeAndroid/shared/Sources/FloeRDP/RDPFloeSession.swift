// SPDX-License-Identifier: MPL-2.0
//
// Real FreeRDP session owned by the Android trusted host.
//
// FreeRDP performs the RDP connection, TLS/certificate handshake,
// authentication, capability negotiation and bitmap decoding. The small
// `FloeRDPNative` C bridge owns the worker and input queue; this file owns the
// Android-side lifetime: immutable bounded frames, explicit input release,
// awaited close, cancellation and the explicit certificate challenge.
//
// The whole implementation is Android-only. The bridge target compiles empty
// elsewhere, so host builds never link or pretend to speak RDP.

#if os(Android)
import Foundation
import FloeCore
import FloeRDPNative

public final class RDPFloeSession: RDPFloeSessionDriving, @unchecked Sendable {
    public let host: String
    public let port: UInt16
    public let certificateHostname: String
    public let maximumFrameBytes: Int

    private let lock = NSLock()
    private let approvedFingerprint: String?
    private let width: UInt32
    private let height: UInt32
    private let username: String
    private let password: String
    private let domain: String

    private var worker: RDPWorker?
    private var _state: RDPFloeState = .disconnected
    private var latestFrame: RDPFloeFrame?
    private var frameRevision: UInt64 = 0
    private var challenge: RDPCertificateChallenge?
    private var leases: [UUID: RDPFloeFrameLease] = [:]

    private var pressedButtons: Set<RDPFloePointerButton> = []
    private var pressedKeys: Set<PressedKey> = []
    private var lastPointerX: UInt16 = 0
    private var lastPointerY: UInt16 = 0
    private var closeCompleted = false

    private struct PressedKey: Hashable, Sendable {
        let scancode: UInt8
        let extended: Bool
    }

    public init(
        host: String,
        port: UInt16,
        username: String,
        password: String,
        domain: String = "",
        certificateHostname: String? = nil,
        approvedFingerprint: String? = nil,
        width: UInt32 = 1440,
        height: UInt32 = 900,
        maximumFrameBytes: Int = RDPFloeFrameBounds.maximumBytes
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.domain = domain
        self.certificateHostname = certificateHostname ?? host
        self.approvedFingerprint = RDPCertificateTrust.normalizePin(approvedFingerprint)
        self.width = width
        self.height = height
        self.maximumFrameBytes = max(1, maximumFrameBytes)
    }

    deinit {
        // No user callback can survive the worker join: the C bridge returns
        // only after pthread_join. The callback context is retained by the
        // lease and released only on a successful destroy.
        let worker = lock.withLock { self.worker }
        worker?.requestStop()
        worker?.detachDestroy()
    }

    // MARK: - Public state

    public static var runtimeVersion: String {
        String(cString: floe_rdp_version())
    }

    public var currentState: RDPFloeState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    public var isConnected: Bool { currentState.isConnected }

    public var certificateChallenge: RDPCertificateChallenge? {
        lock.lock(); defer { lock.unlock() }
        return challenge
    }

    public var framebufferSize: (width: Int, height: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let latestFrame else { return nil }
        return (latestFrame.width, latestFrame.height)
    }

    public var latestFrameRevision: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return latestFrame?.revision ?? 0
    }

    public var latestFrameByteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return latestFrame?.byteCount ?? 0
    }

    // MARK: - Connect / close

    public func connect() {
        lock.lock()
        let retryableState: Bool
        switch _state {
        case .disconnected: retryableState = true
        case .failed: retryableState = true
        default: retryableState = false
        }
        guard !closeCompleted, retryableState, worker == nil else {
            lock.unlock()
            return
        }
        _state = .connecting
        latestFrame = nil
        challenge = nil
        lock.unlock()

        do {
            let box = RDPCallbackBox(owner: self)
            let native = try RDPWorker(
                host: host,
                port: port,
                username: username,
                password: password,
                domain: domain,
                width: width,
                height: height,
                box: box
            )
            lock.lock()
            guard worker == nil, _state == .connecting else {
                lock.unlock()
                native.detachDestroy()
                return
            }
            worker = native
            lock.unlock()
            do {
                try native.start()
            } catch {
                lock.lock()
                worker = nil
                _state = .failed(RDPFloeFailure(
                    category: .runtimeUnavailable,
                    stage: .transport,
                    retryable: true,
                    message: "Could not start the RDP worker."
                ))
                lock.unlock()
                native.detachDestroy()
            }
        } catch {
            lock.lock()
            worker = nil
            if _state == .connecting {
                _state = .failed(RDPFloeFailure(
                    category: .configurationMissing,
                    stage: .configuration,
                    retryable: false,
                    message: "Could not create the RDP runtime."
                ))
            }
            lock.unlock()
        }
    }

    /// Awaits a real worker join. Returns false when closure was not proved in
    /// time; the session then stays `.closing` and the caller must retry
    /// instead of reporting a clean close.
    public func close(timeout: TimeInterval = 5) async -> Bool {
        let native = lock.withLock { worker }
        guard let native else {
            lock.withLock {
                closeCompleted = true
                _state = .disconnected
                latestFrame = nil
                leases.removeAll()
                challenge = nil
            }
            return true
        }
        lock.withLock {
            if !_state.isTerminal { _state = .closing }
        }
        releaseAllInput()
        let destroyed = await native.shutdown(timeout: max(0.1, timeout))
        if destroyed {
            lock.withLock {
                if worker === native {
                    worker = nil
                    closeCompleted = true
                    _state = .disconnected
                    latestFrame = nil
                    leases.removeAll()
                    challenge = nil
                }
            }
        }
        return destroyed
    }

    // MARK: - Frames

    public func currentFrame() -> RDPFloeFrame? {
        lock.lock()
        let snapshot = latestFrame
        lock.unlock()
        return snapshot
    }

    public func acquireFrame() throws -> RDPFloeFrameLease {
        guard currentState.isConnected else {
            throw RDPFloeFailure(
                category: .notConnected,
                stage: .framebuffer,
                retryable: true,
                message: "The RDP session is not connected."
            )
        }
        guard let frame = currentFrame() else {
            throw RDPFloeFailure(
                category: .frameUnavailable,
                stage: .framebuffer,
                retryable: true,
                message: "The RDP server has not produced a framebuffer yet."
            )
        }
        lock.lock()
        defer { lock.unlock() }
        guard leases.count < RDPFloeFrameBounds.maximumLeasesPerSession else {
            throw RDPFloeFailure(
                category: .frameLeaseLimit,
                stage: .framebuffer,
                retryable: true,
                message: "The RDP frame viewer has too many unreleased leases."
            )
        }
        let lease = RDPFloeFrameLease(frame: frame)
        leases[lease.id] = lease
        return lease
    }

    public func releaseFrame(_ id: UUID) {
        lock.lock()
        leases.removeValue(forKey: id)
        lock.unlock()
    }

    // MARK: - Input

    public func releaseAllInput() {
        lock.lock()
        let buttons = pressedButtons
        let keys = pressedKeys
        let x = lastPointerX
        let y = lastPointerY
        let canSend = _state.isConnected || _state == .closing
        pressedButtons.removeAll()
        pressedKeys.removeAll()
        lock.unlock()
        guard canSend else { return }
        var events: [RDPFloeInputEvent] = []
        for button in buttons {
            events.append(.pointerButton(button: button, down: false, x: x, y: y))
        }
        for key in keys {
            events.append(.key(scancode: key.scancode, extended: key.extended, down: false))
        }
        try? enqueue(events, trackState: false)
    }

    public func send(_ events: [RDPFloeInputEvent]) throws {
        try enqueue(events, trackState: true)
    }

    private func enqueue(_ events: [RDPFloeInputEvent], trackState: Bool) throws {
        guard !events.isEmpty else { return }
        lock.lock()
        guard _state.isConnected, let native = worker else {
            lock.unlock()
            throw RDPFloeFailure(
                category: .notConnected,
                stage: .input,
                retryable: true,
                message: "The RDP session is not connected."
            )
        }
        if trackState {
            for event in events {
                switch event {
                case .pointerButton(let button, let down, let x, let y):
                    if down { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
                    lastPointerX = x
                    lastPointerY = y
                case .pointerMove(let x, let y):
                    lastPointerX = x
                    lastPointerY = y
                case .wheel(_, let x, let y, _):
                    lastPointerX = x
                    lastPointerY = y
                case .key(let scancode, let extended, let down):
                    if down { pressedKeys.insert(PressedKey(scancode: scancode, extended: extended)) }
                    else { pressedKeys.remove(PressedKey(scancode: scancode, extended: extended)) }
                case .text:
                    break
                }
            }
        }
        lock.unlock()

        var input: [FloeRDPInput] = []
        input.reserveCapacity(events.count)
        for event in events {
            switch event {
            case .pointerMove(let x, let y):
                input.append(FloeRDPInput(kind: 0, flags: 0x0800, code: 0, x: x, y: y))
            case .pointerButton(let button, let down, let x, let y):
                let flags: UInt16 = (down ? 0x9000 : 0x1000) | button.flag
                input.append(FloeRDPInput(kind: 0, flags: flags, code: 0, x: x, y: y))
            case .wheel(let up, let x, let y, let steps):
                let bounded = max(1, min(20, steps))
                let flags: UInt16 = up ? 0x0278 : 0x0388
                for _ in 0..<bounded {
                    input.append(FloeRDPInput(kind: 0, flags: flags, code: 0, x: x, y: y))
                }
            case .key(let scancode, let extended, let down):
                let flags: UInt16 = (extended ? 0x0100 : 0) | (down ? 0x4000 : 0x8000)
                input.append(FloeRDPInput(kind: 1, flags: flags, code: UInt16(scancode), x: 0, y: 0))
            case .text(let text):
                for unit in text.utf16 {
                    if unit == 10 || unit == 13 {
                        input.append(FloeRDPInput(kind: 1, flags: 0x4000, code: 0x1C, x: 0, y: 0))
                        input.append(FloeRDPInput(kind: 1, flags: 0x8000, code: 0x1C, x: 0, y: 0))
                    } else if unit == 9 {
                        input.append(FloeRDPInput(kind: 1, flags: 0x4000, code: 0x0F, x: 0, y: 0))
                        input.append(FloeRDPInput(kind: 1, flags: 0x8000, code: 0x0F, x: 0, y: 0))
                    } else {
                        input.append(FloeRDPInput(kind: 2, flags: 0x4000, code: unit, x: 0, y: 0))
                        input.append(FloeRDPInput(kind: 2, flags: 0x8000, code: unit, x: 0, y: 0))
                    }
                }
            }
        }
        guard input.count <= 16_384 else {
            throw RDPFloeFailure(
                category: .inputInvalid,
                stage: .input,
                retryable: false,
                message: "The RDP input batch exceeds the bounded queue."
            )
        }
        let accepted = lock.withLock { _state.isConnected } && native.enqueue(input)
        guard accepted else {
            // A previous drag may have sent button-down. Close this transport
            // rather than leaving that remote button held after queue failure.
            native.requestStop()
            throw RDPFloeFailure(
                category: .inputInvalid,
                stage: .input,
                retryable: true,
                message: "RDP input was not queued; the session was closed because it stopped or its input queue was full."
            )
        }
    }

    public func mouseMove(x: UInt16, y: UInt16) throws {
        try send([.pointerMove(x: x, y: y)])
    }

    public func mouseDown(x: UInt16, y: UInt16) throws {
        try send([.pointerButton(button: .left, down: true, x: x, y: y)])
    }

    public func mouseUp(x: UInt16, y: UInt16) throws {
        try send([.pointerButton(button: .left, down: false, x: x, y: y)])
    }

    public func click(x: UInt16, y: UInt16) throws {
        try send([
            .pointerMove(x: x, y: y),
            .pointerButton(button: .left, down: true, x: x, y: y),
            .pointerButton(button: .left, down: false, x: x, y: y),
        ])
    }

    public func scroll(up: Bool, x: UInt16, y: UInt16, steps: UInt32 = 1) throws {
        guard steps > 0, steps <= 100 else {
            throw RDPFloeFailure(
                category: .inputInvalid,
                stage: .input,
                retryable: false,
                message: "RDP scroll steps must be 1-100."
            )
        }
        try send([.wheel(up: up, x: x, y: y, steps: steps)])
    }

    public func send(text: String, submit: Bool = false) throws {
        guard text.utf8.count <= 4_096 else {
            throw RDPFloeFailure(
                category: .inputInvalid,
                stage: .input,
                retryable: false,
                message: "RDP text exceeds 4 KiB."
            )
        }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var events: [RDPFloeInputEvent] = []
        if !normalized.isEmpty { events.append(.text(normalized)) }
        if submit, let returnEvents = RDPFloeKey.namedKeyEvents("return") {
            events.append(contentsOf: returnEvents)
        }
        try send(events)
    }

    public func send(namedKey name: String) throws {
        guard let events = RDPFloeKey.namedKeyEvents(name) else {
            throw RDPFloeFailure(
                category: .inputInvalid,
                stage: .input,
                retryable: false,
                message: "Unsupported RDP key."
            )
        }
        try send(events)
    }

    public func send(modifier: String, down: Bool) throws {
        guard let events = RDPFloeKey.modifierEvents(modifier, down: down) else {
            throw RDPFloeFailure(
                category: .inputInvalid,
                stage: .input,
                retryable: false,
                message: "Unsupported RDP modifier."
            )
        }
        try send(events)
    }

    // MARK: - Native callbacks

    fileprivate func receivedState(_ native: FloeRDPState, code: UInt32) {
        lock.lock()
        switch native {
        case FLOE_RDP_CONNECTING:
            if _state != .closing { _state = .connecting }
        case FLOE_RDP_CONNECTED:
            if _state != .closing { _state = .connected }
        case FLOE_RDP_FAILED:
            let challenge = self.challenge
            let failure: RDPFloeFailure
            if let challenge {
                failure = RDPFloeFailure(
                    category: .certificateRejected,
                    stage: .certificate,
                    retryable: false,
                    message: challenge.reason,
                    underlyingCode: String(format: "0x%08X", code),
                    fingerprintSHA256: challenge.fingerprintSHA256
                )
            } else {
                failure = RDPFloeFailure(
                    category: .handshakeFailed,
                    stage: .handshake,
                    retryable: true,
                    message: "RDP connection failed.",
                    underlyingCode: String(format: "0x%08X", code)
                )
            }
            if _state != .closing { _state = .failed(failure) }
        default:
            if _state != .closing { _state = .disconnected }
        }
        lock.unlock()
    }

    fileprivate func receivedFrame(
        _ bytes: UnsafePointer<UInt8>,
        width: UInt32,
        height: UInt32,
        stride: UInt32
    ) {
        guard width > 0, height > 0,
              width <= UInt32(RDPFloeFrameBounds.maximumEdge),
              height <= UInt32(RDPFloeFrameBounds.maximumEdge),
              stride >= width * 4,
              UInt64(stride) * UInt64(height) <= UInt64(maximumFrameBytes) else {
            requestStopAndFailFrame()
            return
        }
        let count = Int(stride) * Int(height)
        let raw = Data(bytes: bytes, count: count)
        guard let rgba = RDPFloePixelFormat.rgbaFromBGRA(
            raw,
            width: Int(width),
            height: Int(height),
            stride: Int(stride)
        ) else {
            requestStopAndFailFrame()
            return
        }
        lock.lock()
        guard _state == .connected, !closeCompleted else {
            lock.unlock()
            return
        }
        frameRevision &+= 1
        latestFrame = RDPFloeFrame(
            width: Int(width),
            height: Int(height),
            revision: frameRevision,
            data: rgba
        )
        // Keep only the latest immutable frame; existing leases retain their
        // own value. This is the same bounded model as the VNC lane.
        lock.unlock()
    }

    fileprivate func checkCertificate(_ pem: Data) -> Bool {
        let evaluation = RDPCertificateTrust.evaluate(
            pem: pem,
            hostname: certificateHostname,
            port: Int(port),
            pinnedSHA256: approvedFingerprint
        )
        lock.lock()
        if evaluation.accepted {
            challenge = nil
        } else {
            challenge = RDPCertificateChallenge(
                fingerprintSHA256: evaluation.fingerprintSHA256,
                subject: evaluation.subject,
                host: certificateHostname,
                port: Int(port),
                notBefore: evaluation.notBefore,
                notAfter: evaluation.notAfter,
                kind: mapping(evaluation.challengeKind),
                reason: evaluation.reason
            )
        }
        lock.unlock()
        return evaluation.accepted
    }

    private func mapping(_ kind: RDPCertificateChallengeKind?) -> RDPCertificateChallengeKind {
        kind ?? .firstUse
    }

    private func requestStopAndFailFrame() {
        lock.lock()
        if _state == .connected {
            _state = .failed(RDPFloeFailure(
                category: .framebufferTooLarge,
                stage: .framebuffer,
                retryable: true,
                message: "The RDP server published an invalid framebuffer."
            ))
        }
        let native = worker
        lock.unlock()
        native?.requestStop()
    }
}

private final class RDPCallbackBox: @unchecked Sendable {
    weak var owner: RDPFloeSession?
    init(owner: RDPFloeSession) { self.owner = owner }
}

private extension RDPFloePointerButton {
    var flag: UInt16 {
        switch self {
        case .left: return 0x1000
        case .middle: return 0x2000
        case .right: return 0x4000
        }
    }
}

/// The callback context belongs to this native lease, not the Swift view or
/// session. It is released only after `floe_rdp_destroy` proves the worker
/// has joined.
private final class RDPWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var lease: RDPNativeLease?
    private var destroyTask: Task<Bool, Never>?

    init(
        host: String,
        port: UInt16,
        username: String,
        password: String,
        domain: String,
        width: UInt32,
        height: UInt32,
        box: RDPCallbackBox
    ) throws {
        let user = Unmanaged.passRetained(box).toOpaque()
        let callbacks = FloeRDPCallbacks(
            user: user,
            state: { user, state, error in
                guard let user else { return }
                Unmanaged<RDPCallbackBox>.fromOpaque(user).takeUnretainedValue()
                    .owner?.receivedState(state, code: error)
            },
            frame: { user, bytes, frameWidth, frameHeight, stride in
                guard let user, let bytes else { return }
                Unmanaged<RDPCallbackBox>.fromOpaque(user).takeUnretainedValue()
                    .owner?.receivedFrame(
                        bytes,
                        width: frameWidth,
                        height: frameHeight,
                        stride: stride
                    )
            },
            certificate: { user, pem, count, _, _ in
                guard let user, let pem, count > 0,
                      count <= RDPCertificateTrust.maximumPEMBytes else {
                    return 0
                }
                return Unmanaged<RDPCallbackBox>.fromOpaque(user).takeUnretainedValue()
                    .owner?.checkCertificate(Data(bytes: pem, count: count)) == true ? 1 : 0
            }
        )
        let result = host.withCString { hostPointer in
            username.withCString { usernamePointer in
                password.withCString { passwordPointer in
                    domain.withCString { domainPointer in
                        var options = FloeRDPOptions(
                            host: hostPointer,
                            port: port,
                            username: usernamePointer,
                            password: passwordPointer,
                            domain: domainPointer,
                            width: width,
                            height: height
                        )
                        return floe_rdp_create(&options, callbacks)
                    }
                }
            }
        }
        guard let result else {
            Unmanaged<RDPCallbackBox>.fromOpaque(user).release()
            throw RDPFloeFailure(
                category: .configurationMissing,
                stage: .configuration,
                retryable: false,
                message: "Could not create the RDP runtime."
            )
        }
        lease = RDPNativeLease(pointer: result, callback: user)
    }

    /// Atomically checks the live native lease and enqueues the whole batch.
    /// `destroy` clears the lease before joining, so a concurrent close can
    /// never produce a use-after-free here.
    func enqueue(_ input: [FloeRDPInput]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let lease else { return false }
        return input.withUnsafeBufferPointer { buffer in
            floe_rdp_input(lease.pointer, buffer.baseAddress, buffer.count) == 1
        }
    }

    func start() throws {
        let started: Bool = lock.withLock {
            guard let lease else { return false }
            return floe_rdp_start(lease.pointer) == 1
        }
        guard started else {
            throw RDPFloeFailure(
                category: .runtimeUnavailable,
                stage: .transport,
                retryable: true,
                message: "Could not start the RDP worker."
            )
        }
    }

    func requestStop() {
        let pointer = lock.withLock { lease?.pointer }
        if let pointer { floe_rdp_stop(pointer) }
    }

    /// Returns true only when the native destroy call reports a completed
    /// worker join. On timeout the same task remains for a later retry; the
    /// callback context is never released while that task is still running.
    func shutdown(timeout: TimeInterval) async -> Bool {
        let task: Task<Bool, Never> = lock.withLock {
            if let destroyTask { return destroyTask }
            let current = lease
            lease = nil
            let created = Task.detached {
                guard let current else { return true }
                return current.destroy()
            }
            destroyTask = created
            return created
        }
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(Int(max(0.05, timeout) * 1_000)))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        return completed
    }

    /// Best-effort process-lifetime cleanup for a worker whose owner left.
    /// The callback context and native memory are freed only on a real join.
    func detachDestroy() {
        requestStop()
        let task: Task<Bool, Never>? = lock.withLock {
            if let destroyTask { return destroyTask }
            let current = lease
            lease = nil
            let created = Task.detached {
                guard let current else { return true }
                return current.destroy()
            }
            destroyTask = created
            return created
        }
        _ = task
    }
}

private struct RDPNativeLease: @unchecked Sendable {
    let pointer: OpaquePointer
    let callback: UnsafeMutableRawPointer

    func destroy() -> Bool {
        if floe_rdp_destroy(pointer) == 1 {
            Unmanaged<RDPCallbackBox>.fromOpaque(callback).release()
            return true
        }
        return false
    }
}
#endif
