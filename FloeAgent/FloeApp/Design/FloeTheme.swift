// FloeApp — Semantic design tokens (colors, typography, surfaces).
//
// SPDX-License-Identifier: MPL-2.0
//
// Views must never hard-code colors or fonts; they go through these
// semantic tokens. The brand cyan-blue-violet is reserved for selection,
// progress and the primary action; amber means a pending decision; red
// means destructive or failure; green means confirmed success. Reading
// surfaces stay opaque; glass/material is reserved for chrome and the
// composer. All tokens are light/dark aware and honor accessibility
// settings (Reduce Motion, Increased Contrast, Dynamic Type).

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Semantic design tokens for the Floe Agent shell.
enum FloeTheme {

    // MARK: - Brand gradient (cyan → blue → violet)

    /// The three stops of the brand gradient. Selection, progress and the
    /// primary action draw from this ramp; nothing else may.
    private static let brandCyan = Color(red: 0.10, green: 0.78, blue: 0.86)
    private static let brandBlue = Color(red: 0.24, green: 0.48, blue: 0.96)
    private static let brandViolet = Color(red: 0.56, green: 0.36, blue: 0.94)

    /// Brand gradient for primary actions, selection emphasis and progress.
    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [brandCyan, brandBlue, brandViolet],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Semantic colors

    /// Selection, progress and the primary action. Resolves to the app
    /// accent (brand cyan-blue) in asset catalogs.
    static var primary: Color { .accentColor }

    /// A pending decision that needs the user (approvals, trust prompts).
    static var pending: Color { .orange }

    /// Destructive actions and unambiguous failures.
    static var destructive: Color { .red }

    /// Confirmed success only — never used for merely "not failed yet".
    static var success: Color { .green }

    /// Honest unknown / indeterminate state (e.g. unmanaged disconnect).
    static var unknown: Color { .secondary }

    /// Opaque reading surface. Thread content, documents and evidence read
    /// on this; it never goes translucent.
    static var readingSurface: Color { Color(uiColor: .systemBackground) }

    /// Opaque grouped surface for lists and forms.
    static var groupedSurface: Color { Color(uiColor: .systemGroupedBackground) }

    /// Chrome material for navigation bars, the composer and floating
    /// actions. Glass is allowed here and only here.
    static var chromeMaterial: Material { .bar }

    // MARK: - Typography roles

    enum Typography {
        /// Screen / section hero title.
        static let title = Font.title2.weight(.semibold)
        /// Section header inside a screen.
        static let section = Font.headline
        /// Primary reading text.
        static let body = Font.body
        /// Timestamps, counts, secondary context.
        static let metadata = Font.footnote
        /// Terminal output, evidence payloads, fingerprints, JSON.
        static let evidence = Font.system(.footnote, design: .monospaced)
    }

    // MARK: - Accessibility helpers

    /// Minimum hit-target dimension (44pt per HIG).
    static let minimumTarget: CGFloat = 44

    /// Pads a control so its tappable area never drops below 44pt.
    static func minimumTargetFrame<Content: View>(
        _ content: Content,
        alignment: Alignment = .center
    ) -> some View {
        content.frame(
            minWidth: minimumTarget,
            minHeight: minimumTarget,
            alignment: alignment
        )
    }

    /// The animation to use for state transitions, or `nil` when the user
    /// has requested Reduce Motion. Usage:
    /// `.animation(FloeTheme.motionAnimation(reduceMotion: reduceMotion), value: state)`
    static func motionAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy
    }
}
#endif
