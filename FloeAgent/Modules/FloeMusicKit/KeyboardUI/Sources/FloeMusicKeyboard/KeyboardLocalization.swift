import Foundation

/// Package-local strings. The lookup uses `Bundle.module` so the strings stay
/// attached to this package if the host later collects it into the app. A
/// missing key degrades to the key itself.
func kbLocalized(_ key: String, locale: Locale) -> String {
    let host = Bundle.module
    let code = Bundle.preferredLocalizations(
        from: host.localizations, forPreferences: [locale.identifier]
    ).first
    if let code, let url = host.url(forResource: code, withExtension: "lproj"),
       let table = Bundle(url: url) {
        return table.localizedString(forKey: key, value: nil, table: nil)
    }
    return host.localizedString(forKey: key, value: nil, table: nil)
}
