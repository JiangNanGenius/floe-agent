// FloeApp — App-wide navigation router and scene-phase wiring.
//
// SPDX-License-Identifier: MPL-2.0
//
// One router instance drives the adaptive sidebar workbench on both idioms.
// It owns compatibility destinations, column visibility, the currently selected
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

/// Pure per-window lifecycle bookkeeping. `AppRouter` remains shared navigation
/// state, while every WindowGroup content instance supplies its own stable ID.
/// Removing a scene drops its last phase so a discarded foreground window can
/// never keep the app-wide aggregate falsely active.
struct AppScenePhaseAggregation: Sendable, Equatable {
    private(set) var phasesBySceneID: [String: PolicyScenePhase] = [:]

    static func effectivePhase(
        for phases: [PolicyScenePhase]
    ) -> PolicyScenePhase {
        if phases.contains(.active) { return .active }
        if phases.contains(.inactive) { return .inactive }
        // No remaining window is equivalent to app-wide background for
        // resources shared across scenes (SSH/VNC owners in particular).
        return .background
    }

    var effectivePhase: PolicyScenePhase {
        Self.effectivePhase(for: Array(phasesBySceneID.values))
    }

    /// Returns the new aggregate only when this scene report changes it.
    /// Callers can therefore keep app-wide resources stable when a background
    /// window coexists with another active window.
    @discardableResult
    mutating func report(
        _ phase: PolicyScenePhase,
        sceneID: String
    ) -> PolicyScenePhase? {
        let previousEffectivePhase = effectivePhase
        phasesBySceneID[sceneID] = phase
        let newEffectivePhase = effectivePhase
        return newEffectivePhase == previousEffectivePhase ? nil : newEffectivePhase
    }

    struct Removal: Sendable, Equatable {
        var removedPhase: PolicyScenePhase
        /// The new aggregate, or nil when another scene keeps it unchanged.
        var effectivePhaseChange: PolicyScenePhase?
    }

    @discardableResult
    mutating func remove(sceneID: String) -> Removal? {
        let previousEffectivePhase = effectivePhase
        guard let removedPhase = phasesBySceneID.removeValue(forKey: sceneID) else {
            return nil
        }
        let newEffectivePhase = effectivePhase
        return Removal(
            removedPhase: removedPhase,
            effectivePhaseChange: newEffectivePhase == previousEffectivePhase
                ? nil
                : newEffectivePhase
        )
    }
}

/// Navigation state and background-policy wiring for the whole app.
/// Views bind to this; they never hold policy or selection state of their own.
@MainActor
final class AppRouter: ObservableObject {
    private var hasExplicitLaunchTarget = false
    private var scenePhaseAggregation = AppScenePhaseAggregation()
    /// Remote session owners are app-wide. Serialize effective scene changes
    /// so a slow background suspension cannot finish after a newer foreground
    /// reconciliation and leave the shared owners paused.
    private var remoteScenePhaseTask: Task<Void, Never>?

    // MARK: - Selection

    /// Compatibility destination for deep links and legacy callers.
    @Published var selection: AppDestination = .home

    /// The active iPad sidebar selection, including promoted More sections.
    @Published var sidebarSelection: SidebarSelection? = .workbench(.newTask(workspaceID: nil))

    /// iPad split-view column visibility.
    @Published var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    // MARK: - Cross-screen selection

    /// Canonical workbench selection shared by every idiom and entry point.
    @Published var workbenchSelection: WorkbenchSelection = .newTask(workspaceID: nil)
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
                workbenchSelection = .newTask(workspaceID: nil)
                selectedRunID = nil
                if case .workbench = sidebarSelection {
                    sidebarSelection = .workbench(.newTask(workspaceID: nil))
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
                workbenchSelection = .newTask(workspaceID: nil)
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
        case changes
        case workspaceFiles
        case browser
        case terminal
        case progress
        case childAgents
        case permissions
        var id: String { rawValue }
    }

    struct InspectorRoute: Identifiable, Hashable, Sendable {
        var content: InspectorContent
        var conversationID: UUID
        var id: String { "\(content.rawValue).\(conversationID.uuidString)" }
    }

    /// Requested inspector content. Non-nil means "show the inspector":
    /// iPad reveals the third column on demand, iPhone presents a sheet.
    @Published var inspectorRoute: InspectorRoute?
    @Published var presentedSettings = false

    /// Convenience flag derived from inspectorContent (views bind to
    /// this; FileInspectorView reads the content).
    var inspectorVisible: Bool { inspectorRoute != nil }

    /// Opens the inspector with the given content (iPad: third column;
    /// iPhone: sheet — presentation chosen by the shell).
    func showInspector(_ content: InspectorContent) {
        guard let conversationID = selectedConversationID else { return }
        inspectorRoute = InspectorRoute(content: content, conversationID: conversationID)
        columnVisibility = .all
    }

    /// Dismisses the inspector; the iPad third column collapses instead
    /// of leaving an empty placeholder behind.
    func hideInspector() {
        inspectorRoute = nil
        columnVisibility = .doubleColumn
    }

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
    }

    /// Called exactly once by the App lifecycle entry point. Keeping BGTask
    /// registration out of router construction avoids duplicate identifier
    /// registration when SwiftUI rebuilds scenes.
    func registerBackgroundTasksAtAppLaunch() {
        backgroundPolicy.registerTasks()
    }

    /// Feeds a SwiftUI scene-phase transition into the background policy
    /// and reconciles remote sessions (suspend on background, reconcile on
    /// active). The center owns the honest session lifecycle.
    func handleScenePhase(
        _ phase: ScenePhase,
        sceneID: String,
        environment: AppEnvironment
    ) {
        let reportedPhase = policyPhase(for: phase)
        let effectivePhaseChange = scenePhaseAggregation.report(
            reportedPhase,
            sceneID: sceneID
        )
        backgroundPolicy.handleScenePhase(reportedPhase, sceneID: sceneID)
        environment.backgroundRunCoordinator.handleScenePhase(phase, sceneID: sceneID)
        if let effectivePhaseChange {
            enqueueRemoteScenePhase(
                effectivePhaseChange,
                center: environment.remoteSessionCenter
            )
        }
    }

    /// SwiftUI normally publishes `.background` before discarding a scene, but
    /// scene destruction is not required to preserve that callback ordering.
    /// Explicitly downgrade the coordinator's existing per-ID entry before
    /// removing our own record so no stale `.active` value survives the window.
    func removeScene(sceneID: String, environment: AppEnvironment) {
        guard let removal = scenePhaseAggregation.remove(sceneID: sceneID) else { return }
        backgroundPolicy.handleScenePhase(.background, sceneID: sceneID)
        environment.backgroundRunCoordinator.handleScenePhase(
            .background,
            sceneID: sceneID
        )
        if let effectivePhaseChange = removal.effectivePhaseChange {
            enqueueRemoteScenePhase(
                effectivePhaseChange,
                center: environment.remoteSessionCenter
            )
        }
    }

    private func enqueueRemoteScenePhase(
        _ phase: PolicyScenePhase,
        center: RemoteSessionCenter
    ) {
        let precedingTask = remoteScenePhaseTask
        remoteScenePhaseTask = Task { @MainActor in
            await precedingTask?.value
            guard !Task.isCancelled else { return }
            switch phase {
            case .background:
                await center.handleScenePhase(.background)
            case .active:
                await center.handleScenePhase(.active)
            case .inactive:
                await center.handleScenePhase(.inactive)
            }
        }
    }

    /// Reconciles remote session state after a cold launch: any session
    /// not explicitly disconnected is honestly unknown (never paused).
    func reconcileOnLaunch(environment: AppEnvironment) {
        if !hasExplicitLaunchTarget {
            startNewTask()
            hideInspector()
        }
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
        hasExplicitLaunchTarget = true
        if inspectorRoute?.conversationID != conversationID { hideInspector() }
        workbenchSelection = .conversation(conversationID)
        workbenchPath = [conversationID]
        selectedRunID = runID
        navigate(to: .home)
    }

    /// Opens a freshly-started task while keeping Home as the visible entry
    /// point. Home and history still project the same canonical workbench
    /// selection, so switching tabs cannot resurrect an older thread.
    func openThreadFromHome(_ conversationID: UUID, runID: UUID? = nil) {
        if inspectorRoute?.conversationID != conversationID { hideInspector() }
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
        hideInspector()
        workbenchSelection = .newTask(workspaceID: workspaceID)
        workbenchPath = []
        selectedRunID = nil
        sidebarSelection = .workbench(workbenchSelection)
        selection = .home
    }

    func selectWorkspace(_ workspaceID: UUID) {
        hideInspector()
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
        startNewTask()
        hideInspector()
    }

    private func setWorkbenchPath(_ path: [UUID]) {
        workbenchPath = path
        if let id = path.last {
            workbenchSelection = .conversation(id)
        } else if case .conversation = workbenchSelection {
            workbenchSelection = .newTask(workspaceID: nil)
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
