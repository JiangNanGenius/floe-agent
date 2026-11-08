// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeMusicCore
import FloeTools
import FloeWorkspace

nonisolated struct MusicNotationRestoreAuthority: Sendable {
    let identity: UUID
    let ownerToken: String
    let oldStore: MusicProjectStore
    let oldDocument: MusicDocument
}

private nonisolated struct MusicNotationRestoreInput: Sendable {
    let source: URL
    let destination: URL
    let parentID: UUID

    func extract(cancellation: CancellationToken) throws -> URL {
        try Task.checkCancellation(); try cancellation.throwIfCancelled()
        let summary = try ArchiveEngine.extract(format: "zip", source: source, destination: destination,
            limits: .init(maxEntries: 20_000, maxTotalBytes: 2 * 1024 * 1024 * 1024, maxListedEntries: 20_000), cancellation: cancellation)
        guard summary.linksPreserved == 0, summary.linksSkipped == 0 else { throw PersonalContentError.invalidProject }
        let files = FileManager()
        let candidates = [destination] + (try files.contentsOfDirectory(at: destination, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
        let roots = candidates.filter { files.fileExists(atPath: $0.appendingPathComponent(MusicNotationPackage.manifestName).path) }
        guard roots.count == 1, let root = roots.first else { throw PersonalContentError.invalidProject }
        _ = try MusicNotationPackage.directoryIdentity(root)
        _ = try MusicNotationPackage.validateBackup(root: root, parentID: parentID)
        try Task.checkCancellation(); try cancellation.throwIfCancelled()
        return root
    }
}

/// Restore is limited to a verified backup of this same music project. Both
/// originals change at one directory-exchange commit point, never two writes.
@MainActor enum MusicNotationRestore {
    static func restore(_ source: URL, session: MusicProjectSession, expected: MusicNotationSnapshot) async throws {
        guard expected.parentID == session.id else { throw PersonalContentError.changedDocument }
        let parent = session.root.deletingLastPathComponent(), fm = FileManager.default
        let extracted = parent.appendingPathComponent(".music-restore-input-" + UUID().uuidString)
        let stagingName = ".music-restore-stage-" + UUID().uuidString
        let backupName = ".music-restore-backup-" + UUID().uuidString
        let stage = parent.appendingPathComponent(stagingName), backup = parent.appendingPathComponent(backupName)
        let cancellation = CancellationToken()
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() }; try? fm.removeItem(at: extracted) }
        // Native picker URL only. The existing bounded archive engine validates
        // names/CRC/expanded bytes; all links are refused for an original package.
        let input = MusicNotationRestoreInput(source: source, destination: extracted, parentID: expected.parentID)
        let packageRoot = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [input, cancellation] in
                try input.extract(cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
        let manifest = try MusicNotationPackage.validateBackup(root: packageRoot, parentID: session.id)
        try Task.checkCancellation()
        let authority = try await session.beginNotationRestore(expected: expected)
        var journal: MusicNotationRestoreJournal?
        var swapped = false
        var committed = false
        do {
            let imported = try NativeMusicRepository(root: packageRoot)
            var restored = try await imported.load(projectID: .init(rawValue: session.id.uuidString.lowercased()))
            guard restored.revision == manifest.musicRevision, expected.musicRevision < Int64.max else { throw PersonalContentError.changedDocument }
            restored.revision = expected.musicRevision + 1; restored.updatedAt = Date()
            let target = try NativeMusicRepository(root: stage)
            for asset in restored.assets {
                guard let payload = try await imported.assetPayload(assetID: asset.id), payload.asset == asset else { throw PersonalContentError.invalidProject }
                if let existing = try await session.repository.assetPayload(assetID: asset.id) {
                    guard existing.asset.contentHash == asset.contentHash, existing.asset.sourceRevision == asset.sourceRevision else { throw PersonalContentError.changedDocument }
                }
                try Task.checkCancellation(); try await target.stageAsset(payload)
            }
            _ = try await target.save(document: restored, expectedRevision: nil)
            try MusicNotationPackage.prepareRestoredScore(source: packageRoot, destination: stage, expected: expected)
            if manifest.djSHA256 != nil {
                let bytes = try MusicNotationPackage.regularData(packageRoot.appendingPathComponent("dj-session.json"))
                let dj = try JSONDecoder().decode(MusicDJSession.self, from: bytes); try dj.validate()
                guard dj.assets.allSatisfy({ restored.assets.contains($0) }) else { throw PersonalContentError.invalidProject }
                try bytes.write(to: stage.appendingPathComponent("dj-session.json"), options: .withoutOverwriting)
            }
            let targetSnapshot = try MusicNotationPackage.capture(root: stage, parentID: session.id)
            journal = MusicNotationRestoreJournal(parentID: session.id, before: expected, target: targetSnapshot,
                stagingName: stagingName, backupName: backupName)
            try MusicNotationPackage.withRestoreLock(root: session.root) {
                try MusicNotationPackage.requireUnchanged(expected, root: session.root)
                try Task.checkCancellation()
                try MusicNotationPackage.writeJournal(journal!, root: session.root)
                try MusicNotationPackage.swap(session.root, stage)
                swapped = true
                guard MusicNotationPackage.sameOriginals(try MusicNotationPackage.capture(root: session.root, parentID: session.id), targetSnapshot) else { throw PersonalContentError.changedDocument }
            }
            try Task.checkCancellation()
            let next = try await MusicProjectStore.open(projectID: restored.id, repository: session.repository)
            let readback = try await next.currentSnapshot()
            guard readback == restored else { throw PersonalContentError.changedDocument }
            try await session.finishNotationRestore(authority, store: next)
            // Verification and authority adoption precede the commit marker.
            // Until then crash recovery rolls the whole directory pair back.
            try MusicNotationPackage.withRestoreLock(root: session.root) {
                guard MusicNotationPackage.sameOriginals(try MusicNotationPackage.capture(root: session.root, parentID: session.id), targetSnapshot) else { throw PersonalContentError.changedDocument }
                journal!.committed = true
                try MusicNotationPackage.writeJournal(journal!, root: session.root)
                committed = true
                try fm.moveItem(at: stage, to: backup)
                try fm.removeItem(at: parent.appendingPathComponent(MusicNotationPackage.journalName))
            }
            session.completeNotationRestore(authority)
        } catch {
            // A committed journal already identifies one valid complete new
            // pair. Cleanup failure keeps the old backup and is recoverable.
            if committed {
                session.completeNotationRestore(authority)
                session.diagnostic = WorkbenchText.t("工程已恢复，旧备份已保留。", "The project was restored; the previous backup was retained.")
                return
            }
            do {
                if swapped {
                    try MusicNotationPackage.withRestoreLock(root: session.root) {
                        guard let journal,
                              MusicNotationPackage.sameOriginals(try MusicNotationPackage.capture(root: session.root, parentID: session.id), journal.target),
                              MusicNotationPackage.sameOriginals(try MusicNotationPackage.capture(root: stage, parentID: session.id), expected) else { throw PersonalContentError.changedDocument }
                        try MusicNotationPackage.swap(session.root, stage)
                        guard MusicNotationPackage.sameOriginals(try MusicNotationPackage.capture(root: session.root, parentID: session.id), expected) else { throw PersonalContentError.changedDocument }
                    }
                }
                let old = try await MusicProjectStore.open(projectID: authority.oldDocument.id, repository: session.repository)
                try await session.finishNotationRestore(authority, store: old)
                session.completeNotationRestore(authority)
                if FileManager.default.fileExists(atPath: stage.path) { try fm.removeItem(at: stage) }
                if journal != nil { try? fm.removeItem(at: parent.appendingPathComponent(MusicNotationPackage.journalName)) }
            } catch {
                // Keep the journal and both original directories. Editing stays
                // fenced; next open runs recovery before constructing a store.
                session.diagnostic = WorkbenchText.t("恢复未完成，原件和恢复资料均已保留。请重新打开工程。", "Restoration is incomplete. The originals and recovery data were retained. Reopen the project.")
                throw error
            }
            throw error
        }
    }
}
#endif
