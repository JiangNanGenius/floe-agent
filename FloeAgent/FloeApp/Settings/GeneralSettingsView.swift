// FloeApp — General settings section.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_SETTINGS.md §5 row 1: appearance, language, default
// reduce-motion override, haptics and date-time display style. Every control
// reads from and writes to
// SettingsCenter (UserDefaults or DB app_settings); no placeholder text.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeModels

struct GeneralSettingsView: View {
    @ObservedObject var center: SettingsCenter
    @AppStorage(ComposerHardwareReturnBehavior.defaultsKey)
    private var hardwareReturnBehavior = ComposerHardwareReturnBehavior.newline.rawValue
    @AppStorage(VoiceRecognitionPreferences.methodKey) private var voiceMethod = VoiceRecognitionPreferences.Method.automatic.rawValue
    @AppStorage(PersonalLibraryDeletionPreferences.trashEnabledKey) private var trashEnabled = true
    @EnvironmentObject private var speechSettings: TTSSettingsService
    /// Scene foldable capability snapshot. A plain environment value with an
    /// unknown default: isolated hosts never crash, and ordinary devices
    /// never see the foldable row.
    @Environment(\.foldableDisplay) private var foldableDisplay
    @ObservedObject private var layoutPreferences = LayoutPreferences.shared

    init(center: SettingsCenter) {
        self.center = center
    }

    var body: some View {
        Form {
            AppearanceSettingsSection(selection: Binding(
                get: { center.appearance },
                set: { center.setAppearance($0) }
            ))
            if UIDevice.current.userInterfaceIdiom == .pad {
                Section {
                    Picker(IDELanguageRunText.t("侧栏宽度", "Sidebar width"), selection: Binding(
                        get: { layoutPreferences.settings.sidebarWidth },
                        set: { layoutPreferences.setSidebarWidth($0) }
                    )) {
                        Text(IDELanguageRunText.t("紧凑", "Compact")).tag(280.0)
                        Text(IDELanguageRunText.t("标准", "Standard")).tag(320.0)
                        Text(IDELanguageRunText.t("宽", "Wide")).tag(400.0)
                    }
                    .accessibilityIdentifier("settings.general.sidebarWidth")
                }
            }
            Section("settings.general.language") {
                Picker("settings.general.language", selection: Binding(
                    get: { center.languageOverride },
                    set: { center.setLanguageOverride($0) }
                )) {
                    ForEach(LanguagePreference.allCases, id: \.self) { preference in
                        Text(title(for: preference)).tag(preference)
                    }
                }
                .frame(minHeight: FloeTheme.minimumTarget)
                Text("settings.general.language.restart_note")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            }

            Section {
                NavigationLink { SpeechInputSettingsView() } label: {
                    LabeledContent("voice.input.title", value: VoiceRecognitionPreferences.title(VoiceRecognitionPreferences.Method(rawValue: voiceMethod) ?? .automatic))
                }
                NavigationLink { TTSSettingsView() } label: {
                    LabeledContent("settings.voice.title", value: speechSettings.voiceDisplayName(for: speechSettings.snapshot) ?? SpeechVoiceNames.current(speechSettings.snapshot))
                }
            }

            Section("settings.general_settings_view.input_while_running") {
                Picker("settings.general_settings_view.default_send_method", selection: Binding(
                    get: { center.runningInputMode },
                    set: { value in Task { await center.setRunningInputMode(value) } }
                )) {
                    Text("chat.thread_composer_view.add_to_message_queue").tag(RunningInputMode.queue)
                    Text("chat.thread_composer_view.steer_the_current_run").tag(RunningInputMode.steer)
                }
                Text("settings.general_settings_view.the_queue_starts_a_new_turn")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(IDELanguageRunText.t("使用回收站", "Use Trash"), isOn: $trashEnabled)
                    .accessibilityIdentifier("settings.general.trashEnabled")
            } header: {
                Text(IDELanguageRunText.t("文件", "Files"))
            } footer: {
                Text(IDELanguageRunText.t("关闭后，在文件列表删除的内容将永久移除。回收站已有内容仍可恢复或清理。",
                    "When off, deleting from the file list removes items permanently. Existing items in Trash can still be restored or removed."))
            }

            Section {
                Picker(IDELanguageRunText.t("离开文档时", "When leaving a document"), selection: Binding(
                    get: { center.documentAssistantLeavePolicy },
                    set: { center.setDocumentAssistantLeavePolicy($0) }
                )) {
                    Text(IDELanguageRunText.t("每次询问", "Ask each time")).tag(DocumentAssistantLeavePolicy.ask)
                    Text(IDELanguageRunText.t("继续运行", "Continue running")).tag(DocumentAssistantLeavePolicy.continueInBackground)
                    Text(IDELanguageRunText.t("停止当前任务", "Stop current work")).tag(DocumentAssistantLeavePolicy.stopCurrentWork)
                }.accessibilityIdentifier("settings.general.documentAssistantLeave")
            } header: {
                Text(IDELanguageRunText.t("文档助手", "Document assistant"))
            } footer: {
                Text(IDELanguageRunText.t("仅在助手运行时生效。切换标签或收起助手时继续运行。",
                    "Applies while an assistant is running. Switching tabs or hiding the assistant keeps it running."))
            }

            Section("settings.general_settings_view.answer_quality") {
                Toggle("settings.general_settings_view.review_the_final_answer_before_completion", isOn: Binding(
                    get: { center.verifyFinalAnswer },
                    set: { value in Task { await center.setVerifyFinalAnswer(value) } }
                ))
            }

            Section("settings.questions.title") {
                Stepper(value: Binding(
                    get: { center.userQuestionDefaults.optionalTimeoutSeconds },
                    set: { center.setUserQuestionTimeoutSeconds($0) }
                ), in: UserQuestionRequest.minimumDeadlineSeconds...UserQuestionRequest.maximumDeadlineSeconds, step: 5) {
                    Text("settings.questions.timeout_seconds \(center.userQuestionDefaults.optionalTimeoutSeconds)")
                }
                .accessibilityIdentifier("settings.questions.timeout")
                Text("settings.questions.help").font(.caption).foregroundStyle(.secondary)
            }

            // Foldable adaptation is automatic on system-detected folding
            // hardware. The row appears ONLY when the live scene has
            // positively proven hinge capability — never on ordinary devices,
            // even if a stale preference from earlier hardware exists. An
            // explicit off is persisted and survives relaunch/update;
            // fold/unfold events never write this key.
            if foldableDisplay.capability == .foldable {
                Section {
                    Toggle("settings.general.foldable_adaptation", isOn: Binding(
                        get: { layoutPreferences.settings.foldableAdaptationEnabled },
                        set: { layoutPreferences.setFoldableAdaptationEnabled($0) }
                    ))
                    .accessibilityIdentifier(FoldableLayoutIdentifiers.settingsToggle)
                }
            }

            Section {
                Picker("settings.general.keyboard.return", selection: Binding(
                    get: { (ComposerHardwareReturnBehavior(rawValue: hardwareReturnBehavior) ?? .newline).rawValue },
                    set: { hardwareReturnBehavior = $0 }
                )) {
                    Text("settings.general.keyboard.return.newline").tag(ComposerHardwareReturnBehavior.newline.rawValue)
                    Text("settings.general.keyboard.return.send").tag(ComposerHardwareReturnBehavior.send.rawValue)
                }
                .accessibilityIdentifier("settings.general.hardwareReturn")
                .helpSettingsControlAnchor("settings.general.hardwareReturn")
            } header: {
                Text("settings.general.hardware_keyboard")
            } footer: {
                Text(LocalizedStringKey(hardwareReturnBehavior == ComposerHardwareReturnBehavior.send.rawValue
                    ? "settings.general.keyboard.send_help" : "settings.general.keyboard.newline_help"))
            }

            Section("settings.general.accessibility") {
                Picker("settings.general.reduce_motion", selection: Binding(
                    get: { center.reduceMotionOverride },
                    set: { center.setReduceMotionOverride($0) }
                )) {
                    Text("settings.general.reduce_motion.system").tag(Bool?.none)
                    Text("settings.general.reduce_motion.on").tag(Bool?.some(true))
                    Text("settings.general.reduce_motion.off").tag(Bool?.some(false))
                }
                .frame(minHeight: FloeTheme.minimumTarget)

                // Hidden: hapticsEnabled and dateTimeStyle are persisted but
                // nothing consumes them yet, so the controls are removed until
                // they take real effect.
            }

        }
        .navigationTitle(FloeL10n.l("settings.section.general"))
        .task { await center.load() }
    }

    // MARK: - Localized option titles

    private func title(for preference: AppearancePreference) -> LocalizedStringKey {
        switch preference {
        case .system: "settings.general.appearance.system"
        case .light: "settings.general.appearance.light"
        case .dark: "settings.general.appearance.dark"
        }
    }

    private func title(for preference: LanguagePreference) -> LocalizedStringKey {
        switch preference {
        case .system: "settings.general.language.system"
        case .en: "settings.general.language.en"
        case .zhHans: "settings.general.language.zh_hans"
        }
    }

    private func title(for style: DateTimeDisplayStyle) -> LocalizedStringKey {
        switch style {
        case .relative: "settings.general.datetime_style.relative"
        case .absolute: "settings.general.datetime_style.absolute"
        }
    }

}
#endif
