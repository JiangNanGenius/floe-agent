// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — explicit-root design persistence.
//
// Everything here is rooted under the accepted `RuntimeStorageRoot`
// (`<root>/FloeAgent/...`). There is no Application Support / convenience
// root, no parallel project database and no caller-selected path. Owner
// envelope CAS, immutable revision payloads, preview/export receipts and the
// decision outbox are the same physical authority the rest of the creative
// runtime uses.
import Foundation
import FloeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum G09R2DesignStoreError: Error, Equatable {
    case invalidKey(String)
    case corrupt(String)
    case conflict(expected: Int64, actual: Int64)
    case tooLarge(Int)
    case writeFailed
}

enum G09R2DesignFileIO {
    static func containedURL(root: URL, relative: String) -> URL? {
        guard !relative.isEmpty, !relative.hasPrefix("/"),
              !relative.hasPrefix("\\"), !relative.contains("\u{0}") else {
            return nil
        }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }
        for component in components {
            guard !component.isEmpty, component != ".", component != "..",
                  !component.contains("\\") else { return nil }
        }
        let base = root.standardizedFileURL
        let target = relative.split(separator: "/").reduce(base) { partial, component in
            partial.appendingPathComponent(String(component))
        }.standardizedFileURL
        guard target.path == base.path || target.path.hasPrefix(base.path + "/") else {
            return nil
        }
        return target
    }

    static func readBounded(_ url: URL, maxBytes: Int) throws -> Data {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize, size > maxBytes {
            throw G09R2DesignStoreError.tooLarge(size)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw G09R2DesignStoreError.corrupt("readFailed")
        }
        guard data.count <= maxBytes else {
            throw G09R2DesignStoreError.tooLarge(data.count)
        }
        return data
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            throw G09R2DesignStoreError.writeFailed
        }
        let temporary = directory.appendingPathComponent(
            ".floe-design-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: [])
            fsyncFile(temporary)
            if rename(temporary.path, url.path) != 0 {
                throw G09R2DesignStoreError.writeFailed
            }
            fsyncDirectory(directory)
        } catch let typed as G09R2DesignStoreError {
            try? FileManager.default.removeItem(at: temporary)
            throw typed
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw G09R2DesignStoreError.writeFailed
        }
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func fsyncFile(_ url: URL) {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }

    private static func fsyncDirectory(_ url: URL) {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }
}

// MARK: - Owner envelope CAS

/// One envelope file examined by the bounded pending-request scan.
struct G09R2DesignStoredEnvelopeEntry: Sendable {
    let envelope: DesignOwnerEnvelope
    let modifiedAtMS: Int64
}

/// Bounded page of stored creative-request envelopes. `lastExamined*` is the
/// keyset cursor of the last file actually read (not necessarily the last
/// match), so the next page can continue without skipping entries.
struct G09R2DesignCreativeRequestScan: Sendable {
    let entries: [G09R2DesignStoredEnvelopeEntry]
    let lastExaminedMS: Int64?
    let lastExaminedKey: String?
    let exhausted: Bool

    static let empty = G09R2DesignCreativeRequestScan(
        entries: [], lastExaminedMS: nil, lastExaminedKey: nil,
        exhausted: true)
}

/// `DesignOwnerProjectStore` over an explicit directory. The target key is the
/// shared `DesignTarget.stableKey` SHA-256; a stored envelope is accepted only
/// when its target stable key still matches the addressed key.
public actor G09R2DesignOwnerProjectStore: DesignOwnerProjectStore {
    public static let maximumEnvelopeBytes = G09R2CreativeLimits.canvasProjectBytes

    private let directoryURL: URL

    public init(root: RuntimeStorageRoot) {
        self.directoryURL = root.artifactStoreURL
            .appendingPathComponent("DesignRevisions", isDirectory: true)
            .appendingPathComponent("owners", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    public func load(targetKey: String) async throws -> DesignOwnerEnvelope? {
        let url = try url(for: targetKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try G09R2DesignFileIO.readBounded(
            url, maxBytes: Self.maximumEnvelopeBytes)
        let envelope: DesignOwnerEnvelope
        do {
            envelope = try G09CreativeWire.decoder().decode(
                DesignOwnerEnvelope.self, from: data)
        } catch {
            throw G09R2DesignStoreError.corrupt("ownerEnvelopeDecode")
        }
        guard envelope.target.stableKey == targetKey,
              envelope.project.nodeID == targetKey else {
            throw G09R2DesignStoreError.corrupt("ownerEnvelopeBinding")
        }
        return envelope
    }

    /// Every stored owner envelope whose creative request binds this exact
    /// reference as its first result, or whose frozen source identity IS this
    /// reference. This reads the REAL persisted identity fields and is bounded
    /// to the existing `projects` directory (1024 entries). Corrupt/unreadable
    /// records are skipped: the creative owner port requires a positive hit,
    /// so a broken file can never widen access. This is a read-only scan of the
    /// SAME envelope store the workflow writes — no parallel request index.
    public func envelopes(matchingReference reference: String) async -> [DesignOwnerEnvelope] {
        guard !reference.isEmpty, reference.utf8.count <= 1024 else { return [] }
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var matches: [DesignOwnerEnvelope] = []
        for url in entries.prefix(1024) {
            guard url.pathExtension == "json" else { continue }
            guard let data = try? G09R2DesignFileIO.readBounded(
                url, maxBytes: Self.maximumEnvelopeBytes),
                let envelope = try? G09CreativeWire.decoder().decode(
                    DesignOwnerEnvelope.self, from: data) else { continue }
            let bindsReference = envelope.project.creativeRequest?
                .boundResultID == reference
            let isSource = envelope.target.sourceID == reference
            if bindsReference || isSource {
                matches.append(envelope)
            }
        }
        return matches
    }

    /// Bounded reopen scan over the SAME envelope files. Ordered by the write
    /// that advances `updatedAt` (file modification time) with the stable
    /// target key as tiebreak; at most `maxReads` envelopes are decoded per
    /// page. Only envelopes that actually carry a `DesignCreativeRequest` are
    /// returned; the caller receives the exact target/owner revision so it can
    /// reopen through the ordinary `bindTarget` path (no second request store).
    ///
    /// `afterMS`/`afterKey` are a keyset cursor produced from the last examined
    /// entry, so a page is stable under concurrent inserts/removals of older
    /// entries and cannot silently skip the next entry.
    func scanCreativeRequests(
        limit: Int,
        maxReads: Int,
        afterMS: Int64?,
        afterKey: String?
    ) async -> G09R2DesignCreativeRequestScan {
        guard limit > 0, maxReads > 0 else {
            return .empty
        }
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [
                .isRegularFileKey, .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]) else {
            return .empty
        }
        var candidates: [(url: URL, ms: Int64, key: String)] = []
        for url in urls.prefix(1024) {
            guard url.pathExtension == "json" else { continue }
            let key = url.deletingPathExtension().lastPathComponent
            guard Self.isStableKey(key) else { continue }
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey])
            let modified = values?.contentModificationDate ?? .distantPast
            candidates.append((
                url: url,
                ms: Int64((modified.timeIntervalSince1970 * 1000)
                    .rounded(.down)),
                key: key))
        }
        candidates.sort { lhs, rhs in
            if lhs.ms != rhs.ms { return lhs.ms > rhs.ms }
            return lhs.key > rhs.key
        }
        var index = 0
        if let afterMS, let afterKey {
            index = candidates.firstIndex {
                $0.ms < afterMS || ($0.ms == afterMS && $0.key < afterKey)
            } ?? candidates.count
        }
        var entries: [G09R2DesignStoredEnvelopeEntry] = []
        var lastMS: Int64?
        var lastKey: String?
        var reads = 0
        while index < candidates.count,
              reads < maxReads,
              entries.count < limit {
            let candidate = candidates[index]
            index += 1
            reads += 1
            lastMS = candidate.ms
            lastKey = candidate.key
            guard let data = try? G09R2DesignFileIO.readBounded(
                candidate.url, maxBytes: Self.maximumEnvelopeBytes),
                let envelope = try? G09CreativeWire.decoder().decode(
                    DesignOwnerEnvelope.self, from: data),
                envelope.target.stableKey == candidate.key,
                envelope.project.nodeID == candidate.key,
                envelope.target.kind == .creativeDocument,
                envelope.project.creativeRequest != nil else {
                continue
            }
            entries.append(G09R2DesignStoredEnvelopeEntry(
                envelope: envelope, modifiedAtMS: candidate.ms))
        }
        return G09R2DesignCreativeRequestScan(
            entries: entries,
            lastExaminedMS: lastMS,
            lastExaminedKey: lastKey,
            exhausted: index >= candidates.count)
    }

    public func save(
        _ envelope: DesignOwnerEnvelope,
        targetKey: String,
        expectedRevision: Int64?
    ) async throws -> Int64 {
        guard envelope.target.stableKey == targetKey else {
            throw G09R2DesignStoreError.corrupt("ownerEnvelopeBinding")
        }
        let url = try url(for: targetKey)
        let existing = try await load(targetKey: targetKey)
        var next = envelope
        if let existing {
            if let expectedRevision, existing.revision != expectedRevision {
                throw G09R2DesignStoreError.conflict(
                    expected: expectedRevision, actual: existing.revision)
            }
            guard expectedRevision != nil else {
                throw G09R2DesignStoreError.conflict(
                    expected: existing.revision, actual: existing.revision)
            }
            next.revision = existing.revision + 1
        } else {
            if let expectedRevision, expectedRevision != 0 {
                throw G09R2DesignStoreError.conflict(expected: expectedRevision, actual: 0)
            }
            next.revision = expectedRevision == nil ? 0 : 1
        }
        next.updatedAt = Date()
        try write(next, to: url)
        return next.revision
    }

    /// Create the explicit envelope without advancing a revision. `bindTarget`
    /// uses this; ordinary workflow mutations go through `save` and always
    /// advance exactly once.
    public func createInitial(
        _ envelope: DesignOwnerEnvelope,
        targetKey: String
    ) async throws -> DesignOwnerEnvelope {
        guard envelope.target.stableKey == targetKey else {
            throw G09R2DesignStoreError.corrupt("ownerEnvelopeBinding")
        }
        let url = try url(for: targetKey)
        if FileManager.default.fileExists(atPath: url.path) {
            if let existing = try await load(targetKey: targetKey) {
                return existing
            }
            throw G09R2DesignStoreError.corrupt("ownerEnvelopeMissing")
        }
        var next = envelope
        next.revision = 0
        next.updatedAt = Date()
        try write(next, to: url)
        return next
    }

    private func url(for targetKey: String) throws -> URL {
        guard Self.isStableKey(targetKey) else {
            throw G09R2DesignStoreError.invalidKey(targetKey)
        }
        guard let url = G09R2DesignFileIO.containedURL(
            root: directoryURL, relative: "\(targetKey).json") else {
            throw G09R2DesignStoreError.invalidKey(targetKey)
        }
        return url
    }

    private func write(_ envelope: DesignOwnerEnvelope, to url: URL) throws {
        guard envelope.target.stableKey == envelope.project.nodeID else {
            throw G09R2DesignStoreError.corrupt("ownerEnvelopeBinding")
        }
        let data: Data
        do {
            data = try G09CreativeWire.encoder().encode(envelope)
        } catch {
            throw G09R2DesignStoreError.writeFailed
        }
        guard data.count <= Self.maximumEnvelopeBytes else {
            throw G09R2DesignStoreError.tooLarge(data.count)
        }
        try G09R2DesignFileIO.writeAtomically(data, to: url)
    }

    nonisolated static func isStableKey(_ raw: String) -> Bool {
        raw.count == 64 && raw.unicodeScalars.allSatisfy {
            ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f")
        }
    }
}

// MARK: - Immutable revision payloads

/// `DesignOwnerPayloadStore` rooted under the accepted root. Payloads are
/// content-verified before they are referenced and re-verified on every read.
public struct G09R2DesignOwnerPayloadStore: DesignOwnerPayloadStore, Sendable {
    private let directoryURL: URL

    public init(root: RuntimeStorageRoot) {
        self.directoryURL = root.artifactStoreURL
            .appendingPathComponent("DesignRevisions", isDirectory: true)
            .appendingPathComponent("owners", isDirectory: true)
            .appendingPathComponent("payloads", isDirectory: true)
    }

    public func store(
        ownerKey: String,
        revisionID: String,
        bytes: Data,
        expectedContentSHA256: String
    ) throws -> String {
        try Self.validate(ownerKey: ownerKey, revisionID: revisionID)
        guard !bytes.isEmpty,
              bytes.count <= Int(G09R2CreativeLimits.designSourceBytes) else {
            throw G09R2DesignStoreError.tooLarge(bytes.count)
        }
        let actual = FloeDigest.sha256Hex(bytes)
        guard actual.caseInsensitiveCompare(expectedContentSHA256) == .orderedSame else {
            throw G09R2DesignStoreError.corrupt("payloadDigestMismatch")
        }
        let relative = "\(ownerKey)/\(revisionID).payload"
        guard let url = G09R2DesignFileIO.containedURL(
            root: directoryURL, relative: relative) else {
            throw G09R2DesignStoreError.invalidKey(revisionID)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try G09R2DesignFileIO.readBounded(
                url, maxBytes: Int(G09R2CreativeLimits.designSourceBytes))
            guard FloeDigest.sha256Hex(existing)
                .caseInsensitiveCompare(actual) == .orderedSame else {
                throw G09R2DesignStoreError.conflict(expected: 1, actual: 0)
            }
            return relative
        }
        try G09R2DesignFileIO.writeAtomically(bytes, to: url)
        let readback = try G09R2DesignFileIO.readBounded(
            url, maxBytes: Int(G09R2CreativeLimits.designSourceBytes))
        guard FloeDigest.sha256Hex(readback)
            .caseInsensitiveCompare(actual) == .orderedSame else {
            throw G09R2DesignStoreError.writeFailed
        }
        return relative
    }

    public func verifiedBytes(
        ownerKey: String,
        revisionID: String,
        expectedContentSHA256: String
    ) throws -> Data {
        try Self.validate(ownerKey: ownerKey, revisionID: revisionID)
        guard let url = payloadURL(ownerKey: ownerKey, revisionID: revisionID) else {
            throw G09R2DesignStoreError.invalidKey(revisionID)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw G09R2DesignStoreError.corrupt("payloadMissing")
        }
        let data = try G09R2DesignFileIO.readBounded(
            url, maxBytes: Int(G09R2CreativeLimits.designSourceBytes))
        guard FloeDigest.sha256Hex(data)
            .caseInsensitiveCompare(expectedContentSHA256) == .orderedSame else {
            throw G09R2DesignStoreError.corrupt("payloadDigestMismatch")
        }
        return data
    }

    public func abandon(ownerKey: String, revisionID: String) {
        guard let url = payloadURL(ownerKey: ownerKey, revisionID: revisionID) else {
            return
        }
        G09R2DesignFileIO.remove(url)
    }

    public func payloadURL(ownerKey: String, revisionID: String) -> URL? {
        guard Self.isStableKey(ownerKey), Self.isSafeToken(revisionID) else {
            return nil
        }
        return G09R2DesignFileIO.containedURL(
            root: directoryURL, relative: "\(ownerKey)/\(revisionID).payload")
    }

    nonisolated static func validate(ownerKey: String, revisionID: String) throws {
        guard isStableKey(ownerKey) else {
            throw G09R2DesignStoreError.invalidKey(ownerKey)
        }
        guard isSafeToken(revisionID) else {
            throw G09R2DesignStoreError.invalidKey(revisionID)
        }
    }

    nonisolated static func isStableKey(_ raw: String) -> Bool {
        G09R2DesignOwnerProjectStore.isStableKey(raw)
    }

    nonisolated static func isSafeToken(_ raw: String) -> Bool {
        !raw.isEmpty && raw.utf8.count <= 128 && !raw.hasPrefix(".") &&
            raw.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) ||
                    $0 == "-" || $0 == "_" || $0 == "."
            }
    }
}

// MARK: - Verified preview / export receipts

struct G09R2DesignArtifactReceipt: Sendable, Equatable {
    let rootPath: String
    let relativePath: String
    let byteCount: Int64
    let sha256: String
    let format: String
}

/// Native-issued preview/export roots. Every receipt names a file inside one
/// of these directories, and every file is read back and re-hashed before the
/// receipt is returned.
public struct G09R2DesignArtifactStore: Sendable {
    private let previewsRoot: URL
    private let exportsRoot: URL
    private let scratchRoot: URL

    public init(root: RuntimeStorageRoot) {
        let base = root.artifactStoreURL
            .appendingPathComponent("DesignArtifacts", isDirectory: true)
        self.previewsRoot = base.appendingPathComponent("Previews", isDirectory: true)
        self.exportsRoot = base.appendingPathComponent("Exports", isDirectory: true)
        self.scratchRoot = base.appendingPathComponent("Scratch", isDirectory: true)
    }

    public var previewsRootPath: String { previewsRoot.path }
    public var exportsRootPath: String { exportsRoot.path }

    func writePreview(
        targetKey: String,
        revisionKey: String,
        bytes: Data,
        format: String,
        maxBytes: Int
    ) throws -> G09R2DesignArtifactReceipt {
        guard !bytes.isEmpty else {
            throw G09R2DesignStoreError.corrupt("previewEmpty")
        }
        guard bytes.count <= maxBytes else {
            throw G09R2DesignStoreError.tooLarge(bytes.count)
        }
        let extensionValue = Self.fileExtension(for: format)
        let name = "\(Self.safeToken(revisionKey, fallback: "preview")).\(extensionValue)"
        let relative = "\(targetKey)/\(name)"
        guard let url = G09R2DesignFileIO.containedURL(
            root: previewsRoot, relative: relative) else {
            throw G09R2DesignStoreError.invalidKey(relative)
        }
        let digest = FloeDigest.sha256Hex(bytes)
        try G09R2DesignFileIO.writeAtomically(bytes, to: url)
        let readback = try G09R2DesignFileIO.readBounded(url, maxBytes: maxBytes)
        guard readback.count == bytes.count,
              FloeDigest.sha256Hex(readback)
                .caseInsensitiveCompare(digest) == .orderedSame else {
            throw G09R2DesignStoreError.writeFailed
        }
        return G09R2DesignArtifactReceipt(
            rootPath: previewsRoot.path,
            relativePath: relative,
            byteCount: Int64(readback.count),
            sha256: digest,
            format: format)
    }

    func writeExport(
        targetKey: String,
        revisionKey: String,
        bytes: Data,
        format: String,
        suggestedFileName: String?
    ) throws -> G09R2DesignArtifactReceipt {
        guard !bytes.isEmpty else {
            throw G09R2DesignStoreError.corrupt("exportEmpty")
        }
        let extensionValue = Self.fileExtension(for: format)
        let requested = Self.safeFileName(
            suggestedFileName, format: format) ?? "design-\(Self.safeToken(revisionKey, fallback: "export")).\(extensionValue)"
        let relative = try uniqueRelativePath(
            root: exportsRoot, targetKey: targetKey, fileName: requested,
            bytes: bytes)
        guard let url = G09R2DesignFileIO.containedURL(
            root: exportsRoot, relative: relative) else {
            throw G09R2DesignStoreError.invalidKey(relative)
        }
        let digest = FloeDigest.sha256Hex(bytes)
        if !FileManager.default.fileExists(atPath: url.path) {
            try G09R2DesignFileIO.writeAtomically(bytes, to: url)
        }
        let readback = try G09R2DesignFileIO.readBounded(
            url, maxBytes: Int(G09R2CreativeLimits.designSourceBytes))
        guard readback.count == bytes.count,
              FloeDigest.sha256Hex(readback)
                .caseInsensitiveCompare(digest) == .orderedSame else {
            throw G09R2DesignStoreError.writeFailed
        }
        return G09R2DesignArtifactReceipt(
            rootPath: exportsRoot.path,
            relativePath: relative,
            byteCount: Int64(readback.count),
            sha256: digest,
            format: format)
    }

    func makeScratchFile(bytes: Data, format: String) throws -> URL {
        let extensionValue = Self.fileExtension(for: format)
        guard let url = G09R2DesignFileIO.containedURL(
            root: scratchRoot,
            relative: "\(UUID().uuidString.lowercased()).\(extensionValue)") else {
            throw G09R2DesignStoreError.writeFailed
        }
        try G09R2DesignFileIO.writeAtomically(bytes, to: url)
        return url
    }

    func removeScratchFile(_ url: URL) {
        guard url.path.hasPrefix(scratchRoot.standardizedFileURL.path + "/") else {
            return
        }
        G09R2DesignFileIO.remove(url)
    }

    private func uniqueRelativePath(
        root: URL,
        targetKey: String,
        fileName: String,
        bytes: Data
    ) throws -> String {
        let digest = FloeDigest.sha256Hex(bytes)
        var candidate = "\(targetKey)/\(fileName)"
        guard let first = G09R2DesignFileIO.containedURL(
            root: root, relative: candidate) else {
            throw G09R2DesignStoreError.invalidKey(candidate)
        }
        if FileManager.default.fileExists(atPath: first.path) {
            let existing = try G09R2DesignFileIO.readBounded(
                first, maxBytes: Int(G09R2CreativeLimits.designSourceBytes))
            if FloeDigest.sha256Hex(existing)
                .caseInsensitiveCompare(digest) == .orderedSame {
                return candidate
            }
            let stem = (fileName as NSString).deletingPathExtension
            let ext = (fileName as NSString).pathExtension
            let suffix = String(UUID().uuidString.replacingOccurrences(
                of: "-", with: "").lowercased().prefix(10))
            candidate = "\(targetKey)/\(stem)-\(suffix)"
            if !ext.isEmpty { candidate += ".\(ext)" }
        }
        return candidate
    }

    nonisolated static func fileExtension(for format: String) -> String {
        let normalized = format.lowercased()
        switch normalized {
        case "canvas.snapshot", "json": return "json"
        case "markdown": return "md"
        case "jpeg": return "jpg"
        case "text": return "txt"
        default:
            let candidate = normalized.replacingOccurrences(of: ".", with: "")
            if !candidate.isEmpty,
               candidate.unicodeScalars.allSatisfy({
                   CharacterSet.alphanumerics.contains($0)
               }) {
                return String(candidate.prefix(12))
            }
            return "bin"
        }
    }

    nonisolated static func safeToken(_ raw: String, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_"))
        let cleaned = String(raw.unicodeScalars.filter { allowed.contains($0) })
        let value = cleaned.isEmpty ? fallback : cleaned
        return String(value.prefix(80))
    }

    nonisolated static func safeFileName(
        _ raw: String?,
        format: String
    ) -> String? {
        guard let raw else { return nil }
        let base = (raw as NSString).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_. ()"))
        var cleaned = String(base.unicodeScalars.filter { allowed.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let expectedExtension = fileExtension(for: format)
        let currentExtension = (cleaned as NSString).pathExtension.lowercased()
        if currentExtension != expectedExtension {
            let stem = (cleaned as NSString).deletingPathExtension
            cleaned = stem + ".\(expectedExtension)"
        }
        if cleaned.utf8.count > 120 {
            let ext = (cleaned as NSString).pathExtension
            let stem = (cleaned as NSString).deletingPathExtension
            let suffix = ext.isEmpty ? "" : ".\(ext.prefix(12))"
            cleaned = String(stem.prefix(max(1, 120 - suffix.utf8.count))) + suffix
        }
        return cleaned
    }
}
