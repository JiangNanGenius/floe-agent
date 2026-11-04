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
    @Published private(set) var showingConnectionPage = false
    private var visibleConnectionSurfaces: Set<UUID> = []
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
    func setConnectionSurfaceVisible(_ visible: Bool, id: UUID) {
        if visible { visibleConnectionSurfaces.insert(id) }
        else { visibleConnectionSurfaces.remove(id) }
        showingConnectionPage = !visibleConnectionSurfaces.isEmpty
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
                let opened = await UIApplication.shared.open(URL(string: "floe-bridge://connect")!)
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
                        case .disconnected, .ambiguous:
                            // A missing companion needs installation/opening,
                            // not a ninety-second invisible retry loop.
                            if !opened {
                                error = String(localized: "mac.bridge.open_required")
                                return
                            }
                            break // Only idempotent pairing is retried.
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
    var startPairingOnEntry = false
    @ObservedObject private var center = MacBridgeConnectionCenter.shared
    var body: some View {
        Form {
            MacBridgePairingSection(startPairingOnEntry: startPairingOnEntry)
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
        }
        .navigationTitle("mac.bridge.title")
    }
}

/// The same visible connection controls are used by Execution Environment and
/// the detail page. Pairing does not depend on finding a first-launch popup.
struct MacBridgePairingSection: View {
    var startPairingOnEntry = false
    @ObservedObject private var center = MacBridgeConnectionCenter.shared
    @AppStorage("floe.macBridge.preferForNewTasks.v1") private var preferMacForNewTasks = true
    @State private var confirmingForget = false
    @State private var surfaceID = UUID()
    @State private var handledInitialConnection = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Section("mac.bridge.title") {
            LabeledContent("mac.bridge.status", value: center.connected ? center.host : String(localized: "mac.bridge.disconnected"))
            if center.connected {
                Toggle("mac.bridge.prefer_for_new_tasks", isOn: $preferMacForNewTasks)
                Button("mac.bridge.disconnect", role: .destructive) {
                    Task { await center.disconnect() }
                }.disabled(center.connecting)
            } else {
                if center.connecting {
                    HStack { ProgressView(); Text("mac.bridge.confirm_on_mac") }
                    Button("action.cancel") { center.cancelPairing() }
                        .disabled(center.pairingCode != nil)
                } else if center.pairingCode == nil {
                    Button {
                        center.connect()
                    } label: {
                        Label("mac.bridge.connect", systemImage: "link")
                    }
                    .accessibilityIdentifier("mac.bridge.connect")
                }
                if let code = center.pairingCode {
                    Text("mac.bridge.verify_message").foregroundStyle(.secondary)
                    Text(code).font(.title2.monospaced().bold()).textSelection(.enabled)
                        .accessibilityIdentifier("mac.bridge.verificationCode")
                    Button("mac.bridge.verify_match") { center.confirmPairing() }.disabled(center.connecting)
                    Button("action.cancel", role: .cancel) { center.cancelPairing() }.disabled(center.connecting)
                }
                if let url = MacBridgeConnectionCenter.downloadURL {
                    Link(destination: url) {
                        Label("mac.bridge.download", systemImage: "arrow.down.app")
                    }
                } else {
                    Text("mac.bridge.download_pending").foregroundStyle(.secondary)
                }
                if center.hasPairing {
                    Button("mac.bridge.forget", role: .destructive) { confirmingForget = true }
                        .disabled(center.connecting)
                }
                Text("mac.bridge.setup_detail").font(.footnote).foregroundStyle(.secondary)
            }
            if let error = center.error { Text(error).foregroundStyle(.red) }
        }
        .onAppear { center.setConnectionSurfaceVisible(true, id: surfaceID) }
        .onDisappear { center.setConnectionSurfaceVisible(false, id: surfaceID) }
        .task {
            await center.bootstrap()
            guard !Task.isCancelled else { return }
            if startPairingOnEntry && !handledInitialConnection {
                handledInitialConnection = true
                if !center.connected { center.connect() }
            }
        }
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
            MacBridgePairingSection()
        }.navigationTitle("mac.bridge.about")
    }
}

struct MacBridgeRecommendationModifier: ViewModifier {
    var presentationReady: Bool
    var onConnect: () -> Void
    @AppStorage("floe.macBridge.recommendation.dismissed.v1") private var dismissed = false
    @State private var prompt = MacBridgePromptState()
    @State private var bootstrapFinished = false
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var center = MacBridgeConnectionCenter.shared

    private struct Request: Equatable {
        var ready: Bool
        var active: Bool
        var bootstrapped: Bool
        var dismissed: Bool
        var connected: Bool
        var connecting: Bool
        var verification: String?
        var connectionPageVisible: Bool
        var presented: MacBridgePromptState.Prompt?
    }

    private var request: Request {
        Request(ready: presentationReady, active: scenePhase == .active,
                bootstrapped: bootstrapFinished, dismissed: dismissed,
                connected: center.connected, connecting: center.connecting,
                verification: center.pairingCode,
                connectionPageVisible: center.showingConnectionPage,
                presented: prompt.presented)
    }

    private var promptTitle: LocalizedStringKey {
        prompt.presented == .verification ? "mac.bridge.verify_title" : "mac.bridge.recommend.title"
    }

    func body(content: Content) -> some View {
        content.task(id: presentationReady) {
            guard MacBridgeConnectionCenter.isMac, presentationReady, !bootstrapFinished else { return }
            await center.bootstrap()
            guard !Task.isCancelled else { return }
            bootstrapFinished = true
        }
        .task(id: request) {
            // Wait for the previous sheet's dismissal animation. A new launch,
            // route or scene transition cancels this attempt without consuming it.
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            prompt.reconcile(
                platform: .current,
                canPresent: presentationReady && scenePhase == .active && bootstrapFinished && !center.connecting,
                recommendationHandled: dismissed,
                downloadAvailable: MacBridgeConnectionCenter.downloadURL != nil,
                connected: center.connected,
                awaitingVerification: center.pairingCode != nil,
                connectionPageVisible: center.showingConnectionPage
            )
        }
        // One presenter owns both decisions, without competing root alerts
        // for recommendation and verification.
        .alert(promptTitle,
               isPresented: Binding(
                get: { prompt.presented != nil },
                set: { if !$0 { prompt.presentationEnded() } }
               ), presenting: prompt.presented) { presented in
            if presented == .recommendation {
                Button("mac.bridge.download") {
                    dismissed = true
                    if let url = MacBridgeConnectionCenter.downloadURL { UIApplication.shared.open(url) }
                }
                Button("mac.bridge.connect") { dismissed = true; onConnect() }
                Button("action.later", role: .cancel) { dismissed = true }
            } else {
                Button("mac.bridge.verify_match") { center.confirmPairing() }
                    .disabled(center.connecting)
                Button("action.cancel", role: .cancel) { center.cancelPairing() }
                    .disabled(center.connecting)
            }
        } message: { presented in
            if presented == .verification {
                Text("mac.bridge.verify_message") + Text("\n\n" + (center.pairingCode ?? ""))
            } else {
                Text("mac.bridge.introduction")
            }
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
