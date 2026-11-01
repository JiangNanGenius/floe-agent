import Foundation

/// An ephemeral screen image crossing from the XCTest bundle to the host.
/// No UIKit or XCTest type crosses this boundary, and frames are not saved.
public struct BridgeScreenFrame: Sendable {
    public enum Encoding: String, Sendable {
        case jpeg
        case png
    }

    public let imageData: Data
    public let encoding: Encoding
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let pointWidth: Double
    public let pointHeight: Double
    public let capturedAt: Date

    public init(imageData: Data, encoding: Encoding,
                pixelWidth: Int, pixelHeight: Int,
                pointWidth: Double, pointHeight: Double,
                capturedAt: Date = Date()) {
        self.imageData = imageData
        self.encoding = encoding
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.capturedAt = capturedAt
    }
}

public protocol BridgeScreenFrameProvider: Sendable {
    /// A thread-safe observation; this getter must not call XCTest.
    var frameCaptureReady: Bool { get }

    /// Capture through the SAME SDK serialization gate used for RPC actions.
    /// Return nil while an action owns that gate, while stopped or when locked.
    /// Streaming must never start a second XCTest session or persist a frame.
    func captureFrame() async -> BridgeScreenFrame?
}

/// Retains the single process-lifetime capture provider. A listener restart
/// cannot replace it, just as it cannot replace the automation executor.
public final class BridgeScreenFrameRegistry: @unchecked Sendable {
    private let lock = BridgeRPCLock()
    private var owner: String?
    private var provider: (any BridgeScreenFrameProvider)?

    public init() {}

    @discardableResult
    public func register(owner newOwner: String,
                         provider newProvider: any BridgeScreenFrameProvider) -> Bool {
        lock.withLock {
            if let owner { return owner == newOwner }
            owner = newOwner
            provider = newProvider
            return true
        }
    }

    public func currentProvider() -> (any BridgeScreenFrameProvider)? {
        lock.withLock { provider }
    }

    public var isReady: Bool {
        currentProvider()?.frameCaptureReady == true
    }
}

/// Host and embedded test bundle resolve this exact shared-framework instance.
/// The tunnel has its own process and never registers an automation provider.
public enum BridgeRuntime {
    public static let engineRegistry = BridgeRPCEngineRegistry()
    public static let screenFrames = BridgeScreenFrameRegistry()
}
