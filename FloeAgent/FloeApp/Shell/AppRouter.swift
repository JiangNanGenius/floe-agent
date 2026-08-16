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

/// The one source of truth for the work surface. Home, history rows,
/// workspace rows and newly-created tasks all project this same selection;
/// there is no independent Home-vs-Chat conversation state to become stale.
enum WorkbenchSelection: Hashable, Sendable {
    case overview
    case newTask(workspaceID: UUID?)
    case workspace(UUID)
    case conversation(UUID)
}

/// Navigation state and background-policy wiring for the whole app.
/// Views bind to this; they never hold policy or selection state of their own.
@MainActor
final class AppRouter: ObservableObject {

    // MARK: - Selection

    /// The active primary destination (the selected tab on iPhone).
    @Published var selection: AppDestination = .home

    /// The active iPad sidebar selection, including promoted More sections.
    @Published var sidebarSelection: SidebarSelection? = .workbench(.overview)

    /// iPad split-view column visibility.
    @Published var columnVisibility: NavigationSplitViewVisibility = .all

    // MARK: - Cross-screen selection

    /// Canonical workbench selection shared by every idiom and entry point.
    @Published var workbenchSelection: WorkbenchSelection = .overview
    /// The single compact-navigation projection of `workbenchSelection`.
    /// A user-driven NavigationStack pop writes this binding directly, so
    /// reconcile the canonical selection here as well as in router methods.
    @Published var workbenchPath: [UUID] = [] {
        didSet {
            if let id = workbenchPath.last {
                if workbenchSelection != .conversation(id) {
                    workbenchSelection = .conversation(id)
                }
            } else if case .conversation = workbenchSelection {
                workbenchSelection = .overview
                selectedRunID = nil
                if case .workbench = sidebarSelection {
                    sidebarSelection = .workbench(.overview)
                }
            }
        }
    }
    /// iPhone More navigation path. It also gives Home quick actions a
    /// single cross-idiom way to open a concrete settings surface.
    @Published var morePath: [MoreDestination] = []
    /// Run currently inspected (thread detail / runs history), if any.
    @Published var selectedRunID: UUID?
    /// Host currently inspected (host detail / terminal / VNC), if any.
    @Published var selectedHostID: UUID?
    /// A single app-wide setup sheet shared by iPhone and iPad routes.
    @Published var presentedSetup: SetupPresentation?

    /// Compatibility projections for feature views while their callers move
    /// to `workbenchSelection`. Both aliases read and write the same state.
    var selectedConversationID: UUID? {
        get {
            guard case .conversation(let id) = workbenchSelection else { return nil }
            return id
        }
        set {
            if let newValue {
                workbenchSelection = .conversation(newValue)
                workbenchPath = [newValue]
            } else if case .conversation = workbenchSelection {
                workbenchSelection = .overview
                workbenchPath = []
            }
        }
    }

    var homeDetailConversationID: UUID? {
        get { selectedConversationID }
        set { selectedConversationID = newValue }
    }

    var homePath: [UUID] {
        get { workbenchPath }
        set { setWorkbenchPath(newValue) }
    }

    var chatPath: [UUID] {
        get { workbenchPath }
        set { setWorkbenchPath(newValue) }
    }

    // MARK: - Inspector (iPad third column / iPhone sheet)

    /// What the inspector column/sheet should display.
    enum InspectorContent: String, Identifiable, Hashable, Sendable {
        /// The workspace file inspector.
        case workspaceFiles
        var id: String { rawValue }
    }

    /// Requested inspector content. Non-nil means "show the inspector":
    /// iPad reveals the third column on demand, iPhone presents a sheet.
    @Published var inspectorContent: InspectorContent?

    /// Convenience flag derived from inspectorContent (views bind to
    /// this; FileInspectorView reads the content).
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
        switch destination {
        case .home, .chat:
            sidebarSelection = .workbench(workbenchSelection)
        case .files, .browser, .hosts, .more:
            sidebarSelection = .primary(destination)
        }
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
        workbenchSelection = .conversation(conversationID)
        workbenchPath = [conversationID]
        selectedRunID = runID
        navigate(to: .home)
    }

    /// Opens a freshly-started task while keeping Home as the visible entry
    /// point. Home and history still project the same canonical workbench
    /// selection, so switching tabs cannot resurrect an older thread.
    func openThreadFromHome(_ conversationID: UUID, runID: UUID? = nil) {
        workbenchSelection = .conversation(conversationID)
        workbenchPath = [conversationID]
        selectedRunID = runID
        navigate(to: .home)
    }

    func showOverview() {
        workbenchSelection = .overview
        workbenchPath = []
        selectedRunID = nil
        sidebarSelection = .workbench(.overview)
        selection = .home
    }

    func startNewTask(workspaceID: UUID? = nil) {
        workbenchSelection = .newTask(workspaceID: workspaceID)
        workbenchPath = []
        selectedRunID = nil
        sidebarSelection = .workbench(workbenchSelection)
        selection = .home
    }

    func selectWorkspace(_ workspaceID: UUID) {
        workbenchSelection = .workspace(workspaceID)
        workbenchPath = []
        selectedRunID = nil
        sidebarSelection = .workbench(workbenchSelection)
        selection = .home
    }

    /// Repairs selections after deletion, history clear or cross-scene DB
    /// changes. A missing parent can never leave an enabled composer behind.
    func reconcileConversations(_ availableIDs: Set<UUID>) {
        guard case .conversation(let id) = workbenchSelection,
              !availableIDs.contains(id) else { return }
        showOverview()
        hideInspector()
    }

    private func setWorkbenchPath(_ path: [UUID]) {
        workbenchPath = path
        if let id = path.last {
            workbenchSelection = .conversation(id)
        } else if case .conversation = workbenchSelection {
            workbenchSelection = .overview
            selectedRunID = nil
        }
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
