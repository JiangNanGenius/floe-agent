// SPDX-License-Identifier: MPL-2.0
import Foundation

/// One in-flight save request. The editor creates captures through
/// `BuildingEditorHistory.beginSave()` and returns them to the history when the
/// storage layer finishes. A capture identifies a save attempt for the current
/// UI lifecycle; it is not an authorization token.
public struct BuildingEditorSave<Value: Equatable & Sendable>: Sendable {
    public let id: UUID
    public let value: Value
    public let generation: UInt64

    init(id: UUID = UUID(), value: Value, generation: UInt64) {
        self.id = id
        self.value = value
        self.generation = generation
    }
}

/// Bounded, value-typed editor state with undo/redo and a single in-flight save
/// capture. The type owns no storage and performs no encoding; callers persist
/// `value` themselves and resolve the result through the capture lifecycle.
///
/// The initial value is always the logical saved baseline, even when
/// `isPersisted` is `false`. That lets a first save proceed without first
/// manufacturing a dirty edit, while `hasPersistedVersion` still distinguishes
/// a seed that never reached storage.
public struct BuildingEditorHistory<Value: Equatable & Sendable>: Sendable {
    private var currentValue: Value
    private var savedValue: Value
    private var persisted: Bool
    private var undoStack: [Value] = []
    private var redoStack: [Value] = []
    private var activeSave: BuildingEditorSave<Value>?
    private let historyLimit: Int
    private var revision: UInt64 = 0

    public init(value: Value, isPersisted: Bool = false, historyLimit: Int = 40) {
        self.currentValue = value
        self.savedValue = value
        self.persisted = isPersisted
        self.historyLimit = min(max(historyLimit, 0), 200)
    }

    public var value: Value { currentValue }

    public var isDirty: Bool { currentValue != savedValue }

    public var hasPersistedVersion: Bool { persisted }

    public var canUndo: Bool { !undoStack.isEmpty }

    public var canRedo: Bool { !redoStack.isEmpty }

    public var isSaving: Bool { activeSave != nil }

    /// Monotonic content revision. Saving alone does not advance it; value
    /// transitions, storage replacement and a real discard do.
    public var generation: UInt64 { revision }

    /// Applies a new value. Equal values are a no-op so observers are not
    /// invalidated for redundant assignments. A real edit retains a bounded
    /// snapshot of the previous value, invalidates redo, and advances the
    /// generation.
    @discardableResult
    public mutating func edit(_ value: Value) -> Bool {
        guard value != currentValue else { return false }
        pushUndo(currentValue)
        redoStack.removeAll(keepingCapacity: true)
        currentValue = value
        revision += 1
        return true
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        pushRedo(currentValue)
        currentValue = previous
        revision += 1
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        pushUndo(currentValue)
        currentValue = next
        revision += 1
        return true
    }

    /// Captures the exact current value and generation while allowing only one
    /// save to be in flight. The returned capture must be passed back to
    /// `acknowledgeSave(_:)` or `failSave(_:)`.
    public mutating func beginSave() -> BuildingEditorSave<Value>? {
        guard activeSave == nil else { return nil }
        let capture = BuildingEditorSave(value: currentValue, generation: revision)
        activeSave = capture
        return capture
    }

    /// Accepts only the active capture. The captured value becomes the saved
    /// baseline, so edits made while the save ran remain dirty. Undo/redo
    /// history is deliberately retained across a successful save.
    @discardableResult
    public mutating func acknowledgeSave(_ capture: BuildingEditorSave<Value>) -> Bool {
        guard let active = activeSave, Self.matches(active, capture) else { return false }
        activeSave = nil
        savedValue = capture.value
        persisted = true
        return true
    }

    /// Clears only the matching active save. Current edits, dirty state and
    /// undo/redo history are preserved so a retry can reuse them. Stale and
    /// foreign captures are ignored.
    @discardableResult
    public mutating func failSave(_ capture: BuildingEditorSave<Value>) -> Bool {
        guard let active = activeSave, Self.matches(active, capture) else { return false }
        activeSave = nil
        return true
    }

    /// Replaces the editor with storage-owned content. Undo/redo and any active
    /// save are cleared so callbacks from the previous editing session cannot
    /// mutate the new baseline. The generation always advances.
    public mutating func replaceFromStorage(_ value: Value, isPersisted: Bool = true) {
        currentValue = value
        savedValue = value
        persisted = isPersisted
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
        activeSave = nil
        revision += 1
    }

    /// Restores the saved baseline and clears undo/redo plus any active save.
    /// The persisted flag and baseline stay intact. Returns `false` and leaves
    /// the generation unchanged when the editor is already a clean, empty
    /// session.
    @discardableResult
    public mutating func discardChanges() -> Bool {
        let hadHistory = !undoStack.isEmpty || !redoStack.isEmpty
        let hadActiveSave = activeSave != nil
        let hadValueChange = currentValue != savedValue
        guard hadValueChange || hadHistory || hadActiveSave else { return false }
        currentValue = savedValue
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
        activeSave = nil
        revision += 1
        return true
    }

    private mutating func pushUndo(_ value: Value) {
        guard historyLimit > 0 else { return }
        undoStack.append(value)
        let excess = undoStack.count - historyLimit
        if excess > 0 {
            undoStack.removeFirst(excess)
        }
    }

    private mutating func pushRedo(_ value: Value) {
        guard historyLimit > 0 else { return }
        redoStack.append(value)
        let excess = redoStack.count - historyLimit
        if excess > 0 {
            redoStack.removeFirst(excess)
        }
    }

    private static func matches(
        _ active: BuildingEditorSave<Value>,
        _ capture: BuildingEditorSave<Value>
    ) -> Bool {
        active.id == capture.id
            && active.value == capture.value
            && active.generation == capture.generation
    }
}
