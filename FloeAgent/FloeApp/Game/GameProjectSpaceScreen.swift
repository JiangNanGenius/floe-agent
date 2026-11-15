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
    @State private var engineQuestion: ThreadComposerInput?
    @State private var showingQuickEdit = false
    @State private var showingBuild = false
    @State private var showingDeploymentAssets = false
    @State private var showingHistory = false
    @State private var showingImporter = false
    @State private var showingEngineChange = false
    @State private var showingCreateStarter = false
    @State private var ideRequest: GameIDEOpenRequest?
    @State private var starterEngine: GameEngineID?
    @State private var starterError: String?
    @State private var manualSelectionPrompt: GameManualSelectionPrompt?
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
            .sheet(isPresented: $showingAssistant, onDismiss: { engineQuestion = nil }) {
                if let session, let record = session.record {
                    StudioAssistantView(record: record, composerInput: engineQuestion, onInputConsumed: { id in
                        if engineQuestion?.id == id { engineQuestion = nil }
                    }, onClose: { showingAssistant = false })
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
                        ?? session.project.project.engine, error: nil,
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
                    GameStarterCreationSheet(engine: starterEngine,
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
            .confirmationDialog(
                IDELanguageRunText.t("手动使用这个引擎？", "Use this engine manually?"),
                isPresented: Binding(
                    get: { manualSelectionPrompt != nil },
                    set: { if !$0 { manualSelectionPrompt = nil } }),
                titleVisibility: .visible,
                presenting: manualSelectionPrompt) { prompt in
                    Button(prompt.createsStarter
                        ? IDELanguageRunText.t("创建起始工程", "Create starter")
                        : IDELanguageRunText.t("仍然使用", "Use anyway")) {
                        let value = prompt
                        manualSelectionPrompt = nil
                        guard let session else { return }
                        if value.createsStarter {
                            Task { await createStarter(session, engine: value.engine) }
                        } else {
                            Task { await selectManual(session, root: value.root,
                                                      engine: value.engine) }
                        }
                    }
                    Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) {
                        manualSelectionPrompt = nil
                    }
                } message: { prompt in
                    Text(prompt.createsStarter
                        ? IDELanguageRunText.t("会用这个引擎创建真实的起始文件。没有识别依据时，试玩和构建保持关闭，直到工程出现可识别标记。",
                            "Real starter files will be created with this engine. Without recognized evidence, play and build stay closed until a marker appears.")
                        : IDELanguageRunText.t("当前文件里没有识别到这个引擎的依据。选择会保存为手动未验证；检查、读取、编辑和历史保持可用，试玩和构建保持关闭。",
                            "No marker for this engine was recognized in these files. The choice is saved as manual/unverified; inspect, read, edit and history stay available, while play and build stay closed."))
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
            GameProjectSetupPanel(
                snapshot: snapshot,
                library: environment.gameWorkspaces.library,
                proposal: session.project.pendingSelectionProposal,
                proposalIsStale: session.project.isPendingSelectionProposalStale,
                onRecognized: { root, engine in
                    await select(session, root: root, engine: engine)
                },
                onManual: { root, engine in
                    manualSelectionPrompt = GameManualSelectionPrompt(
                        root: root, engine: engine, createsStarter: false)
                },
                onStarter: { engine in
                    manualSelectionPrompt = GameManualSelectionPrompt(
                        root: nil, engine: engine, createsStarter: true)
                },
                onConfirmProposal: { proposal in
                    await confirmProposal(session, proposal)
                },
                onDismissProposal: {
                    session.project.discardSelectionProposal()
                },
                onAskAI: {
                    engineQuestion = ThreadComposerInput(text: IDELanguageRunText.t(
                        "请检查我导入的游戏文件，判断使用了哪个引擎，以及哪个文件夹是游戏根目录。请列出判断依据，有不确定的地方请指出。",
                        "Inspect my imported game files. Which engine and project root do they use? Show the evidence and explain any uncertainty."
                    ), attachments: [])
                    showingAssistant = true
                },
                onImport: {
                    showingImporter = true
                })
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
        let engineName = state?.selectedEngine?.rawValue
            ?? IDELanguageRunText.t("尚未选择引擎", "No engine selected")
        let summary: String
        if let state, state.selectedEngine != nil {
            summary = engineName + " · " + (state.selectedRoot?.value ?? ".")
                + (state.isManualUnverified
                    ? " · " + IDELanguageRunText.t("手动未验证", "manual, unverified")
                    : "")
        } else if project.files.isEmpty {
            summary = IDELanguageRunText.t("空工程 · 选择引擎、创建起始模板或导入",
                                           "Empty project · choose an engine, create a starter or import")
        } else if state?.state == .ambiguous {
            summary = IDELanguageRunText.t("发现多个工程根／引擎，请选择",
                                           "Multiple roots/engines found. Choose one.")
        } else if state?.state == .unresolved {
            summary = IDELanguageRunText.t("未识别引擎 · 手动选择或让当前工程 AI 协助",
                                           "Engine not recognized · choose manually or ask the project AI")
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
            if snapshot.state == .empty {
                return IDELanguageRunText.t("选择引擎后创建真实的起始文件。",
                                            "Choose an engine to create real starter files.")
            }
            if snapshot.state == .ambiguous {
                return IDELanguageRunText.t("请先选择根目录和引擎。",
                                            "Choose a root and engine first.")
            }
            if snapshot.state == .unresolved {
                return IDELanguageRunText.t("没有识别到支持的引擎。可手动选择，或让当前工程 AI 读取依据后建议。",
                                            "No supported engine was recognized. Choose manually or ask the project AI to inspect the evidence.")
            }
            if snapshot.isManualUnverified {
                return IDELanguageRunText.t("引擎是手动选择，没有识别依据；试玩和构建保持关闭。",
                                            "The engine was chosen manually without recognized evidence; play and build stay closed.")
            }
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
            Button(IDELanguageRunText.t("导入文件", "Import files"),
                   systemImage: "square.and.arrow.down") {
                showingImporter = true
            }.buttonStyle(.bordered)
            if session.project.project.files.isEmpty {
                Button(IDELanguageRunText.t("创建起始工程", "Create starter"),
                       systemImage: "wand.and.stars") {
                    // No default engine: the user must pick one in the sheet.
                    starterEngine = nil
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
        guard session.project.selectionSnapshot?.runSelection != nil else {
            if session.project.selectionSnapshot?.isManualUnverified == true {
                notice = IDELanguageRunText.t(
                    "当前引擎是手动选择，没有识别依据。工程出现可识别标记后才能试玩。",
                    "The current engine is a manual choice without recognized evidence. Play opens after a real marker appears.")
            } else {
                notice = IDELanguageRunText.t("请先确认游戏目录和引擎。",
                                              "Choose and confirm a game folder and engine first.")
            }
            return
        }
        do {
            pending = .play
            defer { pending = nil }
            _ = try await environment.gameWorkspaces.ensurePlayableSession(for: session)
            let play = environment.gameWorkspaces.playCoordinator(for: session)
            _ = try await play.start()
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
            notice = IDELanguageRunText.t("已选择并保存 \(engine.rawValue)。",
                                          "Selected and saved \(engine.rawValue).")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func selectManual(_ session: GameWorkspaceSession, root: GameRelativePath?,
                              engine: GameEngineID) async {
        do {
            pending = .simpleEdit
            defer { pending = nil }
            try await session.project.selectManual(
                root: root, engine: engine, acknowledgingUnverified: true)
            notice = IDELanguageRunText.t(
                "已保存手动选择 \(engine.rawValue)；试玩和构建保持关闭。",
                "Saved the manual \(engine.rawValue) choice; play and build stay closed.")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func confirmProposal(_ session: GameWorkspaceSession,
                                 _ proposal: GameProjectSelectionProposal) async {
        do {
            pending = .simpleEdit
            defer { pending = nil }
            let snapshot = try await session.project.confirmSelectionProposal(proposal)
            if snapshot.isManualUnverified {
                notice = IDELanguageRunText.t("已保存手动选择；试玩和构建保持关闭。",
                                              "Saved the manual choice; play and build stay closed.")
            } else {
                let name = snapshot.selectedEngine?.rawValue ?? ""
                notice = IDELanguageRunText.t("已采用并保存 \(name) 选择。",
                                              "Confirmed and saved the \(name) choice.")
            }
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

/// Native catalog-backed starter picker. It lists exactly the bundled 20
/// engine descriptors and their real prerequisites. A runtime-pack starter is
/// offered but explicitly reports its missing prepared pack on failure.
struct GameStarterCreationSheet: View {
    /// Nil means the user must choose explicitly. The sheet never silently
    /// preselects the first catalog engine or a creation hint.
    let engine: GameEngineID?
    let error: String?
    let onCancel: () -> Void
    let onCreate: (GameEngineID) -> Void
    @EnvironmentObject private var environment: AppEnvironment
    @State private var selected: GameEngineID?

    init(engine: GameEngineID?, error: String?, onCancel: @escaping () -> Void,
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
                                Image(systemName: selected == entry.engine
                                      ? "checkmark.circle.fill" : "circle")
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
                if let selected,
                   let entry = environment.gameWorkspaces.library?.entries.first(where: { $0.engine == selected }) {
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
                    Button(IDELanguageRunText.t("创建", "Create")) {
                        guard let selected else { return }
                        onCreate(selected)
                    }
                    .disabled(selected == nil)
                }
            }
        }
    }
}

/// One explicit manual choice awaiting the user's acknowledgement dialog.
struct GameManualSelectionPrompt: Identifiable {
    let id = UUID()
    let root: GameRelativePath?
    let engine: GameEngineID
    let createsStarter: Bool
}

/// The real project setup surface. It composes only catalogue metadata and the
/// already-discovered choices; it never recognizes an engine itself, never
/// starts an engine and never persists a proposal without the user's tap.
struct GameProjectSetupPanel: View {
    let snapshot: GameProjectSelectionSnapshot?
    let library: GameEngineLibrary?
    let proposal: GameProjectSelectionProposal?
    let proposalIsStale: Bool
    let onRecognized: (GameRelativePath?, GameEngineID) async -> Void
    let onManual: (GameRelativePath?, GameEngineID) -> Void
    let onStarter: (GameEngineID) -> Void
    let onConfirmProposal: (GameProjectSelectionProposal) async -> Void
    let onDismissProposal: () -> Void
    let onAskAI: () -> Void
    let onImport: () -> Void

    @State private var expanded = false
    @State private var manualRootID = "."
    @State private var confirmingProposal = false

    private var needsAttention: Bool {
        guard let snapshot else { return false }
        if snapshot.state == .empty || snapshot.state == .unresolved
            || snapshot.state == .ambiguous || snapshot.isManualUnverified {
            return true
        }
        return snapshot.selectedEngine == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let proposal {
                proposalCard(proposal)
            }
            if expanded || needsAttention {
                details
            } else if let snapshot {
                currentSummary(snapshot)
            }
            Divider()
            HStack(spacing: 10) {
                Button(IDELanguageRunText.t("让当前工程 AI 判断", "Ask project AI"),
                       systemImage: "sparkles", action: onAskAI)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("game.setup.askAI")
                Button(IDELanguageRunText.t("导入文件", "Import files"),
                       systemImage: "square.and.arrow.down", action: onImport)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("game.setup.import")
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .onAppear { syncManualRoot() }
        .onChange(of: snapshot?.selectedRoot?.value) { _, _ in syncManualRoot() }
        .onChange(of: snapshot?.state) { _, _ in
            if needsAttention { expanded = true }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gamecontroller")
                .foregroundStyle(.tint)
            Text(IDELanguageRunText.t("工程设置", "Project setup"))
                .font(.headline)
            Spacer()
            if let snapshot {
                Text(stateText(snapshot))
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
                if snapshot.selectedEngine != nil {
                    Button(expanded
                           ? IDELanguageRunText.t("收起", "Hide")
                           : IDELanguageRunText.t("更改", "Change")) {
                        expanded.toggle()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("game.setup.toggle")
                }
            }
        }
    }

    @ViewBuilder private func currentSummary(_ snapshot: GameProjectSelectionSnapshot) -> some View {
        if let engine = snapshot.selectedEngine {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(engine))
                    .font(.body.weight(.medium))
                Text(rootLabel(snapshot.selectedRoot))
                    .font(.caption).foregroundStyle(.secondary)
                Text(snapshot.isManualUnverified
                     ? IDELanguageRunText.t("手动选择 · 未验证，试玩和构建保持关闭",
                                            "Manual choice · unverified, play and build stay closed")
                     : IDELanguageRunText.t("依据已识别标记确认",
                                            "Confirmed by recognized markers"))
                    .font(.caption2)
                    .foregroundStyle(snapshot.isManualUnverified ? Color.orange : Color.secondary)
            }
        } else {
            Text(IDELanguageRunText.t("选择引擎和游戏目录，或导入一个完整工程。",
                                      "Choose an engine and game folder, or import a complete project."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var details: some View {
        if let snapshot {
            if snapshot.isEmptyProject {
                VStack(alignment: .leading, spacing: 8) {
                    Text(IDELanguageRunText.t(
                        "空工程还没有游戏文件。先创建起始模板，或导入已有工程；导入完成后再识别引擎。",
                        "The empty project has no game files. Create a starter or import a project; recognition runs after the import."))
                        .font(.caption).foregroundStyle(.secondary)
                    starterMenu
                }
            } else {
                if snapshot.choices.isEmpty {
                    Text(IDELanguageRunText.t("没有可用的游戏目录。请刷新或重新导入。",
                                              "No game folders are available. Refresh or import again."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(snapshot.choices) { choice in
                    choiceSection(choice, selectedEngine: snapshot.selectedEngine,
                                  selectedRoot: snapshot.selectedRoot, snapshot: snapshot)
                }
                manualSection(snapshot)
            }
            if !snapshot.ambiguities.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(snapshot.ambiguities, id: \.self) { ambiguity in
                        Text(ambiguityText(ambiguity))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            if !snapshot.diagnostics.isEmpty {
                DisclosureGroup(IDELanguageRunText.t("诊断", "Diagnostics")) {
                    ForEach(snapshot.diagnostics.indices, id: \.self) { index in
                        Text("\(snapshot.diagnostics[index].source.rawValue): "
                            + snapshot.diagnostics[index].message)
                            .font(.caption2)
                            .textSelection(.enabled)
                    }
                }
                .font(.caption2)
            }
            if snapshot.state == .automatic, let engine = snapshot.selectedEngine {
                Button(IDELanguageRunText.t("确认并保存当前选择", "Confirm and save this choice")) {
                    Task { await onRecognized(snapshot.selectedRoot, engine) }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("game.setup.confirmAutomatic")
            }
        } else {
            Text(IDELanguageRunText.t("正在读取工程…", "Reading the project…"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func choiceSection(_ choice: GameProjectSelectionChoice,
                                            selectedEngine: GameEngineID?,
                                            selectedRoot: GameRelativePath?,
                                            snapshot: GameProjectSelectionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(rootLabel(choice.root)).font(.subheadline.weight(.medium))
                if choice.engines.isEmpty {
                    Text(IDELanguageRunText.t("未识别引擎", "no engine recognized"))
                        .font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
            }
            ForEach(choice.engines, id: \.engine) { capability in
                Button {
                    Task { await onRecognized(choice.root, capability.engine) }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(capability.displayName).font(.body.weight(.medium))
                                if capability.engine == snapshot.aiRecommendation?.engine {
                                    badge(IDELanguageRunText.t("AI 建议", "AI suggestion"), color: .purple)
                                }
                                if capability.engine == snapshot.heuristicRecommendation?.engine {
                                    badge(IDELanguageRunText.t("识别建议", "Hint"), color: .orange)
                                }
                            }
                            Text(readinessText(capability))
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(evidenceText(capability))
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        Spacer(minLength: 0)
                        if selectedRoot == choice.root && selectedEngine == capability.engine {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("game.setup.use."
                    + (choice.root?.value ?? "root") + "." + capability.engine.rawValue)
            }
            if choice.engines.isEmpty {
                engineMenu(title: IDELanguageRunText.t("为这个目录选择引擎", "Choose an engine for this folder"),
                           root: choice.root)
            }
        }
        .padding(10)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func manualSection(_ snapshot: GameProjectSelectionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(IDELanguageRunText.t("手动选择", "Manual choice"))
                .font(.subheadline.weight(.medium))
            Text(IDELanguageRunText.t(
                "没有可靠依据时仍可人工选择。未识别到手头证据的选项会保存为手动未验证，试玩和构建不会开放。",
                "You can still choose manually without reliable evidence. A choice without a recognized marker is saved as manual/unverified and does not unlock play or build."))
                .font(.caption2).foregroundStyle(.secondary)
            if snapshot.choices.count > 1 {
                Picker(IDELanguageRunText.t("游戏目录", "Game folder"), selection: $manualRootID) {
                    ForEach(snapshot.choices) { choice in
                        Text(rootLabel(choice.root)).tag(choice.id)
                    }
                }
                .pickerStyle(.menu)
            }
            engineMenu(title: IDELanguageRunText.t("手动选择引擎", "Choose engine manually"),
                       root: manualRoot)
        }
        .padding(10)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func engineMenu(title: String, root: GameRelativePath?) -> some View {
        Menu {
            ForEach(library?.entries ?? []) { entry in
                Button(entry.displayName) { onManual(root, entry.engine) }
            }
        } label: {
            Label(title, systemImage: "slider.horizontal.3")
                .font(.callout)
        }
        .disabled(library?.entries.isEmpty != false)
        .accessibilityIdentifier("game.setup.manual")
    }

    private var starterMenu: some View {
        Menu {
            ForEach(library?.entries ?? []) { entry in
                Button(entry.displayName) { onStarter(entry.engine) }
            }
        } label: {
            Label(IDELanguageRunText.t("创建起始模板", "Create starter"),
                  systemImage: "wand.and.stars")
        }
        .buttonStyle(.borderedProminent)
        .disabled(library?.entries.isEmpty != false)
        .accessibilityIdentifier("game.setup.starter")
    }

    @ViewBuilder private func proposalCard(_ proposal: GameProjectSelectionProposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text(IDELanguageRunText.t("当前工程 AI 的引擎建议", "Project AI engine suggestion"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if proposalIsStale {
                    badge(IDELanguageRunText.t("工程已变化", "Project changed"), color: .red)
                } else if proposal.isManualUnverified {
                    badge(IDELanguageRunText.t("未验证", "Unverified"), color: .orange)
                }
            }
            Text(displayName(proposal.selectedEngine) + " · "
                + rootLabel(proposal.selectedRoot))
                .font(.callout.weight(.medium))
            Text(proposal.rationale)
                .font(.caption)
                .textSelection(.enabled)
            if proposalIsStale {
                Text(IDELanguageRunText.t("工程内容已变化，这个建议不能直接采用。重新读取后再建议。",
                                          "The project changed, so this proposal cannot be used. Inspect again before proposing."))
                    .font(.caption2).foregroundStyle(.red)
            } else if proposal.isManualUnverified {
                Text(IDELanguageRunText.t("这个建议没有识别依据；确认后保存为手动未验证，试玩和构建保持关闭。",
                                          "This suggestion has no recognized evidence; confirming saves it as manual/unverified and keeps play/build closed."))
                    .font(.caption2).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Button(IDELanguageRunText.t("采用这个选择", "Use this choice")) {
                    confirmingProposal = true
                    Task {
                        await onConfirmProposal(proposal)
                        confirmingProposal = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(proposalIsStale || confirmingProposal)
                .accessibilityIdentifier("game.setup.proposal.use")
                Button(IDELanguageRunText.t("忽略", "Dismiss"), role: .cancel,
                       action: onDismissProposal)
                    .buttonStyle(.bordered)
                    .disabled(confirmingProposal)
                    .accessibilityIdentifier("game.setup.proposal.dismiss")
                if confirmingProposal { ProgressView().controlSize(.small) }
            }
        }
        .padding(10)
        .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var manualRoot: GameRelativePath? {
        guard manualRootID != "." else { return nil }
        return snapshot?.choices.first { $0.id == manualRootID }?.root
    }

    private func syncManualRoot() {
        if let value = snapshot?.selectedRoot?.value, !value.isEmpty {
            manualRootID = value
        } else if let first = snapshot?.choices.first?.id {
            manualRootID = first
        } else {
            manualRootID = "."
        }
    }

    private func badge(_ value: String, color: Color) -> some View {
        Text(value)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func stateText(_ snapshot: GameProjectSelectionSnapshot) -> String {
        switch snapshot.state {
        case .empty: return IDELanguageRunText.t("空工程", "Empty")
        case .unresolved: return IDELanguageRunText.t("未识别引擎", "Engine not recognized")
        case .ambiguous: return IDELanguageRunText.t("需要选择", "Choose one")
        case .automatic: return IDELanguageRunText.t("已识别", "Recognized")
        case .confirmed:
            return snapshot.isManualUnverified
                ? IDELanguageRunText.t("手动未验证", "Manual, unverified")
                : IDELanguageRunText.t("已确认", "Confirmed")
        }
    }

    private func displayName(_ engine: GameEngineID) -> String {
        library?.entries.first { $0.engine == engine }?.displayName ?? engine.rawValue
    }

    private func rootLabel(_ root: GameRelativePath?) -> String {
        root?.value ?? IDELanguageRunText.t("工程根目录", "Project root")
    }

    private func readinessText(_ capability: GameProjectEngineCapability) -> String {
        switch capability.starterReadiness {
        case .completeSource: return IDELanguageRunText.t("完整源码", "Complete source")
        case .sourceWithBuildTool: return IDELanguageRunText.t("源码 + 构建工具", "Source + build tool")
        case .sourceWithEditor: return IDELanguageRunText.t("源码 + 编辑器", "Source + editor")
        case .runtimePackRequired: return IDELanguageRunText.t("需要运行时包", "Runtime pack required")
        }
    }

    private func evidenceText(_ capability: GameProjectEngineCapability) -> String {
        guard !capability.recognizedEvidence.isEmpty else {
            return IDELanguageRunText.t("没有识别依据", "No recognized evidence")
        }
        let values = capability.recognizedEvidence.prefix(3).map { item in
            item.path.value + (item.versionHint.map { " (" + $0 + ")" } ?? "")
        }.joined(separator: ", ")
        return IDELanguageRunText.t("依据：", "Evidence: ") + values
    }

    private func ambiguityText(_ ambiguity: GameProjectSelectionAmbiguity) -> String {
        switch ambiguity {
        case .multipleRoots(let roots):
            return IDELanguageRunText.t("发现 \(roots.count) 个游戏目录，需要明确选择。",
                                        "\(roots.count) game folders need an explicit choice.")
        case .multipleEngines(let root, let engines):
            return IDELanguageRunText.t("\(rootLabel(root)) 识别到 \(engines.count) 个引擎，需要明确选择。",
                                        "\(engines.count) engines in \(rootLabel(root)); choose one.")
        case .noEngineRecognized(let root):
            return IDELanguageRunText.t("\(rootLabel(root)) 未识别到支持的引擎。",
                                        "No supported engine in \(rootLabel(root)).")
        case .noEngineRecognizedAnywhere:
            return IDELanguageRunText.t("所有目录都未识别到支持的引擎。",
                                        "No supported engine was recognized in any folder.")
        case .persistedSelectionInvalidated:
            return IDELanguageRunText.t("上次选择已因内容变化失效。",
                                        "The previous choice no longer matches the project.")
        case .manualSelectionUnverified(let root, let engine):
            return IDELanguageRunText.t("\(rootLabel(root)) 的 \(engine.rawValue) 是手动选择，没有识别依据。",
                                        "\(engine.rawValue) in \(rootLabel(root)) is a manual choice without recognized evidence.")
        }
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
