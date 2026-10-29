// FloeSkillsTests — task-path Hub install authorization (build-303 repair).
//
// These suites pin the DEADLOCK FIX itself, not a happy-path string:
// - `SkillHubTaskInstallPolicy` is the single pure decision every policy
//   (full-access / automatic / approval-model / manual-human) funnels
//   through. Effective authority is considered BEFORE any prompt: a
//   standing-policy grant already covers an added-scope update, while a
//   one-off human card grant owes exactly one nested inline exact-delta
//   decision. "Installation grant and existing authorized capabilities
//   must not be requested twice."
// - The nested wait rides the runtime's canonical `.waitingApproval`
//   lifecycle through `RuntimeNestedApprovalHandle` (runtime-side lifecycle
//   proofs live in FloeAgentRuntimeTests); at THIS boundary the contract is
//   deterministic: approve → the SAME call returns the real typed receipt;
//   deny → terminal review-declined with nothing installed; cancelled →
//   honest cancellation; no surface → honest retryable failure. There is
//   NEVER a pending-review action state and never a workspace fallback.
// Fakes supply verified metadata shapes only; no network, no App UI, no
// polling waits.

import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeSkills

private let authPinY = String(repeating: "b", count: 40)
private let authDigestD = String(repeating: "d", count: 64)

private func authReceipt(skillID: String = "hub-candidate") throws -> SkillHubInstallReceipt {
    try SkillHubInstallReceipt(
        status: .installed,
        skillID: skillID,
        version: "1.0.0",
        contentDigest: authDigestD,
        packageSHA256: String(repeating: "e", count: 64),
        catalogDigest: String(repeating: "c", count: 64),
        reviewDigest: String(repeating: "f", count: 64),
        sourceCommit: String(repeating: "a", count: 40),
        publicationCommit: authPinY,
        containsScripts: false,
        fileCount: 3,
        totalBytes: 2_048,
        reviewedCapabilities: ["data.transform"],
        reviewedTools: ["exec.shell"]
    )
}

private func authContext(runID: UUID = UUID(), conversationID: UUID = UUID(),
                         toolCallID: String = "call-auth-1",
                         approved: Bool = true, temporary: Bool = false,
                         origin: ToolApprovalOrigin? = .humanCard,
                         nested: RuntimeNestedApprovalHandle? = nil,
                         cancellation: CancellationToken = CancellationToken()) -> ToolContext {
    ToolContext(
        runID: runID,
        toolCallID: toolCallID,
        approvalGrantID: approved ? UUID() : nil,
        cancellation: cancellation,
        conversationID: conversationID,
        temporaryReadOnly: temporary,
        approvalOrigin: origin,
        nestedApproval: nested
    )
}

// MARK: - Pure decision matrix

@Suite("SkillInstallAuthorization.decision")
struct SkillHubTaskInstallDecisionTests {

    private func facts(temporaryReadOnly: Bool = false, grant: Bool = true,
                       declined: Bool = false, userChoice: Bool = false,
                       existingRow: Bool = false, delta: Bool = false,
                       caps: [String] = [], tools: [String] = [],
                       packages: [String] = [],
                       humanScoped: Bool = true, surface: Bool = true) -> SkillHubTaskInstallFacts {
        SkillHubTaskInstallFacts(temporaryReadOnly: temporaryReadOnly, hasApprovalGrant: grant,
                                 persistedDecline: declined, explicitUserChoiceBlocked: userChoice,
                                 existingRow: existingRow, deltaRequiresApproval: delta,
                                 addedCapabilities: caps, addedTools: tools,
                                 addedPythonPackageSpecs: packages,
                                 humanScopedApproval: humanScoped,
                                 inlineApprovalSurfaceAvailable: surface)
    }

    @Test("A brand-new audited skill proceeds: the build-303 park cannot be represented")
    func freshAuditedSkillNeverParks() {
        // The old bug: a NEW skill has no grants, so its delta lists
        // everything declared and was parked in a review the task could not
        // see. Under the call's real authorization it now commits directly,
        // and the commit registers only the declared internal ceiling.
        let decision = SkillHubTaskInstallPolicy.decide(facts(existingRow: false, delta: true,
                                                              caps: ["data.transform"], tools: ["exec.shell"]))
        #expect(decision == .proceedUnderCallAuthorization)
    }

    @Test("Full-access/automatic/approval-model runs never prompt twice for an added-scope update")
    func standingPolicyAuthorityNeedsNoRedundantPrompt() {
        // The user's standing policy choice authorized this call; the same
        // effective authority already exceeds the delta, so NO nested card
        // is requested — with or without a surface.
        for surface in [true, false] {
            let decision = SkillHubTaskInstallPolicy.decide(facts(
                existingRow: true, delta: true, caps: ["network.read"],
                humanScoped: false, surface: surface))
            #expect(decision == .proceedUnderCallAuthorization)
        }
    }

    @Test("A one-off human card grant owes exactly one nested exact-delta decision")
    func humanCardGrantRequestsInlineApproval() {
        let decision = SkillHubTaskInstallPolicy.decide(facts(
            existingRow: true, delta: true,
            caps: ["network.read"], tools: ["web.fetch"], packages: ["pandas==2.2.0"],
            humanScoped: true, surface: true))
        #expect(decision == .requestInlineDeltaApproval(addedCapabilities: ["network.read"],
                                                        addedTools: ["web.fetch"],
                                                        addedPythonPackageSpecs: ["pandas==2.2.0"]))
        // The decision carries ONLY the added facts — already-covered rights
        // are never re-requested.
    }

    @Test("A required prompt with no canonical surface fails honestly; nothing parks invisibly")
    func missingSurfaceRefuses() {
        #expect(SkillHubTaskInstallPolicy.decide(facts(
            existingRow: true, delta: true, caps: ["network.read"],
            humanScoped: true, surface: false)) == .refused(.approvalSurfaceUnavailable))
    }

    @Test("Unknown approval origin is treated conservatively as human-scoped")
    func unknownOriginIsConservative() {
        // `humanScopedApproval` defaults to true: a legacy context without a
        // runtime-issued origin never silently skips the delta decision.
        let conservative = SkillHubTaskInstallFacts(
            temporaryReadOnly: false, hasApprovalGrant: true, persistedDecline: false,
            explicitUserChoiceBlocked: false, existingRow: true, deltaRequiresApproval: true,
            addedCapabilities: ["network.read"], addedTools: [], addedPythonPackageSpecs: [])
        #expect(conservative.humanScopedApproval)
        #expect(!conservative.inlineApprovalSurfaceAvailable)
        #expect(SkillHubTaskInstallPolicy.decide(conservative) == .refused(.approvalSurfaceUnavailable))
    }

    @Test("Covered updates and fresh installs proceed under every origin")
    func coveredPathsProceed() {
        for humanScoped in [true, false] {
            #expect(SkillHubTaskInstallPolicy.decide(facts(existingRow: true, delta: false,
                                                           humanScoped: humanScoped))
                    == .proceedUnderCallAuthorization)
            #expect(SkillHubTaskInstallPolicy.decide(facts(existingRow: false, delta: true,
                                                           caps: ["workspace.write"],
                                                           humanScoped: humanScoped))
                    == .proceedUnderCallAuthorization)
        }
    }

    @Test("Temporary chat refuses even with a grant and never reaches the delta branch")
    func temporaryStaysDenied() {
        #expect(SkillHubTaskInstallPolicy.decide(facts(temporaryReadOnly: true, existingRow: false, delta: true,
                                                       caps: ["workspace.write"])) == .refused(.temporaryChat))
        #expect(SkillHubTaskInstallPolicy.decide(facts(temporaryReadOnly: true, grant: false)) == .refused(.temporaryChat))
    }

    @Test("No grant refuses regardless of origin or surface")
    func missingGrantRefuses() {
        #expect(SkillHubTaskInstallPolicy.decide(facts(grant: false, humanScoped: false, surface: true))
                == .refused(.approvalRequired))
    }

    @Test("A persisted decline is terminal; retries cannot re-prompt the same run/package")
    func persistedDeclineIsTerminal() {
        #expect(SkillHubTaskInstallPolicy.decide(facts(declined: true)) == .refused(.reviewDeclined))
        #expect(SkillHubTaskInstallPolicy.decide(facts(declined: true, existingRow: true, delta: true,
                                                       caps: ["network.read"])) == .refused(.reviewDeclined))
    }

    @Test("An explicit user state wins over proceed and over the delta request")
    func userChoiceWins() {
        #expect(SkillHubTaskInstallPolicy.decide(facts(userChoice: true)) == .refused(.userChoice))
        #expect(SkillHubTaskInstallPolicy.decide(facts(userChoice: true, existingRow: false, delta: true)) == .refused(.userChoice))
    }
}

// MARK: - Exact-delta card copy (bounded, verified facts only)

@Suite("SkillInstallAuthorization.deltaCopy")
struct SkillHubDeltaApprovalCopyTests {

    @Test("The facts line carries identity and ONLY the added entries")
    func factsLineIsExactDelta() {
        let line = SkillHubDeltaApprovalCopy.factsLine(
            skillID: "markitdown", version: "2.0.0", contentDigest: authDigestD,
            addedCapabilities: ["network.read"], addedTools: ["web.fetch"],
            addedPythonPackageSpecs: ["pandas==2.2.0"])
        #expect(line.contains("markitdown 2.0.0"))
        #expect(line.contains("digest " + String(authDigestD.prefix(12))))
        #expect(line.contains("adds capabilities: network.read"))
        #expect(line.contains("tools: web.fetch"))
        #expect(line.contains("packages: pandas==2.2.0"))
        // Covered rights and unrelated vocabulary never appear.
        #expect(!line.contains("data.transform"))
        #expect(!line.lowercased().contains("pending"))
    }

    @Test("Lists and the whole line stay bounded")
    func factsLineIsBounded() {
        let line = SkillHubDeltaApprovalCopy.factsLine(
            skillID: String(repeating: "s", count: 500), version: "1.0.0",
            contentDigest: authDigestD,
            addedCapabilities: (1...64).map { "capability-\($0)" },
            addedTools: (1...64).map { "tool.family-\($0)" },
            addedPythonPackageSpecs: (1...64).map { "pkg-\($0)==1.0.\($0)" })
        #expect(line.count <= 600)
        #expect(line.contains("+48"))
    }
}

// MARK: - End-to-end at the tool boundary (same-call resume, deterministic)

@Suite("SkillInstallAuthorization.toolSameCallResume")
struct SkillHubInstallSameCallResumeTests {

    /// Mirrors the repaired App bridge: the task-path decision runs on real
    /// context facts; an adds-scope update under a human card grant asks the
    /// runtime's nested seam ONCE and completes the SAME call with the real
    /// receipt after the decision.
    private actor NestedHubInstaller: SkillHubInstalling {
        private let receipt: SkillHubInstallReceipt
        private let outcome: NestedApprovalOutcome
        private(set) var reasons: [String] = []
        private(set) var calls = 0
        init(receipt: SkillHubInstallReceipt, outcome: NestedApprovalOutcome) {
            self.receipt = receipt
            self.outcome = outcome
        }
        func install(_ request: SkillHubInstallRequest, context: ToolContext) async throws -> SkillHubInstallReceipt {
            calls += 1
            let facts = SkillHubTaskInstallFacts(
                temporaryReadOnly: context.temporaryReadOnly,
                hasApprovalGrant: context.approvalGrantID != nil,
                persistedDecline: false, explicitUserChoiceBlocked: false,
                existingRow: true, deltaRequiresApproval: true,
                addedCapabilities: ["network.read"], addedTools: [], addedPythonPackageSpecs: [],
                humanScopedApproval: {
                    if let origin = context.approvalOrigin, case .policy = origin { return false }
                    return true
                }(),
                inlineApprovalSurfaceAvailable: context.nestedApproval != nil)
            switch SkillHubTaskInstallPolicy.decide(facts) {
            case .refused(let refusal):
                switch refusal {
                case .temporaryChat, .approvalRequired, .userChoice:
                    throw SkillHubInstallError.userChoiceBlocked
                case .reviewDeclined:
                    throw SkillHubInstallError.reviewDeclined
                case .approvalSurfaceUnavailable:
                    throw SkillUpgradeError.localConflict
                }
            case .proceedUnderCallAuthorization:
                return receipt
            case .requestInlineDeltaApproval(let caps, let tools, let packages):
                guard let handle = context.nestedApproval else { throw SkillUpgradeError.localConflict }
                let reason = "This update asks for new access. " + SkillHubDeltaApprovalCopy.factsLine(
                    skillID: request.id, version: receipt.version, contentDigest: receipt.contentDigest,
                    addedCapabilities: caps, addedTools: tools, addedPythonPackageSpecs: packages)
                reasons.append(reason)
                try context.cancellation.throwIfCancelled()
                switch await handle.request(reason: reason) {
                case .allowed:
                    return receipt
                case .denied:
                    throw SkillHubInstallError.reviewDeclined
                case .cancelled:
                    throw CancellationError()
                case .unavailable:
                    throw SkillUpgradeError.localConflict
                }
            }
        }
        func recordedReasons() -> [String] { reasons }
        func callCount() -> Int { calls }
    }

    private actor SilentWorkspaceInstaller: SkillWorkspaceInstalling {
        private(set) var planCount = 0
        func install(_ plan: SkillWorkspaceInstallPlan) async throws -> SkillWorkspaceInstallCommit {
            planCount += 1
            throw FloeError.validationFailed("workspace fallback must never run")
        }
        func plans() -> Int { planCount }
    }

    /// A handle whose decision is fixed up-front: the runtime-side waiting
    /// lifecycle (state, card, resolveApproval, cancellation edges) is
    /// proven in FloeAgentRuntimeTests; here the contract is what the tool
    /// boundary does with each outcome.
    private func fixedHandle(_ outcome: NestedApprovalOutcome,
                             capture: @escaping @Sendable (String) -> Void = { _ in })
        -> RuntimeNestedApprovalHandle {
        RuntimeNestedApprovalHandle { reason in
            capture(reason)
            return outcome
        }
    }

    @Test("Approving the nested card completes the SAME call with the real typed receipt")
    func approveFinishesSameCall() async throws {
        let workspace = SilentWorkspaceInstaller()
        let hub = NestedHubInstaller(receipt: try authReceipt(), outcome: .allowed)
        let tool = SkillWorkspaceInstallTool(installer: workspace, hub: hub)
        let context = authContext(toolCallID: "call-resume-1",
                                  nested: fixedHandle(.allowed))
        let result = try await tool.execute(.init(source: .hub, id: "hub-candidate"), context: context)
        #expect(result.exitStatus == 0)
        #expect(result.requiresUserAction == false)
        #expect(result.summary.contains("status=installed id=hub-candidate"))
        #expect(result.summary.contains("publicationCommit=" + authPinY))
        // Exactly one nested decision was requested, with the exact delta.
        let reasons = await hub.recordedReasons()
        #expect(reasons.count == 1)
        #expect(reasons[0].contains("adds capabilities: network.read"))
        #expect(!reasons[0].lowercased().contains("pending-review"))
        #expect(await hub.callCount() == 1)
        #expect(await workspace.plans() == 0)
    }

    @Test("Deny terminates the call honestly: no receipt fields, no workspace fallback")
    func denyIsTerminal() async throws {
        let workspace = SilentWorkspaceInstaller()
        let tool = SkillWorkspaceInstallTool(installer: workspace,
                                             hub: NestedHubInstaller(receipt: try authReceipt(), outcome: .denied(reason: "user denied")))
        let result = try await tool.execute(.init(source: .hub, id: "hub-candidate"),
                                            context: authContext(nested: fixedHandle(.denied(reason: "user denied"))))
        #expect(result.exitStatus == 1)
        #expect(result.requiresUserAction == false)
        #expect(result.summary.contains("status=review-declined"))
        #expect(!result.summary.contains("status=installed"))
        #expect(!result.summary.contains("status=pending-review"))
        #expect(await workspace.plans() == 0)
    }

    @Test("Cancellation during the nested wait surfaces cancelled, never a fake failure")
    func cancelDuringWait() async throws {
        let token = CancellationToken()
        let hub = NestedHubInstaller(receipt: try authReceipt(), outcome: .cancelled)
        let tool = SkillWorkspaceInstallTool(installer: SilentWorkspaceInstaller(), hub: hub)
        // The handle cancels the run token while "parked", exactly like the
        // runtime's cancel() interrupting a nested wait.
        let handle = RuntimeNestedApprovalHandle { _ in
            token.cancel()
            return .cancelled
        }
        await #expect(throws: FloeError.cancelled) {
            _ = try await tool.execute(.init(source: .hub, id: "hub-candidate"),
                                       context: authContext(nested: handle, cancellation: token))
        }
    }

    @Test("A required prompt without the runtime seam fails retryably; nothing parks")
    func missingSurfaceFailsHonestly() async throws {
        let workspace = SilentWorkspaceInstaller()
        let tool = SkillWorkspaceInstallTool(installer: workspace,
                                             hub: NestedHubInstaller(receipt: try authReceipt(), outcome: .allowed))
        let result = try await tool.execute(.init(source: .hub, id: "hub-candidate"),
                                            context: authContext(nested: nil))
        #expect(result.exitStatus == 1)
        #expect(result.requiresUserAction == false)
        #expect(result.summary.contains("status=failed"))
        #expect(!result.summary.contains("status=installed"))
        #expect(await workspace.plans() == 0)
    }

    @Test("A standing-policy grant proceeds with NO nested prompt at all")
    func policyGrantSkipsPrompt() async throws {
        let hub = NestedHubInstaller(receipt: try authReceipt(), outcome: .denied(reason: "must not be asked"))
        let tool = SkillWorkspaceInstallTool(installer: SilentWorkspaceInstaller(), hub: hub)
        let result = try await tool.execute(
            .init(source: .hub, id: "hub-candidate"),
            context: authContext(origin: .policy("full-access"),
                                 nested: fixedHandle(.denied(reason: "must not be asked"))))
        #expect(result.exitStatus == 0)
        #expect(result.summary.contains("status=installed"))
        #expect(await hub.recordedReasons().isEmpty, "sufficient effective authority must not prompt again")
    }
}
