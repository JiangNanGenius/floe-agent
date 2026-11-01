import Foundation

/// Start/stop epoch for the packet-tunnel read loop.
///
/// The provider applies network settings asynchronously. A Stop may arrive
/// while that completion is still pending; `completeStart` is the fence that
/// prevents the late completion from resurrecting the tunnel. This value type
/// is exercised directly by the host checks.
public struct BridgeTunnelRunState: Equatable, Sendable {
    public private(set) var epoch: UInt64 = 0
    public private(set) var shouldRun = false
    public private(set) var readLoopActive = false

    public init() {}

    public mutating func beginStart() -> UInt64 {
        epoch &+= 1
        shouldRun = true
        readLoopActive = false
        return epoch
    }

    public mutating func completeStart(_ expectedEpoch: UInt64) -> Bool {
        guard shouldRun, epoch == expectedEpoch, !readLoopActive else { return false }
        readLoopActive = true
        return true
    }

    public mutating func stop() {
        epoch &+= 1
        shouldRun = false
        readLoopActive = false
    }

    public func allowsRead(epoch expectedEpoch: UInt64) -> Bool {
        shouldRun && readLoopActive && epoch == expectedEpoch
    }
}
