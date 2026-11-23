// FloeMac MacScopedApprovalsTests — focused scoped tool/session approval
// tests for the Floe Mac workbench.
//
// SPDX-License-Identifier: MPL-2.0
//
// These tests exercise the REAL grant managers and the scoped approval
// policy against synthetic bindings: grants bind the exact descriptor
// identity + endpoint + authentication + arguments digest + workspace +
// task; only Ask-mode human escalations can be upgraded; automatic modes and
// the catastrophic boundaries stay authoritative. No database, Keychain or
// network — persistence uses an in-memory stub of the shared store seam.

import XCTest
import Foundation
#if canImport(FloeMacUnifiedParity)
@testable import FloeMacUnifiedParity
#endif
import FloeAgentRuntime
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity

// MARK: - In-memory persistence stub

private actor StubScopedPersistence: MacScopedToolGrantPersistence {
    var rows: [StoredGrant] = []

    func allGrants() async throws -> [StoredGrant] { rows }

    func saveGrant(_ grant: StoredGrant) async throws {
        rows.removeAll { $0.id == grant.id }
        rows.append(grant)
    }

    func deleteGrant(id: UUID) async throws {
        rows.removeAll { $0.id == id }
    }
}

// MARK: - Fixtures

private func makeBinding(toolName: String = "mcp_abc_alpha_lookup_0123",
                         descriptorIdentity: String = "identity-alpha",
                         endpoint: String = "http://127.0.0.1/mcp",
                         auth: String = "bearer") -> MacWorkbenchConnectorToolBinding {
    MacWorkbenchConnectorToolBinding(
        serverID: UUID(),
        toolName: toolName,
        descriptorIdentity: descriptorIdentity,
        endpointDigest: FloeDigest.sha256Hex(Data(endpoint.utf8)),
        authenticationDigest: FloeDigest.sha256Hex(Data(auth.utf8)),
        host: "127.0.0.1",
        remoteName: "alpha_lookup"
    )
}

private func makeAction(toolName: String, arguments: String = #"{"input":"x"}"#,
                        scope: ToolScope = .local,
                        hostAndPathScope: ToolScope = .local) throws -> ProposedAction {
    let call = try ToolCall(id: "call-1", toolName: toolName,
                            argumentsJSON: Data(arguments.utf8), scope: scope)
    return ProposedAction(
        toolCall: call,
        riskLabels: ["networkAccess", "modifiesRemoteSystem"],
        userGoal: "test the connector",
        hostAndPathScope: hostAndPathScope
    )
}

// MARK: - Tests

final class MacScopedApprovalsTests: XCTestCase {
    private var workspaceID: UUID!
    private var conversationID: UUID!
    private var otherConversationID: UUID!
    private var otherWorkspaceID: UUID!
    private var binding: MacWorkbenchConnectorToolBinding!

    override func setUp() {
        workspaceID = UUID()
        conversationID = UUID()
        otherConversationID = UUID()
        otherWorkspaceID = UUID()
        binding = makeBinding()
    }

    private func matches(_ grants: MacScopedToolGrants, conversationID: UUID,
                         descriptorIdentity: String = "identity-alpha",
                         endpointDigest: String? = nil,
                         authenticationDigest: String? = nil,
                         argumentsDigest: String) async throws -> Bool {
        try await grants.matches(
            toolName: binding.toolName, workspaceID: workspaceID, conversationID: conversationID,
            descriptorIdentity: descriptorIdentity,
            endpointDigest: endpointDigest ?? binding.endpointDigest,
            authenticationDigest: authenticationDigest ?? binding.authenticationDigest,
            argumentsDigest: argumentsDigest)
    }

    // MARK: Persisted task grants

    func testTaskGrantMatchesOnlyExactBindingAndTask() async throws {
        let store = StubScopedPersistence()
        let grants = MacScopedToolGrants(persistence: store)
        let argsDigest = MacWorkbenchConnectorToolBinding.argumentsDigest(Data(#"{"input":"x"}"#.utf8))

        try await grants.remember(scope: .task, workspaceID: workspaceID, conversationID: conversationID,
                                  toolName: binding.toolName, descriptorIdentity: binding.descriptorIdentity,
                                  endpointDigest: binding.endpointDigest,
                                  authenticationDigest: binding.authenticationDigest,
                                  argumentsDigest: argsDigest)
        let listed = try await grants.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].argumentsDigest, argsDigest)
        XCTAssertTrue(listed[0].bindingIdentity.contains("descriptor=identity-alpha"))
        // A repeated remember is the same row.
        try await grants.remember(scope: .task, workspaceID: workspaceID, conversationID: conversationID,
                                  toolName: binding.toolName, descriptorIdentity: binding.descriptorIdentity,
                                  endpointDigest: binding.endpointDigest,
                                  authenticationDigest: binding.authenticationDigest,
                                  argumentsDigest: argsDigest)
        let repeatedCount = try await grants.list().count
        XCTAssertEqual(repeatedCount, 1)

        // Exact match in the same task.
        let exact = try await matches(grants, conversationID: conversationID, argumentsDigest: argsDigest)
        XCTAssertTrue(exact)

        // Different arguments → a different remote operation, never granted.
        let otherArgs = MacWorkbenchConnectorToolBinding.argumentsDigest(Data(#"{"input":"y"}"#.utf8))
        let otherArguments = try await matches(grants, conversationID: conversationID, argumentsDigest: otherArgs)
        XCTAssertFalse(otherArguments)

        // Another task cannot use the grant.
        let otherTask = try await matches(grants, conversationID: otherConversationID, argumentsDigest: argsDigest)
        XCTAssertFalse(otherTask)

        // Another workspace cannot use the grant.
        let otherWorkspace = try await grants.matches(
            toolName: binding.toolName, workspaceID: otherWorkspaceID, conversationID: conversationID,
            descriptorIdentity: binding.descriptorIdentity, endpointDigest: binding.endpointDigest,
            authenticationDigest: binding.authenticationDigest, argumentsDigest: argsDigest)
        XCTAssertFalse(otherWorkspace)

        // A different tool identity cannot use the grant.
        let otherIdentity = try await matches(grants, conversationID: conversationID,
                                              descriptorIdentity: "identity-other", argumentsDigest: argsDigest)
        XCTAssertFalse(otherIdentity)

        // Revocation is immediate.
        let id = try await grants.list()[0].id
        try await grants.revoke(id: id)
        let afterRevoke = try await matches(grants, conversationID: conversationID, argumentsDigest: argsDigest)
        XCTAssertFalse(afterRevoke)
    }

    func testProjectGrantAppliesToEveryTaskInWorkspace() async throws {
        let grants = MacScopedToolGrants(persistence: StubScopedPersistence())
        let argsDigest = MacWorkbenchConnectorToolBinding.argumentsDigest(Data(#"{"input":"x"}"#.utf8))
        try await grants.remember(scope: .project, workspaceID: workspaceID, conversationID: conversationID,
                                  toolName: binding.toolName, descriptorIdentity: binding.descriptorIdentity,
                                  endpointDigest: binding.endpointDigest,
                                  authenticationDigest: binding.authenticationDigest,
                                  argumentsDigest: argsDigest)
        let sameWorkspace = try await matches(grants, conversationID: otherConversationID, argumentsDigest: argsDigest)
        XCTAssertTrue(sameWorkspace)
        let otherWorkspace = try await grants.matches(
            toolName: binding.toolName, workspaceID: otherWorkspaceID, conversationID: otherConversationID,
            descriptorIdentity: binding.descriptorIdentity, endpointDigest: binding.endpointDigest,
            authenticationDigest: binding.authenticationDigest, argumentsDigest: argsDigest)
        XCTAssertFalse(otherWorkspace)
    }

    func testNonRememberableToolsAreRejected() async throws {
        let grants = MacScopedToolGrants(persistence: StubScopedPersistence())
        let argsDigest = MacWorkbenchConnectorToolBinding.argumentsDigest(Data("{}".utf8))
        XCTAssertFalse(MacScopedToolGrants.canRemember(toolName: "workspace.createFile"))
        XCTAssertFalse(MacScopedToolGrants.canRemember(toolName: DelegateTool.name))
        do {
            try await grants.remember(scope: .task, workspaceID: workspaceID, conversationID: conversationID,
                                      toolName: "workspace.createFile", descriptorIdentity: "x",
                                      endpointDigest: "e", authenticationDigest: "a", argumentsDigest: argsDigest)
            XCTFail("file-write tools keep the file-grant path")
        } catch {
        }
        let rejectedList = try await grants.list()
        XCTAssertTrue(rejectedList.isEmpty)
    }

    // MARK: Session grants

    func testSessionGrantBindsWorkspaceConversationAndArguments() async throws {
        let session = MacSessionApprovalGrants()
        let argsDigest = MacWorkbenchConnectorToolBinding.argumentsDigest(Data(#"{"input":"x"}"#.utf8))
        await session.remember(workspaceID: workspaceID, conversationID: conversationID,
                               toolName: binding.toolName, descriptorIdentity: binding.descriptorIdentity,
                               endpointDigest: binding.endpointDigest,
                               authenticationDigest: binding.authenticationDigest,
                               argumentsDigest: argsDigest)
        let sessionCount = await session.all().count
        XCTAssertEqual(sessionCount, 1)

        func sessionMatches(conversation: UUID, args: String) async -> Bool {
            await session.matches(
                workspaceID: workspaceID, conversationID: conversation, toolName: binding.toolName,
                descriptorIdentity: binding.descriptorIdentity, endpointDigest: binding.endpointDigest,
                authenticationDigest: binding.authenticationDigest, argumentsDigest: args)
        }

        let exact = await sessionMatches(conversation: conversationID, args: argsDigest)
        XCTAssertTrue(exact)

        // A different task in the same session cannot use it.
        let otherTask = await sessionMatches(conversation: otherConversationID, args: argsDigest)
        XCTAssertFalse(otherTask)

        // Different arguments cannot use it.
        let otherArgs = MacWorkbenchConnectorToolBinding.argumentsDigest(Data(#"{"input":"y"}"#.utf8))
        let otherArguments = await sessionMatches(conversation: conversationID, args: otherArgs)
        XCTAssertFalse(otherArguments)

        await session.revokeAll(toolName: binding.toolName)
        let remaining = await session.all().count
        XCTAssertEqual(remaining, 0)
    }

    // MARK: Policy

    func testPolicyUpgradesOnlyAskModeHumanEscalationsWithExactBinding() async throws {
        let grants = MacScopedToolGrants(persistence: StubScopedPersistence())
        let session = MacSessionApprovalGrants()
        let action = try makeAction(toolName: binding.toolName)
        let argsDigest = MacWorkbenchConnectorToolBinding.argumentsDigest(action.toolCall.argumentsJSON)

        struct OuterWrapper: ApprovalPolicy, ApprovalReviewRouting {
            let base: any ApprovalPolicy
            var policyName: String { base.policyName }
            func requiresModelReview(_ action: ProposedAction) -> Bool {
                (base as? any ApprovalReviewRouting)?.requiresModelReview(action) ?? false
            }
            func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
                try await base.decide(action)
            }
        }

        func makePolicy(askModeOnly: Bool) -> any ApprovalPolicy {
            // Composes like the real run stack: scoped policy directly around
            // the human policy, existing wrappers outside.
            MacScopedToolGrantPolicy(
                base: HumanApprovalPolicy(), grants: grants, session: session,
                workspaceID: workspaceID, conversationID: conversationID,
                bindings: [binding.toolName: binding], askModeOnly: askModeOnly)
        }

        // No grant yet: the escalation stands (inside an outer wrapper).
        let cold = try await OuterWrapper(base: makePolicy(askModeOnly: true)).decide(action)
        guard case .escalateToHuman = cold else {
            XCTFail("without a grant the human card must stay"); return
        }

        // Persisted task grant: exact repeat auto-allows.
        try await grants.remember(scope: .task, workspaceID: workspaceID, conversationID: conversationID,
                                  toolName: binding.toolName, descriptorIdentity: binding.descriptorIdentity,
                                  endpointDigest: binding.endpointDigest,
                                  authenticationDigest: binding.authenticationDigest,
                                  argumentsDigest: argsDigest)
        let allowed = try await OuterWrapper(base: makePolicy(askModeOnly: true)).decide(action)
        XCTAssertTrue(allowed.permitsExecution)

        // Automatic mode (askModeOnly = false): ordinary policy stays
        // authoritative even with a grant on file.
        let automatic = try await OuterWrapper(base: makePolicy(askModeOnly: false)).decide(action)
        guard case .escalateToHuman = automatic else {
            XCTFail("automatic mode must not consult scoped grants"); return
        }

        // Different arguments: never granted.
        let otherAction = try makeAction(toolName: binding.toolName, arguments: #"{"input":"y"}"#)
        let different = try await OuterWrapper(base: makePolicy(askModeOnly: true)).decide(otherAction)
        guard case .escalateToHuman = different else {
            XCTFail("a different remote operation must not inherit the grant"); return
        }

        // Session grant (workspace + conversation bound) also auto-allows.
        try await grants.revokeAll(toolName: binding.toolName)
        await session.remember(workspaceID: workspaceID, conversationID: conversationID,
                               toolName: binding.toolName, descriptorIdentity: binding.descriptorIdentity,
                               endpointDigest: binding.endpointDigest,
                               authenticationDigest: binding.authenticationDigest,
                               argumentsDigest: argsDigest)
        let sessionAllowed = try await OuterWrapper(base: makePolicy(askModeOnly: true)).decide(action)
        XCTAssertTrue(sessionAllowed.permitsExecution)

        // A retired binding fails closed: the snapshot no longer offers it.
        let retired = MacScopedToolGrantPolicy(
            base: HumanApprovalPolicy(), grants: grants, session: session,
            workspaceID: workspaceID, conversationID: conversationID,
            bindings: [:], askModeOnly: true)
        let retiredDecision = try await retired.decide(action)
        guard case .escalateToHuman = retiredDecision else {
            XCTFail("retired bindings must fail closed"); return
        }

        // Host-scoped actions can never consume a local tool grant.
        let hostAction = try makeAction(toolName: binding.toolName, scope: .host(UUID()),
                                        hostAndPathScope: .host(UUID()))
        let hostDecision = try await OuterWrapper(base: makePolicy(askModeOnly: true)).decide(hostAction)
        guard case .escalateToHuman = hostDecision else {
            XCTFail("non-local actions must not consume tool grants"); return
        }
    }
}
