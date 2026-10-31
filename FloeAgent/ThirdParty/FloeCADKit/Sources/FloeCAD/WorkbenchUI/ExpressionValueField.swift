//
//  ExpressionValueField.swift
//  openshape3d
//
//  A bar value field that holds TEXT and applies it LIVE: every keystroke
//  that evaluates (the evaluator's arithmetic — "1*0+23", "25.4/2") lands in
//  the bound value, so the tool's preview follows the typing and the bar's
//  Apply button can never commit a stale number.
//
//  Born from the fillet bar (2026-09-04): its formatted numeric field flushed
//  only on Return, could not take an expression, and a hardware keyboard has
//  no select-all — so "type 23, tap Apply" filleted at the field's old 1 mm
//  while showing "1*0+23". The extrude bar's Distance field had the same bug
//  the day before (gotcha 37) and got the same cure.
//
//  It is now the ONE numeric field in the bars. A `TextField(value:format:)`
//  cannot take an expression, cannot apply live, and cannot host the number
//  pad (which edits a String), so every such field migrated here. `Kind` is
//  why that was possible: not everything numeric is a length.
//

import SwiftUI

struct ExpressionValueField: View {
    /// What the bound number MEANS, which decides whether the display unit
    /// applies to it. A length is stored in millimetres and shown in the user's
    /// unit; an angle, a count and a scale factor are already in the terms the
    /// user reads, and converting them would be nonsense (45° is not 4.5 cm°).
    enum Kind { case length, plain }

    var placeholder: String
    /// Millimetres when `kind == .length`; otherwise the value as displayed.
    @Binding var value: Double
    var kind: Kind = .length
    /// Applied to the BOUND value, not to the text, so typing is never fought.
    var clamp: ClosedRange<Double>?
    var width: CGFloat = 64
    var identifier: String
    /// Return in the field, or the pad's commit key, after the value is applied.
    var onSubmit: () -> Void = {}

    @State private var text = ""
    @State private var padOpen = false
    /// Set once the person asks for the real keyboard (a variable name or a
    /// function is not something a ten-key can express).
    @State private var usingSystemKeyboard = CADPreferences.prefersSystemKeyboard
    @FocusState private var focused: Bool

    private var unit: DisplayUnit { CADPreferences.shared.unit }

    private func display(_ value: Double) -> String {
        let shown = kind == .length ? unit.display(fromMM: value) : value
        if abs(shown - shown.rounded()) < 1e-6 { return String(Int(shown.rounded())) }
        return String(format: "%g", (shown * 1000).rounded() / 1000)
    }

    private func apply(_ string: String) -> Bool {
        guard let typed = ExpressionEvaluator.evaluate(string) else { return false }
        var applied = kind == .length ? unit.mm(fromDisplay: typed) : typed
        if let clamp {
            applied = Swift.min(Swift.max(applied, clamp.lowerBound), clamp.upperBound)
        }
        if abs(applied - value) > 1e-9 { value = applied }
        return true
    }

    var body: some View {
        field
            // Tapping the field opens the pad rather than the system keyboard,
            // which on an iPad covers the bar the field is in.
            .contentShape(Rectangle())
            .onTapGesture { if !usingSystemKeyboard { padOpen = true } }
            .numericKeypad(
                isPresented: $padOpen,
                text: $text,
                onCommit: {
                    _ = apply(text)
                    padOpen = false
                    onSubmit()
                },
                onSwitchToSystemKeyboard: {
                    padOpen = false
                    usingSystemKeyboard = true
                    focused = true
                }
            )
    }

    private var field: some View {
        TextField(placeholder, text: $text)
            .keyboardType(.numbersAndPunctuation)
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .allowsHitTesting(usingSystemKeyboard)
            .onAppear { text = display(value) }
            // A drag on the tool's handle moves the value under the field;
            // mirror it unless the person is mid-edit.
            .onChange(of: value) { _, new in
                if !focused && !padOpen { text = display(new) }
            }
            .onChange(of: text) { _, new in
                if focused || padOpen { _ = apply(new) }
            }
            .onSubmit {
                _ = apply(text)
                onSubmit()
            }
            .accessibilityIdentifier(identifier)
    }
}
