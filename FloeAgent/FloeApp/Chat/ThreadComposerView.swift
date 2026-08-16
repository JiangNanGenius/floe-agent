// FloeApp — Thread composer (bottom-pinned, multi-line).
//
// SPDX-License-Identifier: MPL-2.0
//
// The one composer used by both the Chat-first home and the thread
// detail: multi-line input pinned to the bottom (chrome material is
// allowed here), attachment picking (security-scoped bookmark via
// FilesCenter), model selection, workspace project selection, execution target and Agent
// mode. While a run is non-terminal the send button becomes a stop
// button. All controls keep the 44pt minimum target; the app stays
// fully usable without a configured model — only AI send is disabled.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import AVFoundation
import FloeCore
import FloeModels
import FloeAgentRuntime

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
    /// True when sending is allowed (non-empty draft + model + not running).
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

    @State private var isPickerPresented = false
    @State private var attachmentError: String?
    @State private var dictationPrefix = ""
    @EnvironmentObject private var voiceInput: VoiceInputController
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            if let attachmentError {
                errorBanner(attachmentError)
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
        .onChange(of: voiceInput.transcript) { _, transcript in
            guard voiceInput.isListening || !transcript.isEmpty else { return }
            let separator = dictationPrefix.isEmpty || dictationPrefix.last?.isWhitespace == true ? "" : " "
            draft = dictationPrefix + separator + transcript
        }
        .onDisappear { voiceInput.stop() }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding ends the capture session safely; the staged
            // transcript stays in the draft for the user to keep or edit.
            if phase != .active {
                voiceInput.handleInterruption(reason: .interrupted)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            voiceInput.handleAudioInterruption(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            voiceInput.handleAudioRouteChange(notification)
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
                if voiceInput.state.hasSession {
                    // Stop synchronously so a second rapid tap cannot observe
                    // the stale listening state and queue overlapping teardown.
                    voiceInput.stop()
                } else {
                    // Preserve whatever the user already typed; dictation
                    // appends after this prefix and never replaces it.
                    dictationPrefix = draft
                    voiceInput.requestStart()
                }
            } label: {
                Image(systemName: voiceInput.isListening ? "waveform.circle.fill" : "microphone.circle")
                    .font(.title2)
                    .symbolEffect(.pulse, isActive: voiceInput.isListening && !reduceMotion)
                    .foregroundStyle(voiceInput.isListening ? FloeTheme.destructive : FloeTheme.primary)
            }
            .buttonStyle(.plain)
            .disabled(voiceInput.state == .requestingPermission
                      || voiceInput.state == .preparing
                      || voiceInput.state == .stopping)
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel(voiceInput.isListening ? "voice.stop" : "voice.start")
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
                Button {
                    if router.selectedConversationID == nil {
                        router.openMore(.settings)
                    } else {
                        router.showInspector(.permissions)
                    }
                } label: {
                    composerChip(
                        title: router.selectedConversationID == nil ? "默认权限" : "任务权限",
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
#endif
