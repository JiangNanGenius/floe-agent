// FloeAndroid shared/Sources/FloeBrowser — bounded Floe-owned screenshot
// evidence store.
//
// Port of the iOS `BrowserTaskSession.saveSnapshot` persistence half and
// `BrowserSessionCenter.cleanupArtifacts` (BrowserSessionCenter.swift /
// BrowserTaskSessionStore.swift @ 3fd597b…). Deltas: the directory comes from
// the injected configuration (Main's native sandbox path), never
// `.applicationSupportDirectory`; images arrive as bytes from the renderer
// instead of UIImage; retention bounds are identical (128 files / 24 h,
// regular .jpg files whose base name is a UUID — Floe-owned names only).

import Foundation
import FloeCore

public struct BrowserArtifactStore: Sendable {
    public let directory: URL
    public let maximumArtifacts: Int
    public let retentionSeconds: TimeInterval

    public init(directory: URL, maximumArtifacts: Int = 128, retentionSeconds: TimeInterval = 24 * 60 * 60) {
        self.directory = directory
        self.maximumArtifacts = max(1, maximumArtifacts)
        self.retentionSeconds = retentionSeconds
    }

    /// Atomic write of one bounded JPEG under a fresh UUID name. Returns the
    /// evidence reference (relative path is Floe-root-relative, mirroring the
    /// original "BrowserArtifacts/<name>" shape).
    public func store(jpeg: Data, pixelWidth: Int, pixelHeight: Int) throws -> BrowserArtifactReference {
        guard !jpeg.isEmpty, jpeg.count <= 8 * 1024 * 1024 else {
            throw BrowserPolicyError.blocked("The viewport snapshot exceeds 8 MiB")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let name = "\(id.uuidString).jpg"
        try jpeg.write(to: directory.appendingPathComponent(name), options: .atomic)
        return BrowserArtifactReference(
            id: id,
            relativePath: "BrowserArtifacts/\(name)",
            mimeType: "image/jpeg",
            byteCount: jpeg.count,
            sha256: FloeDigest.sha256Hex(jpeg),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    public func read(_ reference: BrowserArtifactReference) -> Data? {
        let filename = (reference.relativePath as NSString).lastPathComponent
        guard Self.isFloeOwnedName(filename) else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(filename))
    }

    /// Keep a bounded recent set and remove stale Floe-owned artifacts
    /// without touching user files.
    public func sweep(now: Date = Date()) {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = now.addingTimeInterval(-retentionSeconds)
        let files = urls.compactMap { url -> (URL, Date)? in
            guard url.pathExtension.lowercased() == "jpg",
                  Self.isFloeOwnedName(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (index, file) in files.enumerated() where index >= maximumArtifacts || file.1 < cutoff {
            try? manager.removeItem(at: file.0)
        }
    }

    static func isFloeOwnedName(_ name: String) -> Bool {
        guard name.hasSuffix(".jpg") else { return false }
        let stem = String(name.dropLast(4))
        return UUID(uuidString: stem) != nil
    }
}
