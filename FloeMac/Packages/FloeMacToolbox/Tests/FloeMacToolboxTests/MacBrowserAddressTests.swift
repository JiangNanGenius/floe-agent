// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
import WebKit
@testable import FloeMacToolbox

struct MacBrowserAddressTests {
    @Test("Accepts websites and explicit loopback destinations")
    func acceptsWebAddresses() {
        #expect(MacBrowserAddress.url(from: "  example.test/about  ")?.absoluteString == "https://example.test/about")
        #expect(MacBrowserAddress.url(from: "http://127.0.0.1:8081/")?.port == 8081)
    }

    @Test("Rejects navigation outside permitted schemes and embedded credentials")
    func rejectsUnsupportedAddresses() {
        for input in ["file:///etc/hosts", "floe-bridge://connect", "https://user:pass@example.test",
                      "example.test\u{0000}/hello", "https://"] {
            #expect(MacBrowserAddress.url(from: input) == nil)
        }
    }

    @Test("Allows ordinary in-tab navigation for permitted http(s) URLs")
    func allowsOrdinaryNavigation() {
        #expect(MacBrowserSession.choice(targetFrameExists: true, navigationType: .linkActivated,
                                         url: URL(string: "https://example.test/a"),
                                         shouldPerformDownload: false) == .allow)
        #expect(MacBrowserSession.choice(targetFrameExists: true, navigationType: .other,
                                         url: URL(string: "http://127.0.0.1:8080/"), shouldPerformDownload: false) == .allow)
    }

    @Test("User-clicked target=_blank links open in the current tab")
    func userBlankLinksLoadInCurrentTab() {
        #expect(MacBrowserSession.choice(targetFrameExists: false, navigationType: .linkActivated,
                                         url: URL(string: "https://example.test/next"),
                                         shouldPerformDownload: false) == .loadInCurrentTab)
        // The fixture the workbench smoke uses: loopback http from a real click.
        #expect(MacBrowserSession.choice(targetFrameExists: false, navigationType: .linkActivated,
                                         url: URL(string: "http://127.0.0.1:49713/workbench-next"),
                                         shouldPerformDownload: false) == .loadInCurrentTab)
    }

    @Test("Automatic or scripted popup navigations stay ignored")
    func ignoresAutomaticPopups() {
        for type in [WKNavigationType.other, .formSubmitted, .formResubmitted, .backForward, .reload] {
            #expect(MacBrowserSession.choice(targetFrameExists: false, navigationType: type,
                                             url: URL(string: "https://example.test/popup"),
                                             shouldPerformDownload: false) == .ignore)
        }
        #expect(MacBrowserSession.choice(targetFrameExists: false, navigationType: .linkActivated,
                                         url: URL(string: "file:///etc/hosts"),
                                         shouldPerformDownload: false) == .ignore)
        #expect(MacBrowserSession.choice(targetFrameExists: true, navigationType: .linkActivated,
                                         url: URL(string: "https://user:pass@example.test"),
                                         shouldPerformDownload: false) == .ignore)
        #expect(MacBrowserSession.choice(targetFrameExists: false, navigationType: .linkActivated,
                                         url: URL(string: "https://example.test/file.bin"),
                                         shouldPerformDownload: true) == .ignore)
        #expect(MacBrowserSession.choice(targetFrameExists: true, navigationType: .linkActivated,
                                         url: URL(string: "https://example.test/file.bin"),
                                         shouldPerformDownload: true) == .ignore)
    }

    @Test("Direct URL open honors the shared scheme guard", .timeLimit(.minutes(1)))
    @MainActor func directOpenGuard() async {
        let session = MacBrowserSession()
        session.open(URL(string: "file:///etc/passwd")!)
        #expect(session.failed)
        #expect(session.address.isEmpty)
        #expect(session.currentURL == nil)
        session.open(URL(string: "https://user:pass@example.test")!)
        #expect(session.failed)
        // A permitted URL is published synchronously and clears the failure;
        // navigation itself needs no assertion here (covered by the App
        // smoke against the coordinator's hosted fixture).
        session.open(URL(string: "http://127.0.0.1:49713/workbench-page")!)
        #expect(!session.failed)
        #expect(session.address == "http://127.0.0.1:49713/workbench-page")
    }
}
