import Foundation
import Testing
@testable import FloeToolboxWorkbenches

struct QRLinkTests {
    @Test func webLinksKeepTheirPathQueryAndFragment() {
        for value in ["https://example.com/a%20b?q=hello%20world#part", "http://192.168.1.1:8080/setup", "https://[2001:db8::1]/path"] {
            #expect(ToolboxQRLink.destination(for: value)?.absoluteString == value)
        }
    }

    @Test func surroundingWhitespaceIsTrimmedWithoutAcceptingInternalControls() {
        #expect(ToolboxQRLink.destination(for: " \nhttps://example.com/path?q=1#part\r\n")?.absoluteString == "https://example.com/path?q=1#part")
        #expect(ToolboxQRLink.destination(for: "https://example.com/a\nb") == nil)
        #expect(ToolboxQRLink.destination(for: "https://example.com/\0") == nil)
    }

    @Test func textRelativeAndNonWebSchemesNeverBecomeOpenActions() {
        for value in ["", "A normal QR message", "example.com", "www.example.com", "/relative", "javascript:alert(1)", "data:text/html,test", "file:///tmp/a", "mailto:hello@example.com", "https://", "https:///missing-host", "https://exa mple.com/path", "https://example.com%2Fbad/path"] {
            #expect(ToolboxQRLink.destination(for: value) == nil, "Unexpected open action for \(value)")
        }
    }

    @Test func theRawPayloadLimitCannotBeBypassedWithWhitespace() {
        let prefix = "https://example.com/"
        let atLimit = prefix + String(repeating: "a", count: 8192 - prefix.utf8.count)
        #expect(ToolboxQRLink.destination(for: atLimit) != nil)
        #expect(ToolboxQRLink.destination(for: atLimit + " ") == nil)
    }
}
