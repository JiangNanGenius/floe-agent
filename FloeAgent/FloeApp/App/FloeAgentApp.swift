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
import FloeModels
import FloePersistence

@main
struct FloeAgentApp: App {
    @StateObject private var environment: AppEnvironment
    @StateObject private var router: AppRouter

    init() {
        let environment = AppEnvironment.live()
        let router = AppRouter()
        _environment = StateObject(wrappedValue: environment)
        _router = StateObject(wrappedValue: router)
        router.registerBackgroundTasksAtAppLaunch()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .environmentObject(router)
                .environmentObject(environment.voiceInput)
                .task { await environment.bootstrap() }
        }
    }
}

/// Idiom-adaptive root: a task-first sidebar workbench on both iPhone and
/// iPad. Scene-phase transitions are forwarded to
/// the router, which owns the background policy.
struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var expandedWorkspaceIDs: Set<UUID> = []
    @State private var renamingConversation: ConversationRecord?
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail

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
            await environment.conversationCenter.resumeSafeRunsAfterForeground()
            await environment.workspaceCenter.reload()
            await environment.backgroundRunCoordinator.reconcileSchedulesAfterLaunch()
            await presentOnboardingIfNeeded()
        }
        .onReceive(environment.conversationCenter.$conversations) { conversations in
            router.reconcileConversations(Set(conversations.map(\.id)))
        }
        .onReceive(NotificationCenter.default.publisher(for: .floeOpenConversation)) { notification in
            if let id = notification.userInfo?["conversationID"] as? UUID {
                router.openConversation(id)
            }
        }
        .sheet(item: $router.presentedSetup, onDismiss: markDismissedSetupSkipped) { _ in
            OnboardingView(center: environment.conversationCenter)
                .presentationSizing(.page)
        }
        .sheet(item: $renamingConversation) { conversation in
            TaskRenameSheet(conversation: conversation) { title in
                try await environment.conversationCenter.renameConversation(
                    id: conversation.id,
                    title: title
                )
            }
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

    // MARK: - iPhone: task workbench with a native sidebar drawer

    private var iPhoneRoot: some View {
        NavigationSplitView(
            columnVisibility: $router.columnVisibility,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            sidebarColumn
        } detail: {
            contentColumn
        }
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

    // MARK: - iPad: task surface with an on-demand inspector

    @ViewBuilder
    private var iPadRoot: some View {
        if let inspectorContent = router.inspectorContent {
            NavigationSplitView(columnVisibility: $router.columnVisibility) {
                sidebarColumn
            } content: {
                contentColumn
            } detail: {
                InspectorColumnView(content: inspectorContent)
            }
        } else {
            NavigationSplitView(columnVisibility: $router.columnVisibility) {
                sidebarColumn
            } detail: {
                contentColumn
            }
        }
    }

    /// Shared information architecture. NavigationSplitView projects this
    /// as a first column on iPad and a native drawer on iPhone.
    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            List(selection: $router.sidebarSelection) {
                Section {
                    Label("新建任务", systemImage: "square.and.pencil")
                        .tag(SidebarSelection.workbench(.newTask(workspaceID: nil)))
                        .accessibilityIdentifier("sidebar.workbench.new_task")
                    Label("任务中心", systemImage: "checklist")
                        .tag(SidebarSelection.workbench(.overview))
                        .accessibilityIdentifier("sidebar.task_center")
                    Label("skills.title", systemImage: "puzzlepiece.extension")
                        .tag(SidebarSelection.more(.skills))
                        .accessibilityIdentifier("sidebar.skills")
                }
                if !environment.workspaceCenter.projectWorkspaces.isEmpty {
                    Section("workspace.title") {
                        ForEach(environment.workspaceCenter.projectWorkspaces) { workspace in
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: { expandedWorkspaceIDs.contains(workspace.id) },
                                    set: { expanded in
                                        if expanded { expandedWorkspaceIDs.insert(workspace.id) }
                                        else { expandedWorkspaceIDs.remove(workspace.id) }
                                    }
                                )
                            ) {
                                ForEach(conversations(in: workspace.id)) { conversation in
                                    conversationSidebarRow(conversation)
                                }
                            } label: {
                                Button {
                                    router.startNewTask(workspaceID: workspace.id)
                                } label: {
                                    Label(workspace.name, systemImage: "folder")
                                }
                                .buttonStyle(.plain)
                            }
                            .accessibilityIdentifier("sidebar.workspace.\(workspace.id.uuidString)")
                        }
                    }
                }
                if !chatConversations.isEmpty {
                    Section("聊天") {
                        ForEach(chatConversations) { conversation in
                            conversationSidebarRow(conversation)
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                Label("账户", systemImage: "person.crop.circle")
                Spacer()
                Button {
                    router.openMore(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("more.settings")
            }
            .padding(.horizontal, 16)
        }
        .navigationTitle("app.name")
        .task {
            await environment.conversationCenter.reload()
            await environment.workspaceCenter.reload()
        }
        .onChange(of: router.sidebarSelection) { _, selection in
            applySidebarSelection(selection)
            preferredCompactColumn = .detail
        }
    }

    private func conversations(in workspaceID: UUID) -> [ConversationRecord] {
        environment.conversationCenter.conversations.filter {
            environment.workspaceCenter.workspaceID(for: $0.id) == workspaceID
        }
    }

    private var chatConversations: [ConversationRecord] {
        let privateIDs = Set(environment.workspaceCenter.workspaces
            .filter { $0.kind == .privateTask }.map(\.id))
        return environment.conversationCenter.conversations.filter {
            environment.workspaceCenter.workspaceID(for: $0.id).map(privateIDs.contains) == true
        }
    }

    private func conversationSidebarRow(_ conversation: ConversationRecord) -> some View {
        Label(
            conversation.title.isEmpty ? String(localized: "chat.untitled") : conversation.title,
            systemImage: "bubble.left"
        )
        .lineLimit(1)
        .tag(SidebarSelection.workbench(.conversation(conversation.id)))
        .accessibilityIdentifier("sidebar.conversation.\(conversation.id.uuidString)")
        .contextMenu {
            Button {
                renamingConversation = conversation
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button {
                router.openConversation(conversation.id)
                router.showInspector(.permissions)
            } label: {
                Label("任务权限", systemImage: "lock.shield")
            }
            Menu("移动到项目") {
                ForEach(environment.workspaceCenter.projectWorkspaces) { workspace in
                    Button(workspace.name) {
                        Task {
                            try? await environment.conversationCenter.moveConversation(
                                id: conversation.id,
                                to: workspace.id
                            )
                        }
                    }
                }
            }
            Button(role: .destructive) {
                Task { try? await environment.conversationCenter.deleteConversation(id: conversation.id) }
            } label: {
                Label("删除任务", systemImage: "trash")
            }
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
        Group {
        switch content {
        case .changes:
            TaskChangesInspectorView(conversationID: router.selectedConversationID)
        case .workspaceFiles:
            FileInspectorView(center: environment.workspaceCenter)
                .background(FloeTheme.readingSurface)
        case .browser:
            BrowserView(center: environment.browserCenter)
        case .terminal:
            HostListView(center: environment.remoteSessionCenter)
        case .progress:
            TaskProgressInspectorView(conversationID: router.selectedConversationID)
        case .childAgents:
            ChildAgentsInspectorView(conversationID: router.selectedConversationID)
        case .permissions:
            TaskPermissionsInspectorView(conversationID: router.selectedConversationID)
        }
        }
        .task(id: "\(content.rawValue)-\(router.selectedConversationID?.uuidString ?? "none")") {
            guard let conversationID = router.selectedConversationID else { return }
            switch content {
            case .changes, .workspaceFiles:
                try? await environment.workspaceCenter.openTaskWorkspace(
                    conversationID: conversationID
                )
            case .browser:
                environment.browserCenter.bind(to: conversationID)
            case .terminal, .progress, .childAgents, .permissions:
                break
            }
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

private struct TaskRenameSheet: View {
    let conversation: ConversationRecord
    let save: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(conversation: ConversationRecord, save: @escaping (String) async throws -> Void) {
        self.conversation = conversation
        self.save = save
        _title = State(initialValue: conversation.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("任务名称", text: $title)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(FloeTheme.destructive)
                }
            }
            .navigationTitle("重命名任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") {
                        Task {
                            isSaving = true
                            defer { isSaving = false }
                            do { try await save(title); dismiss() }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#endif
