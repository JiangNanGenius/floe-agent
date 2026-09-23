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
import UIKit

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
#endif
