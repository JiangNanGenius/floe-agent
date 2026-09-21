// FloeApp — Download and Start Linux card for the local terminal.
//
// Shown when the terminal's Linux image is not installed. It reuses the
// existing App-shared image install job (`EnvironmentPackageJobs`, one job
// per pinned image id) and the verified installer; it exposes size, progress,
// cancel and retry, and truthful unavailable/space/digest errors. No
// arbitrary image URL or install script is offered.

import SwiftUI
import FloeExecution

@MainActor
final class LinuxImageInstallModel: ObservableObject {
    let imageID: String
    @Published private(set) var sizeBytes: Int64?
    @Published private(set) var probingSize = true
    @Published private(set) var resumedAfterInstall = false

    private let jobs = EnvironmentPackageJobs.shared
    private var didProbe = false

    static let jobPrefix = "linux-image:"
    var jobID: String { Self.jobPrefix + imageID }

    init(imageID: String) {
        self.imageID = imageID
    }

    func probeOnce() async {
        guard !didProbe else { return }
        didProbe = true
        sizeBytes = await LinuxGuestImageHTTPDownloader.probePinnedArchiveBytes()
        probingSize = false
    }

    var running: Bool { jobs.running.contains(jobID) }
    var failed: Bool { jobs.failures.contains(jobID) }
    var fraction: Double? { jobs.fractions[jobID] }
    var message: String? { jobs.messages[jobID] }

    func start() {
        resumedAfterInstall = false
        let id = imageID
        let jobID = jobID
        jobs.start(id: jobID,
                   title: String(format: String(localized: "environment.backend.image_download_title"), id)) {
            do {
                let installed = try await FloePlatformServices.shared.installLinuxGuestImage(id: id) { received, expected in
                    guard expected > 0 else { return }
                    let fraction = min(1, Double(received) / Double(expected))
                    Task { @MainActor in
                        EnvironmentPackageJobs.shared.reportProgress(id: jobID, fraction: fraction)
                    }
                }
                return String(format: String(localized: "environment.backend.image_installed"), installed)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        }
    }

    func cancel() {
        jobs.cancel(id: jobID)
    }

    /// Marks that the automatic post-install start already ran, so a later
    /// job revision cannot start the shell twice.
    func markResumed() {
        resumedAfterInstall = true
    }
}

struct LinuxImageInstallCard: View {
    @ObservedObject var model: LinuxImageInstallModel
    /// Called once after a successful install so the owner can start Linux.
    var onInstalled: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "terminal.linux.title"), systemImage: "shippingbox")
                .font(.subheadline.weight(.semibold))
            if model.running {
                if let fraction = model.fraction {
                    ProgressView(value: fraction) {
                        Text("environment.backend.image_downloading")
                    }
                    .font(.caption)
                } else {
                    ProgressView("environment.backend.image_downloading")
                }
                Button(role: .cancel) {
                    model.cancel()
                } label: {
                    Label("action.cancel_task", systemImage: "xmark.circle")
                }
                .font(.caption)
            } else {
                if let message = model.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(model.failed ? FloeTheme.destructive : .secondary)
                        .textSelection(.enabled)
                }
                Button {
                    model.start()
                } label: {
                    Label(model.failed
                          ? String(localized: "terminal.linux.retry")
                          : String(localized: "terminal.linux.download_start"),
                          systemImage: model.failed ? "arrow.clockwise" : "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                if model.probingSize {
                    Text("terminal.linux.size_checking").font(.caption2).foregroundStyle(.secondary)
                } else if let size = model.sizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .task {
            await model.probeOnce()
        }
        .onChange(of: EnvironmentPackageJobs.shared.revision) { _, _ in
            guard !model.resumedAfterInstall,
                  !model.running, !model.failed else { return }
            model.markResumed()
            Task { await onInstalled() }
        }
    }
}
