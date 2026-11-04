#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import FloeExecution
import FloeCore
import FloeMacBridgeProtocol

@MainActor
final class MacBridgeConnectionCenter: ObservableObject {
    static let shared = MacBridgeConnectionCenter()
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var pairingCode: String?
    @Published private(set) var hasPairing = false
    @Published private(set) var recentJobs: [MacBridgeClient.SavedJob] = []
    @Published private(set) var host = ""
    @Published private(set) var error: String?
    @Published var showingConnectionPage = false
    private var operationID = UUID()
    private var cancellingPairing = false
    private var pairingTask: Task<Void, Never>?
    private var availabilityObserver: NSObjectProtocol?
    private init() {
        availabilityObserver = NotificationCenter.default.addObserver(forName: MacBridgeClient.availabilityDidChange, object: nil, queue: .main) { [weak self] notification in
            let connected = notification.userInfo?["connected"] as? Bool ?? false
            Task { @MainActor [weak self] in self?.connected = connected }
        }
    }
    static var isMac: Bool { LocalBridgePlatform.current.supportsMacBridge }
    static var downloadURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "FloeMacBridgeDownloadURL") as? String,
              let url = URL(string: text), url.scheme == "https", url.host == "www.floe-agent.com" else { return nil }
        return url
    }
    func bootstrap() async {
        guard Self.isMac, !connecting, pairingCode == nil else { return }
        let operation = operationID
        do {
            try await MacBridgeClient.shared.bootstrap()
            let available = await MacBridgeClient.shared.isConnected()
            let paired = await MacBridgeClient.shared.hasPairing()
            let jobs = Array((try await MacBridgeClient.shared.savedJobs()).reversed().prefix(20))
            let name: String?
            if available { name = try await MacBridgeClient.shared.call("ping")["host"]?.string }
            else { name = nil }
            guard operationID == operation, !Task.isCancelled else { return }
            connected = available; hasPairing = paired; recentJobs = jobs
            host = name ?? ""; error = nil
        } catch {
            let paired = await MacBridgeClient.shared.hasPairing()
            let jobs = Array(((try? await MacBridgeClient.shared.savedJobs()) ?? []).reversed().prefix(20))
            guard operationID == operation, !Task.isCancelled else { return }
            connected = false; hasPairing = paired; recentJobs = jobs
            self.error = error.localizedDescription
        }
    }
    func connect() {
        guard !connecting, pairingCode == nil, Self.isMac else { return }
        let operation = UUID(); operationID = operation
        connecting = true; error = nil
        pairingTask = Task {
            defer {
                if operationID == operation { connecting = false; pairingTask = nil }
            }
            do {
                _ = await UIApplication.shared.open(URL(string: "floe-bridge://connect")!)
                try checkCurrent(operation)
                let deadline = ContinuousClock.now.advanced(by: .seconds(90))
                for _ in 0..<90 {
                    if ContinuousClock.now >= deadline { break }
                    do {
                        let approved = try await MacBridgeClient.shared.beginPairing()
                        try checkCurrent(operation)
                        if approved {
                            let verification = try await MacBridgeClient.shared.pairingVerification()
                            try checkCurrent(operation)
                            if let verification { pairingCode = verification }
                            else { await finishConnection(operation: operation) }
                            return
                        }
                    } catch let failure as BridgeFailure {
                        try checkCurrent(operation)
                        switch failure {
                        case .disconnected, .ambiguous: break // Only idempotent pairing is retried.
                        default: throw failure
                        }
                    }
                    try await Task.sleep(for: .seconds(1))
                    try checkCurrent(operation)
                }
                error = String(localized: "mac.bridge.confirm_timeout")
            } catch is CancellationError { }
            catch {
                guard operationID == operation else { return }
                connected = false; self.error = error.localizedDescription
            }
        }
    }
    func cancelPairing() {
        guard !cancellingPairing else { return }
        cancellingPairing = true
        let operation = UUID(); operationID = operation
        pairingTask?.cancel(); pairingTask = nil; pairingCode = nil
        // Do not permit a new attempt until the actor has fenced the old one.
        connecting = true
        Task {
            await MacBridgeClient.shared.cancelPairing()
            guard operationID == operation else { return }
            connecting = false; cancellingPairing = false
        }
    }
    func confirmPairing() {
        guard !connecting, let verification = pairingCode else { return }
        let operation = operationID
        connecting = true; error = nil
        pairingTask = Task {
            defer {
                if operationID == operation { connecting = false; pairingTask = nil }
            }
            do {
                try checkCurrent(operation)
                try await MacBridgeClient.shared.confirmPairing(verification: verification)
                try checkCurrent(operation)
                pairingCode = nil
                await finishConnection(operation: operation)
            } catch is CancellationError { }
            catch {
                guard operationID == operation else { return }
                self.error = error.localizedDescription
            }
        }
    }
    private func checkCurrent(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard operationID == operation else { throw CancellationError() }
    }
    private func finishConnection(operation: UUID) async {
        do {
            let state = try await MacBridgeClient.shared.call("ping")
            try checkCurrent(operation)
            connected = true; hasPairing = true
            MacBridgeRoutingPreferences.preferMacForNewTasks = true
            host = state["host"]?.string ?? "Mac"; error = nil
        } catch is CancellationError { }
        catch {
            guard operationID == operation else { return }
            connected = false; self.error = error.localizedDescription
        }
    }
    func disconnect(revoke: Bool = true) async {
        guard !connecting else { return }
        let operation = UUID(); operationID = operation
        pairingTask?.cancel(); pairingTask = nil; pairingCode = nil
        connecting = true
        defer { if operationID == operation { connecting = false } }
        do {
            await MacBridgeClient.shared.cancelPairing()
            try await MacBridgeClient.shared.disconnect(revoke: revoke)
            try checkCurrent(operation)
            connected = false; hasPairing = false; host = ""; error = nil
        } catch {
            guard operationID == operation else { return }
            self.error = error.localizedDescription
        }
    }

}

struct MacBridgeConnectionView: View {
    @ObservedObject private var center = MacBridgeConnectionCenter.shared
    @AppStorage("floe.macBridge.preferForNewTasks.v1") private var preferMacForNewTasks = true
    @State private var confirmingForget = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Form {
            if !center.connected {
                Section("mac.bridge.setup") {
                    Text("mac.bridge.setup_detail")
                    if let url = MacBridgeConnectionCenter.downloadURL {
                        Link(destination: url) {
                            Label("mac.bridge.download", systemImage: "arrow.down.app")
                        }
                    }
                }
            }
            Section {
                LabeledContent("mac.bridge.status", value: center.connected ? center.host : String(localized: "mac.bridge.disconnected"))
                if center.connected {
                    if !preferMacForNewTasks {
                        Button("mac.bridge.prefer_for_new_tasks") { preferMacForNewTasks = true }
                    }
                    Button("mac.bridge.disconnect", role: .destructive) { Task { await center.disconnect() } }.disabled(center.connecting)
                } else {
                    Button("mac.bridge.connect") { center.connect() }.disabled(center.connecting || center.pairingCode != nil)
                    if center.connecting {
                        HStack { ProgressView(); Text("mac.bridge.confirm_on_mac") }
                        Button("action.cancel") { center.cancelPairing() }
                    }
                    if center.hasPairing {
                        Button("mac.bridge.forget", role: .destructive) { confirmingForget = true }
                            .disabled(center.connecting)
                    }
                }
            }
            if let code = center.pairingCode {
                Section("mac.bridge.verify_title") {
                    Text(code).font(.title2.monospaced().bold()).textSelection(.enabled)
                    Text("mac.bridge.verify_message")
                    Button("mac.bridge.verify_match") { center.confirmPairing() }.disabled(center.connecting)
                    Button("action.cancel", role: .cancel) { center.cancelPairing() }.disabled(center.connecting)
                }
            }
            Section {
                NavigationLink("mac.bridge.about") { MacBridgeIntroductionView() }
            }
            if !center.recentJobs.isEmpty {
                Section("mac.bridge.recent_jobs") {
                    ForEach(center.recentJobs) { job in
                        NavigationLink { MacBridgeJobDetails(job: job) } label: {
                            VStack(alignment: .leading) {
                                Text(job.submittedAt, style: .date)
                                Text(job.rootPath).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let error = center.error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("mac.bridge.title")
        .onAppear { center.showingConnectionPage = true }
        .onDisappear { center.showingConnectionPage = false }
        .task { await center.bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await center.bootstrap() } }
        }
        .confirmationDialog("mac.bridge.forget_title", isPresented: $confirmingForget) {
            Button("mac.bridge.forget", role: .destructive) { Task { await center.disconnect(revoke: false) } }
        } message: { Text("mac.bridge.forget_detail") }
    }
}

private struct MacBridgeJobDetails: View {
    let job: MacBridgeClient.SavedJob
    @State private var outputURL: URL?
    @State private var preview = ""
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        Form {
            Section {
                Text(job.submittedAt, style: .date)
                Text(job.rootPath).font(.caption).textSelection(.enabled)
            }
            Section {
                Button("mac.bridge.load_output") { Task { await load() } }.disabled(loading)
                Button("mac.bridge.sync_files") { Task { await syncFiles() } }.disabled(loading)
                if loading { ProgressView() }
                if let outputURL { ShareLink(item: outputURL) }
                if !preview.isEmpty { Text(preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                if let error { Text(error).foregroundStyle(.red) }
            }
        }.navigationTitle("mac.bridge.job_output")
    }
    private func syncFiles() async {
        loading = true; defer { loading = false }
        do { try await MacBridgeClient.shared.synchronizeJobFiles(id: job.id); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do {
            let url = try await MacBridgeClient.shared.saveJobOutput(id: job.id)
            outputURL = url
            let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }
            preview = String(decoding: try reader.read(upToCount: 64 * 1_024) ?? Data(), as: UTF8.self)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct MacBridgeIntroductionView: View {
    var body: some View {
        Form {
            Section {
                Label("mac.bridge.title", systemImage: "terminal")
                Text("mac.bridge.introduction")
            }
            Section {
                if let url = MacBridgeConnectionCenter.downloadURL { Link("mac.bridge.download", destination: url) }
                else { Text("mac.bridge.download_pending").foregroundStyle(.secondary) }
                Button("mac.bridge.connect") { MacBridgeConnectionCenter.shared.connect() }
            }
        }.navigationTitle("mac.bridge.about")
    }
}

struct MacBridgeRecommendationModifier: ViewModifier {
    @AppStorage("floe.macBridge.recommendation.dismissed.v1") private var dismissed = false
    @State private var presented = false
    @ObservedObject private var center = MacBridgeConnectionCenter.shared
    func body(content: Content) -> some View {
        content.task {
            guard MacBridgeConnectionCenter.isMac else { return }
            await center.bootstrap()
            // Do not recommend a download before the release owner has
            // supplied the notarized companion's real official URL.
            if !dismissed && !center.connected && MacBridgeConnectionCenter.downloadURL != nil { presented = true }
        }
        .alert("mac.bridge.recommend.title", isPresented: $presented) {
            Button("mac.bridge.download") {
                dismissed = true
                if let url = MacBridgeConnectionCenter.downloadURL { UIApplication.shared.open(url) }
            }
            Button("mac.bridge.connect") { dismissed = true; center.connect() }
            Button("action.later", role: .cancel) { dismissed = true }
        } message: { Text("mac.bridge.introduction") }
        .alert("mac.bridge.verify_title", isPresented: Binding(
            get: { center.pairingCode != nil && !center.showingConnectionPage },
            set: { _ in /* Explicit buttons resolve the pending trust decision. */ }
        )) {
            Button("mac.bridge.verify_match") { center.confirmPairing() }
            Button("action.cancel", role: .cancel) { center.cancelPairing() }
        } message: {
            Text("mac.bridge.verify_message") + Text("\n\n" + (center.pairingCode ?? ""))
        }
    }
}

/// The caller supplies the already-resolved environment identity. A lost
/// connection changes availability, never the task's backend or run state.
struct MacBridgeDisconnectedBanner: View {
    let isMacEnvironment: Bool
    let onUseBackup: () -> Void
    @ObservedObject private var center = MacBridgeConnectionCenter.shared
    var body: some View {
        if MacBridgeConnectionCenter.isMac && isMacEnvironment && !center.connected {
            HStack {
                Label("mac.bridge.disconnected", systemImage: "cable.connector.slash")
                Spacer()
                Button("mac.bridge.reconnect") { center.connect() }.disabled(center.connecting)
                Button("mac.bridge.use_backup", action: onUseBackup)
            }
            .font(.subheadline)
            .padding(.horizontal).padding(.vertical, 8)
            .background(.regularMaterial)
            .task { await center.bootstrap() }
        }
    }
}
#endif
