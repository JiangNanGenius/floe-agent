// SPDX-License-Identifier: MPL-2.0

import FloeCore
import FloeAgentRuntime
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
    @State private var standaloneDraft = ""
    #if FLOE_UNIFIED_MAC
    @State private var choosingAttachments = false
    @State private var showAttachmentError = false
    @State private var mode: HostAgentMode = .chat
    @State private var criterion = ""
    #else
    @State private var showingSettings = false
    #endif

    private var draft: Binding<String> {
        workspaceDraft ?? $standaloneDraft
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
            } else {
                conversation
                #if FLOE_UNIFIED_MAC
                if let plan = workspace.plan { planCard(plan) }
                if let goal = workspace.goal { goalCard(goal) }
                if let approval = workspace.pendingApproval { approvalCard(approval) }
                composer
                #else
                HStack(alignment: .bottom) {
                    TextField("host.chat.prompt", text: draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...7)
                    if workspace.isSending {
                        Button("host.chat.stop") { workspace.stop() }
                            .disabled(!workspace.canStop)
                    } else {
                        Button("host.chat.send") {
                            if workspace.send(draft.wrappedValue) { draft.wrappedValue = "" }
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
            HStack {
                Button { choosingAttachments = true } label: {
                    Label("mac.workspace.attachFiles", systemImage: "paperclip")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("mac.workspace.attachFiles")
                .frame(width: 30)
                .disabled(workspace.isSending || workspace.isTerminating)
                TextField("host.chat.prompt", text: draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(FloeTheme.Typography.body)
                    .lineLimit(2...7)
                    .accessibilityIdentifier("thread.composer.input")
                    .disabled(workspace.isSending || workspace.isTerminating)
                if workspace.isSending {
                    Button(action: workspace.stop) {
                        FloeComposerActionGlyph(systemImage: "stop.fill", enabled: workspace.canStop, destructive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("host.chat.stop")
                    .disabled(!workspace.canStop)
                } else {
                    let needsCriterion = mode == .goal && workspace.goal?.status.isTerminal != false
                    let canSend = !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !workspace.isTerminating && !workspace.isAcceptingPlan
                        && (!needsCriterion || !criterion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button {
                        let project = workspace.selectedID == nil ? workspace.selectedWorkspaceID : nil
                        if workspace.send(draft.wrappedValue, workspaceID: project, mode: mode,
                                          criterion: needsCriterion ? criterion : "") {
                            draft.wrappedValue = ""
                        }
                    } label: {
                        FloeComposerActionGlyph(systemImage: "arrow.up", enabled: canSend)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("host.chat.send")
                    .accessibilityIdentifier("composer.send")
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
                }
            }
            if let openModelSettings {
                HStack(spacing: 6) {
                    modeControl
                    modelControl(openSettings: openModelSettings)
                    if let openFiles, workspace.selectedID == nil {
                        projectControl(openFiles: openFiles)
                    }
                    Spacer()
                }
                .padding(.leading, 4)
                .disabled(workspace.isSending || workspace.isTerminating || workspace.isAcceptingPlan)
            }
        }
        .padding(12)
        .modifier(FloeThreadComposerChrome())
        .frame(maxWidth: 720)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }

    private func planCard(_ plan: PlanDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: plan.summary)
                        ForEach(plan.sections.sorted { $0.order < $1.order }) { section in
                            Text(verbatim: section.title).font(.headline)
                            Text(verbatim: section.body)
                        }
                        if !plan.assumptions.isEmpty {
                            Text("mac.agent.planAssumptions").font(.headline)
                            ForEach(plan.assumptions) { Text(verbatim: $0.text) }
                        }
                        if !plan.risks.isEmpty {
                            Text("mac.agent.planRisks").font(.headline)
                            ForEach(plan.risks) { risk in
                                Text(verbatim: risk.text)
                                if let mitigation = risk.mitigation { Text(verbatim: mitigation).foregroundStyle(.secondary) }
                            }
                        }
                        Text("mac.agent.acceptanceCriteria").font(.headline)
                        ForEach(plan.acceptanceCriteria) { criterion in
                            Text(verbatim: criterion.text)
                            Text(verbatim: criterion.verification).foregroundStyle(.secondary)
                        }
                        if plan.status == .ready {
                            Button("mac.agent.acceptPlan") {
                                Task {
                                    if await workspace.acceptPlan(plan) { mode = .agent }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(workspace.isSending || workspace.isAcceptingPlan || workspace.isTerminating)
                            .accessibilityIdentifier("mac.agent.acceptPlan")
                        } else if let accepted = workspace.pendingAcceptedPlan {
                            Button("mac.agent.runPlan") { workspace.runAcceptedPlan(accepted) }
                                .buttonStyle(.borderedProminent)
                                .disabled(workspace.isSending || workspace.isTerminating || !workspace.stagedAttachments.isEmpty)
                                .accessibilityIdentifier("mac.agent.runPlan")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 230)
            } label: {
                Label {
                    Text(verbatim: plan.title).lineLimit(1)
                } icon: {
                    Image(systemName: plan.status == .accepted ? "checkmark.circle" : "list.bullet.clipboard")
                }
                .accessibilityLabel(plan.status == .accepted ? Text("mac.agent.planAccepted") : Text("mac.agent.planReview"))
            }
            .id(plan.id)
            .accessibilityIdentifier("mac.agent.planCard")
        }
        .modifier(HostTaskCardChrome())
    }

    private func goalCard(_ goal: ConversationGoal) -> some View {
        DisclosureGroup {
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
            .frame(maxHeight: 180)
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
                Button { mode = choice } label: {
                    if choice == mode {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Label(choice.title, systemImage: choice.symbol)
                    }
                }
            }
        } label: {
            Label(mode.title, systemImage: mode.symbol)
                .font(FloeTheme.Typography.metadata)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("mac.composer.mode")
    }

    private func approvalCard(_ approval: HostAgentApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(LocalizedStringKey(approval.path == nil ? "mac.agent.approvalRequired" : "mac.agent.createFileApproval"),
                  systemImage: "hand.raised")
                .font(.headline)
            Text(verbatim: approval.path ?? approval.toolName)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            if let project = workspace.workspaces.first(where: { $0.id == approval.workspaceID }) {
                Label {
                    Text(verbatim: project.name)
                } icon: {
                    Image(systemName: "folder")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let text = approval.text, !text.isEmpty {
                DisclosureGroup("mac.agent.reviewFileContents") {
                    ScrollView {
                        Text(verbatim: text).font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
            HStack {
                Spacer()
                Button("mac.agent.deny") { Task { await workspace.resolveApproval(approval, allow: false) } }
                    .accessibilityIdentifier("mac.agent.deny")
                Button("mac.agent.allowOnce") { Task { await workspace.resolveApproval(approval, allow: true) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mac.agent.allowOnce")
                    .disabled(approval.path == nil)
            }
            .disabled(workspace.isStopping || workspace.isResolvingApproval || workspace.isTerminating)
        }
        .modifier(HostTaskCardChrome())
        .accessibilityIdentifier("mac.agent.approvalCard")
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(workspace.stagedAttachments, id: \.id) { attachment in
                    let isImage = attachment.kind == .image
                    HStack(spacing: 5) {
                        Image(systemName: isImage ? "photo" : "doc")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: attachment.displayName).lineLimit(1)
                            if !isImage {
                                Text("mac.workspace.attachmentReferenceOnly").foregroundStyle(.secondary)
                            }
                        }
                        Button {
                            workspace.unstageAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("mac.workspace.removeAttachment")
                    }
                    .font(.caption)
                    .padding(6)
                    .background(FloeTheme.fieldSurface, in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
        .scrollIndicators(.hidden)
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
            Label(project?.name ?? String(localized: "mac.workspace.noProject"), systemImage: "folder")
                .font(FloeTheme.Typography.metadata)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder private func modelControl(openSettings: @escaping () -> Void) -> some View {
        if workspace.providers.isEmpty {
            Button(action: openSettings) {
                Label("host.chat.provider", systemImage: "cpu")
                    .font(FloeTheme.Typography.metadata)
            }
            .buttonStyle(.plain)
        } else {
            Menu {
                ForEach(workspace.providers, id: \.profile.id) { provider in
                    Button {
                        workspace.selectChatProvider(id: provider.profile.id)
                    } label: {
                        if provider.profile.id == workspace.selectedProviderID {
                            Label(provider.displayTitle, systemImage: "checkmark")
                        } else {
                            Text(verbatim: provider.displayTitle)
                        }
                    }
                }
                Divider()
                Button("host.chat.provider", action: openSettings)
            } label: {
                Label(workspace.modelName ?? String(localized: "host.chat.provider"), systemImage: "cpu")
                    .font(FloeTheme.Typography.metadata)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var conversation: some View {
        GeometryReader { proxy in
            ScrollView {
                if workspace.messages.isEmpty && workspace.pendingPrompt == nil {
                    FloeWorkbenchWelcomeHeader(icon: Image(nsImage: NSImage(named: "FloeBrand") ?? NSApp.applicationIconImage)) {
                        Text("home.welcome")
                    }
                    .frame(maxWidth: .infinity, minHeight: max(240, proxy.size.height))
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(workspace.messages) { message in
                            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                                if PlanConfirmationSnapshot.from(message: message) != nil {
                                    Label("mac.agent.planAccepted", systemImage: "checkmark.circle")
                                        .foregroundStyle(.secondary)
                                } else if message.role == "user" {
                                    UserMessageBubble(text: message.content, attachments: AttachmentChipItem.items(in: message.parts))
                                } else if message.role == "assistant" {
                                    MarkdownRendererView(source: message.content)
                                } else {
                                    Text(verbatim: message.content).foregroundStyle(.secondary)
                                }
                                ChatMessageFooter(sentAt: message.createdAt, messageID: message.id.uuidString,
                                                  userText: message.role == "user" ? message.content : nil)
                            }
                            .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
                            .contextMenu {
                                if let text = CredentialMessagePart.clipboardText(message.content) {
                                    Button("action.copy") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(text, forType: .string)
                                    }
                                }
                            }
                        }
                        if let prompt = workspace.pendingPrompt { UserMessageBubble(text: prompt) }
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
        }
    }
    #else
    private var conversation: some View {
        ScrollView {
            if workspace.messages.isEmpty && workspace.pendingPrompt == nil {
                ContentUnavailableView("mac.workspace.newTask", systemImage: "bubble.left.and.bubble.right")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
            }
            LazyVStack(alignment: .leading, spacing: 15) {
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

private extension HostAgentMode {
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
