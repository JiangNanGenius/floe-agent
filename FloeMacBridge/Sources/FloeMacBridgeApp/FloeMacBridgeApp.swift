#if os(macOS)
import SwiftUI
import AppKit
import FloeMacBridgeProtocol

@main
struct FloeMacBridgeApp: App {
    @StateObject private var model = BridgeAppModel()
    var body: some Scene {
        MenuBarExtra("Floe Bridge", systemImage: "terminal") {
            Text("Floe Bridge").font(.headline)
            Text(model.error ?? String(localized: "Ready to connect"))
            Button("Connections and Storage…") { model.openSettings() }
            Divider()
            Button("Quit Floe Bridge") { model.quit() }
        }
        Window("Floe Bridge", id: "settings") {
            BridgeSettingsView(model: model).onOpenURL { url in
                if url.scheme == "floe-bridge", url.host == "connect" { model.openSettings() }
            }
        }
            .defaultSize(width: 540, height: 560)
    }
}

@MainActor
final class BridgeAppModel: ObservableObject {
    @Published var error: String?
    @Published var clients: [(String, String)] = []
    @Published var storage: [String: Int64] = [:]
    @Published var cleanupItems: [BridgeCleanupItem] = []
    @Published var permissions: [String: Bool] = [:]
    private(set) var paths: BridgePaths?
    private var service: BridgeService?
    private var server: BridgeHTTPServer?
    init() {
        do {
            let paths = try BridgePaths(); self.paths = paths
            let service = try BridgeService(paths: paths); self.service = service
            let server = try BridgeHTTPServer(service: service); self.server = server
            server.start { [weak self] message in Task { @MainActor in self?.error = message } }
            Task {
                await service.setConsent { [weak self] id, name, verification in self?.offerConnection(id: id, name: name, verification: verification) }
                await refresh()
            }
        } catch { self.error = error.localizedDescription }
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
            permissions = await service.permissions(request: nil).compactMapValues(\.bool)
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
    func requestPermission(_ capability: String) async { _ = await service?.permissions(request: capability); await refresh() }
    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == "Floe Bridge" }?.makeKeyAndOrderFront(nil)
        // Window scene exists independently of menu visibility.
        if !NSApp.windows.contains(where: { $0.title == "Floe Bridge" }) {
            let view = BridgeSettingsView(model: self)
            let controller = NSWindowController(window: NSWindow(contentViewController: NSHostingController(rootView: view)))
            controller.window?.title = "Floe Bridge"
            controller.window?.setContentSize(NSSize(width: 540, height: 560))
            controller.showWindow(nil)
            retainedWindow = controller
        }
    }
    private var retainedWindow: NSWindowController?
    func quit() {
        guard let service else { server?.stop(); NSApp.terminate(nil); return }
        Task {
            await service.jobs.stopAllAndWait()
            // Quit does not leave hidden workers behind. Save output first;
            // terminate the owning process groups before closing the listener.
            server?.stop(); NSApp.terminate(nil)
        }
    }
}

private struct BridgeSettingsView: View {
    @ObservedObject var model: BridgeAppModel
    @State private var managesStorage = false
    var body: some View {
        Form {
            Section("Connections") {
                if model.clients.isEmpty { Text("No connected apps").foregroundStyle(.secondary) }
                ForEach(model.clients, id: \.0) { client in
                    HStack { Text(client.1); Spacer(); Button("Disconnect") { Task { await model.revoke(client.0) } } }
                }
            }
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
            if let error = model.error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
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
