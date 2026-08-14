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
    @State private var showOnboarding = false

    var body: some View {
        Group {
            if !environment.persistenceReady {
                persistenceState
            } else if horizontalSizeClass == .regular {
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
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(center: environment.conversationCenter)
                .interactiveDismissDisabled()
                .presentationSizing(.form)
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
        await environment.conversationCenter.reload()
        if !environment.conversationCenter.hasConfiguredProvider {
            showOnboarding = true
        }
    }

    // MARK: - iPhone: five locked tabs

    private var iPhoneRoot: some View {
        TabView(selection: $router.selection) {
            ForEach(AppDestination.allCases) { destination in
                Tab(value: destination) {
                    if destination == .chat {
                        NavigationStack(path: $router.chatPath) {
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
    }

    // MARK: - iPad: three-column split view

    private var iPadRoot: some View {
        NavigationSplitView(columnVisibility: $router.columnVisibility) {
            List(selection: $router.sidebarSelection) {
                Section {
                    ForEach(AppDestination.allCases) { destination in
                        Label(destination.title, systemImage: destination.systemImage)
                            .tag(SidebarSelection.primary(destination))
                    }
                }
                Section("sidebar.section.more") {
                    ForEach(MoreDestination.visibleCases) { sub in
                        Label(sub.title, systemImage: sub.systemImage)
                            .tag(SidebarSelection.more(sub))
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

    /// Column 2: the list for the sidebar selection. Tab roots that are
    /// themselves lists render here directly; everything else lists its
    /// More sub-destinations.
    @ViewBuilder
    private var contentColumn: some View {
        switch router.sidebarSelection ?? .primary(router.selection) {
        case .primary(let destination):
            PrimaryDestinationView(destination, environment: environment)
        case .more(let sub):
            MoreListView(selection: sub)
        }
    }

    /// Column 3 projects the current selection into a stable work surface.
    @ViewBuilder
    private var detailColumn: some View {
        switch router.sidebarSelection ?? .primary(router.selection) {
        case .primary(.home):
            HomeOverviewDetailView()
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
                ShellPlaceholderView(
                    title: LocalizedStringKey("tab.chat"),
                    systemImage: "bubble.left.and.bubble.right",
                    messageKey: "empty.detail"
                )
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
            HomeWorkbenchView(center: environment.conversationCenter)
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

/// Routes a More sub-destination to its screen. Providers and Diagnostics
/// are real screens today (provider management lands in T03; diagnostics is
/// the committed M0 validation UI); the rest are honest empty states.
private struct MoreDestinationView: View {
    let sub: MoreDestination

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var environment: AppEnvironment

    init(_ sub: MoreDestination) {
        self.sub = sub
    }

    var body: some View {
        switch sub {
        case .runs:
            ShellPlaceholderView(
                title: sub.title,
                systemImage: sub.systemImage,
                messageKey: "empty.runs"
            )
        case .providers:
            ProviderListView(center: environment.conversationCenter)
        case .settings:
            ShellPlaceholderView(
                title: sub.title,
                systemImage: sub.systemImage,
                messageKey: "empty.settings"
            )
        case .privacy:
            ShellPlaceholderView(
                title: sub.title,
                systemImage: sub.systemImage,
                messageKey: "empty.privacy"
            )
        case .diagnostics:
#if DEBUG
            M0DiagnosticsView(model: router.diagnostics)
#else
            ShellPlaceholderView(
                title: sub.title,
                systemImage: sub.systemImage,
                messageKey: "empty.diagnostics"
            )
#endif
        }
    }
}

/// A structural placeholder: a real screen with a navigation title, an SF
/// Symbol and a localized empty state on an opaque reading surface.
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
