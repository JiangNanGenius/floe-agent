// FloeApp — SwiftUI app entry point (iOS/iPadOS only).
//
// SPDX-License-Identifier: MPL-2.0
//
// iPhone shows exactly five locked tabs (Home, Chat, Files, Hosts, More) in
// a TabView; iPad shows a three-column NavigationSplitView with a functional
// sidebar, a content column, and a detail column. Both idioms are driven by
// one AppRouter so navigation state and scene-phase background-policy
// wiring are shared. Feature screens land in T02–T05; the tab roots below
// are honest structural placeholders with localized empty states.

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
            await presentOnboardingIfNeeded()
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
                    // Home and Chat own separate navigation stacks so
                    // starting a task never pollutes the Chat list's back
                    // behavior and vice versa.
                    if destination == .chat {
                        NavigationStack(path: $router.chatPath) {
                            PrimaryDestinationView(destination, environment: environment)
                        }
                    } else if destination == .home {
                        NavigationStack(path: $router.homePath) {
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
                    ForEach(AppDestination.allCases) { destination in
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
        } content: {
            contentColumn
        } detail: {
            detailColumn
        }
    }

    /// Column 2: the list for the sidebar selection. Home owns a task
    /// overview (never the conversation-history list); Chat owns the
    /// conversation list with its own selection; everything else renders
    /// its root screen or the More sub-destination.
    @ViewBuilder
    private var contentColumn: some View {
        switch router.sidebarSelection ?? .primary(router.selection) {
        case .primary(let destination):
            if destination == .home {
                HomeOverviewView(center: environment.conversationCenter)
            } else {
                PrimaryDestinationView(destination, environment: environment)
            }
        case .more(let sub):
            MoreListView(selection: sub)
        }
    }

    /// Column 3 projects the current selection into a stable work surface.
    /// When the inspector is requested (T03 router surface), it replaces
    /// the detail content on demand — the column never idles as an empty
    /// placeholder once content exists.
    ///
    /// Home and Chat project from SEPARATE selection state: Home shows the
    /// thread it started (or the launchpad), Chat shows the conversation
    /// selected in its own list (or a quiet empty state). Neither renders
    /// the other's root.
    @ViewBuilder
    private var detailColumn: some View {
        if let inspectorContent = router.inspectorContent {
            InspectorColumnView(content: inspectorContent)
        } else {
            switch router.sidebarSelection ?? .primary(router.selection) {
            case .primary(.home):
                if let conversationID = router.homeDetailConversationID {
                    NavigationStack {
                        ThreadDetailView(
                            conversationID: conversationID,
                            center: environment.conversationCenter
                        )
                    }
                    .id(conversationID)
                } else {
                    NavigationStack {
                        HomeLaunchpadView(center: environment.conversationCenter)
                    }
                }
            case .primary(.chat):
                if let conversationID = router.selectedConversationID {
                    NavigationStack {
                        ThreadDetailView(
                            conversationID: conversationID,
                            center: environment.conversationCenter
                        )
                    }
                    .id(conversationID)
                } else {
                    // A quiet empty state plus a real new-conversation
                    // entry — never the Home launchpad.
                    ChatDetailEmptyView()
                }
            default:
                ShellPlaceholderView(
                    title: LocalizedStringKey("app.name"),
                    systemImage: "sidebar.right",
                    messageKey: "empty.detail"
                )
            }
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

// MARK: - Placeholder screens (replaced by T02–T05)

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
