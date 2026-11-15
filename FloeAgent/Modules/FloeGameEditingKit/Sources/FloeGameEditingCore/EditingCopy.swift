// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Bilingual user-facing copy. Editors read the host locale from the
/// environment and never hard-code one language.
public struct GameEditCopy: Hashable, Sendable, Codable {
    public let en: String
    public let zh: String
    public init(_ en: String, _ zh: String) { self.en = en; self.zh = zh }
    public func text(_ locale: GameEditLocale) -> String {
        switch locale {
        case .english: return en
        case .chinese: return zh
        }
    }
}

public enum GameEditLocale: String, CaseIterable, Sendable {
    case english = "en"
    case chinese = "zh"

    public static var host: GameEditLocale {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("zh") ? .chinese : .english
    }
}
