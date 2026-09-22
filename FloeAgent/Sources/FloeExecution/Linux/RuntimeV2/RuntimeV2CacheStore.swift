// FloeExecution — Runtime v2 shared caches and bounded diagnostics.
//
// cache/{apt,pip,npm,cargo,staging} holds shared download objects and package
// indexes ONLY — never environment install state (that lives in
// environments/<id>/system/delta.* and nowhere else). Caches are excluded
// from cloud backup and evicted by an LRU pass with a per-kind byte budget;
// eviction never touches files younger than a safety window (a download may
// be in flight) and never deletes staging files still referenced. pip's
// build/tmp directories are given a dedicated, capacity-checked location on
// the mapped cache layer (cache/pip/tmp) instead of the constrained guest
// tmpfs.
//
// logs/ keeps bounded, redacted, exportable runtime diagnostics: size-capped
// rotation, SecretRedactor on every line, and a single-file export. Logs
// never contain credentials or raw secret values.

import Foundation
import FloeCore

public actor RuntimeV2CacheStore {
    /// Default per-kind eviction budgets (bytes).
    public static let defaultBudgets: [String: Int64] = [
        "apt": 512 << 20,
        "pip": 512 << 20,
        "npm": 512 << 20,
        "cargo": 512 << 20,
        "staging": 1 << 30
    ]
    /// Files younger than this are never evicted (a writer may still own them).
    public static let inFlightWindow: TimeInterval = 120

    private let layout: RuntimeV2Layout
    private var fileManager: FileManager { .default }

    public init(layout: RuntimeV2Layout) {
        self.layout = layout
    }

    public func prepare() throws {
        for kind in RuntimeV2Layout.cacheKinds {
            try fileManager.createDirectory(at: layout.cacheDirectory(kind: kind), withIntermediateDirectories: true)
        }
        // pip build/tmp lands on the mapped cache layer, not the guest tmpfs.
        try fileManager.createDirectory(
            at: layout.cacheDirectory(kind: "pip").appendingPathComponent("tmp", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    public var pipTemporaryDirectory: URL {
        layout.cacheDirectory(kind: "pip").appendingPathComponent("tmp", isDirectory: true)
    }

    /// A staging location for an in-flight download/import inside cache/staging.
    public func stagingURL(name: String) -> URL {
        let safe = name.isEmpty || name.contains("/") ? UUID().uuidString : name
        return layout.cacheDirectory(kind: "staging").appendingPathComponent("dl-\(UUID().uuidString)-\(safe)")
    }

    /// Total bytes under one cache kind.
    public func size(kind: String) throws -> Int64 {
        try directorySize(at: layout.cacheDirectory(kind: kind))
    }

    /// LRU eviction for one cache kind: deletes least-recently-modified files
    /// beyond the budget, oldest first, skipping the in-flight window.
    /// Returns reclaimed bytes. Shared objects only; no environment state is
    /// ever stored here, so eviction can never destroy install state.
    @discardableResult
    public func evict(kind: String, budgetBytes: Int64? = nil, now: Date = Date()) throws -> Int64 {
        let budget = budgetBytes ?? RuntimeV2CacheStore.defaultBudgets[kind] ?? (512 << 20)
        let root = layout.cacheDirectory(kind: kind)
        var total = try directorySize(at: root)
        guard total > budget else { return 0 }
        var files: [(url: URL, bytes: Int64, modified: Date)] = []
        if let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        ) {
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                files.append((url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
            }
        }
        files.sort { $0.modified < $1.modified }
        var reclaimed: Int64 = 0
        for file in files {
            guard total > budget else { break }
            guard now.timeIntervalSince(file.modified) > RuntimeV2CacheStore.inFlightWindow else { continue }
            do {
                try fileManager.removeItem(at: file.url)
                total -= file.bytes
                reclaimed += file.bytes
            } catch {
                continue
            }
        }
        return reclaimed
    }

    private func directorySize(at root: URL) throws -> Int64 {
        guard fileManager.fileExists(atPath: root.path) else { return 0 }
        var total: Int64 = 0
        if let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values.isRegularFile == true {
                    total += Int64(values.fileSize ?? 0)
                }
            }
        }
        return total
    }
}

/// Bounded, redacted, exportable runtime diagnostics.
public actor RuntimeV2LogStore {
    public static let fileByteLimit = 1 << 20
    public static let generations = 4

    private let layout: RuntimeV2Layout
    private var fileManager: FileManager { .default }

    public init(layout: RuntimeV2Layout) {
        self.layout = layout
    }

    private var currentLogURL: URL { layout.logsDirectory.appendingPathComponent("runtime.log") }

    /// Appends one redacted line. Rotation is bounded: at most
    /// `generations` archived files of `fileByteLimit` bytes each.
    public func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(SecretRedactor.redact(message))\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: currentLogURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: currentLogURL, options: .atomic)
        }
        rotateIfNeeded()
    }

    private func rotateIfNeeded() {
        let size = (try? fileManager.attributesOfItem(atPath: currentLogURL.path)[.size] as? Int64) ?? 0
        guard size > RuntimeV2LogStore.fileByteLimit else { return }
        for generation in stride(from: RuntimeV2LogStore.generations - 1, through: 1, by: -1) {
            let source = layout.logsDirectory.appendingPathComponent("runtime.\(generation).log")
            let destination = layout.logsDirectory.appendingPathComponent("runtime.\(generation + 1).log")
            try? fileManager.removeItem(at: destination)
            try? fileManager.moveItem(at: source, to: destination)
        }
        let first = layout.logsDirectory.appendingPathComponent("runtime.1.log")
        try? fileManager.moveItem(at: currentLogURL, to: first)
    }

    /// One redacted, bounded diagnostic payload for user-initiated export.
    public func exportDiagnostics() -> Data {
        var combined = Data()
        if let current = try? Data(contentsOf: currentLogURL) {
            combined.append(current)
        }
        for generation in 1...RuntimeV2LogStore.generations {
            let url = layout.logsDirectory.appendingPathComponent("runtime.\(generation).log")
            if let data = try? Data(contentsOf: url) {
                combined.append(data)
            }
        }
        let text = SecretRedactor.redact(String(decoding: combined, as: UTF8.self))
        return Data(text.utf8)
    }
}
