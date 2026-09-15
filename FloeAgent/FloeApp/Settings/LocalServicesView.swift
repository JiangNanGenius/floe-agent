// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
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
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(FloeTheme.destructive) }
            }
            if jobs.isEmpty {
                ContentUnavailableView("services.empty", systemImage: "server.rack", description: Text("services.start_hint"))
            }
            ForEach(jobs) { job in
                let invocation = try? JSONDecoder().decode(LocalServiceTool.Arguments.self, from: job.payloadJSON)
                let progress = job.progressJSON.flatMap { try? JSONDecoder().decode(LocalServiceProgress.self, from: $0) }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(invocation?.entry ?? "Local service").font(.headline).lineLimit(2)
                        HStack {
                            Text(invocation?.runtime == "python" ? "Python" : "Node.js")
                            Spacer()
                            Text(state(job, progress: progress))
                        }.font(.subheadline).foregroundStyle(.secondary)
                        if let owner = environment.conversationCenter.conversations.first(where: { $0.id == job.conversationID }) {
                            Label(owner.title, systemImage: "bubble.left").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let failure = job.lastError, !failure.hasPrefix("Stop requested") { Text(failure).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }.padding(.vertical, 4)
                    if !job.state.isTerminal, progress?.previewURL != nil, progress?.state == "running", scenePhase == .active {
                        Button("services.preview", systemImage: "safari") { preview = job }
                    }
                    if let progress, !progress.stdout.isEmpty || !progress.stderr.isEmpty {
                        DisclosureGroup("services.logs") {
                            Text(progress.stdout + (progress.stderr.isEmpty ? "" : "\n" + progress.stderr))
                                .font(.caption.monospaced()).textSelection(.enabled)
                            if progress.truncated { Text("services.logs_truncated").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Button(job.state.isTerminal ? "services.restart" : "services.stop",
                           systemImage: job.state.isTerminal ? "arrow.clockwise" : "stop.circle") {
                        operate(job)
                    }.disabled(busy.contains(job.id) || (!job.state.isTerminal && job.lastError?.hasPrefix("Stop requested") == true))
                }
            }
        }
        .navigationTitle("services.title")
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

    private func state(_ job: BackgroundJob, progress: LocalServiceProgress?) -> LocalizedStringKey {
        if !job.state.isTerminal, progress?.state == "stopping" || job.lastError?.hasPrefix("Stop requested") == true { return "services.stopping" }
        if job.state == .running && progress?.previewURL == nil { return "services.starting" }
        return LocalizedStringKey("services.state.\(job.state.rawValue)")
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

private struct LocalServicePreview: View {
    let job: BackgroundJob
    @StateObject private var browser = BrowserSessionCenter()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            BrowserView(center: browser)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("action.done") { dismiss() } } }
        }
        .task {
            guard let data = job.progressJSON, let progress = try? JSONDecoder().decode(LocalServiceProgress.self, from: data),
                  let url = progress.previewURL else { return }
            browser.bind(to: job.conversationID)
            browser.addressText = url
            browser.navigateFromAddressBar()
        }
        .onDisappear { browser.discard(conversationID: job.conversationID) }
    }
}
#endif
