// FloeApp — Thread composer (bottom-pinned, multi-line).
//
// SPDX-License-Identifier: MPL-2.0
//
// The one composer used by both the Chat-first home and the thread
// detail: multi-line input pinned to the bottom (chrome material is
// allowed here), attachment picking (security-scoped bookmark via
// FilesCenter), model selection, workspace project selection, execution target and Agent
// mode. While a run is non-terminal Stop remains separate from the running
// input Queue/Steer send action. All controls keep the 44pt minimum target; the app stays
// fully usable without a configured model — only AI send is disabled.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import AVFoundation
import PhotosUI
import FloeCore
import FloeModels
import FloeAgentRuntime
import FloeLocalModels

/// How the next run should execute. Forward-looking selection surface;
/// the runtime mapping lands with the workspace tasks (T04/T05).
enum AgentExecutionMode: String, CaseIterable, Identifiable, Sendable {
    /// Chat plus approved tool calls (default agent behavior).
    case agent
    /// Chat only — no tool execution requested.
    case chat
    /// Read-only discovery that produces a reviewable plan.
    case plan
    /// Persistent, budgeted execution toward evidence-backed criteria.
    case goal

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .agent: "composer.mode.agent"
        case .chat: "composer.mode.chat"
        case .plan: "composer.mode.plan"
        case .goal: "composer.mode.goal"
        }
    }

    var localizedTitle: String {
        switch self {
        case .agent: String(localized: "composer.mode.agent")
        case .chat: String(localized: "composer.mode.chat")
        case .plan: String(localized: "composer.mode.plan")
        case .goal: String(localized: "composer.mode.goal")
        }
    }

    var systemImage: String {
        switch self {
        case .agent: "wand.and.sparkles"
        case .chat: "text.bubble"
        case .plan: "list.bullet.clipboard"
        case .goal: "target"
        }
    }

    var conversationMode: ConversationMode {
        switch self {
        case .plan: .plan
        case .goal: .goal
        case .agent, .chat: .chat
        }
    }

    var toolsEnabled: Bool { self != .chat }
}

/// Where the next run executes. Hosts are wired when SSH tools land;
/// today only local is selectable and the control stays honest about it.
enum AgentExecutionTarget: String, CaseIterable, Identifiable, Sendable {
    case local

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .local: "composer.target.local"
        }
    }

    var localizedTitle: String {
        switch self {
        case .local: String(localized: "composer.target.local")
        }
    }

    var systemImage: String {
        switch self {
        case .local: "iphone"
        }
    }
}

/// A workspace project selectable in the composer. T05 maps these from
/// WorkspaceCenter.workspaces (see the extension below).
struct ComposerProject: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

extension ComposerProject {
    /// Maps a persisted workspace record to a composer project entry.
    init(record: WorkspaceRecord) {
        self.init(id: record.id, name: record.name)
    }
}

/// Bottom-pinned composer: input row + context row (model / project /
/// target / mode / attachments).
struct ThreadComposerView: View {
    @Binding var draft: String
    @Binding var selectedModelID: UUID?

    /// Enabled agent models for the picker.
    let models: [ModelProfile]
    /// Display name of the resolved model (nil = no provider configured).
    let modelName: String?
    /// True when at least one provider+model exists (gates AI send only).
    let providerConfigured: Bool
    /// True while the displayed run is non-terminal (send → stop).
    var isRunning: Bool = false
    /// Present in a thread composer. Home omits it because no run is active.
    var runningInputMode: Binding<RunningInputMode>? = nil
    /// True when sending is allowed. During an active run this controls the
    /// independent queue/steer action; Stop remains available beside it.
    let canSend: Bool
    /// Workspaces available to this conversation.
    var projects: [ComposerProject] = []
    /// Existing tasks have immutable workspace scope. Moving them is an
    /// explicit top-bar action with a confirmation, not a per-message menu.
    var projectSelectionLocked: Bool = false
    @Binding var selectedProjectID: UUID?
    @Binding var executionTarget: AgentExecutionTarget
    @Binding var agentMode: AgentExecutionMode
    /// Attachment refs picked in this composer (displayed as chips).
    @Binding var attachments: [AttachmentRef]

    let onSend: () -> Void
    let onStop: () -> Void
    var onManualCompact: (() -> Void)? = nil
    var onPermissions: () -> Void = {}
    var approvalMode: TaskApprovalMode = .ask
    /// Changes when the composer is reused for another conversation. Local
    /// transient errors must not leak into the next task.
    var contextID: UUID? = nil

    @State private var isPickerPresented = false
    @State private var isPhotoPickerPresented = false
    @State private var photoPickerTraceID: UUID?
    @State private var isCameraPresented = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isAttachmentProcessing = false
    @State private var attachmentError: String?
    @State private var pendingLocalModelSwitch: PendingLocalModelSwitch?
    @State private var pendingLocalCapabilityModel: ModelProfile?
    @State private var preparingLocalModelID: String?
    @State private var dictationPrefix = ""
    @State private var slashNotice: String?
    @EnvironmentObject private var voiceInput: VoiceInputController
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if !slashActions.isEmpty {
                slashCommandPalette
            }
            if let attachmentError {
                errorBanner(attachmentError)
            }
            if let slashNotice {
                infoBanner(slashNotice)
            }
            if let voiceNotice = voiceNotice {
                voiceBanner(voiceNotice)
            }
            if !attachments.isEmpty {
                attachmentChips
            }
            inputRow
            contextRow
        }
        .background(FloeTheme.chromeMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .shadow(color: .black.opacity(0.08), radius: 14, y: 5)
        .sheet(isPresented: $isPickerPresented) {
            DocumentPickerView { url in
                Task { await registerPicked(url) }
            }
        }
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $selectedPhoto,
            matching: .images,
            photoLibrary: .shared()
        )
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraPickerView { image in
                isCameraPresented = false
                registerCapturedImage(image)
            } onCancel: {
                isCameraPresented = false
            }
            .ignoresSafeArea()
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await registerPickedPhoto(item) }
        }
        .onChange(of: attachments.map(\.id)) { _, _ in
            attachmentError = nil
            slashNotice = nil
        }
        .onChange(of: contextID) { _, _ in
            attachmentError = nil
            selectedPhoto = nil
            pendingLocalModelSwitch = nil
            pendingLocalCapabilityModel = nil
            isPhotoPickerPresented = false
            photoPickerTraceID = nil
            if contextID == nil {
                environment.workspaceCenter.closeCurrentWorkspace()
            }
        }
        .task(id: contextID) {
            // The task's immutable owner may be an external project or an
            // app-owned private workspace. Bind either one here so the file
            // inspector cannot remain empty while agent tools use the same
            // private root in the background.
            if let contextID {
                do {
                    try await environment.workspaceCenter.openTaskWorkspace(
                        conversationID: contextID
                    )
                    attachmentError = nil
                } catch is CancellationError {
                    return
                } catch {
                    attachmentError = "工作区挂载失败：\(error.localizedDescription)"
                }
            } else {
                environment.workspaceCenter.closeCurrentWorkspace()
            }
        }
        .onChange(of: isRunning) { _, running in
            if running { attachmentError = nil }
        }
        .onChange(of: voiceInput.transcript) { _, transcript in
            guard voiceInput.isListening || !transcript.isEmpty else { return }
            let separator = dictationPrefix.isEmpty || dictationPrefix.last?.isWhitespace == true ? "" : " "
            draft = dictationPrefix + separator + transcript
        }
        .onDisappear { voiceInput.stop() }
        .confirmationDialog(
            "切换到本地模型？",
            isPresented: Binding(
                get: { pendingLocalCapabilityModel != nil },
                set: { if !$0 { pendingLocalCapabilityModel = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let model = pendingLocalCapabilityModel {
                Button("继续切换到 \(model.displayName)") {
                    pendingLocalCapabilityModel = nil
                    chooseOnDeviceModel(model)
                }
            }
            Button("action.cancel", role: .cancel) {
                pendingLocalCapabilityModel = nil
            }
        } message: {
            Text("本地模型使用独立的小上下文和精简工具集，适合搜索、读取文件、简单文本与本地计算；复杂浏览器自动化、SSH、云工作区和多步骤 Git 操作请继续使用云端模型。")
        }
        .confirmationDialog(
            "切换本地模型？",
            isPresented: Binding(
                get: { pendingLocalModelSwitch != nil },
                set: { if !$0 { pendingLocalModelSwitch = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingLocalModelSwitch {
                Button("切换到 \(pendingLocalModelSwitch.target.displayName)") {
                    applyModelSelection(pendingLocalModelSwitch.target)
                    self.pendingLocalModelSwitch = nil
                }
            }
            Button("action.cancel", role: .cancel) {
                pendingLocalModelSwitch = nil
            }
        } message: {
            if let pendingLocalModelSwitch {
                Text("当前已加载 \(pendingLocalModelSwitch.residentName)。下次使用本地模型时会先释放它，再加载 \(pendingLocalModelSwitch.target.displayName)；正在执行的任务不会被中断。")
            }
        }
    }

    /// User-comprehensible voice notice for the current state, if any.
    /// Permission failures carry a Settings jump entry; the draft remains
    /// fully editable in every failure mode.
    private var voiceNotice: (message: LocalizedStringKey, isPermission: Bool)? {
        switch voiceInput.state {
        case .unavailable:
            return ("voice.unavailable", false)
        case .failed(let reason):
            switch reason {
            case .microphonePermissionDenied, .speechPermissionDenied:
                return ("voice.permission_required", true)
            case .localeUnsupported, .modelNotReady:
                return ("voice.unavailable", false)
            case .noAudioInput:
                return ("voice.no_input", false)
            case .recognizerFailed, .interrupted:
                return ("voice.failed", false)
            }
        case .idle, .requestingPermission, .preparing, .listening, .stopping:
            return nil
        }
    }

    private func voiceBanner(_ notice: (message: LocalizedStringKey, isPermission: Bool)) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "microphone.slash")
                .foregroundStyle(FloeTheme.pending)
                .accessibilityHidden(true)
            Text(notice.message)
                .font(FloeTheme.Typography.metadata)
            Spacer()
            if notice.isPermission, let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Button("voice.open_settings") {
                    UIApplication.shared.open(settingsURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minHeight: FloeTheme.minimumTarget)
                .accessibilityIdentifier("voice.open_settings")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Input row

    private enum SlashActionKind {
        case compact
        case openSkills
        case mode(AgentExecutionMode)
        case skill(id: String, name: String)
    }

    private struct SlashAction: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let systemImage: String
        let kind: SlashActionKind
    }

    private var slashActions: [SlashAction] {
        guard let query = ComposerSlashQuery.parse(draft) else { return [] }
        if query.command == "skill" || query.command == "skills" && !query.argument.isEmpty {
            let needle = query.argument.lowercased()
            return environment.skillsCenter.installed
                .filter { $0.status == "enabled" }
                .filter {
                    needle.isEmpty
                        || $0.name.lowercased().contains(needle)
                        || $0.id.lowercased().contains(needle)
                }
                .prefix(8)
                .map {
                    SlashAction(
                        id: "skill:\($0.id)", title: $0.name,
                        subtitle: "在下一条请求中指定 $\($0.id)",
                        systemImage: "puzzlepiece.extension",
                        kind: .skill(id: $0.id, name: $0.name)
                    )
                }
        }

        var actions: [SlashAction] = [
            SlashAction(
                id: "skills", title: "管理 Skills", subtitle: "打开已安装 Skill 与权限",
                systemImage: "puzzlepiece.extension", kind: .openSkills
            ),
            SlashAction(
                id: "agent", title: "Agent 模式", subtitle: "允许调用已授权工具",
                systemImage: "wand.and.sparkles", kind: .mode(.agent)
            ),
            SlashAction(
                id: "chat", title: "聊天模式", subtitle: "不调用工具",
                systemImage: "text.bubble", kind: .mode(.chat)
            ),
            SlashAction(
                id: "plan", title: "计划模式", subtitle: "只读分析并生成计划",
                systemImage: "list.bullet.clipboard", kind: .mode(.plan)
            ),
            SlashAction(
                id: "goal", title: "目标模式", subtitle: "持续执行到满足验收条件",
                systemImage: "target", kind: .mode(.goal)
            )
        ]
        if onManualCompact != nil {
            actions.insert(SlashAction(
                id: "compact", title: "压缩上下文", subtitle: "下次模型请求前压缩当前会话历史",
                systemImage: "arrow.down.right.and.arrow.up.left", kind: .compact
            ), at: 0)
        }
        let needle = query.command
        return actions.filter { needle.isEmpty || $0.id.hasPrefix(needle) }
    }

    private var slashCommandPalette: some View {
        VStack(spacing: 0) {
            ForEach(slashActions) { action in
                Button {
                    performSlashAction(action)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: action.systemImage)
                            .frame(width: 24)
                            .foregroundStyle(FloeTheme.primary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("/\(action.id.hasPrefix("skill:") ? "skill" : action.id) · \(action.title)")
                                .font(.subheadline.weight(.semibold))
                            Text(action.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                if action.id != slashActions.last?.id { Divider().padding(.leading, 46) }
            }
        }
        .background(FloeTheme.groupedSurface)
        .accessibilityIdentifier("composer.slash.palette")
    }

    private func performSlashAction(_ action: SlashAction) {
        switch action.kind {
        case .compact:
            onManualCompact?()
            draft = ""
            slashNotice = "已安排上下文压缩，将在下一次模型请求前执行。"
        case .openSkills:
            draft = ""
            router.openMore(.skills)
        case .mode(let mode):
            agentMode = mode
            draft = ""
            slashNotice = "已切换到\(mode.localizedTitle)。"
        case .skill(let id, _):
            draft = "Use $\(id) "
        }
    }

    @ViewBuilder
    private var inputRow: some View {
        if voiceInput.state.hasSession || voiceInput.state == .requestingPermission {
            voiceCaptureRow
        } else {
            standardInputRow
        }
    }

    private var standardInputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button {
                    // Present PhotosPicker from the stable composer view. A
                    // PhotosPicker nested directly inside Menu can lose its
                    // presentation anchor when the menu dismisses, producing
                    // the observed no-op on iPad and Mac Catalyst.
                    let traceID = UUID()
                    photoPickerTraceID = traceID
                    FloeLogger(category: .app).info(
                        "photoPickerPresentationRequested trace=\(traceID.uuidString) context=\(contextID?.uuidString ?? "none")"
                    )
                    // A Menu is removed from the hierarchy before its action
                    // finishes. Presenting PhotosPicker in the same update is
                    // dropped on iPadOS. Wait for that dismissal transaction,
                    // then present from this stable composer view.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(180))
                        guard photoPickerTraceID == traceID else { return }
                        isPhotoPickerPresented = true
                        FloeLogger(category: .app).info(
                            "photoPickerPresentationCommitted trace=\(traceID.uuidString)"
                        )
                    }
                } label: {
                    Label("composer.attachment.photo_library", systemImage: "photo.on.rectangle")
                }
                if AppleCapabilityPreferences.isEnabled(.camera),
                   UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        isCameraPresented = true
                        FloeLogger(category: .app).info("cameraCaptureRequested")
                    } label: {
                        Label("composer.attachment.camera", systemImage: "camera")
                    }
                }
                Button {
                    isPickerPresented = true
                } label: {
                    Label("composer.attachment.files", systemImage: "folder")
                }
            } label: {
                Image(systemName: "paperclip")
                    .font(.title3)
                    .foregroundStyle(FloeTheme.primary)
            }
            .buttonStyle(.plain)
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel("composer.attach")

            TextField(text: $draft, axis: .vertical) {
                Text("home.new_task.placeholder")
            }
            .lineLimit(1...5)
            .frame(minHeight: FloeTheme.minimumTarget, alignment: .leading)
            .contentShape(Rectangle())
            .textFieldStyle(.plain)
            .accessibilityLabel("home.new_task.placeholder")
            .accessibilityIdentifier("composer.input")

            Button {
                // Preserve whatever the user already typed; dictation appends
                // after this prefix and never replaces it.
                dictationPrefix = draft
                voiceInput.requestStart()
            } label: {
                Image(systemName: "microphone.circle")
                    .font(.title2)
                    .foregroundStyle(FloeTheme.primary)
            }
            .buttonStyle(.plain)
            .disabled(voiceInput.state == .requestingPermission
                      || voiceInput.state == .preparing
                      || voiceInput.state == .stopping)
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel("voice.start")
            .accessibilityValue(voiceAccessibilityValue)
            .accessibilityHint("voice.hint")
            .accessibilityIdentifier("composer.voice")

            if isRunning {
                Button(role: .destructive) {
                    onStop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(FloeTheme.destructive)
                }
                .buttonStyle(.plain)
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("action.stop")
            }

            Button {
                onSend()
            } label: {
                if isAttachmentProcessing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: sendSystemImage)
                        .font(.title2)
                        .foregroundStyle(canSend ? FloeTheme.primary : Color.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(!canSend || isAttachmentProcessing)
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel(sendAccessibilityLabel)
            .accessibilityIdentifier("composer.send")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// Recording is a distinct composer mode, matching the system-agent
    /// interaction: the editor and microphone disappear, partial speech is
    /// shown in place, and the only primary action is an unambiguous square
    /// stop control. Stopping restores the editable draft via the transcript
    /// observer above.
    private var voiceCaptureRow: some View {
        HStack(spacing: 12) {
            VoiceWaveformView(
                isActive: voiceInput.isListening,
                reduceMotion: reduceMotion
            )
            .frame(width: 92, height: 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(voiceCaptureTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(voiceInput.transcript.isEmpty ? "正在聆听…" : voiceInput.transcript)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .contentTransition(.interpolate)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                // Synchronous state reservation prevents rapid taps from
                // starting a second capture while the final transcript drains.
                voiceInput.stop()
            } label: {
                ZStack {
                    Circle()
                        .fill(FloeTheme.destructive)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.white)
                        .frame(width: 14, height: 14)
                }
                .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel("voice.stop")
            .accessibilityValue(voiceAccessibilityValue)
            .accessibilityIdentifier("composer.voice.stop")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private var voiceCaptureTitle: LocalizedStringKey {
        switch voiceInput.state {
        case .requestingPermission: "正在请求语音权限…"
        case .preparing: "正在准备语音识别…"
        case .listening: "正在听你说话"
        case .stopping: "正在完成转写…"
        case .idle, .unavailable, .failed: "语音输入"
        }
    }

    // MARK: - Context row: model / project / target / mode

    private var contextRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                modelPicker
                reasoningPicker
                projectPicker
                targetPicker
                modePicker
                if isRunning, let runningInputMode {
                    Menu {
                        Button {
                            runningInputMode.wrappedValue = .queue
                        } label: {
                            Label("加入消息队列", systemImage: runningInputMode.wrappedValue == .queue
                                  ? "checkmark" : "text.badge.plus")
                        }
                        Button {
                            runningInputMode.wrappedValue = .steer
                        } label: {
                            Label("引导当前运行", systemImage: runningInputMode.wrappedValue == .steer
                                  ? "checkmark" : "arrow.triangle.turn.up.right.diamond")
                        }
                    } label: {
                        composerChip(
                            title: runningInputMode.wrappedValue == .queue ? "排队" : "引导",
                            systemImage: runningInputMode.wrappedValue == .queue
                                ? "text.badge.plus" : "arrow.triangle.turn.up.right.diamond"
                        )
                    }
                    .accessibilityLabel("运行中发送方式")
                }
                Button {
                    onPermissions()
                } label: {
                    composerChip(
                        title: approvalModeTitle,
                        systemImage: "lock.shield"
                    )
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var approvalModeTitle: String {
        switch approvalMode {
        case .ask: "询问"
        case .automatic: "自动审批"
        case .fullAccess: "完全访问"
        }
    }

    private var sendSystemImage: String {
        guard isRunning, let mode = runningInputMode?.wrappedValue else {
            return "arrow.up.circle.fill"
        }
        return mode == .queue ? "text.badge.plus" : "arrow.triangle.turn.up.right.diamond.fill"
    }

    private var sendAccessibilityLabel: String {
        guard isRunning, let mode = runningInputMode?.wrappedValue else {
            return String(localized: "thread.send")
        }
        return mode == .queue ? "加入消息队列" : "引导当前运行"
    }

    private var modelPicker: some View {
        Group {
            if let modelName {
                Menu {
                    ForEach(models) { model in
                        Button {
                            chooseModel(model)
                        } label: {
                            if selectedModelID == model.id {
                                Label(model.displayName, systemImage: "checkmark")
                            } else {
                                Text(model.displayName)
                            }
                        }
                    }
                } label: {
                    composerChip(
                        title: modelName,
                        systemImage: preparingLocalModelID == nil ? "cpu" : "hourglass"
                    )
                }
                .disabled(preparingLocalModelID != nil)
            } else {
                Label("composer.no_model", systemImage: "cpu")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(FloeTheme.pending)
            }
        }
    }

    private struct PendingLocalModelSwitch: Identifiable {
        let id = UUID()
        let target: ModelProfile
        let residentName: String
    }

    private func chooseModel(_ model: ModelProfile) {
        guard model.providerID == ProviderProfile.onDeviceProviderID else {
            applyModelSelection(model)
            return
        }
        let currentIsCloud = models.first(where: { $0.id == selectedModelID })?
            .providerID != ProviderProfile.onDeviceProviderID
        if currentIsCloud {
            pendingLocalCapabilityModel = model
            return
        }
        chooseOnDeviceModel(model)
    }

    private func chooseOnDeviceModel(_ model: ModelProfile) {
        if model.remoteModelID == AppleFoundationModelIdentity.remoteModelID {
            Task { @MainActor in
                // The system model is owned by iOS and has no Floe-managed
                // residency. Release a manually preloaded model before the
                // switch so only one local inference engine consumes memory.
                if await environment.localModelRuntime.residentModelID() != nil {
                    await environment.localModelRuntime.unload()
                    await environment.localModelsCenter.refresh()
                }
                applyModelSelection(model)
            }
            return
        }
        Task { @MainActor in
            let residentModelID = await environment.localModelRuntime.residentModelID()
            switch LocalModelResidencyPolicy.decision(
                residentModelID: residentModelID,
                targetModelID: model.remoteModelID
            ) {
            case .useResident:
                applyModelSelection(model)
            case .preloadSilently:
                preparingLocalModelID = model.remoteModelID
                defer { preparingLocalModelID = nil }
                do {
                    try await environment.localModelsCenter.prepareForTask(
                        modelID: model.remoteModelID
                    )
                    applyModelSelection(model)
                } catch {
                    attachmentError = presentableComposerError(error, operation: "加载本地模型")
                }
            case .confirmReplacement(let currentModelID):
                let residentName = models.first {
                    $0.providerID == ProviderProfile.onDeviceProviderID
                        && $0.remoteModelID == currentModelID
                }?.displayName ?? currentModelID
                pendingLocalModelSwitch = PendingLocalModelSwitch(
                    target: model,
                    residentName: residentName
                )
            }
        }
    }

    private func applyModelSelection(_ model: ModelProfile) {
        selectedModelID = model.id
        // Persist so the task keeps this model after a reload instead of
        // reverting to the old default.
        Task { await environment.conversationCenter.setDefaultAgentModel(model.id) }
    }

    /// WorkBuddy-style quick control kept beside the model selector. The
    /// persisted value is still model-scoped so every provider adapter can
    /// translate it to its own supported wire fields.
    @ViewBuilder
    private var reasoningPicker: some View {
        if let model = models.first(where: { $0.id == selectedModelID }) {
            Menu {
                ForEach(ModelReasoningEffort.allCases) { effort in
                    Button {
                        Task { await updateReasoningEffort(effort, for: model) }
                    } label: {
                        if model.effectiveReasoningEffort == effort {
                            Label(reasoningTitle(effort), systemImage: "checkmark")
                        } else {
                            Text(reasoningTitle(effort))
                        }
                    }
                }
            } label: {
                composerChip(
                    title: reasoningTitle(model.effectiveReasoningEffort),
                    systemImage: "brain.head.profile"
                )
            }
            .accessibilityLabel("model.reasoning.effort")
            .accessibilityIdentifier("composer.reasoning_effort")
        }
    }

    @MainActor
    private func updateReasoningEffort(_ effort: ModelReasoningEffort, for model: ModelProfile) async {
        var updated = model
        updated.reasoningEffort = effort == .automatic ? nil : effort
        do {
            try await environment.conversationCenter.saveModel(updated)
        } catch {
            attachmentError = presentableComposerError(error, operation: "保存模型设置")
        }
    }

    private func reasoningTitle(_ effort: ModelReasoningEffort) -> String {
        switch effort {
        case .automatic: String(localized: "model.reasoning.automatic")
        case .low: String(localized: "model.reasoning.low")
        case .medium: String(localized: "model.reasoning.medium")
        case .high: String(localized: "model.reasoning.high")
        case .maximum: String(localized: "model.reasoning.maximum")
        }
    }

    private var projectPicker: some View {
        Menu {
            Button {
                selectedProjectID = nil
            } label: {
                if selectedProjectID == nil {
                    Label("composer.project.none", systemImage: "checkmark")
                } else {
                    Text("composer.project.none")
                }
            }
            ForEach(projects) { project in
                Button {
                    selectedProjectID = project.id
                } label: {
                    if selectedProjectID == project.id {
                        Label(project.name, systemImage: "checkmark")
                    } else {
                        Text(project.name)
                    }
                }
            }
            Divider()
            Button {
                router.showInspector(.workspaceFiles)
            } label: {
                Label("composer.project.manage", systemImage: "folder.badge.gearshape")
            }
        } label: {
            composerChip(
                title: selectedProjectName
                    ?? String(localized: "composer.project.none"),
                systemImage: "folder"
            )
        }
        .onChange(of: selectedProjectID, initial: false) { _, newValue in
            Task {
                if let newValue {
                    await openProject(newValue)
                } else {
                    environment.workspaceCenter.closeCurrentWorkspace()
                    attachmentError = nil
                }
            }
        }
        .disabled(projectSelectionLocked)
    }

    /// Opens the selected workspace as the current one (resolving its
    /// security-scoped bookmark) so the agent file tools and the inspector
    /// share the same root. Failures surface through the composer's error
    /// banner instead of being dropped.
    private func openProject(_ id: UUID) async {
        do {
            try await environment.workspaceCenter.openWorkspace(id: id)
            attachmentError = nil
        } catch {
            attachmentError = presentableComposerError(error, operation: "打开工作区")
        }
    }

    private var selectedProjectName: String? {
        projects.first(where: { $0.id == selectedProjectID })?.name
    }

    private var targetPicker: some View {
        Menu {
            ForEach(AgentExecutionTarget.allCases) { target in
                Button {
                    executionTarget = target
                } label: {
                    if executionTarget == target {
                        Label(target.title, systemImage: "checkmark")
                    } else {
                        Label(target.title, systemImage: target.systemImage)
                    }
                }
            }
        } label: {
            composerChip(
                title: executionTarget.localizedTitle,
                systemImage: executionTarget.systemImage
            )
        }
    }

    private var modePicker: some View {
        Menu {
            ForEach(AgentExecutionMode.allCases) { mode in
                Button {
                    agentMode = mode
                } label: {
                    if agentMode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Label(mode.title, systemImage: mode.systemImage)
                    }
                }
            }
        } label: {
            composerChip(
                title: agentMode.localizedTitle,
                systemImage: agentMode.systemImage
            )
        }
    }

    private func composerChip(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(FloeTheme.Typography.metadata)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(FloeTheme.groupedSurface, in: Capsule())
    }

    // MARK: - Attachments

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 4) {
                        Image(systemName: icon(for: attachment.kind))
                            .accessibilityHidden(true)
                        Text(attachment.displayName)
                            .lineLimit(1)
                        Button {
                            withAnimation(FloeTheme.motionAnimation(reduceMotion: reduceMotion)) {
                                attachments.removeAll { $0.id == attachment.id }
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .frame(
                            minWidth: FloeTheme.minimumTarget,
                            minHeight: FloeTheme.minimumTarget
                        )
                        .accessibilityLabel(
                            String(localized: "composer.attachment.remove")
                                + " " + attachment.displayName
                        )
                    }
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .background(FloeTheme.groupedSurface, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    private func icon(for kind: AttachmentRef.Kind) -> String {
        switch kind {
        case .image: "photo"
        case .document: "doc"
        case .audio: "waveform"
        case .other: "paperclip"
        }
    }

    /// Bookmarks the picked file through FilesCenter (security-scoped),
    /// surfacing failures honestly instead of dropping them.
    private func registerPicked(_ url: URL) async {
        do {
            let attachment = try await environment.filesCenter
                .registerPickedDocument(url: url, displayName: url.lastPathComponent)
            attachments.append(attachment)
            attachmentError = nil
        } catch {
            attachmentError = presentableComposerError(error, operation: "导入附件")
        }
    }

    private func registerPickedPhoto(_ item: PhotosPickerItem) async {
        let traceID = photoPickerTraceID ?? UUID()
        let startedAt = Date()
        isAttachmentProcessing = true
        defer { isAttachmentProcessing = false }
        defer {
            selectedPhoto = nil
            photoPickerTraceID = nil
        }
        do {
            let advertisedTypes = item.supportedContentTypes
                .map(\.identifier).prefix(8).joined(separator: ",")
            FloeLogger(category: .app).info(
                "photoPickerTransferStarted trace=\(traceID.uuidString) types=\(advertisedTypes) typeCount=\(item.supportedContentTypes.count)"
            )
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw FloeError.validationFailed(String(localized: "composer.attachment.photo_unreadable"))
            }
            let attachment = try environment.filesCenter.registerPhotoData(
                data,
                displayName: "Photo-\(Int(Date().timeIntervalSince1970)).jpg"
            )
            attachments.append(attachment)
            attachmentError = nil
            FloeLogger(category: .app).info(
                "photoPickerTransferFinished trace=\(traceID.uuidString) attachment=\(attachment.id.uuidString) inputBytes=\(data.count) storedBytes=\(attachment.byteCount) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
        } catch {
            let nsError = error as NSError
            FloeLogger(category: .app).warning(
                "photoPickerTransferFailed trace=\(traceID.uuidString) domain=\(nsError.domain) code=\(nsError.code) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
            attachmentError = String(localized: "composer.attachment.photo_failed")
        }
    }

    private func registerCapturedImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            attachmentError = "无法处理拍摄的照片。"
            return
        }
        do {
            let attachment = try environment.filesCenter.registerPhotoData(
                data,
                displayName: "Camera-\(Int(Date().timeIntervalSince1970)).jpg"
            )
            attachments.append(attachment)
            attachmentError = nil
            FloeLogger(category: .app).info(
                "cameraCaptureFinished attachment=\(attachment.id.uuidString) bytes=\(attachment.byteCount)"
            )
        } catch {
            attachmentError = presentableComposerError(error, operation: "导入相机照片")
        }
    }

    /// Cocoa code 259 is emitted for stale bookmarks and inaccessible files
    /// as well as genuinely corrupt bytes. Never leak the misleading global
    /// "format incorrect" message into every subsequent composer.
    private func presentableComposerError(_ error: Error, operation: String) -> String {
        let nsError = error as NSError
        FloeLogger(category: .app).warning(
            "composerOperationFailed operation=\(operation) domain=\(nsError.domain) code=\(nsError.code)"
        )
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadCorruptFile.rawValue {
            return "\(operation)失败：文件引用已失效或内容不可读，请重新选择该文件。"
        }
        return "\(operation)失败：\(error.localizedDescription)"
    }

    /// VoiceOver-readable microphone state (never color alone).
    private var voiceAccessibilityValue: String {
        switch voiceInput.state {
        case .idle: String(localized: "voice.state.idle")
        case .requestingPermission: String(localized: "voice.state.requesting")
        case .preparing: String(localized: "voice.state.preparing")
        case .listening: String(localized: "voice.state.listening")
        case .stopping: String(localized: "voice.state.stopping")
        case .unavailable: String(localized: "voice.unavailable")
        case .failed: String(localized: "voice.failed")
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.octagon")
                .foregroundStyle(FloeTheme.destructive)
                .accessibilityHidden(true)
            Text(message)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(FloeTheme.destructive)
            Spacer()
            Button {
                attachmentError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(FloeTheme.destructive)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 28, minHeight: 28)
            .accessibilityLabel(Text("action.done"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func infoBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(FloeTheme.success)
            Text(message)
                .font(FloeTheme.Typography.metadata)
            Spacer()
            Button {
                slashNotice = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .frame(minWidth: 28, minHeight: 28)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Lightweight live waveform. The transcriber does not expose raw audio
/// metering, so this intentionally communicates an active capture session
/// without fabricating an amplitude measurement. Reduced Motion renders a
/// stable equalizer instead of continuously animating.
private struct VoiceWaveformView: View {
    let isActive: Bool
    let reduceMotion: Bool

    var body: some View {
        if isActive && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 18.0)) { context in
                bars(phase: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            bars(phase: 0)
        }
    }

    private func bars(phase: TimeInterval) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<15, id: \.self) { index in
                let oscillation = abs(sin(phase * 4.2 + Double(index) * 0.72))
                let envelope = 0.42 + 0.58 * sin(Double(index + 1) / 16.0 * .pi)
                Capsule(style: .continuous)
                    .fill(isActive ? FloeTheme.primary : Color.secondary.opacity(0.5))
                    .frame(width: 3, height: isActive ? 6 + 25 * oscillation * envelope : 5)
            }
        }
        .frame(maxHeight: .infinity)
        .animation(reduceMotion ? nil : .linear(duration: 0.06), value: phase)
    }
}
#endif
