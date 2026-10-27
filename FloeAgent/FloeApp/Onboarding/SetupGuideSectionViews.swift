// FloeApp — Setup guide sections two to ten plus the summary.
//
// SPDX-License-Identifier: MPL-2.0
//
// Common decisions stay inline and write through the service that already
// owns them. Anything richer opens the app's REAL editor inside the guide's
// own stack and returns to the same step, so the guide is one flow rather
// than a directory of Settings links.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeProviders
import FloeModels
import FloeExecution
import FloeLocalModels
import FloeLocalModelCatalog
import FloeAgentRuntime

private extension View {
    func setupTarget() -> some View { frame(minHeight: FloeTheme.minimumTarget) }
}

// MARK: - 2. Images & Creation

struct SetupCreationSection: View {
    @ObservedObject var model: SetupGuideModel
    private var center: ConversationCenter { model.center }
    private var environment: AppEnvironment { center.environment }

    var body: some View {
        List {
            Section {
                rolePicker(
                    titleKey: "setup.creation.vision",
                    role: .vision,
                    selection: Binding(
                        get: { center.modelPreferences.visionModelID },
                        set: { value in
                            guard value != center.modelPreferences.visionModelID else { return }
                            Task { await model.setAuxiliaryRole(.vision, modelID: value) }
                        }
                    ),
                    candidates: center.visionModels
                )
            } header: {
                Text("setup.creation.understanding")
            } footer: {
                Text("setup.creation.vision.footer")
            }

            Section {
                rolePicker(
                    titleKey: "setup.creation.canvas_assistant",
                    role: .canvasAssistant,
                    selection: Binding(
                        get: { center.modelPreferences.canvasAgentModelID },
                        set: { value in
                            guard value != center.modelPreferences.canvasAgentModelID else { return }
                            Task { await model.setAuxiliaryRole(.canvasAssistant, modelID: value) }
                        }
                    ),
                    candidates: center.canvasAssistantModels
                )
                rolePicker(
                    titleKey: "setup.creation.canvas_vision",
                    role: .canvasVision,
                    selection: Binding(
                        get: { center.modelPreferences.canvasVisionModelID },
                        set: { value in
                            guard value != center.modelPreferences.canvasVisionModelID else { return }
                            Task { await model.setAuxiliaryRole(.canvasVision, modelID: value) }
                        }
                    ),
                    candidates: center.visionModels
                )
            } header: {
                Text("settings.settings_root_view.canvas")
            } footer: {
                Text("setup.creation.canvas.footer")
            }

            Section {
                LabeledContent("setup.creation.image_generation") {
                    Text(modelLabel(center.modelPreferences.imageGenerationModelID
                                        ?? center.modelPreferences.sharedImageModelID,
                                     fallbackKey: "setup.creation.not_configured"))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("setup.creation.image_editing") {
                    Text(modelLabel(center.modelPreferences.imageEditingModelID
                                        ?? center.modelPreferences.sharedImageModelID,
                                     fallbackKey: "setup.creation.not_configured"))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("setup.creation.video") {
                    Text(modelLabel(center.modelPreferences.defaultVideoModelID,
                                     fallbackKey: "setup.creation.not_configured"))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("setup.creation.current")
            } footer: {
                Text("setup.creation.current.footer")
            }

            Section {
                NavigationLink {
                    // The shipped editor owns image generation, image editing
                    // and video routing. Changing it here is the same act as
                    // changing it in Settings, and returning lands back on
                    // this step.
                    AuxiliaryModelsView(center: center)
                } label: {
                    Label("setup.creation.open_routing", systemImage: "slider.horizontal.below.rectangle")
                        .setupTarget()
                }
                .accessibilityIdentifier("setup.creation.auxiliary")
            } footer: {
                Text("setup.creation.open_routing.footer")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func modelLabel(_ id: UUID?, fallbackKey: LocalizedStringKey) -> String {
        guard let id else { return FloeL10n.l(fallbackKey) }
        let all = center.configuredModelsByProvider.values.flatMap { $0 }
        return all.first(where: { $0.id == id })?.displayName
            ?? FloeL10n.l("setup.creation.not_configured")
    }

    @ViewBuilder
    private func rolePicker(
        titleKey: LocalizedStringKey,
        role: SetupGuideAuxiliaryRole,
        selection: Binding<UUID?>,
        candidates: [ModelProfile]
    ) -> some View {
        if candidates.isEmpty {
            HStack {
                Text(titleKey)
                Spacer()
                Text("setup.role.not_available")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
            .setupTarget()
            .accessibilityIdentifier("setup.role.\(role.rawValue).empty")
        } else {
            Picker(titleKey, selection: selection) {
                Text("setup.role.not_configured").tag(Optional<UUID>.none)
                ForEach(candidates) { candidate in
                    Text(candidate.displayName).tag(Optional(candidate.id))
                }
            }
            .accessibilityIdentifier("setup.role.\(role.rawValue)")
        }
    }
}

// MARK: - 3. Web Search

struct SetupWebSearchSection: View {
    @ObservedObject var model: SetupGuideModel
    private var center: ConversationCenter { model.center }
    private var search: WebSearchSettingsCenter { center.environment.webSearchSettingsCenter }

    var body: some View {
        List {
            Section {
                if search.instances.isEmpty {
                    Text("setup.search.none")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(search.instances) { instance in
                        Toggle(isOn: Binding(
                            get: { instance.configuration.enabled },
                            set: { search.setEnabled($0, id: instance.id) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(instance.configuration.displayName)
                                Text(search.hasCredential(
                                        account: instance.configuration.credentialAccount)
                                     ? "setup.search.ready" : "setup.search.incomplete")
                                    .font(FloeTheme.Typography.metadata)
                                    .foregroundStyle(.secondary)
                            }
                            .setupTarget()
                        }
                        .accessibilityIdentifier("setup.search.toggle.\(instance.id.uuidString)")
                    }
                }
            } header: {
                Text("setup.search.configured")
            } footer: {
                Text("setup.search.configured.footer")
            }

            Section {
                NavigationLink {
                    WebSearchSettingsView(
                        center: search,
                        catalogOwner: center.environment.contentUpdateCenter
                    )
                } label: {
                    Label("setup.search.open", systemImage: "magnifyingglass.circle")
                        .setupTarget()
                }
                .accessibilityIdentifier("setup.search.editor")
            } footer: {
                Text("setup.search.open.footer")
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - 4. Voice

struct SetupVoiceSection: View {
    @ObservedObject var model: SetupGuideModel
    /// Preview playback is owned by the shared speech service; the guide only
    /// holds its own owner id so leaving the page stops THIS preview and
    /// nothing else.
    @EnvironmentObject private var playback: SpeechService
    @Environment(\.continuousVoiceActive) private var voiceActive
    @AppStorage(VoiceRecognitionPreferences.methodKey) private var method =
        VoiceRecognitionPreferences.Method.automatic.rawValue
    @AppStorage(VoiceRecognitionLanguage.defaultsKey) private var language =
        VoiceRecognitionLanguage.automatic.rawValue
    @AppStorage("voice.audition.text") private var auditionText = ""
    @State private var previewID: String?
    @State private var previewOwnerID = UUID()

    private var center: ConversationCenter { model.center }
    private var speech: TTSSettingsService { center.environment.ttsSettingsService }

    var body: some View {
        List {
            Section {
                Picker("voice.input.method", selection: $method) {
                    ForEach(VoiceRecognitionPreferences.Method.allCases, id: \.rawValue) { option in
                        Text(VoiceRecognitionPreferences.title(option)).tag(option.rawValue)
                    }
                }
                .accessibilityIdentifier("setup.voice.method")
                Picker("settings.general_settings_view.recognition_language", selection: $language) {
                    ForEach(VoiceRecognitionLanguage.allCases, id: \.rawValue) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .accessibilityIdentifier("setup.voice.language")
            } header: {
                Text("voice.input.title")
            } footer: {
                Text("setup.voice.input.footer")
            }

            // The recognizer's own bytes stay service-owned. Asking for them
            // is one explicit tap inside this section, never a page entry.
            Section {
                if let row = model.resources.rows(kind: .speechRecognition).first {
                    SetupResourceRowView(
                        row: row,
                        prepare: { model.resources.prepareSpeechRecognitionModel() },
                        retry: { model.resources.prepareSpeechRecognitionModel() },
                        cancel: { model.resources.cancelSpeechRecognitionModel() }
                    )
                }
                NavigationLink {
                    SpeechInputSettingsView()
                } label: {
                    Label("setup.voice.input_details", systemImage: "waveform.circle")
                        .setupTarget()
                }
                .accessibilityIdentifier("setup.voice.inputEditor")
            } header: {
                Text("setup.voice.recognizer")
            } footer: {
                Text("setup.voice.recognizer.footer")
            }

            Section {
                NavigationLink {
                    SpeechVoicePickerView()
                } label: {
                    LabeledContent("setup.voice.output_voice",
                                   value: speech.voiceDisplayName(for: speech.snapshot)
                                       ?? SpeechVoiceNames.current(speech.snapshot))
                        .setupTarget()
                }
                .accessibilityIdentifier("setup.voice.pickVoice")
            } header: {
                Text("settings.voice.title")
            } footer: {
                Text("setup.voice.pick.footer")
            }

            // Browsing every available voice, including the ones this device
            // has not downloaded. Choosing one only remembers the wish; the
            // voice that already plays keeps playing, and the bytes start on
            // an explicit Download press.
            voiceBrowseSection

            voiceRows

            Section {
                HStack {
                    Text("voice.settings.rate")
                    Slider(value: Binding(
                        get: { speech.snapshot.speechRateRatio },
                        set: { value in speech.update { $0.speechRateRatio = value } }
                    ), in: TTSPlaybackControls.rateRange, step: 0.05)
                    Text(speech.snapshot.speechRateRatio, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                        .font(FloeTheme.Typography.metadata)
                }
                .accessibilityIdentifier("setup.voice.rate")
                Toggle(isOn: Binding(
                    get: { speech.snapshot.autoReadEnabled },
                    set: { value in speech.update { $0.autoReadEnabled = value } }
                )) {
                    Text("voice.settings.autoread")
                }
                .accessibilityIdentifier("setup.voice.autoRead")
                Toggle(isOn: Binding(
                    get: { speech.snapshot.allowBargeIn },
                    set: { value in speech.update { $0.allowBargeIn = value } }
                )) {
                    Text("voice.settings.barge_in")
                }
                .accessibilityIdentifier("setup.voice.interrupt")
                NavigationLink {
                    TTSSettingsView()
                } label: {
                    Label("setup.voice.output_settings", systemImage: "speaker.wave.2")
                        .setupTarget()
                }
                .accessibilityIdentifier("setup.voice.outputEditor")
            } header: {
                Text("setup.voice.reading")
            } footer: {
                Text("setup.voice.reading.footer")
            }

            Section {
                NavigationLink {
                    OnlineSpeechServicesView()
                } label: {
                    Label("voice.online.title", systemImage: "cloud")
                        .setupTarget()
                }
                .accessibilityIdentifier("setup.voice.onlineServices")
            } footer: {
                Text("setup.voice.online.footer")
            }
        }
        .listStyle(.insetGrouped)
        .onChange(of: method) { _, value in
            // Switching to on-device recognition is a stated intent, not a
            // silent download: the row above offers the transfer.
            if value == VoiceRecognitionPreferences.Method.enhanced.rawValue {
                model.markConfigured(.voice)
            }
        }
        .onDisappear {
            // Stop THIS page's preview and forget the intent to preview. The
            // service-owned download is deliberately left running, and nothing
            // is queued to play later.
            if playback.activeOwnerID == previewOwnerID {
                playback.stop()
                playback.clearFailure(ownerID: previewOwnerID)
            }
            previewID = nil
        }
    }

    /// The real voice catalogue, grouped by pack. An installed voice is used
    /// on tap; an undownloaded one is remembered with the service's own
    /// revision fence and only becomes the output voice after its pack is
    /// installed and validated — and only if the user still wants it.
    @ViewBuilder private var voiceBrowseSection: some View {
        Section {
            if speech.localVisibleModels.isEmpty {
                Text("setup.voice.no_voices")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
            ForEach(speech.localVisibleModels) { pack in
                // Bytes on disk are not usability. A pack still being
                // load-validated reads as checking, and one whose validation
                // failed reads as not usable yet — never as Ready.
                let bytesInstalled = speech.localInstalledModelIDs.contains(pack.id)
                let validationFailed = speech.localMigrationNote == "voice.local.error.verify"
                let validating = speech.localProgressOperation?.modelID == pack.id
                let installed = bytesInstalled && !validationFailed && !validating
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(SpeechVoiceNames.model(pack)).font(.subheadline.weight(.semibold))
                        Spacer()
                        if installed {
                            Text("setup.voice.pack.ready")
                                .font(.caption2).foregroundStyle(FloeTheme.success)
                        } else if validating {
                            Text("setup.voice.pack.checking")
                                .font(.caption2).foregroundStyle(FloeTheme.pending)
                        } else if bytesInstalled && validationFailed {
                            Text("setup.voice.pack.not_usable")
                                .font(.caption2).foregroundStyle(FloeTheme.destructive)
                        }
                    }
                    ForEach(pack.voices) { voice in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                // Product name first; the raw identifier only
                                // ever appears inside the pack detail page.
                                Text(voice.name)
                                Text(voice.languages.joined(separator: " · "))
                                    .font(FloeTheme.Typography.metadata)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            if installed {
                                if speech.snapshot.modelID == pack.id, speech.snapshot.voiceID == voice.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(FloeTheme.primary)
                                        .accessibilityLabel("setup.voice.in_use")
                                } else {
                                    Button("setup.voice.use") {
                                        model.choosePendingVoice(modelID: pack.id, voiceID: voice.id,
                                                                 prepare: false)
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("setup.voice.use.\(pack.id).\(voice.id)")
                                }
                            } else if speech.pendingVoice?.modelID == pack.id,
                                      speech.pendingVoice?.voiceID == voice.id {
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text("setup.voice.will_apply_when_ready \(voice.name)")
                                        .font(.caption2)
                                        .foregroundStyle(FloeTheme.pending)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: 6) {
                                        Button("setup.voice.download") {
                                            model.choosePendingVoice(modelID: pack.id, voiceID: voice.id,
                                                                     prepare: true)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .accessibilityIdentifier("setup.voice.download.\(pack.id).\(voice.id)")
                                        Button("action.cancel") { model.clearPendingVoice() }
                                            .buttonStyle(.bordered)
                                    }
                                }
                            } else {
                                VStack(alignment: .trailing, spacing: 4) {
                                    Button("setup.voice.choose") {
                                        model.choosePendingVoice(modelID: pack.id, voiceID: voice.id,
                                                                 prepare: false)
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("setup.voice.choose.\(pack.id).\(voice.id)")
                                    // A voice that is not on this device yet is
                                    // a real entry, not a dead control: the
                                    // download is the way to hear it, and it
                                    // never substitutes another voice.
                                    Button("setup.voice.download_to_preview") {
                                        model.choosePendingVoice(modelID: pack.id, voiceID: voice.id,
                                                                 prepare: true)
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("setup.voice.downloadPreview.\(pack.id).\(voice.id)")
                                }
                            }
                            previewButton(pack: pack, voice: voice, installed: installed)
                        }
                        .frame(minHeight: FloeTheme.minimumTarget)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityIdentifier("setup.voice.pack.\(pack.id)")
            }
            NavigationLink {
                LocalSpeechSettingsView()
            } label: {
                Label("voice.local.title", systemImage: "square.stack.3d.up")
                    .setupTarget()
            }
            .accessibilityIdentifier("setup.voice.localPacks")
        } header: {
            Text("setup.voice.browse")
        } footer: {
            Text("setup.voice.browse.footer")
        }
    }

    /// One independent preview per row. It speaks through the shared service
    /// with this page's own owner id, so stopping it here never touches a
    /// download, another surface's playback or the user's selection.
    @ViewBuilder
    private func previewButton(pack: LocalSpeechModel, voice: LocalSpeechModel.Voice,
                               installed: Bool) -> some View {
        let id = "\(pack.id)/\(voice.id)"
        let playing = previewID == id && playback.activeOwnerID == previewOwnerID && playback.isSpeaking
        Button {
            if playing {
                playback.stop()
                previewID = nil
            } else {
                previewID = id
                playback.preview(previewText, settings: previewSnapshot(pack: pack, voice: voice),
                                 ownerID: previewOwnerID)
            }
        } label: {
            Image(systemName: playing ? "stop.circle.fill" : "play.circle")
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        // Live voice conversation owns the audio route; a preview waits.
        .disabled(!installed || voiceActive || previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel(playing ? "voice.settings.audition.stop" : "voice.settings.audition")
        .accessibilityIdentifier("setup.voice.preview.\(pack.id).\(voice.id)")
    }

    /// The user's own audition text when they wrote one, otherwise a short
    /// neutral sentence. Previewing never changes the selected voice.
    private var previewText: String {
        let own = auditionText.trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? FloeL10n.l("setup.voice.preview.sample") : own
    }

    /// A throwaway snapshot for THIS row only: the current global controls with
    /// the candidate pack and voice. Nothing is persisted by a preview.
    private func previewSnapshot(pack: LocalSpeechModel, voice: LocalSpeechModel.Voice)
        -> TTSSettingsSnapshot {
        var value = speech.snapshot
        value.provider = .onDevice
        value.billingRoute = .payAsYouGo
        value.modelID = pack.id
        value.voiceID = voice.id
        value.language = nil
        value.connectionProviderID = nil
        return value
    }

    /// Every reported voice job keeps its own row. The current selection is
    /// shown as Ready or "will apply when ready" separately, so an already
    /// installed voice never hides a pack that is still downloading.
    @ViewBuilder private var voiceRows: some View {
        let rows = model.resources.rows(kind: .voicePack)
        let selection = model.resources.selection(for: .voicePack)
        Section {
            if rows.isEmpty {
                HStack {
                    Text("setup.voice.packs")
                    Spacer()
                    Text(selection.selectedSubjectID == nil
                         ? "setup.voice.no_pack_selected" : "setup.voice.pack_installed")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
                .setupTarget()
            }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 8) {
                    SetupResourceRowView(
                        row: row,
                        retry: {
                            if let modelID = row.jobSubjectID,
                               let pack = speech.localModelDescriptor(modelID) {
                                model.resources.prepareVoicePack(pack)
                            }
                        },
                        cancel: { model.resources.cancelVoicePack() }
                    )
                    if row.jobSubjectID != selection.selectedSubjectID,
                       let selected = selection.selectedSubjectID {
                        Text("setup.voice.will_apply_when_ready \(title(for: selected))")
                            .font(.caption2)
                            .foregroundStyle(FloeTheme.pending)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let pending = selection.pendingSubjectID {
                        Text("setup.voice.pending_selection \(title(for: pending))")
                            .font(.caption2)
                            .foregroundStyle(FloeTheme.pending)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("setup.voice.row.\(row.id)")
            }
        } header: {
            Text("setup.voice.downloads")
        } footer: {
            Text("setup.voice.downloads.footer")
        }
    }

    private func title(for modelID: String) -> String {
        speech.localModelDescriptor(modelID)?.title
            ?? speech.localVisibleModels.first(where: { $0.id == modelID })?.title
            ?? modelID
    }
}

// MARK: - 5. Files & Workspaces

struct SetupFilesSection: View {
    @ObservedObject var model: SetupGuideModel
    private var center: ConversationCenter { model.center }
    private var settings: SettingsCenter { center.environment.settingsCenter }

    var body: some View {
        List {
            Section {
                if settings.workspaces.isEmpty {
                    Text("setup.files.no_workspace")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("setup.files.default_workspace", selection: workspaceSelection) {
                        Text("setup.files.ask_each_time").tag(Optional<UUID>.none)
                        ForEach(settings.workspaces.filter { $0.kind == .project }) { workspace in
                            Text(workspace.name.isEmpty
                                 ? FloeL10n.l("settings.files.workspace.untitled")
                                 : workspace.name)
                                .tag(Optional(workspace.id))
                        }
                    }
                    .accessibilityIdentifier("setup.files.workspace")
                }
                NavigationLink {
                    FilesSettingsView(center: settings)
                } label: {
                    Label("setup.files.open", systemImage: "folder")
                        .setupTarget()
                }
                .accessibilityIdentifier("setup.files.editor")
            } header: {
                Text("settings.section.files")
            } footer: {
                Text("setup.files.footer")
            }

            // The runtime is its own row: its size, status and transfer are
            // independent of any folder choice and of any remote host, and
            // preparing it never boots the guest.
            Section {
                LinuxImageInstallCard(model: model.resources.runtime, allowsManualStart: false)
                if let row = model.resources.rows(kind: .localRuntime).first {
                    Text(LocalizedStringKey(row.stage.summaryTitleKey))
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("setup.files.runtime")
            } footer: {
                Text("setup.files.runtime.footer")
            }

            Section {
                NavigationLink {
                    ExecutionEnvironmentView(center: settings)
                } label: {
                    Label("settings.section.execution", systemImage: "terminal")
                        .setupTarget()
                }
                .accessibilityIdentifier("setup.files.execution")
                NavigationLink {
                    RemoteSettingsView(center: settings)
                } label: {
                    LabeledContent("setup.files.remote_hosts",
                                   value: "\(settings.remoteHostCount)")
                        .setupTarget()
                }
                .accessibilityIdentifier("setup.files.remote")
                NavigationLink {
                    GitHubSettingsView(center: center.environment.sourceControlCenter)
                } label: {
                    Label("settings.git_hub_settings_view.github_source_control", systemImage: "arrow.triangle.branch")
                        .setupTarget()
                }
                .accessibilityIdentifier("setup.files.git")
            } header: {
                Text("setup.files.connections")
            } footer: {
                Text("setup.files.connections.footer")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var workspaceSelection: Binding<UUID?> {
        Binding(
            get: { settings.defaultWorkspaceID },
            set: { value in
                guard value != settings.defaultWorkspaceID else { return }
                Task {
                    await settings.setDefaultWorkspace(id: value)
                    model.markConfigured(.files)
                }
            }
        )
    }
}

// MARK: - 6. Personalization & Memory

struct SetupPersonalizationSection: View {
    @ObservedObject var model: SetupGuideModel
    @ObservedObject private var memory: MemoryCenter

    init(model: SetupGuideModel) {
        self.model = model
        self.memory = model.center.environment.memoryCenter
    }

    var body: some View {
        List {
            Section {
                documentRow(titleKey: "setup.personalization.profile",
                            present: memory.profile != nil,
                            automatic: memory.profileAutomaticUpdates,
                            kind: .userProfile)
                documentRow(titleKey: "setup.personalization.soul",
                            present: memory.soul != nil,
                            automatic: memory.soulAutomaticUpdates,
                            kind: .soul)
            } header: {
                Text("setup.personalization.documents")
            } footer: {
                Text("setup.personalization.documents.footer")
            }

            Section {
                NavigationLink {
                    MemoryView(center: memory)
                } label: {
                    Label("settings.settings_root_view.memories_personalization", systemImage: "person.crop.circle.badge.checkmark")
                        .setupTarget()
                }
                .accessibilityIdentifier("setup.personalization.editor")
                Toggle(isOn: organizationBinding) {
                    Text("setup.personalization.organization")
                }
                .accessibilityIdentifier("setup.personalization.organization")
            } footer: {
                Text("setup.personalization.editor.footer")
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func documentRow(
        titleKey: LocalizedStringKey,
        present: Bool,
        automatic: Bool,
        kind: PersonalizationDocumentKind
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(titleKey)
                Spacer()
                Text(present ? "setup.personalization.exists" : "setup.personalization.empty")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: Binding(
                get: { automatic },
                set: { value in
                    Task {
                        await memory.setAutomaticUpdates(value, kind: kind)
                        model.markConfigured(.personalization)
                    }
                }
            )) {
                Text("setup.personalization.auto_update")
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("setup.personalization.\(kind.rawValue)")
    }

    /// The shipped memory policy, shown in its own product words and written
    /// through the same published preference the Memory editor uses.
    private var organizationBinding: Binding<Bool> {
        Binding(
            get: { memory.organizationMode == .modelManaged },
            set: { value in
                memory.organizationMode = value ? .modelManaged : .reviewFirst
                model.markConfigured(.personalization)
            }
        )
    }
}

// MARK: - 7. Permissions & Privacy

struct SetupPermissionsSection: View {
    @ObservedObject var model: SetupGuideModel
    private var center: ConversationCenter { model.center }
    private var settings: SettingsCenter { center.environment.settingsCenter }

    var body: some View {
        List {
            Section {
                Picker("settings.permissions.default_mode", selection: modeSelection) {
                    ForEach(AgentMode.allCases, id: \.self) { mode in
                        Text(modeTitle(mode)).tag(mode)
                    }
                }
                .accessibilityIdentifier("setup.permissions.mode")
                // The reviewer model is offered only when that policy is the
                // active one, exactly like the shipped permissions editor.
                if settings.defaultAgentMode == .approvalModel {
                    rolePicker(
                        titleKey: "setup.role.approval",
                        selection: approvalSelection,
                        candidates: center.approvalModels
                    )
                }
            } header: {
                Text("setup.permissions.approvals")
            } footer: {
                Text("setup.permissions.approvals.footer")
            }

            Section {
                NavigationLink {
                    AgentPermissionsView(center: settings)
                } label: {
                    Label("settings.section.permissions", systemImage: "checkmark.shield")
                        .setupTarget()
                }
                .accessibilityIdentifier("setup.permissions.editor")
                NavigationLink {
                    AppleCapabilitiesSettingsView()
                } label: {
                    Label("settings.apple_capabilities_settings_view.apple_capabilities", systemImage: "apple.logo")
                        .setupTarget()
                }
                .accessibilityIdentifier("setup.permissions.apple")
                NavigationLink {
                    PrivacySecurityView(center: settings)
                } label: {
                    Label("settings.section.privacy", systemImage: "hand.raised")
                        .setupTarget()
                }
                .accessibilityIdentifier("setup.permissions.privacy")
            } footer: {
                Text("setup.permissions.open.footer")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var modeSelection: Binding<AgentMode> {
        Binding(
            get: { settings.defaultAgentMode },
            set: { value in
                Task {
                    await settings.setDefaultAgentMode(value)
                    model.markConfigured(.permissions)
                    if value == .approvalModel, center.approvalModels.isEmpty {
                        model.markAttention(.permissions)
                    }
                }
            }
        )
    }

    private var approvalSelection: Binding<UUID?> {
        Binding(
            get: { center.modelPreferences.approvalModelID },
            set: { value in
                guard value != center.modelPreferences.approvalModelID else { return }
                Task { await model.setAuxiliaryRole(.approval, modelID: value) }
            }
        )
    }

    private func modeTitle(_ mode: AgentMode) -> String {
        switch mode {
        case .human: FloeL10n.l("settings.permissions.mode.ask")
        case .approvalModel: FloeL10n.l("settings.permissions.mode.automatic")
        case .fullControl: FloeL10n.l("settings.permissions.mode.full")
        }
    }

    @ViewBuilder
    private func rolePicker(
        titleKey: LocalizedStringKey,
        selection: Binding<UUID?>,
        candidates: [ModelProfile]
    ) -> some View {
        if candidates.isEmpty {
            HStack {
                Text(titleKey)
                Spacer()
                Text("setup.role.not_available").font(FloeTheme.Typography.metadata).foregroundStyle(.secondary)
            }
        } else {
            Picker(titleKey, selection: selection) {
                Text("setup.role.follow_main").tag(Optional<UUID>.none)
                ForEach(candidates) { candidate in
                    Text(candidate.displayName).tag(Optional(candidate.id))
                }
            }
            .accessibilityIdentifier("setup.role.approval")
        }
    }
}

// MARK: - 8. Background

struct SetupBackgroundSection: View {
    @ObservedObject var model: SetupGuideModel
    private var settings: SettingsCenter { model.center.environment.settingsCenter }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { settings.backgroundExecutionOptions.enhancedBackgroundEnabled },
                    set: { value in
                        Task {
                            await settings.setEnhancedBackgroundEnabled(value)
                            model.markConfigured(.background)
                        }
                    }
                )) {
                    Text("setup.background.enhanced")
                }
                .accessibilityIdentifier("setup.background.enhanced")
                if settings.backgroundExecutionOptions.enhancedBackgroundEnabled {
                    Toggle(isOn: Binding(
                        get: { settings.backgroundExecutionOptions.taskLiveActivityEnabled },
                        set: { value in
                            var options = settings.backgroundExecutionOptions
                            options.taskLiveActivityEnabled = value
                            Task {
                                await settings.setBackgroundExecutionOptions(options)
                                model.markConfigured(.background)
                            }
                        }
                    )) {
                        Text("setup.background.live_activity")
                    }
                    .accessibilityIdentifier("setup.background.liveActivity")
                }
            } header: {
                Text("setup.background.title")
            } footer: {
                Text("setup.background.footer")
            }

            Section {
                NavigationLink {
                    BackgroundExecutionSettingsView(
                        center: settings,
                        videoService: model.center.environment.backgroundVideoService,
                        audioService: model.center.environment.pipAudioService
                    )
                } label: {
                    Label("settings.section.background_execution", systemImage: "pip")
                        .setupTarget()
                }
                .accessibilityIdentifier("setup.background.editor")
            } footer: {
                Text("setup.background.open.footer")
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - 9. Sync & Storage

struct SetupSyncStorageSection: View {
    @ObservedObject var model: SetupGuideModel
    private var center: ConversationCenter { model.center }
    private var settings: SettingsCenter { center.environment.settingsCenter }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { settings.overallSyncEnabled },
                    set: { value in
                        settings.setOverallSyncEnabled(value)
                        model.markConfigured(.syncStorage)
                    }
                )) {
                    Text("setup.sync.storage.device_sync")
                }
                .disabled(!iCloudAvailable)
                .accessibilityIdentifier("setup.sync.device")
                Toggle(isOn: Binding(
                    get: { settings.configurationSyncEnabled },
                    set: { value in
                        settings.setConfigurationSyncEnabled(value)
                        model.markConfigured(.syncStorage)
                    }
                )) {
                    Text("setup.sync.configuration")
                }
                .disabled(!iCloudAvailable)
                .accessibilityIdentifier("setup.sync.configuration")
                if !iCloudAvailable {
                    Text("setup.sync.unavailable")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("settings.section.sync")
            } footer: {
                Text("setup.sync.footer")
            }

            Section {
                NavigationLink {
                    SyncSettingsView(center: settings)
                } label: {
                    Label("setup.sync.open", systemImage: "icloud")
                        .setupTarget()
                }
                .accessibilityIdentifier("setup.sync.editor")
                NavigationLink {
                    DataManagementView(environment: center.environment,
                                       conversationCenter: center)
                } label: {
                    Label("setup.storage.open", systemImage: "archivebox")
                        .setupTarget()
                }
                .accessibilityIdentifier("setup.storage.editor")
            } footer: {
                Text("setup.storage.footer")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var iCloudAvailable: Bool {
        if case .available = settings.iCloudDrive { return true }
        return false
    }
}

// MARK: - 10. Skills & Updates

struct SetupSkillsSection: View {
    @ObservedObject var model: SetupGuideModel
    @ObservedObject private var content: ContentUpdateCenter
    @ObservedObject private var skills: SkillsCenter

    init(model: SetupGuideModel) {
        self.model = model
        self.content = model.center.environment.contentUpdateCenter
        self.skills = model.center.environment.skillsCenter
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { content.automaticChecksEnabled },
                    set: { value in
                        content.automaticChecksEnabled = value
                        model.markConfigured(.skills)
                    }
                )) {
                    Text("setup.skills.check_automatically")
                }
                .accessibilityIdentifier("setup.skills.automaticChecks")
                Toggle(isOn: Binding(
                    get: { content.autoUpdateDeclarativeContent },
                    set: { value in
                        content.autoUpdateDeclarativeContent = value
                        model.markConfigured(.skills)
                    }
                )) {
                    Text("setup.skills.auto_declarative")
                }
                .accessibilityIdentifier("setup.skills.autoDeclarative")
                Toggle(isOn: Binding(
                    get: { content.automaticDownloadOnWiFiOnly },
                    set: { value in content.automaticDownloadOnWiFiOnly = value }
                )) {
                    Text("setup.skills.wifi_only")
                }
                .accessibilityIdentifier("setup.skills.wifiOnly")
            } header: {
                Text("setup.skills.policy")
            } footer: {
                Text("setup.skills.policy.footer")
            }

            Section {
                if model.resources.rows(kind: .contentUpdate).isEmpty {
                    HStack {
                        Text(content.isChecking
                             ? "setup.skills.checking" : "setup.skills.up_to_date")
                        Spacer()
                        Button("setup.skills.check_now") { model.resources.checkContent() }
                            .accessibilityIdentifier("setup.skills.checkNow")
                    }
                }
                ForEach(model.resources.rows(kind: .contentUpdate)) { row in
                    SetupResourceRowView(
                        row: row,
                        prepare: {
                            let id = String(row.jobSubjectID ?? row.id.dropFirst("setup.resource.content_updates.".count))
                            model.resources.prepareContent(id)
                        },
                        retry: {
                            let id = String(row.jobSubjectID ?? row.id.dropFirst())
                            model.resources.prepareContent(id)
                        }
                    )
                }
            } header: {
                Text("setup.skills.available")
            } footer: {
                Text("setup.skills.available.footer")
            }

            // A "Get" started in the hub is the centre's own job: mirror its
            // real stage here too, so installing a skill from the wizard is
            // never silently absent from the guide.
            Section {
                ForEach(model.resources.rows(kind: .skillHub)) { row in
                    SetupResourceRowView(
                        row: row,
                        retry: {
                            if let id = row.jobSubjectID { model.resources.prepareSkillHub(id: id) }
                        },
                        cancel: {
                            if let id = row.jobSubjectID { model.resources.cancelSkillHub(id: id) }
                        }
                    )
                }
                NavigationLink {
                    SkillsView(center: skills)
                } label: {
                    Label("setup.skills.browse", systemImage: "puzzlepiece.extension")
                        .setupTarget()
                }
                .accessibilityIdentifier("setup.skills.hub")
            } header: {
                Text("setup.skills.gets")
            } footer: {
                Text("setup.skills.gets.footer")
            }

            Section {
                NavigationLink {
                    ContentUpdatesSettingsView(center: content)
                } label: {
                    Label("settings.section.updates", systemImage: "arrow.triangle.2.circlepath")
                        .setupTarget()
                }
                .accessibilityIdentifier("setup.skills.editor")
                NavigationLink {
                    SkillsView(center: skills)
                } label: {
                    LabeledContent("setup.skills.installed", value: "\(skills.installed.count)")
                        .setupTarget()
                }
                .accessibilityIdentifier("setup.skills.library")
            } footer: {
                Text("setup.skills.open.footer")
            }
        }
        .listStyle(.insetGrouped)
        .onChange(of: content.installingIDs) { _, _ in model.scheduleSummaryRefresh() }
        .onChange(of: skills.hubInstallJobs) { _, _ in model.scheduleSummaryRefresh() }
    }
}

// MARK: - Summary

struct SetupSummarySection: View {
    @ObservedObject var model: SetupGuideModel

    var body: some View {
        List {
            Section {
                ForEach(model.summary) { entry in
                    Button {
                        model.jump(to: entry.section)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: entry.section.systemImage)
                                .foregroundStyle(FloeTheme.primary)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LocalizedStringKey(entry.titleKey))
                                Text(outcomeDetail(entry))
                                    .font(FloeTheme.Typography.metadata)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 6)
                            Text(LocalizedStringKey(entry.outcome.titleKey))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(outcomeColor(entry.outcome))
                        }
                        .frame(minHeight: FloeTheme.minimumTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("setup.summary.jump.\(entry.section.rawValue)")
                }
            } header: {
                Text("setup.summary.sections")
            } footer: {
                Text("setup.summary.sections.footer")
            }

            // Preparation continues on its own terms. Listing it here states
            // the truth without blocking anything or popping a dialog.
            if model.resources.isAnyPreparing {
                Section {
                    ForEach(model.resources.rows.filter { $0.stage.isPreparing }) { row in
                        SetupResourceRowView(
                            row: row,
                            cancel: { cancel(row) }
                        )
                    }
                    Text("setup.summary.preparing \(model.resources.preparingCount.formatted())")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("setup.summary.preparing")
                } footer: {
                    Text("setup.summary.preparing.footer")
                }
            }

            if model.resources.attentionCount > 0 {
                Section {
                    ForEach(model.resources.failedRows) { row in
                        SetupResourceRowView(row: row, retry: { retry(row) })
                    }
                } header: {
                    Text("setup.summary.attention")
                } footer: {
                    Text("setup.summary.attention.footer")
                }
            }

            Section {
                LabeledContent("setup.summary.provider",
                               value: model.center.hasConfiguredProvider
                               ? FloeL10n.l("setup.summary.provider.ready")
                               : FloeL10n.l("setup.summary.provider.none"))
                    .accessibilityIdentifier("setup.summary.provider")
            } footer: {
                Text("setup.summary.provider.footer")
            }
        }
        .listStyle(.insetGrouped)
        .task { await model.refreshFacts() }
        .onReceive(model.resources.objectWillChange) { _ in
            model.scheduleSummaryRefresh()
        }
    }

    private func outcomeDetail(_ entry: SetupSummaryEntry) -> LocalizedStringKey {
        switch entry.outcome {
        case .saved: entry.section.detailKey
        case .defaulted: "setup.summary.defaulted_hint"
        case .preparing: "setup.summary.preparing_hint"
        case .later: "setup.summary.later_hint"
        case .needsAttention: "setup.summary.attention_hint"
        }
    }

    private func outcomeColor(_ outcome: SetupSummaryEntry.Outcome) -> Color {
        switch outcome {
        case .saved: FloeTheme.success
        case .defaulted: FloeTheme.primary
        case .preparing: FloeTheme.pending
        case .later: Color.secondary
        case .needsAttention: FloeTheme.destructive
        }
    }

    private func cancel(_ row: SetupResourceRow) {
        switch row.kind {
        case .speechRecognition: model.resources.cancelSpeechRecognitionModel()
        case .voicePack: model.resources.cancelVoicePack()
        case .onDeviceModel:
            if let id = row.jobSubjectID,
               let entry = CuratedLocalModelCatalog.entries.first(where: { $0.id == id }) {
                model.resources.cancelOnDeviceModel(entry)
            }
        case .localRuntime: model.resources.cancelRuntime()
        // The signed-content installer owns its own commit transaction and
        // exposes no per-entry cancel; the hub job does, and only it is
        // cancellable from here.
        case .contentUpdate: break
        case .skillHub:
            if let id = row.jobSubjectID { model.resources.cancelSkillHub(id: id) }
        }
    }

    private func retry(_ row: SetupResourceRow) {
        switch row.kind {
        case .speechRecognition: model.resources.prepareSpeechRecognitionModel()
        case .voicePack:
            if let id = row.jobSubjectID, let pack = model.center.environment.ttsSettingsService
                .localModelDescriptor(id) {
                model.resources.prepareVoicePack(pack)
            }
        case .onDeviceModel:
            if let id = row.jobSubjectID,
               let entry = CuratedLocalModelCatalog.entries.first(where: { $0.id == id }) {
                model.resources.prepareOnDeviceModel(entry)
            }
        case .localRuntime: model.resources.prepareRuntime()
        case .contentUpdate:
            if let id = row.jobSubjectID { model.resources.prepareContent(id) }
        case .skillHub:
            if let id = row.jobSubjectID { model.resources.prepareSkillHub(id: id) }
        }
    }
}
#endif
