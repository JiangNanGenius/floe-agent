// SPDX-License-Identifier: MPL-2.0
//
// FloeVNC — Android port of the fixed public FloeVNC donor
// (FloeAgent/Sources/FloeVNC @ a59b4d4005f616c611df67fab7620e9853c525b9).
//
// This target is protocol/transport only: RoyalVNCKit performs the real RFB
// handshake, authentication, encodings and framebuffer mutation. FloeVNC
// adds an Android-lifetime session shell, a bounded immutable RGBA frame
// lease, and explicit pointer/keyboard/wheel input. There is no UIKit,
// CoreGraphics, Metal or screenshot-refresh fallback here.

import Foundation

public enum VNCFloeFailureCategory: String, Sendable, Equatable {
    case configurationMissing
    case credentialMissing
    case authenticationFailed
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
}

public enum VNCFloeFailureStage: String, Sendable, Equatable {
    case configuration
    case credentialResolution
    case transport
    case authentication
    case handshake
    case framebuffer
    case input
}

/// Secret-free VNC failure value. It never carries a password, credential
/// body or server fingerprint.
public struct VNCFloeFailure: Error, Sendable, Equatable, LocalizedError {
    public let category: VNCFloeFailureCategory
    public let stage: VNCFloeFailureStage
    public let retryable: Bool
    public let message: String
    public let underlyingCode: String?

    public init(
        category: VNCFloeFailureCategory,
        stage: VNCFloeFailureStage,
        retryable: Bool,
        message: String,
        underlyingCode: String? = nil
    ) {
        self.category = category
        self.stage = stage
        self.retryable = retryable
        self.message = message
        self.underlyingCode = underlyingCode
    }

    public var errorDescription: String? { message }
}

public enum VNCFloeState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case closing
    case failed(VNCFloeFailure)

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
public struct VNCFloeFrame: Sendable, Equatable {
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

public struct VNCFloeFrameLease: Sendable, Equatable {
    public let id: UUID
    public let frame: VNCFloeFrame

    public init(id: UUID = UUID(), frame: VNCFloeFrame) {
        self.id = id
        self.frame = frame
    }
}

public enum VNCFloePointerButton: String, Sendable, Equatable, CaseIterable {
    case left
    case middle
    case right
}

public enum VNCFloeWheelAxis: String, Sendable, Equatable {
    case up
    case down
    case left
    case right
}

public enum VNCFloeInputEvent: Sendable, Equatable {
    case pointerMove(x: Int, y: Int)
    case pointerButton(button: VNCFloePointerButton, down: Bool, x: Int, y: Int)
    case wheel(axis: VNCFloeWheelAxis, steps: Int, x: Int, y: Int)
    case key(keysym: UInt32, down: Bool)
    case text(String)
}

/// Session surface consumed by the Android host domain. `VNCFloeSession` is
/// the production implementation; tests inject a deterministic fake without
/// replacing RoyalVNCKit in production.
public protocol VNCFloeSessionDriving: AnyObject, Sendable {
    var currentState: VNCFloeState { get }
    var isConnected: Bool { get }
    var framebufferSize: (width: Int, height: Int)? { get }
    var latestFrameRevision: UInt64 { get }
    var latestFrameByteCount: Int { get }

    func connect()
    func releaseAllInput()
    func close(timeout: TimeInterval) async -> Bool
    func currentFrame() -> VNCFloeFrame?
    func acquireFrame() throws -> VNCFloeFrameLease
    func releaseFrame(_ id: UUID)
    func send(_ events: [VNCFloeInputEvent]) throws
}
