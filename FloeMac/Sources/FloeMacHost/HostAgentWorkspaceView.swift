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
    static var smokeLocatedMessageID: UUID?
    #endif
    @StateObject private var search: ThreadSearchModel
    @FocusState private var promptFocused: Bool
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
    #if FLOE_UNIFIED_MAC
    @State private var confirmsTaskFullAccess = false
    @State private var approvalSelection: UUID?
    #endif
    @State private var criterion = ""
    @State private var goalToEdit: ConversationGoal?
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
         openImageWorkbench: (() -> Void)? = nil, findRequest: UUID? = nil,
         findConversationID: UUID? = nil, requestedMessageID: UUID? = nil,
         didHandleSearchResult: ((UUID, UUID) -> Void)? = nil) {
        self.workspace = workspace
        self.workspaceDraft = workspaceDraft
        self.captureDraftCommit = captureDraftCommit
        self.openModelSettings = openModelSettings
        self.openPermissionSettings = openPermissionSettings
        self.openFiles = openFiles
        self.openImageWorkbench = openImageWorkbench
        self.didHandleSearchResult = didHandleSearchResult
        self.requestedMessageID = requestedMessageID
        self.findRequest = findRequest
        self.findConversationID = findConversationID
        #if FLOE_UNIFIED_MAC
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

    private func submitDraft(workspaceID: UUID? = nil, mode: HostAgentMode = .chat, criterion: String = "") {
        let binding = draft
        let submitted = binding.wrappedValue
        workspace.send(submitted, workspaceID: workspaceID, mode: mode, criterion: criterion,
            onAdmitted: draftCommit(for: binding, submitted: submitted))
    }

    private func draftCommit(for binding: Binding<String>, submitted: String) -> () -> Void {
        captureDraftCommit?() ?? { if binding.wrappedValue == submitted { binding.wrappedValue = "" } }
    }

    #if FLOE_UNIFIED_MAC
    /// Status caption for a non-queued queue row. Queued rows stay quiet;
    /// a guidance row waiting for a safe insertion point, or mid-promotion,
    /// tells the user what is happening in aligned bilingual copy.
    private func queueStatusText(_ status: PendingUserInputStatus) -> String {
        switch status {
        case .queued: ""
        case .promoting: String(localized: "mac.agent.guidanceConverting")
        case .steerPending: String(localized: "mac.agent.guidanceWaiting")
        case .consumed: String(localized: "mac.agent.guidanceSent")
        case .cancelled: String(localized: "mac.agent.guidanceCancelled")
        }
    }
    #endif

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
                if let goal = workspace.goal { goalCard(goal) }
                if let id = workspace.selectedID {
                    MacChildTasksView(controller: workspace.childSubagents, conversationID: id)
                }
                if let id = workspace.selectedID, let inputs = workspace.queuedInputs[id], !inputs.isEmpty {
                    DisclosureGroup {
                        let queued = inputs.filter { $0.status == .queued }
                        ForEach(inputs) { input in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: input.content).lineLimit(2).textSelection(.enabled)
                                    if input.status != .queued {
                                        Text(queueStatusText(input.status))
                                            .font(.caption)
                                            .foregroundStyle(FloeTheme.pending)
                                    }
                                }
                                Spacer(minLength: 4)
                                if let text = CredentialMessagePart.clipboardText(input.content) {
                                    ChatMessageCopyButton(text: text)
                                }
                                if input.status == .queued || input.status == .steerPending {
                                    let queuedIndex = queued.firstIndex(where: { $0.id == input.id })
                                    Menu {
                                        Button("mac.agent.editQueued", systemImage: "pencil") {
                                            editingQueuedInput = input
                                        }
                                        Button("mac.agent.moveQueuedUp", systemImage: "arrow.up") {
                                            Task { await workspace.moveQueued(input, offset: -1) }
                                        }
                                        .disabled(queuedIndex == nil || queuedIndex == queued.startIndex)
                                        Button("mac.agent.moveQueuedDown", systemImage: "arrow.down") {
                                            Task { await workspace.moveQueued(input, offset: 1) }
                                        }
                                        .disabled(queuedIndex == nil || queuedIndex == queued.indices.last)
                                        // Both directions come from one policy:
                                        // a queued row can convert into guidance
                                        // for the active run, an accepted
                                        // guidance row can return to the queue —
                                        // but only while it has NOT been
                                        // consumed. Consumed rows offer no mode
                                        // action at all.
                                        let modeActions = RunningInputModePolicy.modeActions(
                                            status: input.status, canSteer: workspace.canSteer)
                                        if modeActions.contains(.promoteToSteer) {
                                            Button("mac.agent.convertToGuidance",
                                                   systemImage: "arrow.triangle.turn.up.right.diamond") {
                                                Task { await workspace.promoteQueuedToGuidance(input) }
                                            }
                                            .disabled(!workspace.canSteer)
                                        }
                                        if modeActions.contains(.demoteToQueue) {
                                            Button("mac.agent.backToQueue", systemImage: "arrow.uturn.left") {
                                                Task { await workspace.demoteQueuedGuidance(input) }
                                            }
                                        }
                                        Divider()
                                        Button("mac.agent.removeQueued", systemImage: "trash", role: .destructive) {
                                            Task { await workspace.cancelQueued(input) }
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                                    }
                                    .accessibilityLabel("mac.agent.queueMessageActions")
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                        if !workspace.isSending {
                            Button("mac.agent.sendNextQueued") { Task { await workspace.startNextQueued(id) } }
                        }
                    } label: { Label { Text("mac.agent.queueCount \(inputs.count)") } icon: { Image(systemName: "text.badge.plus") } }
                    .font(.callout).padding(.horizontal, 18)
                }
                if let steer = workspace.lastSteer {
                    Label {
                        Text(verbatim: String(localized: "mac.agent.steerSent") + " · " + steer)
                            .lineLimit(1).help(steer)
                    } icon: { Image(systemName: "arrow.turn.up.right") }
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18)
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
                    Button {
                        Task { await workspace.continueFromHistory(run) }
                    } label: {
                        Label(LocalizedStringKey(workspace.resumesOriginalRun ? "mac.agent.continueTask" : "mac.agent.continueHistory"),
                              systemImage: "play")
                            .padding(.horizontal, 6)
                            .frame(minHeight: FloeTheme.minimumTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("mac.agent.run.continue")
                    #if FLOE_MAC_HOST_SMOKE
                    .background(MacWorkbenchButtonFrameReader { frame in Self.smokeHistoryContinueFrame = frame })
                    #endif
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
                                promptFocused = true
                                return true
                            }
                        }
                    }
                    .disabled(!draft.wrappedValue.isEmpty || !workspace.stagedAttachments.isEmpty)
                    .padding(.horizontal, 16)
                }
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
            search.end()
            attachmentImport?.cancel()
            attachmentImport = nil
            attachmentImportID = nil
            textImportTask?.cancel()
            textImportTask = nil
            textImportAttachmentID = nil
        }
        .sheet(isPresented: $editingPrompt, onDismiss: { promptFocused = true }) {
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
        .sheet(item: $goalToEdit) { goal in
            GoalBuilderSheet(goal: goal, errorMessage: workspace.notice) { objective, criteria, blockers, stops in
                await workspace.editGoal(goal, objective: objective, criteria: criteria, blockers: blockers, stops: stops)
            }
            .frame(minWidth: 420, idealWidth: 520, minHeight: 420, idealHeight: 580)
        }
        .sheet(item: $goalForConfirmation) { goal in
            MacGoalConfirmationView(goal: goal) { steps, criteria in
                await workspace.confirmGoal(goal, completedSteps: steps, confirmedCriteria: criteria)
            }
        }
        .sheet(item: $editingQueuedInput) { input in
            MacQueuedInputEditor(input: input) { text in
                let target = input
                Task { await workspace.editQueued(target, content: text) }
            }
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
        RunningInputModePolicy.sendRoute(isRunActive: workspace.isSending, mode: workspace.runningInputMode)
    }

    private var composerSubmitLabel: LocalizedStringKey {
        LocalizedStringKey(composerSendRoute.composerTitleKey)
    }

    private var canSubmitComposer: Bool {
        guard attachmentImport == nil, !workspace.isTerminating, workspace.selectedID == findConversationID,
              !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if workspace.isSending { return workspace.canSteer }
        let compatible = mode == .chat || workspace.composerProvider?.model.capabilities.contains(.tools) == true
        return workspace.composerProvider != nil && compatible && !workspace.isAcceptingPlan
    }

    private func submitComposer() {
        guard canSubmitComposer else { return }
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
            if workspace.runningInputMode == .steer { workspace.steer(text, attachments: attachments, onAccepted: clear) }
            else { workspace.enqueue(text, attachments: attachments, onAccepted: clear) }
        } else {
            let project = workspace.selectedID == nil ? workspace.selectedWorkspaceID : nil
            let isNewGoal = mode == .goal && workspace.goal?.status.isTerminal != false
            submitDraft(workspaceID: project, mode: mode, criterion: isNewGoal ? criterion : "")
        }
    }

    private var composer: some View {
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
            if mode == .goal, workspace.goal?.status.isTerminal != false {
                TextField("mac.agent.goalCriterionHint", text: $criterion, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mac.agent.goalCriterion")
                    .disabled(workspace.isSending || workspace.isTerminating)
            }
            ComposerResponsiveRow(spacing: 4, stackedSpacing: 2) {
                composerAttachments
                    .composerResponsiveLeadingControl()
                TextField(LocalizedStringKey(workspace.isSending ? (workspace.runningInputMode == .steer ? "mac.agent.steerPrompt" : "mac.agent.queuePrompt") : "host.chat.prompt"), text: draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(FloeTheme.Typography.body)
                    .focused($promptFocused)
                    .onChange(of: workspace.draftSelectionID, initial: true) {
                        if workspace.selectedID == nil { promptFocused = true }
                    }
                    .lineLimit(1...7)
                    .frame(minHeight: FloeTheme.minimumTarget)
                    .onPasteCommand(of: acceptsAttachmentImport ? [.fileURL, .image] : []) { _ in
                        pasteAttachments()
                    }
                    .accessibilityIdentifier("thread.composer.input")
                    #if FLOE_MAC_HOST_SMOKE
                    .background(MacWorkbenchButtonFrameReader { workspace.smokePromptFrame = $0 })
                    #endif
                    .disabled(workspace.isTerminating || (workspace.isSending && workspace.selectedID == nil))
                    .composerResponsiveFieldSlot()
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
                    Button(action: submitComposer) {
                        Label(composerSubmitLabel, systemImage: composerSendRoute.composerSymbol)
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(ComposerButtonStyle())
                    .help(Text(composerSubmitLabel))
                    .disabled(!canSubmitComposer)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("composer.running.send")
                    #if FLOE_MAC_HOST_SMOKE
                    .background(MacWorkbenchButtonFrameReader { workspace.smokeSteerFrame = $0 })
                    #endif
                    Button(action: workspace.stop) {
                        FloeComposerActionGlyph(systemImage: "stop.fill", enabled: workspace.canStop, destructive: true)
                    }
                    .buttonStyle(ComposerButtonStyle())
                    .accessibilityLabel("host.chat.stop")
                    .disabled(!workspace.canStop)
                } else {
                    Button(action: submitComposer) {
                        FloeComposerActionGlyph(systemImage: composerSendRoute.composerSymbol, enabled: canSubmitComposer)
                    }
                    .buttonStyle(ComposerButtonStyle())
                    .accessibilityLabel(Text(composerSubmitLabel))
                    .accessibilityIdentifier("composer.send")
                    .help(workspace.composerProvider == nil ? Text("host.chat.configureFirst") : Text("mac.workspace.sendShortcut"))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSubmitComposer)
                }
            }
            if let openModelSettings {
                ComposerContextLayout {
                    modelControl(openSettings: openModelSettings).disabled(workspace.isSending)
                    if let provider = workspace.composerProvider { reasoningMenu(provider.model) }
                    composerWorkspace
                    modeControl.disabled(workspace.isSending)
                    if workspace.isSending { runningInputControl }
                    permissionControl.disabled(workspace.isStopping || workspace.isResolvingApproval || (workspace.isSending && workspace.runPhase == nil))
                }
                .disabled(workspace.isTerminating || workspace.isAcceptingPlan)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .modifier(FloeThreadComposerChrome())
        .dropDestination(for: URL.self) { urls, _ in
            guard acceptsAttachmentImport else { return false }
            let staged = workspace.stageAttachments(urls.filter(\.isFileURL))
            showAttachmentError = staged.count < urls.count
            return !staged.isEmpty
        }
        .frame(maxWidth: 824)
        .padding(.horizontal, 6)
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity)
    }

    private var runningInputControl: some View {
        FloeComposerRunningInputMenu(queue: Binding(get: { workspace.runningInputMode == .queue },
                                                   set: { workspace.runningInputMode = $0 ? .queue : .steer }))
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

    private func goalCard(_ goal: ConversationGoal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("mac.agent.goalStatus", systemImage: "scope").font(.callout.weight(.semibold))
                Text(LocalizedStringKey("mac.agent.goal.\(goal.status.rawValue)"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if workspace.canConfirmGoal(goal) {
                    Button("mac.agent.confirmGoal", systemImage: "checkmark") { goalForConfirmation = goal }
                        .accessibilityIdentifier("mac.agent.goal.confirm")
                }
                if workspace.canContinueGoal(goal) {
                    Button("mac.agent.continueGoal", systemImage: "play") { workspace.continueGoal(goal) }
                        .accessibilityIdentifier("mac.agent.goal.continue")
                } else if workspace.canPauseGoal(goal) {
                    Button("mac.agent.pauseGoal", systemImage: "pause") { Task { await workspace.pauseGoal(goal) } }
                        .accessibilityIdentifier("mac.agent.goal.pause")
                }
            }
            Text(verbatim: goal.objective).lineLimit(2).help(goal.objective)
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

    private var editableGoal: ConversationGoal? {
        guard let goal = workspace.goal, !goal.status.isTerminal else { return nil }
        return goal
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
                             editGoal: editableGoal.map { goal in { goalToEdit = goal } }, goal: .goal)
        .menuStyle(.button)
        .buttonStyle(ComposerButtonStyle())
        .menuIndicator(.hidden)
        .accessibilityIdentifier("mac.composer.mode")
        #if FLOE_MAC_HOST_SMOKE
        .background(MacWorkbenchButtonFrameReader { workspace.smokeModeFrame = $0 })
        #endif
    }

    /// Permission chip for the current task or the next-task draft, aligned
    /// with the iPad composer chip: choosing a mode updates the task through
    /// the workspace, which authenticates this Mac's user before enabling
    /// full access. Genuine save failures surface through the workspace
    /// notice; a dismissed authentication stays silent.
    private var permissionControl: some View {
        Menu {
            ForEach(TaskApprovalMode.allCases, id: \.self) { choice in
                Button {
                    if choice == .fullAccess && choice != workspace.taskApprovalMode {
                        approvalSelection = workspace.draftSelectionID
                        confirmsTaskFullAccess = true
                    } else { Task { await workspace.setApprovalMode(choice, asDefault: false) } }
                } label: {
                    if workspace.taskApprovalMode == choice {
                        Label(choice.macPermissionsTitle, systemImage: "checkmark")
                    } else {
                        Text(choice.macPermissionsTitle)
                    }
                }
            }
        } label: {
            FloeThreadComposerChip(title: Text(workspace.taskApprovalMode.macPermissionsTitle),
                                   systemImage: "lock.shield")
        }
        .confirmMacFullAccess(isPresented: $confirmsTaskFullAccess, asDefault: false) {
            guard approvalSelection == workspace.draftSelectionID else { return }
            Task { await workspace.setApprovalMode(.fullAccess, asDefault: false) }
        }
        .menuStyle(.button)
        .buttonStyle(ComposerButtonStyle())
        .menuIndicator(.hidden)
        .disabled(workspace.savingApprovalMode)
        .accessibilityIdentifier("composer.approvalMode")
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
        let chatModels = workspace.providers.filter {
            $0.canSelectAsPrimary
        }
        if chatModels.isEmpty {
            Button(action: openSettings) {
                FloeThreadComposerChip(title: Text("mac.workspace.configureModel"), systemImage: "cpu")
            }
            .buttonStyle(ComposerButtonStyle())
        } else {
            ThreadComposerModelMenu(
                models: chatModels.map(\.model), providers: workspace.accounts.map(\.profile),
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
            return String(localized: "host.chat.provider")
        }
        let account = provider.profile.displayName ?? provider.profile.baseURL.host ?? provider.displayTitle
        return "\(account) · \(provider.model.displayName)"
    }

    private var conversation: some View {
        MacThreadTranscript(workspace: workspace, conversationID: findConversationID,
            searchText: search.query, searchIsActive: search.isActive, focusedMessageID: search.focusedMessageID,
            requestedMessageID: requestedMessageID, openModelSettings: openModelSettings,
            openAttachment: { message, item in
                guard let id = item.attachmentID else { return }
                Task {
                    await workspace.withSavedAttachment(id: id, conversationID: message.conversationID) {
                        attachmentPreview = MacConversationAttachmentPreview(id: id, url: $0)
                    }
                }
            }, hasDraft: !draft.wrappedValue.isEmpty, reuseMessage: { text in
                guard !workspace.isSending, !workspace.isTerminating, workspace.selectedID == findConversationID else { return }
                let current = draft.wrappedValue
                draft.wrappedValue = current.isEmpty ? text : current + "\n\n" + text
                promptFocused = true
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
        case .chat: "mac.agent.mode.chat"
        case .agent: "mac.agent.mode.agent"
        case .plan: "mac.agent.mode.plan"
        case .goal: "mac.agent.mode.goal"
        }
    }

    var prompt: LocalizedStringKey {
        switch self {
        case .chat: "mac.chat.welcome"
        case .plan: "mac.plan.welcome"
        case .goal: "mac.goal.welcome"
        case .agent: "home.welcome"
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
private struct MacQueuedInputEditor: View {
    let input: PendingUserInput
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(input: PendingUserInput, onSave: @escaping (String) -> Void) {
        self.input = input
        self.onSave = onSave
        _text = State(initialValue: input.content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("mac.agent.editQueuedMessage")
                .font(.headline)
            TextField("mac.agent.queueMessage", text: $text, axis: .vertical)
                .lineLimit(3...10)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("host.chat.cancel", role: .cancel) { dismiss() }
                Button("host.chat.save") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 420)
    }
}
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
