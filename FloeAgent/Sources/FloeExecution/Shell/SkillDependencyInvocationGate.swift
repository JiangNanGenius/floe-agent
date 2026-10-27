// FloeExecution — skill dependency invocation gate seam.
//
// `exec.shell` accepts an OPTIONAL `skillID` for one reviewed reason: the app's
// official Skill dependency channel (FloeSkills/SkillDependency.swift +
// FloeApp/Skills/SkillDependencyPreparationCenter.swift) needs the exact skill
// identity of the invocation to verify the installed record, the current-run
// plan binding and the approval grant, then automatically prepare and read
// back the declared resources in the task's already-resolved Linux environment.
// FloeExecution never imports FloeSkills, so the seam is this tiny protocol:
// the app-side center implements it and `registerShellTools` receives it at
// construction. When the gate is absent, an invocation that carries `skillID`
// fails honestly (never silently ignoring the requested verification); when
// `skillID` is absent — the ordinary case — the tool behaves exactly as before
// and no gate code runs at all. The gate cannot mint approvals, widen
// policies or execute anything outside the existing reviewed verbs, and it
// never blocks a command that did not ask to be dependency-gated.

import Foundation
import FloeCore
import FloeTools

public enum SkillDependencyInvocationDecision: Sendable, Equatable {
    /// Installed record, current-run binding, grant and all REQUIRED declared
    /// resources verified for this environment; `annotation` is model-safe
    /// text (verified pins plus honest optional-gap notes) to surface in the
    /// command result. The already-approved command proceeds unchanged.
    case proceed(annotation: String)
    /// A required dependency is not ready or the binding/authority no longer
    /// matches. Only THIS skill's dependency-aware invocation is refused with
    /// the model-safe `reason`; ordinary shell commands (no `skillID`) are
    /// untouched so a run can always repair itself.
    case refused(reason: String)
    /// Provisioning cannot be honored in this build (service not wired, or no
    /// approval grant on the calling context). Refused honestly; nothing ran.
    case unavailable(reason: String)
}

public protocol SkillDependencyInvocationGating: Sendable {
    /// Verify the installed record + current run + grant for `skillID`, then
    /// prepare and read back the declared dependencies IN THE CALLER'S ALREADY
    /// RESOLVED environment (`environmentID`). Runs nothing, approves nothing
    /// and never picks or reroutes an environment.
    func dependencyInvocationDecision(
        skillID: String,
        environmentID: String?,
        runID: UUID,
        approvalGrantID: UUID?,
        cancellation: CancellationToken?
    ) async -> SkillDependencyInvocationDecision
}
