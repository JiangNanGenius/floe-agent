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
    var openImageWorkbench: (() -> Void)? = nil
    var findRequest: UUID? = nil
    var findConversationID: UUID? = nil
    @State private var standaloneDraft = ""
    #if FLOE_UNIFIED_MAC
    @StateObject private var search: MacConversationSearchModel
    @State private var choosingAttachments = false
    @State private var showAttachmentError = false
    @State private var criterion = ""
    @State private var goalForConfirmation: ConversationGoal?
    @State private var hiddenPlanConfirmations: Set<ThreadPlanConfirmationPresentationKey> = []
    private var mode: HostAgentMode { workspace.composerMode }
    #else
    @State private var showingSettings = false
    #endif

    init(workspace: HostAgentWorkspace, workspaceDraft: Binding<String>? = nil,
         openModelSettings: (() -> Void)? = nil, openFiles: (() -> Void)? = nil,
         openImageWorkbench: (() -> Void)? = nil, findRequest: UUID? = nil,
         findConversationID: UUID? = nil) {
        self.workspace = workspace
        self.workspaceDraft = workspaceDraft
        self.openModelSettings = openModelSettings
        self.openFiles = openFiles
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
                conversation
                if let failed = workspace.failedUserMessage,
                   let text = CredentialMessagePart.clipboardText(failed.content), !workspace.isSending {
                    Button("mac.agent.editFailedPrompt") {
                        draft.wrappedValue = text
                    }
                    .disabled(!draft.wrappedValue.isEmpty)
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
            switch result {
            case .success(let urls):
                let accepted = workspace.stageAttachments(urls)
                showAttachmentError = !urls.isEmpty && accepted.isEmpty
            case .failure:
                showAttachmentError = true
            }
        }
        .alert("mac.workspace.attachFailed", isPresented: $showAttachmentError) {
            Button("OK", role: .cancel) {}
        }
        .sheet(item: $goalForConfirmation) { goal in
            MacGoalConfirmationView(goal: goal) { steps, criteria in
                await workspace.confirmGoal(goal, completedSteps: steps, confirmedCriteria: criteria)
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
    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !workspace.stagedAttachments.isEmpty {
                attachmentStrip
            }
            if mode == .goal, workspace.goal?.status.isTerminal != false {
                TextField("mac.agent.goalCriterion", text: $criterion)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mac.agent.goalCriterion")
                    .disabled(workspace.isSending || workspace.isTerminating)
            }
            ComposerResponsiveRow {
                composerAttachments
                    .composerResponsiveLeadingControl()
                TextField("host.chat.prompt", text: draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(FloeTheme.Typography.body)
                    .lineLimit(2...7)
                    .accessibilityIdentifier("thread.composer.input")
                    .disabled(workspace.isSending || workspace.isTerminating)
                    .composerResponsiveFieldSlot()
                if workspace.isSending {
                    Button(action: workspace.stop) {
                        FloeComposerActionGlyph(systemImage: "stop.fill", enabled: workspace.canStop, destructive: true)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                    .accessibilityLabel("host.chat.stop")
                    .disabled(!workspace.canStop)
                } else {
                    let needsCriterion = mode == .goal && workspace.goal?.status.isTerminal != false
                    let canSend = !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !workspace.isTerminating && !workspace.isAcceptingPlan
                        && (!needsCriterion || !criterion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button {
                        let project = workspace.selectedID == nil ? workspace.selectedWorkspaceID : nil
                        submitDraft(workspaceID: project, mode: mode, criterion: needsCriterion ? criterion : "")
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
                    HStack(spacing: 10) {
                        modelControl(openSettings: openModelSettings)
                        if let openFiles {
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
                        modeControl
                    }
                }
                .padding(.leading, 4)
                .disabled(workspace.isSending || workspace.isTerminating || workspace.isAcceptingPlan)
            }
        }
        .padding(12)
        .modifier(FloeThreadComposerChrome())
        .dropDestination(for: URL.self) { urls, _ in
            guard workspace.selectedID == findConversationID, !workspace.isSending,
                  !workspace.isTerminating, !workspace.isLoadingHistory else { return false }
            return !workspace.stageAttachments(urls.filter(\.isFileURL)).isEmpty
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }

    private var composerAttachments: some View {
        Menu {
            Button("mac.workspace.attachFiles", systemImage: "paperclip") { choosingAttachments = true }
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
        if let plan = workspace.plan, plan.awaitsConfirmation,
           !hiddenPlanConfirmations.contains(.init(plan)) {
            planReview(for: plan)
                .id(ThreadPlanConfirmationPresentationKey(plan))
        }
    }

    private func planReview(for plan: PlanDraft) -> some View {
        var review = ThreadPlanReview(plan: plan, isAccepting: workspace.isAcceptingPlan,
                                      actionsDisabled: workspace.isSending || workspace.isTerminating,
                                      onDismiss: { hiddenPlanConfirmations.insert(.init(plan)) }) { execution in
            Task { await workspace.confirmAndRunPlan(plan, as: execution) }
        }
        #if FLOE_MAC_HOST_SMOKE
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
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: goal.objective)
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
                HStack(spacing: 8) {
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
            }
        } label: {
            HStack {
                Label("mac.agent.goalStatus", systemImage: "scope")
                Spacer()
                Text(LocalizedStringKey("mac.agent.goal.\(goal.status.rawValue)")).foregroundStyle(.secondary)
            }
        }
        .modifier(HostTaskCardChrome())
        .accessibilityIdentifier("mac.agent.goalCard")
    }

    private var modeControl: some View {
        Menu {
            ForEach(HostAgentMode.allCases, id: \.self) { choice in
                Button { workspace.composerMode = choice } label: {
                    if choice == mode {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Label(choice.title, systemImage: choice.symbol)
                    }
                }
            }
        } label: {
            FloeThreadComposerChip(title: Text(mode.title), systemImage: mode.symbol)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("mac.composer.mode")
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
                ForEach(workspace.providers, id: \.profile.id) { provider in
                    Button {
                        workspace.selectComposerProvider(provider.profile.id)
                    } label: {
                        if provider.profile.id == workspace.composerProvider?.profile.id {
                            Label(provider.displayTitle, systemImage: "checkmark")
                        } else {
                            Text(verbatim: provider.displayTitle)
                        }
                    }
                }
                Divider()
                Button("host.chat.provider", action: openSettings)
            } label: {
                FloeThreadComposerChip(
                    title: Text(verbatim: workspace.composerProvider?.displayTitle ?? String(localized: "host.chat.provider")),
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
                        FloeWorkbenchWelcomeHeader(icon: Image(nsImage: NSImage(named: "FloeBrand") ?? NSApp.applicationIconImage)) {
                            Text("home.welcome")
                        }
                        .frame(maxWidth: .infinity, minHeight: max(240, proxy.size.height))
                    } else {
                        LazyVStack(alignment: .leading, spacing: 16) {
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
                            if let approval = workspace.pendingApproval {
                                MacWorkspaceApprovalView(workspace: workspace, approval: approval)
                            }
                            if !workspace.streamedText.isEmpty {
                                MarkdownRendererView(source: workspace.streamedText, isStreaming: true)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: workspace.pendingApproval?.callID) { _, callID in
                    if let callID { scroll.scrollTo(callID, anchor: .bottom) }
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
            .frame(maxWidth: 720)
            .padding(.horizontal, 14)
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

    var symbol: String {
        switch self {
        case .chat: "bubble.left"
        case .agent: "bolt"
        case .plan: "list.bullet.clipboard"
        case .goal: "scope"
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
