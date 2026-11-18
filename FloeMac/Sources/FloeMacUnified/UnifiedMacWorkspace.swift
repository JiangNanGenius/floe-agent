// SPDX-License-Identifier: MPL-2.0

import AppKit
import FloeMacToolbox
import SwiftUI

/// Owns the native windows from the same application process as Bridge.
/// The shared activity ledger prevents an installation from racing an
/// admitted conversation or the shutdown of an open toolbox.
@MainActor
final class UnifiedMacWorkspace: NSObject, NSWindowDelegate {
    private let activity: BridgeUpdateActivity
    private let testSupport: URL?
    private(set) var agent: HostAgentWorkspace?
    private var agentWindow: NSWindow?
    private(set) var toolbox: MacToolboxWindowController?
    private var toolboxLease: BridgeUpdateActivity.Lease?
    private var drainingToolbox = false

    init(activity: BridgeUpdateActivity, testSupport: URL? = nil) {
        self.activity = activity
        self.testSupport = testSupport
    }

    func openAgent() {
        if agentWindow == nil {
            guard let root = testSupport ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                                      in: .userDomainMask).first,
                  let namespace = Bundle.main.bundleIdentifier else { return }
            let workspace = HostAgentWorkspace(supportDirectory: root, namespace: namespace,
                                                useKeychain: testSupport == nil,
                                                admitWork: { [activity] in
                let lease = try activity.begin(.request)
                return { activity.finish(lease) }
            })
            agent = workspace
            let host = NSHostingController(rootView: HostAgentWorkspaceView(workspace: workspace).padding(24))
            let window = NSWindow(contentViewController: host)
            window.title = String(localized: "host.role.agent")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 960, height: 660))
            window.minSize = NSSize(width: 560, height: 420)
            if testSupport == nil { window.setFrameAutosaveName("FloeMacUnifiedAgent") }
            window.isReleasedWhenClosed = false
            window.center()
            agentWindow = window
        }
        agentWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openToolbox() {
        guard !drainingToolbox else { return }
        if toolbox == nil {
            guard let lease = try? activity.begin(.maintenance) else { return }
            let storage = testSupport?.appendingPathComponent("Toolbox", isDirectory: true)
            let services = MacToolboxServices(storageRoot: storage, mediaEnvironment: .init())
            let controller = MacToolboxWindowController(services: services, autosavesFrame: testSupport == nil)
            controller.window?.delegate = self
            toolbox = controller
            toolboxLease = lease
        }
        toolbox?.present()
    }

    func closeToolbox() async -> Bool {
        guard let toolbox else { return true }
        guard let lease = toolboxLease, !drainingToolbox else { return false }
        drainingToolbox = true
        defer { drainingToolbox = false }
        let services = toolbox.services
        services.closeAdmissionsForTermination()
        guard await services.drainForTermination(), await services.drainCameraForTermination() else {
            services.resumeAfterCancelledTermination()
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

    func windowWillClose(_ notification: Notification) {
        Task { _ = await closeToolbox() }
    }
}
