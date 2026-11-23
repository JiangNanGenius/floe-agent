// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Foundation

public struct DeviceWorkspaceReceiveProgress: Equatable, Sendable {
    public let total: Int
    public fileprivate(set) var processed = 0
    public fileprivate(set) var savedFiles = 0
    public fileprivate(set) var conflicts = 0
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
    let didImport: @MainActor @Sendable (UUID) async -> Void

    public init(resolve: @escaping @MainActor @Sendable (UUID, Bool) async throws -> DeviceWorkspaceRoot,
                ledgerDirectory: URL,
                didImport: @escaping @MainActor @Sendable (UUID) async -> Void = { _ in }) {
        self.resolve = resolve
        ledger = DeviceWorkspaceLedger(directory: ledgerDirectory)
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

    func confirm(_ indexes: [Int], from peerID: String, taskID: UUID, prepared: Prepared) async throws {
        guard !indexes.isEmpty, indexes.count <= DeviceWorkspaceManifest.confirmationLimit,
              Set(indexes).count == indexes.count,
              indexes.allSatisfy({ prepared.entries.indices.contains($0) && prepared.entries[$0].entry.kind == .file }) else {
            throw DeviceHistorySyncError.invalidResponse
        }
        try await prepared.directory.validate()
        var entries: [DeviceWorkspaceEntry] = []
        for index in indexes {
            let item = prepared.entries[index]
            if (try? prepared.directory.matches(item)) == true { entries.append(item.entry) }
        }
        guard !entries.isEmpty else { return }
        try await ledger.record(entries, peerID: peerID, taskID: taskID, scope: prepared.directory.lease.scope)
    }

    func receive(
        _ manifest: DeviceWorkspaceManifest,
        from peerID: String,
        taskID: UUID,
        read: (Int, Int64, Int) async throws -> Data,
        confirm: ([Int]) async throws -> Void,
        onProgress: @Sendable (DeviceWorkspaceReceiveProgress) async -> Void
    ) async throws {
        let directory = try await open(taskID, receiving: true)
        let scope = directory.lease.scope
        let baseline = try await ledger.read(peerID: peerID, taskID: taskID, scope: scope)
        var progress = DeviceWorkspaceReceiveProgress(total: manifest.entries.count)
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
                switch try await receiveFile(entry, in: directory, baseline: baseline[key], read: { offset, count in
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
                try await record(pending, manifest: manifest, peerID: peerID, taskID: taskID, scope: scope, confirm: confirm)
                pending.removeAll(keepingCapacity: true)
            }
        }
        if !pending.isEmpty {
            try await directory.validate()
            try await record(pending, manifest: manifest, peerID: peerID, taskID: taskID, scope: scope, confirm: confirm)
        }
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
        confirm: ([Int]) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try await ledger.record(indexes.map { manifest.entries[$0] }, peerID: peerID, taskID: taskID, scope: scope)
        try await confirm(indexes)
    }

    private func open(_ taskID: UUID, receiving: Bool) async throws -> DeviceWorkspaceDirectory {
        let root = try await resolve(taskID, receiving)
        return try DeviceWorkspaceDirectory(root)
    }
}

private actor DeviceWorkspaceLedger {
    let directory: URL

    init(directory: URL) { self.directory = directory }

    func read(peerID: String, taskID: UUID, scope: String) throws -> [String: String] {
        try read(at: url(peerID: peerID, taskID: taskID, scope: scope))
    }

    func record(_ entries: [DeviceWorkspaceEntry], peerID: String, taskID: UUID, scope: String) throws {
        let location = url(peerID: peerID, taskID: taskID, scope: scope)
        let original = try read(at: location)
        var next = original
        for entry in entries {
            next[DeviceWorkspacePath.comparisonKey(entry.path)] = entry.digest
        }
        guard next != original else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: location, options: .atomic)
    }

    private func read(at location: URL) throws -> [String: String] {
        do { return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: location)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [:] }
    }

    private func url(peerID: String, taskID: UUID, scope: String) -> URL {
        let key = Data("\(peerID)\0\(taskID.uuidString)\0\(scope)".utf8)
        return directory.appendingPathComponent(DeviceWorkspaceDigest.hex(SHA256.hash(data: key)) + ".json")
    }
}
