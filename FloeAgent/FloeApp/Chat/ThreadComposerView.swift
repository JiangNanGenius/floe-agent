// FloeApp — Thread composer (bottom-pinned, multi-line).
//
// SPDX-License-Identifier: MPL-2.0
//
// The one composer used by both the Chat-first home and the thread
// detail: multi-line input pinned to the bottom (chrome material is
// allowed here), attachment picking (security-scoped bookmark via
// FilesCenter), model selection, workspace project selection (placeholder
// data source until T05's WorkspaceCenter), execution target and Agent
// mode. While a run is non-terminal the send button becomes a stop
// button. All controls keep the 44pt minimum target; the app stays
// fully usable without a configured model — only AI send is disabled.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import AVFoundation
import Speech
import FloeCore
import FloeModels

/// System speech-to-text controller used by every composer. Audio never
/// enters Floe persistence; the recognized text is copied into the draft and
/// the audio session is released as soon as dictation stops.
@MainActor
final class SpeechInputController: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case listening
        case unavailable(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = ""

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var sessionActivated = false

    var isListening: Bool { state == .listening }

    func toggle() async {
        if isListening {
            stop()
        } else {
            await start()
        }
    }

    func start() async {
        stop(resetState: false)
        state = .requestingPermission
        guard await requestPermissions() else {
            state = .unavailable(String(localized: "voice.permission_required"))
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            state = .unavailable(String(localized: "voice.unavailable"))
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            sessionActivated = true

            transcript = ""
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            recognitionRequest = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            if tapInstalled { input.removeTap(onBus: 0) }
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                request.append(buffer)
            }
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()
            state = .listening

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        if result.isFinal { self.stop() }
                    } else if error != nil {
                        self.stop(resetState: false)
                        self.state = .unavailable(String(localized: "voice.failed"))
                    }
                }
            }
        } catch {
            stop(resetState: false)
            state = .unavailable(String(localized: "voice.failed"))
        }
    }

    func stop(resetState: Bool = true) {
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if sessionActivated {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            sessionActivated = false
        }
        if resetState { state = .idle }
    }

    private func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speech else { return false }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

/// How the next run should execute. Forward-looking selection surface;
/// the runtime mapping lands with the workspace tasks (T04/T05).
enum AgentExecutionMode: String, CaseIterable, Identifiable, Sendable {
    /// Chat plus approved tool calls (default agent behavior).
    case agent
    /// Chat only — no tool execution requested.
    case chat

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .agent: "composer.mode.agent"
        case .chat: "composer.mode.chat"
        }
    }

    var localizedTitle: String {
        switch self {
        case .agent: String(localized: "composer.mode.agent")
        case .chat: String(localized: "composer.mode.chat")
        }
    }

    var systemImage: String {
        switch self {
        case .agent: "wand.and.sparkles"
        case .chat: "text.bubble"
        }
    }
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
    /// True when sending is allowed (non-empty draft + model + not running).
    let canSend: Bool
    /// Placeholder projects (empty until T05 wires WorkspaceCenter).
    var projects: [ComposerProject] = []
    @Binding var selectedProjectID: UUID?
    @Binding var executionTarget: AgentExecutionTarget
    @Binding var agentMode: AgentExecutionMode
    /// Attachment refs picked in this composer (displayed as chips).
    @Binding var attachments: [AttachmentRef]

    let onSend: () -> Void
    let onStop: () -> Void

    @State private var isPickerPresented = false
    @State private var attachmentError: String?
    @State private var dictationPrefix = ""
    @StateObject private var speechInput = SpeechInputController()
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if let attachmentError {
                errorBanner(attachmentError)
            }
            if case .unavailable(let message) = speechInput.state {
                errorBanner(message)
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
        .onChange(of: speechInput.transcript) { _, transcript in
            guard speechInput.isListening || !transcript.isEmpty else { return }
            let separator = dictationPrefix.isEmpty || dictationPrefix.last?.isWhitespace == true ? "" : " "
            draft = dictationPrefix + separator + transcript
        }
        .onDisappear { speechInput.stop() }
    }

    // MARK: - Input row

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                isPickerPresented = true
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
            .textFieldStyle(.plain)
            .accessibilityLabel("home.new_task.placeholder")
            .accessibilityIdentifier("composer.input")

            Button {
                if !speechInput.isListening { dictationPrefix = draft }
                Task { await speechInput.toggle() }
            } label: {
                Image(systemName: speechInput.isListening ? "waveform.circle.fill" : "microphone.circle")
                    .font(.title2)
                    .symbolEffect(.pulse, isActive: speechInput.isListening && !reduceMotion)
                    .foregroundStyle(speechInput.isListening ? FloeTheme.destructive : FloeTheme.primary)
            }
            .buttonStyle(.plain)
            .disabled(speechInput.state == .requestingPermission)
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel(speechInput.isListening ? "voice.stop" : "voice.start")
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
            } else {
                Button {
                    onSend()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSend ? FloeTheme.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("thread.send")
                .accessibilityIdentifier("composer.send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: - Context row: model / project / target / mode

    private var contextRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                modelPicker
                projectPicker
                targetPicker
                modePicker
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var modelPicker: some View {
        Group {
            if let modelName {
                Menu {
                    ForEach(models) { model in
                        Button {
                            selectedModelID = model.id
                        } label: {
                            if selectedModelID == model.id {
                                Label(model.displayName, systemImage: "checkmark")
                            } else {
                                Text(model.displayName)
                            }
                        }
                    }
                } label: {
                    composerChip(title: modelName, systemImage: "cpu")
                }
            } else {
                Label("composer.no_model", systemImage: "cpu")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(FloeTheme.pending)
            }
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
                    Task { await openProject(project.id) }
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
            guard let newValue else { return }
            Task { await openProject(newValue) }
        }
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
            attachmentError = error.localizedDescription
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
            attachmentError = error.localizedDescription
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
#endif
