// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Source copy that also survives persisted editing history. Editors resolve
/// the other language editions from the package using the host locale.
public struct GameEditCopy: Hashable, Sendable, Codable {
    public let en: String
    public let zh: String
    public init(_ en: String, _ zh: String) { self.en = en; self.zh = zh }
    public func text(_ locale: GameEditLocale) -> String {
        switch locale {
        case .english: return en
        case .chinese: return zh
        default:
            guard let url = Bundle.module.url(forResource: locale.rawValue, withExtension: "lproj"),
                  let bundle = Bundle(url: url) else { return en }
            return bundle.localizedString(forKey: en, value: en, table: nil)
        }
    }
}

public enum GameEditLocale: String, CaseIterable, Sendable {
    case english = "en"
    case chinese = "zh"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case brazilianPortuguese = "pt-BR"

    public init(languageCode: String) {
        self = languageCode == "zh-Hans" ? .chinese : Self(rawValue: languageCode) ?? .english
    }

    public static var host: GameEditLocale {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("zh") ? .chinese : .english
    }
}
