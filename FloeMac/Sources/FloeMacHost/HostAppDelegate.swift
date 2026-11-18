// Floe Mac M00 — native window, menu and packaged-app smoke behavior.
//
// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import SwiftUI
import FloeMacToolbox

struct SmokeOptions: Equatable {
    var exitAfter: TimeInterval
    var resultURL: URL?
}

// BEGIN HOST BRIDGE URL ROUTER
// A link is presentation intent only; it carries no pairing authority.
struct HostBridgeURLRouter {
    private var ready = false
    private var pending = false

    static func recognizes(_ urls: [URL]) -> Bool {
        urls.contains { $0.scheme == "floe-bridge" && $0.host == "connect" }
    }

    mutating func receive(_ urls: [URL]) -> Bool {
        guard Self.recognizes(urls) else { return false }
        if ready { return true }
        pending = true
        return false
    }

    mutating func setReady(_ value: Bool) -> Bool {
        ready = value
        guard ready && pending else { return false }
        pending = false
        return true
    }
}
// END HOST BRIDGE URL ROUTER

@MainActor
final class HostAppDelegate: NSObject, NSApplicationDelegate {
    private let model: HostModel
    private let smoke: SmokeOptions?
    private let toolboxEnabled: Bool
    private var toolboxServices: MacToolboxServices?
    private var toolboxController: MacToolboxWindowController?
    private var window: NSWindow?
    private var bridgeInfoWindow: NSWindow?
    private var bridgeURLRouter = HostBridgeURLRouter()
    private var cancellables = Set<AnyCancellable>()
    private var smokeResultWritten = false
    private var smokeAgentChatVerified = false
    private var terminationApproved = false
    private var terminationInFlight = false

    init(model: HostModel, smoke: SmokeOptions?, toolboxEnabled: Bool = false) {
        self.model = model
        self.smoke = smoke
        self.toolboxEnabled = toolboxEnabled && smoke == nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if toolboxEnabled { toolboxServices = MacToolboxServices() }
        buildMenu()
        let hosting = NSHostingController(rootView: HostRootView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1_040, height: 760))
        window.minSize = NSSize(width: 900, height: 640)
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        model.attach(window: window)
        model.$isFirstRun.sink { [weak self] isFirstRun in
            self?.updateBridgeURLReadiness(isFirstRun: isFirstRun)
        }.store(in: &cancellables)
        model.modeDidChange = { [weak self] _ in self?.buildMenu() }
        window.makeKeyAndOrderFront(nil)
        if smoke == nil {
            NSApp.activate(ignoringOtherApps: true)
        }
        if let smoke {
            runSmoke(smoke)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard HostBridgeURLRouter.recognizes(urls) else { return }
        showWindow()
        if bridgeURLRouter.receive(urls) { showBridgeInfo() }
    }

    private func updateBridgeURLReadiness(isFirstRun: Bool) {
        let ready = window != nil && !isFirstRun && !terminationInFlight && !terminationApproved
        if bridgeURLRouter.setReady(ready) { showBridgeInfo() }
    }

    private func showBridgeInfo() {
        guard !terminationInFlight, !terminationApproved else { return }
        if bridgeInfoWindow == nil {
            let hosting = NSHostingController(rootView: BridgeConnectionInfoView(model: model, bridge: model.bridge))
            let panel = NSWindow(contentViewController: hosting)
            panel.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            panel.setContentSize(NSSize(width: 720, height: 560))
            panel.minSize = NSSize(width: 540, height: 400)
            panel.title = String(localized: "host.bridge.title")
            panel.isReleasedWhenClosed = false
            panel.center()
            bridgeInfoWindow = panel
        }
        bridgeInfoWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Closing the window is not stopping the Bridge. The app keeps its
    // service and any active work; Dock reopen or the Window menu restores it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationApproved { return .terminateNow }
        if terminationInFlight { return .terminateLater }
        terminationInFlight = true
        updateBridgeURLReadiness(isFirstRun: model.isFirstRun)
        toolboxServices?.closeAdmissionsForTermination()
        Task { @MainActor [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            if let services = self.toolboxServices, !(await services.drainNonScannerForTermination()) {
                self.terminationInFlight = false
                self.updateBridgeURLReadiness(isFirstRun: self.model.isFirstRun)
                services.resumeAfterCancelledTermination()
                self.model.errorMessage = String(localized: "host.toolboxHistorySaveFailed")
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            if let services = self.toolboxServices {
                let outcome = await MacScannerQuitDecision.resolve(
                    status: { await services.scannerTerminationStatus() },
                    choose: { Self.askAboutScannerDraft() },
                    discard: { await services.discardScannerDraftForTermination() }
                )
                if outcome != .ready {
                    self.terminationInFlight = false
                    self.updateBridgeURLReadiness(isFirstRun: self.model.isFirstRun)
                    services.resumeAfterCancelledTermination()
                    if outcome == .pending {
                        self.model.errorMessage = String(localized: "host.scanner.quitPending")
                    }
                    sender.reply(toApplicationShouldTerminate: false)
                    if outcome == .review {
                        // The scanner entry is still disabled. Do not imply the
                        // draft is editable until its real UI is connected.
                        self.model.errorMessage = String(localized: "host.scanner.reviewUnavailable")
                        self.showToolbox()
                    }
                    return
                }
            }
            if let services = self.toolboxServices, !(await services.drainCameraForTermination()) {
                self.terminationInFlight = false
                self.updateBridgeURLReadiness(isFirstRun: self.model.isFirstRun)
                services.resumeAfterCancelledTermination()
                self.model.errorMessage = String(localized: "host.toolboxCameraStopFailed")
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            let decision = await self.model.prepareForTermination()
            self.terminationInFlight = false
            if decision.canTerminate {
                self.terminationApproved = true
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                self.updateBridgeURLReadiness(isFirstRun: self.model.isFirstRun)
                self.toolboxServices?.resumeAfterCancelledTermination()
                if let message = decision.message {
                    self.model.errorMessage = message
                }
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    private static func askAboutScannerDraft() -> MacScannerQuitChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "host.scanner.quitTitle")
        alert.informativeText = String(localized: "host.scanner.quitDetail")
        alert.addButton(withTitle: String(localized: "host.scanner.quitReview"))
        alert.addButton(withTitle: String(localized: "host.scanner.quitDiscard"))
        alert.addButton(withTitle: String(localized: "host.scanner.quitCancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return MacScannerQuitDecision.choice(forButtonIndex: 0)
        case .alertSecondButtonReturn: return MacScannerQuitDecision.choice(forButtonIndex: 1)
        case .alertThirdButtonReturn: return MacScannerQuitDecision.choice(forButtonIndex: 2)
        default: return MacScannerQuitDecision.choice(forButtonIndex: nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let smoke, !smokeResultWritten {
            writeSmokeResult(smoke)
        }
        if smoke != nil { model.agentWorkspace?.removeSmokeStoreAfterTermination() }
        toolboxController?.close()
        bridgeInfoWindow?.close()
        toolboxServices?.shutdown()
        model.shutdown()
    }

    private func runSmoke(_ options: SmokeOptions) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(max(options.exitAfter, 1))
            if self.model.mode == .bridge {
                let readyDeadline = Date().addingTimeInterval(12)
                while Date() < readyDeadline {
                    if self.model.bridge.state.status != nil { break }
                    if case .failed = self.model.bridge.state { break }
                    if case .conflict = self.model.bridge.state { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            } else if let workspace = self.model.agentWorkspace {
                let readyDeadline = Date().addingTimeInterval(12)
                while Date() < readyDeadline && !workspace.isReady && workspace.notice == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                #if FLOE_MAC_HOST_SMOKE
                self.smokeAgentChatVerified = await workspace.verifyChatSmoke()
                #endif
            }
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            self.writeSmokeResult(options)
            // AppKit may wait in a nested run loop for the asynchronous
            // termination reply. Let this main actor job return first so
            // that the delegate's drain task can run while AppKit waits.
            RunLoop.main.perform {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
        }
    }

    private func writeSmokeResult(_ options: SmokeOptions) {
        guard let url = options.resultURL, !smokeResultWritten else { return }
        smokeResultWritten = true
        let bridgeState: String
        switch model.bridge.state {
        case .idle: bridgeState = "idle"
        case .starting: bridgeState = "starting"
        case .ready: bridgeState = "ready"
        case .stopping: bridgeState = "stopping"
        case .conflict: bridgeState = "conflict"
        case .failed: bridgeState = "failed"
        }
        let agentUIState: String
        switch model.agentUI.state {
        case .idle: agentUIState = "idle"
        case .launching: agentUIState = "launching"
        case .running(let pid): agentUIState = "running:\(pid)"
        case .failed: agentUIState = "failed"
        }
        let payload: [String: Any] = [
            "schema": "floe-mac-m00-gui-smoke-v1",
            "agentCoreReady": model.agentWorkspace?.isReady ?? false,
            "agentCoreError": model.agentWorkspace?.storageErrorKind ?? "none",
            "agentChatVerified": smokeAgentChatVerified,
            "mode": model.mode.rawValue,
            "modeSource": model.source.rawValue,
            "firstRun": model.isFirstRun,
            "roleTitle": model.roleSnapshot?.windowTitle ?? model.mode.displayName,
            "bridgeState": bridgeState,
            "bridgePID": model.bridge.state.status?.pid ?? 0,
            "bridgeOrigin": model.bridge.launchOrigin?.rawValue ?? "none",
            "bridgeActiveTasks": model.bridge.state.status?.activeTaskIDs.count ?? 0,
            "bridgeUnknownTasks": model.bridge.state.status?.unknownTaskIDs.count ?? 0,
            "bridgeIdentitySource": model.bridge.state.status?.identitySource ?? "none",
            "bridgeIdentityFingerprint": model.bridge.state.status?.identityFingerprintSHA256 ?? "none",
            "bridgeWorkerHome": model.bridge.state.status?.workerHome ?? "none",
            "bridgeOrphaned": model.bridge.state.status?.orphaned ?? false,
            "bridgeControlConnected": model.bridge.state.status != nil,
            "agentUIState": agentUIState,
            "bridgeLogTail": model.bridge.readLogTail(),
            "preferencePath": model.store.preferenceURL.path,
            "bundlePath": Bundle.main.bundleURL.path,
            "windowVisible": window?.isVisible ?? false,
            "bridgeInfoWindowVisible": bridgeInfoWindow?.isVisible ?? false,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
        } catch {
            FileHandle.standardError.write(Data(("Smoke result write failed: \(error)\n").utf8))
        }
    }

    private func buildMenu() {
        let appName = model.mode.displayName
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: String(format: String(localized: "host.about"), appName),
                        action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        let show = appMenu.addItem(withTitle: "Show \(appName)", action: #selector(showWindow), keyEquivalent: "0")
        show.target = self
        appMenu.addItem(.separator())
        let hide = appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(withTitle: String(format: String(localized: "host.quit"), appName),
                                   action: #selector(quit), keyEquivalent: "q")
        quit.target = self

        let modeMenuItem = NSMenuItem()
        mainMenu.addItem(modeMenuItem)
        let modeMenu = NSMenu(title: String(localized: "host.menu.mode"))
        modeMenuItem.submenu = modeMenu
        let agentItem = modeMenu.addItem(withTitle: String(localized: "host.menu.agent"), action: #selector(switchToAgent), keyEquivalent: "1")
        agentItem.target = self
        let bridgeItem = modeMenu.addItem(withTitle: String(localized: "host.menu.bridge"), action: #selector(switchToBridge), keyEquivalent: "2")
        bridgeItem.target = self
        modeMenu.addItem(.separator())
        let openAgent = modeMenu.addItem(withTitle: String(localized: "host.menu.openAgent"), action: #selector(openAgentWorkspace), keyEquivalent: "")
        openAgent.target = self
        let stopBridge = modeMenu.addItem(withTitle: String(localized: "host.menu.stopBridge"), action: #selector(stopBridge), keyEquivalent: "")
        stopBridge.target = self

        if toolboxServices != nil {
            let toolsMenuItem = NSMenuItem()
            mainMenu.addItem(toolsMenuItem)
            let toolsMenu = NSMenu(title: String(localized: "host.menu.tools"))
            toolsMenuItem.submenu = toolsMenu
            toolsMenu.addItem(MacToolboxMenu.makeItem(locale: .current, target: self, action: #selector(showToolbox)))
        }

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let close = windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        close.target = nil
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: RolePresentation.aboutPanelOptions(for: model.mode))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showWindow() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showToolbox() {
        guard let toolboxServices else { return }
        if toolboxController == nil { toolboxController = MacToolboxWindowController(services: toolboxServices) }
        toolboxController?.present()
    }

    @objc private func switchToAgent() {
        model.switchMode(.agent)
    }

    @objc private func switchToBridge() {
        model.switchMode(.bridge)
    }

    @objc private func openAgentWorkspace() {
        model.openAgentWorkspace()
    }

    @objc private func stopBridge() {
        model.stopBridgeExplicitly()
    }
}
