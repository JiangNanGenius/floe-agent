// FloeAndroidWorkspaceTools — baseline manifest: the ACTUAL-FS revision
// record a safe writeback must respect.
//
// Android-owned (job-ade884c46eb84ec1). The baseline is scanned from the real
// Core workspace at import-begin with non-following metadata and streaming
// digests of the bytes as read. It is the "expected" side of every CAS later
// (`AtomicFileCommitter.Conflict.replaceIfUnchanged(expectedSHA256:)` and the
// digest re-verify before any unlink). mtime is recorded only as bounded
// diagnostic; it NEVER decides a writeback.
//
// Budget overruns fail the session honestly. There is no truncated/partial
// baseline: a half-mirrored workspace would make every later "created" vs
// "modified" classification a guess.

import Foundation
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

public struct WorkspaceBaselineEntry: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case file, directory, symlink
    }

    public struct Skipped: Sendable, Equatable, Codable {
        public enum Reason: String, Sendable, Codable {
            case specialFile           // fifo/socket/device: never transferred
            case externalLink          // absolute/escaping symlink target
            case unreadable            // non-ENOENT lstat failure
            case overlong              // path/name exceeded recorded caps mid-scan
        }
        public var reason: Reason
        /// Bounded workspace-relative path (the caller's own data).
        public var path: String
    }

    public var relativePath: String
    public var kind: Kind
    /// Bytes captured by fstat on the O_NOFOLLOW fd that produced the digest.
    public var size: Int64
    /// Permission bits observed by lstat (0o7777 masked).
    public var mode: Int32
    /// SHA-256 of the EXACT bytes read through the no-follow fd. Files only.
    public var digest: String?
    /// Raw recorded target for symlinks classified `.relativeContained`.
    public var linkTarget: String?
    /// Present when the entry was NOT mirrored into the grant snapshot.
    public var skipped: Skipped?

    public init(relativePath: String, kind: Kind, size: Int64, mode: Int32,
                digest: String?, linkTarget: String? = nil, skipped: Skipped? = nil) {
        self.relativePath = relativePath
        self.kind = kind
        self.size = size
        self.mode = mode
        self.digest = digest
        self.linkTarget = linkTarget
        self.skipped = skipped
    }

    public var dictionaryValue: [String: Any] {
        var object: [String: Any] = [
            "path": relativePath,
            "kind": kind.rawValue,
            "size": size,
            "mode": mode,
        ]
        object["digest"] = digest
        object["linkTarget"] = linkTarget
        if let skipped {
            object["skipped"] = ["reason": skipped.reason.rawValue, "path": skipped.path]
        }
        return object
    }

    static func from(dictionary: [String: Any]) -> WorkspaceBaselineEntry? {
        guard let path = dictionary["path"] as? String,
              let kindRaw = dictionary["kind"] as? String,
              let kind = Kind(rawValue: kindRaw),
              let size = dictionary["size"] as? NSNumber,
              let mode = dictionary["mode"] as? NSNumber else { return nil }
        var skipped: Skipped?
        if let raw = dictionary["skipped"] as? [String: Any],
           let reasonRaw = raw["reason"] as? String,
           let reason = Skipped.Reason(rawValue: reasonRaw),
           let skippedPath = raw["path"] as? String {
            skipped = Skipped(reason: reason, path: skippedPath)
        }
        return WorkspaceBaselineEntry(relativePath: path, kind: kind,
                                      size: size.int64Value, mode: Int32(truncatingWithTruncating: mode.int64Value),
                                      digest: dictionary["digest"] as? String,
                                      linkTarget: dictionary["linkTarget"] as? String,
                                      skipped: skipped)
    }
}

extension Int32 {
    /// Narrow helper: NSNumber.int64Value -> Int32 with bit truncation
    /// (mode bits are already masked to 0o7777 at capture).
    fileprivate init(truncatingWithTruncating value: Int64) {
        self = Int32(truncatingIfNeeded: value)
    }
}

/// fd-held streaming digest so baseline/verify/open paths all hash the SAME
/// bytes the descriptor shows, never a re-opened path.
public enum WorkspaceDigest {
    public static func sha256Hex(fromFd fd: Int32, frameBytes: Int,
                                 isCancelled: () -> Bool) -> Result<(String, Int64), WorkspaceTransferError> {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Android)
        var hasher = SHA256()
        let frame = max(4_096, min(frameBytes, 262_144))
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: frame, alignment: 1)
        defer { buffer.deallocate() }
        var hashed: Int64 = 0
        while true {
            if isCancelled() { return .failure(.cancelled) }
            let count = read(fd, buffer, frame)
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                return .failure(.ioFailed(stage: "digestRead", errnoCode: Int32(code)))
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            hashed += Int64(count)
        }
        return .success((hasher.finalize().map { String(format: "%02x", $0) }.joined(), hashed))
        #else
        return .failure(.ioFailed(stage: "digestUnsupported", errnoCode: -1))
        #endif
    }
}

// MARK: - Scanner

public struct WorkspaceBaselineScan: Sendable {
    /// key: canonical relative path (component-joined). Mirrored + skipped
    /// entries are ALL here; commit classification consults `skipped` so a
    /// skipped entry is never mistaken for "absent from Core".
    public var entries: [String: WorkspaceBaselineEntry]
    public var totalMirroredBytes: Int64
    public var mirroredFileCount: Int
    public var directoryCount: Int
    public var safeLinkCount: Int
    public var skipped: [WorkspaceBaselineEntry.Skipped]

    public init() {
        self.entries = [:]
        self.totalMirroredBytes = 0
        self.mirroredFileCount = 0
        self.directoryCount = 0
        self.safeLinkCount = 0
        self.skipped = []
    }
}

public enum WorkspaceBaselineScanner {
    /// Scans `workspaceRoot` (absolute, already proven a real no-follow
    /// directory by the caller) into a durable baseline manifest at
    /// `manifestPath` (JSONL, fsynced) and returns the in-memory plan.
    public static func scan(workspaceRoot: String, manifestPath: String,
                            budgets: WorkspaceTransferBudgets,
                            isCancelled: () -> Bool) throws -> WorkspaceBaselineScan {
        var plan = WorkspaceBaselineScan()
        var caseKeys: [String: String] = [:]
        var queue: [(prefix: String, depth: Int)] = [("", 0)]
        var totalEntries = 0
        while let (prefix, depth) = queue.popLast() {
            if isCancelled() { throw WorkspaceTransferError.cancelled }
            let levelPath = prefix.isEmpty ? workspaceRoot : workspaceRoot + "/" + prefix
            var names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: levelPath)
            } catch let error as NSError {
                // A vanished level mid-scan (deleted by user during import)
                // is absence for the sublevel, recorded honestly.
                if error.code == Int(ENOENT) { continue }
                throw WorkspaceTransferError.ioFailed(stage: "scanDir", errnoCode: Int32(error.code))
            }
            for name in names.sorted() {
                if isCancelled() { throw WorkspaceTransferError.cancelled }
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                // Full re-validation per entry (defense in depth on the ACTUAL
                // names: a weird name on disk cannot smuggle traversal).
                do {
                    _ = try WorkspaceRelativePath.validate(relative, budgets: budgets)
                } catch let failure as WorkspaceTransferError {
                    if case .pathUnsafe(let code) = failure {
                        plan.skipped.append(.init(reason: code == "overlongTotal" || code == "overlongComponent"
                                                    ? .overlong : .specialFile, path: relative))
                        continue
                    }
                    throw failure
                }
                totalEntries += 1
                guard totalEntries <= budgets.entryCount else {
                    throw WorkspaceTransferError.budgetExceeded(code: "entryCount")
                }
                let caseKey = WorkspaceRelativePath.caseFoldKey(relative)
                if let existing = caseKeys[caseKey], existing != relative {
                    // Two entries differing only in case: refuse BOTH (never
                    // guess which one the guest FS view will resolve).
                    for collisionPath in [existing, relative] {
                        plan.entries[collisionPath] = WorkspaceBaselineEntry(
                            relativePath: collisionPath, kind: .directory, size: 0, mode: 0, digest: nil,
                            skipped: .init(reason: .specialFile, path: collisionPath))
                        plan.skipped.append(.init(reason: .specialFile, path: collisionPath))
                    }
                    continue
                }
                caseKeys[caseKey] = relative
                let absolute = workspaceRoot + "/" + relative
                guard let meta = WorkspaceNoFollow.metadata(absolute) else {
                    plan.entries[relative] = WorkspaceBaselineEntry(
                        relativePath: relative, kind: .directory, size: 0, mode: 0, digest: nil,
                        skipped: .init(reason: .unreadable, path: relative))
                    plan.skipped.append(.init(reason: .unreadable, path: relative))
                    continue
                }
                switch meta.kind {
                case .file:
                    guard meta.size <= budgets.maximumEntryBytes else {
                        throw WorkspaceTransferError.budgetExceeded(code: "entryBytes")
                    }
                    if plan.totalMirroredBytes + meta.size > budgets.totalBytes {
                        throw WorkspaceTransferError.budgetExceeded(code: "totalBytes")
                    }
                    switch WorkspaceNoFollow.openRegularNoFollow(absolute) {
                    case .failure(let error):
                        // Skipped placeholder: `kind` carries no transfer
                        // meaning here; the `skipped` record decides the
                        // entry's fate at commit (never mirrored, never
                        // deleted). `kind: .directory` is the documented
                        // placeholder for skipped entries.
                        plan.entries[relative] = WorkspaceBaselineEntry(
                            relativePath: relative, kind: .directory, size: 0, mode: meta.mode, digest: nil,
                            skipped: .init(reason: .unreadable, path: relative))
                        plan.skipped.append(.init(reason: .unreadable, path: relative))
                        if case .cancelled = error { throw error }
                    case .success(let fd):
                        defer { close(fd) }
                        switch WorkspaceDigest.sha256Hex(fromFd: fd, frameBytes: budgets.frameBytes,
                                                         isCancelled: isCancelled) {
                        case .success(let outcome):
                            plan.entries[relative] = WorkspaceBaselineEntry(
                                relativePath: relative, kind: .file,
                                size: outcome.1, mode: meta.mode, digest: outcome.0)
                            plan.totalMirroredBytes += outcome.1
                            plan.mirroredFileCount += 1
                        case .failure(.cancelled):
                            throw WorkspaceTransferError.cancelled
                        case .failure(let error):
                            plan.entries[relative] = WorkspaceBaselineEntry(
                                relativePath: relative, kind: .directory, size: 0, mode: meta.mode, digest: nil,
                                skipped: .init(reason: .unreadable, path: relative))
                            plan.skipped.append(.init(reason: .unreadable, path: relative))
                            _ = error
                        }
                    }
                case .directory:
                    plan.entries[relative] = WorkspaceBaselineEntry(
                        relativePath: relative, kind: .directory, size: 0, mode: meta.mode, digest: nil)
                    plan.directoryCount += 1
                    guard depth + 1 <= WorkspaceRelativePath.maximumComponents else {
                        plan.skipped.append(.init(reason: .overlong, path: relative))
                        continue
                    }
                    queue.append((relative, depth + 1))
                case .symlink:
                    guard let target = WorkspaceNoFollow.readlink(absolute, limit: budgets.maximumLinkTargetBytes) else {
                        plan.entries[relative] = WorkspaceBaselineEntry(
                            relativePath: relative, kind: .symlink, size: 0, mode: meta.mode, digest: nil,
                            skipped: .init(reason: .unreadable, path: relative))
                        plan.skipped.append(.init(reason: .unreadable, path: relative))
                        continue
                    }
                    let components = relative.split(separator: "/").map(String.init)
                    switch WorkspaceRelativePath.classifyLinkTarget(target, linkComponents: components, budgets: budgets) {
                    case .relativeContained:
                        plan.entries[relative] = WorkspaceBaselineEntry(
                            relativePath: relative, kind: .symlink, size: 0, mode: 0o777, digest: nil,
                            linkTarget: target)
                        plan.safeLinkCount += 1
                    case .external:
                        // Kept in place on Core, never mirrored, never followed.
                        plan.entries[relative] = WorkspaceBaselineEntry(
                            relativePath: relative, kind: .symlink, size: 0, mode: 0, digest: nil,
                            skipped: .init(reason: .externalLink, path: relative))
                        plan.skipped.append(.init(reason: .externalLink, path: relative))
                    }
                case .special:
                    plan.entries[relative] = WorkspaceBaselineEntry(
                        relativePath: relative, kind: .directory, size: 0, mode: 0, digest: nil,
                        skipped: .init(reason: .specialFile, path: relative))
                    plan.skipped.append(.init(reason: .specialFile, path: relative))
                case .missing:
                    // Vanished between contentsOfDirectory and lstat: record
                    // absence honestly; no entry.
                    continue
                case .unreadable:
                    plan.entries[relative] = WorkspaceBaselineEntry(
                        relativePath: relative, kind: .directory, size: 0, mode: 0, digest: nil,
                        skipped: .init(reason: .unreadable, path: relative))
                    plan.skipped.append(.init(reason: .unreadable, path: relative))
                }
            }
        }
        try writeManifest(manifestPath: manifestPath, plan: plan, budgets: budgets)
        return plan
    }

    /// Durable baseline: one JSON object per entry, fsynced. `missing` and
    /// skipped entries are stored too, because export classification needs
    /// the complete expected-view, not only the mirrored subset.
    static func writeManifest(manifestPath: String, plan: WorkspaceBaselineScan,
                      budgets: WorkspaceTransferBudgets) throws {
        let fd = open(manifestPath, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o600))
        guard fd >= 0 else {
            throw WorkspaceTransferError.ioFailed(stage: "manifestOpen", errnoCode: Int32(errno))
        }
        defer { close(fd) }
        let header: [String: Any] = [
            "record": "baselineHeader",
            "budgets": budgets.dictionaryValue,
            "totalMirroredBytes": plan.totalMirroredBytes,
            "mirroredFileCount": plan.mirroredFileCount,
            "directoryCount": plan.directoryCount,
            "safeLinkCount": plan.safeLinkCount,
        ]
        try writeLine(header, toFd: fd)
        for key in plan.entries.keys.sorted() {
            if let entry = plan.entries[key] {
                try writeLine(entry.dictionaryValue, toFd: fd)
            }
        }
        if fsync(fd) != 0 {
            throw WorkspaceTransferError.ioFailed(stage: "manifestFsync", errnoCode: Int32(errno))
        }
        _ = WorkspaceNoFollow.fsyncDirectory((manifestPath as NSString).deletingLastPathComponent)
    }

    private static func writeLine(_ object: [String: Any], toFd fd: Int32) throws {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            throw WorkspaceTransferError.malformed
        }
        data.append(UInt8(ascii: "\n"))
        var written = 0
        let failure: WorkspaceTransferError? = data.withUnsafeBytes { raw in
            while written < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    return .ioFailed(stage: "manifestWrite", errnoCode: Int32(code))
                }
                written += count
            }
            return nil
        }
        if let failure { throw failure }
    }

    /// Loads a durable baseline for commit. A manifest that fails validation
    /// is a typed failure — an unknown baseline NEVER authorizes any write.
    public static func load(manifestPath: String) throws -> WorkspaceBaselineScan {
        guard let data = try? Data(floeContentsOf: URL(fileURLWithPath: manifestPath)) else {
            throw WorkspaceTransferError.noSession
        }
        var plan = WorkspaceBaselineScan()
        var seenHeader = false
        for lineData in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(lineData)),
                  let dictionary = object as? [String: Any] else {
                throw WorkspaceTransferError.malformed
            }
            if (dictionary["record"] as? String) == "baselineHeader" {
                seenHeader = true
                plan.totalMirroredBytes = (dictionary["totalMirroredBytes"] as? NSNumber)?.int64Value ?? 0
                plan.mirroredFileCount = (dictionary["mirroredFileCount"] as? NSNumber)?.intValue ?? 0
                plan.directoryCount = (dictionary["directoryCount"] as? NSNumber)?.intValue ?? 0
                plan.safeLinkCount = (dictionary["safeLinkCount"] as? NSNumber)?.intValue ?? 0
                continue
            }
            guard seenHeader, let entry = WorkspaceBaselineEntry.from(dictionary: dictionary) else {
                throw WorkspaceTransferError.malformed
            }
            plan.entries[entry.relativePath] = entry
            if let skipped = entry.skipped { plan.skipped.append(skipped) }
        }
        guard seenHeader else { throw WorkspaceTransferError.malformed }
        return plan
    }
}
