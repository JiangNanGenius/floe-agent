// FloeApp — authoritative Linux component card for Settings and Terminal.
//
// One view model derives `LinuxGuestInstallState` from verified facts
// (image install/digest, per-environment guest runtime, the shared
// cancellable download job) and exposes the download/cancel/start/stop/
// repair actions. A verified installed or running guest can never render
// the download card: the derivation lives in FloeExecution and is unit
// tested there (`LinuxInstallStateDerivationTests`).

import SwiftUI
import FloeExecution
import FloeTools

@MainActor
final class LinuxImageInstallModel: ObservableObject {
    let imageID: String
    @Published private(set) var state: LinuxGuestInstallState = .storageInitializing
    @Published private(set) var sizeBytes: Int64?
    @Published private(set) var probingSize = true
    /// The image-level verification issue, kept so the repair action knows a
    /// re-verify/repair-image sequence is required instead of starting a guest.
    @Published private(set) var imageIssue: LinuxImageVerificationIssue?
    /// Immediate local feedback after a cancel request, until the shared job
    /// task actually unwinds and reports its terminal state.
    @Published private(set) var cancelling = false
    /// True while the explicit re-verify action reads the installed bytes
    /// (which can hash a large disk); the card disables a second tap instead
    /// of silently starting a second full read.
    @Published private(set) var reverifying = false
    /// One-shot success signal for the owner's `onInstalled` continuation:
    /// set only when THIS image's shared job transitioned from running to
    /// finished with a real-file verified status, never for an unrelated job
    /// revision. Consumed exactly once.
    @Published private(set) var completedInstall = false

    private var didProbe = false
    private var environmentIDHint: String?
    private var refreshTask: Task<Void, Never>?
    /// Bumped by every refresh start: a reload that was superseded mid-flight
    /// (a newer refresh, or this task was cancelled) must never publish its
    /// facts over the newer read.
    private var refreshGeneration = 0
    private var completionGate = LinuxGuestInstallCompletionGate()

    static let jobPrefix = "linux-image:"
    var jobID: String { Self.jobPrefix + imageID }

    init(imageID: String) {
        self.imageID = imageID
    }

    var running: Bool { jobs.running.contains(jobID) }
    var failed: Bool { jobs.failures.contains(jobID) }
    var fraction: Double? { jobs.fractions[jobID] }
    /// Live service-reported phase of THIS image's job, nil when no phase was
    /// reported yet. Read live from the shared jobs object so the card does
    /// not need a full state reload to display it.
    var phase: LinuxGuestImageTransferPhase? { jobs.phases[jobID] }
    var message: String? { jobs.messages[jobID] }

    private var jobs: EnvironmentPackageJobs { .shared }

    func probeOnce() async {
        guard !didProbe else { return }
        didProbe = true
        sizeBytes = await LinuxGuestImageHTTPDownloader.probePinnedArchiveBytes()
        probingSize = false
    }

    /// Re-reads every fact and derives the single state. `environmentIDHint`
    /// is the environment the terminal is attached to, if known; the model
    /// otherwise finds the first Linux-backend environment itself.
    ///
    /// An internal refresh (a shared-jobs revision notification) passes no
    /// hint and must NOT forget which environment this card was attached to:
    /// only an explicit hint — a new attachment — updates the identity.
    func refresh(environmentIDHint: String? = nil) async {
        if let environmentIDHint {
            self.environmentIDHint = environmentIDHint
        }
        await beginRefresh().value
    }

    func retryStorage() async {
        await beginRefresh().value
    }

    /// Cancels the previous refresh, bumps the generation and starts the new
    /// read. Awaiting the returned task keeps the owner's ordering contract
    /// (refresh-then-observe) intact.
    @discardableResult
    private func beginRefresh() -> Task<Void, Never> {
        refreshTask?.cancel()
        refreshGeneration += 1
        let generation = refreshGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.reload(generation: generation)
        }
        refreshTask = task
        return task
    }

    /// Consumes the one-shot completion signal. The owner calls this after
    /// its own refresh; a stale/unrelated revision can never trigger it.
    func consumeCompletedInstall() -> Bool {
        guard completedInstall else { return false }
        completedInstall = false
        return true
    }

    private func reload(generation: Int) async {
        // True while this read is still the card's latest request: the image
        // status read observes task cancellation, but the follow-on queries
        // do not; every publication passes this guard so a superseded reload
        // can never overwrite the newer state.
        func isCurrent() -> Bool {
            generation == refreshGeneration && !Task.isCancelled
        }

        let services = FloePlatformServices.shared
        // Loading vs permanent unavailable: try the bounded recoverable init
        // first so a transient assembly-time failure becomes usable.
        if !services.linuxGuestImageStorageAvailable() {
            guard isCurrent() else { return }
            state = .storageInitializing
            let initialized = await services.ensureLinuxImageService()
            guard initialized else {
                guard isCurrent() else { return }
                state = .storageUnavailable
                imageIssue = nil
                return
            }
        }
        // The status read hashes real image bytes when the success
        // fingerprint is stale; without the caller's cancel signal a
        // superseded refresh (every jobs/running change starts a new one)
        // would hold the storage-initializing spinner until the whole disk
        // was read. Cancellation aborts the read and leaves the last
        // published state for the newer refresh to replace; any other read
        // failure settles to the retryable unavailable state instead of the
        // spinner (the service maps real I/O to typed issues, so this is the
        // defensive last net — nonthrowing reload must still publish).
        let imageStatus: LinuxGuestImageInstallationService.ImageStatus?
        do {
            imageStatus = try await services.linuxImageStatus(
                id: imageID, isCancelled: { Task.isCancelled }
            )
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent() else { return }
            state = .storageUnavailable
            imageIssue = nil
            return
        }
        let updateDetail = await services.linuxComponentUpdateNeeded(id: imageID)
        // `??` takes an autoclosure, so the asynchronous lookup has to be
        // awaited into a local value before the fallback is chosen.
        let environmentID: String?
        if let environmentIDHint {
            environmentID = environmentIDHint
        } else {
            environmentID = await services.firstLinuxEnvironmentID()
        }
        let guestStatus = await services.linuxGuestStatus(id: environmentID)

        // Publication guard: the queries above cannot observe cancellation,
        // so a refresh superseded during them must drop its result here
        // instead of publishing stale facts over the newer read.
        guard isCurrent() else { return }

        let runningNow = running
        let failedNow = failed
        // This image's own job success transition: running → finished with
        // the image really verified. A revision for any other job never sets
        // it, and a cancellation or failure never does.
        let verifiedNow = imageStatus?.installed == true && imageStatus?.verificationIssue == nil
        if completionGate.observe(running: runningNow, failed: failedNow, verified: verifiedNow) {
            completedInstall = true
        }

        var facts = LinuxGuestInstallFacts()
        facts.storageAvailable = true
        facts.imageInstalled = imageStatus?.installed ?? false
        facts.imageVerificationIssue = imageStatus?.verificationIssue
        facts.imageDistributable = imageStatus?.distributable ?? false
        facts.componentUpdateDetail = updateDetail
        facts.guestEnvironmentID = environmentID
        facts.guestRunning = guestStatus?.running ?? false
        facts.guestLastError = guestStatus?.lastError
        facts.guestDiskResizeFailure = guestStatus?.diskResizeFailure
        facts.downloadRunning = runningNow
        facts.downloadFraction = fraction
        facts.downloadCancelling = runningNow && (cancelling
            || message?.contains("取消") == true || message?.contains("ancell") == true)
        facts.downloadFailureMessage = failedNow ? message : nil
        imageIssue = imageStatus?.verificationIssue
        state = LinuxGuestInstallStateDerivation.state(from: facts)
        if !runningNow { cancelling = false }
        // The status read settled: any first-preparation pass this read
        // waited on has finished; clear the recovery-stage progress line.
        jobs.reportLinuxStorageStage(nil)
    }

    // MARK: actions

    func startDownload() {
        // Runs the same shared, cancellable job as automatic first-use
        // preparation; concurrent callers share one download.
        cancelling = false
        Task {
            do {
                try await FloePlatformServices.shared.repairLinuxImage(imageID: imageID)
            } catch {
                // The shared job records the failure message; the card's
                // derived state shows it next to the verification reason.
            }
            await refresh()
        }
        Task { await refresh() }
    }

    func cancelDownload() {
        // Immediate feedback, then the real cancellation path: the shared
        // job's owner token and the in-flight install task are both
        // signalled, so the download/extraction/hash stops at its next
        // checkpoint and a partial candidate is never promoted. The reload
        // makes the cancelling state visible without waiting for a revision,
        // which only fires when the job actually ends.
        cancelling = true
        FloePlatformServices.shared.cancelLinuxImagePreparation(imageID: imageID)
        Task { await refresh() }
    }

    func startGuest(environmentID: String?) async {
        do {
            let id: String
            if let environmentID {
                id = environmentID
            } else if let found = await FloePlatformServices.shared.firstLinuxEnvironmentID() {
                id = found
            } else {
                // No Linux environment exists yet; first use still flows
                // through the shared preparation entry.
                _ = try await FloePlatformServices.shared.prepareLinuxEnvironment(cancellation: CancellationToken())
                await refresh()
                return
            }
            try await FloePlatformServices.shared.activateLinuxGuestWithPreparation(id: id)
        } catch {
            // Keep the honest message visible in the card's repair state.
        }
        await refresh()
    }

    func stopGuest(environmentID: String) async {
        await FloePlatformServices.shared.stopLinuxGuest(id: environmentID)
        await refresh()
    }

    /// First recovery step: re-verify the installed image without a download.
    /// A transient file I/O condition may clear; the card then shows the
    /// normal installed state. The flag stays published so the card can show
    /// the check is running instead of accepting a second tap that would
    /// start another full hash of the same bytes.
    func reverifyImage() async {
        reverifying = true
        defer { reverifying = false }
        _ = await FloePlatformServices.shared.reverifyLinuxImage(imageID: imageID)
        await refresh()
    }

    /// Repair that persists: rebuild from verified blobs when possible,
    /// otherwise re-download the pinned image through the safe staged promote.
    /// Runs under the same shared job as a normal download, so it stays
    /// cancellable and coalesced.
    func repairImage() {
        cancelling = false
        Task {
            do {
                try await FloePlatformServices.shared.repairLinuxImage(imageID: imageID)
            } catch {
                // The shared job and the following reload surface the honest
                // message; do not fabricate success.
            }
            await refresh()
        }
    }
}

/// Renders the authoritative state. Used by both Settings and Terminal; it
/// never shows a download button for an installed or running component.
struct LinuxImageInstallCard: View {
    @ObservedObject var model: LinuxImageInstallModel
    /// Observed directly: byte progress and the phase of the shared job live
    /// here, so the card re-renders on every service report instead of only
    /// when a full state reload happens (which previously left the bar frozen
    /// at whatever fraction the last revision carried).
    @ObservedObject private var jobs = EnvironmentPackageJobs.shared
    /// Called once after a successful install so the owner can start Linux.
    var onInstalled: (() async -> Void)? = nil
    /// Whether the card may offer a manual guest start. Settings passes
    /// false: execution prepares and leases the conversation's environment
    /// automatically, so a standalone "Start Linux guest" control there only
    /// suggests the user must boot a VM by hand before running anything.
    /// The Terminal keeps its explicit start affordance.
    var allowsManualStart: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "terminal.linux.title"), systemImage: "shippingbox")
                .font(.subheadline.weight(.semibold))
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .onChange(of: EnvironmentPackageJobs.shared.revision) { _, _ in
            // Refresh first, then continue only when THIS image's own shared
            // job completed with a verified status. An unrelated package job
            // revision (or a stale pre-refresh observation) must not start a
            // guest; cancellation and failure never do.
            Task {
                await model.refresh()
                if model.consumeCompletedInstall() {
                    await onInstalled?()
                }
            }
        }
        .onChange(of: EnvironmentPackageJobs.shared.running) { _, _ in
            // A job can start outside this card (first Linux use auto-prepares
            // through the same shared job). Refresh the derived state on the
            // running transition so the card switches to its downloading
            // presentation immediately; byte updates themselves only need the
            // job object above.
            Task { await model.refresh() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .storageUnavailable:
            Text("environment.backend.image_store_unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await model.retryStorage() }
            } label: {
                Label("environment.backend.retry_init", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .font(.caption)
        case .storageInitializing:
            ProgressView("environment.backend.storage_initializing")
                .font(.caption)
            if let raw = jobs.linuxStorageStage,
               let stage = RuntimeV2Store.RecoveryStage(rawValue: raw) {
                Text(Self.storageStageText(stage))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .downloading(_, let cancelling):
            downloadingContent(cancelling: cancelling || model.cancelling)
        case .needsDownload(let failure):
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(FloeTheme.destructive)
                    .textSelection(.enabled)
            }
            if let message = model.message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(model.failed ? FloeTheme.destructive : .secondary)
                    .textSelection(.enabled)
            }
            Button {
                model.startDownload()
            } label: {
                Label(model.failed
                      ? String(localized: "terminal.linux.retry")
                      : String(localized: "terminal.linux.download_start"),
                      systemImage: model.failed ? "arrow.clockwise" : "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            sizeRow
        case .installedStopped(let environmentID):
            Label("environment.backend.status.installed_stopped", systemImage: "checkmark.seal")
                .font(.caption)
                .foregroundStyle(.secondary)
            if allowsManualStart, let environmentID {
                Button {
                    Task { await model.startGuest(environmentID: environmentID) }
                } label: {
                    Label("environment.backend.start", systemImage: "play")
                }
                .buttonStyle(.bordered)
            }
        case .updateAvailable(let environmentID, let detail):
            Label(detail ?? String(localized: "environment.backend.update_needed"),
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(FloeTheme.pending)
            if allowsManualStart, let environmentID {
                Button {
                    Task { await model.startGuest(environmentID: environmentID) }
                } label: {
                    Label("environment.backend.update_start", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
            }
        case .imageRepairRequired(let transient, let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(FloeTheme.destructive)
                .textSelection(.enabled)
            if transient {
                if model.reverifying {
                    ProgressView("environment.backend.reverify")
                        .font(.caption)
                } else {
                    Button {
                        Task { await model.reverifyImage() }
                    } label: {
                        Label("environment.backend.reverify", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
            }
            Button {
                model.repairImage()
            } label: {
                Label("environment.backend.repair_image", systemImage: "wrench.and.screwdriver")
            }
            .buttonStyle(.bordered)
            .font(.caption)
        case .repairRequired(let environmentID, let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(FloeTheme.destructive)
                .textSelection(.enabled)
            if allowsManualStart, let environmentID {
                Button {
                    Task { await model.startGuest(environmentID: environmentID) }
                } label: {
                    Label("environment.backend.repair", systemImage: "wrench.and.screwdriver")
                }
                .buttonStyle(.bordered)
            }
        case .running:
            // The owner renders the running row (stop action) outside the
            // card; the card itself shows no download/start affordance.
            Label("environment.backend.status.running", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(FloeTheme.success)
        }
    }

    /// Live downloading presentation. The fraction and phase come from the
    /// shared job object (observed above), not from the state snapshot: a
    /// fraction is only shown while the service reports the download phase, so
    /// "100% downloaded" can never stand in for a later verification or
    /// extraction phase. Phase changes clear the fraction in the jobs object,
    /// which is why a stale associated value is intentionally not used here.
    @ViewBuilder
    private func downloadingContent(cancelling: Bool) -> some View {
        let phase = jobs.phases[model.jobID]
        if let phase, phase != .downloading {
            ProgressView()
                .font(.caption)
            Text(Self.phaseText(phase))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let fraction = jobs.fractions[model.jobID] {
            ProgressView(value: fraction) {
                Text("environment.backend.image_downloading")
            }
            .font(.caption)
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            ProgressView("environment.backend.image_downloading")
                .font(.caption)
        }
        Button(role: .cancel) {
            model.cancelDownload()
        } label: {
            Label("action.cancel_task", systemImage: "xmark.circle")
        }
        .font(.caption)
        .disabled(cancelling)
    }

    /// Localized label for the Runtime v2 startup-recovery stage reported by
    /// the shared preparation pass. Each stage has its own catalog entry in
    /// both languages; an unknown raw id falls back to the generic
    /// storage-initializing text instead of rendering a diagnostic id.
    static func storageStageText(_ stage: RuntimeV2Store.RecoveryStage) -> String {
        switch stage {
        case .queue:
            return String(localized: "environment.backend.storage_stage.queue")
        case .leases:
            return String(localized: "environment.backend.storage_stage.leases")
        case .runtimeDirectories:
            return String(localized: "environment.backend.storage_stage.runtime_directories")
        case .preservedQuarantine:
            return String(localized: "environment.backend.storage_stage.preserved_quarantine")
        case .stagedImages:
            return String(localized: "environment.backend.storage_stage.staged_images")
        case .orphanManifests:
            return String(localized: "environment.backend.storage_stage.orphan_manifests")
        case .expandedViews:
            return String(localized: "environment.backend.storage_stage.expanded_views")
        case .templates:
            return String(localized: "environment.backend.storage_stage.templates")
        }
    }

    /// Localized label for the service-owned phase. Each phase has its own
    /// catalog entry in both languages, so only the active app language is
    /// shown (never inline bilingual product text).
    static func phaseText(_ phase: LinuxGuestImageTransferPhase) -> String {
        switch phase {
        case .checking:
            return String(localized: "environment.backend.image_phase.checking")
        case .reconstructing:
            return String(localized: "environment.backend.image_phase.reconstructing")
        case .downloading:
            return String(localized: "environment.backend.image_phase.downloading")
        case .verifyingArchive:
            return String(localized: "environment.backend.image_phase.verifying_archive")
        case .extracting:
            return String(localized: "environment.backend.image_phase.extracting")
        case .verifyingImage:
            return String(localized: "environment.backend.image_phase.verifying_image")
        case .finalizing:
            return String(localized: "environment.backend.image_phase.finalizing")
        }
    }

    @ViewBuilder
    private var sizeRow: some View {
        if model.probingSize {
            Text("terminal.linux.size_checking").font(.caption2).foregroundStyle(.secondary)
        } else if let size = model.sizeBytes {
            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
