// FloeCoreTests — runtime language override resolution.
//
// These tests guard the in-app language switch: an English override on a
// Chinese OS (and a Chinese override on an English OS) must resolve exactly,
// and switching back to "Follow System" must follow the *OS* language even
// immediately after a forced override — never a stale cached preference.

import Foundation
import Testing
@testable import FloeCore

@Suite("FloeCore.FloeL10n", .serialized)
struct FloeL10nTests {

    private struct IsolatedDefaults {
        let standard: UserDefaults
        let suite: UserDefaults
        let standardName: String
        let suiteName: String

        func cleanup() {
            standard.removePersistentDomain(forName: standardName)
            suite.removePersistentDomain(forName: suiteName)
        }
    }

    /// Isolated defaults so tests never read or write the real app prefs.
    private func makeDefaults() -> IsolatedDefaults {
        let suiteName = "floe.l10n.test.\(UUID().uuidString)"
        let standardName = suiteName + ".standard"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let standard = UserDefaults(suiteName: standardName)!
        standard.removePersistentDomain(forName: standardName)
        return IsolatedDefaults(standard: standard, suite: suite,
                                standardName: standardName, suiteName: suiteName)
    }

    private func withSystemLanguages(_ languages: [String], _ body: () -> Void) {
        let previous = FloeL10n.testSystemLanguagesOverride
        FloeL10n.testSystemLanguagesOverride = languages
        defer { FloeL10n.testSystemLanguagesOverride = previous }
        body()
    }

    // MARK: - Pure resolver

    @Test("Resolver honors explicit en/zh-Hans over the system language")
    func explicitOverridesWin() {
        #expect(FloeL10n.resolveLanguageCode(
            preferenceRaw: "en", forcedLanguageCode: nil,
            systemPreferredLanguages: ["zh-Hans"]) == "en")
        #expect(FloeL10n.resolveLanguageCode(
            preferenceRaw: "zhHans", forcedLanguageCode: nil,
            systemPreferredLanguages: ["en"]) == "zh-Hans")
    }

    @Test("Resolver follows the system for the system preference")
    func systemPreferenceFollowsOS() {
        #expect(FloeL10n.resolveLanguageCode(
            preferenceRaw: "system", forcedLanguageCode: nil,
            systemPreferredLanguages: ["zh-Hans-CN", "en"]) == "zh-Hans")
        #expect(FloeL10n.resolveLanguageCode(
            preferenceRaw: "system", forcedLanguageCode: nil,
            systemPreferredLanguages: ["en-US", "zh-Hans"]) == "en")
        #expect(FloeL10n.resolveLanguageCode(
            preferenceRaw: nil, forcedLanguageCode: nil,
            systemPreferredLanguages: ["zh-Hans"]) == "zh-Hans")
    }

    @Test("Launch-argument language always wins")
    func launchArgumentWins() {
        #expect(FloeL10n.resolveLanguageCode(
            preferenceRaw: "en", forcedLanguageCode: "zh-Hans",
            systemPreferredLanguages: ["en"]) == "zh-Hans")
        #expect(FloeL10n.launchArgumentLanguageCode(
            arguments: ["app", "-AppleLanguages", "(en)"]) == "en")
        #expect(FloeL10n.launchArgumentLanguageCode(
            arguments: ["app", "-AppleLanguages", "(zh-Hans)"]) == "zh-Hans")
        #expect(FloeL10n.launchArgumentLanguageCode(
            arguments: ["app"]) == nil)
    }

    // MARK: - Stateful preference switching (the reported bug)

    @Test("English override then Follow System on a Chinese OS returns Chinese")
    func enThenSystemOnChineseOS() {
        let d = makeDefaults()
        defer { d.cleanup() }
        withSystemLanguages(["zh-Hans"]) {
            // User picked English on a Chinese device.
            #expect(FloeL10n.setPreference(rawValue: "en",
                                           standardDefaults: d.standard,
                                           suiteDefaults: d.suite,
                                           arguments: []) == "en")
            #expect(FloeL10n.currentLanguageCode == "en")
            #expect(FloeL10n.isChinese == false)

            // Switch to Follow System in the SAME session. The resolved
            // language must immediately come from the OS (Chinese), not from
            // a cached/forced English value.
            #expect(FloeL10n.setPreference(rawValue: "system",
                                           standardDefaults: d.standard,
                                           suiteDefaults: d.suite,
                                           arguments: []) == "zh-Hans")
            #expect(FloeL10n.currentLanguageCode == "zh-Hans")
            #expect(FloeL10n.isChinese == true)
        }
    }

    @Test("Chinese override then Follow System on an English OS returns English")
    func zhThenSystemOnEnglishOS() {
        let d = makeDefaults()
        defer { d.cleanup() }
        withSystemLanguages(["en-US"]) {
            #expect(FloeL10n.setPreference(rawValue: "zhHans",
                                           standardDefaults: d.standard,
                                           suiteDefaults: d.suite,
                                           arguments: []) == "zh-Hans")
            #expect(FloeL10n.currentLanguageCode == "zh-Hans")
            #expect(FloeL10n.isChinese == true)

            #expect(FloeL10n.setPreference(rawValue: "system",
                                           standardDefaults: d.standard,
                                           suiteDefaults: d.suite,
                                           arguments: []) == "en")
            #expect(FloeL10n.currentLanguageCode == "en")
            #expect(FloeL10n.isChinese == false)
        }
    }

    @Test("Bootstrap with a saved override survives an opposite-language OS")
    func bootstrapPersistsOverride() {
        let d = makeDefaults()
        defer { d.cleanup() }
        withSystemLanguages(["zh-Hans-CN"]) {
            d.standard.set("en", forKey: FloeL10n.defaultsKey)
            #expect(FloeL10n.bootstrap(standardDefaults: d.standard,
                                       suiteDefaults: d.suite,
                                       arguments: []) == "en")
            #expect(FloeL10n.currentLanguageCode == "en")

            // A saved system preference follows the OS.
            d.standard.set("system", forKey: FloeL10n.defaultsKey)
            #expect(FloeL10n.bootstrap(standardDefaults: d.standard,
                                       suiteDefaults: d.suite,
                                       arguments: []) == "zh-Hans")
        }
    }

    @Test("App preference is mirrored into the App Group for extensions")
    func preferenceMirroredToAppGroup() {
        let d = makeDefaults()
        defer { d.cleanup() }
        withSystemLanguages(["en"]) {
            FloeL10n.setPreference(rawValue: "zhHans",
                                   standardDefaults: d.standard,
                                   suiteDefaults: d.suite,
                                   arguments: [])
            #expect(d.suite.string(forKey: FloeL10n.defaultsKey) == "zhHans")
            FloeL10n.setPreference(rawValue: nil,
                                   standardDefaults: d.standard,
                                   suiteDefaults: d.suite,
                                   arguments: [])
            #expect(d.suite.string(forKey: FloeL10n.defaultsKey) == nil)
        }
    }

    // MARK: - Public Locale path (no global-domain reads)

    @Test("Uninjected system resolution uses the public Locale path")
    func publicLocalePath() {
        let previous = FloeL10n.testSystemLanguagesOverride
        FloeL10n.testSystemLanguagesOverride = nil
        defer { FloeL10n.testSystemLanguagesOverride = previous }
        // The real OS-path behaviour after clearing the app-domain override
        // was measured with an app-domain probe (recorded in the privacy
        // deliverable); this guards the injection-free read itself.
        let languages = FloeL10n.systemPreferredLanguages()
        #expect(!languages.isEmpty)
        #expect(languages == Locale.preferredLanguages)
    }

    @Test("System locale keeps the OS region when the language tag differs")
    func systemLocaleKeepsIndependentRegion() {
        // Language and region are independent user choices: English (US)
        // selected with an Australian region must format as en_AU, and
        // Simplified Chinese with an Australian region as zh-Hans_AU.
        #expect(FloeL10n.systemLocaleIdentifier(
            preferredLanguages: ["en-US"], region: "AU") == "en_AU")
        #expect(FloeL10n.systemLocaleIdentifier(
            preferredLanguages: ["zh-Hans-CN"], region: "AU") == "zh-Hans_AU")
        #expect(FloeL10n.systemLocaleIdentifier(
            preferredLanguages: ["en"], region: "AU") == "en_AU")
        // Without an OS region the language tag's own region is kept.
        #expect(FloeL10n.systemLocaleIdentifier(
            preferredLanguages: ["zh-Hans-CN"], region: nil) == "zh-Hans_CN")
        #expect(FloeL10n.systemLocaleIdentifier(
            preferredLanguages: [], region: "AU") == FloeL10n.currentLanguageCode)
    }

    @Test("Switching to Follow System clears this app's AppleLanguages override")
    func systemSwitchClearsAppOverride() {
        let d = makeDefaults()
        defer { d.cleanup() }
        withSystemLanguages(["zh-Hans-CN"]) {
            #expect(FloeL10n.setPreference(rawValue: "en",
                                           standardDefaults: d.standard,
                                           suiteDefaults: d.suite,
                                           arguments: []) == "en")
            #expect(d.standard.stringArray(forKey: "AppleLanguages") == ["en"])
            // Follow System resolves from the OS list, and the app-domain
            // override is removed before resolution, so the public Locale
            // path can never return the previously forced language.
            #expect(FloeL10n.setPreference(rawValue: "system",
                                           standardDefaults: d.standard,
                                           suiteDefaults: d.suite,
                                           arguments: []) == "zh-Hans")
            #expect(d.standard.persistentDomain(forName: d.standardName)?["AppleLanguages"] == nil)
        }
    }

    @Test("Bootstrap with a system preference clears a stale override")
    func bootstrapClearsStaleOverride() {
        let d = makeDefaults()
        defer { d.cleanup() }
        d.standard.set(["en"], forKey: "AppleLanguages")
        d.standard.set("system", forKey: FloeL10n.defaultsKey)
        withSystemLanguages(["zh-Hans-CN"]) {
            #expect(FloeL10n.bootstrap(standardDefaults: d.standard,
                                       suiteDefaults: d.suite,
                                       arguments: []) == "zh-Hans")
            #expect(d.standard.persistentDomain(forName: d.standardName)?["AppleLanguages"] == nil)
        }
    }
}
