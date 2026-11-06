import Foundation
import FloeCanvasCore

/// Explicit host fork request for a professional child project (image,
/// video, CAD, mind-map). A canvas copy NEVER shallow-copies a mutable
/// child project as if it were independent: the original binding is
/// preserved until the host returns an actual new binding from this
/// gateway.
public struct CanvasEditorForkRequest: Hashable, Sendable {
    public var reference: CanvasEditorReference
    public var context: CanvasRuntimeContext
    /// Host-defined reason (e.g. "canvas.copy", "variant.branch").
    public var reason: String?

    public init(
        reference: CanvasEditorReference,
        context: CanvasRuntimeContext,
        reason: String? = nil
    ) {
        self.reference = reference
        self.context = context
        self.reason = reason
    }
}

public struct CanvasEditorForkResult: Hashable, Sendable {
    /// The unchanged original binding.
    public var original: CanvasEditorReference
    /// The new child-project binding created by the host.
    public var forked: CanvasEditorReference

    public init(original: CanvasEditorReference, forked: CanvasEditorReference) {
        self.original = original
        self.forked = forked
    }
}

public protocol CanvasEditorForkGateway: Sendable {
    func forkEditor(
        _ request: CanvasEditorForkRequest
    ) async throws -> CanvasEditorForkResult
}
