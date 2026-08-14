// FloeImages — Value-type edit history for non-destructive image editing.
//
// See docs/ALPHA_DAILY_PLAN.md §"Files, documents and images": an edit
// session is the source plus an ordered list of operations, enabling
// undo/redo and reproducible re-render. The source is never mutated.

import Foundation
import CoreGraphics
import FloeCore

/// A non-destructive image edit session: the immutable source plus an
/// ordered operation history with an undo cursor. Re-rendering applies the
/// operations from the source deterministically.
public struct ImageEditSession: Sendable, Identifiable, Hashable {
    public let id: UUID
    /// The original image, never mutated.
    public let source: CGImage
    /// All operations applied, in order.
    public private(set) var operations: [ImageOperation]
    /// Undo cursor: operations[0..<appliedCount] are currently applied.
    public private(set) var appliedCount: Int

    public init(id: UUID = UUID(), source: CGImage) {
        self.id = id
        self.source = source
        self.operations = []
        self.appliedCount = 0
    }

    /// Operations currently in effect (after undo).
    public var appliedOperations: [ImageOperation] {
        Array(operations.prefix(appliedCount))
    }

    public var canUndo: Bool { appliedCount > 0 }
    public var canRedo: Bool { appliedCount < operations.count }

    /// Appends a validated operation. Clears any redo tail.
    public mutating func apply(_ operation: ImageOperation) throws {
        try operation.validate()
        if appliedCount < operations.count {
            operations = Array(operations.prefix(appliedCount))
        }
        operations.append(operation)
        appliedCount += 1
    }

    public mutating func undo() {
        if canUndo { appliedCount -= 1 }
    }

    public mutating func redo() {
        if canRedo { appliedCount += 1 }
    }

    /// Re-renders the current state by replaying the applied operations
    /// from the source. Deterministic: identical operations on the same
    /// source produce identical output.
    public func render(using pipeline: ImagePipeline) throws -> CGImage {
        var image = source
        for operation in appliedOperations {
            image = try pipeline.apply(operation, to: image)
        }
        return image
    }
}
