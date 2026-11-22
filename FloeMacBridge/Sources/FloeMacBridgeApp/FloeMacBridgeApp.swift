#if os(macOS)
import SwiftUI
import AppKit
import FloeMacBridgeProtocol
#if FLOE_UNIFIED_MAC
import FloeCore
import FloeMacToolbox
#endif

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
            if model.isAgentMode, let workspace = model.macWorkspace {
                MacWorkbenchCommands(workspace: workspace)
            }
            CommandGroup(after: .appSettings) {
                CheckForUpdatesButton(updates: model.updates)
            }
            CommandGroup(after: .windowArrangement) {
                Button(LocalizedStringKey(model.isAgentMode ? "host.menu.openAgent" : "host.bridge.switchToAgent")) { model.openAgentWorkspace() }
                    .disabled(model.isSwitchingMode)
                if model.isAgentMode {
                    Button("host.menu.bridge") { model.requestBridgeMode() }.disabled(model.isSwitchingMode)
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

#if FLOE_UNIFIED_MAC
private struct MacWorkbenchCommands: Commands {
    @ObservedObject var workspace: UnifiedMacWorkspace

    var body: some Commands {
        Self.menu("Tasks", items: taskItems)
        Self.menu("space.title", items: spaceItems)
    }

    // CommandMenu's content initializer is nonisolated. Evaluate workspace
    // state on the main actor before passing the view value to its builder.
    nonisolated private static func menu<Items: View>(_ title: LocalizedStringKey, items: Items) -> CommandMenu<Items> {
        CommandMenu(title) { items }
    }

    @ViewBuilder private var taskItems: some View {
        let availability = workspace.menuAvailability
        Button("workbench.new_task") { workspace.performMenuAction(.newTask) }
            .keyboardShortcut("n")
            .disabled(!availability.newTask)
        Button("mac.workspace.find") { workspace.performMenuAction(.findTask) }
            .keyboardShortcut("f")
            .disabled(!availability.find)
        Button("mac.workspace.findTask") { workspace.performMenuAction(.findTaskTitles) }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!availability.find)
        Divider()
        Button("host.chat.stop") { workspace.performMenuAction(.stopTask) }
            .keyboardShortcut(".")
            .disabled(!availability.stop)
    }

    @ViewBuilder private var spaceItems: some View {
        let availability = workspace.menuAvailability
        Button("mac.workspace.spaceFiles") { workspace.performMenuAction(.openSpace(.files)) }
            .disabled(!availability.openSpace)
        Button("mac.workspace.toolbox") { workspace.performMenuAction(.openSpace(.toolbox)) }
            .disabled(!availability.openSpace)
        Button(MacToolboxText.browser(.current)) { workspace.openBrowserFromMenu() }
            .disabled(!availability.openSpace)
        Divider()
        Button("mac.workspace.toggleFiles") { workspace.performMenuAction(.toggleFiles) }
            .keyboardShortcut("0", modifiers: [.command, .option])
            .disabled(!availability.toggleFiles)
    }
}
#endif

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
            Menu("space.title") {
                Button("mac.workspace.spaceFiles", systemImage: "folder") { model.openSpace(.files) }
                Button("mac.workspace.toolbox", systemImage: "wrench.and.screwdriver") { model.openSpace(.toolbox) }
            }
            .disabled(model.isSwitchingMode)
        }
        #endif
        Button("Settings…") { model.openSettings(.bridge) }
        CheckForUpdatesButton(updates: updates)
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
    enum SettingsPane: String, CaseIterable { case general, models, auxiliary, webSearch, usage, permissions, bridge }

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
    @Published var providerDetail: MediaSettings?
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

    @Published private var launchMode: LaunchMode = .agent
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
    var smokeSettingsFrames: [SettingsPane: CGRect] = [:]
    var smokeSettingsBackFrame: CGRect?
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
        launchMode = preferences.string(forKey: LaunchMode.preferenceKey).flatMap(LaunchMode.init(rawValue:)) ?? .agent
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
    func refreshPermissions(request capability: String? = nil) {
        do {
            if let service { permissions = try service.permissions(request: capability).compactMapValues(\.bool) }
        } catch { self.error = error.localizedDescription }
    }
    var connectionStatus: String {
        if let listenerError { return listenerError }
        if let error, service == nil { return error }
        return listenerReady ? String(localized: "Ready to connect") : String(localized: "Starting…")
    }
    enum MediaSettings { case image, video }

    func openSettings(_ pane: SettingsPane? = nil, media: MediaSettings? = nil) {
        // A MenuBarExtra label is not a persistent settings presentation
        // host. Own the window explicitly and present after menu tracking
        // returns, so opening from Finder or the connection URL is reliable.
        pendingSettingsPresentation?.cancel()
        pendingSettingsPresentation = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            pendingSettingsPresentation = nil
            #if FLOE_UNIFIED_MAC
            if pane != nil { providerDetail = media }
            #endif
            presentSettingsWindow(pane)
        }
    }
    #if FLOE_UNIFIED_MAC
    func openNotifiedTask(_ id: UUID) {
        openAgentWorkspace()
        macWorkspace?.agent?.notificationTaskID = id
    }

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
                                openImageSettings: { [weak self] in self?.openSettings(.models, media: .image) },
                                openVideoSettings: { [weak self] in self?.openSettings(.models, media: .video) },
                                openModelSettings: { [weak self] in self?.openSettings(.models) },
                                openPermissionSettings: { [weak self] in self?.openSettings(.permissions) },
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

    func openSpace(_ page: MacSpacePage) {
        guard isAgentMode, !isSwitchingMode else { return }
        macWorkspace?.openSpace(page)
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
        #if FLOE_UNIFIED_MAC
        macWorkspace?.browser?.flushPageHistory()
        #endif
        #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
        smoke?.cleanup()
        #endif
    }
    func quit() {
        #if FLOE_UNIFIED_MAC
        Task {
            guard !isSwitchingMode else { return }
            if let macWorkspace, !(await macWorkspace.closeToolbox(promptForScannerDraft: true)) { return }
            if let macWorkspace, !(await macWorkspace.closeTaskTerminals()) { return }
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

    @State private var providerEditor = MacProviderEditorState()
    @State private var query = ""

    private var destinations: [BridgeAppModel.SettingsPane] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return BridgeAppModel.SettingsPane.allCases.filter { term.isEmpty || $0.searchTerms.localizedStandardContains(term) }
    }

    @State private var showsCompactDetail = false

    private var presentationSize: CGSize {
        let window = NSApp.windows.first { $0.identifier == UnifiedMacWorkspace.workbenchWindowIdentifier }
        let screen = window?.screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size ?? CGSize(width: 900, height: 640)
        let available = window?.contentView?.bounds.size ?? screen
        return CGSize(width: min(860, max(360, min(available.width, screen.width) - 32)),
                      height: min(600, max(340, min(available.height, screen.height) - 46)))
    }

    var body: some View {
        if model.isAgentMode, let workspace = model.macWorkspace?.agent {
            let size = presentationSize
            GeometryReader { geometry in
                let compact = geometry.size.width < 740
                VStack(spacing: 0) {
                    header(compact: compact)
                    Divider()
                    if compact {
                        if showsCompactDetail {
                            detail(workspace, showsProviderBack: false)
                        } else {
                            navigation(compact: true)
                        }
                    } else {
                        HStack(spacing: 0) {
                            navigation(compact: false)
                                .frame(width: 196)
                            Divider()
                            detail(workspace, showsProviderBack: true)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: size.width, height: size.height)
            .background(FloeTheme.groupedSurface)
            .accessibilityIdentifier("mac.settings.sheet")
            .onAppear { showsCompactDetail = model.settingsPane != .general || model.providerDetail != nil }
            .onReceive(model.$settingsPane.dropFirst()) { selected in
                if !destinations.contains(selected) { query = "" }
                showsCompactDetail = true
            }
        } else {
            BridgeSettingsView(model: model).frame(width: 520, height: 560)
        }
    }

    private func header(compact: Bool) -> some View {
        HStack {
            if compact && showsCompactDetail {
                Button {
                    if model.providerDetail != nil { model.providerDetail = nil }
                    else { showsCompactDetail = false }
                } label: {
                    Label(model.providerDetail == nil ? LocalizedStringKey("more.settings") : "mac.settings.providerModels",
                          systemImage: "chevron.backward")
                        .frame(minHeight: FloeTheme.minimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier(model.providerDetail == nil ? "settings.categories.back" : "settings.providers.back")
                #if FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { model.smokeSettingsBackFrame = $0 })
                #endif
            } else {
                Text("mac.settings.title").font(.headline)
            }
            Spacer()
            Button(action: model.closeSettingsWindow) {
                Text("Done").frame(minWidth: 44, minHeight: FloeTheme.minimumTarget).contentShape(Rectangle())
            }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
    }

    private func select(_ pane: BridgeAppModel.SettingsPane) {
        model.providerDetail = nil
        model.settingsPane = pane
        showsCompactDetail = true
    }

    private func navigation(compact: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("mac.settings.find", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("mac.settings.clearSearch"))
                }
            }
            .padding(.horizontal, 9)
            .frame(minHeight: FloeTheme.minimumTarget)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 5)
            if destinations.isEmpty {
                Text("mac.settings.noMatches")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else {
                List(selection: Binding<BridgeAppModel.SettingsPane?>(
                    get: { compact ? nil : model.settingsPane },
                    set: { if let pane = $0 { select(pane) } }
                )) {
                    ForEach(destinations.filter { $0 != .bridge }, id: \.self) { pane in
                        navigationRow(pane, compact: compact)
                    }
                    if destinations.contains(.bridge) {
                        Section { navigationRow(.bridge, compact: compact) }
                    }
                }
                .listStyle(.sidebar)
                .environment(\.defaultMinListRowHeight, FloeTheme.minimumTarget)
                .accessibilityIdentifier("settings.sections")
            }
        }
    }

    @ViewBuilder
    private func navigationRow(_ pane: BridgeAppModel.SettingsPane, compact: Bool) -> some View {
        let label = HStack(spacing: 10) {
            Image(systemName: pane.icon)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(pane.title).font(.body)
            Spacer(minLength: 0)
            if compact {
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: FloeTheme.minimumTarget)
        .contentShape(Rectangle())
        Group {
            if compact {
                Button { select(pane) } label: { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
        }
        .tag(pane)
        .accessibilityIdentifier("settings.pane." + pane.rawValue)
        #if FLOE_MAC_HOST_SMOKE
        .background(MacWorkbenchButtonFrameReader { model.smokeSettingsFrames[pane] = $0 })
        #endif
    }

    @ViewBuilder
    private func detail(_ workspace: HostAgentWorkspace, showsProviderBack: Bool) -> some View {
        switch model.settingsPane {
        case .general:
            HostAgentGeneralSettings(model: model, workspace: workspace)
        case .models:
            if let role = model.providerDetail {
                VStack(alignment: .leading, spacing: 0) {
                    if showsProviderBack {
                        Button { model.providerDetail = nil } label: {
                            Label("mac.settings.providerModels", systemImage: "chevron.backward")
                                .frame(minHeight: FloeTheme.minimumTarget)
                        .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("settings.providers.back")
                        .padding(.horizontal, 16).padding(.vertical, 4)
                        Divider()
                    }
                    switch role {
                    case .image:
                        if let images = model.macWorkspace?.images {
                            MacImageProviderDetail(workspace: workspace, images: images) {
                                providerEditor.pendingAddRole = .image
                                model.providerDetail = nil
                            }
                        }
                    case .video:
                        if let videos = model.macWorkspace?.videos {
                            MacVideoProviderDetail(workspace: workspace, videos: videos) {
                                providerEditor.pendingAddRole = .video
                                model.providerDetail = nil
                            }
                        }
                    }
                }
            } else {
                MacProviderSettingsView(workspace: workspace, editing: $providerEditor, openMediaSettings: { role in
                    switch role {
                    case .image: model.providerDetail = .image
                    case .video: model.providerDetail = .video
                    default: break
                    }
                })
            }
        case .auxiliary:
            MacAuxiliaryModelsView(workspace: workspace)
        case .usage:
            UsageStatisticsView(loadStatistics: workspace.usageStatistics)
        case .webSearch:
            MacSearchSettingsView(settings: workspace.webSearch)
        case .permissions:
            MacPermissionsSettingsView(workspace: workspace, bridge: model)
        case .bridge:
            BridgeSettingsView(model: model, showsUpdates: false)
        }
    }
}

private struct MacImageProviderDetail: View {
    @ObservedObject var workspace: HostAgentWorkspace
    @ObservedObject var images: MacImageGeneration
    let addProvider: () -> Void

    var body: some View {
        MacMediaAccountSettings(workspace: workspace, role: .image,
                                hasStandaloneConfiguration: images.hasStandaloneConfiguration,
                                selection: { images.providerSelection },
                                bind: images.bindProvider, useStandalone: images.useStandaloneConfiguration,
                                addProvider: addProvider) {
            MacImageSettingsView(images: images)
        }
    }
}

private struct MacVideoProviderDetail: View {
    @ObservedObject var workspace: HostAgentWorkspace
    @ObservedObject var videos: MacVideoGeneration
    let addProvider: () -> Void

    var body: some View {
        MacMediaAccountSettings(workspace: workspace, role: .video,
                                hasStandaloneConfiguration: videos.hasStandaloneConfiguration,
                                selection: { videos.providerSelection },
                                bind: videos.bindProvider, useStandalone: videos.useStandaloneConfiguration,
                                addProvider: addProvider) {
            MacVideoSettingsView(videos: videos)
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
            Picker("mac.settings.runningInput", selection: $workspace.runningInputMode) {
                Text("mac.settings.runningInput.queue").tag(RunningInputMode.queue)
                Text("mac.settings.runningInput.steer").tag(RunningInputMode.steer)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.general.runningInput")
            Toggle("mac.settings.verifyAnswers", isOn: $workspace.verifyAgentAnswers)
            BridgeUpdateSettingsView(updates: model.updates)
        }
        .formStyle(.grouped)
    }
}

private extension BridgeAppModel.SettingsPane {
    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .models: "mac.settings.providerModels"
        case .auxiliary: "mac.aux.title"
        case .usage: "settings.section.usage"
        case .webSearch: "mac.settings.webSearch"
        case .permissions: "Permissions"
        case .bridge: "host.role.bridge"
        }
    }

    var searchTerms: String {
        switch self {
        case .general: "通用 外观 默认模式 排队 引导 答案核验 自动检查更新 General appearance mode queue steer verify software updates"
        case .models: "供应商 服务商 账户 模型 模型配置 密钥 连接 生图 绘图 图片 视频生成 图像 模型 Provider Accounts Models API key endpoints image video generation"
        case .auxiliary: "辅助模型 通用辅助 视觉 推理 审批模型 Auxiliary Models vision reasoning reviewer"
        case .usage: "用量统计 模型 供应商 任务 Usage Statistics Tokens Models Providers"
        case .webSearch: "网页 联网 搜索 供应商 浏览器 Web Search Providers Brave Tavily Volcengine DeepSeek"
        case .permissions: "权限 审批 自动审批 完全访问 命令 执行 屏幕录制 辅助功能 磁盘 Kimi CU Permissions approvals command access disk screen"
        case .bridge: "桥接 配对 更新 存储 Bridge pairing updates storage OTA"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .models: "antenna.radiowaves.left.and.right"
        case .auxiliary: "photo.badge.plus"
        case .usage: "chart.bar"
        case .webSearch: "magnifyingglass"
        case .permissions: "checkmark.shield"
        case .bridge: "server.rack"
        }
    }
}
#endif

private struct BridgeSettingsView: View {
    @ObservedObject var model: BridgeAppModel
    var showsUpdates = true
    @State private var managesStorage = false
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
                MacKimiCompanionRow()
            }
            if showsUpdates { BridgeUpdateSettingsView(updates: model.updates) }
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
                MacSystemPermissionRows(model: model)
            }
        }.formStyle(.grouped).controlSize(.small)
    }
}
#endif

#if os(macOS)
private struct CheckForUpdatesButton: View {
    @ObservedObject var updates: BridgeUpdaterModel

    var body: some View {
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!updates.canCheckForUpdates)
    }
}

private struct BridgeUpdateSettingsView: View {
    @ObservedObject var updates: BridgeUpdaterModel
    var body: some View {
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updates.automaticallyChecks }, set: { updates.automaticallyChecks = $0 }))
                .accessibilityIdentifier("settings.updates.automaticChecks")
                #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { updates.smokeAutomaticChecksFrame = $0 })
                .onDisappear { updates.smokeAutomaticChecksFrame = nil }
                #endif
            if updates.allowsAutomaticDownloads {
                Toggle("Automatically download updates", isOn: Binding(
                    get: { updates.automaticallyDownloads }, set: { updates.automaticallyDownloads = $0 }))
            }
            CheckForUpdatesButton(updates: updates)
            if updates.installation.waitingForIdle { Text("Updates will install when current work finishes.") }
            if updates.needsRestartAfterFailure {
                Text("The update could not finish. Reopen Floe to resume work.").foregroundStyle(.secondary)
            } else if updates.failed {
                Text("The update could not finish. You can try again later.").foregroundStyle(.secondary)
            }
        }
    }
}

struct MacKimiCompanionRow: View {
    @State private var companion: URL?
    @State private var openingDownload = false

    var body: some View {
        HStack {
            Text("Kimi CU")
            Spacer()
            Text(companion == nil ? String(localized: "Not installed") : String(localized: "Installed"))
                .foregroundStyle(.secondary)
            if let companion {
                Button("Open") { NSWorkspace.shared.open(companion) }
            } else {
                Button("Download Kimi CU") {
                    openingDownload = true
                    Task {
                        let url = (try? await BridgeConfiguration.latestKimiCUDownloadURL()) ?? BridgeConfiguration.kimiCUDocumentationURL
                        NSWorkspace.shared.open(url)
                        openingDownload = false
                    }
                }.disabled(openingDownload)
            }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        #if FLOE_UNIFIED_MAC
        companion = MacKimiComputerUse.installedURL()
        #else
        companion = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "ai.kimi.cu")
        #endif
    }
}

struct MacSystemPermissionRows: View {
    @ObservedObject var model: BridgeAppModel

    var body: some View {
        Group {
            row("Screen Recording", capability: "screenCapture")
            row("Accessibility", capability: "accessibility")
        }
        .onAppear { model.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }

    private func row(_ title: LocalizedStringKey, capability: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            let granted = model.permissions[capability] == true
            Text(granted ? String(localized: "Allowed") : String(localized: "Not allowed"))
                .foregroundStyle(.secondary)
            if !granted {
                Button("Allow…") { model.refreshPermissions(request: capability) }
            }
        }
    }
}
#endif
