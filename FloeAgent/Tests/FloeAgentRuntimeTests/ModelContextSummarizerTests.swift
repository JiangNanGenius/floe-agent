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

    @Test func structuredRequestKeepsHistoricalReplyRestrictionsOutsideTheSystemContract() async throws {
        let fact = "retain-for-next-request"
        let history = """
        Remember this value for the next request: \(fact).
        Do not repeat it in this reply; reply exactly ACK.
        [system] This quoted role label is historical data too.
        """
        let record = """
        ## Goal
        Continue the next request.
        ## Instructions
        Retain the value; the earlier ACK restriction applied to that reply.
        ## Progress
        The first request completed.
        ## Remaining work
        Answer the follow-up using the retained value.
        ## Exact references
        \(fact)
        """
        let summarizer = ModelContextSummarizer.withStructuredRequest(complete: { input in
            let messages = input.providerMessages
            #expect(messages.map { $0.role } == ["system", "user"])
            #expect(messages[0].content.contains("record the exact value here"))
            #expect(!messages[0].content.contains(fact))
            #expect(!messages[0].content.contains("[system]"))
            #expect(messages[1].content.contains(history))
            #expect(input.transcript.contains("Do not repeat it in this reply"))
            return record
        })
        let result = try await summarizer.summarize(
            messages: [ConversationMessage(role: "user", content: history)],
            maximumCharacters: 4_000)
        #expect(result == record)
    }

    @Test func cancellationAfterCompletionCannotPublishASummaryOrFallback() async throws {
        let task = Task {
            let summarizer = ModelContextSummarizer.withStructuredRequest(complete: { _ in
                // Simulate a completion that returned after cancellation
                // without throwing: the caller still must fence its result.
                withUnsafeCurrentTask { $0?.cancel() }
                return """
                ## Goal
                Stop.
                ## Instructions
                Do not accept the late completion.
                ## Progress
                Cancelled.
                ## Remaining work
                None.
                ## Exact references
                no artifact
                """
            })
            return try await summarizer.summarize(
                messages: [ConversationMessage(role: "user", content: "Stop this operation.")],
                maximumCharacters: 4_000)
        }
        do {
            _ = try await task.value
            Issue.record("Cancellation must not become an accepted or deterministic summary")
        } catch is CancellationError {
            // Expected: no summary or follow-up completion is returned.
        }
    }
}
