import Foundation

/// Invalidates asynchronous launch work without requiring the invalidating
/// operation to wait for an uncooperative dependency to return.
public struct LaunchEpochFence: Sendable {
    public struct Token: Sendable, Equatable {
        fileprivate let globalEpoch: UInt64
        fileprivate let scope: UUID?
        fileprivate let scopedEpoch: UInt64
    }

    private var globalEpoch: UInt64 = 0
    private var scopedEpochs: [UUID: UInt64] = [:]

    public init() {}

    public func issue(scope: UUID? = nil) -> Token {
        Token(
            globalEpoch: globalEpoch,
            scope: scope,
            scopedEpoch: scope.map { scopedEpochs[$0, default: 0] } ?? 0
        )
    }

    public func isValid(_ token: Token) -> Bool {
        guard token.globalEpoch == globalEpoch else { return false }
        guard let scope = token.scope else { return true }
        return token.scopedEpoch == scopedEpochs[scope, default: 0]
    }

    public mutating func invalidate(scope: UUID) {
        scopedEpochs[scope, default: 0] &+= 1
    }

    public mutating func invalidateAll() {
        globalEpoch &+= 1
    }
}
