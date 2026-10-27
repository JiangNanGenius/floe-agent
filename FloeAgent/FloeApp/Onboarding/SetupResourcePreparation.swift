// FloeApp — Setup guide resource preparation adapter.
//
// SPDX-License-Identifier: MPL-2.0
//
// The guide owns no downloader. Each row mirrors a job an EXISTING service
// already owns and reports only facts that service measured. Leaving the page
// unsubscribes this helper and nothing else: the Task belongs to the store,
// the shared image job or the installer, so returning shows the SAME job at
// its real progress.
//
// A row is identified by the pack/model/image the OWNER says it is working
// on, never by what the user currently has selected. An installed voice
// therefore keeps reading as Ready while a different voice downloads, and a
// running job is never masked by a selection change.
//
// Reads are coalesced and generation-fenced: a burst of owner notifications
// collapses into one pass, a read that finishes after a newer one started
// drops its result, and unsubscribing bumps the generation so a callback in
// flight can never republish rows.

import Foundation
import Combine
import FloeCore
import FloeExecution
import FloeLocalModels
import FloeLocalModelCatalog
import FloeSkills

@MainActor
final class SetupResourcePreparation: ObservableObject {
    /// One row per reported owner job.
    @Published private(set) var rows: [SetupResourceRow] = []
    /// The user's current choice per kind, kept separate from job state.
    @Published private(set) var selections: [SetupResourceRow.Kind: SetupSelectionState] = [:]

    /// The authoritative Linux runtime model, reused unchanged: it derives
    /// its state from verified image bytes and the ONE shared image job, and
    /// preparing the runtime never boots a guest by itself.
    let runtime: LinuxImageInstallModel

    private let center: ConversationCenter
    /// The shared image job's start/finish signal only.
    private var jobsPublisher: AnyPublisher<Set<String>, Never> {
        EnvironmentPackageJobs.shared.$running.eraseToAnyPublisher()
    }
    private var cancellables: Set<AnyCancellable> = []
    private var pump: Task<Void, Never>?
    private var scheduled: Task<Void, Never>?
    private var isObserving = false
    /// Bumped when a read starts and on teardown. Progress notifications do
    /// not invalidate every read while a transfer is continuously active.
    private var generation = 0

    init(center: ConversationCenter) {
        self.center = center
        self.runtime = LinuxImageInstallModel(
            imageID: LinuxGuestImageDistributionCatalog.defaultImageID
        )
    }

    // MARK: - Subscription (teardown unsubscribes only)

    /// Starts mirroring. Idempotent, so a re-entrant body can never install a
    /// second pump on the same owners.
    func observe() {
        guard !isObserving else { return }
        isObserving = true
        let environment = center.environment
        let owners: [ObjectWillChangePublisher] = [
            environment.ttsSettingsService.objectWillChange,
            environment.localModelsCenter.objectWillChange,
            environment.contentUpdateCenter.objectWillChange,
            environment.skillsCenter.objectWillChange,
            environment.settingsCenter.objectWillChange,
            EnvironmentPackageJobs.shared.objectWillChange,
            runtime.objectWillChange,
            center.objectWillChange
        ]
        for owner in owners {
            owner
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.scheduleRebuild() }
                .store(in: &cancellables)
        }
        // The image card owns the only honest disk read. Refresh it on the
        // shared job's start/finish transitions, never per byte callback.
        jobsPublisher
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isObserving else { return }
                Task { [weak self] in
                    await self?.runtime.refresh()
                    await self?.rebuildNow()
                }
            }
            .store(in: &cancellables)
        // The recognition store is an actor with no Combine surface: one
        // bounded 1 Hz read mirrors its real bytes without owning any part of
        // the transfer, and it stops the moment this page goes away.
        pump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let owner = self else { break }
                await owner.rebuildNow()
            }
        }
        Task { [weak self] in
            await self?.runtime.probeOnce()
            await self?.runtime.refresh()
        }
        scheduleRebuild()
    }

    /// Stops mirroring for this page. Owned jobs keep running.
    func stopObserving() {
        isObserving = false
        // Fence first: anything already in flight loses its publication gate.
        generation += 1
        cancellables.removeAll()
        scheduled?.cancel()
        scheduled = nil
        pump?.cancel()
        pump = nil
    }

    // MARK: - Reads

    func row(id: String) -> SetupResourceRow? { rows.first { $0.id == id } }
    func rows(kind: SetupResourceRow.Kind) -> [SetupResourceRow] { rows.filter { $0.kind == kind } }
    func stage(for id: String) -> SetupResourceStage { row(id: id)?.stage ?? .notRequested }

    func selection(for kind: SetupResourceRow.Kind) -> SetupSelectionState {
        selections[kind] ?? SetupSelectionState(kind: kind, selectedSubjectID: nil)
    }

    /// Only feeds the summary's honest counts. No navigation and no finish
    /// decision consults it.
    var preparingCount: Int { rows.filter { $0.stage.isPreparing }.count }
    var readyCount: Int { rows.filter { $0.isReady }.count }
    var isAnyPreparing: Bool { rows.contains { $0.stage.isPreparing } }

    var failedRows: [SetupResourceRow] {
        rows.filter { if case .failed = $0.stage { return true }; return false }
    }
    var attentionCount: Int { failedRows.count }

    /// The voice the user picked that is still being prepared. The voice
    /// service owns the revision fence that decides whether it is applied.
    var pendingVoiceModelID: String? { selection(for: .voicePack).pendingSubjectID }

    // MARK: - Requests (each goes to the existing owner)

    func prepareSpeechRecognitionModel() {
        Task { await WhisperModelStore.shared.beginInstallation() }
        scheduleRebuild()
    }

    func cancelSpeechRecognitionModel() {
        Task { await WhisperModelStore.shared.cancelInstallation() }
        scheduleRebuild()
    }

    /// Asks the voice-output service to install a pack. That service already
    /// fences the pending selection by revision and applies it only when the
    /// user has not changed their mind, so there is no second selection
    /// mechanism here, no cloud substitution and no audition impersonation.
    func prepareVoicePack(_ model: LocalSpeechModel) {
        Task { await center.environment.ttsSettingsService.install(model) }
        scheduleRebuild()
    }

    func cancelVoicePack() {
        Task { await center.environment.ttsSettingsService.cancelInstallation() }
        scheduleRebuild()
    }

    func prepareOnDeviceModel(_ entry: LocalModelCatalogEntry) {
        center.environment.localModelsCenter.download(entry)
        scheduleRebuild()
    }

    func pauseOnDeviceModel(_ entry: LocalModelCatalogEntry) {
        center.environment.localModelsCenter.pause(entry)
        scheduleRebuild()
    }

    func cancelOnDeviceModel(_ entry: LocalModelCatalogEntry) {
        center.environment.localModelsCenter.cancel(entry)
        scheduleRebuild()
    }

    /// The one Linux download entry: the same shared, coalesced and
    /// cancellable job the Terminal and Settings cards use.
    func prepareRuntime() {
        runtime.startDownload()
        scheduleRebuild()
    }

    func cancelRuntime() {
        runtime.cancelDownload()
        scheduleRebuild()
    }

    func prepareContent(_ id: String) {
        Task { await center.environment.contentUpdateCenter.beginInstall(id) }
        scheduleRebuild()
    }

    func cancelContent(_ id: String) {
        center.environment.contentUpdateCenter.cancelInstall(id)
        scheduleRebuild()
    }

    func checkContent() {
        Task { await center.environment.contentUpdateCenter.checkForUpdates(force: true) }
        scheduleRebuild()
    }

    /// One explicit "Get" on a Skill Hub entry. The center owns the single
    /// writer, the stage rows, the scope decision, the retry and the receipt;
    /// closing this page never touches the job.
    func prepareSkillHub(id: String) {
        center.environment.skillsCenter.requestHubInstall(id: id)
        scheduleRebuild()
    }

    func cancelSkillHub(id: String) {
        center.environment.skillsCenter.cancelHubInstall(id: id)
        scheduleRebuild()
    }

    // MARK: - Coalesced, fenced rebuild

    /// Coalesce bursts into a bounded snapshot cadence. A continuous stream
    /// must not keep cancelling the pending read or invalidate it mid-await;
    /// otherwise fast downloads could show no progress until they finished.
    private func scheduleRebuild() {
        guard isObserving, scheduled == nil else { return }
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, self.isObserving else { return }
            self.scheduled = nil
            await self.rebuildNow()
        }
    }

    /// Immediate read for the slow actor pump; it takes a fresh generation so
    /// it can never be mistaken for an older coalesced result.
    private func rebuildNow() async {
        guard isObserving else { return }
        generation += 1
        await rebuild(generation: generation)
    }

    private func rebuild(generation captured: Int) async {
        guard isObserving, generation == captured else { return }
        let snapshot = await collect()
        // The awaits above let a newer read start; its facts are by
        // construction fresher, so this result is dropped.
        guard isObserving, generation == captured else { return }
        rows = snapshot.rows
        selections = snapshot.selections
    }

    private func collect() async
        -> (rows: [SetupResourceRow], selections: [SetupResourceRow.Kind: SetupSelectionState]) {
        let environment = center.environment
        var collected: [SetupResourceRow] = []
        var selections: [SetupResourceRow.Kind: SetupSelectionState] = [:]

        let recognition = await recognitionSnapshot()
        collected.append(SetupResourceStageRules.row(for: recognition.report))
        selections[.speechRecognition] = recognition.selection

        let voice = voiceReports(environment.ttsSettingsService)
        collected.append(contentsOf: voice.rows.map(SetupResourceStageRules.row(for:)))
        selections[.voicePack] = voice.selection

        let models = modelReports(environment.localModelsCenter)
        collected.append(contentsOf: models.rows.map(SetupResourceStageRules.row(for:)))
        selections[.onDeviceModel] = models.selection

        let runtimeReport = runtimeReport()
        collected.append(SetupResourceStageRules.row(for: runtimeReport))
        selections[.localRuntime] = SetupSelectionState(
            kind: .localRuntime,
            selectedSubjectID: runtimeReport.isInstalled ? runtime.imageID : nil,
            installedSubjectIDs: runtimeReport.isInstalled ? [runtime.imageID] : [],
            pendingSubjectID: SetupResourceStageRules.stage(for: runtimeReport).isPreparing
                ? runtime.imageID : nil
        )

        let content = contentReports(environment.contentUpdateCenter)
        collected.append(contentsOf: content.map(SetupResourceStageRules.row(for:)))

        // A Skill Hub "Get" started here must be visible here: its job belongs
        // to SkillsCenter, so only that owner's phase and proof are mirrored.
        let hub = skillHubReports(environment.skillsCenter)
        collected.append(contentsOf: hub.map(SetupResourceStageRules.row(for:)))
        selections[.skillHub] = SetupResourceStageRules.selection(
            kind: .skillHub,
            selectedSubjectID: hub.first(where: {
                $0.phase == .finished || $0.phase == .transferring || $0.phase == .awaitingConfirmation
            })?.jobSubjectID,
            installedSubjectIDs: Set(hub.filter { $0.isInstalled }.map { $0.jobSubjectID ?? "" }),
            activeJobSubjectID: hub.first(where: { $0.phase.isLive })?.jobSubjectID
        )

        return (collected, selections)
    }

    // MARK: - Owner reports

    /// The recognition row follows the store's own job identity, phase and
    /// measured rate; the selection follows the method the user chose. Nothing
    /// here is inferred from a UI timer or from a byte counter alone.
    private func recognitionSnapshot() async
        -> (report: SetupResourceReport, selection: SetupSelectionState) {
        let store = WhisperModelStore.shared
        let installed = await store.isInstalled()
        let identity = await store.installedIdentity()
        let state = await store.installationState()
        let phase: SetupResourcePhase
        if installed, !state.running {
            phase = .finished
        } else if !state.running {
            phase = .idle
        } else {
            phase = switch state.phase {
            case .downloading: .transferring
            case .verifying: .verifying
            case .committing: .installing
            }
        }
        let subject = state.running ? state.modelIdentity : identity
        let report = SetupResourceReport(
            kind: .speechRecognition,
            titleKey: "setup.resource.speech_recognition",
            jobSubjectID: subject,
            phase: phase,
            totalBytes: state.total > 0 ? state.total : nil,
            transferredBytes: state.running || installed ? state.completed : nil,
            bytesPerSecond: state.bytesPerSecond > 0 ? state.bytesPerSecond : nil,
            isInstalled: installed,
            failureMessage: state.error
        )
        // A different fact than the job: the user may have chosen on-device
        // recognition while the pack is still missing.
        let wantsEnhanced = VoiceRecognitionPreferences.method == .enhanced
        let selection = SetupResourceStageRules.selection(
            kind: .speechRecognition,
            selectedSubjectID: wantsEnhanced ? subject : "system",
            installedSubjectIDs: installed ? [subject ?? "whisper"] : [],
            activeJobSubjectID: state.running ? subject : nil
        )
        return (report, selection)
    }

    /// Every reported installation gets its own row, keyed by the pack the
    /// store says it is working on.
    private func voiceReports(_ service: TTSSettingsService)
        -> (rows: [SetupResourceReport], selection: SetupSelectionState) {
        let installation = service.localInstallation
        let installedIDs = service.localInstalledModelIDs
        var reports: [SetupResourceReport] = []
        if let active = installation.modelID {
            let phase: SetupResourcePhase
            if installation.running {
                phase = switch installation.phase {
                case .queued: .queued
                case .downloading: .transferring
                case .verifying: .verifying
                case .committing: .installing
                }
            } else if validatingModelID == active {
                phase = .verifying
            } else if installedIDs.contains(active) {
                phase = .finished
            } else {
                phase = .idle
            }
            reports.append(SetupResourceReport(
                kind: .voicePack,
                titleKey: "setup.resource.voice_pack",
                jobSubjectID: active,
                phase: phase,
                totalBytes: installation.total > 0 ? installation.total : nil,
                transferredBytes: installation.running || installation.completed > 0
                    ? installation.completed : nil,
                bytesPerSecond: installation.bytesPerSecond > 0 ? installation.bytesPerSecond : nil,
                isInstalled: installedIDs.contains(active),
                failureMessage: installation.failureKey
                    ?? (validationFailed ? "voice.local.error.verify" : nil)
            ))
        }
        // The playable source and the remembered choice are two different
        // facts: an installed voice stays Ready while the pack the user asked
        // for is still arriving.
        let selectedID = service.snapshot.modelID.isEmpty ? nil : service.snapshot.modelID
        // Readiness of the SELECTION uses the same validated set, so a row can
        // never claim the chosen voice works while its validation is pending.
        return (reports, SetupResourceStageRules.selection(
            kind: .voicePack,
            selectedSubjectID: selectedID,
            installedSubjectIDs: installedIDs,
            activeJobSubjectID: installation.running ? installation.modelID : nil,
            pendingSubjectID: service.pendingVoice?.modelID
        ))
    }

    /// Active, paused and installed catalogue entries each get exactly one
    /// row. A full transfer still reads as verifying until the store's own
    /// install proof appears.
    private func modelReports(_ models: LocalModelsCenter)
        -> (rows: [SetupResourceReport], selection: SetupSelectionState) {
        var reports: [SetupResourceReport] = []
        var installedIDs = Set<String>()
        for entry in CuratedLocalModelCatalog.entries where models.installedIDs.contains(entry.id) {
            installedIDs.insert(entry.id)
            reports.append(SetupResourceReport(
                kind: .onDeviceModel,
                titleKey: entry.displayName,
                jobSubjectID: entry.id,
                phase: .finished,
                totalBytes: entry.approximateDownloadBytes,
                isInstalled: true
            ))
        }
        for entry in CuratedLocalModelCatalog.entries {
            let active = models.activeDownloads.contains(entry.id)
            let paused = models.pausedDownloads.contains(entry.id)
            let progress = models.downloadProgress[entry.id]
            // A finished-with-error transfer leaves its own per-model failure
            // behind. Without that owner fact a stale byte mirror would read as
            // "queued" forever, so the row stays silent instead of lying.
            let failure = models.failedDownloads[entry.id] ?? models.incompatibleReasons[entry.id]
            guard active || paused || progress != nil || failure != nil,
                  !installedIDs.contains(entry.id) else { continue }
            let phase: SetupResourcePhase
            if active {
                phase = (progress?.fractionCompleted ?? 0) >= 1 && (progress?.bytesExpected ?? 0) > 0
                    ? .verifying : .transferring
            } else if paused {
                phase = .queued
            } else if failure != nil {
                phase = .idle
            } else if progress != nil {
                // The owner stopped reporting bytes with no install proof and
                // no failure: nothing is running any more.
                phase = .idle
            } else {
                phase = .idle
            }
            reports.append(SetupResourceReport(
                kind: .onDeviceModel,
                titleKey: entry.displayName,
                jobSubjectID: entry.id,
                phase: phase,
                // The catalogue carries the real declared size, so an offered
                // resource shows an actual total before its first byte.
                totalBytes: progress?.bytesExpected ?? entry.approximateDownloadBytes,
                transferredBytes: progress?.bytesReceived,
                bytesPerSecond: progress?.bytesPerSecond.map { Int64($0) },
                isPaused: paused && progress == nil && !active ? false : paused,
                failureMessage: failure
            ))
        }
        let selected = center.modelPreferences.defaultAgentModelID.flatMap { id in
            CuratedLocalModelCatalog.entries.first { $0.profileID == id }?.id
        }
        return (reports, SetupResourceStageRules.selection(
            kind: .onDeviceModel,
            selectedSubjectID: selected,
            installedSubjectIDs: models.installedIDs,
            activeJobSubjectID: models.activeDownloads.first
        ))
    }

    /// Derived only from the reused card model and the shared image job, so
    /// the guide cannot disagree with Settings or Terminal about the runtime.
    /// The phase is the service's own reported phase and the total is the
    /// pinned archive's real probed size; an unprobed size stays nil, which
    /// renders an indeterminate bar instead of an invented total.
    private func runtimeReport() -> SetupResourceReport {
        let jobs = EnvironmentPackageJobs.shared
        let running = jobs.running.contains(runtime.jobID)
        let phase = jobs.phases[runtime.jobID]
        let fraction = running ? jobs.fractions[runtime.jobID] : nil
        let installed: Bool
        switch runtime.state {
        case .installedStopped, .running, .updateAvailable: installed = true
        default: installed = false
        }
        var resourcePhase: SetupResourcePhase = .idle
        var failure: String?
        switch runtime.state {
        case .storageInitializing: resourcePhase = running ? .queued : .idle
        case .storageUnavailable: failure = "environment.backend.image_store_unavailable"
        case .needsDownload(let verification):
            resourcePhase = running ? .queued : .idle
            failure = verification
        case .downloading(_, let cancelling):
            if cancelling { failure = nil }
            resourcePhase = switch phase {
            case .some(.downloading): .transferring
            case .some(.checking), .some(.verifyingArchive), .some(.verifyingImage): .verifying
            case .some(.extracting), .some(.finalizing), .some(.reconstructing): .installing
            case .none: .transferring
            }
        case .imageRepairRequired(_, let message), .repairRequired(_, let message):
            failure = message
        case .installedStopped, .running, .updateAvailable:
            resourcePhase = .finished
        }
        let transfer = running ? jobs.transfers[runtime.jobID] : nil
        let total = transfer?.totalBytes ?? runtime.sizeBytes
        let ownerFraction = phase == .downloading && transfer?.totalBytes != nil ? fraction : nil
        return SetupResourceReport(
            kind: .localRuntime,
            titleKey: "setup.resource.local_runtime",
            jobSubjectID: running || installed ? runtime.imageID : nil,
            phase: resourcePhase,
            totalBytes: total,
            transferredBytes: transfer?.receivedBytes,
            bytesPerSecond: transfer?.bytesPerSecond,
            ownerFraction: ownerFraction,
            isInstalled: installed,
            wasCancelled: running ? runtime.cancelling : false,
            failureMessage: failure
        )
    }

    /// The Skill Hub jobs the user already started, mirrored exactly. The
    /// owner publishes no byte total for a hub package, so a running row keeps
    /// an indeterminate bar instead of a made-up percentage, and "ready" comes
    /// only from the installer's own installed phase.
    private func skillHubReports(_ skills: SkillsCenter) -> [SetupResourceReport] {
        // Ready is the store's own proof, not the job's last word: a job that
        // reported `.installed` and a skill that is really persisted both count,
        // and neither a failure nor a cancellation ever does.
        let persistedIDs = Set(skills.installed.map(\.id))
        return skills.hubInstallJobs.values.map { job in
            let phase: SetupResourcePhase = switch job.phase {
            case .queued: .queued
            case .preparing, .downloading: .transferring
            case .checking: .verifying
            case .installing: .installing
            case .awaitingScopeApproval: .awaitingConfirmation
            case .installed: .finished
            case .failed, .cancelled: .idle
            }
            var failure: String?
            if job.phase == .failed {
                failure = job.detail ?? "setup.resource.stage.failed"
            }
            return SetupResourceReport(
                kind: .skillHub,
                titleKey: "setup.resource.skill_hub",
                jobSubjectID: job.skillID,
                phase: phase,
                // No owner-side byte total exists for a hub package, so the
                // row stays indeterminate rather than inventing one.
                totalBytes: nil,
                isInstalled: job.phase == .installed || persistedIDs.contains(job.skillID),
                wasCancelled: job.phase == .cancelled,
                failureMessage: failure
            )
        }
        .sorted { $0.jobSubjectID ?? "" < $1.jobSubjectID ?? "" }
    }

    /// The shipped content kind label the updates editor already uses.
    static func contentTitleKey(for kind: SignedContentKind) -> String {
        switch kind {
        case .prompts: "settings.content_updates.kind.prompts"
        case .providers: "settings.content_updates.kind.providers"
        case .models: "settings.content_updates.kind.models"
        case .help: "settings.content_updates.kind.help"
        case .templates: "settings.content_updates.kind.templates"
        }
    }

    /// Mirror the service-owned attempt, never an unrelated global error.
    /// No byte stream exists for content packages, so progress stays indeterminate.
    private func contentReports(_ content: ContentUpdateCenter) -> [SetupResourceReport] {
        let ids = Set(content.available.keys).union(content.installStates.keys)
        return ids.sorted().map { id in
            let item = content.available[id]
            let attempt = content.installStates[id]
            let running = attempt?.running == true
            let installed = content.installed[id]
            let current = item.map { installed?.version == $0.entry.version } ?? (installed != nil)
            var failure = attempt?.failure
            if !running, failure == nil, let item,
               case .blocked(let reason, _) = item.decision {
                failure = Self.contentBlockedText(reason)
            }
            let phase: SetupResourcePhase
            if running {
                phase = attempt?.phase == .fetching ? .transferring : .installing
            } else {
                phase = current ? .finished : .idle
            }
            return SetupResourceReport(
                kind: .contentUpdate,
                titleKey: item.map { Self.contentTitleKey(for: $0.entry.kind) }
                    ?? "settings.content_updates.title",
                jobSubjectID: id,
                phase: phase,
                totalBytes: item.map { Int64($0.entry.size) },
                isInstalled: current && !running,
                wasCancelled: attempt?.wasCancelled == true && !current,
                failureMessage: failure
            )
        }
    }

    /// The same product wording the shipped updates editor already uses.
    static func contentBlockedText(_ reason: ContentUpdateBlockReason) -> String {
        switch reason {
        case .downgrade:
            return FloeL10n.l("settings.content_updates.decision.blocked.downgrade")
        case .sameVersionDifferentContent:
            return FloeL10n.l("settings.content_updates.decision.blocked.same_version")
        case .incompatibleApp:
            return FloeL10n.l("settings.content_updates.decision.blocked.incompatible_app")
        case .missingDependency:
            return FloeL10n.l("settings.content_updates.decision.blocked.missing_dependency")
        case .pinned:
            return FloeL10n.l("settings.content_updates.decision.blocked.pinned")
        case .feedFailure:
            return FloeL10n.l("settings.content_updates.decision.blocked.invalid")
        }
    }
}
