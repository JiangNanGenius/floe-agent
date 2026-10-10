//
//  CommandShortcutsView.swift
//  openshape3d
//
//  Spec §8.4 — how a hardware-keyboard chord physically reaches the editor.
//
//  Zero-sized buttons whose only job is to carry `.keyboardShortcut`. That
//  looks odd, but it is the mechanism that works here, and it is already the
//  pattern the constraint hotkeys use in `ToolPaletteView`:
//
//  * `.keyboardShortcut` lowers to a `UIKeyCommand`, which UIKit consults on
//    the responder chain APP-WIDE — it does not need the viewport to hold
//    focus, unlike `onKeyPress`, which the Metal view cannot reliably take.
//  * The first responder wins first, so a focused text field still receives
//    plain letters: typing "circle" into a History rename field types the
//    word instead of arming Circle, Arc, Line… No extra guard needed.
//  The list comes from `CommandRegistry.routableChordedCommands`, so a chord
//  is registered only once something can actually run it.
//
//  **The labels are deliberately empty.** Titling these buttons is tempting —
//  it would populate the iPad ⌘-hold shortcut HUD, the closest thing we have
//  to the tutorials' "the hotkeys are shown as part of the tooltip". It also
//  breaks the UI suite: several tests match by title (`buttons["Extrude"]`,
//  see STATUS_AND_NEXT_STEPS gotcha 9), and a second, zero-framed "Extrude"
//  makes those queries ambiguous — the run fails with "Multiple matching
//  elements found", or resolves to this button and then cannot scroll a
//  {{inf, inf}, {0, 0}} frame into view. `.accessibilityHidden(true)` on the
//  container is NOT enough; the children stay queryable. An `EmptyView` label
//  leaves nothing to match. If the HUD is ever wanted, give these real
//  identifiers and move the UI suite off title-based queries first.
//

import SwiftUI

struct CommandShortcutsView: View {
    @Bindable var viewModel: EditorViewModel

    /// Spec §8.4's Single Key Action. With Command Search chosen, a bare
    /// letter is a keystroke for the LAUNCHER, so the bare-key hotkeys are not
    /// registered at all and every letter opens the panel pre-typed instead.
    /// Chorded shortcuts are untouched either way.
    private var launcherOwnsBareKeys: Bool {
        CADPreferences.shared.singleKeyAction == .commandSearch
    }

    /// Registering a–z (rather than only the letters that happen to be
    /// hotkeys) is what makes the setting mean what it says: ANY letter opens
    /// the launcher. A focused text field still wins — the first responder is
    /// consulted before these, which is why typing in a rename field is safe.
    private static let letters = "abcdefghijklmnopqrstuvwxyz".map(String.init)

    var body: some View {
        ZStack {
            if viewModel.canTypeRectangleBaseline {
                ForEach(Array("0123456789."), id: \.self) { character in
                    Button { viewModel.beginRectangleBaselineEdit(firstCharacter: String(character)) }
                        label: { EmptyView() }
                        .keyboardShortcut(KeyEquivalent(character), modifiers: [])
                        .accessibilityHidden(true)
                }
            }
            if viewModel.mode.sketchTool == .arc, viewModel.pendingArc != nil,
               viewModel.editingDimension == nil {
                Button { viewModel.finishArcInput() } label: { EmptyView() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHidden(true)
            }
            if viewModel.mode.sketchTool == .line,
               viewModel.editingDimension == nil {
                Button { viewModel.finishLineInput() } label: { EmptyView() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHidden(true)
            }
            if viewModel.commandSearchActive {
                // The launcher's close button owns Escape while it is open.
                // A competing editor command can otherwise exit the sketch
                // (or cancel a tool) while leaving the search overlay visible.
                Button { viewModel.closeCommandSearch() } label: { EmptyView() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHidden(true)
            } else if viewModel.editingDimension != nil {
                Button { viewModel.cancelDimensionEdit() } label: { EmptyView() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHidden(true)
            } else if viewModel.isPickingSymmetryAxis {
                Button { viewModel.cancelSymmetryAxisPick() } label: { EmptyView() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHidden(true)
            } else if viewModel.mode.sketchTool == .line {
                Button { viewModel.cancelLineInput() } label: { EmptyView() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHidden(true)
                Button { viewModel.deleteLineInput() } label: { EmptyView() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .accessibilityHidden(true)
            } else if viewModel.mode.sketchTool == .rect {
                Button { viewModel.cancelRectangleInput() } label: { EmptyView() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHidden(true)
            } else if viewModel.mode.sketchTool == .circle {
                Button { viewModel.cancelCircleInput() } label: { EmptyView() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHidden(true)
            } else if viewModel.mode.sketchTool == .arc {
                Button { viewModel.cancelArcInput() } label: { EmptyView() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHidden(true)
            } else if viewModel.canExitSketchWithEscape {
                Button { viewModel.finishSketch() } label: { EmptyView() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHidden(true)
            }
            ForEach(CommandRegistry.routableChordedCommands) { command in
                if let chord = command.chord, let key = chord.keyEquivalent,
                   !(launcherOwnsBareKeys && chord.isBareKey) {
                    Button { viewModel.runCommand(command.id) } label: { EmptyView() }
                        .keyboardShortcut(key, modifiers: chord.eventModifiers)
                        .accessibilityHidden(true)
                }
            }
            if launcherOwnsBareKeys {
                ForEach(Self.letters, id: \.self) { letter in
                    Button {
                        viewModel.openCommandSearch(seed: letter)
                    } label: { EmptyView() }
                        .keyboardShortcut(KeyEquivalent(Character(letter)), modifiers: [])
                        .accessibilityHidden(true)
                }
            }
        }
        // Invisible and untappable: the buttons exist purely so their
        // shortcuts register. `.hidden()` alone would drop them from the
        // responder chain, so shrink and clear them instead.
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - KeyChord → SwiftUI

extension KeyChord {
    /// Nil for chords the catalog names but SwiftUI cannot express as a single
    /// `KeyEquivalent` (none today beyond "space", which is spelled out).
    var keyEquivalent: KeyEquivalent? {
        if key == "space" { return .space }
        guard key.count == 1, let character = key.first else { return nil }
        return KeyEquivalent(character)
    }

    /// Note the empty set is meaningful: `.keyboardShortcut(_:)` defaults to
    /// ⌘, so a bare letter has to pass `modifiers: []` explicitly.
    var eventModifiers: EventModifiers {
        var out: EventModifiers = []
        if modifiers.contains(.command) { out.insert(.command) }
        if modifiers.contains(.shift) { out.insert(.shift) }
        if modifiers.contains(.option) { out.insert(.option) }
        return out
    }
}
