// FloeAppTests — in-chat find contract.
//
// Pure, deterministic tests: no App environment, no model request, no
// Simulator. They pin the shared visible-text projection, exact highlight
// offsets (including CJK/emoji), chronological ordering and the find model's
// count/prev/next/Done semantics.

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
@testable import FloeApp

@Suite("FloeApp.ThreadSearch")
struct ThreadSearchTests {
    private func document(
        _ text: String,
        role: String = "assistant",
        createdAt: Date = Date(timeIntervalSince1970: 1_703_000_000)
    ) -> ThreadSearchDocument? {
        ThreadSearchText.document(for: PersistedMessage(
            id: UUID(), conversationID: UUID(), role: role, content: text,
            createdAt: createdAt))
    }

    @Test("Only user/assistant bodies become documents")
    func documentRoles() {
        #expect(document("hello", role: "user") != nil)
        #expect(document("hello", role: "assistant") != nil)
        #expect(document("reasoning", role: "reasoning") == nil)
        #expect(document("system", role: "system") == nil)
        #expect(document("tool", role: "tool") == nil)
    }

    @Test("Markdown offsets are computed on the visible projection, not the source")
    func visibleOffsets() throws {
        let source = "## Heading\n\nA **bold** [link](https://hidden.example/x) and `code`."
        let visible = ConversationSearchText.visibleText(role: "assistant", content: source)
        let query = ConversationSearchQuery(raw: "bold link")
        let ranges = query.ranges(in: visible)
        #expect(ranges.count == 2)
        let characters = Array(visible)
        #expect(String(characters[ranges[0].lowerBound..<ranges[0].upperBound]) == "bold")
        #expect(String(characters[ranges[1].lowerBound..<ranges[1].upperBound]) == "link")
        // Hidden link targets are not searchable visible text.
        #expect(!ConversationSearchQuery(raw: "hidden").matches(visible))
        // The highlighted string keeps exactly the visible characters.
        let highlighted = ThreadSearchText.highlighted(visible, ranges: ranges)
        #expect(String(highlighted.characters) == visible)
    }

    @Test("Highlight offsets count characters, not UTF-16 units")
    func characterOffsets() {
        let text = "😀alpha 中文 beta"
        let query = ConversationSearchQuery(raw: "alpha beta")
        let ranges = query.ranges(in: text)
        #expect(ranges.count == 2)
        let characters = Array(text)
        #expect(String(characters[ranges[0].lowerBound..<ranges[0].upperBound]) == "alpha")
        #expect(String(characters[ranges[1].lowerBound..<ranges[1].upperBound]) == "beta")
        // Out-of-bounds ranges are dropped, never shifted.
        let highlighted = ThreadSearchText.highlighted(text, ranges: [0..<1, 0..<999])
        #expect(String(highlighted.characters) == text)
    }

    @Test("Loaded hits are chronological and require every term in one message")
    func chronologicalAndAndSemantics() throws {
        let base = Date(timeIntervalSince1970: 1_703_100_000)
        let first = try #require(document("beta alpha", createdAt: base))
        let second = try #require(document(
            "alpha only", createdAt: base.addingTimeInterval(1)))
        let third = try #require(document(
            "alpha and beta", role: "user", createdAt: base.addingTimeInterval(2)))
        let hits = ThreadSearchText.hits(
            in: [third, second, first],
            query: ConversationSearchQuery(raw: "alpha beta"))
        #expect(hits.map(\.messageID) == [first.messageID, third.messageID])
        #expect(hits.map(\.role) == ["assistant", "user"])
        #expect(hits.first?.snippet.contains("beta") == true)
    }

    @Test("Find model counts, wraps prev/next and keeps the hit after Done")
    @MainActor
    func findModelLifecycle() async {
        let hits = (0..<3).map { index in
            ThreadSearchHit(
                messageID: UUID(), role: "assistant",
                createdAt: Date(timeIntervalSince1970: 1_703_200_000 + Double(index)),
                snippet: "hit \(index)")
        }
        var revealed: [UUID] = []
        let model = ThreadSearchModel(
            provider: { _ in
                ThreadSearchResult(hits: hits, includesDurableHistory: true)
            },
            reveal: { hit in
                revealed.append(hit.messageID)
                return true
            })
        model.begin()
        model.query = "hit"
        await model.search()
        #expect(model.isActive)
        #expect(model.countLabel == "3/3")
        #expect(model.searchedDurableHistory)
        #expect(model.focusedMessageID == hits.last?.messageID)
        await model.next()
        #expect(model.currentIndex == 0)
        #expect(model.countLabel == "1/3")
        await model.previous()
        #expect(model.currentIndex == 2)
        #expect(revealed.count == 3)

        model.end()
        #expect(!model.isActive)
        #expect(model.query.isEmpty)
        #expect(model.hits.isEmpty)
        // Done stays at the hit: the focused identity is not reset.
        #expect(model.focusedMessageID == hits.last?.messageID)
    }

    @Test("Empty query clears results and a failed reveal is explicit")
    @MainActor
    func emptyAndFailure() async {
        let hit = ThreadSearchHit(
            messageID: UUID(), role: "assistant",
            createdAt: Date(timeIntervalSince1970: 1_703_300_000), snippet: "x")
        let model = ThreadSearchModel(
            provider: { _ in ThreadSearchResult(hits: [hit], includesDurableHistory: false) },
            reveal: { _ in false })
        model.begin()
        model.query = "   "
        await model.search()
        #expect(model.hits.isEmpty)
        #expect(model.countLabel == "0/0")
        model.query = "x"
        await model.search()
        #expect(model.hits.count == 1)
        #expect(model.focusedMessageID == nil)
        #expect(model.errorText == ThreadSearchCopy.olderMatchUnavailable)
    }
}
#endif
