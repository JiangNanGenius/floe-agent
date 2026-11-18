// SPDX-License-Identifier: MPL-2.0

import FloeCore
import FloePersistence
import SwiftUI
#if FLOE_UNIFIED_MAC
import AppKit
#endif

struct HostAgentWorkspaceView: View {
    @ObservedObject var workspace: HostAgentWorkspace
    var workspaceDraft: Binding<String>? = nil
    var openModelSettings: (() -> Void)? = nil
    @State private var standaloneDraft = ""
    #if !FLOE_UNIFIED_MAC
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
            TextField("host.chat.prompt", text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(FloeTheme.Typography.body)
                .lineLimit(2...7)
                .accessibilityIdentifier("thread.composer.input")
            HStack {
                if let openModelSettings {
                    Button(action: openModelSettings) {
                        Label(workspace.modelName ?? String(localized: "host.chat.provider"), systemImage: "cpu")
                            .font(FloeTheme.Typography.metadata)
                    }
                    .buttonStyle(.plain)
                    .disabled(workspace.isSending || workspace.isTerminating)
                }
                Spacer()
                if workspace.isSending {
                    Button(action: workspace.stop) {
                        FloeComposerActionGlyph(systemImage: "stop.fill", enabled: workspace.canStop, destructive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("host.chat.stop")
                    .disabled(!workspace.canStop)
                } else {
                    let canSend = !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !workspace.isTerminating
                    Button {
                        if workspace.send(draft.wrappedValue) { draft.wrappedValue = "" }
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
        }
        .padding(12)
        .modifier(FloeThreadComposerChrome())
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
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
                                if message.role == "user" {
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
