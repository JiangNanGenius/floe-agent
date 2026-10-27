// FloeApp — preinstalled protection + inline batch selection regressions.
//
// Real migration, real SQLiteSkillStore transactions and the actual
// SkillsCenter service boundary — no source-text mirrors.
//
// NOTE (lane handoff): Main moves this file to Tests/FloeAppTests/ during
// integration; the approved lane path is kept here until then.

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeSkills
import FloePersistence
@testable import FloeApp

@Suite("FloeApp.SkillManagementSelection", .serialized)
struct SkillManagementSelectionTests {

    // MARK: - Helpers

    @MainActor
    private func makeFixture() async throws -> (AppEnvironment, SkillsCenter, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-selection-\(UUID())")
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let center = SkillsCenter(environment: environment,
                                  installationRoot: root.appendingPathComponent("Skills"))
        return (environment, center, root)
    }

    @MainActor
    private func waitBatch(_ center: SkillsCenter) async throws -> SkillBatchSummary {
        while center.isBatchRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        return try #require(center.lastBatchSummary)
    }

    @MainActor
    private func createCustom(_ center: SkillsCenter, _ name: String,
                              in environment: AppEnvironment) async throws -> PersistedSkill {
        let created = try await center.createSkill(.init(name: name,
            description: "Selection fixture guide", instructions: "Fixture body for \(name)."))
        return try #require(try await environment.skillStore.all().first { $0.id == created.id })
    }

    @MainActor
    private func persistedRow(_ environment: AppEnvironment, _ id: String) async throws -> PersistedSkill {
        try #require(try await environment.skillStore.all().first { $0.id == id })
    }

    private func item(_ row: PersistedSkill) -> SkillBatchItem {
        SkillBatchItem(id: row.id, title: row.name,
                       preinstalled: SkillBatchSelectionPolicy.isPreinstalled(row.id),
                       expectedDigest: row.rewrittenDigest)
    }

    // MARK: - Preinstalled protection at the service boundary

    @Test("Every removal path rejects preinstalled IDs and the row survives")
    @MainActor func preinstalledRemovalRejectedEverywhere() async throws {
        let (environment, center, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await center.readSkills(id: "floe-pdf").first
        let pdf = try await persistedRow(environment, "floe-pdf")
        // Assistant channel (skill.manage) — exposed builtin.
        await #expect(throws: (any Error).self) {
            try await center.manageSkill(.init(action: .remove, id: pdf.id, expectedDigest: pdf.rewrittenDigest))
        }
        // Hidden builtin keeps its stricter guard.
        let remote = try await persistedRow(environment, "floe-remote")
        await #expect(throws: (any Error).self) {
            try await center.manageSkill(.init(action: .remove, id: remote.id, expectedDigest: remote.rewrittenDigest))
        }
        // UI single-row path stays bilingual and never reaches the store.
        await center.remove(pdf)
        #expect(center.errorMessage == SkillBatchCopy.preinstalledCannotRemove)
        #expect(try await environment.skillStore.all().contains { $0.id == pdf.id })
        #expect(try await !environment.skillStore.wasBundledSkillRemoved(id: pdf.id))
        #expect(try await !environment.skillStore.wasExplicitlyRemoved(id: pdf.id))
    }

    @Test("Visible builtins stay enable/disable through the same boundary")
    @MainActor func builtinEnableDisableStillAllowed() async throws {
        let (environment, center, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await center.readSkills(id: "floe-pdf").first
        let first = try await persistedRow(environment, "floe-pdf")
        _ = try await center.manageSkill(.init(action: .setEnabled, id: first.id,
                                               expectedDigest: first.rewrittenDigest, enabled: false))
        #expect(try await environment.skillStore.all().first { $0.id == "floe-pdf" }?.status == "disabled")
        let row = try await persistedRow(environment, "floe-pdf")
        _ = try await center.manageSkill(.init(action: .setEnabled, id: row.id,
                                               expectedDigest: row.rewrittenDigest, enabled: true))
        #expect(try await environment.skillStore.all().first { $0.id == "floe-pdf" }?.status == "enabled")
    }

    // MARK: - Historical mistaken removal restores via trusted bundled seed

    @Test("Legacy bundled deletion with the package directory left in place restores and clears both markers")
    @MainActor func historicalRemovalRestoresWithDirectoryLeftBehind() async throws {
        let (environment, center, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await center.readSkills(id: "floe-pdf").first
        let pdf = try await persistedRow(environment, "floe-pdf")
        // Reproduce an older App's persisted deletion, bypassing the new
        // service policy: row gone, BOTH differently named markers set.
        try await environment.skillStore.remove(id: pdf.id, expectedDigest: pdf.rewrittenDigest,
                                                suppressBundledSeed: true)
        let installRoot = root.appendingPathComponent("Skills")
        #expect(FileManager.default.fileExists(atPath: installRoot.appendingPathComponent("floe-pdf").path))
        #expect(try await environment.skillStore.wasBundledSkillRemoved(id: pdf.id))
        #expect(try await environment.skillStore.wasExplicitlyRemoved(id: pdf.id))
        let reopened = SkillsCenter(environment: environment, installationRoot: installRoot)
        let restored = try #require(try await reopened.readSkills(id: pdf.id).first)
        #expect(restored.digest == BundledDomainSkills.officialPackageDigests[pdf.id])
        #expect(reopened.builtinSeedFailures[pdf.id] == nil)
        #expect(try await !environment.skillStore.wasBundledSkillRemoved(id: pdf.id))
        #expect(try await !environment.skillStore.wasExplicitlyRemoved(id: pdf.id))
    }

    @Test("Legacy removal whose backup was moved to RemovedSkills restores without touching the backup")
    @MainActor func historicalRemovalWithBackupMoveRestores() async throws {
        let (environment, center, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await center.readSkills(id: "floe-pdf").first
        let pdf = try await persistedRow(environment, "floe-pdf")
        let installRoot = root.appendingPathComponent("Skills")
        try await environment.skillStore.remove(id: pdf.id, expectedDigest: pdf.rewrittenDigest,
                                                suppressBundledSeed: true)
        // The old App's remove MOVED the package directory to RemovedSkills.
        let backupRoot = installRoot.deletingLastPathComponent()
            .appendingPathComponent("RemovedSkills", isDirectory: true)
        let backup = backupRoot.appendingPathComponent("floe-pdf-legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let package = installRoot.appendingPathComponent("floe-pdf", isDirectory: true)
        if FileManager.default.fileExists(atPath: package.path) {
            try FileManager.default.moveItem(at: package, to: backup)
        } else {
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        }
        let reopened = SkillsCenter(environment: environment, installationRoot: installRoot)
        let restored = try #require(try await reopened.readSkills(id: pdf.id).first)
        #expect(restored.digest == BundledDomainSkills.officialPackageDigests[pdf.id])
        // The pre-existing backup stays where it is: restore never overwrites backups.
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    @Test("Seeding never resurrects an externally removed non-builtin skill")
    @MainActor func externalRemovalNeverReappears() async throws {
        let (environment, center, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try await createCustom(center, "selection lane guide", in: environment)
        _ = try await center.manageSkill(.init(action: .remove, id: created.id,
                                               expectedDigest: created.rewrittenDigest))
        #expect(try await environment.skillStore.wasExplicitlyRemoved(id: created.id))
        let reopened = SkillsCenter(environment: environment,
                                    installationRoot: root.appendingPathComponent("Skills"))
        let inventory = try await reopened.readSkills(id: nil)
        #expect(inventory.allSatisfy { $0.id != created.id })
        // Its removal intent is preserved; only preinstalled IDs are repaired.
        #expect(try await environment.skillStore.wasExplicitlyRemoved(id: created.id))
    }

    @Test("Seed pass preserves the installed enabled preference when content matches")
    @MainActor func enabledPreferenceSurvivesSeedPass() async throws {
        let (environment, center, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await center.readSkills(id: "floe-network").first
        let row = try await persistedRow(environment, "floe-network")
        try await environment.skillStore.setEnabled(false, id: row.id, expectedDigest: row.rewrittenDigest)
        let reopened = SkillsCenter(environment: environment,
                                    installationRoot: root.appendingPathComponent("Skills"))
        _ = try await reopened.readSkills(id: "floe-network")
        let after = try await persistedRow(environment, "floe-network")
        #expect(after.status == "disabled")
        #expect(after.rewrittenDigest == row.rewrittenDigest)
        #expect(reopened.builtinSeedFailures.isEmpty)
    }

    // MARK: - Inline batch: serialized, CAS-frozen, failure-preserving

    @Test("Batch delete ignores preselected builtins and keeps them selected")
    @MainActor func batchDeleteRejectsPreinstalledAndRetains() async throws {
        let (environment, center, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await center.readSkills(id: "floe-pdf").first
        let row = try await persistedRow(environment, "floe-pdf")
        center.runSkillBatch(operation: .delete, items: [item(row)])
        let summary = try await waitBatch(center)
        #expect(summary.results.count == 1)
        #expect(summary.results[0].outcome == .failed(SkillBatchCopy.preinstalledCannotRemove))
        #expect(summary.retainedIDs == ["floe-pdf"])
        #expect(summary.removedIDs.isEmpty)
        #expect(try await environment.skillStore.all().contains { $0.id == "floe-pdf" })
    }

    @Test("Batch delete of the eligible non-builtin row removes it and leaves builtins untouched")
    @MainActor func batchDeleteOnlyRemovesEligible() async throws {
        let (environment, center, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await center.readSkills(id: "floe-office").first
        // The view-side eligibility filter drops builtin IDs before
        // submission; the service receives only the eligible snapshot.
        let custom = try await createCustom(center, "batch delete me", in: environment)
        center.runSkillBatch(operation: .delete, items: [item(custom)])
        let summary = try await waitBatch(center)
        #expect(summary.deletedCount == 1)
        #expect(summary.retainedIDs.isEmpty)
        #expect(try await environment.skillStore.all().first { $0.id == custom.id } == nil)
        #expect(try await environment.skillStore.all().contains { $0.id == "floe-office" })
    }

    @Test("Batch enable/disable verifies through a durable post-read and skips target-state rows")
    @MainActor func batchToggleVerifiedOutcomes() async throws {
        let (environment, center, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let onRow = try await createCustom(center, "batch toggle on", in: environment)
        var offRow = try await createCustom(center, "batch toggle off", in: environment)
        try await environment.skillStore.setEnabled(false, id: offRow.id, expectedDigest: offRow.rewrittenDigest)
        offRow = try await persistedRow(environment, offRow.id)
        center.runSkillBatch(operation: .disable, items: [item(onRow), item(offRow)])
        let summary = try await waitBatch(center)
        #expect(summary.results.count == 2)
        #expect(summary.results[0].outcome == .disabled)
        #expect(summary.results[1].outcome == .skipped(.alreadyInTargetState))
        #expect(summary.removedIDs.contains(onRow.id))
        #expect(summary.retainedIDs.isEmpty)
        // Retry pass reconciles again even though a repeated disable of the
        // already-off row produces an otherwise-equal skipped result: each
        // accepted run has a unique identity.
        let offAgain = try await persistedRow(environment, offRow.id)
        center.runSkillBatch(operation: .disable, items: [item(offAgain)])
        let second = try await waitBatch(center)
        #expect(second.runToken != summary.runToken)
        #expect(second != summary)
        #expect(second.results[0].outcome == .skipped(.alreadyInTargetState))
    }

    @Test("Batch acts on the frozen selected digest, never on a replacement from another window")
    @MainActor func batchCasFailsHonestlyOnChangedPackage() async throws {
        let (environment, center, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await createCustom(center, "batch stale target", in: environment)
        // Another window updates/replaces the package while the row is
        // selected: the persisted revision no longer matches the snapshot.
        var replacement = snapshot
        replacement.skillMarkdown = snapshot.skillMarkdown + "\nreplaced\n"
        replacement.rewrittenDigest = String(repeating: "a", count: 64)
        replacement.sourceDigest = replacement.rewrittenDigest
        try await environment.skillStore.save(replacement)
        center.runSkillBatch(operation: .disable, items: [item(snapshot)])
        let summary = try await waitBatch(center)
        #expect(summary.results.count == 1)
        #expect(summary.results[0].outcome == .failed(SkillBatchCopy.changedPackage))
        // Failed selection is PRESERVED for a retry with a fresh snapshot.
        #expect(summary.retainedIDs == [snapshot.id])
        // The replacement's own state was untouched by the stale batch.
        let current = try await persistedRow(environment, snapshot.id)
        #expect(current.status == snapshot.status)
        #expect(current.rewrittenDigest == String(repeating: "a", count: 64))
    }

    @Test("Stale selection on a removed row resolves as gone and leaves the selection")
    @MainActor func batchSkipsMissingRows() async throws {
        let (environment, center, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await createCustom(center, "batch vanishing row", in: environment)
        try await environment.skillStore.remove(id: snapshot.id, expectedDigest: snapshot.rewrittenDigest)
        center.runSkillBatch(operation: .disable, items: [item(snapshot)])
        let summary = try await waitBatch(center)
        #expect(summary.results[0].outcome == .skipped(.alreadyGone))
        #expect(summary.removedIDs.contains(snapshot.id))
        #expect(summary.retainedIDs.isEmpty)
    }

    @Test("Duplicate submissions run once and a concurrent second batch is refused while busy")
    @MainActor func batchSerialGuards() async throws {
        let (environment, center, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await createCustom(center, "batch serial a", in: environment)
        let b = try await createCustom(center, "batch serial b", in: environment)
        center.runSkillBatch(operation: .disable, items: [item(a), item(a), item(b)])
        // Immediate second submission while the service batch owns the list:
        // refused, not queued, never interleaved.
        center.runSkillBatch(operation: .delete, items: [item(b)])
        let summary = try await waitBatch(center)
        #expect(summary.operation == .disable)
        #expect(summary.results.count == 2)
        #expect(try await environment.skillStore.all().contains { $0.id == b.id })
        // Empty submissions are inert.
        center.runSkillBatch(operation: .enable, items: [])
        #expect(!center.isBatchRunning)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(center.lastBatchSummary == summary)
    }

    @Test("Batch completion leaves the builtin protected through the same guard")
    @MainActor func batchNeverBypassesServiceBoundary() async throws {
        let (environment, center, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await center.readSkills(id: "floe-office").first
        let office = try await persistedRow(environment, "floe-office")
        center.runSkillBatch(operation: .delete, items: [item(office)])
        _ = try await waitBatch(center)
        #expect(try await environment.skillStore.all().contains { $0.id == office.id })
        #expect(try await !environment.skillStore.wasExplicitlyRemoved(id: office.id))
        #expect(try await !environment.skillStore.wasBundledSkillRemoved(id: office.id))
    }

    // MARK: - Pure selection reconciliation (view-side contract)

    @Test("Selection prunes invisible rows and keeps only unresolved batch items")
    func selectionReconciliationRules() {
        var selection = SkillBatchSelection()
        selection.enter(selecting: "one")
        selection.toggle("two")
        selection.toggle("three")
        // Search hides "two": its invisible selection leaves the batch.
        selection.prune(toVisible: ["one", "three"])
        #expect(selection.ids == ["one", "three"])
        var summary = SkillBatchSummary(
            runToken: UUID(), operation: .disable,
            results: [
                SkillBatchItemResult(item: .init(id: "one", title: "one", preinstalled: false,
                                                  expectedDigest: String(repeating: "1", count: 64)),
                                     outcome: .disabled),
                SkillBatchItemResult(item: .init(id: "three", title: "three", preinstalled: true,
                                                  expectedDigest: String(repeating: "3", count: 64)),
                                     outcome: .failed(SkillBatchCopy.preinstalledCannotRemove)),
            ],
            wasCancelled: false
        )
        selection.apply(summary: summary)
        #expect(selection.ids == ["three"])
        // A repeated identical outcome set from a NEW run still reconciles
        // (distinct identity, equal payload must not be swallowed).
        summary = SkillBatchSummary(runToken: UUID(), operation: summary.operation,
                                    results: summary.results, wasCancelled: false)
        selection.apply(summary: summary)
        #expect(selection.ids == ["three"])
        #expect(selection.isEverythingSelected(visible: ["three"]))
        selection.exit()
        #expect(!selection.active && selection.ids.isEmpty)
    }

    @Test("Decision table proves post-command states honestly")
    func decisionTablePostRead() {
        let digest = String(repeating: "7", count: 64)
        let item = SkillBatchItem(id: "x", title: "x", preinstalled: false, expectedDigest: digest)
        #expect(SkillBatchDecision.afterCommand(operation: .enable, item: item,
                state: .present(enabled: true, digest: digest)) == .enabled)
        #expect(SkillBatchDecision.afterCommand(operation: .disable, item: item,
                state: .present(enabled: true, digest: digest)) == .failed(SkillBatchCopy.notLanded))
        #expect(SkillBatchDecision.afterCommand(operation: .enable, item: item,
                state: .unreadable("down")) == .unverified("down"))
        #expect(SkillBatchDecision.afterCommand(operation: .delete, item: item,
                state: .present(enabled: true, digest: String(repeating: "8", count: 64)))
                == .unverified(SkillBatchCopy.changedPackage))
        #expect(SkillBatchDecision.afterFailure(operation: .delete, item: item,
                state: .missing, errorText: "boom") == .deleted)
        #expect(SkillBatchDecision.preflight(operation: .disable, item: item,
                state: .present(enabled: false, digest: String(repeating: "9", count: 64)))
                == .failed(SkillBatchCopy.changedPackage))
    }
}
#endif
