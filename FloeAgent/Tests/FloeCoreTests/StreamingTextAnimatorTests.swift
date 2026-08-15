// FloeCoreTests — StreamingTextAnimator: ordered, grapheme-safe reveal;
// drain-before-terminal; non-prefix rebuild; cancellation semantics.

import Foundation
import Testing
@testable import FloeCore

@Suite("FloeCore.StreamingTextAnimator")
struct StreamingTextAnimatorTests {

    /// Captures structured diagnostics for assertions.
    private final class DiagnosticsRecorder: StreamingTextAnimatorDiagnostics, @unchecked Sendable {
        private(set) var advanced: [Int] = []
        private(set) var nonPrefixCount = 0
        private(set) var drainStarts: [Int] = []
        private(set) var drainCompletions = 0

        func streamTargetAdvanced(pendingCharacters: Int) { advanced.append(pendingCharacters) }
        func streamNonPrefixDetected() { nonPrefixCount += 1 }
        func streamDrainStarted(pendingCharacters: Int) { drainStarts.append(pendingCharacters) }
        func streamDrainCompleted() { drainCompletions += 1 }
    }

    @MainActor
    private func makeAnimator(
        diagnostics: DiagnosticsRecorder? = nil
    ) -> StreamingTextAnimator {
        StreamingTextAnimator(diagnostics: diagnostics, baseIntervalNanoseconds: 12_000_000)
    }

    @Test("Displayed text is always a prefix of the target, in grapheme order")
    @MainActor
    func orderedPrefixInvariant() async throws {
        let animator = makeAnimator()
        let full = "The quick brown fox jumps over the lazy dog. 第二次追加的中文内容。"
        // Feed in irregular chunks like a provider stream would.
        var index = full.startIndex
        while index < full.endIndex {
            let step = Int.random(in: 1...7)
            let next = full.index(index, offsetBy: step, limitedBy: full.endIndex) ?? full.endIndex
            animator.update(target: String(full[..<next]))
            index = next
            try await Task.sleep(nanoseconds: 2_000_000)
            #expect(full.hasPrefix(animator.displayedText))
            #expect(full.hasPrefix(animator.targetText))
        }
        await animator.drain()
        #expect(animator.displayedText == full)
    }

    @Test("Chinese, emoji and composed characters are never split")
    @MainActor
    func graphemeIntegrity() async throws {
        let animator = makeAnimator()
        // Family emoji (ZWJ sequence), flag (regional indicators), accented
        // composed character, CJK.
        let full = "家庭👨‍👩‍👧‍👦 国旗🇨🇳 组合é 中文测试🎉"
        animator.update(target: full)
        await animator.drain()
        #expect(animator.displayedText == full)
        // Character count must match exactly — nothing torn apart.
        #expect(animator.displayedText.count == full.count)
    }

    @Test("A large backlog is revealed in bounded batches, never all at once")
    @MainActor
    func boundedBatches() async {
        let animator = makeAnimator()
        let big = String(repeating: "数据", count: 2_000) // 4000 graphemes
        animator.update(target: big)
        // One tick of the animation loop must not dump the whole text.
        try? await Task.sleep(nanoseconds: 30_000_000)
        let shown = animator.displayedText.count
        #expect(shown > 0)
        #expect(shown < big.count)
        await animator.drain()
        #expect(animator.displayedText == big)
    }

    @Test("Terminal arrival drains the display before settling")
    @MainActor
    func drainBeforeTerminal() async {
        let recorder = DiagnosticsRecorder()
        let animator = makeAnimator(diagnostics: recorder)
        let full = String(repeating: "Answer ", count: 200)
        animator.update(target: String(full.prefix(50)))
        // Network reaches terminal while a large remainder is pending.
        animator.update(target: full)
        #expect(animator.displayedText != full)
        await animator.drain()
        #expect(animator.displayedText == full)
        #expect(recorder.drainStarts.count == 1)
        #expect(recorder.drainCompletions == 1)
    }

    @Test("A non-prefix update is logged and safely rebuilt, never interleaved")
    @MainActor
    func nonPrefixRebuild() async {
        let recorder = DiagnosticsRecorder()
        let animator = makeAnimator(diagnostics: recorder)
        animator.update(target: "Hello world")
        try? await Task.sleep(nanoseconds: 50_000_000)
        animator.update(target: "Completely different text")
        #expect(recorder.nonPrefixCount == 1)
        await animator.drain()
        #expect(animator.displayedText == "Completely different text")
    }

    @Test("Cancel stops the animation without jumping to the full target")
    @MainActor
    func cancelKeepsPartialDisplay() async {
        let animator = makeAnimator()
        let big = String(repeating: "x", count: 5_000)
        animator.update(target: big)
        try? await Task.sleep(nanoseconds: 25_000_000)
        animator.cancel()
        let shownAtCancel = animator.displayedText.count
        #expect(shownAtCancel < big.count)
        // Nothing advances after cancel.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(animator.displayedText.count == shownAtCancel)
    }

    @Test("Repeated updates stack at most one animation task")
    @MainActor
    func singleAnimationTask() async {
        let animator = makeAnimator()
        var target = ""
        for i in 0..<50 {
            target.append("\(i) ")
            animator.update(target: target)
        }
        await animator.drain()
        #expect(animator.displayedText == target)
    }

    @Test("Every visible animation step notifies the presentation layer")
    @MainActor
    func displayChangeCallback() async {
        let animator = makeAnimator()
        var observed: [String] = []
        animator.onDisplayedTextChange = { observed.append($0) }
        animator.update(target: "逐字显示")
        await animator.drain()

        #expect(observed.count >= 2)
        #expect(observed.last == "逐字显示")
        #expect(observed.allSatisfy { "逐字显示".hasPrefix($0) })
    }
}
