//
//  AdaptiveBar.swift
//  openshape3d
//
//  Shared layout for the bottom contextual bars (numeric input, blend, shell).
//  At regular width they lay out exactly as they always have: one row, controls
//  on the left, actions on the right.
//
//  At compact width a single fixed HStack has no good answer — SwiftUI
//  compresses every label to its minimum and then wraps it one character per
//  line, which is what turned "Extrude" into a vertical stack of letters and
//  grew the bar to ~40% of an iPhone screen (see
//  marketing/bugs/iphone-extrude-bar-broken.png). So in compact width the same
//  content splits into horizontally scrollable rows: labels keep their natural
//  width, and nothing is pushed off-screen or clipped away.
//
//  Callers supply the slots and place their own `Spacer()` inside `controls` if
//  they want the actions pushed to the trailing edge at regular width. In a
//  compact scroll row that Spacer collapses to its minimum length, so the same
//  slot content serves both layouts.
//
//  Labels stay as words in both size classes on purpose: the UI suite matches
//  several of these buttons by title (`buttons["Extrude"]`, `buttons["Cancel"]`,
//  `buttons["Revolve"]`, `buttons["Done"]`), so swapping in icon-only labels at
//  compact width would break those tests.
//

import SwiftUI

extension ShapeStyle where Self == Color {
    /// Caption colour for de-emphasized label text over a material — the bottom
    /// bars' field labels ("Distance", "W", …) and the side panels' rows.
    ///
    /// These used `.secondary`, which is a *hierarchical* style — over
    /// `.regularMaterial` it is drawn with vibrancy, and vibrancy does not
    /// composite inside a `ScrollView`: the labels come out fully transparent
    /// while still taking up their layout width, so the bar read as
    /// "Box [4] [4] [4]" with no W/D/H at all. (`Color.secondary` is
    /// hierarchical too, so it is not an escape hatch.) A concrete colour
    /// renders the same outside a ScrollView and actually shows up inside one.
    ///
    /// This bites **any** material-backed `ScrollView`, not just the compact
    /// bars: `HistoryPanelView`, `ItemsPanelView`, and `VariablesPanelView` are
    /// all `ScrollView { … }.background(.regularMaterial)` and lost their
    /// headers, row icons, trash buttons, and unit captions to it. Reach for
    /// these two instead of `.secondary`/`.tertiary` in those contexts.
    ///
    /// Note this is invisible to XCUITest — a transparent label still `exists`
    /// and is `isHittable` — so it needs a visual check, not a test.
    static var barLabel: Color { Color(uiColor: .secondaryLabel) }

    /// The `.tertiary` counterpart to ``barLabel``, for the faintest tier of
    /// label text (a row's kind caption, a dimmed icon, "No features yet").
    static var barLabelDim: Color { Color(uiColor: .tertiaryLabel) }
}

/// Advisory copy in a bar ("Drag the arrow, or type a distance"). It is the
/// least important thing in the row and the most expensive: at iPhone width it
/// pushed the bar's actual input off the right edge, so Offset Plane opened
/// with no visible Distance field and Polygon with no visible Sides stepper.
/// Hidden at compact width; unchanged at regular width.
struct BarHint: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        if horizontalSizeClass != .compact {
            Text(text)
                .font(.caption)
                .foregroundStyle(.barLabel)
                .fixedSize()
        }
    }
}

/// Measured height of the bottom bar stack. The tool palette and the corner
/// chips used to reserve a hardcoded 96pt for the bars; a compact bar is
/// routinely taller than that, which is how the Copy badge ended up sitting on
/// top of the dimension bar and the palette's last tools were clipped away.
/// Publishing the real height lets them inset by what the bars actually need.
struct BottomBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Publishes this view's height as the bottom-bar height.
    func measuringBottomBarHeight() -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: BottomBarHeightKey.self, value: geo.size.height)
        })
    }
}

/// Background treatment for a bottom bar. Compact width always uses the
/// rounded-rect panel — a multi-row capsule reads as a lozenge, not a bar.
enum AdaptiveBarStyle {
    /// Numeric input bars: 20/12 padding, 16pt rounded rect.
    case panel
    /// Blend / shell pick bars: tighter 16/10 padding, capsule at regular width.
    case capsule

    var horizontalPadding: CGFloat {
        switch self {
        case .panel: 20
        case .capsule: 16
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .panel: 12
        case .capsule: 10
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .panel: 10
        case .capsule: 8
        }
    }

    var shadowY: CGFloat {
        switch self {
        case .panel: 3
        case .capsule: 2
        }
    }
}

struct AdaptiveBar<Controls: View, Actions: View, Footer: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private let style: AdaptiveBarStyle
    private let spacing: CGFloat
    private let showsFooter: Bool
    private let controls: Controls
    private let actions: Actions
    private let footer: Footer

    /// - Parameter showsFooter: pass `false` to suppress the footer row for a
    ///   bar that only needs it in one size class. A `if …` inside the footer
    ///   builder is not enough: it produces `_ConditionalContent`, not
    ///   `EmptyView`, so the row would still claim its stack spacing.
    init(style: AdaptiveBarStyle = .panel,
         spacing: CGFloat = 16,
         showsFooter: Bool = true,
         @ViewBuilder controls: () -> Controls,
         @ViewBuilder actions: () -> Actions,
         @ViewBuilder footer: () -> Footer) {
        self.style = style
        self.spacing = spacing
        self.showsFooter = showsFooter
        self.controls = controls()
        self.actions = actions()
        self.footer = footer()
    }

    private var isCompact: Bool { horizontalSizeClass == .compact }

    /// Landscape on a non-Max iPhone: ~390pt of height for the viewport, the
    /// bar, the info strip and the tool palette combined. Stacking three rows
    /// there costs over half the screen and scrolls most of the palette out of
    /// reach, so the bar collapses back to a single scrolling row.
    private var isShortScreen: Bool { verticalSizeClass == .compact }

    /// A bar with no buttons (the polygon bar) must not reserve an empty
    /// actions row in the compact layout.
    private var hasActions: Bool { Actions.self != EmptyView.self }
    private var hasFooter: Bool { Footer.self != EmptyView.self && showsFooter }

    var body: some View {
        content
            .padding(.horizontal, isCompact ? 14 : style.horizontalPadding)
            .padding(.vertical, isCompact ? 10 : style.verticalPadding)
            .background(.regularMaterial, in: background)
            .shadow(color: .black.opacity(0.15),
                    radius: style.shadowRadius, y: style.shadowY)
    }

    @ViewBuilder
    private var content: some View {
        if isCompact && isShortScreen {
            // Everything on one scrolling row — height is the scarce axis here.
            scrollRow {
                controls
                actions
                footer
            }
        } else if isCompact {
            VStack(alignment: .leading, spacing: 8) {
                scrollRow { controls }
                if hasActions { scrollRow { actions } }
                if hasFooter { scrollRow { footer } }
            }
        } else if hasFooter {
            VStack(alignment: .leading, spacing: 10) {
                regularRow
                footer
            }
        } else {
            regularRow
        }
    }

    /// The regular-width row: the natural fixed HStack when everything fits
    /// (Spacers keep the actions pushed to the trailing edge), and the same
    /// scrolling row as compact when it doesn't. Without the fallback, a bar
    /// squeezed by a narrow-but-regular width (iPad Split View / Stage
    /// Manager) compresses its last labels to per-character wrapping — the
    /// commit button rendered as "Ex-trude" on two lines, the exact failure
    /// the compact layout already solved. `lineLimit(1)` guards the fitted
    /// row too, so a measurement edge case truncates instead of wrapping.
    private var regularRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) {
                controls
                actions
            }
            .lineLimit(1)
            scrollRow {
                controls
                actions
            }
        }
    }

    private var background: AnyShape {
        if isCompact || style == .panel {
            AnyShape(RoundedRectangle(cornerRadius: 16))
        } else {
            AnyShape(Capsule())
        }
    }

    /// One compact row. `fixedSize(horizontal:)` is the actual fix for the
    /// per-character wrapping: it makes the row take its ideal width instead of
    /// being squeezed into the screen, and the scroll view absorbs the
    /// overflow. `lineLimit(1)` then guarantees no descendant can wrap even if
    /// a future label is wider than the whole screen.
    private func scrollRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) { content() }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                // Prominent buttons draw a shadow past their bounds; without a
                // little slack the scroll view clips it.
                .padding(.vertical, 2)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Convenience initialisers so callers can omit the trailing slots they do not
// use, rather than passing `{ EmptyView() }` by hand.
extension AdaptiveBar where Footer == EmptyView {
    init(style: AdaptiveBarStyle = .panel,
         spacing: CGFloat = 16,
         @ViewBuilder controls: () -> Controls,
         @ViewBuilder actions: () -> Actions) {
        self.init(style: style, spacing: spacing, showsFooter: false,
                  controls: controls, actions: actions, footer: { EmptyView() })
    }
}

extension AdaptiveBar where Actions == EmptyView, Footer == EmptyView {
    init(style: AdaptiveBarStyle = .panel,
         spacing: CGFloat = 16,
         @ViewBuilder controls: () -> Controls) {
        self.init(style: style, spacing: spacing, showsFooter: false,
                  controls: controls, actions: { EmptyView() }, footer: { EmptyView() })
    }
}
