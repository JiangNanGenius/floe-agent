// FloeAgentRuntimeTests — compaction degrade on small local windows.

import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeCore

@Suite("Context compaction degrade")
struct ContextCompactionDegradeTests {
    private func transcript(_ count: Int, characters: Int = 1_200) -> [ConversationMessage] {
        (0..<count).map {
            ConversationMessage(
                role: $0.isMultiple(of: 2) ? "user" : "assistant",
                content: "Turn \($0): " + String(repeating: "evidence\($0) ", count: characters / 10)
            )
        }
    }

    @Test("Tiny local window compaction fits the usable budget instead of failing")
    func tinyWindowDegrades() async throws {
        // 32K window: the summary allowance fits the whole deterministic
        // record, so a failing model summarizer must still retain historical
        // facts rather than silently dropping them.
        let policy = ContextCompressionPolicy.local(
            contextWindowTokens: 32_768,
            reservedOutputTokens: 512
        )
        let engine = HybridContextEngine(summarizer: DeterministicContextSummarizer())
        let history = transcript(30)
        let latestUserID = try #require(history.last(where: { $0.role == "user" })?.id)
        let result = try await engine.compact(CompactionRequest(
            context: ContextRequest(
                messages: history,
                budget: policy.budget,
                protection: ContextProtection(messageIDs: [latestUserID])
            ),
            force: true
        ))
        let usable = policy.budget.availableInputTokens
        #expect(result.estimatedTokens <= usable)
        #expect(result.record.beforeEstimatedTokens > result.record.afterEstimatedTokens)
        #expect(result.messages.contains { $0.id == latestUserID })
        #expect(result.messages.contains { $0.content.contains("[Context compaction notice]") })
        // Every compacted-away message is recorded; originals stay in the durable record.
        let remainingIDs = Set(result.messages.map(\.id))
        #expect(result.record.sourceMessageIDs.count > 0)
        #expect(result.record.sourceMessageIDs.allSatisfy { !remainingIDs.contains($0) })
    }

    @Test("A failing summarizer falls back instead of failing the run")
    func summarizerFailureFallsBack() async throws {
        struct Probe: Error {}
        struct Throwing: ContextSummarizer {
            func summarize(messages: [ConversationMessage], maximumCharacters: Int) async throws -> String { throw Probe() }
        }
        let policy = ContextCompressionPolicy.local(
            contextWindowTokens: 8_192,
            reservedOutputTokens: 512
        )
        let engine = HybridContextEngine(summarizer: Throwing())
        var history = transcript(24)
        // Newest-candidate position: degrade rounds drop the OLDEST
        // summarized messages first, so this fact must survive every round
        // that keeps any summary at all.
        history.insert(ConversationMessage(
            role: "user",
            content: "关键事实：部署口令是 delta-905，后续步骤都依赖它。"
        ), at: 10)
        let result = try await engine.compact(CompactionRequest(
            context: ContextRequest(messages: history, budget: policy.budget),
            force: true
        ))
        #expect(result.estimatedTokens <= policy.budget.availableInputTokens)
        #expect(result.messages.contains { $0.content.contains("[Context compaction notice]") })
        // The deterministic fallback must retain real historical content —
        // acceptance with an empty summary would silently drop every fact.
        let summaryMessage = result.messages.first {
            $0.content.contains("Historical summary:") || $0.content.contains("[Context compaction notice]")
        }
        #expect(summaryMessage?.content.contains("delta-905") == true)
    }

    @Test("Cancellation always propagates")
    func cancellationPropagates() async throws {
        struct Cancelling: ContextSummarizer {
            func summarize(messages: [ConversationMessage], maximumCharacters: Int) async throws -> String {
                throw CancellationError()
            }
        }
        let policy = ContextCompressionPolicy.local(
            contextWindowTokens: 8_192,
            reservedOutputTokens: 512
        )
        let engine = HybridContextEngine(summarizer: Cancelling())
        await #expect(throws: CancellationError.self) {
            try await engine.compact(CompactionRequest(
                context: ContextRequest(messages: transcript(24), budget: policy.budget),
                force: true
            ))
        }
    }

    @Test("Unresolved tool-pair messages survive compaction verbatim")
    func toolPairPreservation() async throws {
        let policy = ContextCompressionPolicy.local(
            contextWindowTokens: 8_192,
            reservedOutputTokens: 512
        )
        let engine = HybridContextEngine(summarizer: DeterministicContextSummarizer())
        var history = transcript(24)
        let toolMessage = ConversationMessage(role: "tool", content: "call-42 result: the exact bytes the next turn needs 0123456789")
        history.insert(toolMessage, at: 2)
        let result = try await engine.compact(CompactionRequest(
            context: ContextRequest(
                messages: history,
                budget: policy.budget,
                protection: ContextProtection(unresolvedToolPairMessageIDs: [toolMessage.id])
            ),
            force: true
        ))
        #expect(result.messages.contains { $0.id == toolMessage.id && $0.content == toolMessage.content })
    }

    @Test("Honest failure only when the fixed floor alone exceeds the window")
    func honestFailureNamesTheFixedFloor() async throws {
        // usable = 1_000 tokens while a single recent message is ~1_300
        // tokens: the protected tail always keeps at least one message, so
        // even the minimal notice cannot fit, and compaction must fail with
        // the accurate reason, not "did not reduce".
        let budget = ContextBudget(
            contextWindowTokens: 1_000,
            reservedOutputTokens: 0,
            triggerRatio: 0.5,
            targetRatio: 0.3,
            protectedTailTokens: 1_200
        )
        let engine = HybridContextEngine(summarizer: DeterministicContextSummarizer())
        let history = transcript(30, characters: 4_000)
        do {
            _ = try await engine.compact(CompactionRequest(
                context: ContextRequest(messages: history, budget: budget),
                force: true
            ))
            Issue.record("compaction should have failed honestly")
        } catch {
            #expect(error.localizedDescription.contains("protected recent messages"))
        }
    }


    // MARK: Transcript budget retention (private follow-up regression)

    @Test("Summarizer budget follows the actual window without overflow")
    func summarizerBudgetInvariant() {
        let estimator = ContextTokenEstimator()
        let cases: [(context: Int, output: Int?)] = [
            (4_096, 2_048),
            (8_192, nil),
            (32_768, nil),
            (65_536, nil),
            (65_536, 32_768),
            (1_024, nil)
        ]
        for item in cases {
            let output = CompactionSummarizerBudget.outputReserveTokens(
                contextTokens: item.context,
                configuredMaxOutputTokens: item.output
            )
            let bytes = CompactionSummarizerBudget.maximumTranscriptBytes(
                contextTokens: item.context,
                configuredMaxOutputTokens: item.output
            )
            if bytes == 0 {
                #expect(
                    output + CompactionSummarizerBudget.promptAllowanceTokens
                        >= item.context,
                    "zero budget must mean prompt + output already fill the window"
                )
                continue
            }
            let input = estimator.estimate(String(repeating: "x", count: bytes))
            #expect(
                input + output + CompactionSummarizerBudget.promptAllowanceTokens
                    <= item.context,
                "prompt + transcript + output exceeded the actual window"
            )
            #expect(input > 0)
        }
        // An explicit 4K output cap is honored; it must not be inflated to a
        // 24K summary reserve.
        #expect(CompactionSummarizerBudget.maximumTranscriptBytes(
            contextTokens: 4_096,
            configuredMaxOutputTokens: 2_048
        ) == 3_070)
        // A 64K window with a 32K output cap still sends the 90,515-byte old
        // message whole.
        #expect(CompactionSummarizerBudget.maximumTranscriptBytes(
            contextTokens: 65_536,
            configuredMaxOutputTokens: 32_768
        ) >= 90_515)
        // A 1K window cannot fit the prompt, output and input together.
        #expect(CompactionSummarizerBudget.maximumTranscriptBytes(
            contextTokens: 1_024,
            configuredMaxOutputTokens: nil
        ) == 0)
    }

    @Test("Zero summarizer budget skips the paid completion and uses deterministic")
    func zeroSummarizerBudgetSkipsPaidCompletion() async throws {
        let fact = "ZERO-BUDGET-FACT-AFTER-600=omega-9"
        let content = String(repeating: "a", count: 900) + " " + fact + " "
            + String(repeating: "b", count: 300)
        let summarizer = ModelContextSummarizer(
            complete: { _ in
                "PAID-COMPLETION-RAN " + String(repeating: "x", count: 200)
            },
            maximumInputCharacters: 0
        )
        let summary = try await summarizer.summarize(
            messages: [ConversationMessage(role: "user", content: content)],
            maximumCharacters: 2_000
        )
        #expect(!summary.contains("PAID-COMPLETION-RAN"))
        #expect(summary.contains("Structured continuation state"))
        #expect(summary.contains(fact))
    }

    @Test("Estimator byte budget avoids overflow on untrusted metadata")
    func estimatorByteBudgetOverflow() {
        let estimator = ContextTokenEstimator()
        #expect(estimator.maximumByteBudget(forTokens: Int.max) == Int.max)
        #expect(estimator.maximumByteBudget(forTokens: Int.max / 3 + 1) == Int.max)
        #expect(CompactionSummarizerBudget.maximumTranscriptBytes(
            contextTokens: Int.max,
            configuredMaxOutputTokens: nil
        ) == Int.max)
    }

    @Test("Estimator byte budget matches its token estimate")
    func estimatorByteBudgetMatchesEstimate() {
        let estimator = ContextTokenEstimator()
        for tokens in [1, 100, 1_024] {
            let bytes = estimator.maximumByteBudget(forTokens: tokens)
            #expect(estimator.estimate(String(repeating: "x", count: bytes)) <= tokens)
        }
    }

    @Test("Transcript keeps facts after the legacy 600-character cut")
    func transcriptKeepsFactAfterLegacyCut() {
        let fact = "RETENTION-FACT-AFTER-600=alpha-905"
        let tail = "TAIL-DECISION=delta-905"
        let content = String(repeating: "a", count: 900) + " " + fact + " "
            + String(repeating: "b", count: 3_000) + " " + tail
        let transcript = ModelContextSummarizer.renderTranscript(
            messages: [ConversationMessage(role: "user", content: content)],
            budget: 2_400
        )
        #expect(transcript.utf8.count <= 2_400)
        #expect(transcript.contains(fact))
        #expect(transcript.contains(tail))
        #expect(transcript.contains("bytes omitted"))
    }

    @Test("Transcript sends every candidate complete when the global budget fits")
    func transcriptSendsCompleteCandidatesWhenTheyFit() {
        let messages = (0..<4).map {
            ConversationMessage(
                role: $0.isMultiple(of: 2) ? "user" : "assistant",
                content: "turn-\($0) exact-value-\($0)"
            )
        }
        let transcript = ModelContextSummarizer.renderTranscript(messages: messages, budget: 4_000)
        for index in 0..<4 {
            #expect(transcript.contains("exact-value-\(index)"))
        }
        #expect(!transcript.contains("bytes omitted"))
        #expect(transcript.contains("[user]"))
        #expect(transcript.contains("[assistant]"))
    }

    @Test("Transcript shares the global budget across messages and preserves both ends")
    func transcriptSharesBudgetAcrossMessages() {
        let firstHead = "FIRST-HEAD=keep-early"
        let firstTail = "FIRST-TAIL=keep-late"
        let thirdHead = "THIRD-HEAD=keep-early"
        let thirdTail = "THIRD-TAIL=keep-late"
        let messages = [
            ConversationMessage(
                role: "user",
                content: firstHead + " " + String(repeating: "x", count: 8_000) + " " + firstTail
            ),
            ConversationMessage(role: "assistant", content: "SHORT-ACK=ACK-ONE"),
            ConversationMessage(
                role: "user",
                content: thirdHead + " " + String(repeating: "y", count: 8_000) + " " + thirdTail
            )
        ]
        let transcript = ModelContextSummarizer.renderTranscript(messages: messages, budget: 6_000)
        #expect(transcript.utf8.count <= 6_000)
        #expect(transcript.contains("[assistant] SHORT-ACK=ACK-ONE"))
        #expect(transcript.contains(firstHead))
        #expect(transcript.contains(firstTail))
        #expect(transcript.contains(thirdHead))
        #expect(transcript.contains(thirdTail))
    }

    @Test("Transcript budget is measured in UTF-8 bytes for CJK text")
    func transcriptBudgetIsUTF8Bytes() {
        let message = ConversationMessage(
            role: "user",
            content: String(repeating: "中文事实", count: 2_000)
        )
        let transcript = ModelContextSummarizer.renderTranscript(messages: [message], budget: 3_000)
        #expect(transcript.utf8.count <= 3_000)
        #expect(transcript.contains("中文事实"))
        #expect(transcript.contains("bytes omitted"))
    }

    @Test("Deterministic fallback keeps a fact after the legacy 420-character cut")
    func deterministicExcerptKeepsFactAfterLegacyCut() async throws {
        let fact = "DETERMINISTIC-FACT=delta-905"
        let content = String(repeating: "a", count: 900) + " " + fact + " "
            + String(repeating: "b", count: 900)
        let summary = try await DeterministicContextSummarizer().summarize(
            messages: [ConversationMessage(role: "user", content: content)],
            maximumCharacters: 2_000
        )
        #expect(summary.contains(fact))
    }

    @Test("Transcript preserves complete paragraph and code whitespace")
    func transcriptPreservesCompleteWhitespace() {
        let content = "objective line\n\n    let value = 1\n\tindented tail"
        let transcript = ModelContextSummarizer.renderTranscript(
            messages: [ConversationMessage(role: "user", content: content)],
            budget: 1_000
        )
        #expect(transcript.contains(content))
    }

    @Test("Tiny shares are marked as omitted instead of looking complete")
    func transcriptMarksTinyShares() {
        let message = ConversationMessage(
            role: "user",
            content: String(repeating: "z", count: 4_000)
        )
        for budget in [32, 64, 128] {
            let transcript = ModelContextSummarizer.renderTranscript(
                messages: [message],
                budget: budget
            )
            #expect(transcript.utf8.count <= budget)
            #expect(transcript.contains("..."))
        }
    }

    @Test("Deterministic record fits one global budget without dropping the tail section")
    func deterministicRecordFitsGlobalBudget() async throws {
        let messages = (0..<12).map { index in
            ConversationMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "message-\(index) " + String(repeating: "context ", count: 60)
                    + "tail-fact-\(index)"
            )
        }
        let summary = try await DeterministicContextSummarizer().summarize(
            messages: messages,
            maximumCharacters: 3_000
        )
        #expect(summary.count <= 3_000)
        #expect(summary.contains("tail-fact-11"))
        #expect(summary.hasPrefix("# Structured continuation state"))
    }

    @Test("Actual ModelContextSummarizer completion failure retains a fact after 600")
    func actualModelSummarizerCompletionFailureRetainsFactAfter600() async throws {
        struct Probe: Error {}
        let fact = "FALLBACK-FACT-AFTER-600=zeta-42"
        let content = String(repeating: "a", count: 900) + " " + fact + " "
            + String(repeating: "b", count: 300)
        let summarizer = ModelContextSummarizer(complete: { _ in throw Probe() })
        let summary = try await summarizer.summarize(
            messages: [ConversationMessage(role: "user", content: content)],
            maximumCharacters: 2_000
        )
        #expect(summary.contains("Structured continuation state"))
        #expect(summary.contains(fact))
    }

    @Test("A degenerate model acknowledgement falls back to the deterministic record")
    func degenerateModelSummaryFallsBack() async throws {
        let fact = "FALLBACK-FACT=epsilon-42"
        let messages = [ConversationMessage(
            role: "user",
            content: "Remember \(fact) for the rest of this task. Reply exactly: ACK."
        )]
        let summarizer = ModelContextSummarizer { _ in "ACK" }
        let summary = try await summarizer.summarize(messages: messages, maximumCharacters: 2_000)
        #expect(summary.contains("Structured continuation state"))
        #expect(summary.contains(fact))
    }

    // MARK: Observed prompt-cache context size

    @Test("Observed context includes both prompt-cache dimensions and saturates")
    func observedContextIncludesPromptCacheTokens() {
        let readOnly = UsageSnapshot(
            inputTokens: 0,
            outputTokens: 900,
            cacheReadTokens: 7_000,
            reasoningTokens: 500
        )
        #expect(HybridContextEngine.observedInputTokenCount(readOnly) == 7_000)
        let writeOnly = UsageSnapshot(inputTokens: 0, cacheWriteTokens: 6_000)
        #expect(HybridContextEngine.observedInputTokenCount(writeOnly) == 6_000)
        let combined = UsageSnapshot(
            inputTokens: 1_000,
            outputTokens: 900,
            cacheReadTokens: 7_000,
            cacheWriteTokens: 2_000,
            reasoningTokens: 500
        )
        #expect(HybridContextEngine.observedInputTokenCount(combined) == 10_000)
        let negative = UsageSnapshot(
            inputTokens: -100,
            cacheReadTokens: -50,
            cacheWriteTokens: 300
        )
        #expect(HybridContextEngine.observedInputTokenCount(negative) == 300)
        let overflow = UsageSnapshot(inputTokens: Int.max, cacheReadTokens: 1)
        #expect(HybridContextEngine.observedInputTokenCount(overflow) == Int.max)
    }

    @Test("Cache-read-only usage still triggers high-pressure compaction")
    func cacheReadOnlyUsageTriggersCompaction() async throws {
        let budget = ContextBudget(
            contextWindowTokens: 10_000,
            reservedOutputTokens: 1_000,
            triggerRatio: 0.5,
            targetRatio: 0.3,
            protectedTailTokens: 0
        )
        let history = transcript(24, characters: 300)
        let baseline = HybridContextEngine(summarizer: DeterministicContextSummarizer())
        let unprepared = try await baseline.prepareContext(for: ContextRequest(
            messages: history,
            budget: budget
        ))
        #expect(unprepared.compaction == nil)
        #expect(unprepared.estimatedInputTokens < budget.availableInputTokens / 2)

        let engine = HybridContextEngine(summarizer: DeterministicContextSummarizer())
        // The provider billed the whole prompt as a cache read and reported
        // no uncached input. This is still a full context, not an empty one.
        await engine.observeUsage(UsageSnapshot(inputTokens: 0, cacheReadTokens: 8_000))
        let prepared = try await engine.prepareContext(for: ContextRequest(
            messages: history,
            budget: budget
        ))
        #expect(prepared.compaction != nil)
        #expect(prepared.estimatedInputTokens <= budget.availableInputTokens)
    }

    @Test("Observed usage does not double-charge reserved schema and image tokens")
    func observedUsageAvoidsDoubleChargingFixedBudget() async throws {
        let budget = ContextBudget(
            contextWindowTokens: 12_000,
            reservedOutputTokens: 1_000,
            toolSchemaTokens: 6_000,
            imageTokens: 1_000,
            triggerRatio: 0.5,
            targetRatio: 0.3,
            protectedTailTokens: 0
        )
        let history = transcript(20, characters: 240)
        let estimate = ContextTokenEstimator().estimate(history)
        #expect(estimate < budget.availableInputTokens / 2)
        let engine = HybridContextEngine(summarizer: DeterministicContextSummarizer())
        // 8,600 prompt tokens include the 7,000 already reserved for schemas
        // and images; the message side is only ~1,600 and must not compact.
        await engine.observeUsage(UsageSnapshot(inputTokens: 8_600))
        let prepared = try await engine.prepareContext(for: ContextRequest(
            messages: history,
            budget: budget
        ))
        #expect(prepared.compaction == nil)
        #expect(prepared.estimatedInputTokens == estimate)
    }

    // MARK: Structured continuation contract

    private func structuredRecord(
        goal: String = "Finish the current task.",
        instructions: String = "Keep the existing budget and approval boundary.",
        progress: String = "Verified the current behavior.",
        remaining: String = "Apply the validated patch.",
        references: String = "Local/Private/example/file.swift"
    ) -> String {
        """
        ## Goal
        \(goal)
        ## Instructions
        \(instructions)
        ## Progress
        \(progress)
        ## Remaining work
        \(remaining)
        ## Exact references
        \(references)
        """
    }

    @Test("A complete structured continuation record is accepted")
    func structuredContinuationAccepted() async throws {
        let sourceID = UUID()
        let fact = "STRUCTURED-FACT=accepted-42"
        let source = [ConversationMessage(
            role: "user",
            content: "Remember \(fact) and the exact reference \(sourceID.uuidString)."
        )]
        let record = structuredRecord(
            goal: "Retain \(fact).",
            references: sourceID.uuidString
        )
        let summarizer = ModelContextSummarizer { _ in record }
        let summary = try await summarizer.summarize(messages: source, maximumCharacters: 4_000)
        #expect(summary == record)
    }

    @Test("A long answer-shaped reply is rejected even when it exceeds 32 characters")
    func longReplyFallsBackDespiteLength() async throws {
        let fact = "LONG-REPLY-FACT=delta-42"
        let source = [ConversationMessage(
            role: "user",
            content: "Remember \(fact) for the rest of this task."
        )]
        let reply = "I understand the task. " + String(
            repeating: "I will remember the conversation and continue without restarting. ",
            count: 8
        )
        #expect(reply.count > 32)
        #expect(!reply.contains("## "))
        let summarizer = ModelContextSummarizer { _ in reply }
        let summary = try await summarizer.summarize(messages: source, maximumCharacters: 4_000)
        #expect(summary.contains("Structured continuation state"))
        #expect(summary.contains(fact))
    }

    @Test("Incomplete or malformed structured records fall back")
    func malformedStructuredRecordsFallBack() async throws {
        let fact = "MALFORMED-FACT=theta-42"
        let source = [ConversationMessage(
            role: "user",
            content: "Remember \(fact) for the rest of this task."
        )]
        let outOfOrder = """
        ## Goal
        Finish the task.
        ## Progress
        Verified the behavior.
        ## Instructions
        Keep the gate.
        ## Remaining work
        Apply the patch.
        ## Exact references
        Local/Private/example/file.swift
        """
        let missingSection = """
        ## Goal
        Finish the task.
        ## Instructions
        Keep the gate.
        ## Progress
        Verified the behavior.
        ## Remaining work
        Apply the patch.
        """
        let cases: [(String, String)] = [
            ("empty section", structuredRecord(progress: "")),
            ("missing section", missingSection),
            ("out-of-order sections", outOfOrder),
            ("unknown heading", structuredRecord() + "\n## Notes\nnot part of the contract"),
            ("duplicate heading", structuredRecord() + "\n## Goal\nduplicate"),
            ("preamble", "Here is the continuation record:\n" + structuredRecord())
        ]
        for (label, record) in cases {
            let summarizer = ModelContextSummarizer { _ in record }
            let summary = try await summarizer.summarize(
                messages: source,
                maximumCharacters: 4_000
            )
            #expect(summary.contains("Structured continuation state"), "\(label)")
            #expect(summary.contains(fact), "\(label)")
        }
    }

    @Test("An oversized structured record falls back instead of being prefix-truncated")
    func oversizedStructuredRecordFallsBack() async throws {
        let fact = "OVERSIZE-FACT=iota-42"
        let source = [ConversationMessage(
            role: "user",
            content: "Remember \(fact) for the rest of this task."
        )]
        let record = structuredRecord(
            progress: String(repeating: "progress line ", count: 200),
            remaining: "Apply the patch after review."
        )
        #expect(record.count > 600)
        let summarizer = ModelContextSummarizer { _ in record }
        let summary = try await summarizer.summarize(messages: source, maximumCharacters: 600)
        #expect(summary.count <= 600)
        #expect(summary.contains("Structured continuation state"))
        #expect(!summary.hasPrefix("## Goal"))
        #expect(summary.contains(fact))
    }

    @Test("An invented UUID-like exact reference falls back")
    func inventedUUIDReferenceFallsBack() async throws {
        let sourceID = UUID()
        let inventedID = UUID()
        let fact = "REFERENCE-FACT=eta-42"
        let source = [ConversationMessage(
            role: "user",
            content: "Keep \(sourceID.uuidString) and remember \(fact)."
        )]
        let malformedID = "123456789-abc-42dd-9686-4e5735dc9fa7"
        let records = [
            structuredRecord(
                goal: "Keep the exact source reference.",
                references: inventedID.uuidString
            ),
            structuredRecord(
                goal: "Keep the exact source reference.",
                references: malformedID
            )
        ]
        #expect(!source[0].content.contains(inventedID.uuidString))
        #expect(!source[0].content.contains(malformedID))
        for (index, record) in records.enumerated() {
            let summarizer = ModelContextSummarizer { _ in record }
            let summary = try await summarizer.summarize(
                messages: source,
                maximumCharacters: 4_000
            )
            #expect(summary.contains("Structured continuation state"), "reference \(index)")
            #expect(summary.contains(sourceID.uuidString), "reference \(index)")
            #expect(summary.contains(fact), "reference \(index)")
        }
    }
}
