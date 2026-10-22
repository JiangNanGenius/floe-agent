// SPDX-License-Identifier: MPL-2.0
// FloeApp — Shared Documents user copy (S5 C4).
//
// Concise bilingual strings for the local Files provider location. iPad
// first; no implementation jargon in user-facing text.

import Foundation

enum SharedDocumentsCopy {
    /// Files app location name and root container filename.
    static var locationName: String {
        isChinese ? "Floe 共享文档" : "Floe Shared Documents"
    }

    /// Settings/home card subtitle.
    static var cardSubtitle: String {
        isChinese
            ? "在“文件”中查看和整理导出的文稿"
            : "Browse and organize exported documents in Files"
    }

    // MARK: - Registration states (truthful; success is not a mount claim)

    static var registeredSubtitle: String {
        isChinese
            ? "在“文件”的“浏览”页面启用 Floe 共享文档。"
            : "Enable Floe Shared Documents on the Browse page in Files."
    }

    static var appGroupMissingMessage: String {
        isChinese
            ? "共享文档暂不可用，请稍后重试。"
            : "Shared Documents is unavailable. Try again later."
    }

    static func storeOpenFailedMessage(_ detail: String) -> String {
        isChinese
            ? "无法打开共享文档，请重试。"
            : "Couldn't open Shared Documents. Try again."
    }

    static func exportFailedMessage(_ detail: String) -> String {
        isChinese
            ? "未能导出到共享文档，请重试。"
            : "Couldn’t export to Shared Documents. Try again."
    }

    static var exportedConfirmation: String {
        isChinese ? "已导出到共享文档" : "Exported to Shared Documents"
    }

    static var registrationFailedMessage: String {
        isChinese ? "暂时无法启用，请重试。" : "Couldn't enable this location. Try again."
    }

    static var refreshAction: String {
        isChinese ? "重试" : "Try Again"
    }

    // MARK: - Locale

    private static var isChinese: Bool {
        Locale.current.language.languageCode?.identifier.hasPrefix("zh") == true
    }
}
