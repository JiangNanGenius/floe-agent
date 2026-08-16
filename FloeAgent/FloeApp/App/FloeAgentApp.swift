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
import AVFoundation
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
    @State private var deletingConversation: ConversationRecord?
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail
    @State private var isPhoneSidebarOpen = false

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
            if newPhase != .active {
                environment.voiceInput.handleInterruption(reason: .interrupted)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) {
            environment.voiceInput.handleAudioInterruption($0)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) {
            environment.voiceInput.handleAudioRouteChange($0)
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
        .onChange(of: environment.browserCenter.presentationRequestID) { _, _ in
            // Browser and preview tools run outside the view hierarchy. Their
            // presentation request is projected through the shared router so
            // the visible WKWebView appears in the current task inspector.
            router.showInspector(.browser)
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
        .sheet(isPresented: $router.presentedSettings) {
            NavigationStack { SettingsRootView() }
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
        .alert("删除任务？", isPresented: Binding(
            get: { deletingConversation != nil },
            set: { if !$0 { deletingConversation = nil } }
        )) {
            Button("取消", role: .cancel) { deletingConversation = nil }
            Button("删除", role: .destructive) {
                guard let target = deletingConversation else { return }
                deletingConversation = nil
                Task { try? await environment.conversationCenter.deleteConversation(id: target.id) }
            }
        } message: {
            Text("任务、私有工作区和临时凭据将被删除，此操作不可撤销。")
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
        GeometryReader { proxy in
            let drawerWidth = min(360, max(280, proxy.size.width - 44))
            ZStack(alignment: .leading) {
                contentColumn
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .offset(x: isPhoneSidebarOpen ? drawerWidth : 0)
                    .overlay(alignment: .topLeading) {
                        if !isPhoneSidebarOpen {
                            Button { withAnimation(.snappy) { isPhoneSidebarOpen = true } } label: {
                                Image(systemName: "sidebar.left")
                                    .frame(width: 44, height: 44)
                                    .background(.regularMaterial, in: Circle())
                            }
                            .padding(.leading, 8)
                            .padding(.top, 4)
                            .accessibilityLabel("打开任务列表")
                            .accessibilityIdentifier("phone.sidebar.open")
                        }
                    }

                sidebarColumn
                    .frame(width: drawerWidth, height: proxy.size.height)
                    .background(FloeTheme.readingSurface)
                    .offset(x: isPhoneSidebarOpen ? 0 : -drawerWidth)
                    .shadow(radius: isPhoneSidebarOpen ? 12 : 0)

                if isPhoneSidebarOpen {
                    Color.clear
                        .frame(width: 44)
                        .contentShape(Rectangle())
                        .offset(x: drawerWidth)
                        .onTapGesture { withAnimation(.snappy) { isPhoneSidebarOpen = false } }
                        .accessibilityLabel("收起任务列表")
                }

                if let route = router.inspectorRoute {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture { router.hideInspector() }
                    NavigationStack { InspectorColumnView(route: route) }
                        .frame(width: drawerWidth, height: proxy.size.height)
                        .background(FloeTheme.readingSurface)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.move(edge: .trailing))
                        .shadow(radius: 12)
                        .accessibilityIdentifier("phone.inspector.drawer")
                }
            }
            .clipped()
            .animation(.snappy, value: isPhoneSidebarOpen)
            .animation(.snappy, value: router.inspectorRoute)
            .contentShape(Rectangle())
            .simultaneousGesture(phoneDrawerGesture(drawerWidth: drawerWidth))
        }
        .onChange(of: router.workbenchSelection) { _, _ in
            withAnimation(.snappy) { isPhoneSidebarOpen = false }
        }
    }

    private func phoneDrawerGesture(drawerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .global)
            .onEnded { value in
                let horizontal = value.translation.width
                guard abs(horizontal) > abs(value.translation.height), abs(horizontal) > 54 else { return }
                if horizontal > 0, value.startLocation.x < 28, router.inspectorRoute == nil {
                    withAnimation(.snappy) { isPhoneSidebarOpen = true }
                } else if horizontal < 0, isPhoneSidebarOpen {
                    withAnimation(.snappy) { isPhoneSidebarOpen = false }
                } else if horizontal > 0, router.inspectorRoute != nil {
                    router.hideInspector()
                }
            }
    }

    // MARK: - iPad: task surface with an on-demand inspector

    @ViewBuilder
    private var iPadRoot: some View {
        if let inspectorRoute = router.inspectorRoute {
            NavigationSplitView(columnVisibility: $router.columnVisibility) {
                sidebarColumn
            } content: {
                contentColumn
            } detail: {
                InspectorColumnView(route: inspectorRoute)
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
                    router.presentedSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("more.settings")
                .accessibilityIdentifier("sidebar.settings")
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
                deletingConversation = conversation
            } label: {
                Label("删除任务", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { try? await environment.conversationCenter.archiveConversation(id: conversation.id) }
            } label: { Label("归档", systemImage: "archivebox") }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { deletingConversation = conversation } label: {
                Label("删除", systemImage: "trash")
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
    let route: AppRouter.InspectorRoute
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        Group {
        switch route.content {
        case .changes:
            TaskChangesInspectorView(conversationID: route.conversationID)
        case .workspaceFiles:
            FileInspectorView(center: environment.workspaceCenter)
                .background(FloeTheme.readingSurface)
        case .browser:
            BrowserView(center: environment.browserCenter)
        case .terminal:
            HostListView(center: environment.remoteSessionCenter)
        case .progress:
            TaskProgressInspectorView(conversationID: route.conversationID)
        case .childAgents:
            ChildAgentsInspectorView(conversationID: route.conversationID)
        case .permissions:
            TaskPermissionsInspectorView(conversationID: route.conversationID)
        }
        }
        .task(id: route.id) {
            let conversationID = route.conversationID
            switch route.content {
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

/// The More list: Runs, Providers, Settings, and Diagnostics. As the iPhone
/// More tab root it pushes sub-screens; as the
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
