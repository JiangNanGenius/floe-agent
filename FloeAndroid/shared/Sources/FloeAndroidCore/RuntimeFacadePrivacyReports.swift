// SPDX-License-Identifier: MPL-2.0
//
// RuntimeFacadePrivacyReports — bounded same-root/process-lifetime failure
// report store for privacy.history.clear and
// privacy.modelConfiguration.clear.
//
// MAIN_PRIVACY_REPORT_STREAMING_DECISION_20261019:
//   * the initial clear value carries a BOUNDED failure array;
//   * every remaining item stays readable through `privacy.summary.get` with
//     the optional `{report:{handle,cursor,maxItems}}` request — no new
//     command/label/scope and never `content.read` with a privacy/foreign
//     label;
//   * the handle is issued ONLY by an actual clear operation in the same
//     trusted root/epoch and is an opaque process-lifetime value;
//   * foreign/expired handles answer typed `notFound`; no arbitrary path,
//     provider or secret is readable;
//   * items are an immutable snapshot in exact stable order, page items are
//     bounded 1...128 and the serialized page stays inside the RB1 value
//     budget (48 KiB actual escaped UTF-8).
//
// Memory-bound repair (2026-10-21, job-2557a0e84e224d9c): the producer no
// longer accumulates an unbounded in-RAM failure inventory and this store
// no longer retains per-report item arrays. Failures are appended
// INCREMENTALLY to a root-private STAGED spool that is finalized into an
// immutable, verified report directory before the clear returns. RAM holds
// at most the bounded initial page, a small post-degradation overflow
// cushion and small descriptors/counts — no per-item in-memory index.
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
import Crypto

// MARK: - Spool limits (one place)

enum PrivacyReportSpoolLimits {
    static let schema = "floe.privacy-report-spool/1"
    static let reportsDirectoryName = "PrivacyReports"
    static let reportDirectoryPrefix = "report-"
    static let stagingDirectoryPrefix = "staging-"
    static let readBufferBytes = 64 * 1024
    /// Hard RAM bound for items recorded after a spool write failure. The
    /// destructive loops stop at the next item boundary, so the real window
    /// is a handful of items; the cap guarantees the bound regardless.
    static let overflowItemLimit = 64
}

// MARK: - Opaque handle spelling (never the raw path on the wire)

enum PrivacyFailureReportHandle {
    static let prefix = "pr:v1:"

    static func mint() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255, using: &generator)
        }
        return prefix + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The exact owned directory name for a handle, or nil when the handle
    /// does not match the minted spelling (rejects foreign/arbitrary input
    /// before any filesystem touch).
    static func validatedDirectoryName(for handle: String) -> String? {
        guard handle.hasPrefix(prefix) else { return nil }
        let suffix = handle.dropFirst(prefix.count)
        guard suffix.count == 32,
              suffix.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            return nil
        }
        return PrivacyReportSpoolLimits.reportDirectoryPrefix + suffix
    }
}

// MARK: - Item codec (lossless line form)

/// One failure per line: `f <itemID|-> <providerID|-> <hex phase> <hex reason>`.
/// Phase/reason are hex encoded so a line is unambiguous without quoting and
/// round-trips the exact bounded wire strings (including escaped UTF-8).
enum PrivacyFailureReportItemCodec {
    static func line(for item: PrivacyFailurePageItem) -> String {
        let itemID = item.itemID?.uuidString ?? "-"
        let providerID = item.providerID?.uuidString ?? "-"
        return "f \(itemID) \(providerID) \(hex(item.phase)) \(hex(item.reason))"
    }

    static func item(fromLine line: String) throws -> PrivacyFailurePageItem {
        let parts = line.split(separator: " ", maxSplits: 4,
                               omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "f" else {
            throw PrivacyDomainError.persistenceUnavailable("reportItemCorrupt")
        }
        let itemID = parts[1] == "-" ? nil : UUID(uuidString: String(parts[1]))
        let providerID = parts[2] == "-" ? nil : UUID(uuidString: String(parts[2]))
        guard parts[1] == "-" || itemID != nil,
              parts[2] == "-" || providerID != nil else {
            throw PrivacyDomainError.persistenceUnavailable("reportItemCorrupt")
        }
        return PrivacyFailurePageItem(
            itemID: itemID, providerID: providerID,
            phase: try unhex(String(parts[3])),
            reason: try unhex(String(parts[4])))
    }

    static func hex(_ string: String) -> String {
        string.utf8.map { String(format: "%02x", $0) }.joined()
    }

    static func unhex(_ raw: String) throws -> String {
        guard raw.count % 2 == 0 else {
            throw PrivacyDomainError.persistenceUnavailable("reportItemCorrupt")
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(raw.count / 2)
        var index = raw.startIndex
        while index < raw.endIndex {
            let next = raw.index(index, offsetBy: 2)
            guard let byte = UInt8(raw[index..<next], radix: 16) else {
                throw PrivacyDomainError.persistenceUnavailable("reportItemCorrupt")
            }
            bytes.append(byte)
            index = next
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Descriptor / manifest

/// Small in-RAM registration record — counts and identity only, never items.
public struct PrivacyFailureReportDescriptor: Sendable, Equatable {
    public var handle: String
    public var kind: PrivacyReportKind
    /// Trusted root identity token (`sha256:<hex>`); never the raw path.
    public var root: String
    public var epoch: UInt64
    /// Local absolute path of the verified report directory. Internal state
    /// only; it never appears on the wire.
    public var directoryPath: String
    public var totalItems: Int
    public var bytes: Int
    public var sha256: String
    public var createdAt: Date

    public init(handle: String, kind: PrivacyReportKind, root: String,
                epoch: UInt64, directoryPath: String, totalItems: Int,
                bytes: Int, sha256: String, createdAt: Date) {
        self.handle = handle
        self.kind = kind
        self.root = root
        self.epoch = epoch
        self.directoryPath = directoryPath
        self.totalItems = totalItems
        self.bytes = bytes
        self.sha256 = sha256
        self.createdAt = createdAt
    }
}

struct PrivacyFailureReportSection: Sendable, Codable, Equatable {
    var bytes: Int
    var lines: Int
    var sha256: String
}

struct PrivacyFailureReportManifest: Sendable, Codable, Equatable {
    var schema: String
    var handle: String
    var kind: PrivacyReportKind
    var root: String
    var epoch: UInt64
    var operationID: UUID
    var createdAt: String
    var items: PrivacyFailureReportSection
}

// MARK: - Staged writer (single writer, unbuffered append, verified finalize)

/// Incremental producer-side writer. Every append is written through
/// immediately, so an append failure means EXACTLY that item is not on disk
/// (no hidden buffered backlog). Finalize renames the staging directory into
/// the immutable report location and re-reads every byte for verification
/// before the report becomes readable.
final class PrivacyFailureReportSpoolWriter: @unchecked Sendable {
    private let stagingDirectory: URL
    private let finalDirectory: URL
    private let kind: PrivacyReportKind
    private let root: String
    private let epoch: UInt64
    private let operationID: UUID
    private var handle: FileHandle
    private var hasher = SHA256()
    private(set) var itemsWritten = 0
    private var bytesWritten = 0
    private var finished = false
    /// Host-qualification fault injection ONLY (never set in production):
    /// POSIX makes post-open permission/flag changes ineffective on an
    /// already-open write descriptor (verified empirically on macOS for both
    /// chmod(0400) and chflags(UCHG)), so a real first-append I/O failure
    /// cannot be forced portably. Tests set this to prove the first-write
    /// degradation policy; the spool ARRANGEMENT failure remains a real I/O
    /// refusal (facade-level arrangement test).
    var testAppendFault: (() -> PrivacyDomainError)?

    init(rootPath: String, kind: PrivacyReportKind, root: String,
         epoch: UInt64, operationID: UUID) throws {
        self.kind = kind
        self.root = root
        self.epoch = epoch
        self.operationID = operationID
        let parent = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(
                PrivacyReportSpoolLimits.reportsDirectoryName, isDirectory: true)
        self.stagingDirectory = parent.appendingPathComponent(
            PrivacyReportSpoolLimits.stagingDirectoryPrefix
                + operationID.uuidString, isDirectory: true)
        // The final directory name is fixed after minting; the writer holds
        // the parent and the caller passes the exact handle at finish().
        self.finalDirectory = parent
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: stagingDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let staged = stagingDirectory
                .appendingPathComponent("items.staged")
            guard fileManager.createFile(
                atPath: staged.path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else {
                throw PrivacyDomainError.persistenceUnavailable("reportSpoolCreate")
            }
            handle = try FileHandle(forWritingTo: staged)
        } catch let error as PrivacyDomainError {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw PrivacyDomainError.persistenceUnavailable("reportSpoolCreate")
        }
    }

    deinit {
        if !finished { abort() }
    }

    /// Appends one item. Throws typed when the item could not be written;
    /// the caller then stops using this writer (first failure is terminal by
    /// policy — no partial buffered backlog is ever claimed as written).
    func append(_ item: PrivacyFailurePageItem) throws {
        guard !finished else {
            throw PrivacyDomainError.persistenceUnavailable("reportSpoolClosed")
        }
        if let testAppendFault {
            throw testAppendFault()
        }
        var data = Data(PrivacyFailureReportItemCodec.line(for: item).utf8)
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
            hasher.update(data: data)
            itemsWritten += 1
            bytesWritten += data.count
        } catch {
            throw PrivacyDomainError.persistenceUnavailable("reportSpoolWrite")
        }
    }

    /// Flush, sync, rename into the immutable report directory, write the
    /// manifest and VERIFY the publication by re-reading every byte.
    func finish(reportHandle: String, createdAt: Date) throws
        -> PrivacyFailureReportDescriptor
    {
        guard !finished else {
            throw PrivacyDomainError.persistenceUnavailable("reportSpoolFinalize")
        }
        finished = true
        let fileManager = FileManager.default
        var finalURL: URL?
        do {
            try handle.synchronize()
            try handle.close()
            guard let directoryName =
                    PrivacyFailureReportHandle.validatedDirectoryName(
                        for: reportHandle) else {
                try? fileManager.removeItem(at: stagingDirectory)
                throw PrivacyDomainError.persistenceUnavailable(
                    "reportHandleInvalid")
            }
            let final = finalDirectory.appendingPathComponent(
                directoryName, isDirectory: true)
            if fileManager.fileExists(atPath: final.path) {
                // A handle collision is impossible in practice; never
                // overwrite an existing immutable report.
                try? fileManager.removeItem(at: stagingDirectory)
                throw PrivacyDomainError.persistenceUnavailable(
                    "reportHandleCollision")
            }
            try fileManager.moveItem(at: stagingDirectory, to: final)
            finalURL = final
            // The staged file takes its immutable publication name; the
            // verified read side opens items.dat (2026-10-21 repair — the
            // finalize used to leave items.staged behind, so verification
            // and every page read failed reportMissing).
            try fileManager.moveItem(
                at: final.appendingPathComponent("items.staged"),
                to: final.appendingPathComponent("items.dat"))
            let digest = "sha256:" + hasher.finalize()
                .map { String(format: "%02x", $0) }.joined()
            let manifest = PrivacyFailureReportManifest(
                schema: PrivacyReportSpoolLimits.schema,
                handle: reportHandle,
                kind: kind,
                root: root,
                epoch: epoch,
                operationID: operationID,
                createdAt: PrivacySnapshotEngine.iso8601Fractional(createdAt),
                items: PrivacyFailureReportSection(
                    bytes: bytesWritten, lines: itemsWritten, sha256: digest))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(manifest)
            let manifestURL = final.appendingPathComponent("manifest.json")
            try data.write(to: manifestURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
            // Verify before publication: bytes, lines and SHA-256 are
            // re-derived from disk. A report that fails here is removed and
            // never becomes readable.
            _ = try PrivacyFailureReportSpool.verify(
                directory: final, manifest: manifest)
            return PrivacyFailureReportDescriptor(
                handle: reportHandle, kind: kind, root: root, epoch: epoch,
                directoryPath: final.path, totalItems: itemsWritten,
                bytes: bytesWritten, sha256: digest, createdAt: createdAt)
        } catch let error as PrivacyDomainError {
            try? fileManager.removeItem(at: stagingDirectory)
            if let finalURL {
                try? fileManager.removeItem(at: finalURL)
            }
            throw error
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            if let finalURL {
                try? fileManager.removeItem(at: finalURL)
            }
            throw PrivacyDomainError.persistenceUnavailable("reportSpoolFinalize")
        }
    }

    func abort() {
        finished = true
        try? handle.close()
        try? FileManager.default.removeItem(at: stagingDirectory)
    }
}

// MARK: - Verified read side

/// Immutable verified report. Never trusts the manifest alone: every read
/// re-hashes the item stream from disk with a bounded 64 KiB buffer before a
/// single item is returned.
struct PrivacyFailureReportSpool {
    let directory: URL
    let manifest: PrivacyFailureReportManifest

    static func open(descriptor: PrivacyFailureReportDescriptor) throws
        -> PrivacyFailureReportSpool
    {
        let directory = URL(fileURLWithPath: descriptor.directoryPath,
                            isDirectory: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw PrivacyDomainError.persistenceUnavailable("reportMissing")
        }
        let decoder = JSONDecoder()
        guard let manifest = try? decoder.decode(
            PrivacyFailureReportManifest.self, from: data),
              manifest.schema == PrivacyReportSpoolLimits.schema,
              manifest.handle == descriptor.handle,
              manifest.kind == descriptor.kind,
              manifest.root == descriptor.root,
              manifest.epoch == descriptor.epoch else {
            throw PrivacyDomainError.persistenceUnavailable(
                "reportManifestInvalid")
        }
        let verified = try verify(directory: directory, manifest: manifest)
        guard verified.items == manifest.items else {
            throw PrivacyDomainError.persistenceUnavailable(
                "reportVerificationMismatch")
        }
        return PrivacyFailureReportSpool(directory: directory,
                                         manifest: manifest)
    }

    static func verify(directory: URL,
                       manifest: PrivacyFailureReportManifest) throws
        -> PrivacyFailureReportManifest
    {
        let url = directory.appendingPathComponent("items.dat")
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw PrivacyDomainError.persistenceUnavailable("reportMissing")
        }
        var hasher = SHA256()
        var total = 0
        var lineCount = 0
        var lastByte: UInt8 = 0x0A
        while true {
            let chunk = try handle.read(
                upToCount: PrivacyReportSpoolLimits.readBufferBytes)
            guard let chunk, !chunk.isEmpty else { break }
            total += chunk.count
            hasher.update(data: chunk)
            for byte in chunk where byte == 0x0A { lineCount += 1 }
            lastByte = chunk.last ?? lastByte
        }
        try? handle.close()
        // A staged line always ends with a newline; a missing final newline
        // is a truncated write, never a valid short line.
        guard lastByte == 0x0A || total == 0 else {
            throw PrivacyDomainError.persistenceUnavailable("reportTruncated")
        }
        let hash = "sha256:" + hasher.finalize()
            .map { String(format: "%02x", $0) }.joined()
        guard total == manifest.items.bytes,
              lineCount == manifest.items.lines,
              hash == manifest.items.sha256 else {
            throw PrivacyDomainError.persistenceUnavailable(
                "reportVerificationMismatch")
        }
        return manifest
    }

    /// Bounded streaming reader (never materializes the report).
    func reader() throws -> PrivacySpoolLineReader {
        try PrivacySpoolLineReader(
            url: directory.appendingPathComponent("items.dat"))
    }
}

// MARK: - Report store (small descriptors only; pages stream from disk)

public final class PrivacyReportStore: @unchecked Sendable {
    /// Process-incarnation ownership of one root's reports directory.
    /// Committed `report-*` handles are process-lifetime values: a store in
    /// a NEW process incarnation has no descriptors for the previous (dead)
    /// incarnation's committed reports, so without this claim they would
    /// accumulate across crashes/restarts forever. Exactly one live owner
    /// exists per root (single-app ownership); the atomic first-claim makes
    /// the winner unambiguous. Same-incarnation re-init keeps everything —
    /// active current/newer-epoch reports are never touched by this path.
    private struct ProcessOwnership: Codable {
        var schema: String
        var incarnation: String
        var claimedAt: String
    }
    private static let ownershipSchema = "floe.privacy-report-ownership/1"
    private static let ownershipFileName = "owner.json"
    private static let processIncarnation = UUID()

    private let lock = NSLock()
    private let rootPath: String
    private let rootToken: String
    private let reportsRoot: URL
    /// The process incarnation this store instance owns the root under.
    /// The internal initializer lets host tests simulate process death
    /// (a foreign incarnation) without any mutable global state. Internal
    /// (not public) so only module tests can read it back.
    let incarnation: UUID
    private var reports: [String: PrivacyFailureReportDescriptor] = [:]
    private var order: [String] = []

    /// One store serves exactly one trusted root. Staging orphans from a
    /// dead process are removed at creation; they are never publishable.
    /// Committed reports of a DIFFERENT (dead) process incarnation are
    /// removed only via the ownership claim, never blindly.
    public convenience init(rootPath: String) {
        self.init(rootPath: rootPath, incarnation: Self.processIncarnation)
    }

    init(rootPath: String, incarnation: UUID) {
        self.rootPath = rootPath
        self.rootToken = PrivacyRootIdentity.token(rootPath: rootPath)
        self.incarnation = incarnation
        self.reportsRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(
                PrivacyReportSpoolLimits.reportsDirectoryName,
                isDirectory: true)
        try? FileManager.default.createDirectory(
            at: reportsRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        claimProcessOwnership()
        removeStaleStaging()
    }

    private func claimProcessOwnership() {
        let fileManager = FileManager.default
        let ownerURL = reportsRoot.appendingPathComponent(
            Self.ownershipFileName, isDirectory: false)
        let payload = ownershipPayload()
        // Atomic first-claim via O_EXCL: exactly one creator observes the
        // file absent. (FileManager.createFile OVERWRITES an existing file
        // and returns true, so it cannot provide claim semantics.)
        let fd = open(ownerURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd >= 0 {
            payload.withUnsafeBytes { raw in
                if let base = raw.baseAddress, raw.count > 0 {
                    _ = write(fd, base, raw.count)
                }
            }
            close(fd)
            return
        }
        if let data = try? Data(contentsOf: ownerURL),
           let owner = try? JSONDecoder().decode(
               ProcessOwnership.self, from: data),
           owner.incarnation == incarnation.uuidString {
            // Same live process: keep every committed report and epoch.
            return
        }
        // The recorded owner is a different incarnation (process death) or
        // malformed/foreign: the previous owner's committed reports are
        // unreachable orphans. Remove ONLY containment-validated owned
        // report/staging directories, then claim.
        removeAllOwnedDirectories()
        try? payload.write(to: ownerURL, options: [.atomic])
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: ownerURL.path)
    }

    private func ownershipPayload() -> Data {
        let owner = ProcessOwnership(
            schema: Self.ownershipSchema,
            incarnation: incarnation.uuidString,
            claimedAt: PrivacySnapshotEngine.iso8601Fractional(Date()))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(owner)) ?? Data("{}".utf8)
    }

    /// Registers ONE finalized, verified report. Returns the terminal-page
    /// summary when the bounded initial array does not hold every failure;
    /// nil means the initial array already holds them all (the caller
    /// normally skips adoption entirely in that case — this is defense in
    /// depth and never mints an empty handle).
    public func adopt(_ descriptor: PrivacyFailureReportDescriptor) throws
        -> PrivacyFailurePageSummary?
    {
        guard descriptor.root == rootToken else {
            throw PrivacyDomainError.notFound
        }
        guard PrivacyFailureReportHandle.validatedDirectoryName(
            for: descriptor.handle) != nil else {
            throw PrivacyDomainError.invalidEnvelope("reportHandleInvalid")
        }
        guard descriptor.totalItems > PrivacyReportLimits.initialFailureItems else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        reports[descriptor.handle] = descriptor
        order.append(descriptor.handle)
        while order.count
                > PrivacyReportLimits.maximumLiveReportsPerRoot * 4 {
            let evicted = order.removeFirst()
            if let entry = reports[evicted] {
                removeReportDirectory(directoryPath: entry.directoryPath)
            }
            reports[evicted] = nil
        }
        return PrivacyFailurePageSummary(
            handle: descriptor.handle,
            returned: PrivacyReportLimits.initialFailureItems,
            total: descriptor.totalItems,
            nextCursor: Self.cursor(
                offset: PrivacyReportLimits.initialFailureItems))
    }

    /// Read ONE page. The handle is validated against the exact live
    /// root/epoch; a foreign, retired, evicted or unknown handle is typed
    /// notFound. The page is re-verified from disk and bounded by BOTH
    /// maxItems (1...128) and the actual serialized 48 KiB value budget —
    /// fewer items may be returned with a truthful nextCursor when the
    /// requested page would not fit.
    public func page(handle: String, root: String, epoch: UInt64,
                     cursor: String?, maxItems: Int) throws
        -> PrivacyFailurePage
    {
        guard maxItems >= PrivacyReportLimits.minimumPageItems,
              maxItems <= PrivacyReportLimits.maximumPageItems else {
            throw PrivacyDomainError.invalidEnvelope(
                "payloadFieldOutOfRange:maxItems")
        }
        let offset: Int
        if let cursor {
            offset = try Self.offset(fromCursor: cursor)
        } else {
            offset = 0
        }
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor = reports[handle],
              descriptor.root == root, descriptor.epoch == epoch else {
            throw PrivacyDomainError.notFound
        }
        guard offset >= 0, offset <= descriptor.totalItems else {
            throw PrivacyDomainError.notFound
        }
        // Immutable verified publication: re-hash the full stream (bounded
        // 64 KiB chunks) before returning any item.
        let spool = try PrivacyFailureReportSpool.open(descriptor: descriptor)
        let reader = try spool.reader()
        // Bounded sequential skip to the cursor offset. No per-item index.
        var skipped = 0
        while skipped < offset {
            let lines = try reader.nextPage(
                limit: min(512, offset - skipped))
            if lines.isEmpty { break }
            skipped += lines.count
        }
        guard skipped == offset else {
            throw PrivacyDomainError.persistenceUnavailable(
                "reportVerificationMismatch")
        }
        let lines = try reader.nextPage(limit: maxItems)
        let hasMore = !(try reader.nextPage(limit: 1)).isEmpty
        let items = try lines.map {
            try PrivacyFailureReportItemCodec.item(fromLine: $0)
        }
        let reached = offset + items.count
        let done = !hasMore && reached == descriptor.totalItems
        // Exact escaped-UTF-8 budget: assemble the real page and measure it
        // with the same encoder class the binder uses; trim from the tail
        // (honest smaller page + nextCursor) until it fits. The cursor must
        // advance from THIS page's START offset by the RETURNED count —
        // passing the reached offset here double-advances a non-terminal
        // cursor and silently skips records (2026-10-21 repair).
        let page = try pageWithinBudget(
            handle: descriptor.handle, kind: descriptor.kind,
            items: items, offset: offset, total: descriptor.totalItems,
            done: done)
        return page
    }

    /// RootStop/epoch retirement: drop ONLY this epoch's reports and their
    /// owned spool directories. Newer epochs and non-task files are never
    /// touched.
    public func retire(epoch: UInt64) {
        lock.lock()
        let doomed = reports.compactMap { entry in
            entry.value.epoch == epoch ? entry.key : nil
        }
        for key in doomed {
            if let entry = reports[key] {
                removeReportDirectory(directoryPath: entry.directoryPath)
            }
            reports[key] = nil
        }
        order.removeAll { reports[$0] == nil }
        lock.unlock()
    }

    public func liveCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return reports.count
    }

    public func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        reports.removeAll()
        order.removeAll()
        removeAllOwnedDirectories()
    }

    // MARK: Containment-checked cleanup (task-owned paths only)

    private var standardizedReportsRoot: String {
        reportsRoot.standardizedFileURL.path
    }

    private func isContainedTaskDirectory(_ path: String) -> Bool {
        let root = standardizedReportsRoot
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        guard candidate.hasPrefix(root + "/") else { return false }
        let name = URL(fileURLWithPath: candidate).lastPathComponent
        return name.hasPrefix(PrivacyReportSpoolLimits.reportDirectoryPrefix)
            || name.hasPrefix(PrivacyReportSpoolLimits.stagingDirectoryPrefix)
    }

    private func removeReportDirectory(directoryPath: String) {
        guard isContainedTaskDirectory(directoryPath) else { return }
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: directoryPath, isDirectory: true))
    }

    private func removeStaleStaging() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: reportsRoot, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent
            .hasPrefix(PrivacyReportSpoolLimits.stagingDirectoryPrefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func removeAllOwnedDirectories() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: reportsRoot, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent
            .hasPrefix(PrivacyReportSpoolLimits.reportDirectoryPrefix)
            || entry.lastPathComponent
                .hasPrefix(PrivacyReportSpoolLimits.stagingDirectoryPrefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: Opaque cursor spelling (rc:v1 item offsets, unchanged contract)

    private static func cursor(offset: Int) -> String {
        "rc:v1:\(offset)"
    }

    private static func offset(fromCursor cursor: String) throws -> Int {
        let prefix = "rc:v1:"
        guard cursor.hasPrefix(prefix),
              cursor.count <= 32,
              let offset = Int(cursor.dropFirst(prefix.count)),
              offset >= 0 else {
            throw PrivacyDomainError.invalidEnvelope("invalidPayloadField:cursor")
        }
        return offset
    }

    // MARK: Exact page budget (48 KiB actual serialized UTF-8)

    /// Assembles the page and enforces the real wire budget. The fast path
    /// encodes once; the trim path re-encodes with one fewer tail item per
    /// step, so the returned page is measured exactly (escape-aware through
    /// the real encoder) and every skipped item remains reachable through
    /// the returned nextCursor.
    private func pageWithinBudget(handle: String, kind: PrivacyReportKind,
                                  items: [PrivacyFailurePageItem],
                                  offset: Int, total: Int,
                                  done originalDone: Bool) throws
        -> PrivacyFailurePage
    {
        let budget = SettingsDomainV1.pageBudgetBytes
        var count = items.count
        while true {
            let end = offset + count
            let done = originalDone && count == items.count
            let candidate = PrivacyFailurePage(
                handle: handle, kind: kind,
                items: Array(items.prefix(count)),
                nextCursor: done ? nil : Self.cursor(offset: end),
                total: total, done: done)
            if let data = try? JSONEncoder().encode(
                PrivacyFailurePageReply(report: candidate)),
               data.count <= budget {
                return candidate
            }
            guard count > 0 else {
                // The empty terminal page always fits; a failure here means
                // the encoder itself is broken, never an oversize page.
                throw PrivacyDomainError.persistenceUnavailable(
                    "reportPageEncode")
            }
            count -= 1
        }
    }
}
