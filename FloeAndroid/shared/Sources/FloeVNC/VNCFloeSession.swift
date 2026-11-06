// SPDX-License-Identifier: MPL-2.0
//
// Real RFB session owned by the Android trusted host. RoyalVNCKit does the
// RFB 3.x handshake, security-type negotiation, authentication, encodings
// and framebuffer mutation. This file owns the Android-side lifetime:
// explicit input release, bounded immutable frame leases, truthful state
// transitions and an awaited close.

import Foundation
import RoyalVNCKit

private final class VNCFloeSilentLogger: VNCLogger {
    var isDebugLoggingEnabled = false
    func logDebug(_ message: @autoclosure () -> String) {}
    func logInfo(_ message: String) {}
    func logWarning(_ message: String) {}
    func logError(_ message: String) {}
}

public final class VNCFloeSession: VNCConnectionDelegate, VNCFloeSessionDriving, @unchecked Sendable {
    public let host: String
    public let port: UInt16
    public let maximumFrameBytes: Int

    private let lock = NSLock()
    private let frameCopyLock = NSLock()
    private let connection: VNCConnection
    private var password: String?

    private var _state: VNCFloeState = .disconnected
    private var framebuffer: VNCFramebuffer?
    private var frameDirty = false
    private var frameRevision: UInt64 = 0
    private var latestFrame: VNCFloeFrame?
    private var leases: [UUID: VNCFloeFrameLease] = [:]

    private var pressedButtons: Set<VNCFloePointerButton> = []
    private var pressedKeys: Set<UInt32> = []
    private var lastPointerX: UInt16 = 0
    private var lastPointerY: UInt16 = 0

    private var closeRequested = false
    private var closeCompleted = false
    private var closeWaiters: [CheckedContinuation<Bool, Never>] = []
    private var closeTimeoutItem: DispatchWorkItem?

    public init(
        host: String,
        port: UInt16,
        password: String?,
        maximumFrameBytes: Int = VNCFloeFrameBounds.maximumBytes
    ) {
        self.host = host
        self.port = port
        self.password = password
        self.maximumFrameBytes = max(1, maximumFrameBytes)
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: host,
            port: port,
            isShared: true,
            isScalingEnabled: false,
            useDisplayLink: false,
            // Input is forwarded explicitly by the App. RoyalVNCKit's .none
            // also drops programmatic pointer/key messages before enqueueing.
            inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
            isClipboardRedirectionEnabled: false,
            colorDepth: .depth24Bit,
            // No Tight/JPEG advertisement: a non-Apple build has no JPEG
            // decoder, so a server choosing Tight-JPEG would fail after
            // negotiation. These encodings are real RFB decoders.
            frameEncodings: [.copyRect, .hextile, .zlib, .zrle, .coRRE, .rre, .raw]
        )
        self.connection = VNCConnection(
            settings: settings,
            logger: VNCFloeSilentLogger(),
            framebufferAllocator: VNCFloeBoundedAllocator(maximumBytes: self.maximumFrameBytes),
            context: nil
        )
        connection.delegate = self
    }

    deinit {
        connection.delegate = nil
        connection.disconnect()
    }

    // MARK: - Public state

    public var currentState: VNCFloeState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    public var isConnected: Bool { currentState.isConnected }

    public func connect() {
        lock.lock()
        if closeRequested || _state.isConnected || _state == .connecting {
            lock.unlock()
            return
        }
        _state = .connecting
        lock.unlock()
        connection.connect()
    }

    /// Releases every pressed protocol input before the transport closes.
    /// Best effort by design: a failed send must not block shutdown.
    public func releaseAllInput() {
        let buttons: Set<VNCFloePointerButton>
        let keys: Set<UInt32>
        let x: UInt16
        let y: UInt16
        lock.lock()
        buttons = pressedButtons
        keys = pressedKeys
        x = lastPointerX
        y = lastPointerY
        pressedButtons.removeAll()
        pressedKeys.removeAll()
        let canSend = _state.isConnected || _state == .closing
        lock.unlock()
        guard canSend else { return }
        for button in buttons {
            connection.mouseButtonUp(Self.royalButton(button), x: x, y: y)
        }
        for key in keys {
            connection.keyUp(VNCKeyCode(key))
        }
    }

    /// Awaits a real disconnect. Returns false when the transport did not
    /// prove closure inside `timeout`; the caller must keep the session in
    /// `.closing` and retry rather than report a drained state.
    public func close(timeout: TimeInterval = 5) async -> Bool {
        let plan = lock.withLock { () -> (finished: Bool, disconnect: Bool) in
            if closeCompleted { return (true, false) }
            if _state.isTerminal {
                closeCompleted = true
                closeRequested = true
                password = nil
                latestFrame = nil
                leases.removeAll()
                return (true, true)
            }
            closeRequested = true
            _state = .closing
            return (false, false)
        }
        if plan.finished {
            if plan.disconnect { connection.disconnect() }
            return true
        }

        releaseAllInput()
        if connection.connectionState.status == .disconnected {
            resolveCloseWaiters(true)
            return true
        }
        let disconnected = await withCheckedContinuation { continuation in
            lock.lock()
            closeWaiters.append(continuation)
            lock.unlock()
            connection.disconnect()
            scheduleCloseTimeout(timeout)
        }
        if disconnected {
            lock.withLock {
                closeCompleted = true
                closeRequested = true
                password = nil
                latestFrame = nil
                leases.removeAll()
                _state = .disconnected
            }
        }
        return disconnected
    }

    private func scheduleCloseTimeout(_ seconds: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in
            self?.resolveCloseWaiters(false)
        }
        lock.lock()
        closeTimeoutItem?.cancel()
        closeTimeoutItem = item
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0.1, seconds), execute: item)
    }

    private func resolveCloseWaiters(_ disconnected: Bool) {
        lock.lock()
        let waiters = closeWaiters
        closeWaiters.removeAll()
        if disconnected {
            closeCompleted = true
            _state = .disconnected
        } else if !_state.isTerminal {
            _state = .closing
        }
        if disconnected {
            password = nil
            latestFrame = nil
            leases.removeAll()
        }
        closeTimeoutItem?.cancel()
        closeTimeoutItem = nil
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: disconnected)
        }
    }

    // MARK: - Frames

    /// Copies the current framebuffer only when a new RFB update has landed.
    /// The immutable copy is safe to read after the session advances.
    public func currentFrame() -> VNCFloeFrame? {
        lock.lock()
        let snapshot = latestFrame
        if let snapshot, !frameDirty {
            lock.unlock()
            return snapshot
        }
        guard let framebuffer else {
            lock.unlock()
            return snapshot
        }
        let revision = frameRevision
        let width = Int(framebuffer.size.width)
        let height = Int(framebuffer.size.height)
        lock.unlock()

        frameCopyLock.lock()
        defer { frameCopyLock.unlock() }

        if let failure = VNCFloeFrameBounds.validate(width: width, height: height) {
            transition(.failed(failure))
            return snapshot
        }
        guard let raw = framebuffer.floeCopyBGRA32() else {
            return snapshot
        }
        guard raw.count == width * height * 4 else {
            transition(.failed(VNCFloeFailure(
                category: .framebufferTooLarge,
                stage: .framebuffer,
                retryable: true,
                message: "The VNC framebuffer byte count does not match its dimensions."
            )))
            return snapshot
        }

        let frame = VNCFloeFrame(
            width: width,
            height: height,
            revision: revision,
            data: VNCFloePixelFormat.rgbaFromBGRA(raw)
        )

        lock.lock()
        // Never let a slower copy regress a newer frame.
        if latestFrame == nil || revision > (latestFrame?.revision ?? 0) {
            latestFrame = frame
        }
        if frameRevision == revision {
            frameDirty = false
        }
        let result = latestFrame
        lock.unlock()
        return result
    }

    /// Mints a bounded lease over the latest immutable frame. The lease
    /// keeps its Data alive even if a newer frame replaces the session's
    /// latest frame; the viewer releases it after copying the bytes.
    public func acquireFrame() throws -> VNCFloeFrameLease {
        guard currentState.isConnected else {
            throw VNCFloeFailure(
                category: .notConnected,
                stage: .framebuffer,
                retryable: true,
                message: "The VNC session is not connected."
            )
        }
        guard let frame = currentFrame() else {
            throw VNCFloeFailure(
                category: .frameUnavailable,
                stage: .framebuffer,
                retryable: true,
                message: "The VNC server has not produced a framebuffer yet."
            )
        }
        lock.lock()
        defer { lock.unlock() }
        guard leases.count < VNCFloeFrameBounds.maximumLeasesPerSession else {
            throw VNCFloeFailure(
                category: .frameLeaseLimit,
                stage: .framebuffer,
                retryable: true,
                message: "The VNC frame viewer has too many unreleased leases."
            )
        }
        let lease = VNCFloeFrameLease(frame: frame)
        leases[lease.id] = lease
        return lease
    }

    public func releaseFrame(_ id: UUID) {
        lock.lock()
        leases.removeValue(forKey: id)
        lock.unlock()
    }

    public var framebufferSize: (width: Int, height: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let framebuffer else { return nil }
        return (Int(framebuffer.size.width), Int(framebuffer.size.height))
    }

    /// Metadata-only accessors used by the host status projection. They do
    /// not copy the framebuffer (a status poll must never allocate 8-33 MiB).
    public var latestFrameRevision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return latestFrame?.revision ?? 0
    }

    public var latestFrameByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return latestFrame?.data.count ?? 0
    }

    // MARK: - Input

    public func send(_ events: [VNCFloeInputEvent]) throws {
        guard !events.isEmpty else { return }
        guard currentState.isConnected else {
            throw VNCFloeFailure(
                category: .notConnected,
                stage: .input,
                retryable: true,
                message: "The VNC session is not connected."
            )
        }
        for event in events {
            switch event {
            case .pointerMove(let x, let y):
                let point = try clamp(x: x, y: y)
                lock.lock(); lastPointerX = point.0; lastPointerY = point.1; lock.unlock()
                connection.mouseMove(x: point.0, y: point.1)

            case .pointerButton(let button, let down, let x, let y):
                let point = try clamp(x: x, y: y)
                lock.lock()
                if down { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
                lastPointerX = point.0
                lastPointerY = point.1
                lock.unlock()
                if down {
                    connection.mouseButtonDown(Self.royalButton(button), x: point.0, y: point.1)
                } else {
                    connection.mouseButtonUp(Self.royalButton(button), x: point.0, y: point.1)
                }

            case .wheel(let axis, let steps, let x, let y):
                let point = try clamp(x: x, y: y)
                let boundedSteps = max(1, min(20, steps))
                lock.lock(); lastPointerX = point.0; lastPointerY = point.1; lock.unlock()
                connection.mouseWheel(
                    Self.royalWheel(axis),
                    x: point.0,
                    y: point.1,
                    steps: UInt32(boundedSteps)
                )

            case .key(let keysym, let down):
                guard keysym > 0, keysym <= 0x10FFFF else {
                    throw VNCFloeFailure(
                        category: .inputInvalid,
                        stage: .input,
                        retryable: false,
                        message: "The VNC key symbol is outside the supported range."
                    )
                }
                lock.lock()
                if down { pressedKeys.insert(keysym) } else { pressedKeys.remove(keysym) }
                lock.unlock()
                if down {
                    connection.keyDown(VNCKeyCode(keysym))
                } else {
                    connection.keyUp(VNCKeyCode(keysym))
                }

            case .text(let text):
                guard text.utf8.count <= 4 * 1_024 else {
                    throw VNCFloeFailure(
                        category: .inputInvalid,
                        stage: .input,
                        retryable: false,
                        message: "The VNC text payload exceeds 4 KiB."
                    )
                }
                for character in text {
                    if character.isNewline {
                        connection.keyDown(.return)
                        connection.keyUp(.return)
                    } else {
                        for key in VNCKeyCode.withCharacter(character) {
                            connection.keyDown(key)
                            connection.keyUp(key)
                        }
                    }
                }
            }
        }
    }

    private func clamp(x: Int, y: Int) throws -> (UInt16, UInt16) {
        lock.lock()
        let size = framebuffer.map { (Int($0.size.width), Int($0.size.height)) }
        lock.unlock()
        guard let size, size.0 > 0, size.1 > 0 else {
            throw VNCFloeFailure(
                category: .notConnected,
                stage: .input,
                retryable: true,
                message: "The VNC framebuffer is not ready for input."
            )
        }
        let clampedX = max(0, min(size.0 - 1, x))
        let clampedY = max(0, min(size.1 - 1, y))
        return (UInt16(clampedX), UInt16(clampedY))
    }

    private static func royalButton(_ button: VNCFloePointerButton) -> VNCMouseButton {
        switch button {
        case .left: .left
        case .middle: .middle
        case .right: .right
        }
    }

    private static func royalWheel(_ axis: VNCFloeWheelAxis) -> VNCMouseWheel {
        switch axis {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
    }

    // MARK: - Delegate

    public func connection(
        _ connection: VNCConnection,
        stateDidChange connectionState: VNCConnection.ConnectionState
    ) {
        switch connectionState.status {
        case .connecting:
            transition(.connecting)
        case .connected:
            transition(.connected)
        case .disconnecting:
            lock.lock()
            if !_state.isTerminal { _state = .closing }
            lock.unlock()
        case .disconnected:
            if let error = connectionState.error {
                lock.lock()
                let configured = password?.isEmpty == false
                lock.unlock()
                let failure = Self.normalizedFailure(
                    error,
                    passwordConfigured: configured
                )
                transition(.failed(failure))
            } else {
                transition(.disconnected)
                resolveCloseWaiters(true)
            }
        }
    }

    public func connection(
        _ connection: VNCConnection,
        credentialFor authenticationType: VNCAuthenticationType,
        completion: @escaping (VNCCredential?) -> Void
    ) {
        lock.lock()
        let configured = password
        lock.unlock()
        guard !authenticationType.requiresUsername else {
            transition(.failed(VNCFloeFailure(
                category: .credentialMissing,
                stage: .credentialResolution,
                retryable: false,
                message: "This VNC server requires a username/password security type that the saved VNC profile does not provide."
            )))
            completion(nil)
            return
        }
        guard authenticationType.requiresPassword else {
            completion(nil)
            return
        }
        guard let configured, !configured.isEmpty else {
            transition(.failed(VNCFloeFailure(
                category: .credentialMissing,
                stage: .credentialResolution,
                retryable: false,
                message: "The VNC server requires a password, but no VNC password is saved."
            )))
            completion(nil)
            return
        }
        completion(VNCPasswordCredential(password: configured))
    }

    public func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        install(framebuffer: framebuffer, resized: false)
    }

    public func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        install(framebuffer: framebuffer, resized: true)
    }

    public func connection(
        _ connection: VNCConnection,
        didUpdateFramebuffer framebuffer: VNCFramebuffer,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16
    ) {
        _ = (x, y, width, height)
        lock.lock()
        self.framebuffer = framebuffer
        frameDirty = true
        frameRevision &+= 1
        lock.unlock()
    }

    public func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {
        _ = cursor
    }

    // MARK: - Internal

    private func install(framebuffer: VNCFramebuffer, resized: Bool) {
        let width = Int(framebuffer.size.width)
        let height = Int(framebuffer.size.height)
        if let failure = VNCFloeFrameBounds.validate(width: width, height: height) {
            transition(.failed(failure))
            connection.disconnect()
            return
        }
        lock.lock()
        if resized || self.framebuffer !== framebuffer {
            latestFrame = nil
        }
        self.framebuffer = framebuffer
        frameDirty = true
        frameRevision &+= 1
        lock.unlock()
    }

    private func transition(_ newState: VNCFloeState) {
        lock.lock()
        switch newState {
        case .disconnected:
            // Preserve an actionable failure (the donor does the same);
            // a clean disconnect after connecting is a real disconnected
            // state, not a stale connected projection.
            if case .failed = _state {
                // keep the failure
            } else {
                _state = .disconnected
            }
        default:
            _state = newState
        }
        lock.unlock()
    }

    private static func normalizedFailure(_ error: Error, passwordConfigured: Bool) -> VNCFloeFailure {
        let nsError = error as NSError
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = "\(raw) \(nsError.domain) \(nsError.code)".lowercased()
        let code = "\(nsError.domain):\(nsError.code)"
        if probe.contains("auth") || probe.contains("password") || probe.contains("security") {
            if passwordConfigured {
                return VNCFloeFailure(
                    category: .authenticationFailed,
                    stage: .authentication,
                    retryable: false,
                    message: "VNC authentication was rejected. Check the saved VNC password and the server security type.",
                    underlyingCode: code
                )
            }
            return VNCFloeFailure(
                category: .credentialMissing,
                stage: .credentialResolution,
                retryable: false,
                message: "VNC authentication requires a password, but this profile has none.",
                underlyingCode: code
            )
        }
        if probe.contains("timed out") || probe.contains("timeout") {
            return VNCFloeFailure(
                category: .timedOut,
                stage: .transport,
                retryable: true,
                message: "The VNC connection timed out.",
                underlyingCode: code
            )
        }
        if probe.contains("refused") {
            return VNCFloeFailure(
                category: .connectionRefused,
                stage: .transport,
                retryable: true,
                message: "The VNC server refused the connection.",
                underlyingCode: code
            )
        }
        if probe.contains("unreachable") || probe.contains("no route") ||
            probe.contains("name or service") || probe.contains("not known") ||
            probe.contains("dns") {
            return VNCFloeFailure(
                category: .networkUnreachable,
                stage: .transport,
                retryable: true,
                message: "The VNC host is unreachable from this device.",
                underlyingCode: code
            )
        }
        if probe.contains("version") || probe.contains("encoding") || probe.contains("protocol") {
            return VNCFloeFailure(
                category: .protocolIncompatible,
                stage: .handshake,
                retryable: false,
                message: "The VNC server uses a protocol or encoding this client does not support.",
                underlyingCode: code
            )
        }
        let detail = raw.isEmpty ? "unknown transport error" : String(raw.prefix(180))
        return VNCFloeFailure(
            category: .handshakeFailed,
            stage: .handshake,
            retryable: true,
            message: "The VNC handshake failed: \(detail)",
            underlyingCode: code
        )
    }
}
