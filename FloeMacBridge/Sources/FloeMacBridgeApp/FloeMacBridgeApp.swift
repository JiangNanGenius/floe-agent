#if os(macOS)
import SwiftUI
import AppKit
import FloeMacBridgeProtocol

@main
struct FloeMacBridgeApp: App {
    @NSApplicationDelegateAdaptor(BridgeApplicationDelegate.self) private var appDelegate
    @StateObject private var model = BridgeAppModel()
    var body: some Scene {
        MenuBarExtra {
            BridgeMenuView(model: model)
        } label: {
            BridgeStatusLabel(model: model)
        }
        Settings {
            BridgeSettingsView(model: model).frame(width: 560, height: 660)
        }
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Floe Bridge") { model.quit() }.keyboardShortcut("q")
            }
        }
    }
}

private struct BridgeStatusLabel: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var model: BridgeAppModel
    var body: some View {
        Label("Floe Bridge", systemImage: "terminal")
            .onAppear { consumeWindowRequest() }
            .onChange(of: model.settingsRequest) { _, _ in consumeWindowRequest() }
    }
    private func consumeWindowRequest() {
        guard let request = model.settingsRequest else { return }
        openSettings(); model.didOpenSettings(request)
    }
}

private struct BridgeMenuView: View {
    @ObservedObject var model: BridgeAppModel
    @ObservedObject private var updates: BridgeUpdaterModel
    init(model: BridgeAppModel) { self.model = model; self.updates = model.updates }
    var body: some View {
        Text("Floe Bridge").font(.headline)
        Text(model.connectionStatus)
        SettingsLink { Text("Settings…") }
        Button("Check for Updates…") { updates.checkForUpdates() }.disabled(!updates.canCheckForUpdates)
        Divider()
        Button("Quit Floe Bridge") { model.quit() }
    }
}

@MainActor
final class BridgeAppModel: ObservableObject {
    @Published var error: String?
    @Published var clients: [(String, String)] = []
    @Published var storage: [String: Int64] = [:]
    @Published var cleanupItems: [BridgeCleanupItem] = []
    @Published var permissions: [String: Bool] = [:]
    @Published private(set) var listenerReady = false
    @Published private(set) var listenerError: String?
    @Published private(set) var settingsRequest: UUID?
    let updates: BridgeUpdaterModel
    private(set) var paths: BridgePaths?
    private var service: BridgeService?
    private var server: BridgeHTTPServer?
    private var applicationLaunched = false
    init() {
        let activity = BridgeUpdateActivity()
        updates = BridgeUpdaterModel(activity: activity)
        BridgeApplicationDelegate.model = self
        do {
            let paths = try BridgePaths(); self.paths = paths
            let service = try BridgeService(paths: paths, updateActivity: activity); self.service = service
            updates.installation.useServiceAdmission(service)
            let server = try BridgeHTTPServer(service: service); self.server = server
            server.start { [weak self] message in
                Task { @MainActor in
                    self?.listenerReady = message == nil; self?.listenerError = message
                    self?.startUpdaterWhenReady()
                }
            }
            Task { [weak self] in
                await service.setConsent { [weak self] id, name, verification in self?.offerConnection(id: id, name: name, verification: verification) }
                await self?.refresh()
            }
        } catch { self.error = error.localizedDescription }
    }
    func applicationDidFinishLaunching() {
        applicationLaunched = true; startUpdaterWhenReady()
    }
    private func startUpdaterWhenReady() {
        // Only the process that owns the loopback listener may update this
        // bridge. A duplicate instance cannot observe another process's jobs.
        if applicationLaunched && listenerReady { updates.start() }
    }
    func offerConnection(id: String, name: String, verification: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Connect Floe to this Mac?")
        alert.informativeText = String(format: String(localized: "%@ will be able to run terminals and use files on this Mac. You can disconnect at any time."), name)
            + "\n\n" + String(localized: "Match this code in Floe:") + "\n" + verification
        alert.addButton(withTitle: String(localized: "Connect"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let allow = alert.runModal() == .alertFirstButtonReturn
        Task { do { try await service?.approve(id, allow: allow); await refresh() } catch { self.error = error.localizedDescription } }
    }
    func refresh() async {
        guard let service else { return }
        clients = await service.pairedClients().sorted { $0.1 < $1.1 }
        do {
            storage = try await service.storage().compactMapValues(\.integer)
            cleanupItems = try await service.cleanupItems()
            permissions = try service.permissions(request: nil).compactMapValues(\.bool)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func revoke(_ id: String) async {
        do { try await service?.revoke(id); await refresh() } catch { self.error = error.localizedDescription }
    }
    func clean(_ category: String) async {
        do { _ = try await service?.cleanup(["category": .string(category)]); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func clean(_ item: BridgeCleanupItem) async {
        var payload: [String: BridgeValue] = ["category": .string(item.category), "id": .string(item.itemID)]
        if let version = item.version { payload["version"] = .string(version) }
        do { _ = try await service?.cleanup(payload); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func open(_ category: String) {
        guard let paths else { return }
        let url = category == "Caches" ? paths.caches : category == "Logs" ? paths.logs : paths.root.appendingPathComponent(category)
        NSWorkspace.shared.open(url)
    }
    func requestPermission(_ capability: String) async {
        do { _ = try service?.permissions(request: capability); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    var connectionStatus: String {
        if let listenerError { return listenerError }
        if let error, service == nil { return error }
        return listenerReady ? String(localized: "Ready to connect") : String(localized: "Starting…")
    }
    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        settingsRequest = UUID()
    }
    func didOpenSettings(_ request: UUID) {
        if settingsRequest == request { settingsRequest = nil }
    }
    func stopListenerForTermination() { server?.stop() }
    func quit() {
        guard let service else { NSApp.terminate(nil); return }
        Task {
            await service.jobs.stopAllAndWait()
            // Quit does not leave hidden workers behind. Save output first;
            // terminate the owning process groups before closing the listener.
            // The application delegate keeps the listener alive if another
            // accepted transfer/operation still prevents termination.
            NSApp.terminate(nil)
        }
    }
}

private struct BridgeSettingsView: View {
    @ObservedObject var model: BridgeAppModel
    @State private var managesStorage = false
    @State private var kimiInstalled = false
    @State private var openingKimiDownload = false
    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Floe Bridge", value: model.connectionStatus)
            }
            Section("Paired Apps") {
                if model.clients.isEmpty { Text("No paired apps").foregroundStyle(.secondary) }
                ForEach(model.clients, id: \.0) { client in
                    HStack { Text(client.1); Spacer(); Button("Disconnect") { Task { await model.revoke(client.0) } } }
                }
            }
            Section("Mac Control") {
                Text("Mac control uses Floe Bridge together with Kimi CU.")
                LabeledContent("Kimi CU", value: kimiInstalled ? String(localized: "Installed") : String(localized: "Not installed"))
                Button("Download Kimi CU") {
                    openingKimiDownload = true
                    Task {
                        let url = (try? await BridgeConfiguration.latestKimiCUDownloadURL()) ?? BridgeConfiguration.kimiCUDocumentationURL
                        NSWorkspace.shared.open(url)
                        openingKimiDownload = false
                    }
                }.disabled(openingKimiDownload)
            }
            BridgeUpdateSettingsView(updates: model.updates)
            Section("Storage") {
                ForEach(["Workspaces", "Tasks", "Skills", "Environments", "Caches", "Logs"], id: \.self) { category in
                    HStack {
                        Text(LocalizedStringKey(category)); Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: model.storage[category] ?? 0, countStyle: .file)).foregroundStyle(.secondary)
                        Button("Show in Finder") { model.open(category) }
                        if category == "Caches" || category == "Logs" {
                            Button("Move to Trash") { Task { await model.clean(category) } }
                        }
                    }
                }
            }
            if !model.cleanupItems.isEmpty {
                Section {
                    Button("Manage Unused Items…") { managesStorage = true }
                }
            }
            Section("Permissions") {
                LabeledContent("Screen Recording", value: model.permissions["screenCapture"] == true ? String(localized: "Allowed") : String(localized: "Not allowed"))
                LabeledContent("Accessibility", value: model.permissions["accessibility"] == true ? String(localized: "Allowed") : String(localized: "Not allowed"))
                if model.permissions["screenCapture"] != true {
                    Button("Allow Screen Recording…") { Task { await model.requestPermission("screenCapture") } }
                }
                if model.permissions["accessibility"] != true {
                    Button("Allow Accessibility…") { Task { await model.requestPermission("accessibility") } }
                }
            }
            if let error = model.listenerError ?? model.error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .task {
            kimiInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "ai.kimi.cu") != nil
            await model.refresh()
        }
        .sheet(isPresented: $managesStorage) {
            VStack(alignment: .leading) {
                HStack { Text("Unused Items").font(.title2.bold()); Spacer(); Button("Done") { managesStorage = false } }.padding()
                List(model.cleanupItems) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.title).lineLimit(2)
                            Text(LocalizedStringKey(item.category)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).foregroundStyle(.secondary)
                        Button("Move to Trash") { Task { await model.clean(item) } }
                    }
                }
            }.frame(minWidth: 520, minHeight: 320)
        }
    }
}
#endif

#if os(macOS)
private struct BridgeUpdateSettingsView: View {
    @ObservedObject var updates: BridgeUpdaterModel
    var body: some View {
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updates.automaticallyChecks }, set: { updates.automaticallyChecks = $0 }))
            Toggle("Automatically download updates", isOn: Binding(
                get: { updates.automaticallyDownloads }, set: { updates.automaticallyDownloads = $0 }))
                .disabled(!updates.allowsAutomaticDownloads)
            Button("Check for Updates…") { updates.checkForUpdates() }.disabled(!updates.canCheckForUpdates)
            if updates.installation.waitingForIdle { Text("Updates will install when current work finishes.") }
            if updates.failed { Text("The update could not finish. You can try again later.").foregroundStyle(.secondary) }
        }
    }
}
#endif
