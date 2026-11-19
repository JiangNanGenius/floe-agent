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
            #if FLOE_UNIFIED_MAC
            UnifiedMacSettingsView(model: model)
            #else
            BridgeSettingsView(model: model).frame(width: 520, height: 560)
            #endif
        }
        .commands {
            #if FLOE_UNIFIED_MAC
            CommandGroup(after: .appSettings) {
                Button("Check for Updates…") { model.updates.checkForUpdates() }
                    .disabled(!model.updates.canCheckForUpdates)
            }
            CommandGroup(after: .windowArrangement) {
                Button(LocalizedStringKey(model.isAgentMode ? "host.menu.openAgent" : "host.bridge.switchToAgent")) { model.openAgentWorkspace() }
                    .disabled(model.isSwitchingMode)
                if model.isAgentMode {
                    Button("host.menu.bridge") { model.requestBridgeMode() }.disabled(model.isSwitchingMode)
                    Button("host.menu.tools") { model.openToolbox() }.disabled(model.isSwitchingMode)
                }
            }
            #endif
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.openSettings() }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .appTermination) {
                #if FLOE_UNIFIED_MAC
                Button("Quit Floe Agent") { model.quit() }.keyboardShortcut("q")
                #else
                Button("Quit Floe Bridge") { model.quit() }.keyboardShortcut("q")
                #endif
            }
        }
    }
}

private struct BridgeStatusLabel: View {
    @ObservedObject var model: BridgeAppModel
    var body: some View {
        BridgeBrandMark(template: true)
            .frame(width: 18, height: 18)
            .accessibilityLabel("Floe Bridge")
            .accessibilityValue(model.connectionStatus)
    }
}

private struct BridgeMenuView: View {
    @ObservedObject var model: BridgeAppModel
    @ObservedObject private var updates: BridgeUpdaterModel
    init(model: BridgeAppModel) { self.model = model; self.updates = model.updates }
    var body: some View {
        Text("Floe Bridge").font(.headline)
        Text(model.connectionStatus)
        #if FLOE_UNIFIED_MAC
        Button(LocalizedStringKey(model.isAgentMode ? "host.menu.openAgent" : "host.bridge.switchToAgent")) { model.openAgentWorkspace() }
            .disabled(model.isSwitchingMode)
        if model.isAgentMode {
            Button("host.menu.tools") { model.openToolbox() }.disabled(model.isSwitchingMode)
        }
        #endif
        Button("Settings…") { model.openSettings(.bridge) }
        Button("Check for Updates…") { updates.checkForUpdates() }.disabled(!updates.canCheckForUpdates)
        Divider()
        #if FLOE_UNIFIED_MAC
        Button("Quit Floe Agent") { model.quit() }
        #else
        Button("Quit Floe Bridge") { model.quit() }
        #endif
    }
}

@MainActor
final class BridgeAppModel: ObservableObject {
    enum SettingsPane: String, CaseIterable { case general, models, images, permissions, bridge }

    @Published var error: String?
    @Published var clients: [(String, String)] = []
    @Published var storage: [String: Int64] = [:]
    @Published var cleanupItems: [BridgeCleanupItem] = []
    @Published var permissions: [String: Bool] = [:]
    @Published private(set) var listenerReady = false
    @Published private(set) var listenerError: String?
    private var settingsWindow: NSWindow?
    private var pendingSettingsPresentation: Task<Void, Never>?
    let updates: BridgeUpdaterModel
    #if FLOE_UNIFIED_MAC
    @Published private(set) var macWorkspace: UnifiedMacWorkspace?
    @Published var settingsPane: SettingsPane = .general
    enum Appearance: String, CaseIterable { case system, light, dark }
    @Published var appearance: Appearance = .system {
        didSet {
            preferences.set(appearance.rawValue, forKey: "floe.mac.appearance")
            applyAppearance()
        }
    }
    @Published private(set) var isSwitchingMode = false
    private enum LaunchMode: String {
        case bridge, agent
        static let preferenceKey = "floe.mac.launchMode"
    }

    @Published private var launchMode: LaunchMode = .bridge
    var isAgentMode: Bool { launchMode == .agent }

    private func rememberMode(_ mode: LaunchMode) {
        guard launchMode != mode else { return }
        preferences.set(mode.rawValue, forKey: LaunchMode.preferenceKey)
        launchMode = mode
    }
    #endif
    private var preferences: UserDefaults {
        #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
        if let smoke { return smoke.preferences }
        #endif
        return .standard
    }
    #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
    private let smoke = UnifiedMacSmoke.configured()
    var smokePort: UInt16? { server?.boundPort }
    var smokeSettingsWindow: NSWindow? { settingsWindow }
    var smokeAgentSettingsSheet: NSWindow? { macWorkspace?.settingsSheet }
    private(set) var smokeSwitchFrame: CGRect?

    func recordSmokeSwitchFrame(_ frame: CGRect) {
        if smoke != nil { smokeSwitchFrame = frame }
    }

    func verifyActiveAgentDefersInstall() -> Bool {
        let activity = updates.installation.activity
        guard activity.activityCount == 1 else { return false }
        if let claimed = activity.reserveInstallationIfIdle() {
            activity.resume(after: claimed)
            return false
        }
        return true
    }
    #endif
    private(set) var paths: BridgePaths?
    private var storeLock: BridgeStoreLock?
    private var service: BridgeService?
    private var server: BridgeHTTPServer?
    private var applicationLaunched = false
    init() {
        let activity = BridgeUpdateActivity()
        updates = BridgeUpdaterModel(activity: activity)
        #if FLOE_UNIFIED_MAC
        launchMode = preferences.string(forKey: LaunchMode.preferenceKey).flatMap(LaunchMode.init(rawValue:)) ?? .bridge
        appearance = preferences.string(forKey: "floe.mac.appearance").flatMap(Appearance.init(rawValue:)) ?? .system
        #endif
        BridgeApplicationDelegate.model = self
        do {
            #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
            let paths = try smoke?.seedLegacyState() ?? BridgePaths()
            #else
            let paths = try BridgePaths()
            #endif
            self.paths = paths
            // The standalone process takes the same cross-process lock as the
            // embedded service. A new Bridge build therefore cannot mutate the
            // same store while another new service owns it. Pre-lock legacy
            // builds are still mutually excluded only by the fixed listener.
            let storeLock = try BridgeStoreLock(root: paths.root)
            self.storeLock = storeLock
            #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
            let service = try BridgeService(paths: paths, updateActivity: activity, signingKey: smoke?.serverKey)
            #else
            let service = try BridgeService(paths: paths, updateActivity: activity)
            #endif
            self.service = service
            updates.installation.useServiceAdmission(service)
            #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
            let server = try BridgeHTTPServer(service: service, port: smoke == nil ? BridgeWire.port : 0)
            self.server = server
            #else
            let server = try BridgeHTTPServer(service: service); self.server = server
            #endif
            server.start { [weak self] message in
                Task { @MainActor in
                    self?.listenerReady = message == nil; self?.listenerError = message
                    self?.startUpdaterWhenReady()
                }
            }
            Task { [weak self] in
                await service.setConsent { [weak self] id, name, verification, attemptID in self?.offerConnection(id: id, name: name, verification: verification, attemptID: attemptID) }
                await self?.refresh()
            }
        } catch { self.error = error.localizedDescription }
    }
    func applicationDidFinishLaunching() {
        // Present after SwiftUI has installed the menu-bar scene and menus.
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated { self?.finishLaunching() }
        }
    }

    private func finishLaunching() {
        #if FLOE_UNIFIED_MAC
        applyAppearance()
        #endif
        #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
        if let smoke {
            presentStartupMode()
            Task { await smoke.exercise(model: self) }
            return
        }
        #endif
        applicationLaunched = true
        startUpdaterWhenReady()
        presentStartupMode()
    }

    private func presentStartupMode() {
        #if FLOE_UNIFIED_MAC
        if isAgentMode {
            showAgentWindow()
            return
        }
        NSApp.setActivationPolicy(.accessory)
        #endif
        if !preferences.bool(forKey: "bridge.setupWindowShown") { openSettings(.bridge) }
    }

    func reopenPreferredWindow() {
        #if FLOE_UNIFIED_MAC
        if isAgentMode {
            showAgentWindow()
            return
        }
        #endif
        openSettings(.bridge)
    }
    private func startUpdaterWhenReady() {
        // Only the process that owns the loopback listener may update this
        // bridge. A duplicate instance cannot observe another process's jobs.
        if applicationLaunched && listenerReady { updates.start() }
    }
    func offerConnection(id: String, name: String, verification: String, attemptID: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Connect Floe to this Mac?")
        alert.informativeText = String(format: String(localized: "%@ will be able to run terminals and use files on this Mac. You can disconnect at any time."), name)
            + "\n\n" + String(localized: "Match this code in Floe:") + "\n" + verification
        alert.addButton(withTitle: String(localized: "Connect"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let allow = alert.runModal() == .alertFirstButtonReturn
        Task {
            do {
                guard let service, try await service.approve(id, attemptID: attemptID, verification: verification, allow: allow) else {
                    self.error = String(localized: "This connection request is no longer current. Please try again.")
                    await refresh()
                    return
                }
                await refresh()
            } catch { self.error = error.localizedDescription }
        }
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
    func openSettings(_ pane: SettingsPane? = nil) {
        // A MenuBarExtra label is not a persistent settings presentation
        // host. Own the window explicitly and present after menu tracking
        // returns, so opening from Finder or the connection URL is reliable.
        pendingSettingsPresentation?.cancel()
        pendingSettingsPresentation = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            pendingSettingsPresentation = nil
            presentSettingsWindow(pane)
        }
    }
    #if FLOE_UNIFIED_MAC
    func openAgentWorkspace() {
        guard !isSwitchingMode else { return }
        if !isAgentMode {
            closeSettingsWindow()
            settingsPane = .general
        }
        rememberMode(.agent)
        showAgentWindow()
    }

    private func showAgentWindow() {
        guard !isSwitchingMode else { return }
        if macWorkspace == nil {
            #if FLOE_MAC_HOST_SMOKE
            macWorkspace = UnifiedMacWorkspace(activity: updates.installation.activity, testSupport: smoke?.root,
                                               preferences: preferences)
            #else
            macWorkspace = UnifiedMacWorkspace(activity: updates.installation.activity, preferences: preferences)
            #endif
        }
        NSApp.setActivationPolicy(.regular)
        macWorkspace?.openAgent(openSettings: { [weak self] in self?.openSettings() },
                                openImageSettings: { [weak self] in self?.openSettings(.images) },
                                openModelSettings: { [weak self] in self?.openSettings(.models) },
                                settingsContent: { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(UnifiedMacSettingsView(model: self))
        })
    }

    private func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func openToolbox(toolID: String? = nil) {
        guard isAgentMode, !isSwitchingMode else { return }
        macWorkspace?.openToolbox(toolID: toolID)
    }

    func requestBridgeMode() {
        Task {
            do { _ = try await switchToBridge() }
            catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "host.mode.switchUnavailable")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    func switchToBridge() async throws -> Bool {
        guard isAgentMode, !isSwitchingMode, let workspace = macWorkspace else { return false }
        let activity = updates.installation.activity
        let transition = try activity.begin(.maintenance)
        isSwitchingMode = true
        defer { isSwitchingMode = false; activity.finish(transition) }
        guard try await workspace.closeForBridgeMode() else { return false }
        rememberMode(.bridge)
        closeSettingsWindow()
        settingsWindow?.contentViewController = nil
        macWorkspace = nil
        NSApp.setActivationPolicy(.accessory)
        openSettings(.bridge)
        return true
    }

    func closeSettingsWindow() {
        pendingSettingsPresentation?.cancel()
        pendingSettingsPresentation = nil
        macWorkspace?.agent?.isSettingsPresented = false
        settingsWindow?.close()
    }
    #endif
    private func presentSettingsWindow(_ pane: SettingsPane?) {
        #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
        let persistsPresentation = smoke == nil
        #else
        let persistsPresentation = true
        #endif
        #if FLOE_UNIFIED_MAC
        if isAgentMode {
            guard !isSwitchingMode else { return }
            if let pane { settingsPane = pane }
            if macWorkspace?.agent?.isSettingsPresented != true { showAgentWindow() }
            macWorkspace?.agent?.isSettingsPresented = true
            return
        }
        #endif
        let window = settingsWindow ?? NSWindow()
        if settingsWindow == nil {
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            if persistsPresentation { window.setFrameAutosaveName("FloeBridgeSettings") }
        }
        if (!window.isVisible && !window.isMiniaturized) || window.contentViewController == nil {
            window.contentViewController = NSHostingController(
                rootView: BridgeSettingsView(model: self).frame(width: 520, height: 560))
        }
        window.title = "Floe Bridge"
        if settingsWindow == nil { window.center() }
        settingsWindow = window
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if window.isVisible { preferences.set(true, forKey: "bridge.setupWindowShown") }
    }
    func stopListenerForTermination() {
        server?.stop()
        #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
        smoke?.cleanup()
        #endif
    }
    func quit() {
        #if FLOE_UNIFIED_MAC
        Task {
            guard !isSwitchingMode else { return }
            if let macWorkspace, !(await macWorkspace.closeToolbox(promptForScannerDraft: true)) { return }
            await service?.jobs.stopAllAndWait()
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        #else
        guard let service else { NSApp.terminate(nil); return }
        Task {
            await service.jobs.stopAllAndWait()
            // Quit does not leave hidden workers behind. Save output first;
            // terminate the owning process groups before closing the listener.
            // The application delegate keeps the listener alive if another
            // accepted transfer/operation still prevents termination.
            NSApp.terminate(nil)
        }
        #endif
    }
}

private struct BridgeBrandMark: View {
    var template = false
    @MainActor private var brandImage: NSImage? {
        guard let url = Bundle.main.url(forResource: template ? "FloeBrand" : "FloeBridgeIcon", withExtension: "png"),
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

#if FLOE_UNIFIED_MAC
private struct UnifiedMacSettingsView: View {
    @ObservedObject var model: BridgeAppModel

    var body: some View {
        if model.isAgentMode, let workspace = model.macWorkspace?.agent {
            VStack(spacing: 0) {
                HStack {
                    Text("mac.settings.title").font(.title3.weight(.semibold))
                    Spacer()
                    Button("Done", action: model.closeSettingsWindow)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(16)
                Divider()
                HStack(spacing: 0) {
                    List(selection: Binding<BridgeAppModel.SettingsPane?>(
                        get: { model.settingsPane },
                        set: { if let pane = $0 { model.settingsPane = pane } }
                    )) {
                        ForEach(BridgeAppModel.SettingsPane.allCases, id: \.self) { pane in
                            Label(pane.title, systemImage: pane.icon).tag(pane)
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(width: 142)
                    Divider()
                    pane(workspace)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 880, height: 585)
            .background(FloeTheme.groupedSurface)
            .accessibilityIdentifier("mac.settings.sheet")
        } else {
            BridgeSettingsView(model: model).frame(width: 520, height: 560)
        }
    }

    @ViewBuilder
    private func pane(_ workspace: HostAgentWorkspace) -> some View {
        switch model.settingsPane {
        case .general:
            HostAgentGeneralSettings(model: model, workspace: workspace)
        case .models:
            MacProviderSettingsView(workspace: workspace)
        case .images:
            if let images = model.macWorkspace?.images {
                MacImageSettingsView(images: images)
            } else {
                ContentUnavailableView("mac.images.unavailable", systemImage: "photo")
            }
        case .permissions:
            HostAgentPermissionsSettings(workspace: workspace)
        case .bridge:
            BridgeSettingsView(model: model)
        }
    }
}

private struct HostAgentGeneralSettings: View {
    @ObservedObject var model: BridgeAppModel
    @ObservedObject var workspace: HostAgentWorkspace

    var body: some View {
        Form {
            Picker("mac.settings.appearance", selection: $model.appearance) {
                Text("mac.settings.appearance.system").tag(BridgeAppModel.Appearance.system)
                Text("mac.settings.appearance.light").tag(BridgeAppModel.Appearance.light)
                Text("mac.settings.appearance.dark").tag(BridgeAppModel.Appearance.dark)
            }
            Picker("mac.settings.defaultMode", selection: $workspace.defaultMode) {
                ForEach(HostAgentMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            Toggle("mac.settings.verifyAnswers", isOn: $workspace.verifyAgentAnswers)
        }
        .formStyle(.grouped)
    }
}

private struct HostAgentPermissionsSettings: View {
    @ObservedObject var workspace: HostAgentWorkspace

    var body: some View {
        Form {
            Section {
                Toggle("mac.settings.workspaceWrites", isOn: $workspace.allowsWorkspaceWrites)
            } footer: {
                Text("mac.settings.workspaceWrites.detail")
            }
        }
        .formStyle(.grouped)
    }
}

private extension BridgeAppModel.SettingsPane {
    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .models: "mac.settings.models"
        case .images: "mac.settings.images"
        case .permissions: "Permissions"
        case .bridge: "host.role.bridge"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .models: "slider.horizontal.3"
        case .images: "photo"
        case .permissions: "hand.raised"
        case .bridge: "link"
        }
    }
}
#endif

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
                #if FLOE_UNIFIED_MAC
                if !model.isAgentMode { switchToAgentButton }
                #endif
            }.padding(.horizontal, 20).padding(.top, 14)
            TabView {
                general.tabItem { Label("General", systemImage: "gearshape") }
                storage.tabItem { Label("Storage", systemImage: "internaldrive") }
                permissions.tabItem { Label("Permissions", systemImage: "hand.raised") }
            }
        }
        #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
        .coordinateSpace(.named("bridgeSettings"))
        #endif
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
    #if FLOE_UNIFIED_MAC
    private var switchToAgentButton: some View {
        Button("host.bridge.switchToAgent") { model.openAgentWorkspace() }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("bridge.switchToAgent")
            #if FLOE_MAC_HOST_SMOKE
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("bridgeSettings")) } action: { model.recordSmokeSwitchFrame($0) }
            #endif
    }
    #endif
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
            if updates.needsRestartAfterFailure {
                Text("The update could not finish. Reopen Floe to resume work.").foregroundStyle(.secondary)
            } else if updates.failed {
                Text("The update could not finish. You can try again later.").foregroundStyle(.secondary)
            }
        }
    }
}
#endif
