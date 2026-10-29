#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import FloeExecution
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
    private var pairingTask: Task<Void, Never>?
    private var availabilityObserver: NSObjectProtocol?
    private init() {
        availabilityObserver = NotificationCenter.default.addObserver(forName: MacBridgeClient.availabilityDidChange, object: nil, queue: .main) { [weak self] notification in
            let connected = notification.userInfo?["connected"] as? Bool ?? false
            Task { @MainActor [weak self] in self?.connected = connected }
        }
    }
    static var isMac: Bool { ProcessInfo.processInfo.isiOSAppOnMac }
    static var downloadURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "FloeMacBridgeDownloadURL") as? String,
              let url = URL(string: text), url.scheme == "https", url.host == "www.floe-agent.com" else { return nil }
        return url
    }
    func bootstrap() async {
        guard Self.isMac else { return }
        do {
            try await MacBridgeClient.shared.bootstrap()
            connected = await MacBridgeClient.shared.isConnected()
            hasPairing = await MacBridgeClient.shared.hasPairing()
            recentJobs = Array((try await MacBridgeClient.shared.savedJobs()).reversed().prefix(20))
            if connected {
                let state = try await MacBridgeClient.shared.call("ping")
                host = state["host"]?.string ?? "Mac"; error = nil
            }
        } catch {
            connected = false
            hasPairing = await MacBridgeClient.shared.hasPairing()
            recentJobs = Array(((try? await MacBridgeClient.shared.savedJobs()) ?? []).reversed().prefix(20))
            self.error = error.localizedDescription
        }
    }
    func connect() {
        guard !connecting, pairingCode == nil, Self.isMac else { return }
        connecting = true; error = nil
        pairingTask = Task {
            defer { connecting = false; pairingTask = nil }
            do {
                // The system opens the user's installed companion. Floe
                // neither downloads code nor silently starts an installer.
                _ = await UIApplication.shared.open(URL(string: "floe-bridge://connect")!)
                for _ in 0..<90 {
                    try Task.checkCancellation()
                    do {
                        if try await MacBridgeClient.shared.beginPairing() {
                            if let verification = try await MacBridgeClient.shared.pairingVerification() {
                                pairingCode = verification
                                return
                            }
                            await finishConnection()
                            return
                        }
                    } catch let failure as BridgeFailure {
                        switch failure {
                        case .disconnected, .ambiguous:
                            // Only the idempotent pairing request waits for the
                            // user-opened app to start. Never retry a command.
                            break
                        default: throw failure
                        }
                    }
                    try await Task.sleep(for: .seconds(1))
                }
                error = String(localized: "mac.bridge.confirm_timeout")
            } catch is CancellationError { }
            catch { connected = false; self.error = error.localizedDescription }
        }
    }
    func cancelPairing() {
        pairingTask?.cancel(); pairingCode = nil
        Task { await MacBridgeClient.shared.cancelPairing() }
    }
    func confirmPairing() {
        guard let verification = pairingCode else { return }
        Task {
            do {
                try await MacBridgeClient.shared.confirmPairing(verification: verification)
                pairingCode = nil
                await finishConnection()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func finishConnection() async {
        do {
            let state = try await MacBridgeClient.shared.call("ping")
            connected = true; hasPairing = true
            MacBridgeRoutingPreferences.preferMacForNewTasks = true
            host = state["host"]?.string ?? "Mac"; error = nil
        } catch { connected = false; self.error = error.localizedDescription }
    }
    func disconnect() async {
        do { try await MacBridgeClient.shared.disconnect(); connected = false; hasPairing = false; host = ""; error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct MacBridgeConnectionView: View {
    @ObservedObject private var center = MacBridgeConnectionCenter.shared
    @AppStorage("floe.macBridge.preferForNewTasks.v1") private var preferMacForNewTasks = true
    var body: some View {
        Form {
            Section {
                LabeledContent("mac.bridge.status", value: center.connected ? center.host : String(localized: "mac.bridge.disconnected"))
                if center.connected {
                    if !preferMacForNewTasks {
                        Button("mac.bridge.prefer_for_new_tasks") { preferMacForNewTasks = true }
                    }
                    Button("mac.bridge.disconnect", role: .destructive) { Task { await center.disconnect() } }
                } else {
                    Button("mac.bridge.connect") { center.connect() }.disabled(center.connecting)
                    if center.connecting {
                        HStack { ProgressView(); Text("mac.bridge.confirm_on_mac") }
                        Button("action.cancel") { center.cancelPairing() }
                    }
                }
            }
            if let code = center.pairingCode {
                Section("mac.bridge.verify_title") {
                    Text(code).font(.title2.monospaced().bold()).textSelection(.enabled)
                    Text("mac.bridge.verify_message")
                    Button("mac.bridge.verify_match") { center.confirmPairing() }
                    Button("action.cancel", role: .cancel) { center.cancelPairing() }
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
        .task { await center.bootstrap() }
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
            get: { center.pairingCode != nil },
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
        if isMacEnvironment && !center.connected {
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
