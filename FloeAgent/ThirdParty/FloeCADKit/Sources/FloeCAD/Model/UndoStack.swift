//
//  UndoStack.swift
//  openshape3d
//
//  Own command stack rather than UndoManager: no responder-chain surprises,
//  and drag coalescing is explicit (amendLast).
//

import Foundation
import Observation

@MainActor
@Observable
final class UndoStack {
    private(set) var undoCommands: [DocumentCommand] = []
    private(set) var redoCommands: [DocumentCommand] = []
    private let limit = 50

    var canUndo: Bool { !undoCommands.isEmpty }
    var canRedo: Bool { !redoCommands.isEmpty }
    var undoTitle: String? { undoCommands.last?.title }

    func perform(_ command: DocumentCommand, on document: inout DesignDocument) {
        command.apply(to: &document)
        undoCommands.append(command)
        if undoCommands.count > limit {
            undoCommands.removeFirst()
        }
        redoCommands.removeAll()
    }

    /// Replace the most recent command (drag coalescing: push once on gesture
    /// end, then amend if the same interaction continues).
    func amendLast(_ command: DocumentCommand, on document: inout DesignDocument) {
        guard !undoCommands.isEmpty else {
            perform(command, on: &document)
            return
        }
        undoCommands[undoCommands.count - 1] = command
        command.apply(to: &document)
    }

    func undo(on document: inout DesignDocument) {
        guard let command = undoCommands.popLast() else { return }
        command.revert(in: &document)
        redoCommands.append(command)
    }

    func redo(on document: inout DesignDocument) {
        guard let command = redoCommands.popLast() else { return }
        command.apply(to: &document)
        undoCommands.append(command)
    }

    func reset() {
        undoCommands.removeAll()
        redoCommands.removeAll()
    }
}
