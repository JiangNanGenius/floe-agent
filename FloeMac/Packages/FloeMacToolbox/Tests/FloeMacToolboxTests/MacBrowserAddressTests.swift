// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
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
}
