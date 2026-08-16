// FloeApp — SwiftUI app entry point (iOS/iPadOS only).
//
// SPDX-License-Identifier: MPL-2.0
//
// iPhone shows exactly five locked tabs (Workbench, Files, Browser, Hosts, More) in
// a TabView; iPad shows a three-column NavigationSplitView with a functional
// sidebar, a content column, and a detail column. Both idioms are driven by
// one AppRouter so navigation state and scene-phase background-policy
// wiring are shared.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

@main
struct FloeAgentApp: App {
    @StateObject private var environment = AppEnvironment.live()
    @StateObject private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .environmentObject(router)
                .task { await environment.bootstrap() }
        }
    }
}

/// Idiom-adaptive root: five-tab TabView on iPhone, three-column
/// NavigationSplitView on iPad. Scene-phase transitions are forwarded to
/// the router, which owns the background policy.
struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// UITest runs pin a deterministic layout: `-ui-testing` forces the
    /// compact (iPhone-style) tab layout; `-ui-testing-ipad` additionally
    /// forces the regular split layout for the iPad suite, regardless of
    /// the size class the test host reports.
    private var forceCompactForUITest: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing") else { return false }
        return !arguments.contains("-ui-testing-ipad")
    }

    private var forceRegularForUITest: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing-ipad")
    }

    var body: some View {
        Group {
            if !environment.persistenceReady {
                persistenceState
            } else if forceRegularForUITest
                        || (horizontalSizeClass == .regular && !forceCompactForUITest) {
                iPadRoot
            } else {
                iPhoneRoot
            }
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            router.handleScenePhase(newPhase, environment: environment)
        }
        .task(id: environment.persistenceReady) {
            guard environment.persistenceReady else { return }
            router.reconcileOnLaunch(environment: environment)
            await environment.conversationCenter.reload()
            await environment.conversationCenter.reconcileInterruptedRunsOnLaunch()
            await environment.workspaceCenter.reload()
            await presentOnboardingIfNeeded()
        }
        .onReceive(environment.conversationCenter.$conversations) { conversations in
            router.reconcileConversations(Set(conversations.map(\.id)))
        }
        .sheet(item: $router.presentedSetup, onDismiss: markDismissedSetupSkipped) { _ in
            OnboardingView(center: environment.conversationCenter)
                .presentationSizing(.page)
        }
    }

    @ViewBuilder
    private var persistenceState: some View {
        if let error = environment.bootstrapError {
            ContentUnavailableView {
                Label("storage.unavailable", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text(error)
            }
            .background(FloeTheme.readingSurface)
        } else {
            ProgressView("storage.preparing")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FloeTheme.readingSurface)
        }
    }

    /// Presents first-run onboarding until a provider+model is configured.
    private func presentOnboardingIfNeeded() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-force-onboarding") {
            router.presentedSetup = .firstLaunch
            return
        }
        #endif
        await environment.conversationCenter.reconcileOnboardingForLaunch()
        if environment.conversationCenter.modelPreferences.onboardingStatus == .unseen,
           UserDefaults.standard.bool(forKey: ConversationCenter.onboardingSkippedDefaultsKey) {
            var preferences = environment.conversationCenter.modelPreferences
            preferences.onboardingStatus = .skipped
            try? await environment.conversationCenter.saveModelPreferences(preferences)
            return
        }
        if environment.conversationCenter.modelPreferences.onboardingStatus == .unseen {
            // Give an existing private-CloudKit configuration a brief chance
            // to arrive, without making launch dependent on network health.
            try? await Task.sleep(for: .seconds(2))
            await environment.conversationCenter.reconcileOnboardingForLaunch()
        }
        if environment.conversationCenter.modelPreferences.onboardingStatus == .unseen {
            router.presentedSetup = .firstLaunch
        }
    }

    private func markDismissedSetupSkipped() {
        let center = environment.conversationCenter
        guard center.modelPreferences.onboardingStatus == .unseen else { return }
        // Interactive sheet dismissal is synchronous. Persist this tiny local
        // marker immediately so a force-quit cannot resurrect onboarding while
        // the durable DB/CloudKit preference save is still being scheduled.
        ConversationCenter.persistOnboardingSkippedMarker(true)
        Task {
            var preferences = center.modelPreferences
            preferences.onboardingStatus = .skipped
            try? await center.saveModelPreferences(preferences)
        }
    }

    // MARK: - iPhone: five locked tabs

    private var iPhoneRoot: some View {
        TabView(selection: $router.selection) {
            ForEach(AppDestination.allCases) { destination in
                Tab(value: destination) {
                    // Home and Chat are two projections of one workbench
                    // selection/path; switching entry points cannot expose a
                    // stale or deleted conversation.
                    if destination == .chat {
                        NavigationStack(path: $router.workbenchPath) {
                            PrimaryDestinationView(destination, environment: environment)
                        }
                    } else if destination == .home {
                        NavigationStack(path: $router.workbenchPath) {
                            PrimaryDestinationView(destination, environment: environment)
                                .navigationDestination(for: UUID.self) { conversationID in
                                    ThreadDetailView(
                                        conversationID: conversationID,
                                        center: environment.conversationCenter
                                    )
                                }
                        }
                    } else if destination == .more {
                        NavigationStack(path: $router.morePath) {
                            PrimaryDestinationView(destination, environment: environment)
                        }
                    } else {
                        NavigationStack {
                            PrimaryDestinationView(destination, environment: environment)
                        }
                    }
                } label: {
                    Label(destination.title, systemImage: destination.systemImage)
                }
            }
        }
        // iPhone presents the inspector as a sheet; iPad reveals the
        // third column instead (see detailColumn).
        .sheet(item: inspectorSheetBinding) { content in
            NavigationStack {
                InspectorColumnView(content: content)
            }
            .presentationSizing(.page)
        }
    }

    /// On iPhone the inspector shows as a sheet; on iPad the third
    /// column handles it, so the binding stays nil there.
    private var inspectorSheetBinding: Binding<AppRouter.InspectorContent?> {
        Binding(
            get: { router.inspectorContent },
            set: { newValue in
                if newValue == nil { router.hideInspector() }
            }
        )
    }

    // MARK: - iPad: three-column split view

    private var iPadRoot: some View {
        NavigationSplitView(columnVisibility: $router.columnVisibility) {
            List(selection: $router.sidebarSelection) {
                Section {
                    Label("tab.home", systemImage: "rectangle.grid.2x2")
                        .tag(SidebarSelection.workbench(.overview))
                        .accessibilityIdentifier("sidebar.workbench.overview")
                    Label("chat.new", systemImage: "square.and.pencil")
                        .tag(SidebarSelection.workbench(.newTask(
                            workspaceID: environment.workspaceCenter.currentWorkspace?.id
                        )))
                        .accessibilityIdentifier("sidebar.workbench.new_task")
                }
                if !environment.workspaceCenter.workspaces.isEmpty {
                    Section("workspace.title") {
                        ForEach(environment.workspaceCenter.workspaces) { workspace in
                            Label(workspace.name, systemImage: "folder")
                                .tag(SidebarSelection.workbench(.workspace(workspace.id)))
                                .accessibilityIdentifier("sidebar.workspace.\(workspace.id.uuidString)")
                        }
                    }
                }
                if !environment.conversationCenter.conversations.isEmpty {
                    Section("home.recent") {
                        ForEach(environment.conversationCenter.conversations) { conversation in
                            Label(
                                conversation.title.isEmpty
                                    ? String(localized: "chat.untitled")
                                    : conversation.title,
                                systemImage: "bubble.left"
                            )
                            .lineLimit(1)
                            .tag(SidebarSelection.workbench(.conversation(conversation.id)))
                            .accessibilityIdentifier("sidebar.conversation.\(conversation.id.uuidString)")
                        }
                        .onDelete { offsets in
                            let conversations = environment.conversationCenter.conversations
                            let targets = offsets.compactMap {
                                conversations.indices.contains($0) ? conversations[$0].id : nil
                            }
                            Task {
                                for id in targets {
                                    try? await environment.conversationCenter.deleteConversation(id: id)
                                }
                            }
                        }
                    }
                }
                Section {
                    ForEach([AppDestination.files, .browser, .hosts, .more]) { destination in
                        Label(destination.title, systemImage: destination.systemImage)
                            .tag(SidebarSelection.primary(destination))
                            .accessibilityIdentifier("sidebar.primary.\(destination.rawValue)")
                    }
                }
                Section("sidebar.section.more") {
                    ForEach(MoreDestination.visibleCases) { sub in
                        Label(sub.title, systemImage: sub.systemImage)
                            .tag(SidebarSelection.more(sub))
                            .accessibilityIdentifier("sidebar.more.\(sub.rawValue)")
                    }
                }
            }
            .navigationTitle("app.name")
            .task {
                await environment.conversationCenter.reload()
                await environment.workspaceCenter.reload()
            }
            .onChange(of: router.sidebarSelection) { _, selection in
                applySidebarSelection(selection)
            }
        } content: {
            contentColumn
        } detail: {
            detailColumn
        }
    }

    /// Column 2 renders the canonical workbench selection or the selected
    /// primary/More destination.
    @ViewBuilder
    private var contentColumn: some View {
        switch router.sidebarSelection ?? .workbench(router.workbenchSelection) {
        case .workbench(let selection):
            switch selection {
            case .overview:
                HomeOverviewView(center: environment.conversationCenter)
            case .newTask(let workspaceID):
                NavigationStack {
                    HomeLaunchpadView(
                        center: environment.conversationCenter,
                        workspaceID: workspaceID
                    )
                }
            case .workspace(let workspaceID):
                NavigationStack {
                    HomeLaunchpadView(
                        center: environment.conversationCenter,
                        workspaceID: workspaceID
                    )
                }
            case .conversation(let conversationID):
                NavigationStack {
                    ThreadDetailView(
                        conversationID: conversationID,
                        center: environment.conversationCenter
                    )
                }
                .id(conversationID)
            }
        case .primary(let destination):
            if destination == .home || destination == .chat {
                HomeOverviewView(center: environment.conversationCenter)
            } else {
                PrimaryDestinationView(destination, environment: environment)
            }
        case .more(let sub):
            MoreListView(selection: sub)
        }
    }

    /// Column 3 projects the current selection into a stable work surface.
    /// When the inspector is requested, it replaces
    /// the detail content on demand — the column never idles as an empty
    /// placeholder once content exists.
    @ViewBuilder
    private var detailColumn: some View {
        if let inspectorContent = router.inspectorContent {
            InspectorColumnView(content: inspectorContent)
        } else {
            switch router.sidebarSelection ?? .workbench(router.workbenchSelection) {
            case .workbench(let selection):
                switch selection {
                case .overview:
                    NavigationStack {
                        HomeLaunchpadView(center: environment.conversationCenter)
                    }
                case .newTask(_), .workspace(_), .conversation(_):
                    HomeOverviewView(center: environment.conversationCenter)
                }
            case .primary(.home), .primary(.chat):
                HomeOverviewView(center: environment.conversationCenter)
            default:
                ShellPlaceholderView(
                    title: LocalizedStringKey("app.name"),
                    systemImage: "sidebar.right",
                    messageKey: "empty.detail"
                )
            }
        }
    }

    private func applySidebarSelection(_ selection: SidebarSelection?) {
        guard let selection else { return }
        switch selection {
        case .workbench(.overview):
            router.showOverview()
        case .workbench(.newTask(let workspaceID)):
            router.startNewTask(workspaceID: workspaceID)
        case .workbench(.workspace(let workspaceID)):
            router.selectWorkspace(workspaceID)
            Task { try? await environment.workspaceCenter.openWorkspace(id: workspaceID) }
        case .workbench(.conversation(let conversationID)):
            router.workbenchSelection = .conversation(conversationID)
            router.workbenchPath = [conversationID]
            router.selection = .home
        case .primary(let destination):
            router.navigate(to: destination)
        case .more(let destination):
            router.openMore(destination)
        }
    }
}

/// The on-demand inspector column (iPad third column / iPhone sheet).
/// T05: renders the real workspace file inspector through WorkspaceCenter.
private struct InspectorColumnView: View {
    let content: AppRouter.InspectorContent
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        switch content {
        case .workspaceFiles:
            FileInspectorView(center: environment.workspaceCenter)
                .background(FloeTheme.readingSurface)
        }
    }
}

/// Routes a primary destination to its root screen. Every root is a real
/// navigation-titled screen with a localized empty state — never a promise
/// of a future milestone.
private struct PrimaryDestinationView: View {
    let destination: AppDestination
    let environment: AppEnvironment

    init(_ destination: AppDestination, environment: AppEnvironment) {
        self.destination = destination
        self.environment = environment
    }

    var body: some View {
        switch destination {
        case .home:
            HomeLaunchpadView(center: environment.conversationCenter)
        case .chat:
            ConversationListView(center: environment.conversationCenter)
        case .files:
            FilesView(center: environment.filesCenter)
        case .browser:
            BrowserView(center: environment.browserCenter)
        case .hosts:
            HostListView(center: environment.remoteSessionCenter)
        case .more:
            MoreView(center: environment.conversationCenter)
        }
    }
}

/// iPad Chat detail with nothing selected: quiet empty state plus a real
/// "new conversation" entry. Never the Home launchpad.
private struct ChatDetailEmptyView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        ContentUnavailableView {
            Label("tab.chat", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("chat.select_or_new")
        } actions: {
            Button("chat.new") {
                Task {
                    if let conversation = try? await environment.conversationCenter
                        .createConversation(title: nil) {
                        router.openConversation(conversation.id)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: FloeTheme.minimumTarget)
            .accessibilityIdentifier("chat.detail.new")
        }
        .background(FloeTheme.readingSurface)
        .navigationTitle("tab.chat")
    }
}

/// The More list: Runs, Providers, Settings, Privacy, and (DEBUG only)
/// Diagnostics. As the iPhone More tab root it pushes sub-screens; as the
/// iPad content column it renders the sidebar-selected section directly.
private struct MoreListView: View {
    /// When set (iPad content column), that section's screen is embedded
    /// here; when nil (iPhone More tab), the full list pushes sub-screens.
    let selection: MoreDestination?

    var body: some View {
        if let selection {
            MoreDestinationView(selection)
        } else {
            List {
                ForEach(MoreDestination.visibleCases) { sub in
                    NavigationLink(value: sub) {
                        Label(sub.title, systemImage: sub.systemImage)
                    }
                }
            }
            .navigationTitle("tab.more")
            .navigationDestination(for: MoreDestination.self) { sub in
                MoreDestinationView(sub)
            }
        }
    }
}

/// Routes a More sub-destination to its real screen.
private struct MoreDestinationView: View {
    let sub: MoreDestination

    @EnvironmentObject private var environment: AppEnvironment

    init(_ sub: MoreDestination) {
        self.sub = sub
    }

    var body: some View {
        switch sub {
        case .runs:
            RunsHistoryView(viewModel: MoreViewModel(center: environment.conversationCenter))
        case .setupGuide:
            SetupGuideLauncherView()
        case .providers:
            ProviderListView(center: environment.conversationCenter)
        case .auxiliaryModels:
            AuxiliaryModelsView(center: environment.conversationCenter)
        case .skills:
            SkillsView(center: environment.skillsCenter)
        case .memory:
            MemoryView(center: environment.memoryCenter)
        case .settings:
            SettingsRootView()
        case .privacy:
            PrivacyView()
        case .diagnostics:
            DiagnosticsAboutView(center: environment.settingsCenter)
        }
    }
}

/// A structural empty state used when the split view has no selected detail.
private struct ShellPlaceholderView: View {
    let title: LocalizedStringKey
    let systemImage: String
    let messageKey: LocalizedStringKey

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(messageKey)
        }
        .background(FloeTheme.readingSurface)
        .navigationTitle(title)
    }
}

#endif
