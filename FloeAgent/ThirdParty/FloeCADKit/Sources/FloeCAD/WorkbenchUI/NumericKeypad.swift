//
//  NumericKeypad.swift
//  openshape3d
//
//  The on-canvas number pad (Shapr3D's dimension keypad). A CAD value is typed
//  with one thumb over the model, so the system keyboard is the wrong tool: it
//  covers half an iPad, carries an accessory bar the app does not want, and has
//  no ÷ or ± where you need them. This pad is compact, sits next to the value
//  it edits, and speaks the evaluator's language — parentheses, the four
//  operators and a trailing unit all round-trip through `ExpressionEvaluator`.
//
//  Purely a text editor: it mutates the bound string and reports intent. It
//  knows nothing about sketches, so any numeric field can adopt it.
//

import SwiftUI

struct NumericKeypad: View {
    @Binding var text: String
    /// Current dimension lock state. Nil hides the key for unrelated fields.
    var isLocked: Bool?
    var lockEnabled = true
    /// Dimension fields start with their measured value selected. Other
    /// numeric consumers retain append behavior unless they opt in.
    var initialValueSelected: Binding<Bool> = .constant(false)
    var onToggleLock: () -> Void = {}
    var onCommit: () -> Void
    /// Shown as the keyboard key; nil hides it (no system keyboard to fall to).
    var onSwitchToSystemKeyboard: (() -> Void)?

    /// Units the pad can append. The evaluator already tolerates a trailing
    /// unit, and `NumericKeypad.trailingUnit` reads it back for conversion.
    nonisolated static let units = ["mm", "cm", "m", "deg"]

    private var visibleUnits: [String] {
        switch CADPreferences.shared.unit {
        case .inches, .feet: ["ft", "in", "deg"]
        default: Self.units
        }
    }

    private static let keyW: CGFloat = 44
    private static let keyH: CGFloat = 36
    private static let gap: CGFloat = 6

    var body: some View {
        VStack(spacing: Self.gap) {
            secondaryRow
            HStack(alignment: .top, spacing: Self.gap) {
                digitsAndOperators
                actionColumn
            }
        }
        .padding(10)
        // A numeric editor must obscure the sketch points/edges below it.
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        // An identifier on a styled container collapses it into ONE element and
        // every key vanishes from the tree (STATUS gotcha: a11y container
        // collapse). `.contain` keeps the pad addressable AND its keys.
        // NOTE: removing this does NOT fix the second-shape bug — tried.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("NumericKeypad")
    }

    // MARK: Rows

    /// Parentheses and units — the keys that make an expression rather than a
    /// number. Flat, so they read as modifiers rather than digits.
    private var secondaryRow: some View {
        HStack(spacing: Self.gap) {
            ForEach(["(", ")"], id: \.self) { token in
                flatKey(token) { append(token) }
            }
            ForEach(visibleUnits, id: \.self) { unit in
                flatKey(unit) { appendUnit(unit) }
            }
        }
    }

    private var digitsAndOperators: some View {
        VStack(spacing: Self.gap) {
            keyRow("7", "8", "9", "÷")
            keyRow("4", "5", "6", "×")
            keyRow("1", "2", "3", "−")
            keyRow("±", "0", ".", "+")
        }
    }

    private func keyRow(_ keys: String...) -> some View {
        HStack(spacing: Self.gap) {
            ForEach(keys, id: \.self) { digitKey($0) }
        }
    }

    /// Backspace, lock and a double-height commit — the column Shapr3D puts
    /// down the right-hand side.
    private var actionColumn: some View {
        VStack(spacing: Self.gap) {
            iconKey("delete.left", id: "KeypadDelete", action: backspace)
            if let isLocked {
                iconKey(isLocked ? "lock.fill" : "lock.open",
                        id: "KeypadLock",
                        tint: .primary,
                        action: onToggleLock)
                    .disabled(!lockEnabled)
                    .opacity(lockEnabled ? 1 : 0.35)
            } else if onSwitchToSystemKeyboard != nil {
                Color.clear.frame(width: Self.keyW, height: Self.keyH)
            }
            Button(action: onCommit) {
                Image(systemName: "checkmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.keyW,
                           height: Self.keyH * 2 + Self.gap)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            // Named for the PAD, not for dimensions — every numeric field uses it.
            .accessibilityIdentifier("KeypadCommit")
        }
    }

    // MARK: Keys

    private func digitKey(_ key: String) -> some View {
        Button(action: { press(key) }) {
            Text(key)
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: Self.keyW, height: Self.keyH)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                // Without an explicit content shape the tappable region is the
                // GLYPH, not the key: a 44×36 button whose hit area is the
                // digit's own ink. Every digit reported hittable with a correct
                // frame and still swallowed taps.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Keypad-\(key)")
    }

    private func flatKey(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Keypad-\(title)")
    }

    private func iconKey(_ symbol: String, id: String,
                         tint: Color = .primary,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: Self.keyW, height: Self.keyH)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: Editing

    /// The pad prints the operators the way CAD reads them (× ÷ −) but the
    /// evaluator parses ASCII, so translate on the way in rather than teaching
    /// the parser three more symbols.
    private static let asciiForKey: [String: String] = [
        "×": "*", "÷": "/", "−": "-",
    ]

    private func press(_ key: String) {
        if key == "±" { toggleSign(); return }
        append(Self.asciiForKey[key] ?? key)
    }

    /// ASSIGN, never mutate in place. `text.append(token)` through the binding
    /// silently does nothing here — the in-place `_modify` never reaches the
    /// binding's setter — while `text = text + token` does. `backspace` and
    /// `appendUnit` already assigned, which is why the delete and unit keys
    /// worked while every digit was swallowed.
    private func append(_ token: String) {
        let replaces = initialValueSelected.wrappedValue &&
            (token.first?.isNumber == true || token == "." || token == "(")
        initialValueSelected.wrappedValue = false
        text = replaces ? token : text + token
    }

    /// A unit belongs at the END of the expression, and there can only be one —
    /// tapping mm then cm should read "cm", not "mm cm".
    private func appendUnit(_ unit: String) {
        initialValueSelected.wrappedValue = false
        var base = text
        if let existing = Self.trailingUnit(in: base) {
            base = String(base.dropLast(existing.count))
                .trimmingCharacters(in: .whitespaces)
        }
        text = base + " " + unit
    }

    /// Negate rather than blindly prepending "-", so ± is its own inverse.
    private func toggleSign() {
        initialValueSelected.wrappedValue = false
        if text.hasPrefix("-") { text = String(text.dropFirst()) } else { text = "-" + text }
    }

    private func backspace() {
        if initialValueSelected.wrappedValue {
            initialValueSelected.wrappedValue = false
            text = ""
            return
        }
        guard !text.isEmpty else { return }
        // A unit reads as one key, so one tap removes the whole suffix.
        if let unit = Self.trailingUnit(in: text) {
            text = String(text.dropLast(unit.count)).trimmingCharacters(in: .whitespaces)
            return
        }
        text = String(text.dropLast())
    }

    /// The trailing unit token, if the text ends in one of `units`.
    /// Returns the matched token INCLUDING nothing else, so callers can both
    /// strip it and map it to a `DisplayUnit`.
    nonisolated static func trailingUnit(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Longest first so "mm" is never mistaken for a trailing "m".
        // Recognition includes both families, regardless of the visible unit row.
        return (units + ["in", "ft"]).sorted { $0.count > $1.count }
            .first { token in
                guard trimmed.hasSuffix(token) else { return false }
                let body = trimmed.dropLast(token.count)
                // Do not mistake a variable such as `pin` for an inch suffix.
                return body.last.map { !$0.isLetter && $0 != "_" } ?? false
            }
    }
}

// MARK: - Attaching the pad to a field

extension View {
    /// Attach the number pad to a numeric field as a popover.
    ///
    /// The canvas dimension field builds its own card because it floats over
    /// the model and has to sit beside the value it edits. Every other numeric
    /// field lives in a bar or a panel, where an anchored popover is both less
    /// code and the platform-correct shape — it positions itself, points at the
    /// field, and dismisses on an outside tap. `.presentationCompactAdaptation`
    /// keeps it a popover on iPhone instead of becoming a half sheet.
    func numericKeypad(
        isPresented: Binding<Bool>,
        text: Binding<String>,
        onCommit: @escaping () -> Void,
        onSwitchToSystemKeyboard: (() -> Void)? = nil
    ) -> some View {
        popover(isPresented: isPresented) {
            NumericKeypad(
                text: text,
                isLocked: nil,
                onCommit: onCommit,
                onSwitchToSystemKeyboard: onSwitchToSystemKeyboard
            )
            .padding(4)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// Attaches the pad to a numeric text field and OWNS the little bit of state
/// that needs — which is why it is a `ViewModifier` and not a function: each
/// application site gets its own `padOpen`, so one line converts a field.
private struct NumericPadAttachment: ViewModifier {
    @Binding var text: String
    var onCommit: () -> Void

    @State private var padOpen = false
    @State private var usingSystemKeyboard = CADPreferences.prefersSystemKeyboard

    func body(content: Content) -> some View {
        content
            // While the pad is the input method the field is a display, so a
            // tap opens the pad instead of raising the system keyboard.
            .allowsHitTesting(usingSystemKeyboard)
            .contentShape(Rectangle())
            .onTapGesture { if !usingSystemKeyboard { padOpen = true } }
            .numericKeypad(
                isPresented: $padOpen,
                text: $text,
                onCommit: {
                    padOpen = false
                    onCommit()
                },
                onSwitchToSystemKeyboard: {
                    padOpen = false
                    usingSystemKeyboard = true
                }
            )
    }
}

extension View {
    /// One-line adoption for a numeric text field.
    func numericKeypadField(text: Binding<String>,
                            onCommit: @escaping () -> Void) -> some View {
        modifier(NumericPadAttachment(text: text, onCommit: onCommit))
    }
}
