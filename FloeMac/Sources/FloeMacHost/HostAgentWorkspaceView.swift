// SPDX-License-Identifier: MPL-2.0

import FloeCore
import FloeAgentRuntime
import FloeMacSelfCore
import FloePersistence
import SwiftUI
#if FLOE_UNIFIED_MAC
import AppKit
import UniformTypeIdentifiers
#endif

struct HostAgentWorkspaceView: View {
    @ObservedObject var workspace: HostAgentWorkspace
    var workspaceDraft: Binding<String>? = nil
    var openModelSettings: (() -> Void)? = nil
    var openFiles: (() -> Void)? = nil
    var chooseTaskProject: (() -> Void)? = nil
    var openImageWorkbench: (() -> Void)? = nil
    var findRequest: UUID? = nil
    var findConversationID: UUID? = nil
    @State private var standaloneDraft = ""
    #if FLOE_UNIFIED_MAC
    @StateObject private var search: MacConversationSearchModel
    @State private var awayFromLatest = false
    @FocusState private var promptFocused: Bool
    @State private var attachmentSelection: UUID?
    @State private var choosingAttachments = false
    @State private var showAttachmentError = false
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
         openModelSettings: (() -> Void)? = nil, openFiles: (() -> Void)? = nil,
         chooseTaskProject: (() -> Void)? = nil, openImageWorkbench: (() -> Void)? = nil, findRequest: UUID? = nil,
         findConversationID: UUID? = nil) {
        self.workspace = workspace
        self.workspaceDraft = workspaceDraft
        self.openModelSettings = openModelSettings
        self.openFiles = openFiles
        self.chooseTaskProject = chooseTaskProject
        self.openImageWorkbench = openImageWorkbench
        self.findRequest = findRequest
        self.findConversationID = findConversationID
        #if FLOE_UNIFIED_MAC
        _search = StateObject(wrappedValue: MacConversationSearchModel(
            loadedWindow: { [weak workspace] in
                guard let workspace, workspace.selectedID == findConversationID else { return ([], nil, false) }
                return workspace.loadedMessageWindow
            },
            historyPage: { [weak workspace] cursor in
                guard let workspace, let id = findConversationID else { throw CancellationError() }
                return try await workspace.searchMessagePage(conversationID: id, before: cursor)
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
        workspace.send(submitted, workspaceID: workspaceID, mode: mode, criterion: criterion) {
            if binding.wrappedValue == submitted { binding.wrappedValue = "" }
        }
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
                    MacConversationSearchBar(model: search)
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
                ErrorEventView(message: notice)
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
        .onChange(of: findRequest, initial: true) { _, request in
            guard request != nil, let id = findConversationID, id == workspace.selectedID else { return }
            search.bind(conversationID: id)
            search.begin()
        }
        .onDisappear { search.end() }
        .onChange(of: workspace.rejectedPrompt) { _, text in
            if let text, draft.wrappedValue.isEmpty { draft.wrappedValue = text }
        }
        .fileImporter(isPresented: $choosingAttachments, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            defer { attachmentSelection = nil }
            guard attachmentSelection == workspace.draftSelectionID, !workspace.isSending,
                  !workspace.isTerminating else { return }
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
    private var needsProject: Bool {
        guard mode == .plan || mode == .agent else { return false }
        if workspace.selectedID == nil { return workspace.selectedWorkspaceID == nil }
        return workspace.selectedConversationWorkspace?.kind != .project
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !workspace.isSending {
                if needsProject, let chooseTaskProject {
                    Button("mac.workspace.chooseProject", systemImage: "folder.badge.plus", action: chooseTaskProject)
                        .help("mac.agent.projectRequired")
                        .controlSize(.small)
                } else if mode != .chat, let provider = workspace.composerProvider,
                          !provider.model.capabilities.contains(.tools) {
                    Text("mac.agent.toolsModelRequired").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !workspace.stagedAttachments.isEmpty {
                attachmentStrip
            }
            if mode == .goal, workspace.goal?.status.isTerminal != false {
                TextField("mac.agent.goalCriterionHint", text: $criterion, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mac.agent.goalCriterion")
                    .disabled(workspace.isSending || workspace.isTerminating)
            }
            ComposerResponsiveRow {
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
                    .accessibilityIdentifier("thread.composer.input")
                    #if FLOE_MAC_HOST_SMOKE
                    .background(MacWorkbenchButtonFrameReader { workspace.smokePromptFrame = $0 })
                    #endif
                    .disabled(workspace.isTerminating || (workspace.isSending && workspace.selectedID == nil))
                    .composerResponsiveFieldSlot()
                if workspace.isSending {
                    Button {
                        let binding = draft
                        let text = binding.wrappedValue
                        let clear = { if binding.wrappedValue == text { binding.wrappedValue = "" } }
                        if workspace.runningInputMode == .steer { workspace.steer(text, onAccepted: clear) }
                        else { workspace.enqueue(text, onAccepted: clear) }
                    } label: {
                        let steering = workspace.runningInputMode == .steer
                        Label(LocalizedStringKey(steering ? "chat.thread_composer_view.steer_the_current_run" : "chat.thread_composer_view.add_to_message_queue"),
                              systemImage: steering ? "arrow.turn.up.right" : "text.badge.plus")
                            .labelStyle(.iconOnly)
                    }
                    .controlSize(.small)
                    .disabled(!workspace.canSteer || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("composer.running.send")
                    #if FLOE_MAC_HOST_SMOKE
                    .background(MacWorkbenchButtonFrameReader { workspace.smokeSteerFrame = $0 })
                    #endif
                    Button(action: workspace.stop) {
                        FloeComposerActionGlyph(systemImage: "stop.fill", enabled: workspace.canStop, destructive: true)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                    .accessibilityLabel("host.chat.stop")
                    .disabled(!workspace.canStop)
                } else {
                    let isNewGoal = mode == .goal && workspace.goal?.status.isTerminal != false
                    let compatible = mode == .chat || workspace.composerProvider?.model.capabilities.contains(.tools) == true
                    let canSend = workspace.composerProvider != nil && compatible && !needsProject && !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !workspace.isTerminating && !workspace.isAcceptingPlan
                    Button {
                        let project = workspace.selectedID == nil ? workspace.selectedWorkspaceID : nil
                        submitDraft(workspaceID: project, mode: mode, criterion: isNewGoal ? criterion : "")
                    } label: {
                        FloeComposerActionGlyph(systemImage: "arrow.up", enabled: canSend)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                    .accessibilityLabel("host.chat.send")
                    .accessibilityIdentifier("composer.send")
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
                }
            }
            if let openModelSettings {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        composerContext(openModelSettings).disabled(workspace.isSending)
                        modeControl.disabled(workspace.isSending)
                        permissionControl.disabled(workspace.isSending)
                        if let provider = workspace.composerProvider { reasoningMenu(provider.model) }
                        if workspace.isSending { runningInputControl }
                    }
                }
                .padding(.leading, 4)
                .disabled(workspace.isTerminating || workspace.isAcceptingPlan)
            }
        }
        .padding(8)
        .modifier(FloeThreadComposerChrome())
        .dropDestination(for: URL.self) { urls, _ in
            guard workspace.selectedID == findConversationID, !workspace.isSending,
                  !workspace.isTerminating, !workspace.isLoadingHistory else { return false }
            return !workspace.stageAttachments(urls.filter(\.isFileURL)).isEmpty
        }
        .frame(maxWidth: 824)
        .padding(.horizontal, 6)
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity)
    }

    private var runningInputControl: some View {
        FloeComposerRunningInputMenu(queue: Binding(get: { workspace.runningInputMode == .queue },
                                                   set: { workspace.runningInputMode = $0 ? .queue : .steer }))
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("composer.runningInputMode")
        #if FLOE_MAC_HOST_SMOKE
        .background(MacWorkbenchButtonFrameReader { workspace.smokeRunningModeFrame = $0 })
        #endif
    }

    private func composerContext(_ openModelSettings: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            modelControl(openSettings: openModelSettings).fixedSize()
            if mode != .chat, let openFiles {
                if let owner = workspace.selectedConversationWorkspace, owner.kind == .project {
                    Button(action: openFiles) {
                        FloeThreadComposerChip(title: Text(verbatim: owner.name), systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                    .help("mac.workspace.browseFiles")
                } else if workspace.selectedID == nil {
                    projectControl(openFiles: openFiles)
                }
            }
        }
    }

    private var composerAttachments: some View {
        Menu {
            Button("mac.workspace.attachFiles", systemImage: "paperclip") {
                attachmentSelection = workspace.draftSelectionID
                choosingAttachments = true
            }
            if let openImageWorkbench {
                Button("mac.settings.images", systemImage: "photo.badge.plus", action: openImageWorkbench)
            }
        } label: {
            FloeWorkbenchControlIcon(systemImage: "paperclip")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("mac.workspace.attachFiles")
        .accessibilityLabel("mac.workspace.attachFiles")
        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
        .disabled(workspace.isSending || workspace.isTerminating)
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
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
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
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(workspace.savingApprovalMode)
        .accessibilityIdentifier("composer.approvalMode")
        .accessibilityLabel(MacPermissionsText.t("审批模式", "Approval mode"))
        .help(MacPermissionsText.t("选择此任务的审批模式", "Choose the approval mode for this task"))
    }

    private func toolActivityCard(_ activity: [HostAgentToolActivity]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(activity) { step in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(step.toolName).font(.callout.monospaced())
                            Spacer()
                            Text(toolStateTitle(step.state)).font(.caption).foregroundStyle(.secondary)
                        }
                        if let path = step.outputPath, step.outputWorkspaceID == workspace.selectedConversationWorkspace?.id {
                            Button {
                                workspace.withOutputFile(step) { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
                            } label: { Label(path, systemImage: "doc") }
                            .help("mac.run.revealFile")
                        }
                        if let summary = step.summary, !summary.isEmpty {
                            Text(summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                .lineLimit(6)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("mac.run.activity", systemImage: "square.stack")
                .font(.callout.weight(.semibold))
        }
        .padding(12)
        .background(FloeTheme.stepSurface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("mac.run.activity")
    }

    private func toolStateTitle(_ state: String) -> LocalizedStringKey {
        switch state {
        case "pending": "mac.run.tool.waiting"
        case "running": "mac.run.tool.running"
        case "settling": "mac.run.tool.settling"
        case "ok": "mac.run.tool.done"
        case "denied": "mac.run.tool.denied"
        case "cancelled": "mac.run.tool.cancelled"
        default: "mac.run.tool.failed"
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(workspace.stagedAttachments, id: \.id) { attachment in
                    let isImage = attachment.kind == .image
                    let eligible = FloeMacSelfRuntime.canInlineTextDocument(uti: attachment.uti, byteCount: attachment.byteCount)
                    let detail = Text(LocalizedStringKey(eligible ? "mac.workspace.textAttachment" : "mac.workspace.attachmentReferenceOnly"))
                    FloeComposerAttachmentChip(name: attachment.displayName, systemImage: isImage ? "photo" : "doc",
                                               detail: isImage ? nil : detail,
                                               removeLabel: String(localized: "mac.workspace.removeAttachment")) {
                        workspace.unstageAttachment(attachment.id)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .disabled(workspace.isSending || workspace.isTerminating)
    }

    private func projectControl(openFiles: @escaping () -> Void) -> some View {
        let projects = workspace.workspaces.filter { $0.kind == .project }
        let project = projects.first { $0.id == workspace.selectedWorkspaceID }
        return Menu {
            Button("mac.workspace.noProject") { workspace.selectWorkspace(nil) }
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
            FloeThreadComposerChip(title: Text(verbatim: project?.name ?? String(localized: "mac.workspace.noProject")),
                                   systemImage: "folder")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder private func modelControl(openSettings: @escaping () -> Void) -> some View {
        if workspace.providers.isEmpty {
            Button(action: openSettings) {
                FloeThreadComposerChip(title: Text("host.chat.provider"), systemImage: "cpu")
            }
            .buttonStyle(.plain)
        } else {
            Menu {
                let groups = Dictionary(grouping: workspace.providers) {
                    $0.profile.displayName ?? $0.profile.baseURL.host ?? $0.displayTitle
                }
                ForEach(groups.keys.sorted(), id: \.self) { name in
                    Section {
                        ForEach(groups[name] ?? [], id: \.profile.id) { provider in
                            Button {
                                workspace.selectComposerProvider(provider.profile.id)
                            } label: {
                                if provider.profile.id == workspace.composerProvider?.profile.id {
                                    Label(provider.model.displayName, systemImage: "checkmark")
                                } else {
                                    Text(verbatim: provider.model.displayName)
                                }
                            }
                        }
                    } header: { Text(verbatim: name) }
                }
                Divider()
                Button("host.chat.provider", action: openSettings)
            } label: {
                FloeThreadComposerChip(
                    title: Text(verbatim: workspace.composerProvider?.model.displayName ?? String(localized: "host.chat.provider")),
                    systemImage: "cpu"
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var conversation: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroll in
                ScrollView {
                    if workspace.messages.isEmpty && workspace.pendingPrompt == nil {
                        VStack(spacing: 12) {
                            FloeWorkbenchWelcomeHeader(icon: Image(nsImage: NSImage(named: "FloeBrand") ?? NSApp.applicationIconImage)) {
                                Text(mode.prompt)
                            }
                            if workspace.composerProvider == nil, let openModelSettings {
                                Button("host.chat.provider", action: openModelSettings)
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            earlierHistoryButton(scroll)
                            ForEach(workspace.messages) { message in
                                VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                                    if let confirmation = PlanConfirmationSnapshot.from(message: message) {
                                        ConfirmedPlanMessageCard(snapshot: confirmation, onRetryStart: retryPlan(confirmation))
                                    } else if message.role == "user" {
                                        UserMessageBubble(text: message.content,
                                                          attachments: AttachmentChipItem.items(in: message.parts),
                                                          onOpenAttachment: { item in
                                            guard let id = item.attachmentID else { return }
                                            Task {
                                                await workspace.withSavedAttachment(id: id, conversationID: message.conversationID) {
                                                    NSWorkspace.shared.activateFileViewerSelecting([$0])
                                                }
                                            }
                                        })
                                    } else if message.role == "assistant" {
                                        ForEach(message.parts.filter { $0.kind == .reasoning }) { part in
                                            if let text = part.text, !text.isEmpty { ReasoningBlockView(text: text) }
                                        }
                                        MarkdownRendererView(source: message.content)
                                    } else {
                                        Text(verbatim: message.content).foregroundStyle(.secondary)
                                    }
                                    ChatMessageFooter(sentAt: message.createdAt, messageID: message.id.uuidString,
                                                      userText: message.role == "user" ? message.content : nil)
                                }
                                .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
                                .background(search.isActive && search.focusedMessageID == message.id
                                            ? Color.accentColor.opacity(0.12) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .contextMenu {
                                    if let text = CredentialMessagePart.clipboardText(message.content) {
                                        Button("action.copy") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(text, forType: .string)
                                        }
                                    }
                                }
                                .task(id: message.runID) {
                                    if message.role == "user", let runID = message.runID {
                                        await workspace.loadVisibleToolActivity(runID: runID, conversationID: message.conversationID)
                                    }
                                }
                                if message.role == "user", let runID = message.runID,
                                   let questions = workspace.settledQuestions[runID] {
                                    MacQuestionHistoryView(requests: questions)
                                }
                                if message.role == "user", let runID = message.runID,
                                   let steps = workspace.runToolActivity[runID], !steps.isEmpty {
                                    toolActivityCard(steps)
                                }
                            }
                            if let prompt = workspace.pendingPrompt {
                                UserMessageBubble(text: prompt)
                                let steps = workspace.liveToolActivity
                                if !steps.isEmpty { toolActivityCard(steps) }
                            }
                            if let question = workspace.pendingQuestion {
                                HostAgentQuestionCardView(question: question, submit: { target, answer in
                                    await workspace.answerQuestion(target: target, answer: answer)
                                }, cancel: { requestID in
                                    await workspace.declineQuestion(requestID: requestID)
                                }, draftChanged: { target, draft in
                                    Task { await workspace.saveQuestionDraft(target: target, answer: draft) }
                                })
                                .id(question.cardIdentity)
                            }
                            if let approval = workspace.pendingApproval {
                                MacWorkspaceApprovalView(workspace: workspace, approval: approval)
                                    .id(approval.callID)
                            }
                            if let attempt = workspace.reconnectAttempt {
                                Label { Text("mac.agent.reconnecting \(attempt)") } icon: { Image(systemName: "arrow.clockwise") }
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !workspace.liveReasoning.isEmpty {
                                ReasoningBlockView(text: workspace.liveReasoning, isStreaming: workspace.streamedText.isEmpty)
                            } else if workspace.awaitingModel && workspace.reconnectAttempt == nil && workspace.streamedText.isEmpty {
                                ModelResponseWaitingView()
                            }
                            if !workspace.streamedText.isEmpty {
                                MarkdownRendererView(source: workspace.streamedText, isStreaming: true)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            Color.clear.frame(height: 1).id("mac.thread.latest").allowsHitTesting(false)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .frame(maxWidth: 824)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity)
                    }
                }
                .defaultScrollAnchor(.bottom)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.visibleRect.maxY > 140
                } action: { _, away in awayFromLatest = away }
                .overlay(alignment: .bottomTrailing) {
                    if awayFromLatest {
                        Button { scroll.scrollTo("mac.thread.latest", anchor: .bottom) } label: {
                            Label("mac.thread.latest", systemImage: "arrow.down")
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .padding(8)
                    }
                }
                .onChange(of: workspace.pendingApproval?.callID) { _, callID in
                    if let callID { scroll.scrollTo(callID, anchor: .bottom) }
                }
                .onChange(of: workspace.lastSteer) { _, _ in
                    if let callID = workspace.pendingApproval?.callID { scroll.scrollTo(callID, anchor: .bottom) }
                }
                .onChange(of: workspace.pendingQuestion?.cardIdentity) { _, identity in
                    if let identity { scroll.scrollTo(identity, anchor: .bottom) }
                }
                .onChange(of: search.focusedMessageID) { _, id in
                    if let id { scroll.scrollTo(id, anchor: .center) }
                }
            }
        }
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
