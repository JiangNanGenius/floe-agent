import Foundation

/// Small, bounded, secret-free log used by the host and the embedded engine.
///
/// The log is written with POSIX append so host and test code can share it
/// without a `FileHandle` lifetime problem. It never accepts pairing records,
/// tokens or packet payloads; callers pass status facts only.
public final class BridgeLog: @unchecked Sendable {
    public static let shared = BridgeLog()

    private let lock = NSLock()
    private let maximumBytes: Int
    private var url: URL?

    public init(maximumBytes: Int = 1_048_576) {
        self.maximumBytes = maximumBytes
    }

    public func configure(url: URL) {
        lock.lock()
        self.url = url
        lock.unlock()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    public func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let url else { return }
        let timestamp = BridgeClock.timestamp()
        let pid = ProcessInfo.processInfo.processIdentifier
        let line = "\(timestamp) pid=\(pid) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
           size.intValue > maximumBytes {
            let rotated = url.deletingPathExtension().appendingPathExtension("1.log")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: url, to: rotated)
        }

        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = write(descriptor, base.advanced(by: offset), data.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
        fsync(descriptor)
    }

    public func tail(maxBytes: Int = 32_768) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let url else { return "" }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

public enum BridgeClock {
    public static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
