// FloeBrowserTests — navigation/URL policy + preview grant semantics.
// Authored (job-9960651880854093), not executed in this source lane.

import XCTest
@testable import FloeBrowser

final class BrowserURLPolicyTests: XCTestCase {
    private func blocked(_ policy: BrowserURLPolicy, _ url: String, conversation: UUID? = nil, allowServices: Bool = false) -> String? {
        do {
            _ = try policy.validate(url, conversationID: conversation, allowRegisteredServices: allowServices)
            return nil
        } catch let error as BrowserPolicyError {
            if case .blocked(let message) = error { return message }
        } catch {}
        return "unexpected error type"
    }

    func testSchemeAndCredentialRules() {
        let policy = BrowserURLPolicy()
        XCTAssertEqual(blocked(policy, "file:///etc/passwd"), "Only http and https URLs are allowed")
        XCTAssertEqual(blocked(policy, "ftp://example.com"), "Only http and https URLs are allowed")
        XCTAssertEqual(blocked(policy, "https://user:pass@example.com"), "Credentials in URLs are not allowed")
        XCTAssertNil(blocked(policy, "https://example.com/path"))
        XCTAssertNil(blocked(policy, "http://example.com"))
    }

    func testPrivateAndLoopbackSpaceIsBlockedByDefault() {
        let policy = BrowserURLPolicy()
        for host in [
            "http://localhost:3000/app",
            "http://127.0.0.1:8080/x",
            "http://10.1.2.3/",
            "http://172.16.0.1/",
            "http://172.31.255.255/",
            "http://192.168.1.1/",
            "http://169.254.9.9/",
            "http://0.1.2.3/",
            "http://printer.local/",
            "http://[::1]:8080/",
        ] {
            XCTAssertEqual(blocked(policy, host), "Loopback and private-network navigation is blocked", "must block \(host)")
        }
        // 172.32 is NOT private: public space keeps flowing.
        XCTAssertNil(blocked(policy, "http://172.32.0.1/"))
    }

    func testPreviewGrantIsExactAllocation() throws {
        let policy = BrowserURLPolicy()
        let conversation = UUID()
        let token = String(repeating: "a", count: 32)
        let granted = URL(string: "http://127.0.0.1:45000/\(token)/index.html")!
        policy.authorizePreview(granted)

        XCTAssertNil(blocked(policy, "http://127.0.0.1:45000/\(token)/index.html", conversation: conversation))
        XCTAssertNil(blocked(policy, "http://127.0.0.1:45000/\(token)/assets/app.js", conversation: conversation))
        // Same port, different token: still blocked. A page/iframe cannot
        // widen access because only the coordinator calls authorizePreview.
        XCTAssertEqual(
            blocked(policy, "http://127.0.0.1:45000/\(String(repeating: "b", count: 32))/secrets", conversation: conversation),
            "Loopback and private-network navigation is blocked"
        )
        // Different port, same token: blocked.
        XCTAssertEqual(
            blocked(policy, "http://127.0.0.1:45001/\(token)/index.html", conversation: conversation),
            "Loopback and private-network navigation is blocked"
        )
        // Short token (<32): never grantable.
        let short = URL(string: "http://127.0.0.1:45002/shorttoken/index.html")!
        policy.authorizePreview(short)
        XCTAssertEqual(
            blocked(policy, "http://127.0.0.1:45002/shorttoken/index.html", conversation: conversation),
            "Loopback and private-network navigation is blocked"
        )
        policy.revokePreview(granted)
        XCTAssertEqual(
            blocked(policy, "http://127.0.0.1:45000/\(token)/index.html", conversation: conversation),
            "Loopback and private-network navigation is blocked"
        )
    }

    func testServiceOriginsAreConversationScoped() throws {
        let policy = BrowserURLPolicy()
        let owner = UUID()
        let conversation = UUID()
        let otherConversation = UUID()
        let url = URL(string: "http://127.0.0.1:3344/")!
        policy.authorizeService(url, owner: owner, conversationID: conversation)
        XCTAssertNil(blocked(policy, "http://127.0.0.1:3344/api", conversation: conversation))
        XCTAssertNil(blocked(policy, "http://127.0.0.1:3344/api", conversation: otherConversation, allowServices: true))
        XCTAssertEqual(
            blocked(policy, "http://127.0.0.1:3344/api", conversation: otherConversation),
            "Loopback and private-network navigation is blocked"
        )
        policy.revokeService(owner: owner)
        XCTAssertEqual(
            blocked(policy, "http://127.0.0.1:3344/api", conversation: conversation),
            "Loopback and private-network navigation is blocked"
        )
    }

    func testIsPreviewAllocationIdentity() {
        let policy = BrowserURLPolicy()
        let token = String(repeating: "c", count: 32)
        let preview = URL(string: "http://127.0.0.1:46000/\(token)/index.html")!
        XCTAssertTrue(policy.isPreviewAllocation(
            URL(string: "http://127.0.0.1:46000/\(token)/dist/app.js")!,
            matching: preview
        ))
        XCTAssertFalse(policy.isPreviewAllocation(
            URL(string: "http://127.0.0.1:46001/\(token)/index.html")!,
            matching: preview
        ))
        XCTAssertFalse(policy.isPreviewAllocation(
            URL(string: "http://127.0.0.1:46000/\(String(repeating: "d", count: 32))/index.html")!,
            matching: preview
        ))
        XCTAssertFalse(policy.isPreviewAllocation(
            URL(string: "https://127.0.0.1:46000/\(token)/index.html")!,
            matching: preview
        ))
    }
}
