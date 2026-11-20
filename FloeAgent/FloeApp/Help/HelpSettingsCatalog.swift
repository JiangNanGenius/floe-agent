// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

/// Native navigation authority. Downloaded help may name an id, never invent a route.
struct HelpSettingsTarget: Hashable, Sendable, Identifiable, Encodable {
    let id: String
    let category: String
    let nestedPage: String?
    let controlID: String?
    let title: String
    let path: [String]

    fileprivate init(id: String, category: String, nestedPage: String? = nil,
                     controlID: String? = nil, title: String, path: [String]) {
        self.id = id; self.category = category; self.nestedPage = nestedPage
        self.controlID = controlID; self.title = title; self.path = path
    }
}

enum HelpSettingsCatalog {
    static func target(id: String, language: HelpLanguage) -> HelpSettingsTarget? {
        func text(_ key: String) -> String {
            FloeL10n.localized(key: "help.settings." + key, languageCode: language.rawValue)
        }
        let settings = text("settings")
        let general = text("general")
        switch id {
        case "general.hardwareReturn":
            let title = text("return_key")
            return HelpSettingsTarget(id: id, category: "general",
                controlID: "settings.general.hardwareReturn", title: title,
                path: [settings, general, text("hardware_keyboard"), title])
        case "general.voiceOutput":
            let title = text("voice_output")
            return HelpSettingsTarget(id: id, category: "general", nestedPage: "voiceOutput",
                title: title, path: [settings, general, title])
        case "execution.memory":
            let title = text("memory")
            return HelpSettingsTarget(id: id, category: "execution",
                controlID: "execution.shared.memory", title: title,
                path: [settings, text("execution_environment"),
                       text("shared_runtime"), title])
        default:
            return nil
        }
    }

    /// Public, static availability only. Never reads the user's environment or values.
    static func availabilityNote(id: String, language: HelpLanguage) -> String? {
        guard id == "execution.memory" else { return nil }
        return FloeL10n.localized(key: "help.settings.memory_availability", languageCode: language.rawValue)
    }
}
