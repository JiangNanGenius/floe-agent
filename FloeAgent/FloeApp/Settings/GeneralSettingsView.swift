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

struct GeneralSettingsView: View {
    @ObservedObject var center: SettingsCenter
    /// Optional content-update center. Present when the settings center hosts
    /// this view; other call sites remain valid without it.
    var contentUpdates: ContentUpdateCenter?
    @AppStorage(VoiceRecognitionLanguage.defaultsKey)
    private var voiceLanguage = VoiceRecognitionLanguage.automatic.rawValue

    init(center: SettingsCenter, contentUpdates: ContentUpdateCenter? = nil) {
        self.center = center
        self.contentUpdates = contentUpdates
    }

    var body: some View {
        Form {
            AppearanceSettingsSection(selection: Binding(
                get: { center.appearance },
                set: { center.setAppearance($0) }
            ))
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

            Section("settings.general_settings_view.voice_input") {
                NavigationLink("settings.general_settings_view.whisper_speech_recognition") { WhisperSettingsView() }
                Picker("settings.general_settings_view.recognition_language", selection: $voiceLanguage) {
                    Text("settings.general_settings_view.automatic").tag(VoiceRecognitionLanguage.automatic.rawValue)
                    Text("settings.general.language.zh_hans").tag(VoiceRecognitionLanguage.simplifiedChinese.rawValue)
                    Text("settings.general_settings_view.text").tag(VoiceRecognitionLanguage.traditionalChinese.rawValue)
                    Text("English").tag(VoiceRecognitionLanguage.english.rawValue)
                }
                Text("settings.general_settings_view.when_automatic_recognition_has_no_result")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("settings.general_settings_view.answer_quality") {
                Toggle("settings.general_settings_view.review_the_final_answer_before_completion", isOn: Binding(
                    get: { center.verifyFinalAnswer },
                    set: { value in Task { await center.setVerifyFinalAnswer(value) } }
                ))
                Text("settings.general_settings_view.when_on_an_extra_self_check")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let contentUpdates {
                Section("settings.content_updates.section") {
                    NavigationLink {
                        ContentUpdatesSettingsView(center: contentUpdates)
                    } label: {
                        Label("settings.content_updates.row", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .frame(minHeight: FloeTheme.minimumTarget)
                    .accessibilityIdentifier("settings.general.content_updates")
                    Text("settings.content_updates.footer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
