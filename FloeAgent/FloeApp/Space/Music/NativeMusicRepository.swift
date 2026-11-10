// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import CryptoKit
import Darwin
import Foundation
import FloeMusicCore
import FloeMusicNative

/// File authority for a Music document inside an explicitly owned personal
/// project. MusicProjectStore supplies edit/session fences; this adapter
/// commits immutable assets and performs the final on-disk revision CAS.
actor NativeMusicRepository: MusicRepository {
    let root: URL
    init(root: URL) throws {
        guard root.isFileURL, root.standardizedFileURL.pathComponents.count > 3 else { throw CocoaError(.fileWriteInvalidFileName) }
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        for directory in ["documents", "assets", "blobs", "locks"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
    }

    private nonisolated func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private nonisolated func identity(_ value: String) -> String { digest(Data(value.utf8)) }
    private nonisolated func assetRecord(_ id: MusicAssetID) -> URL { root.appendingPathComponent("assets/\(identity(id.rawValue)).json") }
    private nonisolated func documentFile(_ id: MusicProjectID) -> URL { root.appendingPathComponent("documents/\(identity(id.rawValue)).json") }
    private nonisolated func blob(_ asset: MusicAsset) -> URL {
        let ext: String
        switch asset.kind {
        case .audioMP3: ext = "mp3"
        case .audioPCM: ext = "wav"
        case .audioM4A: ext = "m4a"
        case .midiFile: ext = "mid"
        case .unsupportedRaw: ext = "bin"
        }
        return root.appendingPathComponent("blobs/\(asset.contentHash).\(ext)")
    }

    private nonisolated func locked<T>(_ name: String, _ operation: () throws -> T) throws -> T {
        let path = root.appendingPathComponent("locks/\(name)").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { _ = flock(fd, LOCK_UN) }
        return try operation()
    }

    private nonisolated func writeAtomic(_ bytes: Data, to destination: URL, fence: MusicCommitFence? = nil, document: MusicDocument? = nil) throws {
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".stage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stage) }
        try bytes.write(to: stage, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: stage)
        try handle.synchronize(); try handle.close()
        let commit = {
            guard rename(stage.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        if let fence, let document { try fence.withValidCommit(document: document, commit) }
        else { try Task.checkCancellation(); try commit() }
    }

    private nonisolated func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func stageAsset(_ payload: MusicAssetPayload) async throws {
        guard digest(payload.bytes) == payload.asset.contentHash else { throw MusicError.invalidAsset(reason: "asset bytes changed") }
        try locked("asset-\(identity(payload.asset.id.rawValue))") {
            let record = assetRecord(payload.asset.id)
            if FileManager.default.fileExists(atPath: record.path) {
                let old = try JSONDecoder().decode(MusicAsset.self, from: Data(contentsOf: record))
                guard old.id == payload.asset.id, old.contentHash == payload.asset.contentHash,
                      old.sourceRevision == payload.asset.sourceRevision else { throw MusicError.invalidAsset(reason: "immutable asset identity collision") }
            }
            let destination = blob(payload.asset)
            if FileManager.default.fileExists(atPath: destination.path) {
                guard digest(try Data(contentsOf: destination, options: .mappedIfSafe)) == payload.asset.contentHash else { throw MusicError.invalidAsset(reason: "corrupt blob") }
            } else { try writeAtomic(payload.bytes, to: destination) }
            if !FileManager.default.fileExists(atPath: record.path) { try writeAtomic(encode(payload.asset), to: record) }
        }
    }

    /// Host-resolved recorded files are staged without materializing a large
    /// take as Data. The existing immutable-asset lock/hash/atomic rename is
    /// retained; the owned recording is removed only after the document saves.
    func stageAssetFile(_ asset: MusicAsset, source: URL) async throws {
        guard source.isFileURL, source.standardizedFileURL == source.standardizedFileURL.resolvingSymlinksInPath(),
              source.path.hasPrefix(root.path + "/"),
              try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              try MusicAudioPreparation.hashFile(source) == asset.contentHash else {
            throw MusicError.invalidAsset(reason: "recorded source identity changed")
        }
        try locked("asset-" + identity(asset.id.rawValue)) {
            let record = assetRecord(asset.id)
            if FileManager.default.fileExists(atPath: record.path) {
                let old = try JSONDecoder().decode(MusicAsset.self, from: Data(contentsOf: record))
                guard old.id == asset.id, old.contentHash == asset.contentHash, old.sourceRevision == asset.sourceRevision else {
                    throw MusicError.invalidAsset(reason: "immutable asset identity collision")
                }
            }
            let destination = blob(asset)
            if !FileManager.default.fileExists(atPath: destination.path) {
                let staged = destination.deletingLastPathComponent().appendingPathComponent(".stage-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: staged) }
                try FileManager.default.copyItem(at: source, to: staged)
                let synced = try FileHandle(forWritingTo: staged)
                try synced.synchronize(); try synced.close()
                guard try MusicAudioPreparation.hashFile(staged) == asset.contentHash else { throw MusicError.invalidAsset(reason: "recording copy integrity failure") }
                try Task.checkCancellation()
                do { try FileManager.default.moveItem(at: staged, to: destination) }
                catch { if !FileManager.default.fileExists(atPath: destination.path) { throw error } }
            }
            guard try MusicAudioPreparation.hashFile(destination) == asset.contentHash else { throw MusicError.invalidAsset(reason: "corrupt recording blob") }
            if !FileManager.default.fileExists(atPath: record.path) { try writeAtomic(encode(asset), to: record) }
        }
    }

    /// Cross-process CAS uses the same project lock as MusicDocument.save,
    /// then the DJ lock. It verifies the on-disk Music revision, source pins,
    /// exact prior sidecar hash and one-step DJ revision before a durable swap.
    nonisolated func saveDJWorkspace(_ value: MusicDJWorkspace, expectedSHA256: String?,
                                     expectedMusicRevision: Int64) throws -> String {
        try value.session.validate()
        return try locked("project-" + identity(value.projectID.rawValue)) {
            let music = try JSONDecoder().decode(MusicDocument.self, from: Data(contentsOf: documentFile(value.projectID)))
            guard music.id == value.projectID, music.revision == expectedMusicRevision else {
                throw MusicError.staleRevision(expected: expectedMusicRevision, actual: music.revision)
            }
            guard music.assets == value.session.assets else { throw MusicError.invalidDJ(reason: "DJ source bindings differ from the saved Music original") }
            return try locked("dj-" + identity(value.projectID.rawValue)) {
                let target = root.appendingPathComponent("dj-session.json")
                if FileManager.default.fileExists(atPath: target.path) {
                    guard target.standardizedFileURL == target.standardizedFileURL.resolvingSymlinksInPath(),
                          try target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                          (try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 16 * 1_024 * 1_024 else {
                        throw MusicError.invalidDJ(reason: "DJ sidecar is not a bounded regular original")
                    }
                    let bytes = try Data(contentsOf: target)
                    let old = try MusicDJWorkspace.decodeSaved(bytes, projectID: value.projectID)
                    guard expectedSHA256 == digest(bytes), old.revision < Int64.max, value.revision == old.revision + 1 else {
                        throw MusicError.staleRevision(expected: value.revision - 1, actual: old.revision)
                    }
                } else {
                    guard expectedSHA256 == nil, value.revision == 1 else { throw MusicError.invalidDJ(reason: "missing DJ original for CAS") }
                }
                let bytes = try encode(value)
                try writeAtomic(bytes, to: target)
                let readback = try Data(contentsOf: target)
                guard readback == bytes else { throw MusicError.invalidDJ(reason: "DJ save read-back differs") }
                return digest(readback)
            }
        }
    }

    nonisolated func resetDJWorkspace(expectedSHA256: String, expectedMusicRevision: Int64,
                                      projectID: MusicProjectID) throws -> (MusicDJWorkspace, String) {
        try locked("project-" + identity(projectID.rawValue)) {
            let music = try JSONDecoder().decode(MusicDocument.self, from: Data(contentsOf: documentFile(projectID)))
            guard music.id == projectID, music.revision == expectedMusicRevision else {
                throw MusicError.staleRevision(expected: expectedMusicRevision, actual: music.revision)
            }
            return try locked("dj-" + identity(projectID.rawValue)) {
                let target = root.appendingPathComponent("dj-session.json")
                let resource = try target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard target.standardizedFileURL == target.standardizedFileURL.resolvingSymlinksInPath(),
                      resource.isRegularFile == true, (resource.fileSize ?? Int.max) <= 16 * 1_024 * 1_024 else {
                    throw MusicError.invalidDJ(reason: "DJ recovery source is not a bounded regular file")
                }
                let original = try Data(contentsOf: target)
                guard digest(original) == expectedSHA256 else { throw MusicError.invalidDJ(reason: "DJ recovery source changed") }
                let old = try? MusicDJWorkspace.decodeSaved(original, projectID: projectID)
                let revision = old?.revision ?? 0
                guard revision < Int64.max else { throw MusicError.invalidDJ(reason: "DJ revision overflow") }
                let next = try MusicDJWorkspace(projectID: projectID, revision: revision + 1,
                    session: MusicDJSession(assets: music.assets, sampleRate: music.tempoMap.sampleRate))
                let backups = root.appendingPathComponent("DJBackups")
                try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
                guard backups.standardizedFileURL == backups.standardizedFileURL.resolvingSymlinksInPath() else {
                    throw MusicError.invalidDJ(reason: "DJ recovery directory changed")
                }
                let backup = backups.appendingPathComponent(UUID().uuidString + ".json")
                try original.write(to: backup, options: .withoutOverwriting)
                let handle = try FileHandle(forWritingTo: backup); try handle.synchronize(); try handle.close()
                guard try Data(contentsOf: backup) == original else { throw MusicError.invalidDJ(reason: "DJ recovery backup differs") }
                let bytes = try encode(next); try writeAtomic(bytes, to: target)
                guard try Data(contentsOf: target) == bytes else { throw MusicError.invalidDJ(reason: "DJ recovery read-back differs") }
                return (next, digest(bytes))
            }
        }
    }

    func save(document: MusicDocument, expectedRevision: Int64?, fence: MusicCommitFence?) async throws -> MusicRevisionToken {
        try document.validate()
        let bytes = try encode(document)
        return try locked("project-\(identity(document.id.rawValue))") {
            let target = documentFile(document.id)
            if let expectedRevision {
                guard FileManager.default.fileExists(atPath: target.path) else { throw MusicError.invalidBatch(reason: "missing project for CAS") }
                let old = try JSONDecoder().decode(MusicDocument.self, from: Data(contentsOf: target))
                guard old.revision == expectedRevision else { throw MusicError.staleRevision(expected: expectedRevision, actual: old.revision) }
                let (next, overflow) = expectedRevision.addingReportingOverflow(1)
                guard !overflow, document.revision == next else { throw MusicError.invalidBatch(reason: "revision must advance once") }
            } else if FileManager.default.fileExists(atPath: target.path) { throw MusicError.invalidBatch(reason: "project already exists") }
            for asset in document.assets {
                let stored = try JSONDecoder().decode(MusicAsset.self, from: Data(contentsOf: assetRecord(asset.id)))
                guard stored.id == asset.id, stored.contentHash == asset.contentHash, stored.sourceRevision == asset.sourceRevision,
                      digest(try Data(contentsOf: blob(stored), options: .mappedIfSafe)) == asset.contentHash else { throw MusicError.invalidAsset(reason: "unstaged source version") }
            }
            try writeAtomic(bytes, to: target, fence: fence, document: document)
            return MusicRevisionToken(revision: document.revision, contentHash: digest(bytes))
        }
    }

    func load(projectID: MusicProjectID) async throws -> MusicDocument {
        let document = try JSONDecoder().decode(MusicDocument.self, from: Data(contentsOf: documentFile(projectID)))
        guard document.id == projectID else { throw MusicError.invalidBatch(reason: "project identity mismatch") }
        try document.validate()
        return document
    }

    func assetPayload(assetID: MusicAssetID) async throws -> MusicAssetPayload? {
        let path = assetRecord(assetID)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let asset = try JSONDecoder().decode(MusicAsset.self, from: Data(contentsOf: path))
        guard asset.id == assetID else { throw MusicError.invalidAsset(reason: "asset identity mismatch") }
        let data = try Data(contentsOf: blob(asset), options: .mappedIfSafe)
        guard digest(data) == asset.contentHash else { throw MusicError.invalidAsset(reason: "asset integrity failure") }
        return MusicAssetPayload(asset: asset, bytes: data)
    }

    func resolvedURL(for asset: MusicAsset) throws -> URL {
        let stored = try JSONDecoder().decode(MusicAsset.self, from: Data(contentsOf: assetRecord(asset.id)))
        guard stored.id == asset.id, stored.contentHash == asset.contentHash, stored.sourceRevision == asset.sourceRevision else {
            throw MusicError.invalidAsset(reason: "resolved source identity mismatch")
        }
        return blob(stored)
    }
}

#endif
