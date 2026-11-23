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

#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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

    /// Opaque platform reading and grouped surfaces.
    #if canImport(UIKit)
    /// Opaque reading surface. Thread content, documents and evidence read
    /// on this; it never goes translucent.
    static var readingSurface: Color { Color(uiColor: .systemBackground) }

    /// Opaque grouped surface for lists and forms.
    /// Distinct navigation and input planes in both appearances.
    static var sidebarSurface: Color { Color(uiColor: .secondarySystemBackground) }
    static var stepSurface: Color { Color(uiColor: .secondarySystemBackground) }
    static var fieldSurface: Color { Color(uiColor: .tertiarySystemFill) }
    static var separator: Color { Color(uiColor: .separator) }

    static var groupedSurface: Color { Color(uiColor: .systemGroupedBackground) }

    #elseif canImport(AppKit)
    static var readingSurface: Color { Color(nsColor: .textBackgroundColor) }
    static var sidebarSurface: Color { Color(nsColor: .windowBackgroundColor) }
    static var stepSurface: Color { Color(nsColor: .controlBackgroundColor) }
    static var fieldSurface: Color { Color(nsColor: .unemphasizedSelectedContentBackgroundColor) }
    static var separator: Color { Color(nsColor: .separatorColor) }
    static var groupedSurface: Color { Color(nsColor: .windowBackgroundColor) }
    #endif

    /// Chrome material for navigation bars, the composer and floating
    /// actions. Glass is allowed here and only here.
    static var chromeMaterial: Material { .bar }

    // MARK: - Typography roles

    enum Typography {
        #if os(macOS)
        static let title = Font.headline
        static let section = Font.body.weight(.semibold)
        static let body = Font.callout
        #else
        /// Screen / section hero title.
        static let title = Font.title2.weight(.semibold)
        /// Section header inside a screen.
        static let section = Font.headline
        /// Primary reading text.
        static let body = Font.body
        #endif
        /// Timestamps, counts, secondary context.
        static let metadata = Font.footnote
        /// Terminal output, evidence payloads, fingerprints, JSON.
        static let evidence = Font.system(.footnote, design: .monospaced)
    }

    // MARK: - Shared symbols

    /// SF Symbol for every Floe/AI assistant *entry* that opens the
    /// assistant conversation surface (Notes document assistant, linked
    /// mind maps, Office header, canvas assistant panel). Notes is the
    /// reference. Generation/image actions, the inline node refine field,
    /// model selectors and other AI glyphs keep their own semantic symbols.
    static let assistantSymbol = "bubble.left.and.bubble.right"

    // MARK: - Accessibility helpers

    static let minimumTarget: CGFloat = 44

    #if os(macOS)
    static let welcomeSpacing: CGFloat = 9
    static let welcomeCorner: CGFloat = 12
    static let welcomeIconSize: CGFloat = 48
    static let composerRadius: CGFloat = 18
    static let sendButtonSize: CGFloat = 26
    #else
    static let welcomeSpacing: CGFloat = 16
    static let welcomeCorner: CGFloat = 18
    static let welcomeIconSize: CGFloat = 76
    static let composerRadius: CGFloat = 22
    static let sendButtonSize: CGFloat = 34
    #endif

    /// Apply the platform control target.
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

    static func stepTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity
        )
    }

    /// The animation to use for state transitions, or `nil` when the user
    /// has requested Reduce Motion. Usage:
    /// `.animation(FloeTheme.motionAnimation(reduceMotion: reduceMotion), value: state)`
    static func motionAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy
    }
}

/// The shared labels and settings control in the Floe workbench sidebar.
struct FloeWorkbenchSidebarItem: View {
    let title: LocalizedStringKey
    let systemImage: String
    var foreground: Color? = nil

    var body: some View {
        if let foreground {
            Label {
                Text(title).foregroundStyle(foreground)
            } icon: {
                Image(systemName: systemImage).symbolRenderingMode(.monochrome).foregroundStyle(foreground)
            }
        } else {
            Label(title, systemImage: systemImage)
        }
    }
}

struct FloeWorkbenchSidebarFooter: View {
    let openSettings: () -> Void

    var body: some View {
        Divider()
        HStack(spacing: 8) {
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("more.settings")
                .accessibilityIdentifier("sidebar.settings")
            Spacer()
        }
        .padding(.horizontal, 16)
    }
}

/// The icon, type and rhythm of the existing Floe launchpad.
struct FloeWorkbenchWelcomeHeader<Welcome: View>: View {
    let icon: Image
    @ViewBuilder var welcome: () -> Welcome

    var body: some View {
        VStack(spacing: FloeTheme.welcomeSpacing) {
            icon
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: FloeTheme.welcomeIconSize, height: FloeTheme.welcomeIconSize)
                .clipShape(RoundedRectangle(cornerRadius: FloeTheme.welcomeCorner, style: .continuous))
                .shadow(color: FloeTheme.primary.opacity(0.18), radius: 18, y: 8)
                .accessibilityHidden(true)
            welcome()
                .font(FloeTheme.Typography.title)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
        }
        .accessibilityElement(children: .combine)
    }
}

struct FloeModelSetupBanner: View {
    #if os(macOS) && FLOE_MAC_HOST_SMOKE
    static var smokeActionFrame: CGRect?
    #endif
    let actionTitle: LocalizedStringKey
    let openSetup: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(FloeTheme.pending)
                .accessibilityHidden(true)
            Text("chat.add_provider.hint")
                .font(FloeTheme.Typography.metadata)
            Spacer(minLength: 8)
            Button(actionTitle, action: openSetup)
                .buttonStyle(.bordered)
                .frame(minHeight: FloeTheme.minimumTarget)
                .accessibilityIdentifier("setup.open")
                #if os(macOS) && FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { Self.smokeActionFrame = $0 })
                #endif
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(FloeTheme.pending.opacity(0.08))
    }
}

struct FloeThreadComposerChrome: ViewModifier {
    var documentAssistant = false

    private var surface: some ShapeStyle {
        #if os(macOS)
        return FloeTheme.stepSurface
        #else
        return FloeTheme.chromeMaterial
        #endif
    }

    func body(content: Content) -> some View {
        content
            .background(surface, in: RoundedRectangle(cornerRadius: documentAssistant ? 0 : FloeTheme.composerRadius, style: .continuous))
            .overlay {
                if !documentAssistant {
                    RoundedRectangle(cornerRadius: FloeTheme.composerRadius, style: .continuous)
                        .strokeBorder(FloeTheme.separator, lineWidth: 0.5)
                }
            }
            .padding(.horizontal, documentAssistant ? 0 : 12)
            .padding(.vertical, documentAssistant ? 0 : 8)
            .shadow(color: .black.opacity(documentAssistant ? 0 : 0.08), radius: 14, y: 5)
    }
}

struct FloeThreadComposerChip: View {
    let title: Text
    let systemImage: String
    var betaBadge = false
    var maximumWidth: CGFloat = 280
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            Label { title } icon: { Image(systemName: systemImage) }
                .lineLimit(1)
                .truncationMode(.tail)
            if betaBadge {
                Text("localmodels.beta_badge")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FloeTheme.pending)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .font(FloeTheme.Typography.metadata)
        .foregroundStyle(tint)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: maximumWidth, alignment: .leading)
        .accessibilityLabel(betaBadge ? Text("\(title) \(Text("localmodels.beta_badge"))") : title)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(FloeTheme.groupedSurface, in: Capsule())
    }
}

/// The same choices, symbols and selected mark in each workbench composer.
struct FloeComposerModeMenu<Mode: Hashable>: View {
    let modes: [Mode]
    @Binding var selection: Mode
    let title: (Mode) -> LocalizedStringKey
    let symbol: (Mode) -> String
    var editGoalTitle = ""
    var editGoal: (() -> Void)? = nil
    let goal: Mode
    var maximumWidth: CGFloat = 280

    var body: some View {
        Menu {
            ForEach(modes, id: \.self) { mode in
                if mode == goal, let editGoal {
                    Button(editGoalTitle, systemImage: "target", action: editGoal)
                        .accessibilityIdentifier("composer.goal.edit")
                } else {
                    Button { selection = mode } label: {
                        Label(title(mode), systemImage: mode == selection ? "checkmark" : symbol(mode))
                    }
                }
            }
        } label: {
            FloeThreadComposerChip(title: Text(title(selection)), systemImage: symbol(selection),
                                   maximumWidth: maximumWidth)
        }
    }
}

struct FloeComposerRunningInputMenu: View {
    @Binding var queue: Bool
    var maximumWidth: CGFloat = 280

    var body: some View {
        Menu {
            Button { queue = true } label: {
                Label("chat.thread_composer_view.add_to_message_queue", systemImage: queue ? "checkmark" : "text.badge.plus")
            }
            Button { queue = false } label: {
                Label("chat.thread_composer_view.steer_the_current_run", systemImage: queue ? "arrow.triangle.turn.up.right.diamond" : "checkmark")
            }
        } label: {
            FloeThreadComposerChip(title: Text(LocalizedStringKey(queue ? "chat.thread_composer_view.queue" : "chat.thread_composer_view.steer")),
                                  systemImage: queue ? "text.badge.plus" : "arrow.triangle.turn.up.right.diamond",
                                  maximumWidth: maximumWidth)
        }
        .accessibilityLabel("chat.thread_composer_view.send_method_while_running")
    }
}

struct FloeWorkbenchControlIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            #if os(macOS)
            .font(.body.weight(.medium))
            #else
            .font(.title3)
            #endif
            .foregroundStyle(FloeTheme.primary)
    }
}

struct FloeComposerAttachmentChip: View {
    let name: String
    let systemImage: String
    var detail: Text? = nil
    let removeLabel: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).lineLimit(1)
                if let detail { detail }
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(removeLabel + " " + name)
        }
        .font(FloeTheme.Typography.metadata)
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .background(FloeTheme.groupedSurface, in: Capsule())
    }
}

struct FloeComposerActionGlyph: View {
    let systemImage: String
    var enabled = true
    var destructive = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: destructive ? 13 : 17, weight: .semibold))
            .foregroundStyle(enabled ? Color.white : Color.secondary)
            .frame(width: FloeTheme.sendButtonSize, height: FloeTheme.sendButtonSize)
            .background(background, in: Circle())
    }

    private var background: Color {
        guard enabled else { return Color.secondary.opacity(0.12) }
        return destructive ? FloeTheme.destructive : FloeTheme.primary
    }
}
#endif
