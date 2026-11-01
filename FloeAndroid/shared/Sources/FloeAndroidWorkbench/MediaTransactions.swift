// FloeWorkbench — Transaction engine shared by the store, UI and tool.
//
// Nonisolated and value-based so it works identically on the actor store,
// the main-actor view model and the model-facing tool. Every transaction is
// draft-then-commit: a rejected command anywhere in a sequence leaves the
// passed document exactly as it was. Undo/redo always advances the revision.

import Foundation
import FloeCore

public enum MediaTransactions {
    public static let defaultUndoDepth = 100

    /// Applies one command as one undoable transaction.
    public static func apply(_ command: MediaEditCommand, to project: inout MediaProject,
                             undoDepth: Int = defaultUndoDepth) throws {
        try apply([command], to: &project, undoDepth: undoDepth)
    }

    /// Applies a command sequence as ONE undoable transaction. On failure
    /// nothing is committed (no partial edits, no revision advance).
    public static func apply(_ commands: [MediaEditCommand], to project: inout MediaProject,
                             undoDepth: Int = defaultUndoDepth) throws {
        var draft = project
        for command in commands {
            try MediaEditCommandApplier.apply(command, to: &draft)
        }
        // No-op rejection: a command that leaves the editable state unchanged
        // must not create a revision or an empty undo step (slider commits,
        // repeated reorder, same-value updates).
        guard draft.memento() != project.memento() else { return }
        let checkpoint = project.memento()
        draft.revision = project.revision + 1
        draft.undoHistory = bounded(project.undoHistory + [checkpoint], depth: undoDepth)
        draft.redoHistory = []
        project = draft
    }

    @discardableResult
    public static func undo(_ project: inout MediaProject, undoDepth: Int = defaultUndoDepth) -> Bool {
        navigate(&project, stack: \.undoHistory, push: \.redoHistory, undoDepth: undoDepth)
    }

    @discardableResult
    public static func redo(_ project: inout MediaProject, undoDepth: Int = defaultUndoDepth) -> Bool {
        navigate(&project, stack: \.redoHistory, push: \.undoHistory, undoDepth: undoDepth)
    }

    public static func canUndo(_ project: MediaProject) -> Bool { !project.undoHistory.isEmpty }
    public static func canRedo(_ project: MediaProject) -> Bool { !project.redoHistory.isEmpty }

    private static func navigate(
        _ project: inout MediaProject,
        stack: WritableKeyPath<MediaProject, [MediaProjectMemento]>,
        push: WritableKeyPath<MediaProject, [MediaProjectMemento]>,
        undoDepth: Int
    ) -> Bool {
        guard let destination = project[keyPath: stack].last else { return false }
        let current = project.memento()
        var draft = project
        draft.restore(destination)
        draft.revision = project.revision + 1
        var source = project[keyPath: stack]
        source.removeLast()
        draft[keyPath: stack] = source
        draft[keyPath: push] = bounded(project[keyPath: push] + [current], depth: undoDepth)
        project = draft
        return true
    }

    private static func bounded(_ stack: [MediaProjectMemento], depth: Int) -> [MediaProjectMemento] {
        guard stack.count > depth else { return stack }
        return Array(stack.suffix(depth))
    }
}
