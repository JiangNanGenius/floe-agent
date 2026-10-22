// FloeAndroidWorkspaceTools — durable session layout, owner markers and journal.
//
// Android-owned (job-ade884c46eb84ec1). Every write here lives OUTSIDE the
// granted workspace tree: Core-side metadata, staging and recovery artifacts
// sit under a dedicated transfer root derived from the trusted storage root
// (never inside `<storageRoot>/Workspace`), and the runtime-side journal sits
// as a SIBLING of the destination directory. No `.private` Core metadata can
// therefore ever appear inside an exported guest snapshot, and no guest path
// can address these directories by construction (containment refuses the
// reserved name prefixes too).
//
// Durability discipline: owner marker written + fsync BEFORE the first
// payload byte; each journal step fsynced before the effect it announces;
// baseline manifest fsynced before the session is reported ready; the
// terminal index is written last. A crash between effect and journal line is
// resolved by the sweep rules below, which NEVER delete an entry whose owner
// cannot be proven task-owned and finished.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

/// Session directory layout under the transfer root.
public struct WorkspaceTransferPaths: Sendable, Equatable {
    public let transferRoot: String
    public let sessionKey: String

    public init(transferRoot: String, sessionKey: String) {
        self.transferRoot = transferRoot
        self.sessionKey = sessionKey
    }

    public var sessionDirectory: String { "\(transferRoot)/sessions/\(sessionKey)" }
    public var ownerMarker: String { "\(sessionDirectory)/owner.json" }
    public var journal: String { "\(sessionDirectory)/journal.jsonl" }
    public var baselineManifest: String { "\(sessionDirectory)/baseline.jsonl" }
    public var stagingDirectory: String { "\(sessionDirectory)/staging" }
    public var conflictsDirectory: String { "\(sessionDirectory)/conflicts" }
    public var terminalIndex: String { "\(sessionDirectory)/index.json" }
    public var recoveredDirectory: String { "\(transferRoot)/recovered/\(sessionKey)" }

    public static let sessionKeyPattern = "^[0-9a-f]{32}$"

    public static func isValidSessionKey(_ raw: String) -> Bool {
        raw.range(of: sessionKeyPattern, options: .regularExpression) != nil
    }

    /// Derives the transfer root from the trusted storage root. The root is
    /// host-supplied (never model-supplied) and MUST be a direct sibling of
    /// the workspace directory, i.e. `<storageRoot>/WorkspaceTransfers`.
    public static func transferRoot(storageRoot: String) -> String {
        "\(storageRoot)/WorkspaceTransfers"
    }
}

/// The durable owner marker. Written before ANY payload work. A marker that
/// fails validation marks its session directory as an unknown owner: the
/// sweep preserves it.
public struct WorkspaceOwnerMarker: Sendable, Equatable, Codable {
    public var version: Int
    public var sessionKey: String
    public var grantID: String
    public var projectID: String
    public var runID: String
    public var rootEpoch: UInt64
    public var createdAtSeconds: Int64
    /// "active" | "terminal" — terminal kind/counters live in index.json.
    public var state: String

    public init(sessionKey: String, grantID: String, projectID: String, runID: String,
                rootEpoch: UInt64, createdAtSeconds: Int64) {
        self.version = 1
        self.sessionKey = sessionKey
        self.grantID = grantID
        self.projectID = projectID
        self.runID = runID
        self.rootEpoch = rootEpoch
        self.createdAtSeconds = createdAtSeconds
        self.state = "active"
    }

    /// Writes the marker with .withoutOverwriting + fsync; returns the fd-held
    /// durability result. The write happens via POSIX so the fsync is exact.
    public func writeDurable(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard fd >= 0 else {
            throw WorkspaceTransferError.ioFailed(stage: "markerOpen", errnoCode: Int32(errno))
        }
        defer { close(fd) }
        var written = 0
        try data.withUnsafeBytes { raw in
            while written < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw WorkspaceTransferError.ioFailed(stage: "markerWrite", errnoCode: Int32(code))
                }
                written += count
            }
        }
        if fsync(fd) != 0 {
            throw WorkspaceTransferError.ioFailed(stage: "markerFsync", errnoCode: Int32(errno))
        }
    }

    public func markTerminal(at path: String) throws {
        var updated = self
        updated.state = "terminal"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(updated)
        let staged = path + ".new"
        let fd = open(staged, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o600))
        guard fd >= 0 else {
            throw WorkspaceTransferError.ioFailed(stage: "markerRewrite", errnoCode: Int32(errno))
        }
        var written = 0
        var failure: WorkspaceTransferError?
        data.withUnsafeBytes { raw in
            while written < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    failure = .ioFailed(stage: "markerRewrite", errnoCode: Int32(code))
                    return
                }
                written += count
            }
            if fsync(fd) != 0 {
                failure = .ioFailed(stage: "markerRewriteFsync", errnoCode: Int32(errno))
            }
        }
        close(fd)
        if let failure {
            unlink(staged)
            throw failure
        }
        if rename(staged, path) != 0 {
            throw WorkspaceTransferError.ioFailed(stage: "markerRename", errnoCode: Int32(errno))
        }
        _ = WorkspaceNoFollow.fsyncDirectory((path as NSString).deletingLastPathComponent)
    }

    public static func load(path: String) -> WorkspaceOwnerMarker? {
        guard let data = try? Data(floeContentsOf: URL(fileURLWithPath: path)),
              let marker = try? JSONDecoder().decode(WorkspaceOwnerMarker.self, from: data) else {
            return nil
        }
        // Structural validity: the marker must describe the directory it is
        // found in and carry canonical identities. Anything else is an
        // UNKNOWN owner (preserved by sweeps), never a cleanup license.
        guard marker.version == 1,
              WorkspaceTransferPaths.isValidSessionKey(marker.sessionKey),
              marker.sessionKey.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
              marker.createdAtSeconds > 0,
              marker.rootEpoch > 0,
              UUID(uuidString: marker.projectID) != nil,
              UUID(uuidString: marker.runID) != nil,
              !marker.grantID.isEmpty, marker.grantID.utf8.count <= 64
        else { return nil }
        return marker
    }
}

/// Append-only fsynced journal. One JSON object per line; readers only need
/// the last record of each type, and the file is bounded by the number of
/// state steps (per-entry staging results are summarized, not journaled one
/// line per byte).
public final class WorkspaceJournal: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()

    public init(path: String) {
        self.path = path
    }

    public func append(_ record: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else {
            throw WorkspaceTransferError.malformed
        }
        var line = data
        line.append(UInt8(ascii: "\n"))
        lock.lock()
        defer { lock.unlock() }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o600))
        guard fd >= 0 else {
            throw WorkspaceTransferError.ioFailed(stage: "journalOpen", errnoCode: Int32(errno))
        }
        defer { close(fd) }
        var written = 0
        let failure: WorkspaceTransferError? = line.withUnsafeBytes { raw in
            while written < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    return .ioFailed(stage: "journalWrite", errnoCode: Int32(code))
                }
                written += count
            }
            if fsync(fd) != 0 {
                return .ioFailed(stage: "journalFsync", errnoCode: Int32(errno))
            }
            return nil
        }
        if let failure { throw failure }
    }

    /// All records, oldest first. Malformed trailing line (crash mid-write)
    /// is dropped with `truncatedTail` set; earlier corruption is a typed
    /// failure (unknown journal state never authorizes deletion).
    public static func read(path: String) throws -> (records: [[String: Any]], truncatedTail: Bool) {
        guard let data = try? Data(floeContentsOf: URL(fileURLWithPath: path)) else {
            return ([], false)
        }
        var records: [[String: Any]] = []
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        var truncatedTail = false
        for (index, lineData) in lines.enumerated() {
            if lineData.isEmpty { continue }
            // A line without a terminating newline is a torn tail ONLY if it
            // is the last one; anywhere else it is corruption.
            let isLast = index == lines.count - 1
            let bytes = Data(lineData)
            if isLast { truncatedTail = truncatedTail || data.last != UInt8(ascii: "\n") }
            guard let object = try? JSONSerialization.jsonObject(with: bytes),
                  let record = object as? [String: Any] else {
                if isLast { truncatedTail = true; continue }
                throw WorkspaceTransferError.malformed
            }
            records.append(record)
        }
        return (records, truncatedTail)
    }
}
