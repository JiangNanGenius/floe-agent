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
            BridgeSettingsView(model: model).frame(width: 520, height: 560)
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
        BridgeBrandMark(template: true)
            .frame(width: 18, height: 18)
            .accessibilityLabel("Floe Bridge")
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

private struct BridgeBrandMark: View {
    var template = false
    @MainActor private var brandImage: NSImage? {
        guard let url = Bundle.main.url(forResource: "FloeBrand", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        // MenuBarExtra consumes the NSImage representation directly. Its
        // intrinsic dimensions must be points, not the source PNG pixels.
        let side: CGFloat = template ? 18 : 36
        image.size = NSSize(width: side, height: side)
        image.isTemplate = template
        return image
    }
    var body: some View {
        if let image = brandImage {
            Image(nsImage: image).renderingMode(template ? .template : .original)
                .resizable().scaledToFit()
        } else { Image(systemName: "terminal") }
    }
}

private struct BridgeSettingsView: View {
    @ObservedObject var model: BridgeAppModel
    @State private var managesStorage = false
    @State private var kimiInstalled = false
    @State private var openingKimiDownload = false
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                BridgeBrandMark().frame(width: 36, height: 36).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Floe Bridge").font(.headline)
                    Text(model.connectionStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 20).padding(.top, 14)
            TabView {
                general.tabItem { Label("General", systemImage: "gearshape") }
                storage.tabItem { Label("Storage", systemImage: "internaldrive") }
                permissions.tabItem { Label("Permissions", systemImage: "hand.raised") }
            }
        }
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
    private var general: some View {
        Form {
            Section("Paired Apps") {
                if model.clients.isEmpty { Text("No paired apps").foregroundStyle(.secondary) }
                ForEach(model.clients, id: \.0) { client in
                    HStack {
                        Text(client.1).lineLimit(1); Spacer()
                        Button("Remove Pairing") { Task { await model.revoke(client.0) } }
                    }
                }
            }
            Section("Mac Control") {
                HStack {
                    Text("Kimi CU"); Spacer()
                    Text(kimiInstalled ? String(localized: "Installed") : String(localized: "Not installed")).foregroundStyle(.secondary)
                    if kimiInstalled {
                        Button("Open") {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "ai.kimi.cu") { NSWorkspace.shared.open(url) }
                        }
                    }
                    Button("Download Kimi CU") {
                        openingKimiDownload = true
                        Task {
                            let url = (try? await BridgeConfiguration.latestKimiCUDownloadURL()) ?? BridgeConfiguration.kimiCUDocumentationURL
                            NSWorkspace.shared.open(url); openingKimiDownload = false
                        }
                    }.disabled(openingKimiDownload)
                }
            }
            BridgeUpdateSettingsView(updates: model.updates)
            if let error = model.listenerError ?? model.error { Text(error).foregroundStyle(.red) }
        }.formStyle(.grouped).controlSize(.small)
    }
    private var storage: some View {
        Form {
            Section {
                ForEach(["Workspaces", "Tasks", "Skills", "Environments", "Caches", "Logs"], id: \.self) { category in
                    HStack {
                        Text(LocalizedStringKey(category)); Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: model.storage[category] ?? 0, countStyle: .file)).foregroundStyle(.secondary)
                        Button { model.open(category) } label: { Image(systemName: "folder") }.help("Show in Finder").accessibilityLabel("Show in Finder")
                        if category == "Caches" || category == "Logs" {
                            Button("Move to Trash") { Task { await model.clean(category) } }
                        }
                    }
                }
                if !model.cleanupItems.isEmpty { Button("Manage Unused Items…") { managesStorage = true } }
            }
        }.formStyle(.grouped).controlSize(.small)
    }
    private var permissions: some View {
        Form {
            Section {
                HStack {
                    Text("Screen Recording"); Spacer()
                    Text(model.permissions["screenCapture"] == true ? String(localized: "Allowed") : String(localized: "Not allowed")).foregroundStyle(.secondary)
                    if model.permissions["screenCapture"] != true { Button("Allow…") { Task { await model.requestPermission("screenCapture") } } }
                }
                HStack {
                    Text("Accessibility"); Spacer()
                    Text(model.permissions["accessibility"] == true ? String(localized: "Allowed") : String(localized: "Not allowed")).foregroundStyle(.secondary)
                    if model.permissions["accessibility"] != true { Button("Allow…") { Task { await model.requestPermission("accessibility") } } }
                }
            }
        }.formStyle(.grouped).controlSize(.small)
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
