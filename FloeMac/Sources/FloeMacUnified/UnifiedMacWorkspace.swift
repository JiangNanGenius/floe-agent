// SPDX-License-Identifier: MPL-2.0

import AppKit
import FloeMacToolbox
import SwiftUI

/// Owns the native windows from the same application process as Bridge.
/// The shared activity ledger prevents an installation from racing an
/// admitted conversation or the shutdown of an open toolbox.
@MainActor
final class UnifiedMacWorkspace: NSObject, NSWindowDelegate, NSMenuItemValidation {
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
    private let testSupport: URL?
    private let preferences: UserDefaults
    private(set) var agent: HostAgentWorkspace?
    private(set) var images: MacImageGeneration?
    private var agentWindow: NSWindow?
    private var taskMenuItem: NSMenuItem?
    private var draftStore: MacWorkspaceDraftStore?
    private var agentLeases = Set<BridgeUpdateActivity.Lease>()
    private(set) var toolbox: MacToolboxWindowController?
    private var toolboxLease: BridgeUpdateActivity.Lease?
    private var drainingToolbox = false

    init(activity: BridgeUpdateActivity, testSupport: URL? = nil, preferences: UserDefaults = .standard) {
        self.activity = activity
        self.testSupport = testSupport
        self.preferences = preferences
    }

    func openAgent(openSettings: @escaping () -> Void, openImageSettings: @escaping () -> Void,
                   openModelSettings: @escaping () -> Void, settingsContent: @escaping () -> AnyView) {
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
            agent = workspace
            let directory = try? HostAgentDatabase.committedSyncStoreURL(applicationSupport: root, namespace: namespace)
                .deletingLastPathComponent()
            let drafts = MacWorkspaceDraftStore(directory: directory?.appendingPathComponent("Drafts", isDirectory: true))
            draftStore = drafts
            let images = directory.map {
                MacImageGeneration(directory: $0.appendingPathComponent("Images", isDirectory: true), namespace: namespace,
                                   useKeychain: testSupport == nil, admitWork: admitWork)
            }
            self.images = images
            workspace.loadAttachmentDraft = { [weak drafts] in drafts?.attachments(for: $0) ?? [] }
            workspace.saveAttachmentDraft = { [weak drafts] id, attachments in drafts?.setAttachments(attachments, for: id) }
            let host = NSHostingController(rootView: MacWorkspaceRootView(
                workspace: workspace, openSettings: openSettings,
                openModelSettings: openModelSettings,
                openToolbox: { [weak self] toolID in self?.openToolbox(toolID: toolID) },
                settingsContent: settingsContent,
                imageContent: {
                    if let images { return AnyView(MacImageWorkbenchView(images: images, openSettings: openImageSettings)) }
                    return AnyView(ContentUnavailableView("mac.images.unavailable", systemImage: "photo"))
                },
                remembersFileRoot: testSupport == nil, draftStore: drafts
            ))
            let window = NSWindow(contentViewController: host)
            window.title = String(localized: "host.role.agent")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1150, height: 750))
            window.minSize = NSSize(width: 720, height: 480)
            if testSupport == nil { window.setFrameAutosaveName("FloeMacUnifiedAgent") }
            window.isReleasedWhenClosed = false
            window.center()
            agentWindow = window
            window.delegate = self
        }
        agentWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installTaskMenu()
    }

    private func performWindowAction(_ action: HostAgentWorkspace.WindowAction) {
        guard let agent, let agentWindow, agentWindow === NSApp.keyWindow,
              !agent.isSettingsPresented, agentWindow.attachedSheet == nil else { return }
        agent.windowCommand = .init(action: action)
    }

    private func installTaskMenu() {
        guard let mainMenu = NSApp.mainMenu, taskMenuItem?.menu !== mainMenu else { return }
        if let taskMenuItem { taskMenuItem.menu?.removeItem(taskMenuItem) }
        let title = String(localized: "Tasks")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        let newTask = menu.addItem(withTitle: String(localized: "workbench.new_task"),
                                   action: #selector(newTaskFromMenu(_:)), keyEquivalent: "n")
        newTask.target = self
        let findTask = menu.addItem(withTitle: String(localized: "mac.workspace.findTask"),
                                    action: #selector(findTaskFromMenu(_:)), keyEquivalent: "f")
        findTask.target = self
        item.submenu = menu
        mainMenu.insertItem(item, at: min(2, mainMenu.items.count))
        taskMenuItem = item
    }

    @objc private func newTaskFromMenu(_ sender: NSMenuItem) {
        agentWindow?.makeKeyAndOrderFront(nil)
        performWindowAction(.newTask)
    }

    @objc private func findTaskFromMenu(_ sender: NSMenuItem) {
        performWindowAction(.findTask)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let agent, !agent.isTerminating, !agent.isSettingsPresented else { return false }
        if menuItem.action == #selector(newTaskFromMenu(_:)) {
            return agent.isReady && !agent.isSending && !agent.isAcceptingPlan
        }
        return agentWindow === NSApp.keyWindow
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if notification.object as? NSWindow === agentWindow { installTaskMenu() }
    }

    #if FLOE_MAC_HOST_SMOKE
    var settingsSheet: NSWindow? { agentWindow?.attachedSheet }
    #endif

    func closeForBridgeMode() async throws -> Bool {
        guard let agent, agentLeases.isEmpty, agent.beginTermination() else { throw CloseError.agentBusy }
        defer { if self.agent != nil { agent.cancelTermination() } }
        guard !agent.hasPendingWorkspaceFileChanges else { throw CloseError.pendingFiles }
        draftStore?.flush()
        guard draftStore?.saveFailed != true else { throw CloseError.draftSaveFailed }
        agent.cancelModelDiscovery()
        guard await closeToolbox(promptForScannerDraft: true) else { return false }
        do { try await agent.finishTermination() }
        catch { throw CloseError.runtimeCloseFailed }
        agent.isSettingsPresented = false
        if let sheet = agentWindow?.attachedSheet { agentWindow?.endSheet(sheet) }
        if let item = taskMenuItem { item.menu?.removeItem(item) }
        taskMenuItem = nil
        agentWindow?.close()
        agentWindow?.contentViewController = nil
        agentWindow = nil
        draftStore = nil
        images = nil
        self.agent = nil
        return true
    }

    func openToolbox(toolID: String?) {
        guard agent?.isTerminating == false, !drainingToolbox else { return }
        if toolbox == nil {
            guard let lease = try? activity.begin(.maintenance) else { return }
            let storage = testSupport?.appendingPathComponent("Toolbox", isDirectory: true)
            let services = MacToolboxServices(storageRoot: storage, mediaEnvironment: .init())
            let controller = MacToolboxWindowController(services: services, autosavesFrame: testSupport == nil)
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
