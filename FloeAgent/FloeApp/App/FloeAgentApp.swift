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

    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                iPadRoot
            } else {
                iPhoneRoot
            }
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            router.handleScenePhase(newPhase)
        }
    }

    // MARK: - iPhone: five locked tabs

    private var iPhoneRoot: some View {
        TabView(selection: $router.selection) {
            ForEach(AppDestination.allCases) { destination in
                Tab(value: destination) {
                    NavigationStack { PrimaryDestinationView(destination, environment: environment) }
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

    /// Column 3: the selected thread / terminal / document. T02–T05 push
    /// real content here; for now it is an honest empty state.
    private var detailColumn: some View {
        ShellPlaceholderView(
            title: LocalizedStringKey("app.name"),
            systemImage: "sidebar.right",
            messageKey: "empty.detail"
        )
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
            ShellPlaceholderView(
                title: destination.title,
                systemImage: destination.systemImage,
                messageKey: "empty.home"
            )
        case .chat:
            ConversationListView(center: environment.conversationCenter)
        case .files:
            ShellPlaceholderView(
                title: destination.title,
                systemImage: destination.systemImage,
                messageKey: "empty.files"
            )
        case .hosts:
            ShellPlaceholderView(
                title: destination.title,
                systemImage: destination.systemImage,
                messageKey: "empty.hosts"
            )
        case .more:
            MoreListView(selection: nil)
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
            ShellPlaceholderView(
                title: sub.title,
                systemImage: sub.systemImage,
                messageKey: "empty.providers"
            )
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
