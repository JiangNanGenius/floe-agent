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
        let chinese = language == .simplifiedChinese
        let settings = chinese ? "设置" : "Settings"
        let general = chinese ? "通用" : "General"
        switch id {
        case "general.hardwareReturn":
            let title = chinese ? "回车键" : "Return Key"
            return HelpSettingsTarget(id: id, category: "general",
                controlID: "settings.general.hardwareReturn", title: title,
                path: [settings, general, chinese ? "实体键盘" : "Hardware Keyboard", title])
        case "general.voiceOutput":
            let title = chinese ? "语音输出" : "Voice Output"
            return HelpSettingsTarget(id: id, category: "general", nestedPage: "voiceOutput",
                title: title, path: [settings, general, title])
        case "execution.memory":
            let title = chinese ? "内存" : "Memory"
            return HelpSettingsTarget(id: id, category: "execution",
                controlID: "execution.shared.memory", title: title,
                path: [settings, chinese ? "执行环境" : "Execution Environment",
                       chinese ? "共享运行环境" : "Shared runtime", title])
        default:
            return nil
        }
    }

    /// Public, static availability only. Never reads the user's environment or values.
    static func availabilityNote(id: String, language: HelpLanguage) -> String? {
        guard id == "execution.memory" else { return nil }
        return language == .simplifiedChinese
            ? "共享运行环境准备好后才显示内存选项；调低内存会等待当前项目关闭。"
            : "Memory options appear after the shared runtime is ready. Lower limits wait for current projects to close."
    }
}
