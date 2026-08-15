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

enum SetupPresentation: String, Identifiable, Hashable, Sendable {
    case firstLaunch
    case manual
    var id: String { rawValue }
}

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
    /// iPhone Home navigation path. Home and Chat own separate stacks so
    /// starting a task from Home never pollutes the Chat list's back
    /// behavior, and returning in Chat never disturbs Home.
    @Published var homePath: [UUID] = []
    /// iPhone More navigation path. It also gives Home quick actions a
    /// single cross-idiom way to open a concrete settings surface.
    @Published var morePath: [MoreDestination] = []
    /// Conversation shown in Home's iPad detail column (a task started
    /// from Home). Separate from `selectedConversationID`, which belongs
    /// to Chat, so the two pages never share selection state.
    @Published var homeDetailConversationID: UUID?
    /// Run currently inspected (thread detail / runs history), if any.
    @Published var selectedRunID: UUID?
    /// Host currently inspected (host detail / terminal / VNC), if any.
    @Published var selectedHostID: UUID?
    /// A single app-wide setup sheet shared by iPhone and iPad routes.
    @Published var presentedSetup: SetupPresentation?

    // MARK: - Inspector (iPad third column / iPhone sheet)

    /// What the inspector column/sheet should display. T05 fills in the
    /// real workspace inspector; T03 only owns the routing surface so
    /// views never invent their own presentation.
    enum InspectorContent: String, Identifiable, Hashable, Sendable {
        /// The workspace file inspector (content provided by T05).
        case workspaceFiles
        var id: String { rawValue }
    }

    /// Requested inspector content. Non-nil means "show the inspector":
    /// iPad reveals the third column on demand, iPhone presents a sheet.
    @Published var inspectorContent: InspectorContent?

    /// Convenience flag derived from inspectorContent (views bind to
    /// this; T05's FileInspectorView reads the content).
    var inspectorVisible: Bool { inspectorContent != nil }

    /// Opens the inspector with the given content (iPad: third column;
    /// iPhone: sheet — presentation chosen by the shell).
    func showInspector(_ content: InspectorContent) {
        inspectorContent = content
    }

    /// Dismisses the inspector; the iPad third column collapses instead
    /// of leaving an empty placeholder behind.
    func hideInspector() {
        inspectorContent = nil
    }

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

    /// Opens a concrete More destination on both idioms: a pushed screen
    /// on iPhone and the promoted sidebar section on iPad.
    func openMore(_ destination: MoreDestination) {
        selection = .more
        sidebarSelection = .more(destination)
        morePath = [destination]
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

    /// Opens a freshly started task thread WITHOUT leaving Home. The new
    /// conversation is pushed onto Home's own navigation stack (iPhone) or
    /// projected into Home's detail column (iPad); the Chat list and its
    /// selection stay untouched until the user visits Chat themselves.
    func openThreadFromHome(_ conversationID: UUID, runID: UUID? = nil) {
        homeDetailConversationID = conversationID
        selectedRunID = runID
        navigate(to: .home)
        homePath = [conversationID]
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
