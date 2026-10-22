// FloeApp — A single foreground voice owner with text and file continuity.
#if canImport(UIKit)
import SwiftUI
import Combine
import PhotosUI
import UniformTypeIdentifiers
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders

@MainActor
final class VoiceConversationModelSelection: ObservableObject {
    @Published var modelID: UUID
    init(_ id: UUID) { modelID = id }
}

/// Observe state/transcripts separately from the high-frequency audio meters.
/// VoiceOrbView samples the meter locally; it never invalidates the transcript.
@MainActor
final class ContinuousVoiceScreenSession: ObservableObject {
    let coordinator: VoiceConversationCoordinator
    let driver: VoiceConversationRunDriver
    let selection: VoiceConversationModelSelection
    @Published private(set) var state: VoiceConversationState = .idle
    @Published private(set) var stagedText = ""
    @Published private(set) var answerText = ""
    @Published private(set) var spokenText = ""
    @Published private(set) var muted = false
    @Published private(set) var consumedAttachmentIDs = Set<UUID>()
    var initialAttachments: [AttachmentRef] { temporary ? [] : request.attachments }
    @Published private(set) var history: [PersistedMessage] = []
    @Published var failureKey: String?
    private let request: ContinuousVoiceRequest
    private let presentation: ContinuousVoicePresentation
    private let environment: AppEnvironment
    private var bridge: ContinuousVoiceSpeechBridge?
    private var subscriptions = Set<AnyCancellable>()
    private var sourceRound: UUID?
    private var source: ConfiguredTTSSpeechSource?
    private var historyTask: Task<Void, Never>?
    private var ended = false
    private var pendingTypedText = ""
    private var pendingFiles: [AttachmentRef] = []
    private let wasTemporary: Bool

    init(request: ContinuousVoiceRequest, presentation: ContinuousVoicePresentation, environment: AppEnvironment) {
        self.request = request
        self.presentation = presentation
        self.environment = environment
        wasTemporary = request.conversationID.map(environment.conversationCenter.isTemporaryConversation) ?? false
        let selection = VoiceConversationModelSelection(request.modelID)
        self.selection = selection
        let resolver: VoiceConversationRunDriver.ModelResolver = {
            environment.conversationCenter.providerAndModel(modelID: selection.modelID)
        }
        let created: @MainActor (UUID) -> Void = { id in
            guard presentation.request?.id == request.id else { return }
            presentation.bindConversation(id, for: request.id)
            request.onConversationCreated(id)
        }
        if let conversationID = request.conversationID {
            driver = VoiceConversationRunDriver(center: environment.conversationCenter,
                existingConversationID: conversationID, resolveModel: resolver,
                workspaceID: request.workspaceID, attachments: request.attachments,
                onConversationCreated: created)
        } else {
            driver = VoiceConversationRunDriver(center: environment.conversationCenter,
                deferredConversationCreation: true, resolveModel: resolver,
                workspaceID: request.workspaceID, attachments: request.attachments,
                chatReasoningDraftOwnerID: request.reasoningDraftOwnerID,
                onConversationCreated: created)
        }
        let language = VoiceRecognitionLanguage(rawValue: UserDefaults.standard.string(forKey: VoiceRecognitionLanguage.defaultsKey) ?? "") ?? .automatic
        coordinator = VoiceConversationCoordinator.live(driving: driver, language: language)
        coordinator.allowBargeIn = environment.ttsSettingsService.snapshot.allowBargeIn
        driver.onAttachmentsConsumed = { [weak self] files in
            guard let self, self.isActive else { return }
            let ids = Set(files.map(\.id))
            self.pendingFiles.removeAll { ids.contains($0.id) }
            self.consumedAttachmentIDs = ids
            request.onAttachmentsConsumed(files)
            if !self.wasTemporary, let owner = request.conversationID ?? request.draftOwnerID,
               let draft = ComposerDraftStore.shared.entry(for: owner) {
                ComposerDraftStore.shared.save(text: draft.text, attachments: draft.attachments.filter { !ids.contains($0.id) }, conversationID: owner)
            }
        }
        driver.onSpeechReceiptSaveIssue = { [weak self] _ in self?.failureKey = "voice.error.receipt" }
        coordinator.$state.removeDuplicates().sink { [weak self] state in
            guard let self else { return }
            self.state = state
            self.presentation.setRecording(state.hasSession && !self.muted, for: request.id)
            if state == .listening || state == .paused { self.refreshHistory() }
        }.store(in: &subscriptions)
        coordinator.$stagedTranscript.removeDuplicates().sink { [weak self] in self?.stagedText = $0 }.store(in: &subscriptions)
        coordinator.$answerText.removeDuplicates().sink { [weak self] in self?.answerText = $0 }.store(in: &subscriptions)
        coordinator.$currentSpokenText.removeDuplicates().sink { [weak self] in self?.spokenText = $0 }.store(in: &subscriptions)
        coordinator.$turnErrorMessage.sink { [weak self] message in
            guard let self else { return }
            if message != nil { self.failureKey = "voice.error.turn" }
            else if self.failureKey == "voice.error.turn" { self.failureKey = nil }
        }.store(in: &subscriptions)
        coordinator.$isMuted.removeDuplicates().sink { [weak self] value in
            guard let self else { return }
            self.muted = value
            self.presentation.setRecording(self.state.hasSession && !value, for: request.id)
        }.store(in: &subscriptions)
        environment.ttsSettingsService.$snapshot.map(\.allowBargeIn).removeDuplicates().sink { [weak self] in
            self?.coordinator.allowBargeIn = $0
        }.store(in: &subscriptions)
        selection.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        selection.$modelID.dropFirst().removeDuplicates().sink { id in request.onModelSelected(id) }.store(in: &subscriptions)
        coordinator.onSessionEnded = { [weak self] _ in self?.close() }
        bridge = ContinuousVoiceSpeechBridge(output: coordinator, synthesize: { [weak self] unit in
            guard let self else {
                let (stream, sender) = TTSAudioChunkStream.make()
                sender.finish(throwing: CancellationError())
                return stream
            }
            if self.sourceRound != unit.token.id {
                self.sourceRound = unit.token.id
                self.source = ConfiguredTTSSpeechSource(snapshot: environment.ttsSettingsService.snapshot,
                    settings: environment.ttsSettingsService, service: environment.ttsSpeechService)
            }
            return self.source!.synthesize(text: AnswerSpeechText.plainText(unit.text), sessionID: unit.token.id, segmentIndex: unit.index)
        }, onFailure: { [weak self] error in
            guard let self else { return }
            self.failureKey = SpeechFailureCopy.key(for: error)
            self.coordinator.pauseForScene(.inactive)
        }, onRoundEnded: { id in
            Task { await environment.localSpeechRuntime.endSession(id) }
        })
    }

    var temporary: Bool { wasTemporary }
    var isActive: Bool { !ended && presentation.request?.id == request.id }

    func start() async {
        guard presentation.request?.id == request.id else { return }
        presentation.installTeardown(for: request.id) { [weak self] in self?.end() }
        state = .preparing
        await environment.voiceInput.stopAndWait()
        await environment.speechService.stopAndWait()
        guard isActive, !Task.isCancelled else { return }
        bridge?.connect()
        refreshHistory()
        await coordinator.start()
    }

    func recover() async {
        let failure = failureKey
        failureKey = nil
        if failure == "voice.error.receipt" { await driver.retryPendingSpeechReceipts(); return }
        if failure == "voice.error.history" { refreshHistory(); return }
        if failure == "voice.error.turn", !stagedText.isEmpty { coordinator.sendNow(); return }
        await coordinator.resume()
    }

    func close() { end(); presentation.dismiss(request.id) }
    func end() {
        guard !ended else { return }
        preserveDraft()
        ended = true
        bridge?.stop()
        coordinator.end()
        historyTask?.cancel()
        subscriptions.removeAll()
    }
    func updatePendingDraft(_ text: String, attachments: [AttachmentRef]) {
        guard !ended else { return }
        pendingTypedText = text
        pendingFiles = attachments
        if !temporary { driver.stageAttachments(attachments) }
    }

    private func preserveDraft() {
        let owner = driver.conversationID ?? request.draftOwnerID
        guard let owner else { return }
        if wasTemporary && !environment.conversationCenter.isTemporaryConversation(owner) { return }
        var text = pendingTypedText
        if !stagedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, stagedText != text {
            text += (text.isEmpty ? "" : "\n\n") + stagedText
        }
        guard !text.isEmpty || !pendingFiles.isEmpty else { return }
        let store = ComposerDraftStore.shared
        let previous = wasTemporary ? nil : store.entry(for: owner)
        let mergedText = (previous?.text ?? "") + ((previous?.text.isEmpty ?? true) || text.isEmpty ? "" : "\n\n") + text
        let existingFiles = previous?.attachments ?? []
        let ids = Set(existingFiles.map(\.id))
        let files = existingFiles + pendingFiles.filter { !ids.contains($0.id) }
        if !wasTemporary {
            store.save(text: mergedText, attachments: files, conversationID: owner)
            store.flush()
        }
        presentation.returnDraft(ContinuousVoiceReturnedDraft(windowID: request.windowID,
            ownerID: owner, text: mergedText, attachments: wasTemporary ? [] : files))
    }

    func pauseForScene(_ phase: ScenePhase) {
        if phase != .active { coordinator.pauseForScene(phase == .background ? .background : .inactive) }
    }
    func submit(text: String, attachments: [AttachmentRef]) async -> Bool {
        guard !ended, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if !temporary { driver.stageAttachments(attachments) }
        return await coordinator.submitText(text)
    }
    func refreshHistory() {
        historyTask?.cancel()
        guard let id = driver.conversationID else { return }
        historyTask = Task { [weak self] in
            guard let self else { return }
            do {
                let messages = try await environment.conversationCenter.conversationStore(for: id).recentMessages(conversationID: id, limit: 200)
                guard !Task.isCancelled, !ended else { return }
                history = messages.filter { $0.role == "user" || $0.role == "assistant" }
            } catch { if !Task.isCancelled { failureKey = "voice.error.history" } }
        }
    }
}

struct ContinuousVoiceSessionHost: View {
    let request: ContinuousVoiceRequest
    let presentation: ContinuousVoicePresentation
    let environment: AppEnvironment
    @StateObject private var session: ContinuousVoiceScreenSession
    @Environment(\.scenePhase) private var scenePhase

    init(request: ContinuousVoiceRequest, presentation: ContinuousVoicePresentation, environment: AppEnvironment) {
        self.request = request; self.presentation = presentation; self.environment = environment
        _session = StateObject(wrappedValue: ContinuousVoiceScreenSession(request: request, presentation: presentation, environment: environment))
    }
    var body: some View {
        VoiceConversationView(session: session, environment: environment)
            .task { await session.start() }
            .onChange(of: scenePhase) { _, phase in session.pauseForScene(phase) }
            .onDisappear { session.close() }
    }
}

struct VoiceConversationView: View {
    @ObservedObject var session: ContinuousVoiceScreenSession
    let environment: AppEnvironment
    @State private var showsText = false
    @State private var showsSettings = false
    @State private var showsFiles = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var draft = ""
    @State private var attachments: [AttachmentRef] = []
    @State private var sending = false
    @State private var importing = false
    @FocusState private var typing: Bool

    init(session: ContinuousVoiceScreenSession, environment: AppEnvironment) {
        self.session = session
        self.environment = environment
        _attachments = State(initialValue: session.initialAttachments)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if showsText || typing {
                    transcript
                } else {
                    Spacer(minLength: 8)
                    VoiceOrbView(coordinator: session.coordinator, state: session.state, muted: session.muted)
                    Text(LocalizedStringKey(statusKey))
                        .font(.title3.weight(.medium))
                        .accessibilityIdentifier("voice.conversation.state")
                    Text(session.stagedText.isEmpty ? currentCaption : session.stagedText)
                        .font(.body).multilineTextAlignment(.center)
                        .lineLimit(4).frame(maxWidth: 460, minHeight: 56, alignment: .top)
                        .textSelection(.enabled)
                        .padding(.horizontal, 20)
                    Spacer(minLength: 8)
                }
                if let failure = session.failureKey ?? stateFailureKey {
                    VStack(spacing: 8) {
                        Text(LocalizedStringKey(failure)).font(.footnote).foregroundStyle(.red)
                        if permissionFailure {
                            Button("voice.action.settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        } else if failure != "voice.error.turn" || !session.stagedText.isEmpty {
                            Button(session.state == .paused ? "voice.action.resume" : "voice.action.retry") { Task { await session.recover() } }
                        }
                    }
                    .padding(.horizontal)
                }
                if session.state == .paused {
                    Button("voice.action.resume", systemImage: "play.fill") { Task { await session.coordinator.resume() } }
                        .buttonStyle(.borderedProminent)
                }
                if !session.stagedText.isEmpty {
                    Button("voice.action.send_now", systemImage: "arrow.up.circle.fill") { session.coordinator.sendNow() }
                }
                controls
                messageInput
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
            .background(Color(uiColor: .systemBackground))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    modelMenu
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(showsText ? "voice.action.hide_text" : "voice.action.show_text", systemImage: showsText ? "waveform" : "text.bubble") {
                        showsText.toggle(); if showsText { session.refreshHistory() }
                    }
                    Button("voice.conversation.settings", systemImage: "slider.horizontal.3") { showsSettings = true }
                    Button("voice.action.end", systemImage: "xmark") { session.close() }
                }
            }
            .sheet(isPresented: $showsSettings) {
                NavigationStack {
                    TTSSettingsView()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("common.done") { showsSettings = false } } }
                }
                .environmentObject(environment)
                .environmentObject(environment.ttsSettingsService)
                .environmentObject(environment.speechService)
                .environment(\.continuousVoiceActive, true)
            }
            .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                Task { await importFiles(urls) }
            }
            .onAppear { session.updatePendingDraft(draft, attachments: attachments) }
            .onReceive(session.$consumedAttachmentIDs) { ids in
                if !ids.isEmpty { attachments.removeAll { ids.contains($0.id) } }
            }
            .onChange(of: draft) { _, text in session.updatePendingDraft(text, attachments: attachments) }
            .onChange(of: attachments) { _, files in session.updatePendingDraft(draft, attachments: files) }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task { await importPhoto(item) }
            }
        }
        .accessibilityIdentifier("voice.conversation")
    }

    private var currentCaption: String {
        if session.spokenText.isEmpty { return FloeL10n.l("voice.conversation.empty") }
        return String(session.spokenText.prefix(200))
    }
    private var statusKey: String {
        if session.muted { return "voice.state.muted" }
        switch session.state {
        case .idle: return "voice.state.idle"
        case .requestingPermission: return "voice.state.permission"
        case .preparing: return "voice.state.preparing"
        case .listening: return "voice.state.listening"
        case .submitting, .waitingModel: return "voice.state.waiting"
        case .answering: return "voice.state.answering"
        case .paused, .failed: return "voice.state.paused"
        case .ending: return "voice.state.ending"
        }
    }
    private var permissionFailure: Bool {
        guard case .failed(let reason) = session.state else { return false }
        return reason == .microphonePermissionDenied || reason == .speechPermissionDenied
    }
    private var stateFailureKey: String? {
        guard case .failed(let reason) = session.state else { return nil }
        switch reason {
        case .microphonePermissionDenied, .speechPermissionDenied: return "voice.error.microphone"
        case .noAudioInput: return "voice.error.no_input"
        case .modelNotReady: return "voice.error.model"
        default: return "voice.error.recognition"
        }
    }
    private var controls: some View {
        HStack(spacing: 28) {
            Button(session.muted ? "voice.action.unmute" : "voice.action.mute", systemImage: session.muted ? "mic.slash.fill" : "mic.fill") {
                session.coordinator.setMuted(!session.muted)
            }
            .tint(session.muted ? .orange : .primary)
            Button("voice.action.interrupt", systemImage: "stop.fill") { session.coordinator.interruptNow() }
                .disabled(session.state != .answering && session.state != .waitingModel)
            Button("voice.action.end", systemImage: "phone.down.fill", role: .destructive) { session.close() }
        }
        .labelStyle(.iconOnly).buttonStyle(.bordered).controlSize(.large)
        .frame(minHeight: 52)
    }
    private var messageInput: some View {
        VStack(spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(attachments) { file in
                            Button { attachments.removeAll { $0.id == file.id } } label: {
                                Label(file.displayName, systemImage: "xmark.circle")
                                    .font(.caption).lineLimit(1)
                            }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                if !session.temporary {
                    Menu {
                        Button("chat.thread_composer_view.import_attachment", systemImage: "doc") { showsFiles = true }
                        PhotosPicker(selection: $selectedPhoto, matching: .images) { Label("voice.action.photo", systemImage: "photo") }
                    } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                    .disabled(importing)
                }
                TextField("voice.action.type", text: $draft, axis: .vertical)
                    .lineLimit(1...4).focused($typing)
                    .padding(.vertical, 12)
                Button("voice.action.send_now", systemImage: "arrow.up.circle.fill") { sendTyped() }
                    .font(.title2).labelStyle(.iconOnly).frame(width: 44, height: 44)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || importing)
            }
            .padding(.horizontal, 8)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22))
        }
    }
    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(session.history) { message in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(message.role == "user" ? "thread.role.user" : "thread.role.assistant")
                            .font(.caption).foregroundStyle(.secondary)
                        MarkdownRendererView(source: message.content, isStreaming: false)
                    }
                }
                if !session.answerText.isEmpty, session.history.last?.content != session.answerText { MarkdownRendererView(source: session.answerText, isStreaming: session.state == .answering) }
                if !session.stagedText.isEmpty { Text(session.stagedText).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical)
        }
        .textSelection(.enabled)
    }
    private var modelMenu: some View {
        Menu {
            let models = environment.conversationCenter.modelsByProvider.values.flatMap { $0 }
                .filter { $0.isEnabled && $0.isHiddenFromPrimaryPicker != true && environment.conversationCenter.providerAndModel(modelID: $0.id) != nil }
                .sorted { $0.displayName < $1.displayName }
            ForEach(models) { model in
                Button(model.displayName) { session.selection.modelID = model.id }
            }
        } label: {
            Text(environment.conversationCenter.providerAndModel(modelID: session.selection.modelID)?.1.displayName ?? FloeL10n.l("voice.conversation.model"))
                .lineLimit(1).font(.subheadline.weight(.semibold))
        }
    }
    private func sendTyped() {
        let text = draft
        let files = attachments
        sending = true
        Task {
            if await session.submit(text: text, attachments: files) {
                if draft == text { draft = "" }
                // Only onAttachmentsConsumed removes files after a real
                // run owns them; pre-launch failures keep the staged files.
                session.updatePendingDraft(draft, attachments: attachments)
                typing = false
            }
            sending = false
        }
    }
    private func importFiles(_ urls: [URL]) async {
        guard !session.temporary, session.isActive else { return }
        importing = true
        defer { importing = false }
        do {
            for url in urls.prefix(10) {
                let attachment = try await environment.filesCenter.registerPickedDocument(url: url, displayName: url.lastPathComponent)
                guard session.isActive, !Task.isCancelled else { return }
                attachments.append(attachment)
            }
        } catch { session.failureKey = "voice.error.attachment" }
    }
    private func importPhoto(_ item: PhotosPickerItem) async {
        guard !session.temporary, session.isActive else { return }
        importing = true
        defer { importing = false; selectedPhoto = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
            guard session.isActive, !Task.isCancelled else { return }
            attachments.append(try environment.filesCenter.registerPhotoData(data, displayName: "Photo-\(UUID().uuidString).jpg"))
        } catch { session.failureKey = "voice.error.attachment" }
    }
}
#endif
