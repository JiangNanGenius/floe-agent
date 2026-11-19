// FloeMacTerminal — bilingual user-facing copy.
//
// SPDX-License-Identifier: MPL-2.0

import Foundation

enum MacTerminalCopy {
    static func t(_ zh: String, _ en: String, _ locale: Locale = .current) -> String {
        locale.language.languageCode?.identifier == "zh" ? zh : en
    }
}

extension String {
    var macTerminalLocalized: String {
        MacTerminalCopy.t(self, self)
    }
}
