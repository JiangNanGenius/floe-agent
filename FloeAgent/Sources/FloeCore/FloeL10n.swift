// FloeCore — runtime language resolution.
//
// SwiftUI's `\.locale` environment only drives `LocalizedStringKey`
// resolution *inside* SwiftUI views. Plain `String(localized:)`, UIKit alerts,
// user notifications, Foundation formatters and code in Swift package modules
// read the process preferred language instead, so an in-app English choice on
// a Chinese system left those surfaces untranslated. `FloeL10n` is the single
// source of truth used everywhere:
//
//   * `bootstrap()` runs once at process launch (app and extensions), before
//     any catalog lookup, and applies the saved preference.
//   * A Bundle proxy routes the main bundle's `Localizable` table lookups to
//     the chosen lproj, so `String(localized:)` and SwiftUI keyed labels
//     reflect an in-session change without an app relaunch.
//   * `localized(key:arguments:)` resolves keys explicitly against the active
//     .lproj table for package modules and UIKit code.
//   * `isChinese` / `swiftUILocale` drive inline bilingual helpers and views.
//
// User data, AI output, log messages and protocol identifiers never pass
// through this layer.

import Foundation
#if canImport(ObjectiveC)
import ObjectiveC
#endif

public enum FloeL10n {
    /// UserDefaults key shared with `SettingsCenter` ("floe.settings.language").
    public static let defaultsKey = "floe.settings.language"

    /// App Group used to mirror the preference into app extensions.
    public static let appGroupIdentifier = "group.org.floeagent.ios"

    /// Product languages; the catalog is compiled for exactly these.
    public static let supportedLanguageCodes = LanguagePreference.allCases.compactMap(\.localizationCode)

    /// Preference raw values (`LanguagePreference.rawValue`).
    public static let preferenceSystem = "system"
    public static let preferenceEn = "en"
    public static let preferenceZhHans = "zhHans"

    /// Locked, Sendable holder for all mutable language state.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        /// Selected catalog language; nil until `bootstrap()` or `setPreference()`.
        /// Unbootstrapped processes (e.g. unit-test hosts) follow the system.
        var languageCode: String?
        /// True when language follows the OS.
        var followingSystem: Bool = true
        /// lproj bundles keyed by language code.
        var bundles: [String: Bundle] = [:]

        func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    private static let state = State()

    /// Test-only extra bundles scanned for the compiled .strings tables.
    nonisolated(unsafe) public static var additionalResourceBundles: [Bundle] = []

    /// Test seam: forces the OS preferred-language list without touching
    /// global user defaults. `nil` (default) reads the real global domain.
    nonisolated(unsafe) public static var testSystemLanguagesOverride: [String]?

    // MARK: - Launch / preference changes

    /// Applies the persisted preference at process launch. Safe to call more
    /// than once and from extensions. Returns the resolved language code.
    @discardableResult
    public static func bootstrap(
        standardDefaults: UserDefaults = .standard,
        suiteDefaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier),
        arguments: [String] = ProcessInfo.processInfo.arguments,
        isExtension: Bool = false
    ) -> String {
        installBundleProxyIfNeeded()
        let forced = launchArgumentLanguageCode(arguments: arguments)
        let localPreference = standardDefaults.string(forKey: defaultsKey)
        let sharedPreference = suiteDefaults?.string(forKey: defaultsKey)
        let stored = isExtension && suiteDefaults != nil
            ? sharedPreference
            : localPreference ?? sharedPreference
        if forced == nil && !isExtension {
            // Mirror a standard-defaults value (set before the app group link
            // existed, or in unit-test hosts) so extensions stay consistent.
            if let localPreference {
                suiteDefaults?.set(localPreference, forKey: defaultsKey)
            } else if let sharedPreference {
                standardDefaults.set(sharedPreference, forKey: defaultsKey)
            }
        }
        let followingSystem = forced == nil && (stored == nil || stored == preferenceSystem)
        if followingSystem {
            // Clear this app's own AppleLanguages override *before* resolving
            // the OS language: the public `Locale.preferredLanguages` path
            // falls back to the OS list only while the app domain has no
            // override (see `systemPreferredLanguages`).
            standardDefaults.removeObject(forKey: "AppleLanguages")
        }
        let code = forced
            ?? (followingSystem ? systemLanguageCode(standardDefaults: standardDefaults)
                                : overrideLanguageCode(preferenceRaw: stored,
                                                       standardDefaults: standardDefaults))
        apply(
            resolvedCode: code,
            followingSystem: followingSystem,
            standardDefaults: standardDefaults,
            arguments: arguments
        )
        return code
    }

    /// Applies a preference chosen in Settings.
    @discardableResult
    public static func setPreference(
        rawValue: String?,
        standardDefaults: UserDefaults = .standard,
        suiteDefaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier),
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> String {
        if let rawValue {
            suiteDefaults?.set(rawValue, forKey: defaultsKey)
        } else {
            suiteDefaults?.removeObject(forKey: defaultsKey)
        }
        let followingSystem = rawValue == nil || rawValue == preferenceSystem
        // Resolve against the actual OS language BEFORE mutating the stored
        // preference. The app-level AppleLanguages override is removed first
        // so the public Locale path cannot inherit the value we forced in an
        // earlier session; a launch argument (UI tests) always wins and its
        // future process is never touched here.
        if followingSystem, launchArgumentLanguageCode(arguments: arguments) == nil {
            standardDefaults.removeObject(forKey: "AppleLanguages")
        }
        let code: String
        if let forced = launchArgumentLanguageCode(arguments: arguments) {
            code = forced
        } else if followingSystem {
            code = systemLanguageCode(standardDefaults: standardDefaults)
        } else {
            code = overrideLanguageCode(preferenceRaw: rawValue,
                                        standardDefaults: standardDefaults)
        }
        apply(
            resolvedCode: code,
            followingSystem: followingSystem,
            standardDefaults: standardDefaults,
            arguments: arguments
        )
        return code
    }

    /// Resolve a persisted preference, falling back to the system list.
    private static func overrideLanguageCode(
        preferenceRaw: String?,
        standardDefaults: UserDefaults = .standard
    ) -> String {
        resolveLanguageCode(
            preferenceRaw: preferenceRaw,
            forcedLanguageCode: nil,
            systemPreferredLanguages: systemPreferredLanguages(standardDefaults: standardDefaults)
        )
    }

    private static func apply(
        resolvedCode: String,
        followingSystem: Bool,
        standardDefaults: UserDefaults,
        arguments: [String]
    ) {
        state.withLock {
            state.languageCode = resolvedCode
            state.followingSystem = followingSystem
            state.bundles.removeAll(keepingCapacity: true)
        }

        // Keep the process preferred language consistent for Foundation
        // formatters and system frameworks on the NEXT launch. The Bundle
        // proxy handles in-session behavior; a launch argument (UI tests)
        // always wins and is never overwritten here.
        if launchArgumentLanguageCode(arguments: arguments) == nil {
            if followingSystem {
                standardDefaults.removeObject(forKey: "AppleLanguages")
            } else {
                standardDefaults.set([resolvedCode], forKey: "AppleLanguages")
            }
        }

        // Register the process main bundle for table interception.
        BundleProxy.register(Bundle.main)

        NotificationCenter.default.post(name: .floeLanguageDidChange, object: resolvedCode)
    }

    // MARK: - Resolution (pure, unit-testable)

    /// - Parameters:
    ///   - preferenceRaw: stored LanguagePreference value (nil = unset).
    ///   - forcedLanguageCode: language forced by launch arguments.
    ///   - systemPreferredLanguages: the *OS* preferred-language list.
    public static func resolveLanguageCode(
        preferenceRaw: String?,
        forcedLanguageCode: String?,
        systemPreferredLanguages: [String]
    ) -> String {
        if let forcedLanguageCode, let supported = matchingLanguageCode(forcedLanguageCode) {
            return supported
        }
        if let preferenceRaw,
           let code = LanguagePreference(rawValue: preferenceRaw)?.localizationCode {
            return code
        }
        return systemPreferredLanguages.lazy.compactMap(matchingLanguageCode).first ?? "en"
    }

    /// Matches Apple language tags, including regional and script-qualified preferences.
    public static func matchingLanguageCode(_ identifier: String) -> String? {
        let language = Locale.Language.Components(identifier: identifier)
        guard let code = language.languageCode?.identifier else { return nil }
        if code == "zh" {
            if let script = language.script?.identifier {
                return script == "Hant" ? "zh-Hant" : "zh-Hans"
            }
            let traditionalRegions = ["TW", "HK", "MO"]
            return traditionalRegions.contains(language.region?.identifier ?? "")
                ? "zh-Hant" : "zh-Hans"
        }
        if code == "pt" { return "pt-BR" }
        return supportedLanguageCodes.contains(code) ? code : nil
    }

    /// Parses `-AppleLanguages (en)` or `(ja-JP, en)` launch arguments.
    static func launchArgumentLanguageCode(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "-AppleLanguages"),
              index + 1 < arguments.count else { return nil }
        let delimiters = CharacterSet(charactersIn: "()\"'").union(.whitespacesAndNewlines)
        return arguments[index + 1].split(separator: ",").lazy
            .map { $0.trimmingCharacters(in: delimiters) }
            .compactMap(matchingLanguageCode).first
    }

    /// Reads the *OS* preferred languages independently of this app's
    /// `AppleLanguages` override. This is the public `Locale` path: Foundation
    /// resolves the app-domain override when one is present and falls back to
    /// the OS-wide list when it is not. Every caller that resolves a
    /// system-following choice clears the app-domain override first
    /// (`bootstrap`, `setPreference`), so a previously forced language can
    /// never leak into the OS value.
    ///
    /// `UserDefaults.globalDomain` is deliberately not read: no approved
    /// `NSPrivacyAccessedAPICategoryUserDefaults` reason covers system-written
    /// defaults (`CA92.1`/`1C8F.1` explicitly exclude "information that was
    /// written by other apps or the system"), and `Locale.preferredLanguages`
    /// is the documented public API for exactly this value.
    public static func systemPreferredLanguages(
        standardDefaults: UserDefaults = .standard
    ) -> [String] {
        if let testSystemLanguagesOverride { return testSystemLanguagesOverride }
        return Locale.preferredLanguages
    }

    /// Product language code derived purely from the OS preferences.
    public static func systemLanguageCode(
        standardDefaults: UserDefaults = .standard
    ) -> String {
        resolveLanguageCode(
            preferenceRaw: nil,
            forcedLanguageCode: nil,
            systemPreferredLanguages: systemPreferredLanguages(standardDefaults: standardDefaults)
        )
    }

    // MARK: - Current language

    public static var currentLanguageCode: String {
        if let resolved = state.withLock({ state.languageCode }) { return resolved }
        return systemLanguageCode()
    }

    /// True when the active product language is Simplified Chinese.
    public static var isChinese: Bool { currentLanguageCode == "zh-Hans" }

    /// Locale for SwiftUI's `\.locale` environment. Always a concrete
    /// locale: in system mode the OS language/region (so date and number
    /// formatting keep the user's region), otherwise the explicit override.
    /// Never `.autoupdatingCurrent`, whose process-cached preference list
    /// would ignore an in-session switch (English -> Follow System).
    public static var swiftUILocale: Locale {
        if state.withLock({ state.followingSystem }) {
            return Locale(identifier: systemLocaleIdentifier())
        }
        return Locale(identifier: currentLanguageCode)
    }

    /// OS language/region identifier resolved through the public `Locale`
    /// APIs, independent of the app-level AppleLanguages override (which the
    /// system-following callers clear first). The *language* comes from the
    /// OS preferred-language list; the *region* comes from the process
    /// locale's region, because the two are independent choices — English
    /// (US) language with an Australian region must keep formatting at
    /// `en_AU`. `Locale.current` itself is not returned: it is process-cached
    /// and can keep a previously forced language, but its region does not
    /// change with the app's language override (verified with the app-domain
    /// probe recorded in the privacy deliverable).
    public static func systemLocaleIdentifier(
        standardDefaults: UserDefaults = .standard
    ) -> String {
        systemLocaleIdentifier(
            preferredLanguages: systemPreferredLanguages(standardDefaults: standardDefaults),
            region: Locale.current.region?.identifier
        )
    }

    /// Pure composition of the OS language and the OS region (unit-testable).
    /// A missing region keeps the language tag's own region.
    static func systemLocaleIdentifier(
        preferredLanguages: [String],
        region: String?
    ) -> String {
        guard !preferredLanguages.isEmpty else { return currentLanguageCode }
        let preferred = preferredLanguages.first { matchingLanguageCode($0) != nil } ?? "en"
        var components = Locale.Components(identifier: preferred)
        // Keep the selected catalog's Chinese script visible to SwiftUI
        // even when a device reports only a regional Chinese tag.
        if let supported = matchingLanguageCode(preferred), supported.hasPrefix("zh-") {
            components.languageComponents.script = Locale.Language.Components(identifier: supported).script
        }
        if let region, !region.isEmpty {
            components.languageComponents.region = Locale.Region(region)
        }
        return Locale(components: components).identifier
    }

    /// True when language follows the OS. Internal accessor for the Bundle
    /// proxy (which lives in a file-level extension in the same module).
    static var isFollowingSystem: Bool {
        state.withLock { state.followingSystem }
    }

    // MARK: - Keyed lookup

    /// Resolves a dotted catalog key against the active language table.
    /// Falls back to English, then to the key itself, never to a raw Chinese
    /// source literal. Arguments substitute `%@` placeholders (and positional
    /// `%n$@` forms) using `String(describing:)`, matching Swift string
    /// interpolation behavior and remaining type-safe for any value.
    public static func localized(key: String, arguments: [Any] = []) -> String {
        guard let format = resolvedFormat(forKey: key) else { return key }
        guard !arguments.isEmpty else { return format }
        return substituting(format: format, arguments: arguments)
    }

    /// Variadic convenience used by migrated call sites.
    public static func l(_ key: String, _ arguments: Any...) -> String {
        localized(key: key, arguments: arguments)
    }

    /// Looks up a literal pair from an inline bilingual UI helper. The two
    /// original strings remain the fallback when a pair is assembled at runtime.
    public static func bilingual(chinese: String, english: String) -> String {
        let code = currentLanguageCode
        if code == "zh-Hans" { return chinese }
        guard code != "en", chinese != english else { return english }
        var key: UInt64 = 0xcbf29ce484222325
        for byte in (english + "\0" + chinese).utf8 {
            key = (key ^ UInt64(byte)) &* 0x100000001b3
        }
        return localizedFormat(forKey: "app.bilingual." + String(key, radix: 16), code: code) ?? english
    }

    /// Selects the singular sibling for catalogs using one/other forms.
    /// CJK languages use the base entry. Missing singular variants use the base.
    public static func plural(_ key: String, count: Int, _ extra: Any...) -> String {
        var resolvedKey = key
        if usesSingular(count: count, code: currentLanguageCode),
           let singular = localizedFormat(forKey: key + ".one", code: currentLanguageCode),
           count != 0 || singular.contains("%") {
            resolvedKey = key + ".one"
        }
        return localized(key: resolvedKey, arguments: [count] + extra)
    }

    static func usesSingular(count: Int, code: String) -> Bool {
        switch code {
        case "fr", "pt-BR": count == 0 || count == 1
        case "en", "de", "es": count == 1
        default: false
        }
    }

    /// Replaces placeholders with the string representation of each argument.
    /// `%@` uses `String(describing:)`, matching Swift interpolation.
    /// Numeric/`c`/`s` conversions are formatted with `String(format:)` when
    /// the value is representable as a C var-arg (legacy catalog formats).
    /// `%%` is a literal percent. Missing arguments keep the placeholder.
    static func substituting(format: String, arguments: [Any]) -> String {
        var result = ""
        var nextIndex = 0
        let scalars = Array(format)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            guard c == "%" else { result.append(c); i += 1; continue }
            guard i + 1 < scalars.count else { result.append(c); break }
            if scalars[i + 1] == "%" {
                result.append("%"); i += 2; continue
            }
            // Optional positional index `n$`.
            var j = i + 1
            var digits = ""
            while j < scalars.count, scalars[j].isNumber {
                digits.append(scalars[j]); j += 1
            }
            var positional: Int? = nil
            var specifierBodyStart = i + 1
            if !digits.isEmpty, j < scalars.count, scalars[j] == "$" {
                positional = Int(digits)
                j += 1
                specifierBodyStart = j
            }
            // Flags, width, precision.
            while j < scalars.count, "-+ #0.,".contains(scalars[j]) || scalars[j].isNumber {
                j += 1
            }
            // Length modifiers.
            while j < scalars.count, "hlLzjt".contains(scalars[j]) {
                j += 1
            }
            guard j < scalars.count else { result.append(c); break }
            let conversion = scalars[j]
            let isStringConversion = (conversion == "@" || conversion == "s")
            let isNumericConversion = "diouxXeEfgGaAcp".contains(conversion)
            guard isStringConversion || isNumericConversion else {
                // Unknown conversion: emit literally.
                result.append(c); i += 1; continue
            }
            let argIndex: Int
            if let positional {
                argIndex = positional - 1
            } else {
                argIndex = nextIndex
                nextIndex += 1
            }
            if argIndex >= 0, argIndex < arguments.count {
                if conversion == "@" {
                    result.append(String(describing: arguments[argIndex]))
                } else if let cvarArg = cVarArgValue(arguments[argIndex]) {
                    // `String(format:)` with the single selected argument must
                    // not carry the `n$` positional prefix (it would read the
                    // nth C var-arg and return garbage); keep only flags,
                    // width, precision and length modifiers.
                    let bareSpecifier = "%" + String(scalars[specifierBodyStart...j])
                    result.append(String(format: bareSpecifier, cvarArg))
                } else {
                    result.append(String(describing: arguments[argIndex]))
                }
            } else {
                // Missing argument: keep the original specifier text.
                result.append(String(scalars[i...j]))
            }
            i = j + 1
        }
        return result
    }

    /// Maps a Swift value to a C var-arg for `String(format:)` when possible.
    private static func cVarArgValue(_ value: Any) -> CVarArg? {
        switch value {
        case let v as Int: return v
        case let v as Int8: return Int(v)
        case let v as Int16: return Int(v)
        case let v as Int32: return Int(v)
        case let v as Int64: return v
        case let v as UInt: return v
        case let v as UInt32: return v
        case let v as UInt64: return v
        case let v as Double: return v
        case let v as Float: return v
        default: return nil
        }
    }

    static func resolvedFormat(forKey key: String) -> String? {
        localizedFormat(forKey: key, code: currentLanguageCode)
            ?? localizedFormat(forKey: key, code: "en")
    }

    public static func localized(
        key: String, languageCode: String, arguments: [Any] = []
    ) -> String {
        let format = localizedFormat(forKey: key, code: languageCode)
            ?? localizedFormat(forKey: key, code: "en") ?? key
        return arguments.isEmpty ? format : substituting(format: format, arguments: arguments)
    }

    private static func localizedFormat(forKey key: String, code: String) -> String? {
        guard let value = lookup(key: key, code: code), value != key, !value.isEmpty else {
            return nil
        }
        return value
    }

    static func lookup(key: String, code: String) -> String? {
        if let bundle = state.withLock({ state.bundles[code] }) {
            return bundle.localizedString(forKey: key, value: key, table: "Localizable")
        }
        if let bundle = loadTableBundle(code: code) {
            state.withLock { state.bundles[code] = bundle }
            return bundle.localizedString(forKey: key, value: key, table: "Localizable")
        }
        #if DEBUG
        if let table = sourceCatalogTable(code: code) {
            return table[key] ?? key
        }
        #endif
        return nil
    }

    #if DEBUG
    /// Test-host fallback: parse the canonical catalog JSON relative to this
    /// source file. Never used in production releases (compiled .strings are
    /// present in the app bundle).
    nonisolated(unsafe) private static var sourceTableCache: [String: [String: String]] = [:]

    private static func sourceCatalogTable(code: String) -> [String: String]? {
        if let cached = state.withLock({ sourceTableCache[code] }) { return cached }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FloeCore
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // FloeAgent root
            .appendingPathComponent("FloeApp/Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = object["strings"] as? [String: Any] else { return nil }
        var table: [String: String] = [:]
        for (key, value) in strings {
            guard let entry = value as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let locale = localizations[code] as? [String: Any],
                  let unit = locale["stringUnit"] as? [String: Any],
                  let resolved = unit["value"] as? String else { continue }
            table[key] = resolved
        }
        state.withLock { sourceTableCache[code] = table }
        return table
    }
    #endif

    private static func loadTableBundle(code: String) -> Bundle? {
        var candidates: [Bundle] = [Bundle.main] + Bundle.allBundles + additionalResourceBundles
        #if canImport(Darwin)
        candidates.append(contentsOf: Bundle.allFrameworks)
        #endif
        for host in candidates {
            if let url = host.url(forResource: code, withExtension: "lproj"),
               let tableBundle = Bundle(url: url),
               tableBundle.url(forResource: "Localizable", withExtension: "strings") != nil {
                return tableBundle
            }
        }
        return nil
    }

    // MARK: - Bundle proxy

    #if canImport(ObjectiveC)
    fileprivate enum BundleProxy {
        /// Registered host bundles whose lookups are redirected (main bundle).
        nonisolated(unsafe) static var registeredTargets = NSHashTable<Bundle>.weakObjects()
        nonisolated(unsafe) static var lprojCache: [ObjectIdentifier: [String: Bundle]] = [:]
        static let proxyLock = NSLock()

        static func register(_ bundle: Bundle) {
            proxyLock.lock()
            defer { proxyLock.unlock() }
            let already = registeredTargets.allObjects.contains { $0 == bundle }
            if !already {
                registeredTargets.add(bundle)
            }
        }

        static func isRegistered(_ bundle: Bundle) -> Bool {
            proxyLock.lock(); defer { proxyLock.unlock() }
            return registeredTargets.allObjects.contains { $0 == bundle }
        }

        static func languageBundle(for host: Bundle, code: String) -> Bundle? {
            let id = ObjectIdentifier(host)
            proxyLock.lock()
            if let cached = lprojCache[id]?[code] {
                proxyLock.unlock()
                return cached
            }
            proxyLock.unlock()

            guard let url = host.url(forResource: code, withExtension: "lproj"),
                  let tableBundle = Bundle(url: url) else { return nil }
            proxyLock.lock()
            var map = lprojCache[id] ?? [:]
            map[code] = tableBundle
            lprojCache[id] = map
            proxyLock.unlock()
            return tableBundle
        }
    }

    private static let installProxy: Void = {
        let cls: AnyClass = Bundle.self
        let originalSelector = #selector(Bundle.localizedString(forKey:value:table:))
        let swizzledSelector = #selector(Bundle.floe_proxyLocalizedString(forKey:value:table:))
        guard let originalMethod = class_getInstanceMethod(cls, originalSelector),
              let swizzledMethod = class_getInstanceMethod(cls, swizzledSelector) else { return () }
        method_exchangeImplementations(originalMethod, swizzledMethod)
        return ()
    }()

    /// Enables table interception. Idempotent; safe in extensions and tests.
    public static func installBundleProxyIfNeeded() {
        _ = installProxy
        BundleProxy.register(Bundle.main)
    }
    #else
    // Portable (non-Darwin, e.g. Linux) fallback: method swizzling and
    // NSHashTable are ObjectiveC-runtime facilities that do not exist there.
    // Lookup already goes through the explicit lproj tables in `lookup(key:)`,
    // so localization resolution keeps working without Bundle interception.
    fileprivate enum BundleProxy {
        static func register(_ bundle: Bundle) {}
        static func isRegistered(_ bundle: Bundle) -> Bool { false }
    }

    /// No-op on platforms without the Objective-C runtime.
    public static func installBundleProxyIfNeeded() {
        BundleProxy.register(Bundle.main)
    }
    #endif
}

#if canImport(ObjectiveC)
extension Bundle {
    @objc func floe_proxyLocalizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        // Only intercept first-party catalog lookups on registered hosts.
        guard FloeL10n.BundleProxy.isRegistered(self) else {
            // Calls into lproj bundles land here after swizzling and must use
            // the original implementation (now behind the swizzled selector).
            return floe_proxyLocalizedString(forKey: key, value: value, table: tableName)
        }
        let table = tableName ?? "Localizable"
        guard table == "Localizable" else {
            return floe_proxyLocalizedString(forKey: key, value: value, table: tableName)
        }
        // Always route to the resolved product language table. Passing
        // through to the original implementation would use the process
        // preferred-language cache, which can lag an in-session switch.
        let code = FloeL10n.currentLanguageCode
        if let target = FloeL10n.BundleProxy.languageBundle(for: self, code: code) {
            let resolved = target.localizedString(forKey: key, value: key, table: table)
            if resolved != key { return resolved }
        }
        if code != "en",
           let english = FloeL10n.BundleProxy.languageBundle(for: self, code: "en") {
            let resolved = english.localizedString(forKey: key, value: value ?? key, table: table)
            if resolved != key { return resolved }
        }
        return floe_proxyLocalizedString(forKey: key, value: value, table: tableName)
    }
}
#endif

public extension Notification.Name {
    /// Posted after the active app language changes; object is the language code.
    static let floeLanguageDidChange = Notification.Name("FloeLanguageDidChange")
}
