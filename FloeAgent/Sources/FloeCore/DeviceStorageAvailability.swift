import Foundation

/// Device-volume capacity, separate from Floe's per-category storage census.
/// This is a cheap read, not a scan or a reservation. Unknown stays unknown.
public struct DeviceStorageAvailability: Sendable, Equatable {
    public enum Level: Int, Sendable, Comparable {
        case normal, low, critical
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public static let lowBytes: Int64 = 1_024 * 1_024 * 1_024
    public static let criticalBytes: Int64 = 256 * 1_024 * 1_024
    public let availableBytes: Int64?

    public init(availableBytes: Int64?) {
        self.availableBytes = availableBytes.flatMap { $0 >= 0 ? $0 : nil }
    }

    public var level: Level {
        guard let availableBytes else { return .normal }
        if availableBytes < Self.criticalBytes { return .critical }
        return availableBytes < Self.lowBytes ? .low : .normal
    }

    public static func read(at url: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Self {
        // Use currently free bytes for the warning; purgeable "important
        // usage" capacity is not proof that SQLite can write right now.
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let bytes = values.volumeAvailableCapacity {
            return Self(availableBytes: Int64(bytes))
        }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
        return Self(availableBytes: (attributes?[.systemFreeSize] as? NSNumber)?.int64Value)
    }

    public var formattedAvailable: String? {
        availableBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}

/// Typed, bounded inspection only. A generic I/O/permission/corruption error
/// must never be relabelled "disk full" just because the device is low.
public enum StorageSpaceFailure {
    public static let notification = Notification.Name("org.floeagent.storage.writeOutOfSpace")

    public static func matches(_ error: Error) -> Bool {
        var pending = [error as NSError]
        var visited = Set<ObjectIdentifier>()
        var inspected = 0
        while let current = pending.popLast(), inspected < 32 {
            guard visited.insert(ObjectIdentifier(current)).inserted else { continue }
            inspected += 1
            if current.domain == NSCocoaErrorDomain && current.code == 640 { return true }
            if current.domain == NSPOSIXErrorDomain && (current.code == 28 || current.code == 69) { return true }
            // GRDB's CustomNSError uses the extended SQLite result code.
            if current.domain == "GRDB.DatabaseError" && current.code & 0xff == 13 { return true }
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                pending.append(underlying)
            }
            if let multiple = current.userInfo["NSMultipleUnderlyingErrors"] as? [NSError] {
                pending.append(contentsOf: multiple.prefix(32))
            }
        }
        return false
    }

    /// No error, SQL, file path or user content crosses this notification.
    /// Callers preserve and rethrow the original error/transaction outcome.
    @discardableResult
    public static func reportIfNeeded(_ error: Error) -> Bool {
        guard matches(error) else { return false }
        NotificationCenter.default.post(name: notification, object: nil)
        return true
    }
}
