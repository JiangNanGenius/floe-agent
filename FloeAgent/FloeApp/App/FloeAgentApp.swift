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
import FloeCore
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
                .environmentObject(environment.speechService)
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
    @GestureState private var phoneDrawerTranslation: CGFloat = 0
    /// Global frame of the sidebar's scrollable `List`, used to distinguish a
    /// left-swipe on a row (swipe actions) from a left-swipe outside the list
    /// (dismiss the drawer).
    @State private var sidebarListFrame: CGRect = .zero
    @State private var showingAutomaticScreenShare = false

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
                // Persist the diagnostics ring buffer before suspension so a
                // crash or relaunch never loses the most recent evidence.
                FloeLogger.buffer.flush()
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
            // Refresh the complete settings snapshot (including probes) after
            // the launch-critical values were restored during bootstrap.
            await environment.settingsCenter.load()
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
        .onReceive(environment.screenShareCenter.$requestedConversationID) { conversationID in
            guard let conversationID,
                  environment.screenShareCenter.consumeBroadcastRequest(for: conversationID) else { return }
            FloeLogger(category: .app).info(
                "screenShareSheetPresentationRequested conversation=\(conversationID.uuidString)"
            )
            showingAutomaticScreenShare = true
        }
        .onReceive(environment.screenShareCenter.$isSharing) { isSharing in
            if isSharing { showingAutomaticScreenShare = false }
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
        .sheet(isPresented: $showingAutomaticScreenShare) {
            BroadcastPickerView(center: environment.screenShareCenter)
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
        .preferredColorScheme(resolvedColorScheme)
        .environment(\.locale, resolvedLocale)
    }

    /// Maps the appearance preference to a concrete color scheme (nil = follow
    /// the system).
    private var resolvedColorScheme: ColorScheme? {
        switch environment.settingsCenter.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Maps the language override to a concrete locale (autoupdating follows
    /// the system language).
    private var resolvedLocale: Locale {
        switch environment.settingsCenter.languageOverride {
        case .system: return .autoupdatingCurrent
        case .en: return Locale(identifier: "en")
        case .zhHans: return Locale(identifier: "zh-Hans")
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
            let drawerWidth = min(390, max(300, proxy.size.width - 44))
            let baseOffset = isPhoneSidebarOpen ? CGFloat.zero : -drawerWidth
            let interactiveOffset = min(0, max(-drawerWidth, baseOffset + phoneDrawerTranslation))
            let drawerProgress = 1 - abs(interactiveOffset / drawerWidth)
            ZStack(alignment: .leading) {
                contentColumn
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(1 - drawerProgress * 0.025, anchor: .trailing)
                    .offset(x: drawerProgress * 18)
                    .clipShape(.rect(cornerRadius: drawerProgress * 22))
                    .overlay(alignment: .topLeading) {
                        if drawerProgress == 0 {
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

                if drawerProgress > 0 {
                    Color.black.opacity(0.22 * drawerProgress)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.snappy) { isPhoneSidebarOpen = false } }
                        .accessibilityLabel("收起任务列表")
                }

                sidebarColumn
                    .frame(width: drawerWidth)
                    .frame(maxHeight: .infinity)
                    .background(FloeTheme.readingSurface.ignoresSafeArea())
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .offset(x: interactiveOffset)
                    .shadow(color: .black.opacity(0.18 * drawerProgress), radius: 24, x: 8)
                    .accessibilityIdentifier("phone.sidebar.drawer")

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
            // Respect the top safe area so the navigation bar (and the
            // drawer's "Floe Agent" title) never collides with the system
            // status-bar clock. Overlay scrims and drawer backgrounds still
            // extend behind the status bar via their own .ignoresSafeArea().
            .animation(.snappy, value: isPhoneSidebarOpen)
            .animation(.snappy, value: router.inspectorRoute)
            .contentShape(Rectangle())
            .simultaneousGesture(phoneDrawerGesture(drawerWidth: drawerWidth))
        }
        .onPreferenceChange(SidebarListFramePreferenceKey.self) { frame in
            sidebarListFrame = frame
        }
        .onChange(of: router.workbenchSelection) { _, _ in
            withAnimation(.snappy) { isPhoneSidebarOpen = false }
        }
    }

    private func phoneDrawerGesture(drawerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($phoneDrawerTranslation) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if isPhoneSidebarOpen, !sidebarListFrame.contains(value.startLocation) {
                    state = min(0, value.translation.width)
                } else if value.startLocation.x < 28, router.inspectorRoute == nil {
                    state = max(0, value.translation.width)
                }
            }
            .onEnded { value in
                let horizontal = value.translation.width
                let predicted = value.predictedEndTranslation.width
                guard abs(horizontal) > abs(value.translation.height) else { return }
                if !isPhoneSidebarOpen,
                   value.startLocation.x < 28,
                   router.inspectorRoute == nil,
                   max(horizontal, predicted) > drawerWidth * 0.22 {
                    withAnimation(.snappy) { isPhoneSidebarOpen = true }
                } else if isPhoneSidebarOpen,
                          !sidebarListFrame.contains(value.startLocation),
                          min(horizontal, predicted) < -drawerWidth * 0.22 {
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
            .background(GeometryReader { geo in
                Color.clear.preference(
                    key: SidebarListFramePreferenceKey.self,
                    value: geo.frame(in: .global)
                )
            })
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
            NavigationStack {
                MemoryView(center: environment.memoryCenter)
            }
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

/// Reports the global frame of the sidebar `List`. The iPhone drawer's
/// left-swipe dismiss gesture consults this frame so a swipe that starts on a
/// list row keeps its native swipe actions (delete/archive) instead of also
/// dragging the drawer closed.
private struct SidebarListFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

#endif
