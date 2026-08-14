// FloeApp — App-wide navigation router and scene-phase wiring.
//
// SPDX-License-Identifier: MPL-2.0
//
// One router instance drives both idioms: the five-tab iPhone TabView and
// the three-column iPad NavigationSplitView. It owns the selected
// destination, the iPad column visibility, the currently selected
// conversation/run/host identifiers, and the scene-phase →
// PlatformBackgroundPolicy forwarding (moved out of the view layer).

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import Foundation

/// Navigation state and background-policy wiring for the whole app.
/// Views bind to this; they never hold policy or selection state of their own.
@MainActor
final class AppRouter: ObservableObject {

    // MARK: - Selection

    /// The active primary destination (the selected tab on iPhone).
    @Published var selection: AppDestination = .home

    /// The active iPad sidebar selection, including promoted More sections.
    @Published var sidebarSelection: SidebarSelection? = .primary(.home)

    /// iPad split-view column visibility.
    @Published var columnVisibility: NavigationSplitViewVisibility = .all

    // MARK: - Cross-screen selection

    /// Conversation currently opened in the thread detail, if any.
    @Published var selectedConversationID: UUID?
    /// iPhone Chat navigation path. iPad uses selectedConversationID to
    /// project the same thread into the split-view detail column.
    @Published var chatPath: [UUID] = []
    /// Run currently inspected (thread detail / runs history), if any.
    @Published var selectedRunID: UUID?
    /// Host currently inspected (host detail / terminal / VNC), if any.
    @Published var selectedHostID: UUID?

    /// Stable per-scene identifier used for iPad multi-scene background
    /// accounting. Each scene creates its own router, so a per-router UUID
    /// is a per-scene identifier.
    let sceneID: String = UUID().uuidString

    // MARK: - Background policy

    /// Runtime-selected background policy (see Platform/).
    let backgroundPolicy: any PlatformBackgroundPolicy

#if DEBUG
    /// M0 technical validation model, kept reachable under More →
    /// Diagnostics in DEBUG builds.
    let diagnostics = M0DiagnosticsModel()
#endif

    init() {
        if UIDevice.current.userInterfaceIdiom == .pad {
            backgroundPolicy = iPadBackgroundPolicy()
        } else {
            backgroundPolicy = iPhoneBackgroundPolicy()
        }
        BackgroundPolicyRegistry.shared.install(backgroundPolicy)
        backgroundPolicy.registerTasks()
    }

    /// Feeds a SwiftUI scene-phase transition into the background policy
    /// and reconciles remote sessions (suspend on background, reconcile on
    /// active). The center owns the honest session lifecycle.
    func handleScenePhase(_ phase: ScenePhase, environment: AppEnvironment) {
        backgroundPolicy.handleScenePhase(policyPhase(for: phase), sceneID: sceneID)
        let center = environment.remoteSessionCenter
        Task { @MainActor in
            switch phase {
            case .background:
                await center.handleScenePhase(.background)
            case .active:
                await center.handleScenePhase(.active)
            case .inactive:
                await center.handleScenePhase(.inactive)
            @unknown default:
                break
            }
        }
    }

    /// Reconciles remote session state after a cold launch: any session
    /// not explicitly disconnected is honestly unknown (never paused).
    func reconcileOnLaunch(environment: AppEnvironment) {
        Task { @MainActor in
            await environment.remoteSessionCenter.reconcileOnLaunch()
        }
    }

    /// Navigates to a primary destination. On iPhone this switches tabs;
    /// on iPad it also moves the sidebar selection.
    func navigate(to destination: AppDestination) {
        selection = destination
        sidebarSelection = .primary(destination)
    }

    /// Opens one conversation through the idiom-appropriate presentation.
    /// Keeping this operation here prevents Home and Chat from drifting into
    /// separate navigation behavior.
    func openConversation(_ conversationID: UUID, runID: UUID? = nil) {
        selectedConversationID = conversationID
        selectedRunID = runID
        navigate(to: .chat)
        chatPath = [conversationID]
    }

    private func policyPhase(for phase: ScenePhase) -> PolicyScenePhase {
        switch phase {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        @unknown default: .inactive
        }
    }
}
#endif
