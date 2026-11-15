// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeCore
import FloeGameCore
import FloeGameAuthoring
import FloeGameAuthoringUI
import FloeGameIDEBridge
import FloeGameProjectFlow
import FloeGameStarterKit
import FloeGameAppIntegration
import FloeWorkspace

/// Space's real game project screen. It hosts the already delivered
/// `GameProjectOverviewView` and routes its four primary actions to the
/// existing assistant, native quick editor, existing IDE and owned play
/// services. It never creates a second file tree or IDE.
struct GameProjectSpaceScreen: View {
    let record: PersonalContentRecord
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var session: GameWorkspaceSession?
    @State private var error: String?
    @State private var notice: String?
    @State private var loading = true
    @State private var pending: GameProjectOverviewAction?
    @State private var showingAssistant = false
    @State private var showingQuickEdit = false
    @State private var showingBuild = false
    @State private var showingDeploymentAssets = false
    @State private var showingHistory = false
    @State private var showingImporter = false
    @State private var showingEngineChange = false
    @State private var showingCreateStarter = false
    @State private var ideRequest: GameIDEOpenRequest?
    @State private var selectedEngine: GameEngineID?
    @State private var starterEngine: GameEngineID?
    @State private var starterError: String?
    @State private var resourceBusy = false
    @State private var resourceError: String?

    private var snapshot: GameProjectSelectionSnapshot? { session?.project.selectionSnapshot }
    private var project: GameStoredProject? { session?.project.project }

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    overview(session)
                } else if loading {
                    ProgressView(IDELanguageRunText.t("正在打开游戏", "Opening game"))
                } else {
                    ContentUnavailableView {
                        Label(IDELanguageRunText.t("无法打开游戏", "Unable to open game"),
                              systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error ?? IDELanguageRunText.t("工程不存在或已被移动。", "The project is unavailable or has moved."))
                    } actions: {
                        Button(IDELanguageRunText.t("重试", "Retry")) { Task { await load() } }
                    }
                }
            }
            .navigationTitle(record.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IDELanguageRunText.t("完成", "Done")) { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(IDELanguageRunText.t("构建／导出", "Build / export"), systemImage: "shippingbox") {
                        showingBuild = true
                    }.disabled(session == nil)
                    Button(IDELanguageRunText.t("助手", "Assistant"), systemImage: "sparkles") {
                        showingAssistant = true
                    }.disabled(session == nil)
                }
            }
            .task { await load() }
            .onAppear {
                environment.gameWorkspaces.navigation.handler = { request in
                    ideRequestBox = IDEOpenBox(request: request)
                }
            }
            .onDisappear {
                if environment.gameWorkspaces.navigation.handler != nil {
                    environment.gameWorkspaces.navigation.handler = nil
                }
            }
            .sheet(isPresented: $showingAssistant) {
                if let session, let record = session.record {
                    StudioAssistantView(record: record, onClose: { showingAssistant = false })
                        .environmentObject(environment)
                }
            }
            .fullScreenCover(isPresented: $showingQuickEdit) {
                if let session {
                    GameProjectQuickEditScreen(session: session)
                        .environmentObject(environment)
                }
            }
            .sheet(isPresented: $showingBuild) {
                if let session {
                    GameProjectBuildScreen(session: session)
                        .environmentObject(environment)
                }
            }
            .sheet(isPresented: $showingDeploymentAssets) {
                if let session { RPGDeploymentAssetsScreen(session: session) }
            }
            .sheet(isPresented: $showingHistory) {
                if let session {
                    GameProjectHistoryScreen(session: session)
                        .environmentObject(environment)
                }
            }
            .fullScreenCover(isPresented: $showingPlay) {
                if let session {
                    GameProjectPlayScreen(session: session)
                        .environmentObject(environment)
                }
            }
            .sheet(isPresented: $showingEngineChange) {
                if let session {
                    GameStarterCreationSheet(engine: session.project.selectionSnapshot?.selectedEngine
                        ?? session.project.project.engine ?? .godot, error: nil,
                        onCancel: { showingEngineChange = false },
                        onCreate: { engine in
                            showingEngineChange = false
                            Task { await convert(session, engine: engine) }
                        })
                        .environmentObject(environment)
                }
            }
            .sheet(isPresented: $showingCreateStarter) {
                if let session {
                    GameStarterCreationSheet(engine: starterEngine ?? .unassignedFallback,
                        error: starterError,
                        onCancel: { showingCreateStarter = false },
                        onCreate: { engine in
                            Task { await createStarter(session, engine: engine) }
                        })
                }
            }
            .fullScreenCover(item: $ideRequestBox) { box in
                GameProjectIDEPresentation(request: box.request, session: session,
                    environment: environment)
            }
            .fileImporter(isPresented: $showingImporter,
                allowedContentTypes: [.folder, .zip, .archive, .data, .item],
                allowsMultipleSelection: false) { result in
                Task { await importSource(result) }
            }
        }
    }

    /// Identifiable wrapper because the SDK request intentionally has no UI ID
    /// beyond its workspace identity.
    private struct IDEOpenBox: Identifiable {
        let id = UUID()
        let request: GameIDEOpenRequest
    }
    @State private var ideRequestBox: IDEOpenBox?

    @ViewBuilder private func overview(_ session: GameWorkspaceSession) -> some View {
        VStack(spacing: 0) {
            if let error { noticeBar(error, failed: true) }
            if let notice { noticeBar(notice, failed: false) }
            runtimeBanner(session)
            if snapshot?.requiresExplicitChoice == true {
                GameProjectSelectionChooser(snapshot: snapshot, library: environment.gameWorkspaces.library,
                    onSelect: { root, engine in await select(session, root: root, engine: engine) })
            }
            GameProjectOverviewView(content: content(session), pendingAction: pending,
                status: status(session)) { action in
                    perform(action, session: session)
                }
            Divider()
            secondaryActions(session)
        }
    }

    @ViewBuilder private func runtimeBanner(_ session: GameWorkspaceSession) -> some View {
        if let engine = session.project.selectionSnapshot?.selectedEngine
            ?? session.project.project.engine,
           let readiness = environment.gameWorkspaces.runtimeResources.readiness(for: engine) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: readiness.isReady
                          ? "checkmark.seal.fill" : "shippingbox")
                        .foregroundStyle(readiness.isReady ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(readiness.displayName).font(.callout.weight(.medium))
                        Text(readiness.statusText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if resourceBusy {
                        ProgressView(value: environment.gameWorkspaces.runtimeResources
                            .progress[readiness.packID] ?? 0)
                            .progressViewStyle(.linear)
                            .frame(width: 90)
                        Button(IDELanguageRunText.t("取消", "Cancel")) {
                            Task {
                                await environment.gameWorkspaces
                                    .cancelRuntimeResourcePreparation(for: engine)
                                resourceBusy = false
                            }
                        }.font(.caption)
                    }
                    if readiness.canDownload || readiness.canRetry {
                        Button {
                            Task { await downloadRuntime(for: engine, session: session) }
                        } label: {
                            if resourceBusy {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(readiness.canDownload
                                     ? IDELanguageRunText.t("下载", "Download")
                                     : IDELanguageRunText.t("重试", "Retry"))
                            }
                        }.buttonStyle(.bordered)
                            .disabled(resourceBusy)
                    }
                }
                if let resourceError {
                    Text(resourceError).font(.caption2).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
        }
    }

    private func downloadRuntime(for engine: GameEngineID,
                                 session: GameWorkspaceSession) async {
        resourceBusy = true
        resourceError = nil
        defer { resourceBusy = false }
        do {
            try await environment.gameWorkspaces.prepareRuntimeResource(
                for: engine, session: session)
        } catch is CancellationError {
            resourceError = nil
        } catch {
            resourceError = error.localizedDescription
        }
    }

    private func content(_ session: GameWorkspaceSession) -> GameProjectOverviewContent {
        let state = session.project.selectionSnapshot
        let project = session.project.project
        let engine = state?.selectedEngine ?? project.engine
        let engineName = engine?.rawValue ?? IDELanguageRunText.t("尚未选择引擎", "No engine selected")
        let summary: String
        if let state, let selected = state.selectedEngine {
            summary = engineName + " · " + (state.selectedRoot?.value ?? ".")
        } else if project.files.isEmpty {
            summary = IDELanguageRunText.t("空工程 · 选择引擎或导入已有工程", "Empty project · choose an engine or import")
        } else if state?.state == .ambiguous {
            summary = IDELanguageRunText.t("发现多个工程根／引擎，请选择", "Multiple roots/engines found. Choose one.")
        } else {
            summary = engineName
        }
        return GameProjectOverviewContent(title: project.title, engineSummary: summary,
            description: state?.aiRecommendation.map { "AI: \($0.rationale)" } ?? "",
            iconPNG: nil, previewPNG: nil, lastSaved: nil,
            hasFiles: !project.files.isEmpty)
    }

    private func status(_ session: GameWorkspaceSession) -> String? {
        if pending != nil { return IDELanguageRunText.t("正在处理…", "Working…") }
        if let snapshot = session.project.selectionSnapshot {
            if snapshot.state == .empty { return IDELanguageRunText.t("选择引擎后创建真实的起始文件。", "Choose an engine to create real starter files.") }
            if snapshot.state == .ambiguous { return IDELanguageRunText.t("请先选择根目录和引擎。", "Choose a root and engine first.") }
            if let recommendation = snapshot.aiRecommendation {
                return IDELanguageRunText.t("AI 建议：\(recommendation.engine.rawValue)，可手动采用或覆盖。", "AI suggests \(recommendation.engine.rawValue). You can use or override it.")
            }
            if let heuristic = snapshot.heuristicRecommendation {
                return IDELanguageRunText.t("识别结果：\(heuristic.engine.rawValue)（规则匹配，不是 AI）", "Recognized \(heuristic.engine.rawValue) (heuristic, not AI)")
            }
        }
        return nil
    }

    private func secondaryActions(_ session: GameWorkspaceSession) -> some View {
        HStack(spacing: 10) {
            Button(IDELanguageRunText.t("切换引擎（新副本）", "Change engine (new copy)"),
                   systemImage: "arrow.triangle.branch") {
                showingEngineChange = true
            }.buttonStyle(.bordered)
            if let engine = snapshot?.selectedEngine,
               [.rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce, .rpgMakerMV, .rpgMakerMZ].contains(engine) {
                Button(IDELanguageRunText.t("部署资源", "Deployment assets"), systemImage: "archivebox") {
                    showingDeploymentAssets = true
                }.buttonStyle(.bordered)
            }
            if session.project.project.files.isEmpty {
                Button(IDELanguageRunText.t("创建起始工程", "Create starter"), systemImage: "wand.and.stars") {
                    starterEngine = session.project.selectionSnapshot?.recordedEngine
                        ?? session.project.selectionSnapshot?.selectedEngine ?? .godot
                    starterError = nil
                    showingCreateStarter = true
                }.buttonStyle(.borderedProminent)
            }
            Spacer()
        }.padding(16)
    }

    /// Bind a real game environment before the assistant starts its first run.
    /// The assistant keeps its own private task workspace; only its execution
    /// location is the game-root session container. If a historical run exists
    /// without that binding, the tool remains usable for repository edits but
    /// play/build report the exact missing environment instead of rebinding
    /// historical work silently.
    private func prepareForAI(_ session: GameWorkspaceSession) async {
        do {
            if session.environmentID == nil {
                _ = try await environment.gameWorkspaces.prepareEnvironment(for: session, backend: .linuxVM)
            }
            showingAssistant = true
        } catch {
            self.error = error.localizedDescription
            showingAssistant = true
        }
    }

    private func perform(_ action: GameProjectOverviewAction, session: GameWorkspaceSession) {
        switch action {
        case .aiModify:
            Task { await prepareForAI(session) }
        case .simpleEdit:
            if session.project.selectionSnapshot?.selectedEngine == nil {
                notice = IDELanguageRunText.t("请先选择引擎。", "Choose an engine first.")
            } else {
                showingQuickEdit = true
            }
        case .ide:
            Task { await openIDE(session, destination: .files) }
        case .play:
            Task { await play(session) }
        case .files:
            Task { await openIDE(session, destination: .files) }
        case .history:
            showingHistory = true
        case .importProject:
            showingImporter = true
        }
    }

    private func openIDE(_ session: GameWorkspaceSession, destination: GameIDEDestination) async {
        do {
            pending = .ide
            defer { pending = nil }
            // Opening the IDE must not depend on a play environment or a saved
            // assistant run. The existing WorkspaceIDEView is shown first; its
            // optional Run extension resolves separately and reports any real
            // missing prerequisite there.
            try await session.project.prepareForHandoff()
            try Task.checkCancellation()
            guard let workspace = session.center.currentWorkspace else {
                throw GameIDEBridgeError.workspaceChanged
            }
            let pin = try GameIDEWorkspacePin(workspaceID: workspace.id,
                context: try session.project.context)
            let request = GameIDEOpenRequest(workspace: pin, destination: destination)
            ideRequestBox = IDEOpenBox(request: request)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func play(_ session: GameWorkspaceSession) async {
        guard let engine = session.project.selectionSnapshot?.selectedEngine else {
            notice = IDELanguageRunText.t("请先选择引擎。", "Choose an engine first.")
            return
        }
        do {
            pending = .play
            defer { pending = nil }
            _ = try await environment.gameWorkspaces.ensurePlayableSession(for: session)
            let play = environment.gameWorkspaces.playCoordinator(for: session)
            _ = try await play.start()
            _ = engine
            guard play.isRunning else { throw GameWorkspaceRegistryError.noSavedRun }
            showingPlay = true
        } catch {
            self.error = error.localizedDescription
        }
    }
    @State private var showingPlay = false
    // Play is a full-screen presentation over the same owned session.
    // Declared here so the overview owns no second player.
    private var playPresentation: some View {
        Group {
            if let session {
                GameProjectPlayScreen(session: session)
                    .environmentObject(environment)
            }
        }
    }

    private func importSource(_ result: Result<[URL], Error>) async {
        do {
            guard let url = try result.get().first, let session else { return }
            pending = .importProject
            defer { pending = nil }
            try await environment.gameWorkspaces.importSource(url, into: session)
            notice = IDELanguageRunText.t("已导入完整工程文件。", "The complete project tree was imported.")
            await refresh(session)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func select(_ session: GameWorkspaceSession, root: GameRelativePath?, engine: GameEngineID) async {
        do {
            pending = .simpleEdit
            defer { pending = nil }
            try await session.project.select(root: root, engine: engine)
            notice = IDELanguageRunText.t("已选择 \(engine.rawValue)。", "Selected \(engine.rawValue).")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createStarter(_ session: GameWorkspaceSession, engine: GameEngineID) async {
        do {
            pending = .simpleEdit
            defer { pending = nil }
            if [GameEngineID.phaser, .kaplay, .babylon, .playcanvas].contains(engine) {
                _ = try environment.gameWorkspaces.runtimeResources.requireReady(engine)
            }
            try await session.project.initializeStarter(engine: engine)
            showingCreateStarter = false
            starterError = nil
            notice = IDELanguageRunText.t("已创建真实起始文件。", "Created real starter files.")
        } catch {
            starterError = error.localizedDescription
            self.error = error.localizedDescription
        }
    }

    private func convert(_ session: GameWorkspaceSession, engine: GameEngineID) async {
        do {
            pending = .simpleEdit
            defer { pending = nil }
            let converted = try await environment.gameWorkspaces.makeEngineConversionCopy(
                source: session, title: session.record?.title ?? "Game", engine: engine)
            notice = IDELanguageRunText.t("已创建新副本。原工程未改变。", "A new copy was created. The original is unchanged.")
            _ = converted
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refresh(_ session: GameWorkspaceSession) async {
        do { try await session.project.refresh() }
        catch { self.error = error.localizedDescription }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let value = try await environment.gameWorkspaces.openSpaceGame(record: record)
            session = value
            try await value.project.refresh()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func noticeBar(_ text: String, failed: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(text).font(.callout)
            Spacer()
        }
        .foregroundStyle(failed ? Color.red : Color.secondary)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .accessibilityIdentifier("game.project.notice")
    }
}

extension GameEngineID {
    /// A neutral fallback used only for the empty starter picker. It never
    /// creates a project or gets persisted as a selection.
    static var unassignedFallback: GameEngineID { .godot }
}

/// Native catalog-backed starter picker. It lists exactly the bundled 20
/// engine descriptors and their real prerequisites. A runtime-pack starter is
/// offered but explicitly reports its missing prepared pack on failure.
struct GameStarterCreationSheet: View {
    let engine: GameEngineID
    let error: String?
    let onCancel: () -> Void
    let onCreate: (GameEngineID) -> Void
    @EnvironmentObject private var environment: AppEnvironment
    @State private var selected: GameEngineID

    init(engine: GameEngineID, error: String?, onCancel: @escaping () -> Void,
         onCreate: @escaping (GameEngineID) -> Void) {
        self.engine = engine
        self.error = error
        self.onCancel = onCancel
        self.onCreate = onCreate
        _selected = State(initialValue: engine)
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.callout)
                    }
                }
                Section(IDELanguageRunText.t("引擎", "Engine")) {
                    ForEach(environment.gameWorkspaces.library?.entries ?? []) { entry in
                        Button {
                            selected = entry.engine
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: selected == entry.engine ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.displayName)
                                    Text(entry.entry.value + " · " + entry.readiness.rawValue)
                                        .font(.caption).foregroundStyle(.secondary)
                                    if !entry.prerequisiteSummary.isEmpty {
                                        Text(entry.prerequisiteSummary).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                }
                if let entry = environment.gameWorkspaces.library?.entries.first(where: { $0.engine == selected }) {
                    Section(IDELanguageRunText.t("键位与许可", "Controls and licenses")) {
                        Text(entry.defaultButtons.map { $0.label + ": " + $0.keys.joined(separator: "+") }
                            .joined(separator: "\n")).font(.caption)
                        Text(entry.sourceLicense).font(.caption2).foregroundStyle(.secondary)
                        Text(entry.engineLicense).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(IDELanguageRunText.t("创建起始工程", "Create starter"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IDELanguageRunText.t("取消", "Cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(IDELanguageRunText.t("创建", "Create")) { onCreate(selected) }
                }
            }
        }
    }
}

/// Explicit root/engine choice after a whole-tree import. AI/heuristic values
/// are displayed but only the user's tap commits a selection.
struct GameProjectSelectionChooser: View {
    let snapshot: GameProjectSelectionSnapshot?
    let library: GameEngineLibrary?
    let onSelect: (GameRelativePath?, GameEngineID) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(IDELanguageRunText.t("选择工程根和引擎", "Choose project root and engine"))
                .font(.headline)
            if let snapshot {
                if let recommendation = snapshot.aiRecommendation {
                    Text(IDELanguageRunText.t("AI 建议：\(recommendation.engine.rawValue) · \(recommendation.rationale)", "AI suggestion: \(recommendation.engine.rawValue) · \(recommendation.rationale)"))
                        .font(.caption).foregroundStyle(.secondary)
                } else if let heuristic = snapshot.heuristicRecommendation {
                    Text(IDELanguageRunText.t("规则识别：\(heuristic.engine.rawValue)（不是 AI）", "Heuristic: \(heuristic.engine.rawValue) (not AI)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(snapshot.choices) { choice in
                    ForEach(choice.engines, id: \.engine) { engine in
                        Button {
                            Task { await onSelect(choice.root, engine.engine) }
                        } label: {
                            HStack {
                                Text((choice.root?.value ?? ".") + " · " + engine.displayName)
                                Spacer()
                                if snapshot.selectedRoot == choice.root && snapshot.selectedEngine == engine.engine {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }.buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(16)
    }
}

/// Hosts the existing WorkspaceIDEView, unchanged except for the reviewed
/// optional run/sidebar extension. It verifies the pinned workspace/root before
/// showing the editor, so a stale request cannot open another project.
struct GameProjectIDEPresentation: View {
    let request: GameIDEOpenRequest
    let session: GameWorkspaceSession?
    let environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let session {
                if session.center.currentWorkspace?.id == request.workspace.workspaceID,
                   let root = session.center.currentRootURL,
                   root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                    == request.workspace.rootURL.pathComponents {
                    WorkspaceIDEView(initialRelativePath: initialPath, center: session.center,
                        initialSidebarMode: initialSidebar, projectRunExtension: nil,
                        onSaved: {})
                        .environmentObject(environment)
                } else {
                    ContentUnavailableView {
                        Label(IDELanguageRunText.t("工程已切换", "Project changed"),
                              systemImage: "folder.badge.questionmark")
                    } description: {
                        Text(IDELanguageRunText.t("请从游戏项目重新打开。", "Reopen from the game project."))
                    }
                }
            } else {
                ProgressView()
            }
        }
    }

    private var initialPath: String? {
        if case .code(let path) = request.destination { return path?.value }
        return nil
    }
    private var initialSidebar: IDESidebarMode {
        request.destination == .sourceControl ? .sourceControl : .files
    }
}

/// Read-only historical list plus an explicit full-snapshot restore into a new
/// head. It never rewrites Git or the imported original.
struct GameProjectHistoryScreen: View {
    let session: GameWorkspaceSession
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var revisions: [GameRevisionSummary] = []
    @State private var error: String?
    @State private var loading = false
    @State private var confirming: GameRevisionSummary?

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }
                ForEach(revisions) { revision in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(revision.revision.prefix(12)).font(.headline.monospaced())
                        Text("\(revision.fileCount) files · \(revision.engine?.rawValue ?? "-")")
                            .font(.caption).foregroundStyle(.secondary)
                        if revision.revision == session.project.project.revision {
                            Text(IDELanguageRunText.t("当前版本", "Current")).font(.caption2).foregroundStyle(.tint)
                        }
                    }
                    .swipeActions {
                        if revision.revision != session.project.project.revision {
                            Button(IDELanguageRunText.t("恢复", "Restore")) { confirming = revision }
                                .tint(.orange)
                        }
                    }
                }
            }
            .navigationTitle(IDELanguageRunText.t("版本记录", "Version history"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(IDELanguageRunText.t("关闭", "Close")) { dismiss() } } }
            .overlay { if loading { ProgressView() } }
            .task { await load() }
            .confirmationDialog(IDELanguageRunText.t("恢复这个版本？", "Restore this revision?"),
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible, presenting: confirming) { revision in
                Button(IDELanguageRunText.t("恢复为新版本", "Restore as new revision")) {
                    Task { await restore(revision) }
                }
                Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) { confirming = nil }
            } message: { revision in
                Text(IDELanguageRunText.t("当前文件会保留在历史中；不会改写 Git 或原始导入包。", "Current files remain in history; Git and the imported archive are unchanged."))
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let context = try session.project.context
            let docs = GameProjectDocumentService(repository: session.project.repository)
            revisions = try await docs.history(context, limit: 64)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func restore(_ revision: GameRevisionSummary) async {
        do {
            let context = try session.project.context
            let docs = GameProjectDocumentService(repository: session.project.repository)
            _ = try await docs.restore(context, expectedRevision: context.savedRevision,
                historicalRevision: revision.revision)
            try await session.project.refresh()
            confirming = nil
            await load()
        } catch { self.error = error.localizedDescription }
    }
}
#endif
