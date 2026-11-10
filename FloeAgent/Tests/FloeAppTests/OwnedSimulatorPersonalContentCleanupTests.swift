// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CryptoKit
import XCTest
@testable import FloeApp

/// Operational cleanup, never part of ordinary acceptance. Root supplies one
/// reviewed exact manifest; an absent flag skips before reading library data.
@MainActor final class OwnedSimulatorPersonalContentCleanupTests: XCTestCase {
    private struct Manifest: Decodable, Sendable {
        let schema: Int
        let action: String
        let operationID: UUID
        let appBundleID: String
        let simulatorUDID: String
        let records: [Expected]
    }
    private struct Expected: Decodable, Sendable {
        let id: UUID
        let title: String
        let kind: PersonalContentKind
        let relativePath: String
        let metadataSHA256: String
        let treeSHA256: String
    }
    private struct FileEntry: Codable, Sendable, Equatable {
        let path: String
        let directory: Bool
        let bytes: Int64
        let sha256: String
    }
    private struct Tree: Codable, Sendable, Equatable {
        let entries: [FileEntry]
        let bytes: Int64
        let sha256: String
    }
    private enum Refusal: Error { case invalidManifest, changed, unsafePath, oversized, backupMismatch }

    func testDeleteOnlyVerifiedOwnedWorksAfterRecoverableBackup() async throws {
        guard let raw = ProcessInfo.processInfo.environment["FLOE_QA_PERSONAL_CLEANUP_MANIFEST_JSON"] else {
            throw XCTSkip("Operational cleanup is off; an explicit reviewed exact manifest is required.")
        }
        #if !targetEnvironment(simulator)
        throw XCTSkip("This operational cleanup is restricted to the canonical Simulator.")
        #else
        let data = Data(raw.utf8)
        guard data.count <= 131_072 else { throw Refusal.invalidManifest }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.schema == 1,
              manifest.action == "backup-and-delete-exact-owned-test-works",
              manifest.appBundleID == "org.floeagent.ios",
              Bundle.main.bundleIdentifier == manifest.appBundleID,
              manifest.simulatorUDID == "6366F0FB-C395-4A9C-8983-0082850F43A6",
              ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == manifest.simulatorUDID,
              (1...64).contains(manifest.records.count),
              Set(manifest.records.map(\.id)).count == manifest.records.count,
              manifest.records.allSatisfy({ !$0.title.isEmpty && !$0.title.contains("QA-Piano")
                  && Self.validDigest($0.metadataSHA256) && Self.validDigest($0.treeSHA256) }) else {
            throw Refusal.invalidManifest
        }
        // Reuse the actual launch graph and its bounded persistence-ready
        // gate. Flag/manifest checks above remain before all bootstrap/library I/O.
        let environment = try await appQualificationEnvironment()
        let library = try await PersonalContentService.shared.library()
        let root = await library.root
        let actualRoot = try PersonalContentLibrary.applicationRoot().standardizedFileURL.resolvingSymlinksInPath()
        guard root.path == actualRoot.path,
              actualRoot.path.hasPrefix(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/") else {
            throw Refusal.unsafePath
        }
        let before = try await library.records(includingDeleted: true)
        let selected = Set(manifest.records.map(\.id))
        let protected = Dictionary(uniqueKeysWithValues: before.filter { !selected.contains($0.id) }.map { ($0.id, $0) })
        let protectedHashes = try Dictionary(uniqueKeysWithValues: protected.values.map {
            ($0.id, try Self.fileHash(Self.metadataURL(root: root, path: $0.relativePath)))
        })
        let oldTrash = Set(try await library.recentlyDeleted())
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let backup = support.appendingPathComponent("FloeAgent/OperationalCleanupRecovery", isDirectory: true)
            .appendingPathComponent(manifest.operationID.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: backup.path), !selected.isEmpty else { throw Refusal.changed }

        // Verify all originals before creating recovery output, and back up all
        // selected originals before the first production deletion is admitted.
        var originals: [UUID: PersonalContentRecord] = [:]
        var trees: [UUID: Tree] = [:]
        for expected in manifest.records {
            let record = try await Self.verify(expected, library: library, root: root, mustBeActive: true)
            originals[record.id] = record
            trees[record.id] = try Self.tree(Self.projectURL(root: root, path: record.relativePath))
        }
        let backupBytes = trees.values.reduce(Int64(0)) { $0 + $1.bytes }
        let available = try FileManager.default.attributesOfFileSystem(forPath: support.path)[.systemFreeSize] as? NSNumber
        guard backupBytes <= 1_073_741_824, let available,
              available.int64Value >= backupBytes * 2 + 67_108_864 else { throw Refusal.oversized }
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try data.write(to: backup.appendingPathComponent("EXACT-MANIFEST.json"), options: .withoutOverwriting)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for expected in manifest.records {
            try Task.checkCancellation()
            _ = try await Self.verify(expected, library: library, root: root, mustBeActive: true)
            let source = try Self.projectURL(root: root, path: expected.relativePath)
            let destination = backup.appendingPathComponent(expected.id.uuidString + ".floeproject", isDirectory: true)
            try FileManager.default.copyItem(at: source, to: destination)
            guard try Self.tree(destination) == trees[expected.id],
                  try Self.tree(source) == trees[expected.id] else { throw Refusal.backupMismatch }
            try encoder.encode(trees[expected.id]).write(to: backup.appendingPathComponent(expected.id.uuidString + ".inventory.json"), options: .withoutOverwriting)
        }
        let recovery = XCTAttachment(string: "Exact test-original recovery: \(backup.path)\nRecords: \(manifest.records.map { $0.id.uuidString }.joined(separator: ","))\nAll source/copy trees were byte-verified before any deletion. Root must export recovery before retiring it.")
        recovery.name = "Verified owned-work recovery"; recovery.lifetime = .keepAlways; add(recovery)

        for expected in manifest.records {
            try Task.checkCancellation()
            guard let original = originals[expected.id] else { throw Refusal.changed }
            let validateActive: @MainActor @Sendable () async throws -> Void = {
                _ = try await Self.verify(expected, library: library, root: root, mustBeActive: true)
            }
            // Existing lifecycle stops/refuses owned sessions and holds its
            // barriers. A changed/active project is preserved, never force-deleted.
            let entry = try await PersonalLibraryFileActions.delete(original, environment: environment, library: library, validateSource: validateActive)
            guard entry.projectID == expected.id, entry.relativePath == expected.relativePath,
                  entry.contentKind == expected.kind, entry.title == expected.title else { throw Refusal.changed }
            let validateDeleted: @MainActor @Sendable () async throws -> Void = {
                // Production softDelete appends an index overlay; it keeps the
                // original bytes in place until the purge's fd-anchored CAS.
                // Bind this second phase to that exact returned tombstone,
                // never to an arbitrary deleted record or an older purge stage.
                let current = try await Self.verify(expected, library: library, root: root, mustBeActive: false)
                let trash = try await library.recentlyDeleted()
                let pending = try await library.permanentDeletionPendingIDs()
                guard current.deletedAt == entry.deletedAt, trash.contains(entry),
                      trash.filter({ $0.projectID == expected.id }).count == 1,
                      !pending.contains(entry.id) else { throw Refusal.changed }
            }
            try await validateDeleted()
            let plans = try await PersonalLibraryFileActions.permanentDeletionPlans([entry], environment: environment, library: library)
            guard plans.count == 1, plans[0].entry == entry, !plans[0].cleanupPending,
                  Set(plans[0].coveredEntries.map(\.id)) == [entry.id],
                  Set(plans[0].members.map(\.id)) == [expected.id] else { throw Refusal.changed }
            let deleted = try await PersonalLibraryFileActions.permanentlyDelete(plans[0], environment: environment, library: library, validateSource: validateDeleted)
            guard deleted.entryID == entry.id, Set(deleted.projectIDs) == [expected.id],
                  Set(deleted.removedEntryIDs) == [entry.id], !deleted.privateJournalCleanupPending else { throw Refusal.changed }
            let pathRemains = FileManager.default.fileExists(atPath: root.appendingPathComponent(expected.relativePath).path)
            XCTAssertFalse(pathRemains)
            let remainingRecords = try await library.records(includingDeleted: true)
            let remainingTrash = try await library.recentlyDeleted()
            XCTAssertFalse(remainingRecords.contains { $0.id == expected.id })
            XCTAssertFalse(remainingTrash.contains { $0.projectID == expected.id || $0.id == entry.id })
            guard !pathRemains, !remainingRecords.contains(where: { $0.id == expected.id }),
                  !remainingTrash.contains(where: { $0.projectID == expected.id || $0.id == entry.id }) else { throw Refusal.changed }
        }
        let after = try await library.records(includingDeleted: true)
        let remainingIdentities = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
        XCTAssertEqual(remainingIdentities, protected)
        guard remainingIdentities == protected else { throw Refusal.changed }
        for record in protected.values {
            let hash = try Self.fileHash(Self.metadataURL(root: root, path: record.relativePath))
            XCTAssertEqual(hash, protectedHashes[record.id])
            guard hash == protectedHashes[record.id] else { throw Refusal.changed }
        }
        let finalTrash = Set(try await library.recentlyDeleted())
        XCTAssertEqual(finalTrash, oldTrash, "Existing unrelated Trash must remain unchanged; selected tests must leave no tombstone.")
        guard finalTrash == oldTrash else { throw Refusal.changed }
        let receipt = "OWNED-WORK-CLEANUP|operation=\(manifest.operationID.uuidString)|deleted=\(manifest.records.count)|protected=\(protected.count)|backup=\(backup.path)\n"
        try Data(receipt.utf8).write(to: backup.appendingPathComponent("COMPLETED.txt"), options: .withoutOverwriting)
        FileHandle.standardOutput.write(Data(receipt.utf8))
        #endif
    }

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func projectURL(root: URL, path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), !path.hasPrefix("/"),
              (path as NSString).pathExtension == "floeproject" else { throw Refusal.unsafePath }
        var location = root
        for part in parts {
            location.appendPathComponent(String(part))
            let info = try location.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard info.isSymbolicLink != true, info.isDirectory == true else { throw Refusal.unsafePath }
        }
        guard location.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw Refusal.unsafePath }
        return location
    }
    private static func metadataURL(root: URL, path: String) throws -> URL {
        try projectURL(root: root, path: path).appendingPathComponent("FloeProject.json")
    }
    private static func verify(_ expected: Expected, library: PersonalContentLibrary, root: URL, mustBeActive: Bool) async throws -> PersonalContentRecord {
        let records = try await library.records(includingDeleted: true)
        guard let record = records.first(where: { $0.id == expected.id }), record.title == expected.title,
              record.kind == expected.kind, record.relativePath == expected.relativePath,
              !record.needsRecovery, !mustBeActive || record.deletedAt == nil,
              try fileHash(metadataURL(root: root, path: record.relativePath)) == expected.metadataSHA256,
              try tree(projectURL(root: root, path: record.relativePath)).sha256 == expected.treeSHA256 else { throw Refusal.changed }
        return record
    }
    private static func fileHash(_ url: URL) throws -> String {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else { throw Refusal.unsafePath }
        guard let size = info.fileSize, size <= 268_435_456 else { throw Refusal.oversized }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256(), count = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation(); count += data.count
            guard count <= 268_435_456 else { throw Refusal.oversized }
            hash.update(data: data)
        }
        guard count == size else { throw Refusal.changed }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func tree(_ directory: URL) throws -> Tree {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var traversalFailed = false
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
            options: [], errorHandler: { _, _ in traversalFailed = true; return false }) else { throw Refusal.unsafePath }
        var rows: [FileEntry] = [], total: Int64 = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let info = try url.resourceValues(forKeys: Set(keys))
            guard info.isSymbolicLink != true, url.path.hasPrefix(directory.path + "/") else { throw Refusal.unsafePath }
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            if info.isDirectory == true { rows.append(.init(path: relative, directory: true, bytes: 0, sha256: "-")) }
            else {
                guard info.isRegularFile == true, let size = info.fileSize else { throw Refusal.unsafePath }
                total += Int64(size); guard total <= 1_073_741_824 else { throw Refusal.oversized }
                rows.append(.init(path: relative, directory: false, bytes: Int64(size), sha256: try fileHash(url)))
            }
            guard rows.count <= 20_000 else { throw Refusal.oversized }
        }
        guard !traversalFailed else { throw Refusal.unsafePath }
        rows.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        var hash = SHA256()
        for row in rows {
            let line = (row.directory ? "d" : "f") + "\0" + Data(row.path.utf8).base64EncodedString() + "\0" + String(row.bytes) + "\0" + row.sha256 + "\n"
            hash.update(data: Data(line.utf8))
        }
        return .init(entries: rows, bytes: total, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
#endif
