// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Foundation

public struct DeviceWorkspaceReceiveProgress: Equatable, Sendable {
    public let total: Int
    public fileprivate(set) var processed = 0
    public fileprivate(set) var savedFiles = 0
    public fileprivate(set) var conflicts = 0
    /// Baseline-confirmed removals applied on this device because the peer
    /// no longer shares them and the local copy still matched the shared
    /// baseline exactly.
    public fileprivate(set) var deletedFiles = 0
    /// Baseline-confirmed renames converged locally without re-transferring
    /// bytes (or the source spelling dropped after identical content was
    /// found at the destination).
    public fileprivate(set) var movedFiles = 0
    /// Manifest-absent baseline paths that were NOT exact safe cases: the
    /// local file was kept and this receipt records that decision.
    public fileprivate(set) var preservedRemovals = 0
}

/// Baseline entries no longer present in the peer manifest must never be
/// touched by default (`.v1`, the original keep-local behavior). `.v2` is
/// negotiated per peer and converges renames and deletions only when the
/// local copy is still the exactly confirmed shared baseline.
public enum DeviceWorkspaceConvergence: Int, Sendable, Equatable {
    case v1 = 1
    case v2 = 2
}

/// A rename the receiver converged locally, reported to the sender so both
/// confirmed baselines keep the same spelling.
public struct DeviceWorkspaceMove: Sendable, Equatable {
    public let key: String
    public let path: String
    public let digest: String

    public init(key: String, path: String, digest: String) {
        self.key = key
        self.path = path
        self.digest = digest
    }
}

private struct ConvergenceReport: Sendable {
    var removals: [String] = []
    var moves: [DeviceWorkspaceMove] = []
}

/// Both Apple hosts bind this to the conversation's authoritative local
/// workspace. The directory URL and scope never enter the wire protocol.
public final class DeviceWorkspaceSyncHost: Sendable {
    struct Prepared: Sendable {
        let directory: DeviceWorkspaceDirectory
        let entries: [DeviceWorkspaceDirectory.Scanned]
        let manifest: Data
        let digest: String
    }

    private let resolve: @MainActor @Sendable (UUID, Bool) async throws -> DeviceWorkspaceRoot
    private let ledger: DeviceWorkspaceLedger
    public let canPropagateWorkspaceChanges: Bool
    let didImport: @MainActor @Sendable (UUID) async -> Void

    public init(resolve: @escaping @MainActor @Sendable (UUID, Bool) async throws -> DeviceWorkspaceRoot,
                ledgerDirectory: URL,
                canPropagateWorkspaceChanges: Bool = false,
                didImport: @escaping @MainActor @Sendable (UUID) async -> Void = { _ in }) {
        self.resolve = resolve
        ledger = DeviceWorkspaceLedger(directory: ledgerDirectory)
        self.canPropagateWorkspaceChanges = canPropagateWorkspaceChanges
        self.didImport = didImport
    }

    func shareScope(for id: UUID) async throws -> String {
        let directory = try await open(id, receiving: false)
        try await directory.validate()
        return directory.lease.scope
    }

    func prepare(_ taskID: UUID, scope: String) async throws -> Prepared {
        let directory = try await open(taskID, receiving: false)
        guard directory.lease.scope == scope else { throw DeviceHistorySyncError.notShared }
        try await directory.validate()
        let entries = try directory.scan()
        let manifest = try DeviceWorkspaceManifest(entries: entries.map(\.entry)).validated()
        let bytes = try JSONEncoder().encode(manifest)
        guard bytes.count <= DeviceWorkspaceManifest.maximumManifestBytes else { throw DeviceHistorySyncError.tooLarge }
        try await directory.validate()
        return Prepared(directory: directory, entries: entries, manifest: bytes,
                        digest: DeviceWorkspaceDigest.hex(SHA256.hash(data: bytes)))
    }

    func confirm(_ indexes: [Int], removals: [String] = [], moves: [DeviceWorkspaceMove] = [],
                 from peerID: String, taskID: UUID, prepared: Prepared) async throws {
        guard !indexes.isEmpty || !removals.isEmpty || !moves.isEmpty else {
            throw DeviceHistorySyncError.invalidResponse
        }
        guard indexes.count <= DeviceWorkspaceManifest.confirmationLimit,
              Set(indexes).count == indexes.count,
              indexes.allSatisfy({ prepared.entries.indices.contains($0) && prepared.entries[$0].entry.kind == .file }) else {
            throw DeviceHistorySyncError.invalidResponse
        }
        // Convergence receipts only shrink or relocate the confirmed baseline;
        // they can never introduce new bytes beyond the prepared snapshot.
        guard removals.count <= Self.maximumConvergenceReceipt,
              Set(removals).count == removals.count,
              removals.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1_024 }) else {
            throw DeviceHistorySyncError.invalidResponse
        }
        guard moves.count <= DeviceWorkspaceManifest.confirmationLimit,
              Set(moves.map(\.key)).count == moves.count,
              Set(moves.map({ DeviceWorkspacePath.comparisonKey($0.path) })).count == moves.count,
              moves.allSatisfy({
                  !$0.key.isEmpty && $0.key.utf8.count <= 1_024
                      && DeviceWorkspacePath.isSyncable($0.path)
                      && DeviceWorkspaceDigest.isValid($0.digest)
              }) else {
            throw DeviceHistorySyncError.invalidResponse
        }
        let scope = prepared.directory.lease.scope
        if !removals.isEmpty || !moves.isEmpty {
            let present = Set(prepared.entries.map { DeviceWorkspacePath.comparisonKey($0.entry.path) })
            let baseline = try await ledger.read(peerID: peerID, taskID: taskID, scope: scope)
            guard removals.allSatisfy({ !present.contains($0) }),
                  moves.allSatisfy({ move in
                      let destinationKey = DeviceWorkspacePath.comparisonKey(move.path)
                      let recorded = baseline[move.key] ?? baseline[destinationKey]
                      return !present.contains(move.key) && recorded?.digest == move.digest
                  }) else {
                throw DeviceHistorySyncError.invalidResponse
            }
        }
        var relocated: [DeviceWorkspaceEntry] = []
        for move in moves {
            guard !removals.contains(move.key),
                  let destination = prepared.entries.first(where: {
                      $0.entry.kind == .file
                          && DeviceWorkspacePath.comparisonKey($0.entry.path) == DeviceWorkspacePath.comparisonKey(move.path)
                          && $0.entry.digest == move.digest
                  }), try prepared.directory.matches(destination) else {
                throw DeviceHistorySyncError.invalidResponse
            }
            relocated.append(destination.entry)
        }
        try await prepared.directory.validate()
        var entries: [DeviceWorkspaceEntry] = []
        for index in indexes {
            let item = prepared.entries[index]
            if (try? prepared.directory.matches(item)) == true { entries.append(item.entry) }
        }
        try await ledger.record(entries + relocated, removing: removals + moves.map(\.key),
                                peerID: peerID, taskID: taskID, scope: scope)
    }

    private static let maximumConvergenceReceipt = 1_024

    func receive(
        _ manifest: DeviceWorkspaceManifest,
        from peerID: String,
        taskID: UUID,
        convergence: DeviceWorkspaceConvergence = .v1,
        read: (Int, Int64, Int) async throws -> Data,
        confirm: ([Int], [String], [DeviceWorkspaceMove]) async throws -> Void,
        onProgress: @Sendable (DeviceWorkspaceReceiveProgress) async -> Void
    ) async throws {
        let directory = try await open(taskID, receiving: true)
        let scope = directory.lease.scope
        let baseline = try await ledger.read(peerID: peerID, taskID: taskID, scope: scope)
        var progress = DeviceWorkspaceReceiveProgress(total: manifest.entries.count)
        var receipt = ConvergenceReport()
        if convergence == .v2, canPropagateWorkspaceChanges {
            receipt = try await converge(directory: directory, manifest: manifest, baseline: baseline,
                                         peerID: peerID, taskID: taskID, scope: scope, progress: &progress)
        }
        var pending: [Int] = []
        await onProgress(progress)

        for (index, entry) in manifest.entries.enumerated() {
            try await directory.validate()
            switch entry.kind {
            case .directory:
                do {
                    try directory.createDirectory(at: entry.path)
                } catch DeviceHistorySyncError.conflict {
                    try directory.createDirectory(at: directory.conflictPath(for: entry))
                    progress.conflicts += 1
                }
            case .file:
                let key = DeviceWorkspacePath.comparisonKey(entry.path)
                switch try await receiveFile(entry, in: directory, baseline: baseline[key]?.digest, read: { offset, count in
                    try await read(index, offset, count)
                }) {
                case .unchanged: pending.append(index)
                case .written: pending.append(index); progress.savedFiles += 1
                case .keptLocal: break
                case .conflict: progress.conflicts += 1
                }
            }
            progress.processed += 1
            await onProgress(progress)
            if pending.count == DeviceWorkspaceManifest.confirmationLimit {
                try await directory.validate()
                try await record(pending, manifest: manifest, peerID: peerID, taskID: taskID, scope: scope,
                                 receipt: receipt, confirm: confirm)
                receipt = ConvergenceReport()
                pending.removeAll(keepingCapacity: true)
            }
        }
        if !pending.isEmpty || !receipt.removals.isEmpty || !receipt.moves.isEmpty {
            try await directory.validate()
            try await record(pending, manifest: manifest, peerID: peerID, taskID: taskID, scope: scope,
                             receipt: receipt, confirm: confirm)
        }
    }

    /// Converges manifest-absent baseline entries before any content is
    /// transferred, so a peer rename reuses the already-confirmed local
    /// bytes instead of downloading them again. Every decision requires the
    /// exact confirmed baseline identity; anything else is kept locally and
    /// reported through `preservedRemovals`.
    private func converge(
        directory: DeviceWorkspaceDirectory,
        manifest: DeviceWorkspaceManifest,
        baseline: [String: DeviceWorkspaceRecordedFile],
        peerID: String,
        taskID: UUID,
        scope: String,
        progress: inout DeviceWorkspaceReceiveProgress
    ) async throws -> ConvergenceReport {
        let manifestKeys = Set(manifest.entries.filter { $0.kind == .file }.map { DeviceWorkspacePath.comparisonKey($0.path) })
        let removedKeys = baseline.keys.filter { !manifestKeys.contains($0) }.sorted()
        guard !removedKeys.isEmpty else { return ConvergenceReport() }
        // A rename shows up as a baseline path disappearing while a new
        // manifest path carries the identical confirmed digest. Only paths
        // that are themselves new can be rename destinations.
        var candidates: [String: [DeviceWorkspaceEntry]] = [:]
        for entry in manifest.entries where entry.kind == .file {
            let key = DeviceWorkspacePath.comparisonKey(entry.path)
            guard !baseline.keys.contains(key), let digest = entry.digest else { continue }
            candidates[digest, default: []].append(entry)
        }
        for digest in candidates.keys {
            candidates[digest]?.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        }
        var consumed = Set<String>()
        var report = ConvergenceReport()
        for (index, key) in removedKeys.enumerated() {
            if report.moves.count == DeviceWorkspaceManifest.confirmationLimit
                || report.removals.count == Self.maximumConvergenceReceipt {
                progress.preservedRemovals += removedKeys.count - index
                break
            }
            try Task.checkCancellation()
            try await directory.validate()
            guard let recorded = baseline[key] else { continue }
            if let destination = candidates[recorded.digest]?.first(where: {
                !consumed.contains(DeviceWorkspacePath.comparisonKey($0.path))
            }) {
                let destinationKey = DeviceWorkspacePath.comparisonKey(destination.path)
                switch try directory.move(locatingKey: key, digest: recorded.digest,
                                          pathHint: recorded.path, to: destination.path) {
                case .moved:
                    consumed.insert(destinationKey)
                    report.moves.append(.init(key: key, path: destination.path, digest: recorded.digest))
                    progress.movedFiles += 1
                    try await ledger.record([destination], removing: [key],
                                            peerID: peerID, taskID: taskID, scope: scope)
                case .preserved:
                    progress.preservedRemovals += 1
                }
            } else {
                switch try directory.trash(locatingKey: key, digest: recorded.digest, pathHint: recorded.path) {
                case .removed:
                    report.removals.append(key)
                    progress.deletedFiles += 1
                    try await ledger.remove([key], peerID: peerID, taskID: taskID, scope: scope)
                case .preserved:
                    progress.preservedRemovals += 1
                }
            }
        }
        return report
    }

    private enum FileOutcome { case unchanged, written, keptLocal, conflict }

    private func receiveFile(
        _ entry: DeviceWorkspaceEntry, in directory: DeviceWorkspaceDirectory, baseline: String?,
        read: (Int64, Int) async throws -> Data
    ) async throws -> FileOutcome {
        guard let digest = entry.digest, let size = entry.size else { throw DeviceHistorySyncError.invalidResponse }
        let local: DeviceWorkspaceDirectory.FileVersion?
        let blocked: Bool
        do {
            local = try directory.version(at: entry.path)
            blocked = false
        } catch DeviceHistorySyncError.conflict {
            local = nil
            blocked = true
        }
        if local?.digest == digest { return .unchanged }
        if baseline == digest { return .keptLocal }
        let canReplace = !blocked && local?.digest == baseline
        let conflict = directory.conflictPath(for: entry)
        if !canReplace, try directory.version(at: conflict)?.digest == digest { return .conflict }
        let staged = try directory.stage()
        var offset: Int64 = 0
        while offset < size {
            try Task.checkCancellation()
            let count = Int(min(Int64(DeviceWorkspaceManifest.chunkSize), size - offset))
            let bytes = try await read(offset, count)
            guard bytes.count == count else { throw DeviceHistorySyncError.invalidResponse }
            try staged.append(bytes)
            offset += Int64(bytes.count)
        }
        try staged.seal(size: size, digest: digest)
        try await directory.validate()
        if canReplace {
            do {
                try directory.commit(staged, path: entry.path, replacing: local)
                return .written
            } catch DeviceHistorySyncError.conflict {
                // A concurrent write after staging must also be preserved.
                if (try? directory.version(at: entry.path))?.digest == digest { return .unchanged }
            }
        }
        if try directory.version(at: conflict)?.digest != digest {
            try directory.commit(staged, path: conflict, replacing: nil)
        }
        return .conflict
    }

    private func record(
        _ indexes: [Int], manifest: DeviceWorkspaceManifest, peerID: String, taskID: UUID, scope: String,
        receipt: ConvergenceReport,
        confirm: ([Int], [String], [DeviceWorkspaceMove]) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try await ledger.record(indexes.map { manifest.entries[$0] }, peerID: peerID, taskID: taskID, scope: scope)
        try await confirm(indexes, receipt.removals, receipt.moves)
    }

    private func open(_ taskID: UUID, receiving: Bool) async throws -> DeviceWorkspaceDirectory {
        let root = try await resolve(taskID, receiving)
        return try DeviceWorkspaceDirectory(root)
    }
}

/// One confirmed baseline file. `path` keeps the exact on-disk spelling so
/// later syncs can converge removals without rescanning the tree; entries
/// recorded before paths were kept decode with `path == nil` and fall back
/// to a comparison-key lookup.
struct DeviceWorkspaceRecordedFile: Sendable, Equatable, Codable {
    var digest: String
    var path: String?
}

private actor DeviceWorkspaceLedger {
    let directory: URL

    init(directory: URL) { self.directory = directory }

    func read(peerID: String, taskID: UUID, scope: String) throws -> [String: DeviceWorkspaceRecordedFile] {
        try read(at: url(peerID: peerID, taskID: taskID, scope: scope))
    }

    func record(_ entries: [DeviceWorkspaceEntry], removing keys: [String] = [],
                peerID: String, taskID: UUID, scope: String) throws {
        let location = url(peerID: peerID, taskID: taskID, scope: scope)
        let original = try read(at: location)
        var next = original
        for key in keys { next.removeValue(forKey: key) }
        for entry in entries where entry.kind == .file {
            next[DeviceWorkspacePath.comparisonKey(entry.path)] = DeviceWorkspaceRecordedFile(
                digest: entry.digest ?? "", path: entry.path)
        }
        guard next != original else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: location, options: .atomic)
    }

    func remove(_ keys: [String], peerID: String, taskID: UUID, scope: String) throws {
        try record([], removing: keys, peerID: peerID, taskID: taskID, scope: scope)
    }

    private func read(at location: URL) throws -> [String: DeviceWorkspaceRecordedFile] {
        do {
            let data = try Data(contentsOf: location)
            // New entries carry {"digest":…,"path":…}; entries written by
            // older builds are bare digest strings and decode path == nil.
            return try JSONDecoder().decode([String: LedgerValue].self, from: data)
                .mapValues { DeviceWorkspaceRecordedFile(digest: $0.digest, path: $0.path) }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [:] }
    }

    private struct LedgerValue: Decodable {
        let digest: String
        let path: String?

        init(from decoder: any Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let legacy = try? single.decode(String.self) {
                digest = legacy
                path = nil
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            digest = try container.decode(String.self, forKey: .digest)
            path = try container.decodeIfPresent(String.self, forKey: .path)
        }

        private enum CodingKeys: String, CodingKey { case digest, path }
    }

    private func url(peerID: String, taskID: UUID, scope: String) -> URL {
        let key = Data("\(peerID)\0\(taskID.uuidString)\0\(scope)".utf8)
        return directory.appendingPathComponent(DeviceWorkspaceDigest.hex(SHA256.hash(data: key)) + ".json")
    }
}
