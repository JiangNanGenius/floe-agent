import Foundation

/// Package-local strings. The lookup uses `Bundle.module` so the strings stay
/// attached to this package if the host later collects it into the app. A
/// missing key degrades to the key itself.
func kbLocalized(_ key: String) -> String {
    Bundle.module.localizedString(forKey: key, value: nil, table: nil)
}
