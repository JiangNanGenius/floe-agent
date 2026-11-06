import Foundation

/// UI-module error surface for host-contract violations and flow-run
/// lifecycle problems. These indicate a host wiring gap, never a silent
/// fallback: each maps to an actionable alert.
public enum CanvasEditorUIError: Error, Hashable, Sendable {
    /// `makeRunConfiguration` is required for flow runs but was not injected.
    case runConfigurationProviderMissing
    /// The host-provided run identity does not match the live document
    /// (canvas ID, current revision, or flow graph identity/revision).
    case runIdentityMismatch
    /// No Flow runtime is available (host did not inject one).
    case flowRuntimeMissing
    /// The run to attach does not exist in the trusted runtime.
    case runNotFound(UUID)
    /// Script/API nodes require a real host environment but none is bound.
    case environmentRequired
    /// A recognized geometry/edit precondition failed (actionable alert).
    case invalidInput(String)
}
