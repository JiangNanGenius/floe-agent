// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloePersistence

/// The view observes durable jobs; leaving it never cancels their runners.
struct LocalServicesView: View {
    let environmentID: String
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @State private var jobs: [BackgroundJob] = []
    @State private var error: String?
    @State private var busy: Set<UUID> = []
    @State private var preview: BackgroundJob?

    var body: some View {
        List {
            Section {
                Text("services.description").font(.subheadline).foregroundStyle(.secondary)
            }
            NavigationLink { LinuxPortManagementView(environmentID: environmentID) } label: {
                Label("portforward.title", systemImage: "network")
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(FloeTheme.destructive) }
            }
            if jobs.isEmpty {
                ContentUnavailableView("services.empty", systemImage: "server.rack", description: Text("services.start_hint"))
            }
            ForEach(jobs) { job in
                Section {
                    LocalServiceJobRow(job: job,
                        ownerTitle: environment.conversationCenter.conversations.first(where: { $0.id == job.conversationID })?.title,
                        isBusy: busy.contains(job.id),
                        onPreview: { preview = job }, onOperate: { operate(job) })
                }
            }
        }
        .navigationTitle(FloeL10n.l("services.title"))
        .refreshable { await reload() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await reload()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .sheet(item: $preview) { job in
            LocalServicePreview(job: job)
        }
    }

    @MainActor private func reload() async {
        do {
            jobs = try await BackgroundJobStore(database: environment.database).jobs(environmentID: environmentID, targetTool: "exec.localService")
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func operate(_ job: BackgroundJob) {
        guard let service = environment.backgroundJobService else { return }
        busy.insert(job.id)
        Task {
            defer { busy.remove(job.id) }
            do {
                if job.state.isTerminal { _ = try await service.restartLocalService(id: job.id) }
                else { _ = try await service.cancel(id: job.id) }
                await reload()
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Shared service semantics in Settings and the task-progress inspector.
/// Raw job termination remains available in storage/tool details.
enum LocalServicePresentation {
    static func statusKey(for job: BackgroundJob) -> String {
        switch job.serviceState {
        case .queued: "services.state.queued"
        case .starting: "services.starting"
        case .running: "services.state.running"
        case .stopping: "services.stopping"
        case .stopped: "services.state.cancelled"
        case .ended: "services.state.completed"
        case .failed: "services.state.failed"
        case .interrupted: "services.state.interrupted"
        case nil: "services.state.failed"
        }
    }
}

struct LocalServiceJobRow: View {
    let job: BackgroundJob
    var ownerTitle: String? = nil
    var isBusy = false
    let onPreview: () -> Void
    let onOperate: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let invocation = try? JSONDecoder().decode(LocalServiceTool.Arguments.self, from: job.payloadJSON)
        let progress = job.progressJSON.flatMap { try? JSONDecoder().decode(LocalServiceProgress.self, from: $0) }
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text(invocation?.entry ?? FloeL10n.l("services.title")).font(.headline).lineLimit(2)
                HStack {
                    Text(invocation?.runtime == "python" ? "Python" : (invocation?.runtime == "shell" ? "Shell" : "Node.js"))
                    Spacer()
                    Text(LocalizedStringKey(LocalServicePresentation.statusKey(for: job)))
                }.font(.subheadline).foregroundStyle(.secondary)
                if let ownerTitle {
                    Label(ownerTitle, systemImage: "bubble.left").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if (job.state == .failed || job.state == .interrupted), let failure = job.lastError {
                    Text(failure).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.padding(.vertical, 4)
            if job.servicePreviewURL != nil, scenePhase == .active {
                Button("services.preview", systemImage: "safari", action: onPreview)
                    .accessibilityIdentifier("services.preview.\(job.id.uuidString)")
            }
            if let progress, !progress.stdout.isEmpty || !progress.stderr.isEmpty {
                DisclosureGroup("services.logs") {
                    Text(progress.stdout + (progress.stderr.isEmpty ? "" : "\n" + progress.stderr))
                        .font(.caption.monospaced()).textSelection(.enabled)
                    if progress.truncated { Text("services.logs_truncated").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Button(job.state.isTerminal ? "services.restart" : "services.stop",
                   systemImage: job.state.isTerminal ? "arrow.clockwise" : "stop.circle", action: onOperate)
                .disabled(isBusy || job.serviceState == .stopping)
                .accessibilityIdentifier("services.operate.\(job.id.uuidString)")
        }
        .accessibilityIdentifier("services.row.\(job.id.uuidString)")
    }
}

struct LocalServicePreview: View {
    let job: BackgroundJob
    /// A click-time endpoint resolved by the IDE service terminal. Nil keeps
    /// the existing Settings/local-services behavior of deriving the endpoint
    /// from the durable progress document.
    var resolvedURL: URL? = nil
    @StateObject private var browser = BrowserSessionCenter(durableHandoffs: false, taskHandoffsEnabled: false)
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            BrowserView(center: browser)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("action.done") { dismiss() }
                            .accessibilityIdentifier("workspace.ide.service.preview.done")
                    }
                }
        }
        .task {
            let url: URL?
            if let resolvedURL {
                url = resolvedURL
            } else {
                let progress = job.progressJSON.flatMap {
                    try? JSONDecoder().decode(LocalServiceProgress.self, from: $0)
                }
                url = progress?.previewURL.flatMap { URL(string: $0) }
            }
            guard let url else { return }
            browser.bind(to: job.conversationID)
            browser.addressText = url.absoluteString
            browser.navigateFromAddressBar()
        }
        .onDisappear { browser.discard(conversationID: job.conversationID) }
    }
}
#endif
