// SPDX-License-Identifier: MPL-2.0
import Foundation

/// In-memory, bounded checkpoint ring. It is a recovery aid for the current
/// live run, not project storage: a checkpoint never writes into the game root,
/// original archive, Git repository or save service.
public struct GameDeveloperCheckpointStore: Sendable {
    public let maximumCount: Int
    public let maximumBytes: Int
    public private(set) var checkpoints: [GameDeveloperCheckpoint] = []

    public init(maximumCount: Int, maximumBytes: Int) {
        self.maximumCount = max(1, maximumCount)
        self.maximumBytes = max(1_024, maximumBytes)
    }

    public func checkpoint(_ id: UUID) -> GameDeveloperCheckpoint? {
        checkpoints.first { $0.id == id }
    }

    public var totalBytes: Int {
        checkpoints.reduce(0) { $0 + $1.byteCount }
    }

    public var baseline: GameDeveloperCheckpoint? {
        checkpoints.last { $0.kind == .baseline }
    }

    /// Adds a checkpoint, evicting the oldest non-baseline entries first. A
    /// baseline is retained until explicitly cleared. An oversized single
    /// checkpoint is rejected by the caller before this method.
    public mutating func insert(_ checkpoint: GameDeveloperCheckpoint) {
        checkpoints.append(checkpoint)
        while checkpoints.count > maximumCount || totalBytes > maximumBytes {
            guard let index = checkpoints.firstIndex(where: { $0.kind != .baseline }) else { break }
            if checkpoints[index].id == checkpoint.id { break }
            checkpoints.remove(at: index)
        }
    }

    public mutating func removeAll() {
        checkpoints.removeAll()
    }

    public mutating func remove(_ id: UUID) {
        checkpoints.removeAll { $0.id == id && $0.kind != .baseline }
    }
}
