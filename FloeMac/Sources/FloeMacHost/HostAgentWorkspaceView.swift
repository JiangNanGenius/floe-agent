// SPDX-License-Identifier: MPL-2.0

import FloeCore
import FloeAgentRuntime
import FloeMacSelfCore
import FloePersistence
import SwiftUI
#if FLOE_UNIFIED_MAC
import AppKit
import CoreTransferable
import ImageIO
import PhotosUI
import UniformTypeIdentifiers
#endif

struct HostAgentWorkspaceView: View {
    @ObservedObject var workspace: HostAgentWorkspace
    var workspaceDraft: Binding<String>? = nil
    var captureDraftCommit: (() -> (() -> Void))? = nil
    var openModelSettings: (() -> Void)? = nil
    var openPermissionSettings: (() -> Void)? = nil
    var openFiles: (() -> Void)? = nil
    var openTaskPermissions: (() -> Void)? = nil
    var openImageWorkbench: (() -> Void)? = nil
    var findRequest: UUID? = nil
    var findConversationID: UUID? = nil
    var requestedMessageID: UUID? = nil
    var didHandleSearchResult: ((UUID, UUID) -> Void)?
    @State private var standaloneDraft = ""
    #if FLOE_UNIFIED_MAC
    #if FLOE_MAC_HOST_SMOKE
    static var smokeAttachmentFrames: [String: CGRect] = [:]
    static var smokeExpandFrame: CGRect?
    static var smokeHistoryContinueFrame: CGRect?
    static var smokeGoalContinueFrame: CGRect?
    static var smokeLocatedMessageID: UUID?
    #endif
    @StateObject private var search: ThreadSearchModel
    @ObservedObject private var voiceSession: MacVoiceSession
    @State private var promptFocusRequest: UUID?
    @State private var editingPrompt = false
    @State private var promptSelection = NSRange(location: 0, length: 0)
    @State private var attachmentPreview: MacConversationAttachmentPreview?
    @State private var attachmentSelection: UUID?
    @State private var choosingAttachments = false
    @State private var choosingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var photoOrigin: UUID?
    @State private var photoProject: UUID?
    @State private var attachmentImport: Task<Void, Never>?
    @State private var attachmentImportID: UUID?
    @State private var showAttachmentError = false
    @State private var textImportTask: Task<Void, Never>?
    @State private var textImportAttachmentID: UUID?
    @State private var showTextImportError = false
    @State private var textImportFoundNoText = false
    @State private var goalToEdit: ConversationGoal?
    @State private var goalPendingDeletion: ConversationGoal?
    @State private var goalForConfirmation: ConversationGoal?
    @State private var editingQueuedInput: PendingUserInput?
    @State private var hiddenPlanConfirmations: Set<ThreadPlanConfirmationPresentationKey> = []
    private var mode: HostAgentMode { workspace.composerMode }
    #else
    @State private var showingSettings = false
    #endif

    init(workspace: HostAgentWorkspace, workspaceDraft: Binding<String>? = nil,
         captureDraftCommit: (() -> (() -> Void))? = nil,
         openModelSettings: (() -> Void)? = nil, openPermissionSettings: (() -> Void)? = nil, openFiles: (() -> Void)? = nil,
         openTaskPermissions: (() -> Void)? = nil,
         openImageWorkbench: (() -> Void)? = nil, findRequest: UUID? = nil,
         findConversationID: UUID? = nil, requestedMessageID: UUID? = nil,
         didHandleSearchResult: ((UUID, UUID) -> Void)? = nil) {
        self.workspace = workspace
        self.workspaceDraft = workspaceDraft
        self.captureDraftCommit = captureDraftCommit
        self.openModelSettings = openModelSettings
        self.openPermissionSettings = openPermissionSettings
        self.openFiles = openFiles
        self.openTaskPermissions = openTaskPermissions
        self.openImageWorkbench = openImageWorkbench
        self.didHandleSearchResult = didHandleSearchResult
        self.requestedMessageID = requestedMessageID
        self.findRequest = findRequest
        self.findConversationID = findConversationID
        #if FLOE_UNIFIED_MAC
        _voiceSession = ObservedObject(wrappedValue: workspace.voiceSession)
        _search = StateObject(wrappedValue: ThreadSearchModel(
            provider: { [weak workspace] query in
                guard let workspace, let id = findConversationID, workspace.selectedID == id else {
                    return ThreadSearchResult(hits: [], includesDurableHistory: false)
                }
                return await workspace.searchTranscript(query, in: id)
            },
            reveal: { [weak workspace] hit in
                guard let workspace, let id = findConversationID else { return false }
                return await workspace.revealMessage(hit.messageID, in: id)
            }
        ))
        #endif
    }

    private var draft: Binding<String> {
        workspaceDraft ?? $standaloneDraft
    }

    private func submitDraft(workspaceID: UUID? = nil, mode: HostAgentMode = .chat) {
        let binding = draft
        let submitted = binding.wrappedValue
        workspace.send(submitted, workspaceID: workspaceID, mode: mode,
            onAdmitted: draftCommit(for: binding, submitted: submitted))
    }

    private func draftCommit(for binding: Binding<String>, submitted: String) -> () -> Void {
        captureDraftCommit?() ?? { if binding.wrappedValue == submitted { binding.wrappedValue = "" } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if !FLOE_UNIFIED_MAC
            HStack {
                Picker("host.chat.history", selection: Binding(
                    get: { workspace.selectedID },
                    set: { id in Task { await workspace.select(id) } }
                )) {
                    Text("host.chat.new").tag(nil as UUID?)
                    ForEach(workspace.conversations) { conversation in
                        Text(conversation.title).tag(Optional(conversation.id))
                    }
                }
                Spacer()
                Button(workspace.modelName ?? String(localized: "host.chat.provider")) { showingSettings = true }
            }
            .disabled(!workspace.isReady || workspace.isSending || workspace.isTerminating)
            #endif
            if workspace.isPreparing {
                ProgressView("host.chat.opening")
            } else if !workspace.isReady {
                Button("host.chat.tryAgain") { Task { await workspace.prepare() } }
                    .disabled(workspace.isTerminating)
            } else if workspace.isLoadingHistory {
                ProgressView("host.chat.opening")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if workspace.historyLoadFailed {
                VStack(spacing: 10) {
                    Text("host.chat.historyUnavailable")
                    Button("host.chat.tryAgain") { Task { await workspace.select(workspace.selectedID) } }
                        .disabled(workspace.isTerminating)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                #if FLOE_UNIFIED_MAC
                if search.isActive {
                    ThreadSearchBar(model: search)
                        .id(findRequest)
                        #if FLOE_MAC_HOST_SMOKE
                        .onAppear { workspace.smokeConversationSearchMounted = true }
                        .onDisappear { workspace.smokeConversationSearchMounted = false }
                        #endif
                }
                pendingPlanReview
                if let id = workspace.selectedID {
                    MacChildTasksView(controller: workspace.childSubagents, conversationID: id)
                }
                conversation
                if let question = workspace.pendingQuestion {
                    HostAgentQuestionCardView(question: question, note: workspace.pendingQuestionRecoveryNote, submit: { target, answer in
                        await workspace.answerQuestion(target: target, answer: answer)
                    }, cancel: { requestID in
                        await workspace.declineQuestion(requestID: requestID)
                    }, draftChanged: { target, draft in
                        Task { await workspace.saveQuestionDraft(target: target, answer: draft) }
                    })
                    .id(question.cardIdentity)
                    .padding(.horizontal, 12)
                }
                if let run = workspace.continuableRun {
                    VStack(alignment: .leading, spacing: 3) {
                        if workspace.needsInterruptedRunReview {
                            Label(MacPermissionsText.t("待核对", "Needs review"), systemImage: "exclamationmark.circle")
                                .font(.callout.weight(.semibold))
                                .accessibilityIdentifier("mac.agent.run.reviewRequired")
                            Text(MacPermissionsText.t(
                                "上次回合的结果仍待核对。请查看执行记录和工作区文件。",
                                "Review the previous round’s execution records and workspace files."))
                                .font(.caption).foregroundStyle(.secondary)
                        } else if let summary = workspace.restoredApprovalSummary {
                            Text(MacPermissionsText.t("已保存的审批请求", "Saved approval request")).font(.callout.weight(.semibold))
                            Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Button {
                            Task { await workspace.continueFromHistory(run) }
                        } label: {
                            if workspace.needsInterruptedRunReview {
                                Label(MacPermissionsText.t("开始新的核对回合", "Start a separate review"), systemImage: "doc.text.magnifyingglass")
                            } else if workspace.restoredApprovalSummary != nil {
                                Label(MacPermissionsText.t("继续审批", "Resume approval"), systemImage: "checkmark.shield")
                            } else {
                                Label(LocalizedStringKey(workspace.resumesOriginalRun ? "mac.agent.continueTask" : "mac.agent.continueHistory"),
                                      systemImage: "play")
                            }
                        }
                        .frame(minHeight: FloeTheme.minimumTarget)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("mac.agent.run.continue")
                        #if FLOE_MAC_HOST_SMOKE
                        .background(MacWorkbenchButtonFrameReader { frame in Self.smokeHistoryContinueFrame = frame })
                        #endif
                    }
                    .padding(.horizontal, 16)
                }
                if let failed = workspace.failedUserMessage,
                   CredentialMessagePart.clipboardText(failed.content) != nil, !workspace.isSending {
                    Button("mac.agent.editFailedPrompt") {
                        let binding = draft
                        Task {
                            await workspace.editFailedInput(failed) { text in
                                guard binding.wrappedValue.isEmpty else { return false }
                                binding.wrappedValue = text
                                promptFocusRequest = UUID()
                                return true
                            }
                        }
                    }
                    .disabled(!draft.wrappedValue.isEmpty || !workspace.stagedAttachments.isEmpty)
                    .padding(.horizontal, 16)
                }
                if let goal = workspace.goal { goalCard(goal) }
                composer
                #else
                conversation
                HStack(alignment: .bottom) {
                    TextField("host.chat.prompt", text: draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...7)
                    if workspace.isSending {
                        Button("host.chat.stop") { workspace.stop() }
                            .disabled(!workspace.canStop)
                    } else {
                        Button("host.chat.send") {
                            submitDraft()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.isTerminating)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
                #endif
            }
            if let notice = workspace.notice {
                #if FLOE_UNIFIED_MAC
                VStack(alignment: .leading, spacing: 0) {
                    ErrorEventView(message: notice)
                    if workspace.showsModelSettingsForFailure, let openModelSettings {
                        Button(action: openModelSettings) {
                            Label("mac.settings.models", systemImage: "gearshape")
                                .padding(.horizontal, 10)
                                .frame(minHeight: FloeTheme.minimumTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("workbench.providerFailure.settings")
                    }
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                #else
                Text(notice).foregroundStyle(.secondary)
                #endif
            }
        }
        #if FLOE_UNIFIED_MAC
        .background(FloeTheme.readingSurface)
        .environment(\.runOutputArtifactRoot, workspace.runOutputArtifactRoot)
        .task(id: [findRequest, workspace.selectedID]) {
            guard findRequest != nil, let id = findConversationID, id == workspace.selectedID else { return }
            search.begin()
        }
        .task(id: search.query) {
            guard search.isActive else { return }
            if search.hasQuery {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await search.search()
        }
        .onDisappear {
            if voiceSession.isActive { voiceSession.stop() }
            search.end()
            attachmentImport?.cancel()
            attachmentImport = nil
            attachmentImportID = nil
            textImportTask?.cancel()
            textImportTask = nil
            textImportAttachmentID = nil
        }
        .onChange(of: workspace.attachmentOwnerID) { _, _ in
            if voiceSession.isActive { voiceSession.stop() }
        }
        .sheet(isPresented: $editingPrompt, onDismiss: { promptFocusRequest = UUID() }) {
            VStack(spacing: 0) {
                MacExpandedComposer(text: draft, selection: $promptSelection, canSend: canSubmitComposer,
                                    sendLabel: composerSubmitLabel, submit: submitComposer)
                if !workspace.stagedAttachments.isEmpty {
                    attachmentStrip
                        .padding(.bottom, 6)
                        .background(FloeTheme.readingSurface)
                }
            }
        }
        .sheet(item: $attachmentPreview) { preview in
            MacConversationAttachmentSheet(preview: preview)
        }
        .onChange(of: workspace.draftSelectionID) {
            editingPrompt = false
            attachmentPreview = nil
            promptSelection = NSRange(location: 0, length: 0)
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            guard photoOrigin == workspace.draftSelectionID, photoProject == workspace.selectedWorkspaceID else { return }
            importAttachments([.photo(item)])
        }
        .onChange(of: workspace.rejectedPrompt) { _, text in
            if let text, draft.wrappedValue.isEmpty { draft.wrappedValue = text }
        }
        .fileImporter(isPresented: $choosingAttachments, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            defer { attachmentSelection = nil }
            guard attachmentSelection == workspace.draftSelectionID, acceptsAttachmentImport else { return }
            switch result {
            case .success(let urls):
                let accepted = workspace.stageAttachments(urls)
                showAttachmentError = accepted.count < urls.count
            case .failure(let error):
                showAttachmentError = (error as NSError).code != NSUserCancelledError
            }
        }
        .alert("mac.workspace.attachFailed", isPresented: $showAttachmentError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: MacPermissionsText.t("每次最多添加 8 个附件。请选择可读取的本机文件或图片，单个文件上限 32 MiB，图片可缩小后重试。",
                                                "Attach up to 8 items. Choose readable local files up to 32 MiB each, or try a smaller image."))
        }
        .alert(Text(verbatim: MacComposerInputText.t("导入识别文字", "Import Recognized Text")),
               isPresented: $showTextImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: textImportFoundNoText
                ? MacComposerInputText.t("在这张图片中没有识别到可用文字。", "No usable text was recognized in this image.")
                : MacComposerInputText.t("图片无法读取或识别失败，请重试。", "The image could not be read or recognition failed. Try again."))
        }
        .onChange(of: workspace.goalBuilderRequest, initial: true) {
            guard workspace.goalBuilderRequest != nil else { return }
            workspace.goalBuilderRequest = nil
            if let editableGoal { presentGoalEditor(editableGoal) }
        }
        .sheet(item: $goalToEdit) { goal in
            GoalBuilderSheet(goal: goal, showsDefinitionFields: false, errorMessage: workspace.notice) { objective, criteria, blockers, stops in
                await workspace.editGoal(goal, objective: objective, criteria: criteria, blockers: blockers, stops: stops)
            }
            .frame(minWidth: 420, idealWidth: 485, minHeight: 225, idealHeight: 285)
        }
        .confirmationDialog(MacPermissionsText.t("删除目标？", "Delete goal?"),
            isPresented: Binding(get: { goalPendingDeletion != nil }, set: { if !$0 { goalPendingDeletion = nil } }),
            titleVisibility: .visible, presenting: goalPendingDeletion) { goal in
                Button(MacPermissionsText.t("删除目标", "Delete goal"), role: .destructive) {
                    Task { await workspace.deleteGoal(goal) }
                }
            } message: { _ in
                Text(MacPermissionsText.t("目标将停止推进后续回合。本轮继续，会话、文件和已有结果会保留。",
                                         "The goal stops advancing after this round. The conversation, files, and results are kept."))
            }
        .sheet(item: $goalForConfirmation) { goal in
            MacGoalConfirmationView(goal: goal) { steps, criteria in
                await workspace.confirmGoal(goal, completedSteps: steps, confirmedCriteria: criteria)
            }
        }
        .sheet(item: $editingQueuedInput) { input in
            PendingInputEditor(input: input) { text in
                Task { await workspace.editQueued(input, content: text) }
            }
            .frame(minWidth: 420, idealWidth: 500, minHeight: 270)
        }
        #else
        .padding(20)
        #endif
        .task { await workspace.prepare() }
        #if !FLOE_UNIFIED_MAC
        .sheet(isPresented: $showingSettings) {
            HostAgentProviderForm(workspace: workspace, isPresented: $showingSettings)
        }
        #endif
    }

    @ViewBuilder
    private func earlierHistoryButton(_ scroll: ScrollViewProxy) -> some View {
        if workspace.hasEarlierMessages {
            Button("mac.workspace.loadEarlierMessages") {
                let firstID = workspace.messages.first?.id
                let conversationID = workspace.selectedID
                Task {
                    await workspace.loadEarlierMessages()
                    if workspace.selectedID == conversationID, let firstID,
                       workspace.messages.first?.id != firstID {
                        scroll.scrollTo(firstID, anchor: .top)
                    }
                }
            }
            .disabled(workspace.isLoadingEarlierMessages || workspace.isTerminating)
            .accessibilityIdentifier("workspace.history.earlier")
            .frame(maxWidth: .infinity)
        }
    }

    #if FLOE_UNIFIED_MAC
    private var composerSendRoute: RunningInputSendRoute {
        RunningInputModePolicy.sendRoute(isRunActive: workspace.isSending, mode: workspace.conversationRunningInputMode)
    }

    @ViewBuilder private var pendingInputs: some View {
        if let id = workspace.selectedID, let inputs = workspace.queuedInputs[id], !inputs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                PendingInputQueueView(
                    inputs: inputs, canSteer: workspace.canSteer,
                    onEdit: { editingQueuedInput = $0 },
                    onDelete: { input in Task { await workspace.cancelQueued(input) } },
                    onMove: { input, offset in Task { await workspace.moveQueued(input, offset: offset) } },
                    onSteer: { input in Task { await workspace.promoteQueuedToGuidance(input) } },
                    onDemote: { input in Task { await workspace.demoteQueuedGuidance(input) } }
                )
                if !workspace.isSending {
                    Button("mac.agent.sendNextQueued") { Task { await workspace.startNextQueued(id) } }
                        .padding(.horizontal, 12)
                }
            }
            .frame(maxWidth: .infinity)
            #if FLOE_MAC_HOST_SMOKE
            .background(MacWorkbenchButtonFrameReader { workspace.smokePendingInputsFrame = $0 })
            #endif
        }
    }

    private var composerSubmitLabel: LocalizedStringKey {
        LocalizedStringKey(composerSendRoute.composerTitleKey)
    }

    private var composerPlaceholder: String {
        guard workspace.isSending else { return String(localized: "host.chat.prompt") }
        return workspace.conversationRunningInputMode == .steer
            ? String(localized: "mac.agent.steerPrompt") : String(localized: "mac.agent.queuePrompt")
    }

    private var canSubmitComposer: Bool {
        guard attachmentImport == nil, !voiceSession.isActive, !workspace.isTerminating,
              workspace.selectedID == findConversationID,
              MacComposerTextInput.hasText(draft.wrappedValue) else { return false }
        if workspace.isSending { return workspace.canSteer }
        let compatible = mode == .chat || workspace.composerProvider?.model.capabilities.contains(.tools) == true
        return workspace.composerProvider != nil && compatible && !workspace.isAcceptingPlan
    }

    private func submitComposer() {
        guard canSubmitComposer, (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        if workspace.isSending {
            // iPad parity: a running task accepts text plus the currently
            // staged attachments as one queued/steered message. Text stays
            // required (an attachment-only payload is not part of the shared
            // contract); the host binds the exact staged refs to the durable
            // row and only the submitted set is consumed from the strip.
            let attachments = workspace.stagedAttachments
            let binding = draft
            let text = binding.wrappedValue
            let clear = draftCommit(for: binding, submitted: text)
            workspace.submitRunningInput(text, mode: workspace.conversationRunningInputMode,
                                         attachments: attachments, onAccepted: clear)
        } else {
            let project = workspace.selectedID == nil ? workspace.selectedWorkspaceID : nil
            submitDraft(workspaceID: project, mode: mode)
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            pendingInputs
            if workspace.isReady, !workspace.isLoadingHistory, !workspace.isSending,
               !workspace.taskModelChoices.contains(where: \.canSelectAsPrimary),
               let openModelSettings {
                FloeModelSetupBanner(actionTitle: "host.chat.provider", openSetup: openModelSettings)
                    .padding(.horizontal, 12)
            }
            inlineComposer
        }
        .frame(maxWidth: 824)
        .padding(.horizontal, 6)
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity)
    }

    private var inlineComposer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !workspace.isSending, mode != .chat, let provider = workspace.composerProvider,
               !provider.model.capabilities.contains(.tools) {
                HStack {
                    Text("mac.agent.toolsModelRequired").font(.caption).foregroundStyle(.secondary)
                    if let openModelSettings {
                        Button("mac.settings.models", action: openModelSettings).controlSize(.small)
                    }
                }
            }
            if !workspace.isSending, (mode == .agent || mode == .goal), !workspace.allowsWorkspaceWrites,
               let openPermissionSettings {
                HStack {
                    Label("mac.workspace.readOnlyActions", systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Permissions", action: openPermissionSettings).controlSize(.small)
                        .accessibilityIdentifier("composer.openPermissions")
                }
            }
            if !workspace.stagedAttachments.isEmpty {
                attachmentStrip
            }
            if attachmentImport != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: MacPermissionsText.t("正在添加附件…", "Adding attachments…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ComposerResponsiveRow(spacing: 4, stackedSpacing: 2) {
                composerAttachments
                    .composerResponsiveLeadingControl()
                composerInput
                    .composerResponsiveFieldSlot()
                voiceControls
                Button { editingPrompt = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(ComposerButtonStyle())
                .help("mac.composer.expand")
                .accessibilityLabel("mac.composer.expand")
                .accessibilityIdentifier("thread.composer.expand")
                #if FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { Self.smokeExpandFrame = $0 })
                #endif
                .disabled(workspace.isTerminating || (workspace.isSending && workspace.selectedID == nil))
                if workspace.isSending {
                    Button(action: workspace.stop) {
                        FloeComposerActionGlyph(systemImage: "stop.fill", enabled: workspace.canStop, destructive: true)
                    }
                    .buttonStyle(ComposerButtonStyle())
                    .accessibilityLabel("host.chat.stop")
                    .accessibilityIdentifier("composer.stop")
                    .disabled(!workspace.canStop)
                    #if FLOE_MAC_HOST_SMOKE
                    .background(MacWorkbenchButtonFrameReader { workspace.smokeStopFrame = $0 })
                    #endif
                }
                Button(action: submitComposer) {
                    FloeComposerActionGlyph(systemImage: composerSendRoute.composerSymbol, enabled: canSubmitComposer)
                }
                .buttonStyle(ComposerButtonStyle())
                .accessibilityLabel(Text(composerSubmitLabel))
                .accessibilityIdentifier("composer.send")
                .help(workspace.isSending ? Text(composerSubmitLabel)
                      : (workspace.composerProvider == nil ? Text("host.chat.configureFirst") : Text("mac.workspace.sendShortcut")))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSubmitComposer)
                #if FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { workspace.smokeSteerFrame = $0 })
                #endif
            }
            if voiceSession.isActive || voiceSession.problem != nil {
                voiceStatus
            }
            if let openModelSettings {
                ComposerContextLayout {
                    modelControl(openSettings: openModelSettings).disabled(workspace.isSending)
                    if let provider = workspace.composerProvider { reasoningMenu(provider.model) }
                    if mode != .chat { composerWorkspace }
                    modeControl.disabled(workspace.isSending)
                    if workspace.isSending { runningInputControl }
                    if mode != .chat {
                        permissionControl.disabled(workspace.isStopping || workspace.isResolvingApproval || (workspace.isSending && workspace.runPhase == nil))
                    }
                }
                .disabled(workspace.isTerminating || workspace.isAcceptingPlan)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .modifier(FloeThreadComposerChrome())
        #if FLOE_MAC_HOST_SMOKE
        .background(MacWorkbenchButtonFrameReader { workspace.smokeComposerSurfaceFrame = $0 })
        #endif
        .dropDestination(for: URL.self) { urls, _ in
            guard acceptsAttachmentImport else { return false }
            let staged = workspace.stageAttachments(urls.filter(\.isFileURL))
            showAttachmentError = staged.count < urls.count
            return !staged.isEmpty
        }
    }

    private var composerInput: some View {
        let editable = !workspace.isTerminating && (!workspace.isSending || workspace.selectedID != nil)
        let paste: (() -> Void)? = acceptsAttachmentImport ? { pasteAttachments() } : nil
        return MacComposerTextInput(text: draft, placeholder: composerPlaceholder, focusRequest: promptFocusRequest,
                                    isEditable: editable, pasteAttachments: paste, submit: submitComposer)
            .onChange(of: workspace.draftSelectionID, initial: true) {
                if workspace.selectedID == nil { promptFocusRequest = UUID() }
            }
            .frame(minHeight: FloeTheme.minimumTarget)
            .accessibilityIdentifier("thread.composer.input")
            #if FLOE_MAC_HOST_SMOKE
            .background(MacWorkbenchButtonFrameReader { workspace.smokePromptFrame = $0 })
            #endif
    }

    @ViewBuilder private var voiceControls: some View {
        if voiceSession.isActive {
            let dictating = voiceSession.mode == .dictation
            Button {
                if dictating { voiceSession.finishDictation() }
                else { voiceSession.stop() }
            } label: {
                Image(systemName: "stop.circle")
            }
            .buttonStyle(ComposerButtonStyle())
            .help(dictating ? Text("mac.voice.finishDictation") : Text("mac.voice.stop"))
            .accessibilityLabel(dictating ? Text("mac.voice.finishDictation") : Text("mac.voice.stop"))
            .accessibilityIdentifier("thread.composer.voice.stop")
        } else {
            Button { beginVoice(.dictation) } label: { Image(systemName: "mic") }
                .buttonStyle(ComposerButtonStyle())
                .help("mac.voice.dictation")
                .accessibilityLabel("mac.voice.dictation")
                .accessibilityIdentifier("thread.composer.voice.dictate")
                .disabled(!workspace.isReady || workspace.isTerminating || workspace.isLoadingHistory)
            Button { beginVoice(.conversation) } label: { Image(systemName: "waveform") }
                .buttonStyle(ComposerButtonStyle())
                .help("mac.voice.conversation")
                .accessibilityLabel("mac.voice.conversation")
                .accessibilityIdentifier("thread.composer.voice.conversation")
                .disabled(!workspace.isReady || workspace.isTerminating || workspace.isSending
                          || workspace.isLoadingHistory || workspace.composerProvider == nil)
        }
    }

    private var voiceStatus: some View {
        let action: LocalizedStringKey = switch voiceSession.phase {
        case .idle: ""
        case .preparing: "mac.voice.preparing"
        case .listening: "mac.voice.listening"
        case .finishing: "mac.voice.finishing"
        case .waiting: "mac.voice.waiting"
        case .speaking: "mac.voice.speaking"
        }
        return HStack(spacing: 7) {
            if let problem = voiceSession.problem { Text(problem) }
            else {
                Text(action).fontWeight(.medium)
                if voiceSession.phase == .listening, !voiceSession.transcript.isEmpty {
                    Text(voiceSession.transcript).lineLimit(2)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    private func beginVoice(_ mode: MacVoiceSession.Mode) {
        let owner = workspace.attachmentOwnerID
        let binding = draft
        voiceSession.start(mode, locale: workspace.voiceLocale, admit: workspace.admitScheduleWork) { text in
            guard workspace.attachmentOwnerID == owner else { return }
            let current = binding.wrappedValue
            binding.wrappedValue = current.isEmpty || current.last?.isWhitespace == true ? current + text : current + " " + text
            promptFocusRequest = UUID()
        } turn: { text in
            try await workspace.runVoiceTurn(text, owner: owner)
        }
    }

    private var runningInputControl: some View {
        FloeComposerRunningInputMenu(queue: Binding(get: { workspace.conversationRunningInputMode == .queue },
                                                   set: { workspace.selectConversationRunningInputMode($0 ? .queue : .steer) }))
        .menuStyle(.button)
        .buttonStyle(ComposerButtonStyle())
        .menuIndicator(.hidden)
        .accessibilityIdentifier("composer.runningInputMode")
        #if FLOE_MAC_HOST_SMOKE
        .background(MacWorkbenchButtonFrameReader { workspace.smokeRunningModeFrame = $0 })
        #endif
    }

    @ViewBuilder private var composerWorkspace: some View {
        if let openFiles {
            if let owner = workspace.selectedConversationWorkspace {
                Button(action: openFiles) {
                    FloeThreadComposerChip(title: owner.kind == .project ? Text(verbatim: owner.name) : Text("mac.workspace.conversationFolder"),
                                           systemImage: "folder", maximumWidth: 148)
                }
                .buttonStyle(ComposerButtonStyle())
                .help("mac.workspace.browseFiles")
            } else if workspace.selectedID == nil {
                projectControl(openFiles: openFiles).disabled(workspace.isSending)
            }
        }
    }

    /// Keep compact desktop labels while giving the button itself a touch target.
    private struct ComposerButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            FloeTheme.minimumTargetFrame(configuration.label)
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.65 : 1)
        }
    }

    /// Keep each native menu in place as the window changes width, wrapping
    /// in reading order so the last menu is accessible without a trackpad.
    private struct ComposerContextLayout: Layout {
        private let spacing: CGFloat = 4

        private func positions(for sizes: [CGSize], width: CGFloat) -> (origins: [CGPoint], height: CGFloat) {
            var origins: [CGPoint] = []
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            for size in sizes {
                if x > 0, x + size.width > width {
                    x = 0
                    y += rowHeight
                    rowHeight = 0
                }
                origins.append(CGPoint(x: x, y: y))
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
            return (origins, y + rowHeight)
        }

        private func sizes(of subviews: Subviews, width: CGFloat?) -> [CGSize] {
            subviews.map { view in
                let ideal = view.sizeThatFits(.unspecified)
                guard let width, ideal.width > width else { return ideal }
                return view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let sizes = sizes(of: subviews, width: proposal.width)
            let ideal = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(sizes.count - 1, 0))
            let width = min(ideal, proposal.width ?? ideal)
            return CGSize(width: width, height: positions(for: sizes, width: width).height)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let sizes = sizes(of: subviews, width: bounds.width)
            let origins = positions(for: sizes, width: bounds.width).origins
            for (index, view) in subviews.enumerated() {
                view.place(at: CGPoint(x: bounds.minX + origins[index].x, y: bounds.minY + origins[index].y),
                           anchor: .topLeading, proposal: ProposedViewSize(sizes[index]))
            }
        }
    }

    /// Staging stays available while the visible task runs: the in-flight
    /// run captured its attachments at admission, so anything staged now
    /// binds to the next queued or steered message on submit.
    private var acceptsAttachmentImport: Bool {
        workspace.isReady && workspace.selectedID == findConversationID
            && !workspace.isTerminating && !workspace.isLoadingHistory && attachmentImport == nil
    }

    private func pasteAttachments() {
        guard acceptsAttachmentImport else { return }
        let remaining = HostAgentWorkspace.maximumStagedAttachmentCount - workspace.stagedAttachments.count
        let inputs = MacComposerImport.read(.general, limit: remaining)
        guard !inputs.isEmpty else { showAttachmentError = true; return }
        importAttachments(inputs)
    }

    private func importAttachments(_ inputs: [MacComposerImport.Input]) {
        guard acceptsAttachmentImport else { return }
        let selection = workspace.draftSelectionID
        let owner = workspace.attachmentOwnerID
        let project = workspace.selectedWorkspaceID
        let importID = UUID()
        attachmentImportID = importID
        attachmentImport = Task { @MainActor in
            defer {
                if attachmentImportID == importID { attachmentImport = nil; attachmentImportID = nil }
            }
            @MainActor func originIsCurrent() -> Bool {
                !Task.isCancelled && workspace.isReady && workspace.draftSelectionID == selection
                    && workspace.attachmentOwnerID == owner && workspace.selectedWorkspaceID == project
                    && !workspace.isTerminating && !workspace.isLoadingHistory
            }
            var failed = false
            for input in inputs {
                guard originIsCurrent() else { return }
                guard workspace.stagedAttachments.count < HostAgentWorkspace.maximumStagedAttachmentCount else {
                    failed = true
                    break
                }
                do {
                    switch input {
                    case .file(let url):
                        if workspace.stageAttachments([url]).isEmpty { failed = true }
                    case .invalid:
                        failed = true
                    case .image, .photo:
                        let image = try await MacComposerImport.prepare(input)
                        guard originIsCurrent() else { return }
                        if !MacComposerImport.stage(image, in: workspace, owner: owner) { failed = true }
                    }
                } catch { failed = true }
            }
            if originIsCurrent() { showAttachmentError = failed }
        }
    }

    private var composerAttachments: some View {
        Menu {
            Button(MacPermissionsText.t("照片图库…", "Photo Library…"), systemImage: "photo.on.rectangle") {
                photoOrigin = workspace.draftSelectionID
                photoProject = workspace.selectedWorkspaceID
                choosingPhoto = true
            }
            Button("mac.workspace.attachFiles", systemImage: "folder") {
                attachmentSelection = workspace.draftSelectionID
                choosingAttachments = true
            }
            Button(MacPermissionsText.t("粘贴附件", "Paste Attachment"), systemImage: "document.on.clipboard") {
                pasteAttachments()
            }
            if let openImageWorkbench {
                Divider()
                Button("mac.settings.images", systemImage: "photo.badge.plus", action: openImageWorkbench)
            }
        } label: {
            FloeWorkbenchControlIcon(systemImage: "paperclip")
        }
        .menuStyle(.button)
        .buttonStyle(ComposerButtonStyle())
        .menuIndicator(.hidden)
        .help("mac.workspace.attachFiles")
        .accessibilityLabel("mac.workspace.attachFiles")
        .disabled(!acceptsAttachmentImport)
    }

    @ViewBuilder
    private var pendingPlanReview: some View {
        if let plan = workspace.plan, plan.awaitsConfirmation {
            let key = ThreadPlanConfirmationPresentationKey(plan)
            if hiddenPlanConfirmations.contains(key) {
                Button {
                    hiddenPlanConfirmations.remove(key)
                } label: {
                    Label("mac.agent.reopenPlan", systemImage: "list.bullet.clipboard")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .accessibilityIdentifier("thread.plan.reopen")
                #if FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { workspace.smokeReopenPlanFrame = $0 })
                #endif
            } else {
                planReview(for: plan).id(key)
            }
        }
    }

    private func planReview(for plan: PlanDraft) -> some View {
        var review = ThreadPlanReview(plan: plan, isAccepting: workspace.isAcceptingPlan,
                                      actionsDisabled: workspace.isSending || workspace.isTerminating,
                                      onDismiss: { hiddenPlanConfirmations.insert(.init(plan)) }) { execution in
            Task { await workspace.confirmAndRunPlan(plan, as: execution) }
        }
        #if FLOE_MAC_HOST_SMOKE
        review.onCloseFrame = { frame in workspace.smokeClosePlanFrame = frame }
        review.onNormalActionFrame = { frame in workspace.smokePlanExecuteFrame = frame }
        #endif
        return review
    }

    private func retryPlan(_ snapshot: PlanConfirmationSnapshot) -> (() -> Void)? {
        guard workspace.pendingAcceptedPlan == snapshot, !workspace.isSending,
              !workspace.isAcceptingPlan, !workspace.isTerminating else { return nil }
        return { workspace.runAcceptedPlan(snapshot) }
    }

    private func presentGoalEditor(_ goal: ConversationGoal) {
        goalToEdit = goal
        workspace.notice = nil
    }

    private func goalCard(_ goal: ConversationGoal) -> some View {
        let statusKey = LocalizedStringKey("mac.agent.goal." + goal.status.rawValue)
        let canEdit = editableGoal?.id == goal.id && !workspace.isChangingSelectedGoal
        let summary = VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label("mac.agent.goalStatus", systemImage: "target").font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(statusKey).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("mac.agent.goal.status")
            }
            Text(verbatim: goal.objective).font(.subheadline).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                if canEdit {
                    Button { presentGoalEditor(goal) } label: { summary }
                        .buttonStyle(.plain)
                        .accessibilityLabel("mac.agent.editGoal")
                        .accessibilityValue(goal.objective)
                        .accessibilityIdentifier("mac.agent.goal.editSummary")
                } else {
                    summary
                }
                Group {
                    if workspace.isChangingSelectedGoal {
                        ProgressView().controlSize(.small)
                    } else if workspace.canContinueGoal(goal) {
                        Button("mac.agent.continueGoal", systemImage: "play.fill") { workspace.continueGoal(goal) }
                            .accessibilityIdentifier("mac.agent.goal.continue")
                            #if FLOE_MAC_HOST_SMOKE
                            .background(MacWorkbenchButtonFrameReader { Self.smokeGoalContinueFrame = $0 })
                            #endif
                    } else if workspace.canPauseGoal(goal) {
                        Button("mac.agent.pauseGoal", systemImage: "pause.fill") { Task { await workspace.pauseGoal(goal) } }
                            .accessibilityIdentifier("mac.agent.goal.pause")
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                Menu {
                    if workspace.canContinueGoal(goal), workspace.canPauseGoal(goal) {
                        Button("mac.agent.pauseGoal", systemImage: "pause") { Task { await workspace.pauseGoal(goal) } }
                            .accessibilityIdentifier("mac.agent.goal.pause")
                    }
                    if canEdit {
                        Button("mac.agent.editGoal", systemImage: "pencil") { presentGoalEditor(goal) }
                            .accessibilityIdentifier("mac.agent.goal.edit")
                    }
                    Button(MacPermissionsText.t("删除目标", "Delete goal"), systemImage: "trash", role: .destructive) {
                        goalPendingDeletion = goal
                    }
                    .accessibilityIdentifier("mac.agent.goal.delete")
                } label: {
                    Image(systemName: "ellipsis.circle").frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                }
                .menuIndicator(.hidden)
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel("mac.agent.goalActions")
                .accessibilityIdentifier("mac.agent.goal.actions")
                .disabled(workspace.isChangingSelectedGoal)
            }
            let completedSteps = goal.steps.filter { $0.status == .completed }.count
            ProgressView(value: Double(completedSteps), total: Double(max(1, goal.steps.count)))
                .accessibilityLabel("mac.agent.goalProgress")
                .accessibilityValue(Text("mac.agent.goalProgressValue \(completedSteps) \(max(1, goal.steps.count))"))
                .accessibilityIdentifier("mac.agent.goal.progress")
            if let reason = GoalEvidenceReviewContract.blockerExplanation(for: goal) {
                Text(verbatim: reason)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("thread.goal.blockedReason")
            }
            if workspace.canConfirmGoal(goal) {
                Button("mac.agent.confirmGoal", systemImage: "checkmark") { goalForConfirmation = goal }
                    .accessibilityIdentifier("mac.agent.goal.confirm")
            }
            if goal.status == .paused, workspace.isSending {
                Text("mac.agent.goalPausedRunning")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mac.agent.goal.pausedRunning")
            }
            DisclosureGroup("mac.agent.goalCriteria") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(goal.acceptanceCriteria) { criterion in
                            Label {
                                Text(verbatim: criterion.text)
                            } icon: {
                                Image(systemName: criterion.isSatisfied ? "checkmark.circle" : "circle")
                            }
                        }
                        if !goal.steps.isEmpty {
                            Text("mac.agent.goalStepList").font(.headline)
                            ForEach(goal.steps) { step in
                                Label {
                                    Text(verbatim: step.title).lineLimit(1)
                                        .help(step.title)
                                } icon: {
                                    Image(systemName: stepStatusSymbol(step.status))
                                }
                            }
                            .accessibilityIdentifier("mac.agent.goal.steps")
                        }
                        if !goal.evidence.isEmpty {
                            Text("mac.agent.goalEvidence").font(.headline)
                            ForEach(Array(goal.evidence.suffix(8))) { evidence in
                                Text(verbatim: evidence.summary).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
            }
        }
        .controlSize(.small)
        .modifier(HostTaskCardChrome())
        .accessibilityIdentifier("mac.agent.goalCard")
    }

    private var editableGoal: ConversationGoal? { workspace.goal }

    /// Saved step state shown in the goal disclosure, aligned with the
    /// criterion icons: open circle until done, crossed out on failure.
    private func stepStatusSymbol(_ status: GoalStepStatus) -> String {
        switch status {
        case .completed: "checkmark.circle"
        case .failed: "xmark.circle"
        case .skipped: "minus.circle"
        case .inProgress: "circle.lefthalf.filled"
        case .pending: "circle"
        }
    }

    private func reasoningMenu(_ model: ModelProfile) -> some View {
        let inChat = mode == .chat
        let current = inChat ? workspace.chatReasoning.rawValue : model.effectiveReasoningEffort.rawValue
        return Menu {
            if inChat {
                ForEach(ChatReasoningPreference.allCases) { choice in
                    Button { Task { await workspace.changeChatReasoning(choice) } } label: {
                        reasoningChoice(choice.rawValue, selected: current)
                    }
                }
            } else {
                ForEach(ModelReasoningEffort.allCases) { choice in
                    Button { workspace.changeModelEffort(choice, modelID: model.id) } label: {
                        reasoningChoice(choice.rawValue, selected: current)
                    }
                }
            }
        } label: {
            FloeThreadComposerChip(title: Text(LocalizedStringKey("mac.reasoning." + current)),
                                   systemImage: "brain.head.profile")
        }
        .menuStyle(.button)
        .buttonStyle(ComposerButtonStyle())
        .menuIndicator(.hidden)
        .disabled(workspace.isSending || workspace.isLoadingHistory || workspace.savingChatReasoning)
        .accessibilityIdentifier("composer.reasoning")
        .accessibilityLabel("mac.reasoning.label")
        .help("mac.reasoning.label")
        #if FLOE_MAC_HOST_SMOKE
        .background(MacWorkbenchButtonFrameReader { workspace.smokeReasoningFrame = $0 })
        #endif
    }

    @ViewBuilder private func reasoningChoice(_ choice: String, selected: String) -> some View {
        let title = LocalizedStringKey("mac.reasoning." + choice)
        if choice == selected { Label(title, systemImage: "checkmark") }
        else { Text(title) }
    }

    private var modeControl: some View {
        FloeComposerModeMenu(modes: HostAgentMode.allCases,
                             selection: Binding(get: { mode }, set: { workspace.composerMode = $0 }),
                             title: { $0.title }, symbol: { $0.symbol },
                             editGoalTitle: String(localized: "mac.agent.editGoal"),
                             editGoal: editableGoal.map { goal in { presentGoalEditor(goal) } }, goal: .goal)
        .menuStyle(.button)
        .buttonStyle(ComposerButtonStyle())
        .menuIndicator(.hidden)
        .accessibilityIdentifier("mac.composer.mode")
        #if FLOE_MAC_HOST_SMOKE
        .background(MacWorkbenchButtonFrameReader { workspace.smokeModeFrame = $0 })
        #endif
    }

    private var permissionControl: some View {
        Button { openTaskPermissions?() } label: {
            FloeThreadComposerChip(title: Text(FloeTaskApprovalSection.title(workspace.taskApprovalMode)),
                                   systemImage: "lock.shield")
        }
        .buttonStyle(ComposerButtonStyle())
        .disabled(openTaskPermissions == nil || workspace.savingApprovalMode)
        .accessibilityIdentifier("composer.approvalMode")
        #if FLOE_MAC_HOST_SMOKE
        .background(MacWorkbenchButtonFrameReader { workspace.smokeTaskPermissionsFrame = $0 })
        .onDisappear { workspace.smokeTaskPermissionsFrame = nil }
        #endif
        .accessibilityLabel(MacPermissionsText.t("审批模式", "Approval mode"))
        .help(MacPermissionsText.t("选择此任务的审批模式", "Choose the approval mode for this task"))
    }

    private var attachmentStrip: some View {
        MacComposerInputAttachmentStrip(
            items: workspace.stagedAttachments.map { attachment in
                let isImage = attachment.kind == .image
                let eligible = FloeMacSelfRuntime.canInlineTextDocument(uti: attachment.uti, byteCount: attachment.byteCount)
                return .init(id: attachment.id, name: attachment.displayName, isImage: isImage,
                             detail: isImage ? nil : Text(LocalizedStringKey(eligible ? "mac.workspace.textAttachment"
                                                                                  : "mac.workspace.attachmentReferenceOnly")))
            },
            importingItemID: textImportAttachmentID,
            removeDisabled: workspace.isTerminating,
            onRemove: { workspace.unstageAttachment($0) },
            onImportText: { importRecognizedText(from: $0) }
        )
    }

    /// Imports the recognized text of one explicitly selected staged image
    /// into the draft. Runs local Vision OCR (the iPad OCR policy); the
    /// result is appended to the draft as ordinary editable text and the
    /// attachment itself stays staged. A task switch between pick and
    /// completion discards the result instead of leaking it into another
    /// task's draft.
    private func importRecognizedText(from attachmentID: UUID) {
        guard textImportAttachmentID == nil,
              let attachment = workspace.stagedAttachments.first(where: { $0.id == attachmentID }),
              attachment.kind == .image, acceptsAttachmentImport else { return }
        let selection = workspace.draftSelectionID
        textImportAttachmentID = attachmentID
        let task = Task { @MainActor in
            defer { if textImportAttachmentID == attachmentID { textImportAttachmentID = nil } }
            do {
                let text = try await MacComposerImageTextImport.recognizedText(from: attachment.url)
                guard !Task.isCancelled, workspace.draftSelectionID == selection,
                      !workspace.isTerminating else { return }
                let binding = draft
                let current = binding.wrappedValue
                binding.wrappedValue = current.isEmpty ? text : current + "\n\n" + text
            } catch MacComposerImageTextImportError.noTextRecognized {
                guard !Task.isCancelled, workspace.draftSelectionID == selection else { return }
                textImportFoundNoText = true
                showTextImportError = true
            } catch {
                guard !Task.isCancelled, workspace.draftSelectionID == selection else { return }
                textImportFoundNoText = false
                showTextImportError = true
            }
        }
        textImportTask = task
    }

    private func projectControl(openFiles: @escaping () -> Void) -> some View {
        let projects = workspace.workspaces.filter { $0.kind == .project }
        let project = projects.first { $0.id == workspace.selectedWorkspaceID }
        return Menu {
            Button { workspace.selectWorkspace(nil) } label: {
                if project == nil { Label("mac.workspace.conversationFolder", systemImage: "checkmark") }
                else { Text("mac.workspace.conversationFolder") }
            }
            ForEach(projects, id: \.id) { option in
                Button {
                    workspace.selectWorkspace(option.id)
                } label: {
                    if option.id == project?.id {
                        Label(option.name, systemImage: "checkmark")
                    } else {
                        Text(verbatim: option.name)
                    }
                }
            }
            Divider()
            Button("mac.workspace.browseFiles", action: openFiles)
        } label: {
            FloeThreadComposerChip(title: Text(verbatim: project?.name ?? String(localized: "mac.workspace.conversationFolder")),
                                   systemImage: "folder", maximumWidth: 148)
        }
        .menuStyle(.button)
        .buttonStyle(ComposerButtonStyle())
        .menuIndicator(.hidden)
    }

    @ViewBuilder private func modelControl(openSettings: @escaping () -> Void) -> some View {
        let chatModels = workspace.taskModelChoices.filter {
            $0.canSelectAsPrimary
        }
        if chatModels.isEmpty {
            Button(action: openSettings) {
                FloeThreadComposerChip(title: Text("composer.no_model"), systemImage: "cpu", tint: FloeTheme.pending)
            }
            .buttonStyle(ComposerButtonStyle())
            .accessibilityIdentifier("composer.model.configure")
        } else {
            ThreadComposerModelMenu(
                models: chatModels.map(\.model), providers: workspace.taskModelProviderProfiles,
                selectedModelID: workspace.composerProvider?.model.id,
                onSelect: { _ = workspace.selectComposerModel($0.id) }
            ) {
                FloeThreadComposerChip(
                    title: Text(verbatim: composerModelTitle), systemImage: "cpu", maximumWidth: 205
                )
            } extraActions: {
                Divider()
                Button("host.chat.provider", action: openSettings)
            }
            .menuStyle(.button)
            .buttonStyle(ComposerButtonStyle())
            .menuIndicator(.hidden)
            .disabled(workspace.isLoadingHistory)
            .accessibilityIdentifier("composer.model.menu")
            #if FLOE_MAC_HOST_SMOKE
            .background(MacWorkbenchButtonFrameReader { workspace.smokeComposerModelFrame = $0 })
            #endif
        }
    }

    /// Readable "Provider · Model" chip title; the plain provider label only
    /// stands in while nothing is configured.
    private var composerModelTitle: String {
        guard let provider = workspace.composerProvider else {
            if workspace.needsLocalModel { return String(localized: "mac.localModels.selectedUnavailable") }
            return String(localized: "host.chat.provider")
        }
        let account = provider.profile.displayName ?? provider.profile.baseURL.host ?? provider.displayTitle
        return "\(account) · \(provider.model.displayName)"
    }

    private var conversation: some View {
        MacThreadTranscript(workspace: workspace, conversationID: findConversationID,
            searchText: search.query, searchIsActive: search.isActive, focusedMessageID: search.focusedMessageID,
            requestedMessageID: requestedMessageID,
            openAttachment: { message, item in
                guard let id = item.attachmentID else { return }
                Task {
                    await workspace.withSavedAttachment(id: id, conversationID: message.conversationID) {
                        attachmentPreview = MacConversationAttachmentPreview(id: id, url: $0, name: item.name)
                    }
                }
            }, hasDraft: !draft.wrappedValue.isEmpty, reuseMessage: { text in
                guard !workspace.isSending, !workspace.isTerminating, workspace.selectedID == findConversationID else { return }
                let current = draft.wrappedValue
                draft.wrappedValue = current.isEmpty ? text : current + "\n\n" + text
                promptFocusRequest = UUID()
            }, retryPlan: retryPlan, handleSearchResult: didHandleSearchResult)
    }
    #else
    private var conversation: some View {
        ScrollViewReader { scroll in
            ScrollView {
                if workspace.messages.isEmpty && workspace.pendingPrompt == nil {
                    ContentUnavailableView("mac.workspace.newTask", systemImage: "bubble.left.and.bubble.right")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                }
                LazyVStack(alignment: .leading, spacing: 15) {
                    earlierHistoryButton(scroll)
                    ForEach(workspace.messages) { message in
                        row(message.content, user: message.role == "user")
                    }
                    if let prompt = workspace.pendingPrompt {
                        row(prompt, user: true)
                    }
                    if !workspace.streamedText.isEmpty {
                        row(workspace.streamedText, user: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 240, idealHeight: 300)
            .defaultScrollAnchor(.bottom)
        }
    }

    private func row(_ text: String, user: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(user ? "host.chat.user" : "host.chat.assistant")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if user {
                Text(verbatim: text).textSelection(.enabled)
            } else if let formatted = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(formatted).textSelection(.enabled)
            } else {
                Text(verbatim: text).textSelection(.enabled)
            }
        }
    }
    #endif
}

#if FLOE_UNIFIED_MAC
private struct MacGoalConfirmationView: View {
    let goal: ConversationGoal
    let complete: (Set<UUID>, Set<UUID>) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmedSteps = Set<UUID>()
    @State private var confirmedCriteria = Set<UUID>()
    @State private var saving = false

    private var steps: [GoalStep] {
        goal.steps.filter { $0.status != .completed && $0.status != .skipped }
    }

    private var criteria: [GoalCriterion] {
        let evidence = Set(goal.evidence.map(\.id))
        return goal.acceptanceCriteria.filter {
            !$0.isSatisfied || $0.requiresUserConfirmation || $0.evidenceIDs.isEmpty
                || !Set($0.evidenceIDs).isSubset(of: evidence)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("mac.agent.confirmGoal").font(.headline)
            Text(verbatim: goal.objective).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !steps.isEmpty {
                        Text("mac.agent.goalSteps").font(.subheadline.bold())
                        ForEach(steps) { step in
                            Toggle(isOn: checked(step.id, in: $confirmedSteps)) { Text(verbatim: step.title) }
                        }
                    }
                    if !criteria.isEmpty {
                        Text("mac.agent.goalCriteria").font(.subheadline.bold())
                        ForEach(criteria) { criterion in
                            Toggle(isOn: checked(criterion.id, in: $confirmedCriteria)) { Text(verbatim: criterion.text) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            HStack {
                Spacer()
                Button("host.chat.cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button("mac.agent.confirmGoal") {
                    saving = true
                    Task {
                        await complete(confirmedSteps, confirmedCriteria)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || confirmedSteps.count != steps.count || confirmedCriteria.count != criteria.count)
            }
        }
        .padding(20)
        .frame(minWidth: 400, idealWidth: 460)
    }

    private func checked(_ id: UUID, in selection: Binding<Set<UUID>>) -> Binding<Bool> {
        Binding(get: { selection.wrappedValue.contains(id) }, set: { isOn in
            if isOn { selection.wrappedValue.insert(id) }
            else { selection.wrappedValue.remove(id) }
        })
    }
}

private struct HostTaskCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(FloeTheme.fieldSurface, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 800)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
    }
}

extension HostAgentMode {
    var title: LocalizedStringKey {
        switch self {
        case .chat: "composer.mode.chat"
        case .agent: "composer.mode.agent"
        case .plan: "composer.mode.plan"
        case .goal: "composer.mode.goal"
        }
    }

    var prompt: LocalizedStringKey {
        switch self {
        case .chat: "chat.new.prompt"
        case .agent, .plan, .goal: "home.welcome"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "text.bubble"
        case .agent: "wand.and.sparkles"
        case .plan: "list.bullet.clipboard"
        case .goal: "target"
        }
    }
}
#endif

struct HostAgentProviderForm: View {
    @ObservedObject var workspace: HostAgentWorkspace
    @Binding var isPresented: Bool
    @State private var endpoint = ""
    @State private var modelID = ""
    @State private var key = ""
    @State private var protocolKind: ModelProtocol = .openAIChatCompletions

    var body: some View {
        Form {
            TextField("host.chat.endpoint", text: $endpoint)
                .textContentType(.URL)
            Picker("host.chat.protocol", selection: $protocolKind) {
                Text("OpenAI Chat Completions").tag(ModelProtocol.openAIChatCompletions)
                Text("OpenAI Responses").tag(ModelProtocol.openAIResponses)
                Text("Anthropic Messages").tag(ModelProtocol.anthropicMessages)
            }
            TextField("host.chat.modelID", text: $modelID)
            SecureField("host.chat.key", text: $key)
            if let notice = workspace.notice {
                Text(notice).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("host.chat.cancel", role: .cancel) { isPresented = false }
                Button("host.chat.save") {
                    if workspace.saveProvider(endpoint: endpoint, protocolKind: protocolKind, modelID: modelID, key: key) {
                        key = ""
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(endpoint.isEmpty || modelID.isEmpty || workspace.isTerminating)
            }
        }
        .formStyle(.grouped)
        .frame(width: 470)
        .padding()
    }
}

#if FLOE_UNIFIED_MAC
/// Editor sheet for one queued or accepted-guidance message. Saving routes
/// through the workspace so a guidance row is withdrawn before its text
/// changes; the runtime never consumes an edited message.
#endif

#if FLOE_UNIFIED_MAC
enum MacComposerImport {
    enum Input {
        case file(URL), image(NSPasteboardItem, NSPasteboard.PasteboardType), photo(PhotosPickerItem), invalid
    }

    struct ImageBytes: Sendable {
        let data: Data
        let fileExtension: String
    }

    /// Only invoked by a user-initiated paste. A Finder item may also offer
    /// an icon or thumbnail; its file URL always wins.
    @MainActor static func read(_ board: NSPasteboard, limit: Int) -> [Input] {
        var result: [Input] = []
        for item in board.pasteboardItems ?? [] {
            if result.count >= limit { result.append(.invalid); break }
            if let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL {
                result.append(.file(url))
            } else if let type = item.types.first(where: { UTType($0.rawValue)?.conforms(to: .image) == true }) {
                result.append(.image(item, type))
            }
        }
        return result
    }

    @MainActor static func prepare(_ input: Input) async throws -> ImageBytes {
        let bytes: Data
        switch input {
        case .image(let item, let type):
            guard let data = item.data(forType: type), !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            guard data.count <= HostAgentWorkspace.maximumAttachmentBytes else { throw CocoaError(.fileReadTooLarge) }
            bytes = data
        case .photo(let item):
            guard let transfer = try await item.loadTransferable(type: PhotoTransfer.self) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            bytes = transfer.data
        default: throw CocoaError(.fileReadUnsupportedScheme)
        }
        try Task.checkCancellation()
        let inlineLimit = HostAgentWorkspace.maximumInlineImageBytes
        return try await Task.detached(priority: .userInitiated) {
            try normalize(bytes, inlineLimit: inlineLimit)
        }.value
    }

    private struct PhotoTransfer: Transferable {
        let data: Data
        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(importedContentType: .image) { file in
                let limit = await MainActor.run { HostAgentWorkspace.maximumAttachmentBytes }
                let handle = try FileHandle(forReadingFrom: file.file)
                defer { try? handle.close() }
                guard let data = try handle.read(upToCount: limit + 1), !data.isEmpty, data.count <= limit else {
                    throw CocoaError(.fileReadTooLarge)
                }
                return Self(data: data)
            }
        }
    }

    private static func normalize(_ bytes: Data, inlineLimit: Int) throws -> ImageBytes {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(bytes as CFData, options),
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 100_000_000 / h else { throw CocoaError(.fileReadCorruptFile) }
        let native = [UTType.png.identifier: "png", UTType.jpeg.identifier: "jpg",
                      UTType.gif.identifier: "gif", UTType.webP.identifier: "webp"]
        if bytes.count <= inlineLimit, let ext = native[type] {
            return ImageBytes(data: bytes, fileExtension: ext)
        }
        // TIFF screenshots and HEIC photos need a provider-readable raster;
        // downsample in the decoder rather than allocating a full-size bitmap.
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_560
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
        else { throw CocoaError(.fileReadCorruptFile) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length > 0, data.length <= inlineLimit
        else { throw CocoaError(.fileReadTooLarge) }
        return ImageBytes(data: data as Data, fileExtension: "jpg")
    }

    @MainActor static func stage(_ image: ImageBytes, in workspace: HostAgentWorkspace, owner: UUID) -> Bool {
        guard workspace.attachmentOwnerID == owner else { return false }
        let id = UUID()
        do {
            let base = workspace.personalTaskLeaseBase
            let url = try HostAgentDatabase.saveComposerImage(image.data, fileExtension: image.fileExtension,
                                                               id: id, owner: owner, runtimeDirectory: base)
            if workspace.stageAttachments([url], importedImageID: id).first?.id == id { return true }
            HostAgentDatabase.discardComposerImage(url, id: id, owner: owner, runtimeDirectory: base)
        } catch {}
        return false
    }

    #if FLOE_MAC_HOST_SMOKE
    /// Runs with an isolated workspace and a private pasteboard. The user's
    /// pasteboard and Photos library are never touched.
    @MainActor static func verify(in workspace: HostAgentWorkspace, file: URL) async -> Bool {
        guard workspace.stagedAttachments.isEmpty else { return false }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("ordinary text", forType: .string)
        guard read(board, limit: 8).isEmpty else { return false }
        board.clearContents()
        guard board.writeObjects([file as NSURL]), case .file(let url) = read(board, limit: 8).first,
              let external = workspace.stageAttachments([url]).first else { return false }
        workspace.unstageAttachment(external.id)
        guard FileManager.default.fileExists(atPath: file.path),
              let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC") else { return false }
        board.clearContents()
        board.setData(png, forType: .png)
        guard let input = read(board, limit: 8).first, let image = try? await prepare(input),
              stage(image, in: workspace, owner: workspace.attachmentOwnerID),
              let original = workspace.stagedAttachments.first, original.kind == .image,
              original.sha256 == FloeDigest.sha256Hex(png) else { return false }
        // A draft reconstructed from a sent attachment has a new draft ID.
        HostAgentDatabase.discardComposerImage(original.url, id: UUID(), owner: workspace.attachmentOwnerID,
                                              runtimeDirectory: workspace.personalTaskLeaseBase)
        guard FileManager.default.fileExists(atPath: original.url.path) else { return false }
        workspace.unstageAttachment(original.id)
        return !FileManager.default.fileExists(atPath: original.url.path) && workspace.stagedAttachments.isEmpty
    }
    #endif
}
#endif
