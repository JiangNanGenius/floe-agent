import Foundation

/// Content growth is not a user scroll. Keep follow intent separate from
/// return-button visibility, including while the new tail awaits layout.
public struct LatestMessageFollowState: Sendable, Equatable {
    public private(set) var followsLatest = true
    public private(set) var isAwayFromLatest = false
    private var previousOffset: Double?
    public init() {}

    public mutating func returnToLatest() { followsLatest = true }

    public mutating func observe(offset: Double, bottomDistance: Double, userScrolling: Bool) {
        isAwayFromLatest = bottomDistance > 48
        if userScrolling {
            if bottomDistance <= 48 {
                followsLatest = true
            } else if let previousOffset, offset < previousOffset - 0.5 {
                followsLatest = false
            }
        }
        previousOffset = offset
    }
}
