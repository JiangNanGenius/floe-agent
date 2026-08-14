// FloeApp — General settings section.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_SETTINGS.md §5 row 1: appearance, language, default
// start page, reduce-motion override, haptics, date-time display style and
// the default agent mode. Every control reads from and writes to
// SettingsCenter (UserDefaults or DB app_settings); no placeholder text.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

struct GeneralSettingsView: View {
    @ObservedObject var center: SettingsCenter

    var body: some View {
        Form {
            Section("settings.general.appearance") {
                Picker("settings.general.appearance", selection: Binding(
                    get: { center.appearance },
                    set: { center.setAppearance($0) }
                )) {
                    ForEach(AppearancePreference.allCases, id: \.self) { preference in
                        Text(title(for: preference)).tag(preference)
                    }
                }
                .frame(minHeight: FloeTheme.minimumTarget)

                Picker("settings.general.language", selection: Binding(
                    get: { center.languageOverride },
                    set: { center.setLanguageOverride($0) }
                )) {
                    ForEach(LanguagePreference.allCases, id: \.self) { preference in
                        Text(title(for: preference)).tag(preference)
                    }
                }
                .frame(minHeight: FloeTheme.minimumTarget)

                Picker("settings.general.start_page", selection: Binding(
                    get: { center.defaultStartPage },
                    set: { Task { await center.setDefaultStartPage($0) } }
                )) {
                    ForEach(StartPage.allCases, id: \.self) { page in
                        Text(title(for: page)).tag(page)
                    }
                }
                .frame(minHeight: FloeTheme.minimumTarget)
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

                Toggle("settings.general.haptics", isOn: Binding(
                    get: { center.hapticsEnabled },
                    set: { center.setHapticsEnabled($0) }
                ))
                .frame(minHeight: FloeTheme.minimumTarget)

                Picker("settings.general.datetime_style", selection: Binding(
                    get: { center.dateTimeStyle },
                    set: { center.setDateTimeStyle($0) }
                )) {
                    ForEach(DateTimeDisplayStyle.allCases, id: \.self) { style in
                        Text(title(for: style)).tag(style)
                    }
                }
                .frame(minHeight: FloeTheme.minimumTarget)
            }

            Section {
                Picker("settings.general.agent_mode", selection: Binding(
                    get: { center.defaultAgentMode },
                    set: { Task { await center.setDefaultAgentMode($0) } }
                )) {
                    ForEach(AgentMode.allCases, id: \.self) { mode in
                        Text(title(for: mode)).tag(mode)
                    }
                }
                .frame(minHeight: FloeTheme.minimumTarget)
            } header: {
                Text("settings.general.agent")
            } footer: {
                Text("settings.general.agent_mode.footer")
            }
        }
        .navigationTitle("settings.section.general")
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

    private func title(for page: StartPage) -> LocalizedStringKey {
        switch page {
        case .home: "tab.home"
        case .chat: "tab.chat"
        case .files: "tab.files"
        case .remote: "tab.hosts"
        case .more: "tab.more"
        }
    }

    private func title(for style: DateTimeDisplayStyle) -> LocalizedStringKey {
        switch style {
        case .relative: "settings.general.datetime_style.relative"
        case .absolute: "settings.general.datetime_style.absolute"
        }
    }

    private func title(for mode: AgentMode) -> LocalizedStringKey {
        switch mode {
        case .human: "settings.general.agent_mode.human"
        case .approvalModel: "settings.general.agent_mode.approval_model"
        case .fullControl: "settings.general.agent_mode.full_control"
        }
    }
}
#endif
