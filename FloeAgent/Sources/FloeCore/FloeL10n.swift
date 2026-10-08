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
//   * `localized(key:arguments:)` resolves keys explicitly against the
//     `en.lproj` / `zh-Hans.lproj` tables for package modules and UIKit code.
//   * `isChinese` / `swiftUILocale` drive inline bilingual helpers and views.
//
// User data, AI output, log messages and protocol identifiers never pass
// through this layer.

import Foundation
import ObjectiveC

public enum FloeL10n {
    /// UserDefaults key shared with `SettingsCenter` ("floe.settings.language").
    public static let defaultsKey = "floe.settings.language"

    /// App Group used to mirror the preference into app extensions.
    public static let appGroupIdentifier = "group.org.floeagent.ios"

    /// Product languages; the catalog is compiled for exactly these.
    public static let supportedLanguageCodes = ["en", "zh-Hans"]

    /// Preference raw values (`LanguagePreference.rawValue`).
    public static let preferenceSystem = "system"
    public static let preferenceEn = "en"
    public static let preferenceZhHans = "zhHans"

    /// Locked, Sendable holder for all mutable language state.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        /// `"en"` or `"zh-Hans"`; nil until `bootstrap()`/`setPreference()`.
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
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> String {
        installBundleProxyIfNeeded()
        let forced = launchArgumentLanguageCode(arguments: arguments)
        var stored = standardDefaults.string(forKey: defaultsKey)
            ?? suiteDefaults?.string(forKey: defaultsKey)
        if forced == nil {
            // Mirror a standard-defaults value (set before the app group link
            // existed, or in unit-test hosts) so extensions stay consistent.
            if let standardValue = standardDefaults.string(forKey: defaultsKey) {
                suiteDefaults?.set(standardValue, forKey: defaultsKey)
            } else if stored == nil, let suiteValue = suiteDefaults?.string(forKey: defaultsKey) {
                standardDefaults.set(suiteValue, forKey: defaultsKey)
                stored = suiteValue
            }
        }
        let followingSystem = forced == nil && (stored == nil || stored == preferenceSystem)
        let code = forced
            ?? (followingSystem ? systemLanguageCode(standardDefaults: standardDefaults)
                                : overrideLanguageCode(preferenceRaw: stored))
        apply(
            resolvedCode: code,
            followingSystem: followingSystem,
            standardDefaults: standardDefaults,
            arguments: arguments
        )
        return code
    }

    /// Applies a preference chosen in Settings ("system"/"en"/"zhHans").
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
        // Resolve against the actual OS language BEFORE mutating the app-level
        // AppleLanguages override, so switching en -> System on a Chinese OS
        // (or zhHans -> System on an English OS) cannot inherit the previous
        // forced value through a cached preferred-languages list.
        let code: String
        if let forced = launchArgumentLanguageCode(arguments: arguments) {
            code = forced
        } else if followingSystem {
            code = systemLanguageCode(standardDefaults: standardDefaults)
        } else {
            code = overrideLanguageCode(preferenceRaw: rawValue)
        }
        apply(
            resolvedCode: code,
            followingSystem: followingSystem,
            standardDefaults: standardDefaults,
            arguments: arguments
        )
        return code
    }

    /// Language code for an explicit en/zhHans preference (never system).
    private static func overrideLanguageCode(preferenceRaw: String?) -> String {
        switch preferenceRaw {
        case preferenceEn: return "en"
        case preferenceZhHans: return "zh-Hans"
        default: return systemLanguageCode()
        }
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
    ///   - preferenceRaw: stored "system"/"en"/"zhHans" value (nil = unset).
    ///   - forcedLanguageCode: language forced by launch arguments.
    ///   - systemPreferredLanguages: the *OS* preferred-language list.
    public static func resolveLanguageCode(
        preferenceRaw: String?,
        forcedLanguageCode: String?,
        systemPreferredLanguages: [String]
    ) -> String {
        if let forcedLanguageCode, supportedLanguageCodes.contains(forcedLanguageCode) {
            return forcedLanguageCode
        }
        switch preferenceRaw {
        case preferenceEn: return "en"
        case preferenceZhHans: return "zh-Hans"
        default: break
        }
        if let first = systemPreferredLanguages.first, first.hasPrefix("zh") {
            return "zh-Hans"
        }
        return "en"
    }

    /// Parses `-AppleLanguages (en)` / `(zh-Hans)` style launch arguments.
    static func launchArgumentLanguageCode(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "-AppleLanguages"),
              index + 1 < arguments.count else { return nil }
        var raw = arguments[index + 1]
        if raw.hasPrefix("(") { raw = String(raw.dropFirst()) }
        if raw.hasSuffix(")") { raw = String(raw.dropLast()) }
        raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        guard let code = raw.components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces) else { return nil }
        if code.hasPrefix("zh") { return "zh-Hans" }
        if code.hasPrefix("en") { return "en" }
        return nil
    }

    /// Reads the *OS* preferred languages independently of this app's
    /// `AppleLanguages` override. The app-level override lives in the
    /// application preferences domain, while the OS list is stored in the
    /// global domain, so the global-domain value remains accurate even while
    /// (or immediately after) the app forces en/zh-Hans.
    public static func systemPreferredLanguages(
        standardDefaults: UserDefaults = .standard
    ) -> [String] {
        if let testSystemLanguagesOverride { return testSystemLanguagesOverride }
        if let global = standardDefaults.persistentDomain(forName: UserDefaults.globalDomain),
           let languages = global["AppleLanguages"] as? [String],
           !languages.isEmpty {
            return languages
        }
        // Fallback for unusual hosts (e.g. some unit-test environments where
        // the global domain is unavailable).
        return Locale.preferredLanguages
    }

    /// Product language code derived purely from the OS preferences.
    public static func systemLanguageCode(
        standardDefaults: UserDefaults = .standard
    ) -> String {
        let languages = systemPreferredLanguages(standardDefaults: standardDefaults)
        if let first = languages.first, first.hasPrefix("zh") { return "zh-Hans" }
        return "en"
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

    /// OS language/region identifier resolved from the global preferences
    /// domain, independent of the app-level AppleLanguages override.
    public static func systemLocaleIdentifier(
        standardDefaults: UserDefaults = .standard
    ) -> String {
        if let global = standardDefaults.persistentDomain(forName: UserDefaults.globalDomain),
           let locale = global["AppleLocale"] as? String,
           !locale.isEmpty {
            return locale
        }
        if let first = systemPreferredLanguages(standardDefaults: standardDefaults).first {
            return first
        }
        return currentLanguageCode
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

    /// Count-aware lookup: English resolves the sibling `<key>.one` entry when
    /// the count is exactly 1 (Chinese has no plural form and always uses the
    /// base entry). Falls back to the base entry when no singular is defined.
    public static func plural(_ key: String, count: Int, _ extra: Any...) -> String {
        var resolvedKey = key
        if count == 1, currentLanguageCode == "en",
           resolvedFormat(forKey: key + ".one") != nil {
            resolvedKey = key + ".one"
        }
        return localized(key: resolvedKey, arguments: [count] + extra)
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
        let code = currentLanguageCode
        if let value = lookup(key: key, code: code), value != key, !value.isEmpty {
            return value
        }
        if code != "en", let fallback = lookup(key: key, code: "en"),
           fallback != key, !fallback.isEmpty {
            return fallback
        }
        return nil
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
        let lprojName = code == "zh-Hans" ? "zh-Hans" : "en"
        var candidates: [Bundle] = [Bundle.main] + Bundle.allBundles + additionalResourceBundles
        #if canImport(Darwin)
        candidates.append(contentsOf: Bundle.allFrameworks)
        #endif
        for host in candidates {
            if let url = host.url(forResource: lprojName, withExtension: "lproj"),
               let tableBundle = Bundle(url: url),
               tableBundle.url(forResource: "Localizable", withExtension: "strings") != nil {
                return tableBundle
            }
        }
        return nil
    }

    // MARK: - Bundle proxy

    fileprivate enum BundleProxy {
        /// Registered host bundles whose lookups are redirected (main bundle).
        nonisolated(unsafe) static var registeredTargets = NSHashTable<Bundle>.weakObjects()
        nonisolated(unsafe) static var lprojCache: [ObjectIdentifier: [String: Bundle]] = [:]
        static let proxyLock = NSLock()

        static func register(_ bundle: Bundle) {
            proxyLock.lock()
            defer { proxyLock.unlock() }
            let already = registeredTargets.allObjects.contains { ($0 as? Bundle) == bundle }
            if !already {
                registeredTargets.add(bundle)
            }
        }

        static func isRegistered(_ bundle: Bundle) -> Bool {
            proxyLock.lock(); defer { proxyLock.unlock() }
            return registeredTargets.allObjects.contains { ($0 as? Bundle) == bundle }
        }

        static func languageBundle(for host: Bundle, code: String) -> Bundle? {
            let id = ObjectIdentifier(host)
            proxyLock.lock()
            if let cached = lprojCache[id]?[code] {
                proxyLock.unlock()
                return cached
            }
            proxyLock.unlock()

            let lprojName = code == "zh-Hans" ? "zh-Hans" : "en"
            guard let url = host.url(forResource: lprojName, withExtension: "lproj"),
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
}

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
            let resolved = target.localizedString(forKey: key, value: value ?? key, table: table)
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

public extension Notification.Name {
    /// Posted after the active app language changes; object is the language code.
    static let floeLanguageDidChange = Notification.Name("FloeLanguageDidChange")
}
