//
//  CommandDispatch.swift
//  openshape3d
//
//  Spec §8.4 — the half of the hotkey story `CommandRegistry` could not carry.
//
//  The registry is a pure, tested catalog of named commands and their chords,
//  but nothing ever ran one: until this file it had no references outside its
//  own test target, so every hotkey in the catalog was dead. Driving the
//  Shapr3D starter tutorials surfaced that as a real gap — the videos lean on
//  "press C for circle, A for arc, T for trim" throughout.
//
//  Two halves, split so the interesting one is testable:
//
//  * `routableIDs` + `unroutedChordedCommands` are pure statics on the
//    registry, so a unit test can assert which catalog entries actually reach
//    the editor without ever building an `EditorViewModel` (which owns a
//    `DocumentSession`, and a `ModelContainer` in-process crashes XCTest —
//    see STATUS_AND_NEXT_STEPS gotcha 1).
//  * `EditorViewModel.runCommand(_:)` is the thin, untestable half: one switch
//    onto entry points that already exist and are already exercised through
//    the tool palette.
//

import Foundation

// MARK: - Which catalog entries reach the editor

extension CommandRegistry {

    /// Command ids `EditorViewModel.runCommand(_:)` knows how to perform.
    ///
    /// Kept as data rather than inferred from the switch so a test can diff it
    /// against the catalog: adding a chorded command without routing it shows
    /// up in `unroutedChordedCommands` instead of silently doing nothing when
    /// the user presses the key.
    nonisolated static let routableIDs: Set<String> = [
        // Sketch tools — the tutorial's C / A / L / R / T / G.
        "sketch.line", "sketch.rectangle", "sketch.circle", "sketch.arc",
        "sketch.ellipse", "sketch.polygon", "sketch.text", "sketch.trim",
        "sketch.offset", "sketch.construction", "sketch.onHoveredPlane",

        // Modeling.
        "model.extrude", "model.revolve", "model.sweep", "model.loft",
        "model.fillet", "model.chamfer", "model.shell", "model.project",

        // Booleans.
        "bool.union", "bool.subtract", "bool.intersect",

        // Transform.
        "model.move", "transform.scaleUniform", "transform.pattern",

        // Direct modeling — the face tools shipped 2026-08-29.
        "model.deleteFace", "model.replaceFace",

        // The launcher itself: X and Cmd+F open Command Search.
        "app.commandSearch", "app.commandSearchAlt",

        // Edit.
        "edit.undo", "edit.redo", "edit.delete",

        // View.
        "view.front", "view.back", "view.left", "view.right",
        "view.top", "view.bottom", "view.isometric", "view.fit",
    ]

    /// Catalog entries that advertise a chord but have no editor entry point
    /// yet — Insert Image, Command Search, the project/import commands,
    /// Select All. Surfaced (and pinned by a test) so the gap stays visible
    /// rather than presenting as a key that quietly does nothing.
    static var unroutedChordedCommands: [AppCommand] {
        all.filter { $0.chord != nil && !routableIDs.contains($0.id) }
            .sorted { $0.id < $1.id }
    }

    /// Every routable command that has a chord — the set the UI needs to
    /// register with the system so a hardware keyboard can reach it.
    static var routableChordedCommands: [AppCommand] {
        all.filter { $0.chord != nil && routableIDs.contains($0.id) }
    }

    /// What Command Search is allowed to offer: commands `runCommand` can
    /// actually perform, minus the launcher itself.
    ///
    /// The catalog is deliberately WIDER than this — it also names commands
    /// whose editor entry points do not exist yet, and `unroutedChordedCommands`
    /// keeps that gap visible. A launcher must not show them: a result that
    /// does nothing when chosen is the same silent failure as a hotkey that
    /// does nothing, and harder to explain because the user just read the name
    /// off a list. `CommandSearchTests` pins the two sets together.
    nonisolated static var launchableCommands: [AppCommand] {
        all.filter {
            routableIDs.contains($0.id)
                && $0.id != "app.commandSearch" && $0.id != "app.commandSearchAlt"
        }
    }
}

// MARK: - Running one

extension EditorViewModel {

    /// Perform a catalog command, returning whether it actually ran.
    ///
    /// `false` means "not applicable right now" (wrong mode, nothing selected,
    /// no chord owner) and the caller should let the keystroke fall through
    /// rather than swallowing it. The guards deliberately mirror the tool
    /// palette's own `enabled` conditions, so a hotkey can never reach a state
    /// the equivalent button would have refused.
    @discardableResult
    func runCommand(_ id: String, honoringSingleKeyAction: Bool = true) -> Bool {
        guard let command = CommandRegistry.command(inCatalog: id) else { return false }

        // Honour the spec's Single Key Action setting. The registry is a pure
        // value and does not observe preferences, so sync its copy here rather
        // than keeping a second source of truth.
        commandRegistry.singleKeyAction = CADPreferences.shared.singleKeyAction
        // With the launcher preference on, a bare letter is a keystroke for
        // Command Search: open it pre-typed instead of firing the hotkey.
        // (`CommandShortcutsView` also stops registering bare-key hotkeys in
        // that mode, so this is the belt to its braces.)
        if honoringSingleKeyAction, command.chord?.isBareKey == true,
           commandRegistry.singleKeyAction == .commandSearch {
            openCommandSearch(seed: command.chord?.key ?? "")
            return true
        }

        guard perform(command) else { return false }
        commandRegistry.markUsed(id)
        return true
    }

    private func perform(_ command: AppCommand) -> Bool {
        switch command.id {

        // MARK: Sketch tools (only while a sketch is open)
        case "sketch.line":         return armSketchTool(.line)
        case "sketch.onHoveredPlane": return sketchOnHoveredPlane()
        case "sketch.rectangle":    return armSketchTool(.rect)
        case "sketch.circle":       return armSketchTool(.circle)
        case "sketch.arc":          return armSketchTool(.arc)
        case "sketch.ellipse":      return armSketchTool(.ellipse)
        case "sketch.polygon":      return armSketchTool(.polygon)
        case "sketch.text":         return armSketchTool(.text)
        case "sketch.trim":         return armSketchTool(.trim)
        case "sketch.offset":       return armSketchTool(.offset)
        case "model.project":       return armSketchTool(.project)

        case "sketch.construction":
            guard mode.isSketching, !selectedSketchEntityIDs.isEmpty else { return false }
            toggleConstructionOnSelection()
            return true

        // MARK: Creators — need a profile to act on, same as the palette
        case "model.extrude":       return armCreateTool(.extrude)
        case "model.revolve":       return armCreateTool(.revolve)
        case "model.sweep":         return armCreateTool(.sweep)
        case "model.loft":          return armCreateTool(.loft)

        // MARK: Blends and shell — need a body
        case "model.fillet":        return armBlend(.fillet)
        case "model.chamfer":       return armBlend(.chamfer)
        case "model.shell":
            guard !session.document.bodies.isEmpty else { return false }
            beginShell()
            return true

        // MARK: Direct-modeling face tools (spec §4.12 / §4.16)
        case "model.deleteFace":
            guard !session.document.bodies.isEmpty else { return false }
            beginDeleteFace()
            return true
        case "model.replaceFace":
            guard !session.document.bodies.isEmpty else { return false }
            beginReplaceFace()
            return true

        // MARK: The launcher itself
        case "app.commandSearch", "app.commandSearchAlt":
            commandSearchActive = true
            return true

        // MARK: Booleans — arm against exactly one selected body
        case "bool.union":          return armBooleanTool(.union)
        case "bool.subtract":       return armBooleanTool(.subtract)
        case "bool.intersect":      return armBooleanTool(.intersect)

        // MARK: Transform
        case "model.move":
            guard !selection.isEmpty || hasModelSketchSelection else { return false }
            beginMoveTool()
            return true
        case "transform.scaleUniform":
            guard !selection.isEmpty else { return false }
            beginScaleTool()
            return true
        case "transform.pattern":
            guard canBeginPattern else { return false }
            beginPattern()
            return true

        // MARK: Edit
        case "edit.undo":
            guard session.undoStack.canUndo else { return false }
            undo()
            return true
        case "edit.redo":
            guard session.undoStack.canRedo else { return false }
            redo()
            return true
        case "edit.delete":
            guard !selection.isEmpty || !selectedSketchEntityIDs.isEmpty else { return false }
            deleteSelection()
            return true

        // MARK: View
        case "view.front":      applyStandardView(.front);      return true
        case "view.back":       applyStandardView(.back);       return true
        case "view.left":       applyStandardView(.left);       return true
        case "view.right":      applyStandardView(.right);      return true
        case "view.top":        applyStandardView(.top);        return true
        case "view.bottom":     applyStandardView(.bottom);     return true
        case "view.isometric":  applyStandardView(.isometric);  return true
        case "view.fit":        fitView();                      return true

        default:
            return false
        }
    }

    // MARK: - Shared guards

    /// Arming a sketch tool that is already armed disarms it, matching the
    /// palette's tap-the-active-tool-to-drop-it toggle (and the tutorial's
    /// "press C again to get out of the circle command").
    private func armSketchTool(_ tool: SketchTool) -> Bool {
        guard case .sketching(_, let current) = mode else { return false }
        if current == tool {
            deselectSketchTool()
        } else {
            startSketch(tool: tool)
        }
        return true
    }

    private func armCreateTool(_ tool: CreateTool) -> Bool {
        guard hasExtrudableProfile else { return false }
        if pendingCreateTool == tool { cancelCreate() } else { beginCreate(tool) }
        return true
    }

    private func armBlend(_ kind: BlendKind) -> Bool {
        guard !session.document.bodies.isEmpty else { return false }
        if case .pickingBlendEdges(let current) = mode, current == kind {
            cancelBlend()
        } else {
            beginBlend(kind)
        }
        return true
    }

    private func armBooleanTool(_ kind: BooleanKind) -> Bool {
        if case .pickingBooleanTool(let current, _) = mode, current == kind {
            cancelBooleanPicking()
            return true
        }
        guard selection.count == 1 else { return false }
        armBoolean(kind)
        return true
    }
}

// MARK: - Catalog lookup without an instance

extension CommandRegistry {
    /// `command(id:)` is an instance method; the dispatcher only needs the
    /// catalog, so this avoids threading a registry through just to read it.
    nonisolated static func command(inCatalog id: String) -> AppCommand? {
        all.first { $0.id == id }
    }
}
