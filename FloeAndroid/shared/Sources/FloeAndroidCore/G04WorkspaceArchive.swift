// SPDX-License-Identifier: MPL-2.0
//
// G04 — full-window archive document bridge `floe.archive/25`.
//
// The App's Kotlin archive host is the only caller. It sends the already-
// owned task/workspace identity plus workspace-relative paths and receives
// bounded listings, extraction receipts, bounded entry-preview text and
// progress/cancel handles. No file bytes cross this channel except one
// bounded, plainly-truncated UTF-8 preview; every archive effect happens
// inside the task workspace through the EXISTING safe engine:
//
//   * authority: every operation acquires the ORIGINAL
//     `G04WorkspaceAccessPort` lease (`G04LiveWorkspaceAccess` through
//     `G04WorkspaceComposition`) with the real native epoch, task UUID,
//     workspace UUID and the host generation the App read from the live
//     root. A stale epoch, a retired generation, a temporary task or a
//     model/frontend-supplied root never reaches the filesystem: the
//     authorizer re-proves ownership from the original stores per call.
//   * engine: `ArchiveBrowserService` → `WorkspaceArchiveTool` →
//     `ArchiveEngine`, the same bounded path the agent tool uses. Entry/
//     size limits, traversal/symlink rejection, the no-overwrite commit and
//     the expansion-bomb byte budget stay in that ONE place; this bridge
//     adds no second decoder, no buffered replay and no UI-global root.
//   * capabilities: zip, tar, tar.gz, tar.bz2, tar.xz and 7z list/extract;
//     gzip/bzip2/xz single-file decompress; create stays on the agent tool.
//     RAR extraction is available through the original agent archive tool;
//     this manual viewer retains the fixed iOS browser's format coverage.
//   * lifecycle: listing/extract jobs outlive the Compose view (the App
//     owns the controller). Cancellation is a real token the engine polls;
//     progress is polled by the App over `g04.archive.progress`; a failed
//     or cancelled extract leaves the workspace untouched (the engine's
//     staged-commit never overwrote anything) and the UI maps the typed
//     failure honestly.
//
// Source-only: this file is authored against the current FloeAndroidCore
// APIs and is compiled by Main's unified qualification, not by this lane.
import Foundation
import FloeCore
import FloeTools
import FloeWorkspace

// MARK: - Closed wire identity

public enum G04ArchiveWire {
    public static let version = 25
    public static let schema = "floe.archive/25"
    /// The frozen `floe_bridge_exchange` C string bound is 65,536 bytes.
    /// Requests are structured metadata; the one text reply is bounded by
    /// `maximumPreviewBytes` far below the response cap.
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 65_536
    /// One entry preview never exceeds this many UTF-8 bytes on the wire;
    /// the on-disk file gate stays the engine/iOS 1 MiB bound below.
    public static let maximumPreviewBytes = 32 * 1024
    /// Same on-disk gate as the original iOS browser surface.
    public static let maximumPreviewFileBytes = 1024 * 1024
    public static let operations: [String] = [
        "handshake",
        "g04.archive.listing",
        "g04.archive.extract",
        "g04.archive.decompress",
        "g04.archive.previewEntry",
        "g04.archive.previewDiscard",
        "g04.archive.progress",
        "g04.archive.cancel",
    ]
}

public enum BridgeV25 {
    public static let version = G04ArchiveWire.version
}

// MARK: - Errors

public struct G04ArchiveError: Error, Equatable, Sendable {
    public let code: String
    public let reason: String

    public init(_ code: String, _ reason: String) {
        self.code = code
        self.reason = reason
    }

    public static let unsupportedVersion = G04ArchiveError("unsupportedVersion", "version")
    public static let requestTooLarge = G04ArchiveError("requestTooLarge", "requestBytes")
    public static let responseTooLarge = G04ArchiveError("responseTooLarge", "responseBytes")
    public static let unsupportedOperation = G04ArchiveError("unsupportedOperation", "operation")
    public static let invalidRequest = G04ArchiveError("invalidRequest", "request")
    public static let invalidOwner = G04ArchiveError("invalidOwner", "owner")
    public static let invalidPath = G04ArchiveError("invalidPath", "path")
    public static let invalidDestination = G04ArchiveError("invalidDestination", "destination")
    public static let invalidOperationID = G04ArchiveError("invalidOperationID", "operationID")
    public static let invalidPreviewID = G04ArchiveError("invalidPreviewID", "previewID")
    public static let invalidEntry = G04ArchiveError("invalidEntry", "entryPath")
    public static let retired = G04ArchiveError("retired", "nativeEpoch")
    public static let ownerChanged = G04ArchiveError("ownerChanged", "owner")
    public static let runtimeUnavailable = G04ArchiveError("runtimeUnavailable", "runtime")
    public static let unsupportedFormat = G04ArchiveError("unsupportedFormat", "format")
    public static let notFound = G04ArchiveError("notFound", "path")
    public static let failed = G04ArchiveError("failed", "operation")
    public static let cancelled = G04ArchiveError("cancelled", "operation")
}

// MARK: - Owner

/// The already-owned document identity. Only the App host may supply it;
/// the authorizer re-proves every component against the original stores.
public struct G04ArchiveOwner: Sendable, Equatable {
    public let taskID: UUID
    public let workspaceID: UUID
    public let nativeEpoch: UInt64
    public let hostGeneration: UInt64

    public init(taskID: UUID, workspaceID: UUID,
                nativeEpoch: UInt64, hostGeneration: UInt64) throws {
        guard nativeEpoch > 0 else { throw G04ArchiveError.invalidOwner }
        self.taskID = taskID
        self.workspaceID = workspaceID
        self.nativeEpoch = nativeEpoch
        self.hostGeneration = hostGeneration
    }

    public var workspaceOwner: G04WorkspaceOwner {
        G04WorkspaceOwner(epoch: nativeEpoch, taskID: taskID, workspaceID: workspaceID)
    }

    public static func parse(_ value: Any?) throws -> G04ArchiveOwner {
        guard let object = value as? [String: Any],
              let task = g04ArchiveString(object["taskID"], maxBytes: 64),
              let workspace = g04ArchiveString(object["workspaceID"], maxBytes: 64),
              let taskID = UUID(uuidString: task),
              let workspaceID = UUID(uuidString: workspace),
              let epoch = g04ArchiveUInt64(object["nativeEpoch"]),
              let generation = g04ArchiveUInt64(object["hostGeneration"]) else {
            throw G04ArchiveError.invalidOwner
        }
        return try G04ArchiveOwner(taskID: taskID, workspaceID: workspaceID,
                                   nativeEpoch: epoch, hostGeneration: generation)
    }
}

// MARK: - Long-running operation registry (progress + real cancellation)

/// Thread-safe registry for ONE in-flight extract/decompress. The App polls
/// progress over a separate bridge call while the blocking operation runs;
/// `cancel` trips the derived token the engine actually polls, so
/// cancellation is physical (staged output is abandoned by the engine's
/// no-overwrite commit), never a UI-only flag.
public final class G04ArchiveOperationRegistry: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var phase: String
        public var completedBytes: Int64
        public var totalBytes: Int64?
        public var completedEntries: Int
        public var cancelled: Bool
    }

    private struct Record {
        let owner: G04ArchiveOwner
        let token: CancellationToken
        var progress: ArchiveProgress?
        var cancelled: Bool
    }

    public static let shared = G04ArchiveOperationRegistry()

    private let lock = NSLock()
    private var records: [UUID: Record] = [:]

    public init() {}

    public func begin(owner: G04ArchiveOwner, operationID: UUID, parent: CancellationToken) -> CancellationToken {
        let token = parent.derived()
        lock.lock()
        records[operationID] = Record(owner: owner, token: token, progress: nil, cancelled: false)
        lock.unlock()
        return token
    }

    public func update(_ operationID: UUID, progress: ArchiveProgress) {
        lock.lock()
        records[operationID]?.progress = progress
        lock.unlock()
    }

    public func snapshot(_ operationID: UUID) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let record = records[operationID] else { return nil }
        let latest = record.progress
        return Snapshot(
            phase: latest?.phase.rawValue ?? "running",
            completedBytes: latest?.completedBytes ?? 0,
            totalBytes: latest?.totalBytes,
            completedEntries: latest?.completedEntries ?? 0,
            cancelled: record.cancelled)
    }

    /// Real cancellation: the derived token the engine polls is tripped.
    /// Returns false when the operation is unknown or already finished.
    @discardableResult
    public func cancel(_ operationID: UUID) -> Bool {
        lock.lock()
        guard var record = records[operationID] else {
            lock.unlock()
            return false
        }
        record.cancelled = true
        records[operationID] = record
        let token = record.token
        lock.unlock()
        token.cancel()
        return true
    }

    public func end(_ operationID: UUID) {
        lock.lock()
        records.removeValue(forKey: operationID)
        lock.unlock()
    }

    public func cancelAll(for owner: G04ArchiveOwner? = nil) -> Int {
        lock.lock()
        let matches = records.filter { owner == nil || $0.value.owner == owner }
        for (id, var record) in matches {
            record.cancelled = true
            records[id] = record
        }
        let tokens = matches.map(\.value.token)
        lock.unlock()
        tokens.forEach { $0.cancel() }
        return matches.count
    }
}

// MARK: - Preview staging sessions

/// One hidden `.floe-archive-preview/<id>` staging directory per browser
/// session, reused across entry selections and removed on discard/close —
/// the exact lifecycle of the original iOS `ArchiveBrowserView`.
public final class G04ArchivePreviewRegistry: @unchecked Sendable {
    public static let shared = G04ArchivePreviewRegistry()

    private let lock = NSLock()
    private var sessions: [UUID: Session] = [:]

    public init() {}

    @discardableResult
    public func session(_ previewID: UUID, owner: G04ArchiveOwner, relativePath: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[previewID] {
            return existing.owner == owner && existing.relativePath == relativePath
        }
        sessions[previewID] = Session(owner: owner, relativePath: relativePath, directory: nil)
        return true
    }

    public func stagedDirectory(_ previewID: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[previewID]?.directory
    }

    public func markStaged(_ previewID: UUID, directory: String) {
        lock.lock()
        sessions[previewID]?.directory = directory
        lock.unlock()
    }

    /// True when the session was live and is now removed; the caller then
    /// deletes the staged bytes through the workspace lease.
    @discardableResult
    public func takeForDiscard(_ previewID: UUID, owner: G04ArchiveOwner) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        guard sessions[previewID]?.owner == owner else { return nil }
        return sessions.removeValue(forKey: previewID)
    }

    public struct Session: Sendable {
        public let owner: G04ArchiveOwner
        public let relativePath: String
        public var directory: String?
    }
}

// MARK: - Bridge

public enum G04ArchiveBridge {
    /// Seconds one blocking extract/decompress may hold its JNI thread;
    /// the App-side controller owns a wider view-level timeout, and an
    /// engine that ignores cancellation still fails bounded by this gate.
    static let operationSeconds: UInt64 = 600

    public static func handle(requestData: Data,
                              fallbackRequestID: String?,
                              operations: G04ArchiveOperationRegistry = .shared,
                              previews: G04ArchivePreviewRegistry = .shared) -> [String: Any] {
        handle(requestData: requestData, fallbackRequestID: fallbackRequestID,
               operations: operations, previews: previews, wait: true)
    }

    /// `wait:false` runs the operation without the semaphore gate (tests).
    static func handle(requestData: Data,
                       fallbackRequestID: String?,
                       operations: G04ArchiveOperationRegistry,
                       previews: G04ArchivePreviewRegistry,
                       wait: Bool) -> [String: Any] {
        var requestID = fallbackRequestID
        func failure(_ error: G04ArchiveError, operation: String?, detail: String? = nil) -> [String: Any] {
            var value: [String: Any] = [
                "ok": false,
                "code": error.code,
                "reason": error.reason,
                "schema": G04ArchiveWire.schema,
            ]
            if let operation { value["operation"] = operation }
            if let detail { value["detail"] = detail }
            if let requestID { value["requestID"] = requestID }
            return value
        }
        func success(_ fields: [String: Any], operation: String) -> [String: Any] {
            var value = fields
            value["ok"] = true
            value["schema"] = G04ArchiveWire.schema
            value["operation"] = operation
            if let requestID { value["requestID"] = requestID }
            return value
        }
        guard requestData.count <= G04ArchiveWire.maximumRequestBytes else {
            return failure(.requestTooLarge, operation: nil)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: requestData))
                as? [String: Any],
              let version = g04ArchiveInt(object["version"]),
              version == G04ArchiveWire.version,
              let operation = g04ArchiveString(object["operation"], maxBytes: 64) else {
            return failure(.invalidRequest, operation: nil)
        }
        requestID = g04ArchiveString(object["requestID"], maxBytes: 256) ?? requestID
        do {
            switch operation {
            case "handshake":
                return success(handshake(), operation: operation)
            case "g04.archive.listing":
                return success(try listing(object), operation: operation)
            case "g04.archive.extract":
                return success(try extract(object, operations: operations, wait: wait),
                               operation: operation)
            case "g04.archive.decompress":
                return success(try decompress(object, operations: operations, wait: wait),
                               operation: operation)
            case "g04.archive.previewEntry":
                return success(try previewEntry(object, previews: previews, wait: wait),
                               operation: operation)
            case "g04.archive.previewDiscard":
                return success(try previewDiscard(object, previews: previews, wait: wait),
                               operation: operation)
            case "g04.archive.progress":
                return success(try progress(object, operations: operations), operation: operation)
            case "g04.archive.cancel":
                return success(try cancel(object, operations: operations), operation: operation)
            default:
                return failure(.unsupportedOperation, operation: operation)
            }
        } catch let error as G04ArchiveError {
            return failure(error, operation: operation)
        } catch let error as ArchiveBrowseError {
            return failure(mapBrowse(error), operation: operation, detail: error.localizedDescription)
        } catch let error as G04DocumentError {
            return failure(mapDocument(error), operation: operation)
        } catch let error as WorkspaceToolError {
            return failure(.failed, operation: operation, detail: error.localizedDescription)
        } catch {
            return failure(.failed, operation: operation, detail: "\(error)")
        }
    }

    // MARK: Operations

    static func handshake() -> [String: Any] {
        [
            "version": G04ArchiveWire.version,
            "schema": G04ArchiveWire.schema,
            "operations": G04ArchiveWire.operations,
            "nativeFormats": ArchiveBrowserService.nativeFormats.sorted(),
            "singleFileFormats": ArchiveBrowserService.singleFileFormats.sorted(),
            "rar": [
                "supported": false,
                "reason": "Open RAR archives through task extraction",
            ],
            "limits": [
                "maxRequestBytes": G04ArchiveWire.maximumRequestBytes,
                "maxResponseBytes": G04ArchiveWire.maximumResponseBytes,
                "maxPreviewBytes": G04ArchiveWire.maximumPreviewBytes,
                "maxPreviewFileBytes": G04ArchiveWire.maximumPreviewFileBytes,
            ],
        ]
    }

    static func listing(_ object: [String: Any]) throws -> [String: Any] {
        let owner = try G04ArchiveOwner.parse(object["owner"])
        let path = try relativePath(object["relativePath"], error: .invalidPath)
        try preflightFormat(path, allowSingleFileListing: true)
        return try leasedJSONObject(owner, intent: .read, path: path, wait: true) { service, cancellation in
            let browser = ArchiveBrowserService(rootProvider: { service.guardResolver.rootURL })
            let value = try await browser.listing(
                relativePath: path,
                rootURL: service.guardResolver.rootURL,
                cancellation: cancellation)
            return [
                "format": value.format,
                "entryCount": value.entries.count,
                "truncated": value.truncated,
                "summary": value.summary,
                "entries": value.entries.map { entry in
                    [
                        "path": entry.path,
                        "isDirectory": entry.isDirectory,
                        "size": entry.size,
                    ]
                },
            ]
        }
    }

    static func extract(_ object: [String: Any],
                        operations: G04ArchiveOperationRegistry,
                        wait: Bool) throws -> [String: Any] {
        let owner = try G04ArchiveOwner.parse(object["owner"])
        let path = try relativePath(object["relativePath"], error: .invalidPath)
        let destination = try relativePath(object["destinationDir"], error: .invalidDestination)
        let operationID = try operationIdentifier(object)
        try preflightFormat(path, allowSingleFileListing: false)
        guard let format = ArchiveBrowserService.format(for: path),
              ArchiveBrowserService.nativeFormats.contains(format) else {
            throw G04ArchiveError.unsupportedFormat
        }
        return try leasedJSONObject(owner, intent: .fileMutation, path: destination, wait: wait) { service, cancellation in
            let token = operations.begin(owner: owner, operationID: operationID, parent: cancellation)
            defer { operations.end(operationID) }
            let browser = ArchiveBrowserService(rootProvider: { service.guardResolver.rootURL })
            let summary: String
            do {
                summary = try await browser.extract(
                    relativePath: path,
                    destinationDir: destination,
                    rootURL: service.guardResolver.rootURL,
                    cancellation: token) { progress in
                        operations.update(operationID, progress: progress)
                    }
            } catch {
                if token.isCancelled { throw G04ArchiveError.cancelled }
                throw error
            }
            return extractSummaryFields(summary, destination: destination)
        }
    }

    static func decompress(_ object: [String: Any],
                           operations: G04ArchiveOperationRegistry,
                           wait: Bool) throws -> [String: Any] {
        let owner = try G04ArchiveOwner.parse(object["owner"])
        let path = try relativePath(object["relativePath"], error: .invalidPath)
        let destination = try relativePath(object["destinationFile"], error: .invalidDestination)
        let operationID = try operationIdentifier(object)
        try preflightFormat(path, allowSingleFileListing: true)
        guard let format = ArchiveBrowserService.format(for: path),
              ArchiveBrowserService.singleFileFormats.contains(format) else {
            // Container formats extract through `g04.archive.extract`; a
            // single-file payload is the only valid input here.
            throw G04ArchiveError.unsupportedFormat
        }
        return try leasedJSONObject(owner, intent: .fileMutation, path: destination, wait: wait) { service, cancellation in
            let token = operations.begin(owner: owner, operationID: operationID, parent: cancellation)
            defer { operations.end(operationID) }
            let browser = ArchiveBrowserService(rootProvider: { service.guardResolver.rootURL })
            let summary: String
            do {
                summary = try await browser.decompress(
                    relativePath: path,
                    destinationFile: destination,
                    rootURL: service.guardResolver.rootURL,
                    cancellation: token) { progress in
                        operations.update(operationID, progress: progress)
                    }
            } catch {
                if token.isCancelled { throw G04ArchiveError.cancelled }
                throw error
            }
            return extractSummaryFields(summary, destination: destination)
        }
    }

    static func previewEntry(_ object: [String: Any],
                             previews: G04ArchivePreviewRegistry,
                             wait: Bool) throws -> [String: Any] {
        let owner = try G04ArchiveOwner.parse(object["owner"])
        let path = try relativePath(object["relativePath"], error: .invalidPath)
        let entry = try relativePath(object["entryPath"], error: .invalidEntry)
        let previewID = try previewIdentifier(object)
        guard previews.session(previewID, owner: owner, relativePath: path) else {
            throw G04ArchiveError.ownerChanged
        }
        return try leasedJSONObject(owner, intent: .read, path: path, wait: wait) { service, cancellation in
            let directory = try await ensurePreviewStaged(
                previews: previews, previewID: previewID, owner: owner,
                relativePath: path, service: service, cancellation: cancellation)
            guard let url = safeChild(root: service.guardResolver.rootURL,
                                      directory: directory, child: entry) else {
                throw G04ArchiveError.invalidEntry
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw G04ArchiveError.invalidEntry
            }
            let size = values.fileSize ?? 0
            guard size <= G04ArchiveWire.maximumPreviewFileBytes else {
                throw G04ArchiveError.failed
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard let text = String(data: data, encoding: .utf8) else {
                // Honest typed refusal, exactly like the original surface:
                // binary entries are previewable only after extraction.
                return [
                    "previewable": false,
                    "byteCount": size,
                    "truncated": false,
                    "message": "notUTF8",
                ]
            }
            var bounded = text
            var truncated = false
            if text.utf8.count > G04ArchiveWire.maximumPreviewBytes {
                var prefix = text.utf8.prefix(G04ArchiveWire.maximumPreviewBytes)
                while String(bytes: prefix, encoding: .utf8) == nil, !prefix.isEmpty {
                    prefix = prefix.dropLast()
                }
                bounded = String(decoding: prefix, as: UTF8.self)
                truncated = true
            }
            return [
                "previewable": true,
                "byteCount": size,
                "truncated": truncated,
                "text": bounded,
            ]
        }
    }

    static func previewDiscard(_ object: [String: Any],
                               previews: G04ArchivePreviewRegistry,
                               wait: Bool) throws -> [String: Any] {
        let owner = try G04ArchiveOwner.parse(object["owner"])
        let previewID = try previewIdentifier(object)
        guard let session = previews.takeForDiscard(previewID, owner: owner) else {
            return ["discarded": 0]
        }
        guard let directory = session.directory else {
            return ["discarded": 1]
        }
        return try leasedJSONObject(owner, intent: .fileMutation, path: directory, wait: wait) { service, _ in
            let url = service.guardResolver.rootURL.appendingPathComponent(directory, isDirectory: true)
            try? FileManager.default.removeItem(at: url)
            return ["discarded": 1]
        }
    }

    static func progress(_ object: [String: Any],
                         operations: G04ArchiveOperationRegistry) throws -> [String: Any] {
        let operationID = try operationIdentifier(object)
        guard let snapshot = operations.snapshot(operationID) else {
            throw G04ArchiveError.invalidOperationID
        }
        var value: [String: Any] = [
            "phase": snapshot.phase,
            "completedBytes": snapshot.completedBytes,
            "completedEntries": snapshot.completedEntries,
            "cancelled": snapshot.cancelled,
        ]
        if let total = snapshot.totalBytes { value["totalBytes"] = total }
        return value
    }

    static func cancel(_ object: [String: Any],
                       operations: G04ArchiveOperationRegistry) throws -> [String: Any] {
        let operationID = try operationIdentifier(object)
        guard operations.cancel(operationID) else {
            throw G04ArchiveError.invalidOperationID
        }
        return ["cancelled": true]
    }

    // MARK: - Internals

    /// The hidden staging directory one preview session extracts into. The
    /// reuse mirrors the original browser: the first selection performs the
    /// bounded extract; later selections read from the same staging.
    static func ensurePreviewStaged(previews: G04ArchivePreviewRegistry,
                                    previewID: UUID,
                                    owner: G04ArchiveOwner,
                                    relativePath: String,
                                    service: WorkspaceFileService,
                                    cancellation: CancellationToken) async throws -> String {
        if let existing = previews.stagedDirectory(previewID) { return existing }
        let directory = ".floe-archive-preview/\(UUID().uuidString)"
        let browser = ArchiveBrowserService(rootProvider: { service.guardResolver.rootURL })
        let format = ArchiveBrowserService.format(for: relativePath) ?? ""
        if ArchiveBrowserService.singleFileFormats.contains(format) {
            let name = (relativePath as NSString).lastPathComponent
            let derived = ArchiveEngine.decompressedName(for: name, format: format)
            let fileName = derived == name ? name + ".unpacked" : derived
            _ = try await browser.decompress(
                relativePath: relativePath,
                destinationFile: directory + "/" + fileName,
                rootURL: service.guardResolver.rootURL,
                cancellation: cancellation)
        } else {
            _ = try await browser.extract(
                relativePath: relativePath,
                destinationDir: directory,
                rootURL: service.guardResolver.rootURL,
                cancellation: cancellation)
        }
        previews.markStaged(previewID, directory: directory)
        return directory
    }

    /// Re-validates containment even though the engine already refused
    /// traversal entries; a staged path must stay inside its staging root.
    static func safeChild(root: URL, directory: String, child: String) -> URL? {
        let base = root.appendingPathComponent(directory, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let candidate = base.appendingPathComponent(child)
            .resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(base.path + "/") else { return nil }
        return candidate
    }

    /// Format checks that must fail BEFORE any lease is taken, so an
    /// obviously-unsupported document is refused without touching the
    /// workspace authority (and stays testable without a composition).
    /// Throws the ORIGINAL service error so the wire failure carries the
    /// same truthful reason the agent tool reports.
    static func preflightFormat(_ path: String, allowSingleFileListing: Bool) throws {
        guard let format = ArchiveBrowserService.format(for: path) else {
            throw ArchiveBrowseError.unsupportedFormat(
                format: "unknown",
                reason: "the file name has no archive extension this app recognises")
        }
        if ArchiveBrowserService.rarFormats.contains(format) {
            // Truthful original reason; the signed decoder capability is
            // inspected in the HANDOFF, never downloaded or faked here.
            throw ArchiveBrowseError.unsupportedFormat(
                format: format,
                reason: "Open RAR archives through task extraction")
        }
        if ArchiveBrowserService.nativeFormats.contains(format) { return }
        if ArchiveBrowserService.singleFileFormats.contains(format),
           allowSingleFileListing { return }
        throw ArchiveBrowseError.unsupportedFormat(
            format: format,
            reason: "this archive format is not supported")
    }

    static func extractSummaryFields(_ summary: String, destination: String) -> [String: Any] {
        // The engine's summary is the receipt: `status=ok action=extract
        // format=… source=… destination=… entries=N skipped=M
        // uncompressedBytes=B …`. Parse the bounded scalar fields; the full
        // line is returned too so the App can show the real receipt text.
        var fields: [String: Any] = ["destination": destination, "summary": summary]
        for part in summary.split(separator: " ") {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let key = String(part[..<equals])
            let value = String(part[part.index(after: equals)...])
            switch key {
            case "entries": fields["entries"] = Int(value) ?? 0
            case "skipped": fields["skipped"] = Int(value) ?? 0
            case "uncompressedBytes": fields["uncompressedBytes"] = Int64(value) ?? 0
            default: continue
            }
        }
        return fields
    }

    /// Runs `body` under the REAL owned workspace lease. The bridge thread
    /// blocks on the semaphore: the C ABI is invoked from a Kotlin IO thread,
    /// and the operation is physical file work, never main-thread work.
    // Keep mutable heterogeneous JSON on its owning task. Only immutable
    // serialized Data crosses the detached task's Sendable result boundary.
    private static func leasedJSONObject(
        _ owner: G04ArchiveOwner,
        intent: G04WorkspaceIntent,
        path: String?,
        wait: Bool,
        _ body: @escaping @Sendable (WorkspaceFileService, CancellationToken) async throws -> [String: Any]
    ) throws -> [String: Any] {
        let data: Data = try leased(owner, intent: intent, path: path, wait: wait) { service, cancellation in
            let object = try await body(service, cancellation)
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw G04ArchiveError.failed
        }
        return object
    }

    static func leased<T: Sendable>(_ owner: G04ArchiveOwner,
                                    intent: G04WorkspaceIntent,
                                    path: String?,
                                    wait: Bool,
                                    _ body: @escaping @Sendable (WorkspaceFileService, CancellationToken) async throws -> T) throws -> T {
        guard let installed = G02RuntimeComposition.shared.installedComposition,
              installed.epoch == G02NativeRootEpoch.readback(),
              G02NativeRootEpoch.readback() == owner.nativeEpoch else {
            throw G04ArchiveError.retired
        }
        let access = G04WorkspaceComposition.liveAccess(epoch: installed.epoch, installed: installed)
        let box = G04ArchiveBox<T>()
        let gate = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                let lease = try await access.acquire(owner: owner.workspaceOwner,
                                                     intent: intent, relativePath: path)
                do {
                    try lease.cancellation.throwIfCancelled()
                    let result = try await body(lease.service, lease.cancellation)
                    await lease.release()
                    box.value = .success(result)
                } catch {
                    await lease.release()
                    box.value = .failure(G04ArchiveErasedError(error))
                }
            } catch {
                box.value = .failure(G04ArchiveErasedError(error))
            }
            gate.signal()
        }
        if wait {
            let outcome = gate.wait(timeout: .now() + .seconds(operationSeconds))
            if outcome == .timedOut { throw G04ArchiveError.failed }
        }
        return try box.valueOrThrow()
    }

    // MARK: - Parsing helpers

    static func relativePath(_ value: Any?, error: G04ArchiveError) throws -> String {
        guard let raw = g04ArchiveString(value, maxBytes: 1024) else { throw error }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"),
              !trimmed.split(separator: "/").contains("..") else { throw error }
        return trimmed
    }

    static func operationIdentifier(_ object: [String: Any]) throws -> UUID {
        guard let raw = g04ArchiveString(object["operationID"], maxBytes: 64),
              let value = UUID(uuidString: raw) else {
            throw G04ArchiveError.invalidOperationID
        }
        return value
    }

    static func previewIdentifier(_ object: [String: Any]) throws -> UUID {
        guard let raw = g04ArchiveString(object["previewID"], maxBytes: 64),
              let value = UUID(uuidString: raw) else {
            throw G04ArchiveError.invalidPreviewID
        }
        return value
    }

    static func mapBrowse(_ error: ArchiveBrowseError) -> G04ArchiveError {
        switch error {
        case .unsupportedFormat: return .unsupportedFormat
        case .notFound: return .notFound
        case .failed: return .failed
        }
    }

    static func mapDocument(_ error: G04DocumentError) -> G04ArchiveError {
        switch error {
        case .retired: return .retired
        case .ownerChanged: return .ownerChanged
        default: return .failed
        }
    }
}

/// Error is not Sendable; the box is the synchronization boundary and the
/// wrapped value is only re-thrown on the waiting bridge thread.
struct G04ArchiveErasedError: Error, @unchecked Sendable {
    let base: Error
    init(_ base: Error) { self.base = base }
}

/// Locked result box mirroring the established `HostHopBox` seam.
final class G04ArchiveBox<T: Sendable>: @unchecked Sendable {
    enum Outcome: Sendable {
        case pending
        case success(T)
        case failure(G04ArchiveErasedError)
    }

    private let lock = NSLock()
    private var outcome: Outcome = .pending

    var value: Outcome {
        get {
            lock.lock(); defer { lock.unlock() }
            return outcome
        }
        set {
            lock.lock(); outcome = newValue; lock.unlock()
        }
    }

    func valueOrThrow() throws -> T {
        switch value {
        case .success(let value): return value
        case .failure(let error): throw error.base
        case .pending: throw G04ArchiveError.failed
        }
    }
}

func g04ArchiveString(_ value: Any?, maxBytes: Int) -> String? {
    guard let string = value as? String,
          !string.isEmpty,
          string.utf8.count <= maxBytes,
          !string.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
        return nil
    }
    return string
}

func g04ArchiveInt(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string) }
    return nil
}

func g04ArchiveUInt64(_ value: Any?) -> UInt64? {
    if let number = value as? NSNumber { return number.uint64Value }
    if let string = value as? String { return UInt64(string) }
    return nil
}
