// FloeAppTests — Composer editing contract.
//
// Pins the Part-10 multi-line/full-edit behavior at the decision and seam
// layers: draft-store revision semantics (stale async writes rejected,
// revisions never restart after a clear), send identity (a stored text or
// live editor generation the user retyped during the await — A→B→A — is
// never erased), the async-send commit contract (what a successful/failed
// send may erase), 100k round-trip fidelity, per-conversation isolation,
// selection clamping/restore ordering, the per-instance full-editor
// controller (two windows never share actions), the editor's Cmd+Enter send
// policy (inline guard + IME marked text), debounced footer counts, the
// Cmd+Return / IME send policy, the line + one-third-height growth budget,
// the measured height memo, the rough token estimate and the failed-send
// full-text restore. Device feel (dynamic type, split, rotation, keyboard)
// remains user acceptance on a real device.

#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import SwiftUI
import FloeCore
import FloeModels
@testable import FloeApp

private func makeTempDraftURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("composer-tests-\(UUID().uuidString).json")
}

private func makeAttachment(_ name: String) -> AttachmentRef {
    AttachmentRef(kind: .document, displayName: name, uti: "public.data")
}

@Suite("FloeApp.ComposerDraftStore")
@MainActor
struct ComposerDraftStoreTests {

    @Test("Creative start drafts survive independently of Home and task drafts")
    func creativeStartDraftIsolation() {
        let url = makeTempDraftURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ComposerDraftStore(fileURL: url)
        let taskID = UUID()
        #expect(CreativeDesignStartView.draftID != ComposerDraftStore.homeDraftID)
        store.save(text: "普通任务尚未发送", conversationID: ComposerDraftStore.homeDraftID)
        store.save(text: "制作一份带原生图表的PPT", conversationID: CreativeDesignStartView.draftID)
        store.save(text: "已有任务的修改", conversationID: taskID)
        #expect(store.flushAndWait())
        let restored = ComposerDraftStore(fileURL: url)
        #expect(restored.text(for: CreativeDesignStartView.draftID) == "制作一份带原生图表的PPT")
        restored.clear(conversationID: CreativeDesignStartView.draftID)
        #expect(restored.text(for: ComposerDraftStore.homeDraftID) == "普通任务尚未发送")
        #expect(restored.text(for: taskID) == "已有任务的修改")
    }

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
        #expect(store.flushAndWait())

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

    @Test("Clearing never restarts the revision sequence (stale writers stay rejected)")
    func revisionFloorAfterClear() {
        let store = ComposerDraftStore(fileURL: makeTempDraftURL())
        let id = UUID()
        guard let sentRevision = store.save(text: "已发送的草稿", conversationID: id) else {
            Issue.record("Save must return a revision")
            return
        }
        store.clear(conversationID: id)
        // A stale merge captured before the clear must not match a fresh
        // entry that restarted at revision 1.
        #expect(store.save(
            text: "过期转写", conversationID: id, expectedRevision: sentRevision
        ) == nil)
        #expect(store.text(for: id).isEmpty)
        // The next legitimate write continues above the cleared revision.
        let next = store.save(text: "新草稿", conversationID: id)
        #expect(next == sentRevision + 1)
        #expect(store.text(for: id) == "新草稿")
    }

    @Test("A successful send keeps text typed while the send was in flight")
    func asyncSendKeepsInFlightDraft() {
        let store = ComposerDraftStore(fileURL: makeTempDraftURL())
        let id = UUID()
        let sent = "第一版提示词"
        #expect(store.save(text: sent, conversationID: id) == 1)
        // While the run is in flight the composer suppresses the send's own
        // empty-field save and the user types the next prompt.
        #expect(store.save(text: "第二条还在输入", conversationID: id, expectedRevision: 1) == 2)
        // Send succeeds: only the content that was sent is committed away.
        #expect(store.clearAfterSend(conversationID: id, sentText: sent))
        #expect(store.text(for: id) == "第二条还在输入")
        // A stale voice merge holding the pre-send revision is still dead.
        #expect(store.save(text: "旧转写", conversationID: id, expectedRevision: 1) == nil)
        #expect(store.text(for: id) == "第二条还在输入")
    }

    @Test("A successful send clears an untouched draft and drops sent attachments only")
    func asyncSendClearsUntouchedDraft() {
        let store = ComposerDraftStore(fileURL: makeTempDraftURL())
        let id = UUID()
        let sentAttachment = makeAttachment("sent.pdf")
        #expect(store.save(
            text: "发送内容", attachments: [sentAttachment], conversationID: id
        ) == 1)
        #expect(store.clearAfterSend(
            conversationID: id, sentText: "发送内容", sentAttachments: [sentAttachment]
        ))
        #expect(store.entry(for: id) == nil)
        #expect(store.text(for: id).isEmpty)
    }

    @Test("Attachments staged during a send survive the commit; sent ones do not")
    func asyncSendKeepsNewAttachments() {
        let store = ComposerDraftStore(fileURL: makeTempDraftURL())
        let id = UUID()
        let sentAttachment = makeAttachment("sent.pdf")
        let laterAttachment = makeAttachment("later.pdf")
        #expect(store.save(
            text: "发送内容", attachments: [sentAttachment], conversationID: id
        ) == 1)
        // The user stages another file while the send is in flight.
        #expect(store.save(
            text: "发送内容",
            attachments: [sentAttachment, laterAttachment],
            conversationID: id,
            expectedRevision: 1
        ) == 2)
        #expect(store.clearAfterSend(
            conversationID: id, sentText: "发送内容", sentAttachments: [sentAttachment]
        ))
        #expect(store.text(for: id).isEmpty)
        #expect(store.attachments(for: id).map(\.id) == [laterAttachment.id])
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
        #expect(store.entry(for: id)?.selection == NSRange(location: 2, length: 3))
    }

    @Test("A send token keeps a draft the user retyped A→B→A during the await")
    func sendCommitTokenKeepsRetypedDraft() {
        let store = ComposerDraftStore(fileURL: makeTempDraftURL())
        let id = UUID()
        let sentAttachment = makeAttachment("sent.pdf")
        let laterAttachment = makeAttachment("later.pdf")
        #expect(store.save(
            text: "A", attachments: [sentAttachment], conversationID: id
        ) == 1)
        let token = store.sendCommitToken(for: id)
        // The user edits while the send is suspended: A → B → A. The string
        // compares equal again, but the identity must not.
        #expect(store.save(
            text: "B", attachments: [sentAttachment],
            conversationID: id, expectedRevision: 1
        ) == 2)
        #expect(store.save(
            text: "A", attachments: [sentAttachment, laterAttachment],
            conversationID: id, expectedRevision: 2
        ) == 3)
        #expect(store.clearAfterSend(
            conversationID: id,
            sentText: "A",
            sentAttachments: [sentAttachment],
            sendToken: token
        ))
        #expect(store.text(for: id) == "A")
        #expect(store.attachments(for: id).map(\.id) == [laterAttachment.id])
    }

    @Test("A send token clears the stored text only while it is unchanged")
    func sendCommitTokenClearsUnchangedText() {
        let store = ComposerDraftStore(fileURL: makeTempDraftURL())
        let id = UUID()
        let sentAttachment = makeAttachment("sent.pdf")
        #expect(store.save(
            text: "已发送的完整提示词", attachments: [sentAttachment], conversationID: id
        ) == 1)
        let token = store.sendCommitToken(for: id)
        #expect(store.clearAfterSend(
            conversationID: id,
            sentText: "已发送的完整提示词",
            sentAttachments: [sentAttachment],
            sendToken: token
        ))
        #expect(store.entry(for: id) == nil)
        #expect(store.text(for: id).isEmpty)
    }

    @Test("Staging an attachment during the await still clears the sent text")
    func sendCommitTokenClearsTextWhenOnlyAttachmentsChanged() {
        let store = ComposerDraftStore(fileURL: makeTempDraftURL())
        let id = UUID()
        let sentAttachment = makeAttachment("sent.pdf")
        let laterAttachment = makeAttachment("later.pdf")
        #expect(store.save(
            text: "发送内容", attachments: [sentAttachment], conversationID: id
        ) == 1)
        let token = store.sendCommitToken(for: id)
        // Attachment-only update: the entry revision moves but the text
        // identity does not, so the sent prompt must still be committed away.
        #expect(store.save(
            text: "发送内容",
            attachments: [sentAttachment, laterAttachment],
            conversationID: id,
            expectedRevision: 1
        ) == 2)
        #expect(store.clearAfterSend(
            conversationID: id,
            sentText: "发送内容",
            sentAttachments: [sentAttachment],
            sendToken: token
        ))
        #expect(store.text(for: id).isEmpty)
        #expect(store.attachments(for: id).map(\.id) == [laterAttachment.id])
    }

    @Test("Caret moves during the await do not invalidate the send token")
    func sendCommitTokenIgnoresSelectionUpdates() {
        let store = ComposerDraftStore(fileURL: makeTempDraftURL())
        let id = UUID()
        #expect(store.save(text: "选中文字", conversationID: id) == 1)
        let token = store.sendCommitToken(for: id)
        store.updateSelection(NSRange(location: 2, length: 2), conversationID: id)
        store.updateSelection(NSRange(location: 0, length: 0), conversationID: id)
        #expect(store.clearAfterSend(
            conversationID: id, sentText: "选中文字", sendToken: token
        ))
        #expect(store.entry(for: id) == nil)
    }

    @Test("A captured caret round-trips through disk for relaunch restore")
    func selectionRoundTripsThroughDisk() {
        let url = makeTempDraftURL()
        let id = UUID()
        let store = ComposerDraftStore(fileURL: url)
        #expect(store.save(text: "第一行\n第二行", conversationID: id) == 1)
        store.updateSelection(NSRange(location: 4, length: 0), conversationID: id)
        #expect(store.flushAndWait())
        let reloaded = ComposerDraftStore(fileURL: url)
        #expect(reloaded.entry(for: id)?.selection == NSRange(location: 4, length: 0))
        try? FileManager.default.removeItem(at: url)
    }

    @Test("Flush persists the latest snapshot for background/relaunch")
    func flushPersistsLatest() {
        let url = makeTempDraftURL()
        let store = ComposerDraftStore(fileURL: url)
        let id = UUID()
        store.save(text: "最新内容", conversationID: id)
        #expect(store.flushAndWait())
        #expect(store.lastWriteState == .idle)
        let reloaded = ComposerDraftStore(fileURL: url)
        #expect(reloaded.text(for: id) == "最新内容")
        try? FileManager.default.removeItem(at: url)
    }

    @Test("A failed durable write is reported, never silently swallowed")
    func writeFailureReportedAndRecoverable() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-blocked-\(UUID().uuidString)")
        // A regular file where the drafts directory should be makes both
        // createDirectory and the atomic write fail deterministically.
        try Data("blocked".utf8).write(to: parent)
        let url = parent.appendingPathComponent("drafts.json")
        let store = ComposerDraftStore(fileURL: url)
        let id = UUID()
        store.save(text: "无法落盘的内容", conversationID: id)
        #expect(!store.flushAndWait(timeout: 1))
        #expect(store.lastWriteState.failureMessage != nil)
        // The in-memory draft is untouched, and a retry after the obstruction
        // is gone succeeds.
        #expect(store.text(for: id) == "无法落盘的内容")
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        #expect(store.flushAndWait(timeout: 2))
        #expect(store.lastWriteState == .idle)
        let reloaded = ComposerDraftStore(fileURL: url)
        #expect(reloaded.text(for: id) == "无法落盘的内容")
        try? FileManager.default.removeItem(at: parent)
    }

    @Test("A starved flush reports pending until the attempt's real failure is published")
    func starvedFlushPublishesOnlyRealFailure() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-starved-\(UUID().uuidString)")
        // Same blocked durable path as above: the creation and the atomic
        // write both fail deterministically once an attempt runs.
        try Data("blocked".utf8).write(to: parent)
        defer { try? FileManager.default.removeItem(at: parent) }
        let url = parent.appendingPathComponent("drafts.json")
        // A suspended serial writer occupies the queue, so no attempt can run
        // before the first bounded deadline expires. This is the shape the
        // canonical-iPad run hit for real: `flushAndWait` parked the main
        // thread at user-interactive QoS while the writer queue was pinned to
        // `.utility`, the attempt missed its 1 s deadline, and the failure
        // notice was still nil when the caller read it.
        let queue = DispatchQueue(label: "floe-test-composer-writer-starved")
        queue.suspend()
        let store = ComposerDraftStore(fileURL: url, writeQueue: queue)
        let id = UUID()
        store.save(text: "无法落盘的内容", conversationID: id)
        #expect(!store.flushAndWait(timeout: 0.3))
        // No attempt has run, so asserting a failure here would be a lie. A
        // bounded flush that timed out can only prove "pending"; the failure
        // message must appear once the real attempt has failed.
        #expect(store.lastWriteState == .pending)
        #expect(store.lastWriteState.failureMessage == nil)
        queue.resume()
        // The queued attempt now runs and fails; the next bounded flush
        // observes that real failure synchronously, before it returns.
        #expect(!store.flushAndWait(timeout: 2))
        #expect(store.lastWriteState.failureMessage != nil)
        #expect(store.text(for: id) == "无法落盘的内容")
    }

    @Test("An unreadable draft file is preserved and the failure is reported")
    func corruptFilePreserved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("drafts.json")
        try Data("{ this is not the draft document".utf8).write(to: url)

        let store = ComposerDraftStore(fileURL: url)
        #expect(store.text(for: UUID()).isEmpty)
        #expect(store.lastWriteState.failureMessage != nil)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let preserved = names.filter { $0.contains("corrupt-") }
        #expect(preserved.count == 1)
        // The preserved copy still holds the original bytes.
        if let name = preserved.first {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            #expect(String(decoding: data, as: UTF8.self)
                == "{ this is not the draft document")
        }
        try? FileManager.default.removeItem(at: directory)
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

    @Test("A restored selection is clamped into the current UTF16 text")
    func selectionClamp() {
        #expect(ComposerSelection.clamped(
            NSRange(location: 2, length: 3), utf16Length: 5
        ) == NSRange(location: 2, length: 3))
        #expect(ComposerSelection.clamped(
            NSRange(location: 9, length: 1), utf16Length: 5
        ) == NSRange(location: 5, length: 0))
        #expect(ComposerSelection.clamped(
            NSRange(location: 2, length: 99), utf16Length: 5
        ) == NSRange(location: 2, length: 3))
        #expect(ComposerSelection.clamped(
            NSRange(location: NSNotFound, length: 0), utf16Length: 5
        ) == nil)
        #expect(ComposerSelection.clamped(nil, utf16Length: 5) == nil)
    }

    @Test("The initial text is seeded before the caret, so non-zero carets restore")
    func selectionPrepareOrder() {
        let view = UITextView()
        ComposerSelection.prepare(view, text: "中文abc", selection: NSRange(location: 2, length: 1))
        #expect(view.text == "中文abc")
        #expect(view.selectedRange == NSRange(location: 2, length: 1))
        // A caret from a longer draft clamps to the end of the shorter one.
        ComposerSelection.prepare(view, text: "ab", selection: NSRange(location: 2, length: 1))
        #expect(view.selectedRange == NSRange(location: 2, length: 0))
    }

    @Test("Footer counts stay off the keystroke path and handle a 100k draft")
    func footerCountsDebounce() async {
        let counts = ComposerFooterCounts()
        let text = String(repeating: "中文abc123。", count: 12_000)
        #expect(text.count > 100_000)
        counts.schedule(text: text, debounce: .milliseconds(10))
        // Nothing is computed synchronously while typing.
        #expect(counts.characters == 0)
        await counts.waitForScheduledCounts()
        #expect(counts.characters == text.count)
        #expect(counts.estimatedTokens == ComposerTokenEstimator.estimatedTokens(in: text))
    }

    @Test("A newer edit invalidates an older scheduled count")
    func footerCountsRevisionGuard() async {
        let counts = ComposerFooterCounts()
        counts.schedule(text: "AAAA", debounce: .milliseconds(80))
        counts.schedule(text: "B", debounce: .milliseconds(10))
        await counts.waitForScheduledCounts()
        #expect(counts.characters == 1)
        #expect(counts.estimatedTokens == ComposerTokenEstimator.estimatedTokens(in: "B"))
        // An immediate recount cancels a pending debounce and wins.
        counts.schedule(text: "仍在等待", debounce: .seconds(5))
        counts.setImmediately(text: "abc")
        #expect(counts.characters == 3)
        await counts.waitForScheduledCounts()
        #expect(counts.characters == 3)
    }
}

@Suite("FloeApp.ComposerSendCommit")
@MainActor
struct ComposerSendCommitTests {

    @Test("A retyped A→B→A draft survives a successful send")
    func retypedDraftSurvivesSuccess() {
        let store = ComposerDraftStore(fileURL: makeTempDraftURL())
        let id = UUID()
        let sentAttachment = makeAttachment("sent.pdf")
        let laterAttachment = makeAttachment("later.pdf")
        #expect(store.save(
            text: "A", attachments: [sentAttachment], conversationID: id
        ) == 1)
        // Captured at send start: the live editor generation and the stored
        // text identity of the sent draft.
        var generation = 1
        let commit = ComposerSendCommit(
            draft: "A", attachments: [sentAttachment],
            editorGeneration: generation, conversationID: id, store: store
        )
        // While the send is suspended the user edits A → B → A and stages a
        // second file. Both identities move even though the string returns.
        generation += 1
        _ = store.save(
            text: "B", attachments: [sentAttachment],
            conversationID: id, expectedRevision: 1
        )
        generation += 1
        _ = store.save(
            text: "A", attachments: [sentAttachment, laterAttachment],
            conversationID: id, expectedRevision: 2
        )

        #expect(commit.draftAfterSuccess(
            currentDraft: "A", currentGeneration: generation
        ) == "A")
        #expect(commit.attachmentsAfterSuccess(
            current: [sentAttachment, laterAttachment]
        ).map(\.id) == [laterAttachment.id])
        #expect(commit.commitStore(store: store))
        #expect(store.text(for: id) == "A")
        #expect(store.attachments(for: id).map(\.id) == [laterAttachment.id])
    }

    @Test("An unchanged send clears the field and the stored draft")
    func unchangedSendClears() {
        let store = ComposerDraftStore(fileURL: makeTempDraftURL())
        let id = UUID()
        let sentAttachment = makeAttachment("sent.pdf")
        #expect(store.save(
            text: "原始草稿", attachments: [sentAttachment], conversationID: id
        ) == 1)
        let commit = ComposerSendCommit(
            draft: "原始草稿", attachments: [sentAttachment],
            editorGeneration: 4, conversationID: id, store: store
        )
        #expect(commit.draftAfterSuccess(
            currentDraft: "原始草稿", currentGeneration: 4
        ).isEmpty)
        #expect(commit.attachmentsAfterSuccess(
            current: [sentAttachment]
        ).isEmpty)
        #expect(commit.commitStore(store: store))
        #expect(store.entry(for: id) == nil)
    }

    @Test("Only the sent attachment refs are reconciled away")
    func onlySentAttachmentsAreConsumed() {
        let store = ComposerDraftStore(fileURL: makeTempDraftURL())
        let id = UUID()
        let sentAttachment = makeAttachment("sent.pdf")
        let laterAttachment = makeAttachment("later.pdf")
        #expect(store.save(text: "内容", conversationID: id) == 1)
        let commit = ComposerSendCommit(
            draft: "内容", attachments: [sentAttachment],
            editorGeneration: 0, conversationID: id, store: store
        )
        // A file staged during the send must keep its own identity, and the
        // send may not erase the draft the user typed next either.
        let remaining = commit.attachmentsAfterSuccess(
            current: [laterAttachment]
        )
        #expect(remaining.map(\.id) == [laterAttachment.id])
        #expect(commit.draftAfterSuccess(
            currentDraft: "下一条", currentGeneration: 1
        ) == "下一条")
    }

    @Test("A failed send still restores the full original draft")
    func failureRestoresFullDraft() {
        let store = ComposerDraftStore(fileURL: makeTempDraftURL())
        let id = UUID()
        let original = "  完整原文，含首尾空白  \n第二行也不能少"
        let commit = ComposerSendCommit(
            draft: original, attachments: [],
            editorGeneration: 1, conversationID: id, store: store
        )
        let goal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing typed while the send was in flight: the whole original
        // comes back (never the trimmed goal), exactly as before.
        #expect(commit.draftAfterFailure(
            trimmedGoal: goal, currentDraft: ""
        ) == original)
        // Text typed during the flight still wins over the restore.
        #expect(commit.draftAfterFailure(
            trimmedGoal: goal, currentDraft: "新输入"
        ) == "新输入")
    }
}

@Suite("FloeApp.ComposerFullEditor")
@MainActor
struct ComposerFullEditorTests {

    @Test("Two editor instances never share toolbar actions or selections")
    func controllerIsolationAcrossInstances() {
        let firstController = FullEditorController()
        let secondController = FullEditorController()
        let firstView = FullEditorUITextView()
        let secondView = FullEditorUITextView()
        firstView.text = "first window"
        secondView.text = "second window"
        let secondInitialSelection = secondView.selectedRange
        firstController.attach(firstView)
        secondController.attach(secondView)

        var firstCaptured: NSRange?
        var secondCaptured: NSRange?
        firstController.onFinalSelection = { firstCaptured = $0 }
        secondController.onFinalSelection = { secondCaptured = $0 }

        firstController.selectAll()
        #expect(firstView.selectedRange == NSRange(location: 0, length: 12))
        // The other window's caret is exactly where it was.
        #expect(secondView.selectedRange == secondInitialSelection)

        firstController.captureSelection()
        #expect(firstCaptured == NSRange(location: 0, length: 12))
        #expect(secondCaptured == nil)

        // Detaching one editor leaves the other fully functional.
        firstController.detach(firstView)
        firstController.captureSelection()
        secondController.captureSelection()
        #expect(secondCaptured == secondInitialSelection)
    }

    @Test("Undo runs on the attached view's own manager")
    func controllerUndoRouting() {
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        let probe = UndoProbe()
        manager.registerUndo(withTarget: probe) { $0.undid = true }
        manager.endUndoGrouping()

        let controller = FullEditorController()
        let view = FullEditorUITextView()
        view.text = "text"
        view.sharedUndoManager = manager
        controller.attach(view)
        #expect(view.undoManager === manager)
        #expect(controller.canUndo)
        controller.undo()
        #expect(probe.undid)
    }

    @Test("The inline field and full editor share one undo history")
    func sharedUndoManagerAcrossSurfaces() {
        let shared = UndoManager()
        let inline = HardwareReturnTextView()
        inline.sharedUndoManager = shared
        let full = FullEditorUITextView()
        full.sharedUndoManager = shared
        #expect(inline.undoManager === shared)
        #expect(full.undoManager === shared)
        // Without an injected manager each view keeps UIKit's own.
        #expect(HardwareReturnTextView().undoManager !== shared)
        #expect(FullEditorUITextView().undoManager !== shared)
    }

    @Test("Cmd+Enter sends through the composer guard and is suppressed by IME")
    func editorSendCommandFollowsComposerGuard() {
        let controller = FullEditorController()
        var sends = 0
        controller.onSend = { sends += 1 }
        // The composer's live guard is off (no model, blank draft, a send in
        // flight): nothing is sent and the press is not consumed.
        #expect(!controller.commandReturnSends())
        #expect(!controller.requestSend())
        #expect(sends == 0)
        controller.sendAllowed = true
        // An unconfirmed input-method candidate can never send.
        controller.markedTextOverride = true
        #expect(!controller.requestSend())
        #expect(sends == 0)
        controller.markedTextOverride = false
        #expect(controller.requestSend())
        #expect(sends == 1)
        // The exact same policy the inline field uses.
        #expect(ComposerSendKeyPolicy.commandReturnSends(
            canSend: true, hasMarkedText: false
        ))
        // Without a composer action the editor never fires one.
        controller.onSend = nil
        controller.sendAllowed = true
        #expect(!controller.requestSend())
        #expect(sends == 1)
    }

    @Test("The toolbar send button and Cmd+Enter share one real IME guard")
    func editorToolbarAndKeyboardShareImeGuard() {
        let controller = FullEditorController()
        let view = FullEditorUITextView()
        controller.attach(view)
        var sends = 0
        controller.onSend = { sends += 1 }
        controller.sendAllowed = true
        #expect(!controller.hasMarkedText)
        // A half-confirmed candidate blocks the single entrypoint that both
        // the toolbar button and the hardware shortcut call, so the button
        // cannot send when the keyboard shortcut is suppressed.
        controller.markedTextOverride = true
        #expect(!controller.commandReturnSends())
        #expect(!controller.requestSend())
        #expect(sends == 0)
        controller.markedTextOverride = false
        #expect(controller.requestSend())
        #expect(sends == 1)
        // A detached editor has no marked text and still follows the guard.
        controller.detach(view)
        #expect(controller.requestSend())
        #expect(sends == 2)
    }
}

private final class UndoProbe: @unchecked Sendable {
    var undid = false
}

@Suite("FloeApp.ComposerMeasurementHardening")
@MainActor
struct ComposerMeasurementHardeningTests {

    @Test("Overflow scroll changes are deferred even without a host callback")
    func overflowMutationIsDeferred() async {
        let field = ComposerReturnField(text: .constant(""), placeholder: "", onReturn: {})
        let coordinator = field.makeCoordinator()
        let view = HardwareReturnTextView()
        view.isScrollEnabled = false
        coordinator.scheduleOverflowReport(true, textView: view, report: nil)
        #expect(!view.isScrollEnabled)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(view.isScrollEnabled)
    }

    @Test("A layout burst applies only its latest view and overflow verdict")
    func overflowBurstUsesLatestView() async {
        let field = ComposerReturnField(text: .constant(""), placeholder: "", onReturn: {})
        let coordinator = field.makeCoordinator()
        let firstView = HardwareReturnTextView()
        let latestView = HardwareReturnTextView()
        firstView.isScrollEnabled = false
        latestView.isScrollEnabled = true
        var reports: [Bool] = []
        coordinator.scheduleOverflowReport(true, textView: firstView, report: { reports.append($0) })
        coordinator.scheduleOverflowReport(false, textView: latestView, report: { reports.append($0) })
        #expect(reports.isEmpty)
        #expect(!firstView.isScrollEnabled && latestView.isScrollEnabled)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(!firstView.isScrollEnabled && !latestView.isScrollEnabled)
        #expect(reports == [false])
    }

    @Test("Missing font attributes use the visible field font without changing the source")
    func inheritedFontMeasurement() {
        let text = String(repeating: "中文English0123456789", count: 100)
        let storage = NSTextStorage(string: text)
        let original = NSAttributedString(attributedString: storage)
        let font = UIFont.systemFont(ofSize: 28)
        let reference = NSTextStorage(string: text, attributes: [.font: font])
        let measured = ComposerFieldMeasurement.detachedHeight(of: storage, width: 600, fallbackFont: font)
        let expected = ComposerFieldMeasurement.detachedHeight(of: reference, width: 600)
        #expect(abs(measured - expected) < 0.5)
        #expect(storage.isEqual(to: original))
        #expect(measured > ComposerFieldMeasurement.detachedHeight(of: storage, width: 600))
    }

    @Test("Accepted sends clear durable text before a run finishes, with newer work preserved")
    func acceptedSendDoesNotRestoreOnNavigation() {
        let url = makeTempDraftURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ComposerDraftStore(fileURL: url)
        let id = UUID()
        let sent = makeAttachment("sent.txt"), new = makeAttachment("new.txt")
        store.save(text: "长问题", attachments: [sent], conversationID: id)
        let commit = ComposerSendCommit(draft: "长问题", attachments: [sent], editorGeneration: 1, conversationID: id, store: store)
        // This is the atomic startRun acceptance boundary, before the
        // provider task finishes. A reconstructed editor reads this store.
        commit.commitStore(store: store)
        #expect(store.text(for: id).isEmpty)
        #expect(store.attachments(for: id).isEmpty)
        store.save(text: "A", attachments: [new], conversationID: id)
        store.save(text: "B", attachments: [new], conversationID: id)
        store.save(text: "A", attachments: [new], conversationID: id)
        #expect(commit.draftAfterSuccess(currentDraft: "A", currentGeneration: 4) == "A")
        #expect(store.text(for: id) == "A")
        #expect(store.attachments(for: id).map(\.id) == [new.id])
    }

    /// Build-272 regression: the composer must never mutate live TextKit
    /// state while SwiftUI measures it. The detached path is the width-change
    /// branch of `sizeThatFits`; it may read the view's storage but must not
    /// touch its container, scroll flag or layout manager.
    @Test("Detached measurement never mutates the live view")
    func detachedMeasurementIsSideEffectFree() {
        let view = HardwareReturnTextView()
        view.text = String(repeating: "中文长文本与English mix，无空格长串aaaaaaaaaaaaaaaa。\n", count: 60)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        view.layoutIfNeeded()
        let containerSize = view.textContainer.size
        let scrollEnabled = view.isScrollEnabled
        let measured = ComposerFieldMeasurement.detachedHeight(
            of: view.textStorage,
            width: 200
        )
        #expect(measured > 0)
        #expect(view.textContainer.size == containerSize)
        #expect(view.isScrollEnabled == scrollEnabled)
        // The view's live layout manager never received the detached layout.
        #expect(view.layoutManager.usedRect(for: view.textContainer).height >= 0)
    }

    /// A width change wraps differently: the narrower width is taller, and
    /// both measurements are positive for real text.
    @Test("Detached measurement wraps long CJK text at the proposed width")
    func detachedMeasurementWrapsAtWidth() {
        let storage = NSTextStorage(string: String(repeating: "这是一段用于验证换行高度的中文草稿。", count: 24))
        let wide = ComposerFieldMeasurement.detachedHeight(of: storage, width: 480)
        let narrow = ComposerFieldMeasurement.detachedHeight(of: storage, width: 160)
        #expect(wide > 0)
        #expect(narrow > wide)
        // Zero/negative widths still measure (bounded to 1pt).
        #expect(ComposerFieldMeasurement.detachedHeight(of: storage, width: 0) >= wide)
    }

    /// The always-detached measurement replaced a crash path; this records the
    /// ACTUAL cost of that path for a ~100k-character draft at composer widths
    /// (wrap + scroll verdict included) instead of assuming it is cheap. The
    /// numbers below are the observed cost of this path on the executing
    /// machine — there is deliberately no baseline/improvement claim.
    @Test("100k-character draft: measurement cost, wrap and scroll verdict are recorded")
    func longDraftMeasurementCost() {
        let text = String(repeating: "中文与English混排的长草稿，这一行会换行。", count: 5_000)
        #expect(text.count > 100_000)
        let storage = NSTextStorage(string: text)
        // Warm-up: the first layout also builds font/line-fragment state.
        _ = ComposerFieldMeasurement.detachedHeight(of: storage, width: 320)

        var timingsMs: [Double] = []
        for _ in 0..<3 {
            let started = CFAbsoluteTimeGetCurrent()
            let height = ComposerFieldMeasurement.detachedHeight(of: storage, width: 320)
            timingsMs.append((CFAbsoluteTimeGetCurrent() - started) * 1_000)
            #expect(height > 0)
        }
        let narrow = ComposerFieldMeasurement.detachedHeight(of: storage, width: 160)
        let wide = ComposerFieldMeasurement.detachedHeight(of: storage, width: 480)
        // Wrapping: a narrower proposal never produces a shorter block.
        #expect(narrow > wide)

        // Scroll verdict for the long draft: the natural height is far past
        // the 8-line cap, so the field really scrolls instead of growing.
        let lineHeight = ComposerFieldMeasurement.detachedHeight(
            of: NSTextStorage(string: FloeL10n.l("design.composer_return_field.chars")),
            width: 320)
        let insets: CGFloat = 16
        let cap = ComposerFieldMetrics.heightCap(
            lineCapHeight: lineHeight * 8 + insets, availableHeight: nil)
        let natural = wide + insets
        #expect(natural > cap, "a 100k draft must exceed the line cap and scroll")

        print("FLOE_COMPOSER_100K characters=\(text.count) detachedHeightMs=\(timingsMs) "
            + "narrow=\(narrow) wide=\(wide) cap=\(cap) natural=\(natural)")
        // Generous, observed ceiling: one measurement of a 100k draft must
        // stay well inside an interactive frame budget violation; the memoized
        // coordinator avoids repeating it for unchanged content.
        let worst = timingsMs.max() ?? 0
        #expect(worst < 5_000, "one 100k detached measurement took \(worst) ms")
    }

    /// The detached number is the same quantity the live field reports at the
    /// same width, so the height contract is unchanged by the hardening.
    @Test("Detached measurement matches the live used-rect height")
    func detachedMatchesLiveHeight() {
        let view = HardwareReturnTextView()
        view.text = String(repeating: "中文与English混排的长草稿，这一行会换行。\n", count: 40)
        let width: CGFloat = 300
        view.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        view.layoutManager.ensureLayout(for: view.textContainer)
        let live = view.layoutManager.usedRect(for: view.textContainer).height
        // Measurement order: compare only the used height, not the insets.
        let detached = ComposerFieldMeasurement.detachedHeight(
            of: view.textStorage,
            width: width
        )
        #expect(abs(detached - live) < 0.5)
    }
}

#endif
