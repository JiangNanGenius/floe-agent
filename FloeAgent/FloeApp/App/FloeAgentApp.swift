// FloeApp — SwiftUI app entry point (iOS/iPadOS only).
// iPhone uses a compact TabView; iPad uses NavigationSplitView with
// multi-scene support. Concrete views land in M2; M1 ships the navigation
// skeleton and background-policy wiring only.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

@main
struct FloeAgentApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
        }
    }
}

/// Destinations shared by both idioms: Home, Chat, Files, Hosts, Runs,
/// Settings.
enum AppDestination: String, Hashable, CaseIterable, Identifiable {
    case home, chat, files, hosts, runs, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .chat: "Chat"
        case .files: "Files"
        case .hosts: "Hosts"
        case .runs: "Runs"
        case .settings: "Settings"
        }
    }
}

/// App-wide observable model; M1 holds only the selected destination and
/// the background policy handle.
@MainActor
final class AppModel: ObservableObject {
    @Published var selection: AppDestination = .home

    /// Runtime-selected background policy (see Platform/).
    let backgroundPolicy: any PlatformBackgroundPolicy

    init() {
        if UIDevice.current.userInterfaceIdiom == .pad {
            backgroundPolicy = iPadBackgroundPolicy()
        } else {
            backgroundPolicy = iPhoneBackgroundPolicy()
        }
        BackgroundPolicyRegistry.shared.install(backgroundPolicy)
        backgroundPolicy.registerTasks()
    }
}

/// Idiom-adaptive root: TabView on iPhone, NavigationSplitView on iPad.
struct RootView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneID = UUID().uuidString

    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                iPadRoot
            } else {
                iPhoneRoot
            }
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            appModel.backgroundPolicy.handleScenePhase(
                policyPhase(for: newPhase),
                sceneID: sceneID
            )
        }
    }

    private var iPhoneRoot: some View {
        TabView(selection: $appModel.selection) {
            ForEach(AppDestination.allCases) { destination in
                PlaceholderView(title: destination.title)
                    .tabItem { Label(destination.title, systemImage: icon(for: destination)) }
                    .tag(destination)
            }
        }
    }

    private var iPadRoot: some View {
        NavigationSplitView {
            List {
                ForEach(AppDestination.allCases) { destination in
                    Button {
                        appModel.selection = destination
                    } label: {
                        Label(destination.title, systemImage: icon(for: destination))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        appModel.selection == destination
                            ? Color.accentColor.opacity(0.14)
                            : Color.clear
                    )
                    .accessibilityAddTraits(
                        appModel.selection == destination ? .isSelected : []
                    )
                }
            }
            .navigationTitle("Floe Agent")
        } detail: {
            PlaceholderView(title: appModel.selection.title)
        }
    }

    private func icon(for destination: AppDestination) -> String {
        switch destination {
        case .home: return "house"
        case .chat: return "bubble.left.and.bubble.right"
        case .files: return "folder"
        case .hosts: return "server.rack"
        case .runs: return "play.rectangle"
        case .settings: return "gearshape"
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

/// M1 placeholder; real screens arrive in M2.
struct PlaceholderView: View {
    let title: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: "hammer",
            description: Text("This screen is implemented in M2.")
        )
        .navigationTitle(title)
    }
}
#endif
