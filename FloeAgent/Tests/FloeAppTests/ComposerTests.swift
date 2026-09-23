// FloeAppTests — Composer editing contract.
//
// Pins the Part-10 multi-line/full-edit behavior at the pure decision
// layer: draft-store revision semantics (stale async writes rejected),
// 100k round-trip fidelity, per-conversation isolation, the Cmd+Return /
// IME send policy, the line + one-third-height growth budget, the measured
// height memo, the rough token estimate and the failed-send full-text
// restore. Device feel (dynamic type, split, rotation, keyboard) remains
// user acceptance on a real device.

#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import FloeApp

private func makeTempDraftURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("composer-tests-\(UUID().uuidString).json")
}

@Suite("FloeApp.ComposerDraftStore")
@MainActor
struct ComposerDraftStoreTests {

    @Test("A 100k-character draft round-trips exactly through the store")
    func largeDraftRoundTrip() {
        let url = makeTempDraftURL()
        let id = UUID()
        let store = ComposerDraftStore(fileURL: url)
        let longText = String(repeating: "中文字符与English mix，无空格长串aaaaaaaaaaaaaaaaaaaaaaaa。",
                              count: 2_000) // ~100k scalars
        #expect(longText.count > 90_000)
        let revision = store.save(text: longText, conversationID: id)
        #expect(revision == 1)
        store.flush()

        let reloaded = ComposerDraftStore(fileURL: url)
        let restored = reloaded.entry(for: id)?.text ?? ""
        #expect(restored == longText)
        #expect(restored.count == longText.count)
        try? FileManager.default.removeItem(at: url)
    }

    @Test("Drafts are isolated per conversation and clear independently")
    func sessionIsolation() {
        let store = ComposerDraftStore(fileURL: makeTempDraftURL())
        let first = UUID(), second = UUID()
        store.save(text: "第一条草稿", conversationID: first)
        store.save(text: "second draft", conversationID: second)
        #expect(store.text(for: first) == "第一条草稿")
        #expect(store.text(for: second) == "second draft")
        store.clear(conversationID: first)
        #expect(store.text(for: first).isEmpty)
        #expect(store.text(for: second) == "second draft")
    }

    @Test("A stale expected revision is rejected and newer text survives")
    func staleWriteRejected() {
        let store = ComposerDraftStore(fileURL: makeTempDraftURL())
        let id = UUID()
        guard let first = store.save(text: "用户正在输入", conversationID: id) else {
            Issue.record("First save must return a revision")
            return
        }
        #expect(first == 1)
        // Voice transcript lands with the revision captured before the user
        // typed — it must not clobber the newer draft.
        let stale = store.save(
            text: "旧转写", conversationID: id, expectedRevision: first - 1
        )
        #expect(stale == nil)
        #expect(store.text(for: id) == "用户正在输入")
        // The matching revision still works.
        let current = store.save(
            text: "用户正在输入更多", conversationID: id, expectedRevision: first
        )
        #expect(current == 2)
        #expect(store.text(for: id) == "用户正在输入更多")
    }

    @Test("Selection updates do not bump the draft revision")
    func selectionDoesNotBumpRevision() {
        let store = ComposerDraftStore(fileURL: makeTempDraftURL())
        let id = UUID()
        let revision = store.save(text: "hello", conversationID: id)
        store.updateSelection(NSRange(location: 5, length: 0), conversationID: id)
        store.updateSelection(NSRange(location: 2, length: 3), conversationID: id)
        #expect(store.entry(for: id)?.revision == revision)
        #expect(store.entry(for: id)?.selectionLocation == 2)
        #expect(store.entry(for: id)?.selectionLength == 3)
    }

    @Test("Flush persists the latest snapshot for background/relaunch")
    func flushPersistsLatest() {
        let url = makeTempDraftURL()
        let store = ComposerDraftStore(fileURL: url)
        let id = UUID()
        store.save(text: "最新内容", conversationID: id)
        store.flush()
        let reloaded = ComposerDraftStore(fileURL: url)
        #expect(reloaded.text(for: id) == "最新内容")
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite("FloeApp.ComposerEditingPrimitives")
@MainActor
struct ComposerEditingPrimitivesTests {

    @Test("Cmd+Return sends only when allowed and no marked text is pending")
    func commandReturnPolicy() {
        #expect(ComposerSendKeyPolicy.commandReturnSends(canSend: true, hasMarkedText: false))
        // Marked (unconfirmed IME) text always blocks the send.
        #expect(!ComposerSendKeyPolicy.commandReturnSends(canSend: true, hasMarkedText: true))
        // A disabled send never fires.
        #expect(!ComposerSendKeyPolicy.commandReturnSends(canSend: false, hasMarkedText: false))
    }

    @Test("Line cap is 6 lines on compact widths and 8 on regular")
    func lineCapBySizeClass() {
        #expect(ComposerFieldMetrics.lineCap(horizontalSizeClass: .compact) == 6)
        #expect(ComposerFieldMetrics.lineCap(horizontalSizeClass: .regular) == 8)
        #expect(ComposerFieldMetrics.lineCap(horizontalSizeClass: .unspecified) == 6)
    }

    @Test("Height cap never exceeds one third of the available height")
    func heightCapBudget() {
        let lineCap: CGFloat = 300
        #expect(ComposerFieldMetrics.heightCap(lineCapHeight: lineCap, availableHeight: 900) == 300)
        #expect(ComposerFieldMetrics.heightCap(lineCapHeight: lineCap, availableHeight: 600) == 200)
        #expect(ComposerFieldMetrics.heightCap(lineCapHeight: lineCap, availableHeight: nil) == 300)
        #expect(ComposerFieldMetrics.heightCap(lineCapHeight: lineCap, availableHeight: 0) == 300)
    }

    @Test("The height memo recomputes only on generation, width or category change")
    func heightMemo() {
        var memo = ComposerFieldMetrics.HeightCache()
        var computations = 0
        let compute = { computations += 1; return CGFloat(120) }
        let first = memo.value(
            generation: 1, width: 320,
            contentSizeCategory: .large, compute: compute)
        let second = memo.value(
            generation: 1, width: 320,
            contentSizeCategory: .large, compute: compute)
        #expect(first == 120)
        #expect(second == 120)
        #expect(computations == 1)
        _ = memo.value(
            generation: 2, width: 320,
            contentSizeCategory: .large, compute: compute)
        _ = memo.value(
            generation: 2, width: 640,
            contentSizeCategory: .large, compute: compute)
        _ = memo.value(
            generation: 2, width: 640,
            contentSizeCategory: .accessibilityMedium, compute: compute)
        #expect(computations == 4)
    }

    @Test("Token estimate separates CJK and Latin scalars and stays positive")
    func tokenEstimate() {
        #expect(ComposerTokenEstimator.estimatedTokens(in: "") == 0)
        // 4 CJK scalars ≈ 4 tokens.
        #expect(ComposerTokenEstimator.estimatedTokens(in: "中文输入") == 4)
        // 12 Latin scalars ≈ 3 tokens.
        #expect(ComposerTokenEstimator.estimatedTokens(in: "hello world!") == 3)
        let mixed = ComposerTokenEstimator.estimatedTokens(in: "中文abc")
        #expect(mixed >= 3)
    }

    @Test("A failed send restores the full original draft, never a trimmed copy")
    func sendFailureKeepsFullText() {
        let original = "  开头的空白和结尾的空白都要保留  \n全文一行都不能少"
        let goal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(ComposerDraftSafety.draftAfterSendFailure(
            originalDraft: original, trimmedGoal: goal, currentDraft: "") == original)
        // Text typed while the send was in flight wins over the restore.
        #expect(ComposerDraftSafety.draftAfterSendFailure(
            originalDraft: original, trimmedGoal: goal, currentDraft: "新输入") == "新输入")
        // Defensive fallback when both are empty.
        #expect(ComposerDraftSafety.draftAfterSendFailure(
            originalDraft: "", trimmedGoal: "", currentDraft: "").isEmpty)
    }
}
#endif
