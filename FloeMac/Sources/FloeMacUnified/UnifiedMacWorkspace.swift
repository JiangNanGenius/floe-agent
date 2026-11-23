// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import FloeCore
import FloeDeviceSync
import FloeLocalModelCatalog
import FloeLocalModels
import FloeMacSelfCore
import FloeMacToolbox
import FloeModels
import FloeSecurity
import FloeTools
import SwiftUI

@MainActor
private final class WorkbenchTerminalAdmission: MacTaskTerminalAdmission {
    private struct Key: Hashable {
        let task: UUID
        let destination: MacTaskTerminalDestination
    }

    private let activity: BridgeUpdateActivity
    weak var workspace: HostAgentWorkspace?
    private var leases: [Key: BridgeUpdateActivity.Lease] = [:]
    private var vncLeases: [UUID: BridgeUpdateActivity.Lease] = [:]
    var isClosing = false

    init(activity: BridgeUpdateActivity) { self.activity = activity }

    func acquire(for destination: MacTaskTerminalDestination, taskID: UUID) async throws {
        let key = Key(task: taskID, destination: destination)
        guard !isClosing, workspace?.isTerminating == false, leases[key] == nil else { throw CocoaError(.userCancelled) }
        leases[key] = try activity.begin(.maintenance)
    }

    func release(for destination: MacTaskTerminalDestination, taskID: UUID) async {
        if let lease = leases.removeValue(forKey: Key(task: taskID, destination: destination)) { activity.finish(lease) }
    }

    func acquireVNC(taskID: UUID) async throws {
        guard !isClosing, workspace?.isTerminating == false, vncLeases[taskID] == nil else {
            throw CocoaError(.userCancelled)
        }
        vncLeases[taskID] = try activity.begin(.maintenance)
    }

    func releaseVNC(taskID: UUID) async {
        if let lease = vncLeases.removeValue(forKey: taskID) { activity.finish(lease) }
    }
}

private final class TaskTerminalFolderAccess {
    let url: URL
    private let scoped: Bool
    init(_ url: URL) { self.url = url; scoped = url.startAccessingSecurityScopedResource() }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

/// Owns the native windows from the same application process as Bridge.
/// The shared activity ledger prevents an installation from racing an
/// admitted conversation or the shutdown of an open toolbox.
@MainActor
final class UnifiedMacWorkspace: NSObject, NSWindowDelegate, ObservableObject {
    static let workbenchWindowIdentifier = NSUserInterfaceItemIdentifier("floe.agent.workbench")

    enum CloseError: LocalizedError {
        case agentBusy, pendingFiles, draftSaveFailed, runtimeCloseFailed

        var errorDescription: String? {
            switch self {
            case .agentBusy: String(localized: "host.mode.agentBusy")
            case .pendingFiles: String(localized: "host.mode.pendingFiles")
            case .draftSaveFailed: String(localized: "host.mode.draftSaveFailed")
            case .runtimeCloseFailed: String(localized: "host.mode.runtimeCloseFailed")
            }
        }
    }

    private let activity: BridgeUpdateActivity
    private let taskTerminals = MacTaskTerminalStore()
    private let taskConnections = MacTaskRemoteConnectionsStore()
    private var remoteCatalog: MacRemoteConnectionsCatalog?
    private var remoteDatabase: MacRemoteDatabase?
    private var terminalFolderAccess: [UUID: TaskTerminalFolderAccess] = [:]
    private let terminalAdmission: WorkbenchTerminalAdmission
    private let testSupport: URL?
    private let preferences: UserDefaults
    private(set) var agent: HostAgentWorkspace?
    private(set) var images: MacImageGeneration?
    private(set) var videos: MacVideoGeneration?
    private(set) var creativeLibrary: MacCreativeLibrary?
    private(set) var managedStorage: MacManagedStorageService?
    private var localModelsContent: ((HostAgentWorkspace) -> AnyView)?
    private var stopLocalModels: (() async -> Void)?
    private var connectorRestore: Task<Void, Never>?
    private var agentWindow: NSWindow?
    struct MenuAvailability: Equatable {
        var openSpace = false
        var newTask = false
        var find = false
        var stop = false
        var toggleFiles = false
    }
    @Published private(set) var menuAvailability = MenuAvailability()
    private var commandObservation: AnyCancellable?
    private var draftStore: MacWorkspaceDraftStore?
    private(set) var temporaryChat: MacTemporaryChatModel?
    private var agentLeases = Set<BridgeUpdateActivity.Lease>()
    private(set) var toolbox: MacToolboxWindowController?
    private var toolboxLease: BridgeUpdateActivity.Lease?
    private var drainingToolbox = false
    /// Workbench browser controller; created with the Agent window so the
    /// isolated sessions outlive individual destinations.
    private(set) var browser: MacBrowserWorkbenchController?

    init(activity: BridgeUpdateActivity, testSupport: URL? = nil, preferences: UserDefaults = .standard) {
        self.activity = activity
        self.terminalAdmission = WorkbenchTerminalAdmission(activity: activity)
        self.testSupport = testSupport
        self.preferences = preferences
        super.init()
    }

    func openAgent(openSettings: @escaping () -> Void, openImageSettings: @escaping () -> Void,
                   openVideoSettings: @escaping () -> Void, openModelSettings: @escaping () -> Void,
                   openPermissionSettings: @escaping () -> Void, settingsContent: @escaping () -> AnyView) {
        if agentWindow == nil {
            guard let root = testSupport ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                                      in: .userDomainMask).first,
                  let namespace = Bundle.main.bundleIdentifier else { return }
            let admitWork: HostAgentWorkspace.AdmitWork = { [weak self] in
                guard let self else { throw CloseError.agentBusy }
                let lease = try activity.begin(.request)
                agentLeases.insert(lease)
                return { [weak self, activity] in
                    self?.agentLeases.remove(lease)
                    activity.finish(lease)
                }
            }
            let workspace = HostAgentWorkspace(supportDirectory: root, namespace: namespace,
                                               useKeychain: testSupport == nil, preferences: preferences,
                                               admitWork: admitWork)
            if testSupport == nil { workspace.taskNotifications = MacTaskNotifications.shared }
            let remoteStorage = MacRemoteDatabase { [weak workspace] in
                guard let workspace else { throw CocoaError(.userCancelled) }
                return try await workspace.remoteDataStores()
            }
            remoteDatabase = remoteStorage
            remoteCatalog = MacRemoteConnectionsCatalog(store: remoteStorage)
            terminalAdmission.workspace = workspace
            workspace.endTaskTerminal = { [weak self] id in
                guard let self else { return true }
                guard await taskConnections.stopAndRemove(taskID: id) else { return false }
                guard await taskTerminals.stopAndRemove(taskID: id) else { return false }
                terminalFolderAccess.removeValue(forKey: id)
                return true
            }
            agent = workspace
            let directory = try? HostAgentDatabase.prepareStorageDirectory(applicationSupport: root, namespace: namespace)
            var storageRoots = MacManagedStorageRoots.standard(bundleIdentifier: namespace)
            storageRoots.managed = directory
            if let testSupport {
                storageRoots.runtime = nil
                storageRoots.caches = nil
                storageRoots.webKit = nil
                storageRoots.scratch = FloeScratch.scratchRoot(temporary: testSupport)
                storageRoots.temporary = testSupport
                storageRoots.allowedBases = [testSupport]
            }
            managedStorage = MacManagedStorageService(roots: storageRoots, hooks: .init(idleProbe: { [activity] _ in
                activity.activityCount == 0
            }))
            if let directory {
                workspace.deviceAttachmentFiles = HostAgentDatabase.DeviceAttachmentFiles(directory: directory)
                let vault = KeychainStore(service: namespace + ".device-sync", synchronizable: false,
                                          accessibility: .afterFirstUnlockThisDeviceOnly)
                let account = "endpoint-identity-v1"
                let identity: DeviceHistoryIdentityStorage
                if testSupport == nil {
                    identity = .init(load: {
                        do { return try vault.read(account: account) }
                        catch KeychainStoreError.itemNotFound { return nil }
                    }, save: { try vault.store(account: account, secret: $0) })
                } else {
                    let fixtureKey = directory.appendingPathComponent("DeviceSync-fixture.key")
                    identity = .init(load: { try? Data(contentsOf: fixtureKey) },
                                     save: { try $0.write(to: fixtureKey, options: .atomic) })
                }
                let sync = DeviceHistorySyncCenter(
                    settingsURL: directory.appendingPathComponent("DeviceSync/settings.json"),
                    identityStorage: identity,
                    source: .init(list: { [weak workspace] shared in
                        await workspace?.deviceHistoryOffers(shared: shared) ?? []
                    }, export: { [weak workspace] id, version in
                        guard let workspace else { throw CocoaError(.userCancelled) }
                        return try await workspace.exportDeviceHistory(id, version: version)
                    }, exportPage: { [weak workspace] id, after, through, version in
                        guard let workspace else { throw CocoaError(.userCancelled) }
                        return try await workspace.exportDeviceHistoryPage(id, after: after, through: through, version: version)
                    }, attachment: { [weak workspace] owner, id, offset, count in
                        guard let workspace else { throw CocoaError(.userCancelled) }
                        return try await workspace.exportDeviceAttachment(owner, id: id, offset: offset, count: count)
                    }),
                    localTasks: { [weak workspace] in workspace?.deviceHistoryOffers() ?? [] },
                    importHistory: { [weak workspace] id, data in
                        guard let workspace else { throw CocoaError(.userCancelled) }
                        return try await workspace.receiveDeviceHistory(id, data)
                    },
                    pagedHistory: .init(cursor: { [weak workspace] peerID, id in
                        guard let workspace else { throw CocoaError(.userCancelled) }
                        return try await workspace.receivedDeviceHistoryCursor(from: peerID, conversationID: id)
                    }, commit: { [weak workspace] peerID, id, data, nextCursor in
                        guard let workspace else { throw CocoaError(.userCancelled) }
                        return try await workspace.receiveDeviceHistory(id, data, from: peerID, nextCursor: nextCursor)
                    }),
                    workspaceHost: .init(resolve: { [weak workspace, weak self] id, receiving in
                        guard let self, let workspace else { throw DeviceHistorySyncError.unavailable }
                        return try await workspace.acquireDeviceWorkspaceRoot(id, receiving: receiving) { [weak self] taskIDs in
                            self?.taskTerminals.hasLiveSession(in: taskIDs) ?? true
                        }
                    }, ledgerDirectory: directory.appendingPathComponent("DeviceSync/WorkspaceLedger", isDirectory: true),
                        canPropagateWorkspaceChanges: true,
                        didImport: { [weak workspace] id in
                            await workspace?.refreshReceivedDeviceWorkspace(id)
                        }),
                    attachmentRestore: .init(pending: { [weak workspace] id in
                        guard let workspace else { throw DeviceHistorySyncError.unavailable }
                        return try await workspace.pendingDeviceAttachments(id)
                    }, restore: { [weak workspace] owner, item, bytes in
                        guard let workspace else { throw DeviceHistorySyncError.unavailable }
                        return try await workspace.restoreDeviceAttachment(owner, item: item, data: bytes)
                    }),
                    requiresAttachmentConsent: true,
                    didImport: { [weak workspace] id in
                        await workspace?.refreshReceivedDeviceHistory(id)
                    }
                )
                workspace.deviceHistorySync = sync
            }
            if let directory, let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                let catalogs = FloeMacOfficialCatalogs(root: directory.appendingPathComponent("ProviderCatalogs", isDirectory: true),
                                                       appVersion: version)
                workspace.officialCatalogs = catalogs
                workspace.webSearch.officialCatalogs = catalogs
                let extensions = directory.appendingPathComponent("WorkbenchTools", isDirectory: true)
                workspace.workbenchSkills = MacWorkbenchSkillsService(
                    catalogSource: MacWorkbenchCatalogSnapshotSource(
                        snapshotURL: extensions.appendingPathComponent("SkillCatalog.json")
                    ),
                    store: MacWorkbenchDatabaseSkills { [weak workspace] in
                        guard let workspace else { throw CocoaError(.userCancelled) }
                        return try await workspace.installedSkillStore()
                    },
                    installationRoot: extensions.appendingPathComponent("Skills", isDirectory: true),
                    appVersion: version,
                    admitWork: admitWork
                )
                workspace.workbenchConnectors = MacWorkbenchConnectorsService(
                    store: MacWorkbenchFileConnectorStore(url: extensions.appendingPathComponent("Connector.json")),
                    registry: ToolRunnerRegistry(),
                    credentials: testSupport == nil
                        ? MacWorkbenchKeychainCredentialStore(keychain: KeychainStore(service: namespace + ".mcp",
                            synchronizable: false, accessibility: .whenUnlockedThisDeviceOnly))
                        : MacWorkbenchMemoryCredentialStore()
                )
                if testSupport == nil, let connectors = workspace.workbenchConnectors {
                    connectorRestore = Task {
                        guard let release = try? admitWork() else { return }
                        defer { release() }
                        await connectors.restore()
                        let enabled = connectors.servers.filter(\.enabled).map(\.id)
                        await withTaskGroup(of: Void.self) { tasks in
                            var pending = enabled.makeIterator()
                            for _ in 0..<min(4, enabled.count) {
                                if let id = pending.next() { tasks.addTask { _ = await connectors.refresh(serverID: id) } }
                            }
                            while await tasks.next() != nil, !Task.isCancelled {
                                if let id = pending.next() { tasks.addTask { _ = await connectors.refresh(serverID: id) } }
                            }
                        }
                    }
                }
                if #available(macOS 15.4, *) {
                    let models = MacLocalModelService(store: LocalModelStore(
                        root: directory.appendingPathComponent("LocalModels", isDirectory: true)
                    ))
                    let settings = MacLocalModelsSettingsModel(service: models, admitWork: admitWork)
                    localModelsContent = { workspace in
                        AnyView(MacOnDeviceModelSettingsPane(model: settings, selectedModelID: workspace.selectedPrimaryModelID,
                            useAsDefault: { [weak workspace] id in workspace?.selectDefaultModel(id) == true },
                            appleAvailability: workspace.appleSystemModelAvailability,
                            appleEnabled: Binding(get: { workspace.appleSystemModelEnabled },
                                                  set: { workspace.setAppleSystemModelEnabled($0) }),
                            refreshingModels: { await models.refreshInstalledModels() }))
                    }
                    stopLocalModels = {
                        models.setHostHooks(nil)
                        await models.unloadForTeardown()
                    }
                    let adapter = models.makeAdapter()
                    let provider = MacLocalModelService.providerProfile
                    let supportsDownloads = settings.runtimeSupport.isSupported
                    models.setHostHooks(.init { [weak workspace] result in
                        guard case .success(let profiles) = result else { return }
                        Task { @MainActor in
                            let availability = await AppleFoundationModelRuntime.shared.availability()
                            let usableProfiles = supportsDownloads ? profiles : profiles.filter {
                                $0.id == AppleFoundationModelIdentity.profileID
                            }
                            workspace?.publishInstalledLocalModels(usableProfiles, provider: provider, adapter: adapter,
                                                                   appleAvailability: availability)
                        }
                    })
                    Task { await models.refreshInstalledModels() }
                }
            }
            let drafts = MacWorkspaceDraftStore(directory: directory?.appendingPathComponent("Drafts", isDirectory: true))
            draftStore = drafts
            let images = directory.map {
                MacImageGeneration(directory: $0.appendingPathComponent("Images", isDirectory: true), namespace: namespace,
                                   useKeychain: testSupport == nil, workspace: workspace, preferences: preferences, admitWork: admitWork)
            }
            workspace.taskImages = images
            self.images = images
            let videos = directory.map {
                MacVideoGeneration(directory: $0.appendingPathComponent("Videos", isDirectory: true), namespace: namespace,
                                   useKeychain: testSupport == nil, workspace: workspace, preferences: preferences, admitWork: admitWork)
            }
            let library = directory.map {
                MacCreativeLibrary(directory: $0.appendingPathComponent("Canvases", isDirectory: true), preferences: preferences, admitWork: admitWork)
            }
            workspace.taskVideos = videos
            self.videos = videos
            self.creativeLibrary = library
            videos?.resume()
            drafts.adoptLegacyHomeDraft(for: workspace.uncommittedDraftID)
            workspace.loadAttachmentDraft = { [weak drafts] in drafts?.attachments(for: $0) ?? [] }
            workspace.saveAttachmentDraft = { [weak drafts] id, attachments in drafts?.setAttachments(attachments, for: id) }
            // Page-restore records persist per surviving task; the snapshot
            // closure is consulted lazily (never at browser-controller init,
            // before the workspace task list is prepared).
            let browser = MacBrowserWorkbenchController(
                storeDirectory: directory?.appendingPathComponent("Browser", isDirectory: true),
                survivingOwnerIDs: { [weak workspace, weak drafts] in
                    guard let workspace, workspace.isReady else { return Set() }
                    var ids = Set(workspace.conversations.map(\.id))
                    ids.insert(workspace.uncommittedDraftID)
                    if let drafts {
                        ids.formUnion(drafts.uncommittedDrafts(excluding: ids).map(\.id))
                    }
                    return ids
                },
                admitWork: admitWork
            )
            if browser.taskTools.siteMemory == nil {
                browser.taskTools.siteMemory = MacSiteMemoryRegistry(
                    directory: directory?.appendingPathComponent("Browser/SiteMemory", isDirectory: true)
                )
            }
            self.browser = browser
            workspace.makeTaskBrowserTools = { [weak browser] owner, root in
                browser?.taskTools.makeToolBundle(conversationID: owner, workspaceRoot: root) ?? []
            }
            workspace.endTaskBrowserRun = { [weak browser] run in browser?.taskTools.finishRun(run) }
            let temporary = MacTemporaryChatModel()
            temporaryChat = temporary
            let host = NSHostingController(rootView: MacWorkspaceRootView(
                workspace: workspace, openSettings: openSettings,
                openModelSettings: openModelSettings, openPermissionSettings: openPermissionSettings,
                openToolbox: { [weak self] toolID in self?.openToolbox(toolID: toolID) },
                openTerminal: { [weak self] id, record in try self?.terminalOwner(for: id, record: record) },
                openConnections: { [weak self] terminal in self?.connections(for: terminal) },
                settingsContent: settingsContent,
                imageContent: { attach in
                    if let images {
                        return AnyView(MacImageWorkbenchView(images: images, openSettings: openImageSettings,
                                                             attachToTask: attach))
                    }
                    return AnyView(ContentUnavailableView("mac.images.unavailable", systemImage: "photo"))
                },
                creativeContent: { saveToTask in
                    guard let library, let videos, let images else {
                        return AnyView(ContentUnavailableView("mac.creative.error", systemImage: "externaldrive.badge.exclamationmark"))
                    }
                    return AnyView(MacCreativeWorkbenchView(library: library, images: images, videos: videos,
                                                            imageSettings: openImageSettings, videoSettings: openVideoSettings,
                                                            saveToTask: saveToTask))
                },
                remembersFileRoot: testSupport == nil, draftStore: drafts, browserWorkbench: browser, temporaryChat: temporary
            ))
            // The split-view header reserves the traffic lights itself; a second
            // host titlebar inset would leave an empty row above both columns.
            host.safeAreaRegions = []
            let window = NSWindow(contentViewController: host)
            window.identifier = Self.workbenchWindowIdentifier
            window.title = String(localized: "host.role.agent")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.setContentSize(NSSize(width: 1150, height: 750))
            window.contentMinSize = NSSize(width: 720, height: 480)
            if testSupport == nil {
                let frameName = "FloeMacUnifiedAgent"
                if !window.setFrameUsingName(frameName) { window.center() }
                window.setFrameAutosaveName(frameName)
            } else {
                window.center()
            }
            window.isReleasedWhenClosed = false
            agentWindow = window
            window.delegate = self
            commandObservation = workspace.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.refreshMenuAvailability()
            }
        }
        agentWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshMenuAvailability()
    }

    private var workbenchHasModalPresentation: Bool {
        agent?.isSettingsPresented == true || agentWindow?.attachedSheet != nil
            || NSApp.modalWindow != nil || NSApp.keyWindow?.sheetParent != nil
    }

    private var currentMenuAvailability: MenuAvailability {
        guard let agent, let window = agentWindow, !agent.isTerminating,
              !workbenchHasModalPresentation else { return .init() }
        let key = window === NSApp.keyWindow && window.isKeyWindow
        return .init(openSpace: true, newTask: agent.isReady && !agent.isAcceptingPlan,
                     find: key, stop: key && agent.canStop, toggleFiles: key && agent.windowShowsTask)
    }

    private func refreshMenuAvailability() {
        // AppKit owns the modal input lock. Keep the last window menu state
        // during a sheet transition; dispatch still checks the live window.
        guard !workbenchHasModalPresentation else { return }
        let latest = currentMenuAvailability
        if latest != menuAvailability { menuAvailability = latest }
    }

    func performMenuAction(_ action: HostAgentWorkspace.WindowAction) {
        guard let agent, let window = agentWindow else { return }
        let allowed = currentMenuAvailability
        switch action {
        case .newTask:
            guard allowed.newTask else { return }
            window.makeKeyAndOrderFront(nil)
        case .findTask, .findTaskTitles:
            guard allowed.find else { return }
        case .stopTask:
            guard allowed.stop else { return }
        case .toggleFiles:
            guard allowed.toggleFiles else { return }
        case .openSpace(let page):
            guard allowed.openSpace else { return }
            openSpace(page)
            return
        }
        agent.windowCommand = .init(action: action)
    }

    func openBrowserFromMenu() {
        guard currentMenuAvailability.openSpace else { return }
        browser?.present()
        agentWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidBecomeKey(_ notification: Notification) { refreshMenuAvailability() }

    func localModelsSettings(for workspace: HostAgentWorkspace) -> AnyView {
        localModelsContent?(workspace) ?? AnyView(ContentUnavailableView("mac.localModels.unavailable", systemImage: "cpu"))
    }

    func windowDidResignKey(_ notification: Notification) {
        // AppKit assigns the next key window after the resign callback.
        DispatchQueue.main.async { [weak self] in self?.refreshMenuAvailability() }
    }

    func windowDidEndSheet(_ notification: Notification) {
        guard notification.object as? NSWindow === agentWindow else { return }
        DispatchQueue.main.async { [weak self] in self?.refreshMenuAvailability() }
    }

    #if FLOE_MAC_HOST_SMOKE
    var settingsSheet: NSWindow? { agentWindow?.attachedSheet }
    var smokeDraftStore: MacWorkspaceDraftStore? { draftStore }

    func smokeTerminalOwner(for id: UUID, record: WorkspaceRecord) throws -> MacTaskTerminalOwner {
        try terminalOwner(for: id, record: record)
    }
    #endif

    func closeForBridgeMode() async throws -> Bool {
        connectorRestore?.cancel()
        await connectorRestore?.value
        connectorRestore = nil
        if agent?.voiceSession.isActive == true { agent?.voiceSession.stop() }
        guard let agent, agentLeases.isEmpty, agent.beginTermination() else { throw CloseError.agentBusy }
        defer { if self.agent != nil { agent.cancelTermination() } }
        guard !agent.hasPendingWorkspaceFileChanges else { throw CloseError.pendingFiles }
        draftStore?.flushBeforeClosing()
        guard draftStore?.saveFailed != true else { throw CloseError.draftSaveFailed }
        agent.cancelModelDiscovery()
        guard await closeToolbox(promptForScannerDraft: true) else { return false }
        guard await closeTaskTerminals() else { throw CloseError.agentBusy }
        await agent.deviceHistorySync?.pause()
        await agent.workbenchConnectors?.disconnect()
        do { try await agent.finishTermination() }
        catch { throw CloseError.runtimeCloseFailed }
        await stopLocalModels?()
        stopLocalModels = nil
        localModelsContent = nil
        agent.isSettingsPresented = false
        if let sheet = agentWindow?.attachedSheet { agentWindow?.endSheet(sheet) }
        commandObservation = nil
        menuAvailability = .init()
        agentWindow?.close()
        agentWindow?.contentViewController = nil
        agentWindow = nil
        draftStore = nil
        images = nil
        videos = nil
        creativeLibrary = nil
        managedStorage = nil
        temporaryChat?.discard()
        temporaryChat = nil
        browser?.reset()
        browser?.taskTools.siteMemory?.flush()
        browser = nil
        remoteCatalog = nil
        remoteDatabase = nil
        self.agent = nil
        return true
    }

    private func terminalOwner(for id: UUID, record: WorkspaceRecord) throws -> MacTaskTerminalOwner {
        let url: URL
        if record.kind == .privateTask {
            url = try MacAgentWorkspaceTools.resolvePrivateTaskRoot(record, base: agent?.personalTaskLeaseBase)
        } else {
            var stale = false
            url = try URL(resolvingBookmarkData: record.rootBookmark,
                          options: [.withSecurityScope, .withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw CocoaError(.fileReadNoPermission) }
        }
        let access = TaskTerminalFolderAccess(url)
        let owner = try taskTerminals.owner(taskID: id, workspaceURL: access.url)
        owner.admission = terminalAdmission
        terminalFolderAccess[id] = access
        return owner
    }

    func closeTaskTerminals() async -> Bool {
        terminalAdmission.isClosing = true
        defer { terminalAdmission.isClosing = false }
        guard await taskConnections.stopAll() else { return false }
        let closed = await taskTerminals.stopAll()
        let remaining = Set(taskTerminals.activeTaskIDs)
        terminalFolderAccess = terminalFolderAccess.filter { remaining.contains($0.key) }
        return closed
    }

    private func connections(for terminal: MacTaskTerminalOwner) -> MacTaskConnectionPresentation? {
        guard let remoteCatalog, let remoteDatabase, agent?.isTerminating == false else { return nil }
        let owner = taskConnections.owner(taskID: terminal.taskID, terminalOwner: terminal,
                                          catalog: remoteCatalog, registry: remoteDatabase)
        guard owner.terminalOwner === terminal else { return nil }
        if owner.vncAdmission == nil {
            owner.vncAdmission = .init(acquire: { [terminalAdmission] id in
                try await terminalAdmission.acquireVNC(taskID: id)
            }, release: { [terminalAdmission] id in
                await terminalAdmission.releaseVNC(taskID: id)
            })
        }
        return .init(owner: owner, catalog: remoteCatalog)
    }

    func openSpace(_ page: MacSpacePage) {
        guard let agent, !agent.isTerminating else { return }
        agent.windowCommand = .init(action: .openSpace(page))
        agentWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openToolbox(toolID: String?) {
        guard agent?.isTerminating == false, !drainingToolbox else { return }
        guard let toolID else {
            openSpace(.toolbox)
            return
        }
        guard MacToolboxCatalog.isAvailable(toolID: toolID) else { return }
        if toolbox == nil {
            guard let lease = try? activity.begin(.maintenance) else { return }
            let storage = testSupport?.appendingPathComponent("Toolbox", isDirectory: true)
            let services = MacToolboxServices(storageRoot: storage, mediaEnvironment: .init())
            let controller = MacToolboxWindowController(services: services, autosavesFrame: testSupport == nil,
                                                        preferences: preferences)
            controller.window?.delegate = self
            toolbox = controller
            toolboxLease = lease
        }
        toolbox?.present(toolID: toolID)
    }

    func closeToolbox(promptForScannerDraft: Bool = false) async -> Bool {
        guard let toolbox else { return true }
        guard let lease = toolboxLease, !drainingToolbox else { return false }
        drainingToolbox = true
        defer { drainingToolbox = false }
        let services = toolbox.services
        services.closeAdmissionsForTermination()
        guard await services.drainNonScannerForTermination() else {
            services.resumeAfterCancelledTermination()
            if promptForScannerDraft { showToolboxCloseError("host.toolboxHistorySaveFailed") }
            return false
        }
        let outcome = await MacScannerQuitDecision.resolve(
            status: { await services.scannerTerminationStatus() },
            choose: { promptForScannerDraft ? self.askAboutScannerDraft() : .cancel },
            discard: { await services.discardScannerDraftForTermination() }
        )
        guard outcome == .ready else {
            services.resumeAfterCancelledTermination()
            if outcome == .review { toolbox.present(toolID: "scanner") }
            if outcome == .pending, promptForScannerDraft { showToolboxCloseError("host.scanner.quitPending") }
            return false
        }
        guard await services.drainCameraForTermination() else {
            services.resumeAfterCancelledTermination()
            if promptForScannerDraft { showToolboxCloseError("host.toolboxCameraStopFailed") }
            return false
        }
        services.shutdown()
        toolbox.window?.delegate = nil
        toolbox.close()
        self.toolbox = nil
        toolboxLease = nil
        activity.finish(lease)
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === toolbox?.window else { return true }
        Task { _ = await closeToolbox(promptForScannerDraft: true) }
        return false
    }

    private func askAboutScannerDraft() -> MacScannerQuitChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "host.scanner.quitTitle")
        alert.informativeText = String(localized: "host.scanner.closeDetail")
        alert.addButton(withTitle: String(localized: "host.scanner.quitReview"))
        alert.addButton(withTitle: String(localized: "host.scanner.closeDiscard"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .review
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    private func showToolboxCloseError(_ message: String.LocalizationValue) {
        let alert = NSAlert()
        alert.messageText = String(localized: message)
        alert.runModal()
    }
}
