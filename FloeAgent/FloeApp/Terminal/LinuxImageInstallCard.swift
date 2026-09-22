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
    @Published private(set) var state: LinuxGuestInstallState = .storageUnavailable
    @Published private(set) var sizeBytes: Int64?
    @Published private(set) var probingSize = true

    private var didProbe = false
    private var environmentIDHint: String?
    private var refreshTask: Task<Void, Never>?

    static let jobPrefix = "linux-image:"
    var jobID: String { Self.jobPrefix + imageID }

    init(imageID: String) {
        self.imageID = imageID
    }

    var running: Bool { jobs.running.contains(jobID) }
    var failed: Bool { jobs.failures.contains(jobID) }
    var fraction: Double? { jobs.fractions[jobID] }
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
    func refresh(environmentIDHint: String? = nil) async {
        self.environmentIDHint = environmentIDHint
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.reload()
        }
        await refreshTask?.value
    }

    private func reload() async {
        let services = FloePlatformServices.shared
        guard services.linuxGuestImageStorageAvailable() else {
            state = .storageUnavailable
            return
        }
        let imageStatus = await services.linuxImageStatus(id: imageID)
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

        var facts = LinuxGuestInstallFacts()
        facts.storageAvailable = true
        facts.imageInstalled = imageStatus?.installed ?? false
        facts.imageVerificationFailure = imageStatus?.verificationFailure
        facts.imageDistributable = imageStatus?.distributable ?? false
        facts.componentUpdateDetail = updateDetail
        facts.guestEnvironmentID = environmentID
        facts.guestRunning = guestStatus?.running ?? false
        facts.guestLastError = guestStatus?.lastError
        facts.guestDiskResizeFailure = guestStatus?.diskResizeFailure
        facts.downloadRunning = running
        facts.downloadFraction = fraction
        facts.downloadCancelling = running && (message?.contains("取消") == true || message?.contains("ancell") == true)
        state = LinuxGuestInstallStateDerivation.state(from: facts)
    }

    // MARK: actions

    func startDownload() {
        // Runs the same shared, cancellable job as automatic first-use
        // preparation; concurrent callers share one download.
        Task {
            do {
                _ = try await FloePlatformServices.shared.prepareLinuxEnvironment(cancellation: CancellationToken())
            } catch {
                // The shared job records the message; the card re-derives
                // needsDownload/retry from it.
            }
            await reload()
        }
        Task { await reload() }
    }

    func cancelDownload() {
        jobs.cancel(id: jobID)
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
                await reload()
                return
            }
            try await FloePlatformServices.shared.activateLinuxGuestWithPreparation(id: id)
        } catch {
            // Keep the honest message visible in the card's repair state.
        }
        await reload()
    }

    func stopGuest(environmentID: String) async {
        await FloePlatformServices.shared.stopLinuxGuest(id: environmentID)
        await reload()
    }
}

/// Renders the authoritative state. Used by both Settings and Terminal; it
/// never shows a download button for an installed or running component.
struct LinuxImageInstallCard: View {
    @ObservedObject var model: LinuxImageInstallModel
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
            Task { await model.refresh() }
            guard !model.running, !model.failed else { return }
            Task { await onInstalled?() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .storageUnavailable:
            Text("environment.backend.image_store_unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .downloading(let fraction, let cancelling):
            if let fraction {
                ProgressView(value: fraction) {
                    Text("environment.backend.image_downloading")
                }
                .font(.caption)
            } else {
                ProgressView("environment.backend.image_downloading")
            }
            Button(role: .cancel) {
                model.cancelDownload()
            } label: {
                Label("action.cancel_task", systemImage: "xmark.circle")
            }
            .font(.caption)
            .disabled(cancelling)
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
