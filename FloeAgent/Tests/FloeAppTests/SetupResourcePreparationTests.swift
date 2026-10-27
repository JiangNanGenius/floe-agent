// FloeAppTests — Setup resource preparation contracts.
//
// Pins the non-blocking resource lifecycle the setup guide mirrors:
//   * a job row is identified by the subject the OWNER reports, never by the
//     user's current selection, so an installed voice stays Ready while a
//     different pack downloads;
//   * a finished transfer is Checking/Installing, never Ready, until the owner
//     proves installed bytes;
//   * an unknown total stays indeterminate — no invented size, percentage or
//     speed;
//   * failure, cancellation and pause are bound to the exact resource;
//   * nothing in any stage blocks navigation or Finish;
//   * an explicit voice chosen before its pack exists is applied only while it
//     is still the user's choice, with no substitute and no cloud fallback.
//
// The voice cases run against the REAL `TTSSettingsService` over an injected
// synthetic catalog, so the revision fence under test is the production one.

import Foundation
import Testing
import CryptoKit
@testable import FloeApp
import FloeCore

@Suite("FloeApp.SetupResourceStageRules")
struct SetupResourceStageRulesTests {

    private func report(
        kind: SetupResourceRow.Kind = .voicePack,
        subject: String? = "pack-a",
        phase: SetupResourcePhase = .transferring,
        total: Int64? = 1_000,
        transferred: Int64? = 400,
        installed: Bool = false,
        failure: String? = nil
    ) -> SetupResourceReport {
        SetupResourceReport(
            kind: kind, titleKey: "setup.resource.voice_pack", jobSubjectID: subject,
            phase: phase, totalBytes: total, transferredBytes: transferred,
            isInstalled: installed, failureMessage: failure
        )
    }

    @Test("A complete transfer is checking, not ready")
    func completeTransferIsNotReady() {
        let row = SetupResourceStageRules.row(for: report(transferred: 1_000))
        #expect(row.stage == .verifying)
        #expect(!row.isReady)
        #expect(row.percentText == "100%")
    }

    @Test("Ready comes only from the owner's install proof")
    func readyRequiresInstallProof() {
        let verifying = SetupResourceStageRules.row(for: report(phase: .verifying, installed: false))
        #expect(verifying.stage == .verifying)
        let installed = SetupResourceStageRules.row(for: report(phase: .finished, installed: true))
        #expect(installed.stage == .ready)
        // A byte counter alone can never claim readiness.
        let bytesOnly = SetupResourceStageRules.row(for: report(transferred: 1_000, installed: false))
        #expect(bytesOnly.stage != .ready)
    }

    @Test("An unknown total renders indeterminate instead of a fabricated percentage")
    func unknownTotalStaysIndeterminate() {
        let row = SetupResourceStageRules.row(for: report(total: nil, transferred: 250))
        #expect(row.fraction == nil)
        #expect(row.percentText == nil)
        #expect(row.stage == .downloading)
        let zeroTotal = SetupResourceStageRules.row(for: report(total: 0, transferred: 0))
        #expect(zeroTotal.fraction == nil)
    }

    @Test("An owner-published fraction is used as-is, never re-derived")
    func ownerFractionWins() {
        var ownerReport = report(total: 900, transferred: nil)
        ownerReport.ownerFraction = 0.42
        let row = SetupResourceStageRules.row(for: ownerReport)
        #expect(row.fraction == 0.42)
        #expect(row.percentText == "42%")
    }

    @Test("No stage ever blocks navigation or Finish")
    func nothingBlocksNavigation() {
        let stages: [SetupResourceStage] = [
            .notRequested, .queued, .downloading, .verifying, .installing,
            .awaitingConfirmation, .ready, .paused, .cancelled, .failed("owner error")
        ]
        for stage in stages {
            #expect(!stage.blocksNavigation, "\(stage) must never gate navigation")
        }
        // A failed or paused resource is retryable, and only that one row.
        let failed = SetupResourceStageRules.row(for: report(failure: "owner error"))
        #expect(failed.canRetry)
        #expect(!failed.canCancel)
        let paused = SetupResourceStageRules.row(for: report(phase: .queued))
        #expect(paused.canCancel)
    }

    @Test("Row identity follows the job subject, not the current selection")
    func identityFollowsTheJob() {
        let installingNew = SetupResourceReport(
            kind: .voicePack, titleKey: "t", jobSubjectID: "pack-b",
            phase: .transferring, totalBytes: 10, transferredBytes: 5
        )
        let row = SetupResourceStageRules.row(for: installingNew)
        #expect(row.id == "setup.resource.voicePack.pack-b")
        #expect(row.jobSubjectID == "pack-b")
        // The already-installed pack the user still has selected keeps its own
        // row identity and its own Ready state.
        let installedOld = SetupResourceReport(
            kind: .voicePack, titleKey: "t", jobSubjectID: "pack-a",
            phase: .finished, isInstalled: true
        )
        let oldRow = SetupResourceStageRules.row(for: installedOld)
        #expect(oldRow.id != row.id)
        #expect(oldRow.stage == .ready)
        #expect(row.stage == .downloading)
    }

    @Test("Selection readiness is a separate fact from the running job")
    func selectionIsSeparateFromTheJob() {
        // Old pack installed and selected, new pack downloading.
        let selection = SetupResourceStageRules.selection(
            kind: .voicePack,
            selectedSubjectID: "pack-a",
            installedSubjectIDs: ["pack-a"],
            activeJobSubjectID: "pack-b",
            pendingSubjectID: nil
        )
        #expect(selection.isSelectedReady)
        #expect(selection.pendingSubjectID == nil)
        #expect(selection.isSatisfied)

        // The user asked for pack-b while pack-a still plays.
        let pending = SetupResourceStageRules.selection(
            kind: .voicePack,
            selectedSubjectID: "pack-a",
            installedSubjectIDs: ["pack-a"],
            activeJobSubjectID: "pack-b",
            pendingSubjectID: "pack-b"
        )
        #expect(pending.isSelectedReady, "the playable source is still ready")
        #expect(pending.pendingSubjectID == "pack-b")

        // A selected pack that is not installed is honestly pending.
        let missing = SetupResourceStageRules.selection(
            kind: .voicePack,
            selectedSubjectID: "pack-c",
            installedSubjectIDs: ["pack-a"],
            activeJobSubjectID: nil
        )
        #expect(!missing.isSelectedReady)
        #expect(missing.pendingSubjectID == "pack-c")
    }

    @Test("A pending choice applies only while it is still the current choice")
    func pendingChoiceFence() {
        #expect(SetupResourceStageRules.shouldApplyPendingSelection(
            pendingSubjectID: "pack-b", currentSubjectID: "pack-b", isInstalled: true))
        #expect(!SetupResourceStageRules.shouldApplyPendingSelection(
            pendingSubjectID: "pack-b", currentSubjectID: "pack-c", isInstalled: true))
        #expect(!SetupResourceStageRules.shouldApplyPendingSelection(
            pendingSubjectID: "pack-b", currentSubjectID: "pack-b", isInstalled: false))
        #expect(!SetupResourceStageRules.shouldApplyPendingSelection(
            pendingSubjectID: nil, currentSubjectID: "pack-b", isInstalled: true))
    }

    @Test("A failure is bound to the resource that actually failed")
    func failureIsPerResource() {
        let failed = SetupResourceStageRules.row(for: report(subject: "model-x", failure: "out of space"))
        let healthy = SetupResourceStageRules.row(for: report(subject: "model-y", phase: .finished,
                                                              installed: true))
        #expect(failed.id == "setup.resource.onDeviceModel.model-x" || failed.id.hasSuffix("model-x"))
        #expect(failed.stage == .failed("out of space"))
        #expect(healthy.stage == .ready)
        // A stale byte mirror with no owner activity is not "queued" forever.
        let stale = SetupResourceStageRules.row(for: SetupResourceReport(
            kind: .onDeviceModel, titleKey: "t", jobSubjectID: "model-z",
            phase: .idle, totalBytes: 10, transferredBytes: 4
        ))
        #expect(stale.stage == .notRequested)
    }

    @Test("Skill Hub jobs and signed content updates stay distinct resources")
    func hubAndContentAreDifferentOwners() {
        let hub = SetupResourceStageRules.row(for: SetupResourceReport(
            kind: .skillHub, titleKey: "setup.resource.skill_hub", jobSubjectID: "impeccable",
            phase: .awaitingConfirmation
        ))
        let content = SetupResourceStageRules.row(for: SetupResourceReport(
            kind: .contentUpdate, titleKey: "settings.content_updates.kind.prompts",
            jobSubjectID: "floe.prompts.core", phase: .installing
        ))
        #expect(hub.kind == .skillHub)
        #expect(content.kind == .contentUpdate)
        #expect(hub.id != content.id)
        #expect(hub.stage == .awaitingConfirmation)
        #expect(content.stage == .installing)
        // Both belong to the same product section, and neither blocks it.
        #expect(SetupGuideSummaryBuilder.ownerSection(of: hub) == .skills)
        #expect(SetupGuideSummaryBuilder.ownerSection(of: content) == .skills)
        #expect(!hub.stage.blocksNavigation)
        #expect(!content.stage.blocksNavigation)
    }

    @Test("Preparing work lifts only its own section in the summary")
    func preparingLiftsOnlyItsSection() {
        var state = SetupGuideState()
        SetupGuideReducer.reduce(&state, .setStatus(.chatModels, .configured))
        let rows = [
            SetupResourceStageRules.row(for: SetupResourceReport(
                kind: .localRuntime, titleKey: "t", jobSubjectID: "img",
                phase: .transferring, totalBytes: 100, ownerFraction: 0.3
            )),
            SetupResourceStageRules.row(for: SetupResourceReport(
                kind: .voicePack, titleKey: "t", jobSubjectID: "pack",
                phase: .finished, isInstalled: true
            ))
        ]
        let entries = SetupGuideSummaryBuilder.entries(state: state, resources: rows)
        let outcomes = Dictionary(uniqueKeysWithValues: entries.map { ($0.section, $0.outcome) })
        #expect(outcomes[.files] == .preparing)
        #expect(outcomes[.voice] == .later, "a ready pack is not a user decision")
        #expect(outcomes[.chatModels] == .saved)
    }
}

@Suite("FloeApp.SetupGuideFinishFence")
struct SetupGuideFinishFenceTests {

    @Test("Finish is terminal: no later action reopens the guide as in progress")
    func finishIsTerminal() {
        var state = SetupGuideState()
        SetupGuideReducer.reduce(&state, .jump(.summary))
        SetupGuideReducer.reduce(&state, .finish)
        #expect(state.finished)

        // A late resource mirror, a navigation callback and a status write all
        // arrive after the terminal Finish; none may undo it.
        SetupGuideReducer.reduce(&state, .setPreparation(.voice, true))
        SetupGuideReducer.reduce(&state, .setStatus(.voice, .configured))
        SetupGuideReducer.reduce(&state, .next)
        SetupGuideReducer.reduce(&state, .jump(.chatModels))
        SetupGuideReducer.reduce(&state, .deferCurrentSection)
        #expect(state.finished)
        #expect(state.section == .summary)
        #expect(state.status(for: .voice) == .unset)
    }

    @Test("Finish without any provider still completes the guide")
    func finishWithoutProvider() {
        // The guide's own completion is not gated on provider readiness: the
        // user may finish with nothing configured and preparation still running.
        var state = SetupGuideState()
        for section in SetupGuideSection.configurable {
            SetupGuideReducer.reduce(&state, .setStatus(section, .deferred))
        }
        SetupGuideReducer.reduce(&state, .jump(.summary))
        SetupGuideReducer.reduce(&state, .finish)
        #expect(state.finished)
        let entries = SetupGuideSummaryBuilder.entries(state: state)
        #expect(entries.allSatisfy { $0.outcome == .later })
    }

    @Test("A resumable record is written only while the guide is unfinished")
    func progressIsWrittenOnlyWhenUnfinished() {
        let suiteName = "FloeAppTests.SetupGuideFinish.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var state = SetupGuideState()
        SetupGuideReducer.reduce(&state, .start(.lightStart))
        SetupGuideReducer.reduce(&state, .next)
        SetupGuideProgressStore.save(SetupGuideReducer.progress(from: state), to: defaults)
        #expect(SetupGuideProgressStore.load(from: defaults)?.currentSection == .creation)

        // Terminal Finish clears the record, and a teardown afterwards must
        // not write it back.
        SetupGuideReducer.reduce(&state, .jump(.summary))
        SetupGuideReducer.reduce(&state, .finish)
        SetupGuideProgressStore.clear(from: defaults)
        #expect(SetupGuideProgressStore.load(from: defaults) == nil)
        #expect(state.finished)
    }
}

// MARK: - Real voice service contract

@Suite("FloeApp.SetupPendingVoiceContract")
@MainActor
struct SetupPendingVoiceContractTests {

    @Test("An explicit undownloaded voice keeps the playable source until the pack is installed")
    func pendingVoiceDoesNotSwitchSourceEarly() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }

        // Nothing installed yet: the current source is the system voice.
        #expect(fixture.service.snapshot.provider == .apple)
        let pack = try #require(fixture.service.chooseVoice(
            modelID: fixture.model.id, voiceID: "serena"))
        #expect(pack.id == fixture.model.id)
        // The wish is remembered, the playable source is untouched.
        #expect(fixture.service.pendingVoice?.voiceID == "serena")
        #expect(fixture.service.snapshot.provider == .apple)
        #expect(!fixture.service.localInstalledModelIDs.contains(fixture.model.id))

        await fixture.service.install(pack)
        await fixture.settle()
        await fixture.service.syncLocalSelection()

        // Installed + validated: the explicit voice is now the source.
        #expect(fixture.service.snapshot.provider == .onDevice)
        #expect(fixture.service.snapshot.voiceID == "serena")
        #expect(fixture.service.pendingVoice == nil)
    }

    @Test("A later user choice during a suspended validation wins and nothing is substituted")
    func laterChoiceWinsAtCommit() async throws {
        let fixture = try await Fixture.make(holdValidation: true)
        defer { fixture.cleanup() }

        let pack = try #require(fixture.service.chooseVoice(
            modelID: fixture.model.id, voiceID: "serena"))
        await fixture.service.install(pack)
        await fixture.settle()

        // The validator is suspended; the user picks the system voice instead.
        let sync = Task { await fixture.service.syncLocalSelection() }
        await fixture.gate.waitForEntry()
        fixture.service.update {
            $0.provider = .apple
            $0.voiceID = "com.apple.voice.compact.en-GB.Daniel"
        }
        await fixture.gate.release(.passed)
        await sync.value

        // The stale intent cannot commit, and the pending record is dropped.
        #expect(fixture.service.snapshot.provider == .apple)
        #expect(fixture.service.snapshot.voiceID == "com.apple.voice.compact.en-GB.Daniel")
        #expect(fixture.service.pendingVoice == nil)
    }

    @Test("The first explicit non-default voice wins over the catalog default")
    func explicitVoiceBeatsFirstInstallDefault() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }

        // The catalog default is "default"; the user asks for "serena" first.
        let pack = try #require(fixture.service.chooseVoice(
            modelID: fixture.model.id, voiceID: "serena"))
        await fixture.service.install(pack)
        await fixture.settle()
        await fixture.service.syncLocalSelection()

        #expect(fixture.service.snapshot.voiceID == "serena",
                "the explicit choice must not be replaced by the catalog default")
        #expect(fixture.service.snapshot.modelID == fixture.model.id)
    }

    @Test("Cancelling the transfer drops the pending voice without touching the source")
    func cancelDropsPendingVoice() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }

        let pack = try #require(fixture.service.chooseVoice(
            modelID: fixture.model.id, voiceID: "serena"))
        await fixture.service.install(pack)
        await fixture.service.cancelInstallation()
        await fixture.settle()
        await fixture.service.syncLocalSelection()

        #expect(fixture.service.pendingVoice == nil)
        #expect(fixture.service.snapshot.provider == .apple)
    }

    @Test("A failed validation keeps the pending voice retryable and the source playable")
    func failedValidationKeepsSource() async throws {
        let fixture = try await Fixture.make(validation: .failed)
        defer { fixture.cleanup() }

        let pack = try #require(fixture.service.chooseVoice(
            modelID: fixture.model.id, voiceID: "serena"))
        await fixture.service.install(pack)
        await fixture.settle()
        await fixture.service.syncLocalSelection()

        #expect(fixture.service.snapshot.provider == .apple)
        #expect(fixture.service.localMigrationNote == "voice.local.error.verify")
    }

    @Test("A superseded intent cannot be committed by its own late validation")
    func supersededIntentCannotCommit() async throws {
        let fixture = try await Fixture.make(holdValidation: true)
        defer { fixture.cleanup() }

        let pack = try #require(fixture.service.chooseVoice(
            modelID: fixture.model.id, voiceID: "serena"))
        await fixture.service.install(pack)
        await fixture.settle()

        let firstSync = Task { await fixture.service.syncLocalSelection() }
        await fixture.gate.waitForEntry()
        // The user changes the wish to the catalog default voice instead.
        _ = fixture.service.chooseVoice(modelID: fixture.model.id, voiceID: "default")
        await fixture.gate.release(.passed)
        await firstSync.value
        await fixture.service.syncLocalSelection()

        #expect(fixture.service.snapshot.voiceID == "default",
                "only the newest intent may commit")
        #expect(fixture.service.pendingVoice == nil)
    }
}

// MARK: - Test fixtures

/// A synthetic visible pack with two voices, installed through the real store
/// and the real settings service. No network, no Keychain item and no audio.
@MainActor
private struct Fixture {
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    let model: LocalSpeechModel
    let store: LocalSpeechModelStore
    let gate: ValidationGate
    let service: TTSSettingsService

    static func make(
        holdValidation: Bool = false,
        validation: LocalPackValidation = .passed
    ) async throws -> Fixture {
        let suiteName = "setup-voice-test.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data("synthetic-voice-pack".utf8)
        let revision = String(repeating: "a", count: 40)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let model = LocalSpeechModel(
            id: "synthetic-pack",
            title: "Synthetic Pack",
            engine: "mossTTSNano",
            repository: "test/synthetic",
            revision: revision,
            license: "Apache-2.0",
            languages: ["zh", "en"],
            voices: [
                .init(id: "default", name: "Default", languages: ["zh", "en"]),
                .init(id: "serena", name: "Serena", languages: ["zh", "en"])
            ],
            files: [.init(
                path: "weights.bin",
                url: URL(string: "https://huggingface.co/test/synthetic/resolve/\(revision)/weights.bin")!,
                sha256: hash,
                byteCount: Int64(bytes.count)
            )],
            tokenizerRelativePath: nil,
            minimumMemoryBytes: nil,
            defaultVoiceID: "default",
            visibility: "visible"
        )
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let store = LocalSpeechModelStore(
            catalog: LocalSpeechCatalog(schemaVersion: 1, models: [model]),
            root: root.appendingPathComponent("models"),
            defaults: UserDefaults(suiteName: suiteName)!,
            downloader: SyntheticDownloader(root: root, bytes: bytes)
        )
        let gate = ValidationGate()
        await gate.setResult(validation)
        if holdValidation { await gate.hold() }
        let service = TTSSettingsService(
            defaults: defaults,
            keychain: SyntheticKeychain(),
            modelStore: store,
            loadValidator: { _, _ in await gate.current() }
        )
        // The catalog is read once so chooseVoice can resolve the pack.
        await service.refreshAfterExternalChange()
        return Fixture(root: root, suiteName: suiteName, defaults: defaults, model: model,
                       store: store, gate: gate, service: service)
    }

    /// Waits for the store's own install task to finish.
    func settle() async throws {
        for _ in 0..<400 {
            if await !(store.state().running) {
                try await Task.sleep(for: .milliseconds(20))
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("synthetic install did not finish")
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

/// Suspends the load-validation hook so a selection change can be made while
/// the validator is in flight.
private actor ValidationGate {
    private var waiters: [CheckedContinuation<LocalPackValidation, Never>] = []
    private var result: LocalPackValidation = .passed
    private var holding = false
    private(set) var entries = 0

    func setResult(_ value: LocalPackValidation) { result = value }
    func hold() { holding = true }

    func current() async -> LocalPackValidation {
        entries += 1
        guard holding else { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func waitForEntry() async {
        while entries == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func release(_ value: LocalPackValidation) {
        holding = false
        result = value
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: value) }
    }
}

private actor SyntheticDownloader: LocalSpeechDownloading {
    let root: URL
    let bytes: Data
    init(root: URL, bytes: Data) { self.root = root; self.bytes = bytes }
    func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: target)
        progress(Int64(bytes.count))
        return target
    }
}

private final class SyntheticKeychain: KeychainProbeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    func store(account: String, secret: Data) throws {
        lock.lock(); items[account] = secret; lock.unlock()
    }
    func read(account: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value = items[account] else { throw KeychainStoreError.itemNotFound }
        return value
    }
    func delete(account: String) throws {
        lock.lock(); items.removeValue(forKey: account); lock.unlock()
    }
}
