import libgit2

public typealias TransferProgressHandler = (TransferProgress) -> Void

public struct TransferProgress {
    /// The number of objects that the pack will contain.
    public let totalObjects: Int

    /// The number of objects that the pack has indexed.
    public let indexedObjects: Int

    /// The number of objects that the pack has received.
    public let receivedObjects: Int

    /// The number of local objects that the pack has.
    public let localObjects: Int

    /// The number of deltas that the pack will contain.
    public let totalDeltas: Int

    /// The number of bytes that the pack has indexed.
    public let indexedDeltas: Int

    /// The number of bytes that the pack has received.
    public let receivedBytes: Int

    init(from stats: git_indexer_progress) {
        totalObjects = Int(stats.total_objects)
        indexedObjects = Int(stats.indexed_objects)
        receivedObjects = Int(stats.received_objects)
        localObjects = Int(stats.local_objects)
        totalDeltas = Int(stats.total_deltas)
        indexedDeltas = Int(stats.indexed_deltas)
        receivedBytes = Int(stats.received_bytes)
    }
}
