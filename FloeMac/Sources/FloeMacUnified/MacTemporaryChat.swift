// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeCore
import FloeModels
import FloeTools
import FloeAgentRuntime
import FloeMacSelfCore
import FloePersistence

@MainActor
final class MacTemporaryChatModel: ObservableObject {
    typealias Writer = @MainActor (ConversationPromoter.Snapshot, [ConversationPromoter.ModelConfiguration],
                                   @escaping @Sendable () throws -> Void) async throws -> Void
    @Published private(set) var session: FloeMacTemporaryConversation?
    @Published var draft = ""
    @Published private(set) var messages: [PersistedMessage] = []
    @Published private(set) var answer = ""
    @Published private(set) var sending = false
    @Published private(set) var keeping = false
    @Published private(set) var approval: ApprovalRequestSnapshot?
    @Published private(set) var notice: String?
    private var sendTask: Task<Void, Never>?
    private var keepTask: Task<Void, Never>?

    func begin() {
        discard()
        session = FloeMacTemporaryConversation()
    }

    func discard() {
        let previous = session
        previous?.invalidate()
        session = nil
        sendTask?.cancel()
        keepTask?.cancel()
        sendTask = nil
        keepTask = nil
        draft = ""
        messages = []
        answer = ""
        sending = false
        keeping = false
        approval = nil
        notice = nil
        if let previous { Task { await previous.discard() } }
    }

    func send(provider: FloeMacSelfProviderBinding, search: MacSearchAccess? = nil) {
        let text = draft
        guard let origin = session, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sending, !keeping else { return }
        let priorCount = messages.count
        sending = true
        draft = ""
        notice = nil
        answer = ""
        sendTask = Task {
            do {
                let fetch = MacPublicWebFetch()
                var tools = [AnyAgentTool(descriptor: MacPublicWebFetch.descriptor, run: fetch.run)]
                if let search, search.isConfigured {
                    let web = MacSearchTool(access: search)
                    tools.append(AnyAgentTool(descriptor: MacSearchTool.descriptor, run: web.run))
                }
                try await origin.send(text, provider: provider, publicWeb: tools,
                    onPrepared: { [weak self] in await self?.refresh(from: origin) },
                    onEvent: { [weak self] event in await self?.receive(event, from: origin) })
            } catch {
                guard session === origin else { return }
                notice = MacPermissionsText.t("消息未能完成，请重试或检查模型设置。", "The message could not finish. Try again or check the model settings.")
                if draft.isEmpty, await origin.messages().count == priorCount, session === origin { draft = text }
            }
            await refresh(from: origin)
            guard session === origin else { return }
            answer = ""
            sending = false
            approval = nil
            sendTask = nil
        }
    }

    private func refresh(from origin: FloeMacTemporaryConversation) async {
        let stored = await origin.messages()
        if session === origin { messages = stored }
    }

    private func receive(_ event: HarnessEvent, from origin: FloeMacTemporaryConversation) {
        guard session === origin else { return }
        switch event {
        case .answerDelta(let delta): answer += delta.text
        case .approvalRequested(let request): approval = request
        case .approvalResolved(let id):
            if approval?.toolCall.id == id { approval = nil }
        case .terminal(.failed(let error, _)): notice = SecretRedactor.redact(error)
        default: break
        }
    }

    func resolve(_ request: ApprovalRequestSnapshot, allow: Bool) {
        guard let origin = session, approval?.id == request.id else { return }
        Task {
            if await origin.resolve(request, allow: allow), session === origin, approval?.id == request.id { approval = nil }
        }
    }

    func stop() {
        if let origin = session { Task { await origin.stop() } }
    }

    func keep(using save: @escaping Writer, didKeep: @escaping @MainActor (UUID) -> Void) {
        guard let origin = session, !keeping, !messages.isEmpty else { return }
        keeping = true
        let currentSend = sendTask
        keepTask = Task {
            // Let in-flight provider or approved reads settle in RAM. A route
            // change invalidates immediately even while this task is waiting.
            await currentSend?.value
            guard session === origin, !Task.isCancelled else { return }
            do {
                try await origin.keep { snapshot, profiles, fence in
                    try await save(snapshot, profiles, fence)
                }
                guard session === origin, !Task.isCancelled else { return }
                didKeep(origin.id)
                if session === origin { discard() }
            } catch {
                guard session === origin else { return }
                keeping = false
                keepTask = nil
                notice = MacPermissionsText.t("保存失败。临时聊天仍在这里，可以再次保存。", "Could not save. Your temporary chat is still here. Try saving again.")
            }
        }
    }
}

struct MacTemporaryChatView: View {
    @ObservedObject var model: MacTemporaryChatModel
    let provider: HostAgentProvider?
    var search: MacSearchAccess? = nil
    let save: MacTemporaryChatModel.Writer
    let didKeep: @MainActor (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(MacPermissionsText.t("离开后清除。保留后可在任务列表中继续。", "Cleared when you leave. Keep it to continue from your task list."))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(MacPermissionsText.t("保留为会话", "Keep as Saved Chat")) {
                    model.keep(using: save, didKeep: didKeep)
                }
                .disabled(model.messages.isEmpty || model.keeping)
            }
            Divider()
            ThreadTranscriptViewport(ready: model.session != nil, searchIsActive: false, jump: nil,
                updates: ThreadTranscriptUpdates(textBytes: model.answer.utf8.count, reasoningBytes: 0,
                    eventCount: 0, messageCount: model.messages.count, isRunning: model.sending),
                firstRowID: nil, hasEarlierMessages: false, loadingEarlierMessages: false, loadEarlier: { false }) { _ in
                ForEach(model.messages.filter { ["user", "assistant"].contains($0.role) }) { message in
                    Group {
                        if message.role == "user" {
                            UserMessageBubble(text: CredentialMessagePart.clipboardText(message.content)
                                ?? String(localized: "chat.user_message_bubble.secure_credentials"))
                        } else {
                            MarkdownRendererView(source: message.content)
                        }
                    }
                    .textSelection(.enabled)
                }
                if !model.answer.isEmpty { MarkdownRendererView(source: model.answer, isStreaming: true).textSelection(.enabled) }
            }
            if let approval = model.approval {
                let fields = (try? JSONSerialization.jsonObject(with: approval.toolCall.argumentsJSON)) as? [String: Any]
                let isSearch = approval.toolCall.toolName == MacSearchTool.name
                let target = isSearch ? fields?["query"] as? String : (fields?["url"] as? String).flatMap(URL.init(string:))?.host
                HStack {
                    Text(isSearch ? MacPermissionsText.t("搜索网页", "Search the web") : MacPermissionsText.t("读取公开网页", "Read public webpage"))
                    if let target { Text(verbatim: SecretRedactor.redact(target)).lineLimit(3).textSelection(.enabled) }
                    Spacer()
                    Button(MacPermissionsText.t("拒绝", "Decline")) { model.resolve(approval, allow: false) }
                    Button(MacPermissionsText.t("允许一次", "Allow Once")) { model.resolve(approval, allow: true) }
                }
            }
            if let notice = model.notice { Text(verbatim: notice).font(.callout).foregroundStyle(.secondary) }
            if provider == nil {
                Text(MacPermissionsText.t("请先在模型供应商设置中选择对话模型。", "Choose a chat model in model provider settings.")).foregroundStyle(.secondary)
            } else if let provider {
                Text(verbatim: provider.model.displayName).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom) {
                TextField("host.chat.prompt", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...7).disabled(model.keeping)
                if model.sending {
                    Button("host.chat.stop", action: model.stop)
                } else {
                    Button("host.chat.send") { if let provider { model.send(provider: provider.binding(), search: search) } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(provider == nil || model.keeping || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if model.keeping { ProgressView(MacPermissionsText.t("正在保留会话…", "Saving chat…")).controlSize(.small) }
        }
        .padding().frame(maxWidth: 800).frame(maxWidth: .infinity)
        .accessibilityIdentifier("mac.temporary.chat")
    }
}

#if FLOE_MAC_HOST_SMOKE
import FloeProviders

extension MacTemporaryChatModel {
    /// Isolated Agent smoke only. A fresh provider and model have never had
    /// an ordinary launch: Keep must repair their foreign keys atomically.
    static func verify(in workspace: HostAgentWorkspace) async -> Bool {
        guard workspace.isReady, let config = try? HostAgentProvider(displayName: "Temporary Fixture",
            endpoint: "https://fixture.invalid/v1", protocolKind: .openAIChatCompletions, modelID: "temporary-fixture", apiKey: "")
        else { return false }
        let binding = FloeMacSelfProviderBinding(provider: config.profile, model: config.model, adapter: FixtureProvider(), credentials: .init())
        let model = MacTemporaryChatModel()
        model.begin()
        guard let first = model.session else { return false }
        model.draft = "temporary message"
        model.send(provider: binding)
        await model.sendTask?.value
        guard model.messages.map(\.content) == ["temporary message", "temporary reply"],
              !workspace.conversations.contains(where: { $0.id == first.id }),
              (try? await workspace.transcript(conversationID: first.id))?.isEmpty != false else { return false }

        // Deliberately throw on the last in-transaction check. The whole
        // write must roll back and the same RAM conversation can be retried.
        let cancelAtCommit = FixtureCommitFailure()
        var navigated: UUID?
        model.keep(using: { snapshot, profiles, check in
            try await workspace.keepTemporaryConversation(snapshot, configuration: profiles, checkCancellation: {
                try check()
                try cancelAtCommit.check()
            })
        }, didKeep: { navigated = $0 })
        await model.keepTask?.value
        guard navigated == nil, model.session === first, !model.keeping,
              (try? await workspace.transcript(conversationID: first.id))?.isEmpty != false else { return false }
        model.keep(using: workspace.keepTemporaryConversation, didKeep: { navigated = $0 })
        await model.keepTask?.value
        guard navigated == first.id, let saved = workspace.conversations.first(where: { $0.id == first.id }),
              saved.purpose == .ordinary,
              (try? await workspace.transcript(conversationID: first.id))?.map(\.content) == ["temporary message", "temporary reply"]
        else { return false }
        guard await workspace.changeConversationMetadata(id: first.id, change: .delete) else { return false }

        model.begin()
        guard let discarded = model.session else { return false }
        model.draft = "leave before saving"
        model.send(provider: binding)
        await model.sendTask?.value
        guard !model.messages.isEmpty else { return false }
        var entered = false
        let proceed = AsyncStream<Void>.makeStream()
        model.keep(using: { snapshot, profiles, check in
            entered = true
            for await _ in proceed.stream { break }
            try await workspace.keepTemporaryConversation(snapshot, configuration: profiles, checkCancellation: check)
        }, didKeep: { _ in navigated = discarded.id })
        let operation = model.keepTask
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !entered, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        guard entered else {
            proceed.continuation.finish()
            model.discard()
            return false
        }
        model.begin()
        proceed.continuation.finish()
        await operation?.value
        guard model.session?.id != discarded.id, model.messages.isEmpty, model.draft.isEmpty,
              navigated != discarded.id, (try? await workspace.transcript(conversationID: discarded.id))?.isEmpty != false
        else { return false }
        model.discard()
        return true
    }

    private struct FixtureProvider: ProviderAdapter {
        let protocolKind: ModelProtocol = .openAIChatCompletions
        func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
            AsyncThrowingStream { stream in
                guard request.ephemeralTransport else {
                    stream.finish(throwing: FloeError.validationFailed("Expected ephemeral transport"))
                    return
                }
                stream.yield(.textDelta(.init(text: "temporary reply")))
                stream.yield(.completed(.init(stopReason: .endTurn)))
                stream.finish()
            }
        }
        func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
    }

    private final class FixtureCommitFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var checks = 0
        func check() throws {
            try lock.withLock {
                checks += 1
                // Runtime admission, writer entry, and final commit decision.
                if checks == 3 { throw CancellationError() }
            }
        }
    }
}
#endif
