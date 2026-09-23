// FloeApp — Composer editing primitives (pure, testable decisions).
//
// SPDX-License-Identifier: MPL-2.0
//
// The deterministic rules behind the multi-line composer and its full
// editor: hardware-key send policy, the visible-line / available-height
// budget, the measured-height memo, the rough token estimate, and the
// fail-safe that keeps the whole draft when a send fails. Kept free of
// SwiftUI/view state so FloeAppTests can pin them directly.

#if canImport(UIKit)
import Combine
import Foundation
import UIKit
import FloeModels

/// Hardware-key send policy for the shared composer.
enum ComposerSendKeyPolicy {
    /// Cmd+Return on a hardware keyboard sends only while sending is allowed
    /// and no input method composition is in flight. Plain Return (hardware
    /// or software) always inserts a newline — during and after composition —
    /// so a half-confirmed IME candidate can never trigger a send.
    static func commandReturnSends(canSend: Bool, hasMarkedText: Bool) -> Bool {
        canSend && !hasMarkedText
    }
}

/// Sizing rules for the growing composer field.
enum ComposerFieldMetrics {
    /// Visible line budget before the field switches to internal
    /// scrolling: iPhone-class widths (compact) get 6 lines, iPad-class
    /// widths (regular) get 8. Updated for split/rotation by re-reading the
    /// current horizontal size class at measurement time.
    static func lineCap(horizontalSizeClass: UIUserInterfaceSizeClass) -> Int {
        horizontalSizeClass == .regular ? 8 : 6
    }

    /// Effective pixel cap for the field: the line budget, and never more
    /// than one third of the height available to the hosting page. A nil or
    /// non-positive budget disables the height rule (callers without a
    /// measured container, e.g. previews).
    static func heightCap(lineCapHeight: CGFloat, availableHeight: CGFloat?) -> CGFloat {
        guard let availableHeight, availableHeight > 0 else { return lineCapHeight }
        return min(lineCapHeight, (availableHeight / 3).rounded(.down))
    }

    /// O(1) memo around TextKit measurement. Recomputes only when the text
    /// generation, proposed width or content-size category changed, so a
    /// 100k-character draft never triggers a full re-layout per keystroke —
    /// SwiftUI asks `sizeThatFits` far more often than the text changes.
    struct HeightCache: Equatable {
        private(set) var height: CGFloat = 0
        private var generation: Int = -1
        private var width: CGFloat = -1
        private var contentSizeCategory: UIContentSizeCategory = .unspecified

        mutating func value(
            generation: Int,
            width: CGFloat,
            contentSizeCategory: UIContentSizeCategory,
            compute: () -> CGFloat
        ) -> CGFloat {
            if generation != self.generation
                || width != self.width
                || contentSizeCategory != self.contentSizeCategory {
                height = compute()
                self.generation = generation
                self.width = width
                self.contentSizeCategory = contentSizeCategory
            }
            return height
        }
    }
}

/// Rough token estimate for the composer footer. CJK scalars ≈ 1 token each;
/// everything else ≈ 4 scalars per token. Always presented as an estimate,
/// never as an exact provider count.
enum ComposerTokenEstimator {
    static func estimatedTokens(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let scalarCount = text.unicodeScalars.count
        let cjkCount = text.unicodeScalars.filter {
            (0x3400...0x9FFF).contains(Int($0.value))
        }.count
        return max(1, cjkCount + (scalarCount - cjkCount + 3) / 4)
    }
}

/// Selection handoff between the inline field and the full editor. Both
/// surfaces edit the same UTF16-backed string, so a caret captured in one
/// surface (or restored from disk on the next launch) can point past the
/// end of a shorter draft or belong to another conversation. Every restore
/// is clamped, and restoring is always two ordered steps: seed the text
/// first, apply the selection second — a non-zero selection set on an empty
/// text view is clamped away before the text exists.
enum ComposerSelection {
    /// Clamps a stored selection into a UTF16 range of `utf16Length`.
    /// `NSNotFound` and negative values collapse to a safe caret.
    static func clamped(_ range: NSRange?, utf16Length: Int) -> NSRange? {
        guard let range, range.location != NSNotFound else { return nil }
        let length = max(0, utf16Length)
        let location = min(max(0, range.location), length)
        let available = length - location
        return NSRange(location: location, length: min(max(0, range.length), available))
    }

    /// Seeds a text view with its initial text and then restores the caret
    /// (the order `makeUIView` must use; kept here so it is testable).
    @MainActor
    static func prepare(_ textView: UITextView, text: String, selection: NSRange?) {
        textView.text = text
        apply(selection, to: textView)
    }

    /// Applies a clamped selection. Returns the range actually applied, or
    /// nil when there was nothing to restore.
    @MainActor
    @discardableResult
    static func apply(_ range: NSRange?, to textView: UITextView) -> NSRange? {
        guard let clamped = clamped(range, utf16Length: (textView.text as NSString).length) else {
            return nil
        }
        textView.selectedRange = clamped
        return clamped
    }
}

/// Debounced character/token footer for the full editor.
///
/// The footer previously recomputed `text.count` (grapheme segmentation) and
/// the full scalar token scan inside the SwiftUI body — i.e. on every
/// keystroke of a possibly 100k-character draft. Counts are now scheduled
/// behind a cancellation-safe debounce and computed off the main actor; a
/// newer revision invalidates an older computation instead of racing it.
@MainActor
final class ComposerFooterCounts: ObservableObject {
    @Published private(set) var characters = 0
    @Published private(set) var estimatedTokens = 0

    private var generation = 0
    private var pending: Task<Void, Never>?

    /// Recomputes synchronously (editor just opened). Cancels any pending
    /// debounce so an older keystroke burst cannot overwrite it.
    func setImmediately(text: String) {
        pending?.cancel()
        pending = nil
        generation += 1
        characters = text.count
        estimatedTokens = ComposerTokenEstimator.estimatedTokens(in: text)
    }

    /// Schedules a revision-based recount after `debounce`.
    func schedule(text: String, debounce: Duration = .milliseconds(220)) {
        generation += 1
        let generation = self.generation
        pending?.cancel()
        guard !text.isEmpty else {
            pending = nil
            characters = 0
            estimatedTokens = 0
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let snapshot = text
            let counted = await Task.detached(priority: .utility) {
                (snapshot.count, ComposerTokenEstimator.estimatedTokens(in: snapshot))
            }.value
            guard let self, self.generation == generation else { return }
            self.characters = counted.0
            self.estimatedTokens = counted.1
        }
    }

    /// Awaits the currently scheduled computation (deterministic flush in
    /// tests and before a sheet closes).
    func waitForScheduledCounts() async {
        await pending?.value
    }
}

/// Fail-safe around the send action. A failed send (provider error, context
/// budget, …) must return the complete original draft — never the trimmed
/// goal, never a prefix, and silently truncating is not an option. Text the
/// user typed while the send was in flight takes precedence over the
/// restore so nothing they wrote is lost either.
enum ComposerDraftSafety {
    static func draftAfterSendFailure(
        originalDraft: String,
        trimmedGoal: String,
        currentDraft: String
    ) -> String {
        if !currentDraft.isEmpty { return currentDraft }
        return originalDraft.isEmpty ? trimmedGoal : originalDraft
    }
}

/// One send's claim on the composer field and the persisted draft.
///
/// Captured at the send entrypoint (after the send's own programmatic clear,
/// when there is one) and asked only on outcome. Both the editor generation
/// and the draft store's text identity are pinned, because neither string
/// equality nor the store alone can tell "still the sent draft" from "the
/// user typed and came back to the same string" (A → B → A). A successful
/// send may clear only the identity it actually consumed; a failure keeps
/// the existing full-text restore semantics.
@MainActor
struct ComposerSendCommit {
    /// Conversation whose draft the send consumed.
    let conversationID: UUID
    /// Complete draft as it was sent (never the trimmed goal).
    let sentText: String
    /// Attachments that belonged to the send.
    let sentAttachments: [AttachmentRef]
    /// Live editor generation when the send consumed the field.
    let editorGeneration: Int
    /// Text identity of the draft store when the send started.
    let storeToken: ComposerDraftStore.SendCommitToken

    init(
        draft: String,
        attachments: [AttachmentRef],
        editorGeneration: Int,
        conversationID: UUID,
        store: ComposerDraftStore? = nil
    ) {
        let store = store ?? .shared
        self.conversationID = conversationID
        self.sentText = draft
        self.sentAttachments = attachments
        self.editorGeneration = editorGeneration
        self.storeToken = store.sendCommitToken(for: conversationID)
    }

    /// True while the live field still holds exactly the generation this
    /// send consumed; any user edit since — including A → B → A — is false.
    func editorStillConsumed(currentGeneration: Int) -> Bool {
        currentGeneration == editorGeneration
    }

    /// The draft to show after a successful send: empty only when the field
    /// has not changed since the send consumed it.
    func draftAfterSuccess(currentDraft: String, currentGeneration: Int) -> String {
        editorStillConsumed(currentGeneration: currentGeneration) ? "" : currentDraft
    }

    /// Attachments remaining after a successful send: only the sent refs are
    /// consumed, so a file staged during the flight keeps its identity.
    func attachmentsAfterSuccess(current: [AttachmentRef]) -> [AttachmentRef] {
        let sentIDs = Set(sentAttachments.map(\.id))
        guard !sentIDs.isEmpty else { return current }
        return current.filter { !sentIDs.contains($0.id) }
    }

    /// Durable reconciliation of a successful send; clears the stored text
    /// only while its captured text identity is unchanged.
    @discardableResult
    func commitStore(store: ComposerDraftStore? = nil) -> Bool {
        (store ?? .shared).clearAfterSend(
            conversationID: conversationID,
            sentText: sentText,
            sentAttachments: sentAttachments,
            sendToken: storeToken
        )
    }

    /// The draft to restore after a failed send (bounded by what the user
    /// typed while the send was in flight).
    func draftAfterFailure(trimmedGoal: String, currentDraft: String) -> String {
        ComposerDraftSafety.draftAfterSendFailure(
            originalDraft: sentText,
            trimmedGoal: trimmedGoal,
            currentDraft: currentDraft
        )
    }
}
#endif
