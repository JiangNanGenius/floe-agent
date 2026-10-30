// FloeAgentRuntimeTests — Model-backed semantic compaction (G1).

import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeCore

@Suite("Model context summarizer")
struct ModelContextSummarizerTests {
    private func messages(_ count: Int) -> [ConversationMessage] {
        (0..<count).map { ConversationMessage(role: $0.isMultiple(of: 2) ? "user" : "assistant", content: "Turn \($0): decided to keep option \($0) because evidence file r\($0).txt proved it.") }
    }

    @Test func modelSummaryIsUsedWhenTheCompletionSucceeds() async throws {
        let record = """
        ## Goal
        ship 1.6.3.
        ## Instructions
        Keep the existing release gate.
        ## Progress
        Verified: engine green.
        ## Remaining work
        Tag the release.
        ## Exact references
        r3.txt
        """
        let summarizer = ModelContextSummarizer { prompt in
            // The prompt must carry the preservation contract and transcript.
            #expect(prompt.contains("Preserve exactly"))
            #expect(prompt.contains("## Exact references"))
            #expect(prompt.contains("Turn 3"))
            return record
        }
        let summary = try await summarizer.summarize(messages: messages(8), maximumCharacters: 4_000)
        #expect(summary == record)
        #expect(summary.contains("ship 1.6.3"))
    }

    @Test func completionFailureFallsBackToDeterministic() async throws {
        struct Probe: Error {}
        let summarizer = ModelContextSummarizer { _ in throw Probe() }
        let summary = try await summarizer.summarize(messages: messages(8), maximumCharacters: 4_000)
        // The deterministic structured record takes over; compaction survives.
        #expect(summary.contains("Structured continuation state"))
    }

    @Test func emptyCompletionFallsBackToDeterministic() async throws {
        let summarizer = ModelContextSummarizer { _ in "   " }
        let summary = try await summarizer.summarize(messages: messages(8), maximumCharacters: 4_000)
        #expect(summary.contains("Structured continuation state"))
    }

    @Test func outputAndInputAreBounded() async throws {
        let oversized = """
        ## Goal
        Ship the release.
        ## Instructions
        Keep the existing gate.
        ## Progress
        \(String(repeating: "x", count: 10_000))
        ## Remaining work
        Tag the release.
        ## Exact references
        r3.txt
        """
        let summarizer = ModelContextSummarizer(complete: { prompt in
            #expect(prompt.utf8.count < 8_000)
            return oversized
        }, maximumInputCharacters: 2_000)
        let summary = try await summarizer.summarize(messages: messages(400), maximumCharacters: 500)
        #expect(summary.count <= 500)
        #expect(summary.contains("Structured continuation state"))
    }
}
