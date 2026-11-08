// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeBiologyCore

/// Stored native CAS/binding metadata, never a permission token or tool input.
nonisolated struct PersonalBiologyPermanentDeletionSource: Codable, Hashable, Sendable {
    let projectID: UUID
    let bindingSHA256: String
    let native: BiologyPermanentDeletionPlan
}

/// Actual cross-store orchestration. The App coordinator supplies its canonical
/// store under the same Library usage/native-file fences. Tests use those SAME
/// real stores with owned synthetic directories, not a substitute executor.
nonisolated enum BiologyLibraryPermanentDeletion {
    static func prepare(_ proposals: [PersonalPermanentDeletePlan], library: PersonalContentLibrary,
        store: BiologyProjectStore) async throws -> [PersonalPermanentDeletePlan] {
        let root = await library.root
        var results: [PersonalPermanentDeletePlan] = []
        for proposal in proposals {
            var sources: [PersonalBiologyPermanentDeletionSource] = []
            for record in proposal.members where record.kind == .biology {
                let saved = proposal.biologySources.first { $0.projectID == record.id }
                let native: BiologyPermanentDeletionPlan
                if let saved {
                    native = try await store.permanentDeletionPlan(projectID: record.id, trashID: saved.native.trashID, transactionID: proposal.id)
                    guard native.sourceIdentity == saved.native.sourceIdentity else { throw PersonalPermanentDeleteError.changed }
                } else {
                    let deleted = try await store.deletedProjects().filter { $0.projectID == record.id }
                    guard deleted.count == 1, let original = deleted.first else { throw PersonalPermanentDeleteError.changed }
                    native = try await store.permanentDeletionPlan(projectID: record.id, trashID: original.id, transactionID: proposal.id)
                }
                let binding: String
                if proposal.wrapperRemovalStarted, native.completed, let saved {
                    // The actual native completion marker and anchored wrapper
                    // journal survive removal of the binding file itself.
                    binding = saved.bindingSHA256
                } else {
                    binding = try PersonalLibraryPurgeIO.biologyBindingDigest(root: root,
                        relativePath: proposal.physicalRelativePath(for: record), projectID: record.id)
                    if let saved, binding != saved.bindingSHA256 { throw PersonalPermanentDeleteError.changed }
                }
                sources.append(.init(projectID: record.id, bindingSHA256: binding, native: native))
            }
            results.append(try proposal.includingBiology(sources))
        }
        return results
    }

    static func remove(_ selected: PersonalPermanentDeletePlan, library: PersonalContentLibrary,
        store: BiologyProjectStore,
        nativeCheckpoint: (@Sendable (BiologyPermanentDeletionCheckpoint) throws -> Void)? = nil,
        wrapperCheckpoint: (@Sendable (PersonalPermanentDeleteCheckpoint) throws -> Void)? = nil) async throws -> PersonalPermanentDeleteReceipt {
        guard !selected.biologySources.isEmpty else { throw PersonalPermanentDeleteError.changed }
        // Re-read the actual native deleted revision/binding before staging.
        let proposals = try await library.permanentDeletionProposals([selected.entry])
        let fresh = try await prepare(proposals, library: library, store: store)
        guard fresh.count == 1, fresh[0] == selected else { throw PersonalPermanentDeleteError.changed }
        try Task.checkCancellation()
        try await library.stageBiologyPermanentDeletion(selected)
        do {
            var receipts: [BiologyPermanentDeletionReceipt] = []
            for source in selected.biologySources {
                receipts.append(try await store.permanentlyDelete(source.native, checkpoint: nativeCheckpoint))
            }
            // Real native commit has occurred. Finish the wrapper/index even
            // if cancellation arrived after the irreversible boundary.
            return try await library.finishBiologyPermanentDeletion(selected, receipts: receipts, checkpoint: wrapperCheckpoint)
        } catch {
            let original = error
            var pending = false
            for source in selected.biologySources {
                do {
                    if try await store.hasPermanentDeletionRecord(projectID: source.projectID, transactionID: selected.id) { pending = true }
                } catch { pending = true }
            }
            if !pending {
                // Native pre-commit cancellation/failure restored every source.
                // Return the still-soft-deleted wrapper to its original name.
                try await library.rollbackBiologyPermanentDeletion(selected)
                throw original
            }
            // Native or wrapper progress exists. Never advertise cancellation
            // as zero writes or Restore after partial irreversible deletion.
            throw PersonalPermanentDeleteError.incomplete
        }
    }
}

#if canImport(UIKit)
@MainActor extension BiologyLibraryCoordinator {
    func permanentDeletionPlans(_ proposals: [PersonalPermanentDeletePlan], library: PersonalContentLibrary) async throws -> [PersonalPermanentDeletePlan] {
        let host = try permanentDeletionHost()
        return try await BiologyLibraryPermanentDeletion.prepare(proposals, library: library, store: host.store)
    }
    func permanentlyDeleteUnderHeldBarrier(_ selected: PersonalPermanentDeletePlan,
        library: PersonalContentLibrary) async throws -> PersonalPermanentDeleteReceipt {
        let host = try permanentDeletionHost()
        let ids = Set(selected.members.filter { $0.kind == .biology }.map(\.id))
        try host.requireNoPermanentDeletionOwners(ids)
        try await host.files.beginPermanentDeletion(ids)
        do {
            try host.requireNoPermanentDeletionOwners(ids)
            let receipt = try await BiologyLibraryPermanentDeletion.remove(selected, library: library, store: host.store)
            // Keep the per-project native file fence after irreversible work.
            // It also rejects an already-authorized suspended copy on resume.
            return receipt
        } catch {
            var hasRecord = false
            for source in selected.biologySources {
                do { if try await host.store.hasPermanentDeletionRecord(projectID: source.projectID, transactionID: selected.id) { hasRecord = true } }
                catch { hasRecord = true }
            }
            if !hasRecord { await host.files.endPermanentDeletion(ids) }
            throw error
        }
    }
}
#endif
