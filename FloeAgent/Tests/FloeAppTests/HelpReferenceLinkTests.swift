// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeCore
#if !HELP_TOOL_QUALIFICATION
@testable import FloeApp
#endif

@Suite("FloeApp.HelpReferenceLinks")
struct HelpReferenceLinkTests {
    @Test("Exact snapshot, language and section survive citation encoding")
    func citationRoundTrip() throws {
        for language in HelpLanguage.allCases {
            for section in [nil, "keyboard.return-key"] as [String?] {
                let reference = HelpReference(version: "1.1.0", language: language,
                    articleID: "input.keyboard", sectionID: section)
                let url = try HelpReferenceLink.url(for: reference)
                #expect(url.scheme == "floe-help")
                #expect(url.host == "guide")
                #expect(try HelpReferenceLink.reference(from: url) == reference)
                #expect(try HelpReferenceLink.reference(from: url.absoluteString) == reference)
            }
        }
    }

    @Test("Citations cannot become arbitrary file, network or settings routes", arguments: [
        "https://example.test/guide/input.keyboard?package=floe.help.quickstart&version=1.1.0&locale=en",
        "file:///private/config.json",
        "floe://settings/general",
        "floe-help://settings/general",
        "floe-help://bundle/help/manifest.json",
        "floe-help://guide/input.keyboard?package=other.package&version=1.1.0&locale=en",
        "floe-help://guide/input.keyboard?package=floe.help.quickstart&version=1.1.0&locale=fr",
        "floe-help://guide/input.keyboard?package=floe.help.quickstart&version=latest&locale=en",
        "floe-help://guide/input.keyboard?package=floe.help.quickstart&version=1.1.0&locale=en&setting=general.hardwareReturn",
        "floe-help://guide/input.keyboard?package=floe.help.quickstart&version=1.1.0&locale=en&locale=zh-Hans",
        "floe-help://guide/input.keyboard?package=floe.help.quickstart&version=1.1.0&locale=en#keyboard",
        "floe-help://guide/input.keyboard?package=floe.help.quickstart&version=1.1.0&locale=en&section=",
        "floe-help://user@guide/input.keyboard?package=floe.help.quickstart&version=1.1.0&locale=en",
        "floe-help://guide:80/input.keyboard?package=floe.help.quickstart&version=1.1.0&locale=en",
        "floe-help://guide/../input.keyboard?package=floe.help.quickstart&version=1.1.0&locale=en",
        "floe-help://guide/input%2Fkeyboard?package=floe.help.quickstart&version=1.1.0&locale=en",
        "floe-help://guide/%69nput.keyboard?package=floe.help.quickstart&version=1.1.0&locale=en",
        "floe-help://guide/input.keyboard?package=floe.help.quickstart&version=1.1.0&locale=en&section=%2e%2e",
        "floe-help://guide/input.keyboard?package=floe.help.quickstart&version=1.1.0&locale=en&section=keyboard%0a",
        "floe-help://guide/input.keyboard?package=floe.help.quickstart&version=1.1.0&locale=en&url=https://example.test"
    ])
    func rejectsUntrustedRoutes(_ value: String) {
        #expect(throws: (any Error).self) { try HelpReferenceLink.reference(from: value) }
    }

    @Test("Identifiers and links have bounded, canonical forms")
    func rejectsUnboundedAndInvalidIdentifiers() {
        for value in ["", "../secret", "a/b", "a%2fb", "a\nb", "a\n", "指南", String(repeating: "a", count: 129)] {
            let reference = HelpReference(version: "1.1.0", language: .english, articleID: value)
            #expect(throws: (any Error).self) { try HelpReferenceLink.url(for: reference) }
        }
        let oversize = "floe-help://guide/" + String(repeating: "a", count: 1_025)
        #expect(throws: (any Error).self) { try HelpReferenceLink.reference(from: oversize) }
        let newlineVersion = HelpReference(version: "1.1.0\n", language: .english, articleID: "quickstart")
        #expect(throws: (any Error).self) { try HelpReferenceLink.url(for: newlineVersion) }
    }

    @Test("Native setting labels and targets match the shipping settings controls")
    func knownSettingsOnly() throws {
        let keyboard = try #require(HelpSettingsCatalog.target(id: "general.hardwareReturn", language: .simplifiedChinese))
        #expect(keyboard.path == ["设置", "通用", "实体键盘", "回车键"])
        #expect(keyboard.category == "general")
        #expect(keyboard.controlID == "settings.general.hardwareReturn")
        #expect(keyboard.nestedPage == nil)

        let voice = try #require(HelpSettingsCatalog.target(id: "general.voiceOutput", language: .english))
        #expect(voice.path == ["Settings", "General", "Voice Output"])
        #expect(voice.nestedPage == "voiceOutput")
        #expect(voice.controlID == nil)

        let memory = try #require(HelpSettingsCatalog.target(id: "execution.memory", language: .simplifiedChinese))
        #expect(memory.path == ["设置", "执行环境", "共享运行环境", "内存"])
        #expect(memory.controlID == "execution.shared.memory")
        #expect(HelpSettingsCatalog.availabilityNote(id: memory.id, language: .english)?.contains("runtime is ready") == true)
        for invalid in ["", "general", "general.apiKey", "execution.memory.value", "../general.hardwareReturn", "General.hardwareReturn"] {
            #expect(HelpSettingsCatalog.target(id: invalid, language: .english) == nil)
        }
    }
}
