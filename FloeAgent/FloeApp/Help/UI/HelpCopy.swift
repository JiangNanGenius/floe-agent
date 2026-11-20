// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

struct HelpCopy {
    let language: HelpLanguage
    static var current: Self { .init(language: HelpLanguage(preference: FloeL10n.currentLanguageCode)) }
    var title: String { FloeL10n.localized(key: "help.ui.title", languageCode: language.rawValue) }
    var search: String { FloeL10n.localized(key: "help.ui.search", languageCode: language.rawValue) }
    var searchResults: String { FloeL10n.localized(key: "help.ui.search_results", languageCode: language.rawValue) }
    var noResults: String { FloeL10n.localized(key: "help.ui.no_results", languageCode: language.rawValue) }
    var trySearch: String { FloeL10n.localized(key: "help.ui.try_search", languageCode: language.rawValue) }
    var offline: String { FloeL10n.localized(key: "help.ui.offline", languageCode: language.rawValue) }
    var unavailable: String { FloeL10n.localized(key: "help.ui.unavailable", languageCode: language.rawValue) }
    var unavailableDetail: String { FloeL10n.localized(key: "help.ui.unavailable_detail", languageCode: language.rawValue) }
    var retry: String { FloeL10n.localized(key: "help.ui.retry", languageCode: language.rawValue) }
    var close: String { FloeL10n.localized(key: "help.ui.close", languageCode: language.rawValue) }
    var done: String { FloeL10n.localized(key: "help.ui.done", languageCode: language.rawValue) }
    var contents: String { FloeL10n.localized(key: "help.ui.contents", languageCode: language.rawValue) }
    var find: String { FloeL10n.localized(key: "help.ui.find", languageCode: language.rawValue) }
    var reading: String { FloeL10n.localized(key: "help.ui.reading", languageCode: language.rawValue) }
    var appearance: String { FloeL10n.localized(key: "help.ui.appearance", languageCode: language.rawValue) }
    var system: String { FloeL10n.localized(key: "help.ui.system", languageCode: language.rawValue) }
    var light: String { FloeL10n.localized(key: "help.ui.light", languageCode: language.rawValue) }
    var dark: String { FloeL10n.localized(key: "help.ui.dark", languageCode: language.rawValue) }
    var textSize: String { FloeL10n.localized(key: "help.ui.text_size", languageCode: language.rawValue) }
    var copy: String { FloeL10n.localized(key: "help.ui.copy", languageCode: language.rawValue) }
    var copied: String { FloeL10n.localized(key: "help.ui.copied", languageCode: language.rawValue) }
    var info: String { FloeL10n.localized(key: "help.ui.info", languageCode: language.rawValue) }
    var version: String { FloeL10n.localized(key: "help.ui.version", languageCode: language.rawValue) }
    var source: String { FloeL10n.localized(key: "help.ui.source", languageCode: language.rawValue) }
    var languageLabel: String { FloeL10n.localized(key: "help.ui.language_label", languageCode: language.rawValue) }
    var openSetting: String { FloeL10n.localized(key: "help.ui.open_setting", languageCode: language.rawValue) }
    var enlargeImage: String { FloeL10n.localized(key: "help.ui.enlarge_image", languageCode: language.rawValue) }
    var relatedHelp: String { FloeL10n.localized(key: "help.ui.related_help", languageCode: language.rawValue) }
    var readGuide: String { FloeL10n.localized(key: "help.ui.read_guide", languageCode: language.rawValue) }
    var readFullChapter: String { FloeL10n.localized(key: "help.ui.read_full_chapter", languageCode: language.rawValue) }
}
