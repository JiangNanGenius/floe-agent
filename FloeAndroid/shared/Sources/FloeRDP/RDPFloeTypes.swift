// SPDX-License-Identifier: MPL-2.0
//
// FloeRDP — Android remote-desktop values for the real FreeRDP transport.
//
// This target is protocol/transport only. FreeRDP performs the actual RDP
// negotiation, authentication, TLS/certificate handshake, bitmap decoding and
// input dispatch through the small `FloeRDPNative` C bridge. This module adds
// an Android-lifetime session shell, a bounded immutable RGBA frame lease and
// explicit pointer/keyboard/wheel input. It contains no UIKit, CoreGraphics,
// Metal or screenshot-refresh fallback; screenshots are produced by the
// ordinary artifact tools from real frames.

import Foundation

public enum RDPFloeFailureCategory: String, Sendable, Equatable {
    case configurationMissing
    case credentialMissing
    case authenticationFailed
    case certificateRequired
    case certificateRejected
    case networkUnreachable
    case connectionRefused
    case timedOut
    case handshakeFailed
    case protocolIncompatible
    case framebufferTooLarge
    case frameUnavailable
    case frameLeaseLimit
    case notConnected
    case inputInvalid
    case cancelled
    case closed
    case runtimeUnavailable
}

public enum RDPFloeFailureStage: String, Sendable, Equatable {
    case configuration
    case credentialResolution
    case transport
    case certificate
    case authentication
    case handshake
    case framebuffer
    case input
}

/// Secret-free RDP failure value. It never carries a password, credential
/// body or raw certificate bytes.
public struct RDPFloeFailure: Error, Sendable, Equatable, LocalizedError {
    public let category: RDPFloeFailureCategory
    public let stage: RDPFloeFailureStage
    public let retryable: Bool
    public let message: String
    public let underlyingCode: String?
    public let fingerprintSHA256: String?

    public init(
        category: RDPFloeFailureCategory,
        stage: RDPFloeFailureStage,
        retryable: Bool,
        message: String,
        underlyingCode: String? = nil,
        fingerprintSHA256: String? = nil
    ) {
        self.category = category
        self.stage = stage
        self.retryable = retryable
        self.message = message
        self.underlyingCode = underlyingCode
        self.fingerprintSHA256 = fingerprintSHA256
    }

    public var errorDescription: String? { message }
}

public enum RDPFloeState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case closing
    case failed(RDPFloeFailure)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isTerminal: Bool {
        switch self {
        case .disconnected, .failed:
            return true
        default:
            return false
        }
    }
}

/// Immutable RGBA8 frame. `data.count == width * height * 4`; rows are
/// tightly packed (`stride == width * 4`). The same value may be referenced
/// by a lease after a newer frame has replaced the session's latest frame.
public struct RDPFloeFrame: Sendable, Equatable {
    public static let pixelFormat = "RGBA8888"

    public let id: UUID
    public let width: Int
    public let height: Int
    public let stride: Int
    public let revision: UInt64
    public let data: Data
    public let capturedAt: Date

    public init(
        id: UUID = UUID(),
        width: Int,
        height: Int,
        revision: UInt64,
        data: Data,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.stride = width * 4
        self.revision = revision
        self.data = data
        self.capturedAt = capturedAt
    }

    public var byteCount: Int { data.count }
}

/// A retained immutable frame. The caller releases the lease after copying
/// the bytes; a closed session drops every lease without touching the Data.
public final class RDPFloeFrameLease: @unchecked Sendable {
    public let id: UUID
    public let frame: RDPFloeFrame

    public init(id: UUID = UUID(), frame: RDPFloeFrame) {
        self.id = id
        self.frame = frame
    }
}

public enum RDPFloeFrameBounds {
    public static let maximumEdge = 4_096
    public static let maximumBytes = 32 * 1_024 * 1_024
    public static let maximumLeasesPerSession = 4
    public static let maximumGlobalLeases = 8

    public static func validate(width: Int, height: Int) -> RDPFloeFailure? {
        guard width > 0, height > 0 else {
            return RDPFloeFailure(
                category: .framebufferTooLarge,
                stage: .framebuffer,
                retryable: false,
                message: "The RDP framebuffer dimensions are invalid."
            )
        }
        guard width <= maximumEdge, height <= maximumEdge else {
            return RDPFloeFailure(
                category: .framebufferTooLarge,
                stage: .framebuffer,
                retryable: false,
                message: "The RDP framebuffer exceeds the 4096-pixel edge limit."
            )
        }
        let (product, overflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, overflowBytes) = product.multipliedReportingOverflow(by: 4)
        guard !overflow, !overflowBytes, bytes <= maximumBytes else {
            return RDPFloeFailure(
                category: .framebufferTooLarge,
                stage: .framebuffer,
                retryable: false,
                message: "The RDP framebuffer exceeds the 32 MiB limit."
            )
        }
        return nil
    }
}

public enum RDPFloePointerButton: String, Sendable, CaseIterable, Equatable {
    case left
    case middle
    case right
}

/// One explicit protocol input. Keyboard values are RDP scancodes (the same
/// public protocol bitfields the C bridge forwards), not platform key codes.
public enum RDPFloeInputEvent: Sendable, Equatable {
    case pointerMove(x: UInt16, y: UInt16)
    case pointerButton(button: RDPFloePointerButton, down: Bool, x: UInt16, y: UInt16)
    case wheel(up: Bool, x: UInt16, y: UInt16, steps: UInt32)
    case key(scancode: UInt8, extended: Bool, down: Bool)
    case text(String)
}

/// Named RDP keys expressed as the protocol scancode/extended bitfield. The
/// same table is used by the UI bridge and the ordinary model tools.
public enum RDPFloeKey {
    public static func scancode(named name: String) -> (scancode: UInt8, extended: Bool)? {
        switch name.lowercased() {
        case "return", "enter": return (0x1C, false)
        case "tab": return (0x0F, false)
        case "escape", "esc": return (0x01, false)
        case "space": return (0x39, false)
        case "backspace": return (0x0E, false)
        case "delete", "forwarddelete": return (0x53, true)
        case "left": return (0x4B, true)
        case "right": return (0x4D, true)
        case "up": return (0x48, true)
        case "down": return (0x50, true)
        case "pageup": return (0x49, true)
        case "pagedown": return (0x51, true)
        case "home": return (0x47, true)
        case "end": return (0x4F, true)
        case "insert": return (0x52, true)
        case "f1": return (0x3B, false)
        case "f2": return (0x3C, false)
        case "f3": return (0x3D, false)
        case "f4": return (0x3E, false)
        case "f5": return (0x3F, false)
        case "f6": return (0x40, false)
        case "f7": return (0x41, false)
        case "f8": return (0x42, false)
        case "f9": return (0x43, false)
        case "f10": return (0x44, false)
        case "f11": return (0x57, false)
        case "f12": return (0x58, false)
        default: return nil
        }
    }

    public static func namedKeyEvents(_ name: String) -> [RDPFloeInputEvent]? {
        guard let key = scancode(named: name) else { return nil }
        return [
            .key(scancode: key.scancode, extended: key.extended, down: true),
            .key(scancode: key.scancode, extended: key.extended, down: false),
        ]
    }

    public static func modifierEvents(_ name: String, down: Bool) -> [RDPFloeInputEvent]? {
        let key: (scancode: UInt8, extended: Bool)
        switch name.lowercased() {
        case "shift": key = (0x2A, false)
        case "rightshift": key = (0x36, false)
        case "control", "ctrl": key = (0x1D, false)
        case "alt", "option": key = (0x38, false)
        case "meta", "command", "win": key = (0x5B, true)
        default: return nil
        }
        return [.key(scancode: key.scancode, extended: key.extended, down: down)]
    }
}

/// Cross-protocol pixel/input contract shared with the remote-desktop model
/// tools. Protocol negotiation and credentials stay with each transport.
public protocol RDPFloeSessionDriving: AnyObject, Sendable {
    var currentState: RDPFloeState { get }
    var isConnected: Bool { get }
    var framebufferSize: (width: Int, height: Int)? { get }
    var latestFrameRevision: UInt64 { get }
    var latestFrameByteCount: Int { get }
    var certificateChallenge: RDPCertificateChallenge? { get }

    func connect()
    func releaseAllInput()
    func close(timeout: TimeInterval) async -> Bool
    func currentFrame() -> RDPFloeFrame?
    func acquireFrame() throws -> RDPFloeFrameLease
    func releaseFrame(_ id: UUID)
    func send(_ events: [RDPFloeInputEvent]) throws
}
