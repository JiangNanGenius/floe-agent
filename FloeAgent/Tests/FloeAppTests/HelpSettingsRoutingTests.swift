// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeCore
@testable import FloeApp

#if canImport(UIKit)
@MainActor
@Suite("Help settings destinations")
struct HelpSettingsRoutingTests {
    @Test func returnKeyAndMemoryRemainNativeControlRoutes() throws {
        let keyboard = try #require(HelpSettingsCatalog.target(id: "general.hardwareReturn", language: .english))
        let keyboardPlan = try #require(HelpSettingsRoutePlan(target: keyboard, language: .simplifiedChinese))
        #expect(keyboardPlan.categoryID == "general")
        #expect(keyboardPlan.nestedPage == nil)
        #expect(keyboardPlan.target.controlID == "settings.general.hardwareReturn")
        #expect(keyboardPlan.target.path.first == "设置")
        let memory = try #require(HelpSettingsCatalog.target(id: "execution.memory", language: .english))
        let memoryPlan = try #require(HelpSettingsRoutePlan(target: memory, language: .english))
        #expect(memoryPlan.categoryID == "execution")
        #expect(memoryPlan.target.controlID == "execution.shared.memory")
        #expect(memoryPlan.nestedPage == nil)
    }

    @Test func voiceOutputPushesTheExistingNestedPage() throws {
        let target = try #require(HelpSettingsCatalog.target(id: "general.voiceOutput", language: .english))
        let plan = try #require(HelpSettingsRoutePlan(target: target, language: .english))
        #expect(plan.categoryID == "general")
        #expect(plan.nestedPage == .voiceOutput)
        #expect(plan.target.controlID == nil)
    }


}
#endif

@Suite("Help offline resource URLs")
struct HelpResourceURLTests {
    @Test func answerCardsComeOnlyFromStrictMarkdownCitations() throws {
        let reference = HelpReference(version: "1.1.0", language: .english, articleID: "input.keyboard")
        let url = try HelpReferenceLink.url(for: reference).absoluteString
        #expect(HelpAnswerReferences.references(in: "[Guide](\(url))\n[Again](\(url))") == [reference])
        #expect(HelpAnswerReferences.references(in: "`[Code](\(url))`").isEmpty)
        #expect(HelpAnswerReferences.references(in: "```text\n[Code](\(url))\n```").isEmpty)
        #expect(HelpAnswerReferences.references(in: url).isEmpty)
        #expect(HelpAnswerReferences.references(in: "[Other](https://example.com) [Invalid](floe-help://guide/input.keyboard?path=/private)").isEmpty)
    }

    @Test func resourceSchemeRejectsAuthorityChangesAndTraversal() throws {
        let valid = try #require(HelpResourceURL.url(path: "help/en/input.keyboard.html"))
        #expect(HelpResourceURL.path(url: valid) == "help/en/input.keyboard.html")
        for input in [
            "file:///private/file", "https://example.com/image.png",
            "floe-help://other/help/en/input.keyboard.html", "floe-help://user@bundle/help/a.html",
            "floe-help://bundle:80/help/a.html", "floe-help://bundle/help/a.html?path=elsewhere",
            "floe-help://bundle/help/%2e%2e/private", "floe-help://bundle/help%2fprivate",
            "floe-help://bundle/help/%252e%252e/private", "floe-help://bundle/help/%5cprivate"
        ] {
            #expect(HelpResourceURL.path(url: try #require(URL(string: input))) == nil)
        }
        #expect(HelpResourceURL.url(path: "../private") == nil)
        #expect(HelpResourceURL.url(path: "help//private") == nil)
        #expect(HelpResourceURL.url(path: "/private") == nil)
    }
}
