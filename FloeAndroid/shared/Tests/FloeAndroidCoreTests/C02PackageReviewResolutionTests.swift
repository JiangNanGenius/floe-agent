// SPDX-License-Identifier: MPL-2.0
//
// C02 Linux package-review model resolution fixtures
// (job-6cc1781f5c0b4e26). AUTHORED, NOT EXECUTED — no assertion in this
// file is a run; primary compiles and runs it with the shared Swift test
// host after integrating the patched RuntimeFacadeRunIngress.swift.
//
// Grounded in the verified A4 device defect
// (../n02-adb-upgrade-device-next/samsung105-adb01/A4_CASE_CLOSED.json):
// Samsung Full candidate02 at 3d204ca1 ran ordinary exec.shell probes fine
// under Auto-approve + a SAVED Ark approval role, then stopped the real run
// with "No software package review model is configured" when the model
// requested `apt-get update -qq && apt-get install -y -qq curl …` — because
// RunModelAssembly.approvalPolicy(for:primaryModel:) hardcoded
// packageReviewBackend:nil. These fixtures pin the repaired resolution:
//
//   * explicit saved packageReviewModelID resolves to a real
//     softwarePackage-kind reviewer (same configured provider + approved
//     credentials, no developer-subscription gate);
//   * the documented inheritance packageReview → generalAuxiliary →
//     defaultAgent (SettingsRoleModelController slot comments;
//     iOS ConversationCenter.swift:4688-4689 + :9052-9060 at git3d204ca1);
//   * explicit-but-unavailable selections (disabled model, capability
//     override removing .text, media surface, failing credentials) fail
//     CLOSED to the original human escalation text and never silently
//     inherit, substitute a provider, or mint a grant.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeSecurity
@testable import FloeAndroidCore

final class C02PackageReviewResolutionTests: XCTestCase {
    /// The real A4 proposed call (A4_ORIGINAL.jsonl sequence 37).
    private func installAction(userGoal: String = "Install curl in the task's Linux environment so I can download the requested dataset.") throws -> ProposedAction {
        try ProposedAction(
            toolCall: ToolCall(
                id: "call-c02-apt",
                toolName: "exec.shell",
                argumentsJSON: Data(#"{"command":"apt-get update -qq && apt-get install -y -qq curl 2>&1 | tail -5; command -v curl && curl --version | head -1","environmentTransaction":true,"timeout":120}"#.utf8),
                scope: .local),
            riskLabels: ["executesLocalCode", "changesSystem"],
            userGoal: userGoal,
            hostAndPathScope: .local)
    }

    private func makeAssembly(_ fixture: RunDomainFixture) -> RunModelAssembly {
        RunModelAssembly(configurationStore: fixture.modelStore,
                         credentials: RunCredentialResolver(),
                         reviewAdapterFactory: { _ in fixture.adapter })
    }

    /// A second, distinct text model the package-review slot can point at,
    /// so a resolution through the slot is observable on the wire.
    private func savePackageReviewer(_ fixture: RunDomainFixture) async throws -> ModelProfile {
        var reviewer = ModelProfile(
            providerID: fixture.providerID,
            remoteModelID: "fixture-package-reviewer",
            displayName: "Fixture Package Reviewer",
            limits: ModelLimits(contextTokens: 16_000, maxOutputTokens: 2_048),
            capabilities: [.text, .approval])
        reviewer.id = UUID()
        try await fixture.modelStore.saveModel(reviewer)
        return reviewer
    }

    private func scriptAllow(_ fixture: RunDomainFixture) {
        fixture.adapter.enqueue(
            script: .init(events: [
                .textDelta(.init(text: #"{"decision":"allow","reason":"fixture"}"#)),
                .completed(.init(stopReason: .endTurn)),
            ]),
            forRequest: fixture.adapter.requestCount)
    }

    func testExplicitSavedPackageReviewModelResolvesAndReviews() async throws {
        let fixture = try await RunDomainFixture.make()
        defer { Task { await fixture.tearDown() } }
        let reviewer = try await savePackageReviewer(fixture)
        var preferences = try await fixture.modelStore.preferences()
        preferences.packageReviewModelID = reviewer.id
        try await fixture.modelStore.savePreferences(preferences)

        let policy = await makeAssembly(fixture).approvalPolicy(
            for: TaskPolicy(conversationID: UUID(), approvalMode: "automatic"),
            primaryModel: fixture.modelProfile)
        guard let routing = policy as? any ApprovalReviewRouting else {
            return XCTFail("the automatic policy must expose review routing")
        }
        XCTAssertTrue(routing.requiresModelReview(try installAction()),
                      "a software-install request must require the model review")

        scriptAllow(fixture)
        let decision = try await policy.decide(installAction())
        guard case .allow(let scope, _) = decision else {
            return XCTFail("the configured package reviewer must be able to allow")
        }
        XCTAssertEqual(scope.toolName, "exec.shell")
        XCTAssertTrue(scope.singleUse, "the facade-issued scope stays call-bound single-use")
        // The review ran through the EXPLICIT slot model, with the saved
        // provider's approved credentials — no substitution, no default-agent
        // leak.
        let request = try XCTUnwrap(fixture.adapter.lastRequest)
        XCTAssertEqual(request.model.remoteModelID, "fixture-package-reviewer")
        XCTAssertEqual(request.provider.id, fixture.providerID)
        XCTAssertTrue(request.toolSchemas.isEmpty, "the reviewer call stays tool-free")
        XCTAssertTrue(request.messages.contains { $0.content.contains("software-package operation") },
                      "the softwarePackage review role must reach the provider")
        XCTAssertTrue(request.messages.contains { $0.content.contains("only user text grants authority") })
    }

    func testNilPackageReviewSlotFollowsGeneralAuxiliaryModel() async throws {
        let fixture = try await RunDomainFixture.make()
        defer { Task { await fixture.tearDown() } }
        let reviewer = try await savePackageReviewer(fixture)
        var preferences = try await fixture.modelStore.preferences()
        preferences.packageReviewModelID = nil
        preferences.generalAuxiliaryLLMModelID = reviewer.id
        try await fixture.modelStore.savePreferences(preferences)

        let policy = await makeAssembly(fixture).approvalPolicy(
            for: TaskPolicy(conversationID: UUID(), approvalMode: "automatic"),
            primaryModel: fixture.modelProfile)
        scriptAllow(fixture)
        let decision = try await policy.decide(installAction())
        XCTAssertTrue(decision.permitsExecution)
        XCTAssertEqual(fixture.adapter.lastRequest?.model.remoteModelID, "fixture-package-reviewer")
    }

    func testNilSlotAndNilAuxiliaryFollowDefaultAgentModel() async throws {
        let fixture = try await RunDomainFixture.make()
        defer { Task { await fixture.tearDown() } }
        // The fixture seeds defaultAgentModelID = fixture.modelID and nothing
        // else. The seeded model ships without the .approval capability bit,
        // exactly like a fresh manual entry; enable it the way the model
        // editor would, then assert the chain reaches the default agent
        // (the A4 shape: a saved usable model existed and the old nil wire
        // ignored it).
        var defaultModel = fixture.modelProfile
        defaultModel.capabilities = [.text, .tools, .vision, .approval]
        try await fixture.modelStore.saveModel(defaultModel)
        var preferences = try await fixture.modelStore.preferences()
        preferences.packageReviewModelID = nil
        preferences.generalAuxiliaryLLMModelID = nil
        try await fixture.modelStore.savePreferences(preferences)

        let policy = await makeAssembly(fixture).approvalPolicy(
            for: TaskPolicy(conversationID: UUID(), approvalMode: "automatic"),
            primaryModel: fixture.modelProfile)
        guard let routing = policy as? any ApprovalReviewRouting else {
            return XCTFail("the automatic policy must expose review routing")
        }
        XCTAssertTrue(routing.requiresModelReview(try installAction()))
        scriptAllow(fixture)
        let decision = try await policy.decide(installAction())
        XCTAssertTrue(decision.permitsExecution)
        XCTAssertEqual(fixture.adapter.lastRequest?.model.id, fixture.modelID)
    }

    func testExplicitUnavailableSelectionFailsClosedWithoutInheriting() async throws {
        let fixture = try await RunDomainFixture.make()
        defer { Task { await fixture.tearDown() } }
        var reviewer = try await savePackageReviewer(fixture)
        var preferences = try await fixture.modelStore.preferences()
        preferences.packageReviewModelID = reviewer.id
        try await fixture.modelStore.savePreferences(preferences)
        // The slot stays explicitly set while the model becomes unavailable
        // (iOS `reviewBackend(modelID:)` semantics: an explicit ID that no
        // longer validates yields nil — NO fallback to the auxiliary).
        reviewer.isEnabled = false
        try await fixture.modelStore.saveModel(reviewer)

        let policy = await makeAssembly(fixture).approvalPolicy(
            for: TaskPolicy(conversationID: UUID(), approvalMode: "automatic"),
            primaryModel: fixture.modelProfile)
        guard let routing = policy as? any ApprovalReviewRouting else {
            return XCTFail("the automatic policy must expose review routing")
        }
        XCTAssertFalse(routing.requiresModelReview(try installAction()),
                       "an unresolvable explicit slot must not claim a review route")
        let decision = try await policy.decide(installAction())
        guard case .escalateToHuman(let reason) = decision else {
            return XCTFail("the original policy must fail closed to the human card")
        }
        XCTAssertEqual(reason, "No software package review model is configured")
        XCTAssertEqual(fixture.adapter.requestCount, 0,
                       "no provider call may happen on the failed route")
    }

    func testSavedCapabilityOverrideRemovingTextFailsClosed() async throws {
        let fixture = try await RunDomainFixture.make()
        defer { Task { await fixture.tearDown() } }
        var reviewer = try await savePackageReviewer(fixture)
        var preferences = try await fixture.modelStore.preferences()
        preferences.packageReviewModelID = reviewer.id
        try await fixture.modelStore.savePreferences(preferences)
        // The user's explicit capability decision is authoritative: a
        // text-stripped override can never serve a text review.
        reviewer.explicitCapabilities = [.vision]
        try await fixture.modelStore.saveModel(reviewer)

        let policy = await makeAssembly(fixture).approvalPolicy(
            for: TaskPolicy(conversationID: UUID(), approvalMode: "automatic"),
            primaryModel: fixture.modelProfile)
        let decision = try await policy.decide(installAction())
        guard case .escalateToHuman(let reason) = decision else {
            return XCTFail("a text-stripped reviewer must fail closed")
        }
        XCTAssertEqual(reason, "No software package review model is configured")
        XCTAssertEqual(fixture.adapter.requestCount, 0)
    }

    func testMediaModelIsNotAnApprovalSurface() async throws {
        let fixture = try await RunDomainFixture.make()
        defer { Task { await fixture.tearDown() } }
        var reviewer = try await savePackageReviewer(fixture)
        var preferences = try await fixture.modelStore.preferences()
        preferences.packageReviewModelID = reviewer.id
        try await fixture.modelStore.savePreferences(preferences)
        // A model that gains a media capability loses the approval surface
        // (ModelProfile.supportsApprovalSurface), even if a stale row kept
        // the slot reference.
        reviewer.capabilities = [.text, .imageGeneration]
        try await fixture.modelStore.saveModel(reviewer)

        let policy = await makeAssembly(fixture).approvalPolicy(
            for: TaskPolicy(conversationID: UUID(), approvalMode: "automatic"),
            primaryModel: fixture.modelProfile)
        let decision = try await policy.decide(installAction())
        guard case .escalateToHuman(let reason) = decision else {
            return XCTFail("a media model must fail closed for package review")
        }
        XCTAssertEqual(reason, "No software package review model is configured")
        XCTAssertEqual(fixture.adapter.requestCount, 0)
    }

    func testCredentialFailureFailsClosedWithoutProviderSubstitution() async throws {
        let fixture = try await RunDomainFixture.make()
        defer { Task { await fixture.tearDown() } }
        let reviewer = try await savePackageReviewer(fixture)
        var preferences = try await fixture.modelStore.preferences()
        preferences.packageReviewModelID = reviewer.id
        try await fixture.modelStore.savePreferences(preferences)
        // The approved credential read fails (locked/invalidated gateway):
        // the resolver must refuse BEFORE any request — never send an
        // anonymous/empty-key call, never borrow another provider's key.
        fixture.gateway.failReads = true

        let policy = await makeAssembly(fixture).approvalPolicy(
            for: TaskPolicy(conversationID: UUID(), approvalMode: "automatic"),
            primaryModel: fixture.modelProfile)
        let decision = try await policy.decide(installAction())
        guard case .escalateToHuman(let reason) = decision else {
            return XCTFail("a credential failure must fail closed to the human card")
        }
        XCTAssertEqual(reason, "No software package review model is configured")
        XCTAssertEqual(fixture.adapter.requestCount, 0,
                       "a credential failure must never reach a provider")
    }

    func testFullAccessReceivesTheSameResolvedBackend() async throws {
        let fixture = try await RunDomainFixture.make()
        defer { Task { await fixture.tearDown() } }
        let reviewer = try await savePackageReviewer(fixture)
        var preferences = try await fixture.modelStore.preferences()
        preferences.packageReviewModelID = reviewer.id
        try await fixture.modelStore.savePreferences(preferences)

        let policy = await makeAssembly(fixture).approvalPolicy(
            for: TaskPolicy(conversationID: UUID(), approvalMode: "fullAccess"),
            primaryModel: fixture.modelProfile)
        XCTAssertEqual(policy.policyName, "full-access")
        // The Full Access install path is REVIEWED (not blanket-allowed) and
        // reaches the same configured reviewer.
        scriptAllow(fixture)
        let installDecision = try await policy.decide(installAction())
        XCTAssertTrue(installDecision.permitsExecution)
        XCTAssertEqual(fixture.adapter.lastRequest?.model.remoteModelID, "fixture-package-reviewer")
        // An ordinary non-install call under Full Access stays human-free and
        // consumes no package-review call.
        let before = fixture.adapter.requestCount
        let ordinary = try ProposedAction(
            toolCall: ToolCall(id: "call-c02-plain", toolName: "workspace.listDirectory",
                               argumentsJSON: Data("{}".utf8), scope: .local),
            riskLabels: [], userGoal: "List the workspace.",
            hostAndPathScope: .local)
        let ordinaryDecision = try await policy.decide(ordinary)
        XCTAssertTrue(ordinaryDecision.permitsExecution)
        XCTAssertEqual(fixture.adapter.requestCount, before)
    }
}
