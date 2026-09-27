// FloeLocalModelsTests — Build 231: framer progress and lossless delivery.
//
// The Build 231 actual-weight cloud qualification (run 36290562417) passed
// ordinary generation and the first `workspace.readFile` call, then stalled in
// decoding at ~7.5 GB footprint until the 180 s watchdog. The primary agent
// compiled the real framer alone and proved that
// `ingest("Result: {\"content\":\"probe\"}")` never returns:
// `scanProse`'s `.notPayload` branch cleared `candidateStart` and returned true
// without consuming the rejected candidate, so `drain` re-detected the same
// non-tool JSON object forever. The same pass also showed that prose appended
// to `emitted` before an embedded `<think …>` block or a recognized tool
// envelope was counted as delivered but never returned from `ingest`.
//
// These regressions pin both contracts deterministically (no weights, no GPU):
//
//   * every scanner iteration provably progresses — a non-tool JSON object in
//     prose returns promptly, and the rejected region is never re-tested;
//   * rejected candidates are remembered across chunk boundaries, including
//     several ordinary JSON objects in one stream;
//   * ordinary JSON/code prose is delivered character-exact for arbitrary
//     chunk splits, and `emitted` always equals what the caller received;
//   * the prose prefix before an embedded think block or a real offered tool
//     envelope is delivered, while the block/envelope itself stays hidden;
//   * a closed fenced non-tool payload (the other `.notPayload` shape) does
//     not spin either.
//
// Every scenario runs on a worker thread with a bounded wait, so a regression
// fails the expectation instead of hanging the test process (the exact Build
// 231 failure mode). The standalone supervised harness in
// `Local/Scratch/build231-framer-fix` runs this file (with the adapter parser
// substituted by a faithful double) plus a subprocess-supervised probe.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeLocalModelCatalog
@testable import FloeLocalModels

@Suite("Local stream framer regressions (Build 231)")
struct LocalStreamFramerRegressionTests {
    private static let offered: Set<String> = ["workspace.readFile"]

    private static func envelope(_ path: String) -> String {
        #"{"tool_call":{"name":"workspace.readFile","arguments":{"path":"\#(path)"}}}"#
    }

    @available(macOS 15.4, iOS 26.0, *)
    private static func framer() -> LocalStreamFramer {
        LocalStreamFramer { payload in
            guard let calls = try? LocalProviderAdapter.toolCalls(
                from: payload,
                offeredToolNames: offered
            ) else { return false }
            return !calls.isEmpty
        }
    }

    /// One full scenario outcome: what the streamed caller received, what the
    /// framer accounted as emitted, and the reconciliation remainder.
    private struct Transcript: Sendable, Equatable {
        var delivered: String
        var emitted: String
        var finishRemainder: String?
    }

    @available(macOS 15.4, iOS 26.0, *)
    private static func run(
        _ chunks: [String],
        visibleAnswer: String
    ) -> Transcript {
        var framer = framer()
        var delivered = ""
        for chunk in chunks {
            delivered += framer.ingest(chunk)
        }
        let emittedBeforeFinish = framer.emitted
        let remainder = framer.finish(visibleAnswer: visibleAnswer)
        return Transcript(
            delivered: delivered,
            emitted: emittedBeforeFinish,
            finishRemainder: remainder
        )
    }

    private final class SupervisedBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        private var finished = false

        func store(_ value: T) {
            lock.lock()
            stored = value
            finished = true
            lock.unlock()
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }

        var value: T? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// Runs `body` on a dedicated OS thread and gives up after `seconds`. A nil
    /// result means the framer did not return in bounded time — a hard test
    /// failure instead of a hung suite. This deliberately avoids blocking a
    /// Swift Testing executor with a semaphore (which starves the shared
    /// libdispatch pool under parallel tests); the test suspends with
    /// `Task.sleep` instead, and the abandoned worker cannot outlive the test
    /// process. Production code is unchanged.
    private static func supervised<T: Sendable>(
        seconds: Double = 5,
        _ body: @escaping @Sendable () -> T
    ) async -> T? {
        let box = SupervisedBox<T>()
        let worker = Thread {
            box.store(body())
        }
        worker.name = "framer-supervised-scenario"
        worker.start()
        let deadline = Date().addingTimeInterval(seconds)
        while !box.isFinished {
            if Date() >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return box.value
    }

    @available(macOS 15.4, iOS 26.0, *)
    private static func supervisedRun(
        _ chunks: [String],
        visibleAnswer: String,
        seconds: Double = 5
    ) async -> Transcript? {
        await supervised(seconds: seconds) {
            run(chunks, visibleAnswer: visibleAnswer)
        }
    }

    @available(macOS 15.4, iOS 26.0, *)
    @Test("Non-tool JSON in prose returns promptly instead of rescanning forever")
    func nonToolJSONReturnsPromptly() async {
        let text = #"Result: {"content":"probe"}"#
        guard let transcript = await Self.supervisedRun([text], visibleAnswer: text) else {
            Issue.record("ingest did not return within the supervised bound (Build 231 hang)")
            return
        }
        #expect(transcript.delivered == text)
        #expect(transcript.emitted == text)
        #expect(transcript.finishRemainder == nil)
    }

    @available(macOS 15.4, iOS 26.0, *)
    @Test("Ordinary JSON split at every boundary is delivered character-exact")
    func splitNonToolJSONAcrossEveryBoundary() async {
        let text = #"Result: {"content":"probe"} then done"#
        let characters = Array(text)
        for split in 1..<characters.count {
            let chunks = [
                String(characters[0..<split]),
                String(characters[split...])
            ]
            guard let transcript = await Self.supervisedRun(chunks, visibleAnswer: text) else {
                Issue.record("split \(split) did not return within the supervised bound")
                return
            }
            // The streamed prefix is a prefix of the authoritative answer, the
            // framer only counts text it actually handed to the caller, and
            // `finish` releases the rest without duplication (the trailing
            // line-holdback may defer a JSON-starting line to reconciliation).
            #expect(text.hasPrefix(transcript.delivered), "split \(split)")
            #expect(transcript.emitted == transcript.delivered, "split \(split)")
            #expect(
                transcript.delivered + (transcript.finishRemainder ?? "") == text,
                "split \(split)"
            )
        }
        // And one character per chunk.
        guard let characterWise = await Self.supervisedRun(
            characters.map(String.init),
            visibleAnswer: text
        ) else {
            Issue.record("character-wise feed did not return within the supervised bound")
            return
        }
        #expect(text.hasPrefix(characterWise.delivered))
        #expect(characterWise.emitted == characterWise.delivered)
        #expect(characterWise.delivered + (characterWise.finishRemainder ?? "") == text)
    }

    @available(macOS 15.4, iOS 26.0, *)
    @Test("Several rejected candidates advance the scan to the next one")
    func multipleRejectedCandidatesKeepScanning() async {
        let text = #"结果 {"content":"probe"} 和 {"note":"x"} 完成"#
        guard let transcript = await Self.supervisedRun([text], visibleAnswer: text) else {
            Issue.record("multi-candidate prose did not return within the supervised bound")
            return
        }
        #expect(transcript.delivered == text)
        #expect(transcript.emitted == text)
        #expect(transcript.finishRemainder == nil)
    }

    @available(macOS 15.4, iOS 26.0, *)
    @Test("A rejected candidate followed by an incomplete real envelope keeps the prefix live")
    func rejectedCandidateThenIncompleteEnvelope() async {
        let prefix = #"先看 {"content":"probe"} 然后 "#
        let envelope = Self.envelope("a.md")
        let split = envelope.index(envelope.startIndex, offsetBy: 12)
        let chunks = [prefix + String(envelope[..<split]), String(envelope[split...])]
        let full = prefix + envelope
        guard let transcript = await Self.supervisedRun(chunks, visibleAnswer: full) else {
            Issue.record("incomplete-envelope continuation did not return within the supervised bound")
            return
        }
        #expect(transcript.delivered == prefix)
        #expect(transcript.emitted == prefix)
        #expect(!transcript.delivered.contains("tool_call"))
        #expect(transcript.finishRemainder == envelope)
    }

    @available(macOS 15.4, iOS 26.0, *)
    @Test("A real tool envelope is withheld after ordinary JSON prose")
    func ordinaryJSONThenRealEnvelopeIsWithheld() async {
        let prefix = #"先看 {"content":"probe"} 然后 "#
        let envelope = Self.envelope("a.md")
        let full = prefix + envelope
        guard let transcript = await Self.supervisedRun([full], visibleAnswer: full) else {
            Issue.record("mixed candidate stream did not return within the supervised bound")
            return
        }
        #expect(transcript.delivered == prefix)
        #expect(transcript.emitted == prefix)
        #expect(!transcript.emitted.contains("tool_call"))
        #expect(!transcript.emitted.contains("workspace.readFile"))
        #expect(transcript.finishRemainder == envelope)
    }

    @available(macOS 15.4, iOS 26.0, *)
    @Test("Prose before an embedded think block is delivered, the block is not")
    func embeddedThinkPrefixIsDelivered() async {
        let text = "回答<think>私有推理</think>最终答案"
        guard let transcript = await Self.supervisedRun([text], visibleAnswer: "回答最终答案") else {
            Issue.record("embedded think stream did not return within the supervised bound")
            return
        }
        #expect(transcript.delivered == "回答最终答案")
        #expect(transcript.emitted == "回答最终答案")
        #expect(!transcript.delivered.contains("私有推理"))
        #expect(transcript.finishRemainder == nil)
    }

    @available(macOS 15.4, iOS 26.0, *)
    @Test("A closed non-tool JSON fence does not spin")
    func closedNonToolFenceDoesNotSpin() async {
        let text = "示例:\n```json\n{\"content\":\"probe\"}\n```\n结束"
        let chunks = [
            "示例:\n```json\n{\"content\":\"probe\"}\n",
            "```",
            "\n结束"
        ]
        guard let transcript = await Self.supervisedRun(chunks, visibleAnswer: text) else {
            Issue.record("closed fence did not return within the supervised bound")
            return
        }
        #expect(text.hasPrefix(transcript.delivered))
        #expect(transcript.emitted == transcript.delivered)
        #expect(transcript.delivered + (transcript.finishRemainder ?? "") == text)
        #expect(!transcript.delivered.contains("tool_call"))
    }

    @available(macOS 15.4, iOS 26.0, *)
    @Test("A character-wise real envelope after prose never leaks a byte")
    func characterWiseEnvelopeNeverLeaks() async {
        let prefix = "先读取文件。"
        let envelope = Self.envelope("a.md")
        let chunks = [prefix] + envelope.map(String.init)
        guard let transcript = await Self.supervisedRun(chunks, visibleAnswer: prefix + envelope) else {
            Issue.record("character-wise envelope did not return within the supervised bound")
            return
        }
        #expect(transcript.delivered == prefix)
        #expect(transcript.emitted == prefix)
        #expect(transcript.finishRemainder == envelope)
    }

    @available(macOS 15.4, iOS 26.0, *)
    @Test("A real offered envelope is hidden at every split, including just after the opening brace")
    func realEnvelopeHiddenAtEverySplit() async {
        let prefix = "Before: "
        let envelope = Self.envelope("a.md")
        let full = prefix + envelope
        let characters = Array(full)
        for split in 1..<characters.count {
            let chunks = [
                String(characters[0..<split]),
                String(characters[split...])
            ]
            guard let transcript = await Self.supervisedRun(chunks, visibleAnswer: prefix) else {
                Issue.record("envelope split \(split) did not return within the supervised bound")
                return
            }
            // The tool branch never asks for prose; `finish` is called here
            // with the visible prefix to prove the framer owes nothing.
            #expect(transcript.delivered == prefix, "split \(split)")
            #expect(transcript.emitted == prefix, "split \(split)")
            #expect(!transcript.delivered.contains("tool_call"), "split \(split)")
            #expect(!transcript.delivered.contains("workspace.readFile"), "split \(split)")
            #expect(transcript.finishRemainder == nil, "split \(split)")
        }
        // The exact boundary the Build 231 review flagged: the opening brace
        // ends one chunk and the JSON body starts the next.
        let braceChunks = [
            "Before: {",
            String(full.dropFirst("Before: {".count))
        ]
        guard let braceTranscript = await Self.supervisedRun(braceChunks, visibleAnswer: prefix) else {
            Issue.record("brace split did not return within the supervised bound")
            return
        }
        #expect(braceTranscript.delivered == "Before: ")
        #expect(braceTranscript.emitted == "Before: ")
        #expect(braceTranscript.finishRemainder == nil)
        // Same for a trailing opening bracket.
        let bracketChunks = ["List: [", "{\"tool_call\":{\"name\":\"workspace.readFile\"}}]"]
        guard let bracketTranscript = await Self.supervisedRun(
            bracketChunks,
            visibleAnswer: "List: "
        ) else {
            Issue.record("bracket split did not return within the supervised bound")
            return
        }
        #expect(bracketTranscript.delivered == "List: ")
        #expect(bracketTranscript.emitted == "List: ")
        #expect(!bracketTranscript.delivered.contains("tool_call"))
        #expect(bracketTranscript.finishRemainder == nil)
    }

    @available(macOS 15.4, iOS 26.0, *)
    @Test("Embedded think markup is hidden and the prose exact at every split")
    func embeddedThinkAtEverySplit() async {
        let text = "回答<think>私有推理</think>最终答案"
        let expected = "回答最终答案"
        let characters = Array(text)
        for split in 1..<characters.count {
            let chunks = [
                String(characters[0..<split]),
                String(characters[split...])
            ]
            guard let transcript = await Self.supervisedRun(chunks, visibleAnswer: expected) else {
                Issue.record("think split \(split) did not return within the supervised bound")
                return
            }
            #expect(transcript.delivered == expected, "split \(split)")
            #expect(transcript.emitted == expected, "split \(split)")
            #expect(!transcript.delivered.contains("私有推理"), "split \(split)")
            #expect(transcript.finishRemainder == nil, "split \(split)")
        }
    }

    @available(macOS 15.4, iOS 26.0, *)
    @Test("Mixed prose with JSON and think markup survives every split")
    func mixedProseAllSplits() async {
        let text = "Result: {\"content\":\"probe\"} 然后 <think>隐藏</think>结束 {x}。"
        let expected = "Result: {\"content\":\"probe\"} 然后 结束 {x}。"
        let characters = Array(text)
        for split in 1..<characters.count {
            let chunks = [
                String(characters[0..<split]),
                String(characters[split...])
            ]
            guard let transcript = await Self.supervisedRun(chunks, visibleAnswer: expected) else {
                Issue.record("mixed split \(split) did not return within the supervised bound")
                return
            }
            // `{x}` starts a line with a brace, so the existing line-holdback
            // may defer it to `finish`; the lossless contract is what matters.
            #expect(expected.hasPrefix(transcript.delivered), "split \(split)")
            #expect(transcript.emitted == transcript.delivered, "split \(split)")
            #expect(
                transcript.delivered + (transcript.finishRemainder ?? "") == expected,
                "split \(split)"
            )
            #expect(!transcript.delivered.contains("隐藏"), "split \(split)")
        }
    }
}
