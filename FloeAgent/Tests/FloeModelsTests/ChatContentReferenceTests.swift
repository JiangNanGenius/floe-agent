// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeModels

@Suite("Chat content reference locators")
struct ChatContentReferenceTests {
    @Test func eachNamespaceRoundTripsAndHasARealURLHost() throws {
        let owner = UUID(), content = UUID()
        for kind in [ChatContentReference.Kind.artifact, .output, .attachment] {
            let id = kind == .output ? String(repeating: "a", count: 64) : content.uuidString
            let value = try #require(ChatContentReference(kind: kind, ownerID: owner, contentID: id))
            #expect(URLComponents(string: value.uri)?.host == kind.rawValue)
            #expect(ChatContentReference(value.uri) == value)
            #expect(try JSONDecoder().decode(ChatContentReference.self, from: JSONEncoder().encode(value)) == value)
        }
    }
    @Test func unsafeOrMalformedLocatorsNeverBecomeReferences() {
        let owner = UUID().uuidString, id = UUID().uuidString
        for uri in ["file:///etc/passwd", "https://example.com/x.html", "floe-content://unknown/\(owner)/\(id)",
                    "floe-content://artifact/../\(id)", "floe-content://artifact/\(owner)/%2e%2e",
                    "floe-content://artifact/\(owner)/\(id)?path=/etc/passwd", "floe-content://artifact/\(owner)/\(id)#x",
                    "floe-content://user@artifact/\(owner)/\(id)", "floe-content://artifact:123/\(owner)/\(id)",
                    "floe-content://%61rtifact/\(owner)/\(id)", "floe-content://artifact/\(owner)/\(id)/extra",
                    "floe-content://output/\(owner)/\(id)"] { #expect(ChatContentReference(uri) == nil) }
    }
    @Test func decodedLocatorsValidateIDsAndKeyOrderDoesNotMatter() throws {
        let owner = UUID(), id = UUID()
        let a = "{\"kind\":\"artifact\",\"ownerID\":\"\(owner)\",\"contentID\":\"\(id)\"}"
        let b = "{\"contentID\":\"\(id)\",\"ownerID\":\"\(owner)\",\"kind\":\"artifact\"}"
        #expect(try JSONDecoder().decode(ChatContentReference.self, from: Data(a.utf8)) == JSONDecoder().decode(ChatContentReference.self, from: Data(b.utf8)))
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ChatContentReference.self, from: Data(a.replacingOccurrences(of: id.uuidString, with: "../x").utf8)) }
    }
    @Test func emittedMarkdownCannotInjectAnotherBlock() throws {
        let ref = try #require(ChatContentReference(kind: .artifact, ownerID: UUID(), contentID: UUID().uuidString))
        let markdown = ref.markdown(title: "Chart]\\\n![another")
        #expect(!markdown.contains("\n"))
        #expect(markdown.hasSuffix("(\(ref.uri))"))
    }
}
