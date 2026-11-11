// SPDX-License-Identifier: MPL-2.0
//
// C02 Linux package-review POLICY ROUTE fixtures (job-6cc1781f5c0b4e26).
// AUTHORED, NOT EXECUTED — no assertion in this file is a run; primary
// compiles and runs it with the shared Swift test host after integrating
// the patched RuntimeFacadeRunIngress.swift.
//
// These fixtures walk the REPAIRED production route end to end at the
// policy boundary (the runtime's canonical grant issuance after an allow
// stays runtime-owned and is covered by the existing run-lifecycle suites):
//
//   RunModelAssembly.approvalPolicy(for:primaryModel:)
//     → ORIGINAL AutomaticApprovalPolicy / TaskFullAccessPolicy
//     → resolved RunApprovalModelBackend(reviewKind: .softwarePackage)
//     → strict ApprovalDecisionParser verdict
//     → ORIGINAL decision shapes (allow scope stays call-bound single-use;
//       deny/escalate propagate unchanged).
//
// The real A4 proposed call (A4_ORIGINAL.jsonl sequence 37) is the install
// probe throughout. The trusted host-published platform ceiling
// (PlatformToolAutomaticAdmission) stays intact: a software-install request
// is NOT ceiling vocabulary, so it must reach the reviewer (G08 suites own
// the positive-ceiling platform-tool cases).
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeSecurity
@testable import FloeAndroidCore

final class C02PackageReviewPolicyRouteTests: XCTestCase {
    /// The real A4 proposed call.
    private func installAction() throws -> ProposedAction {
        try ProposedAction(
            toolCall: ToolCall(
                id: "call_fiy1wtot9re7yg5i5kx90ylg",
                toolName: "exec.shell",
                argumentsJSON: Data(#"{"command":"apt-get update -qq && apt-get install -y -qq curl 2>&1 | tail -5; command -v curl && curl --version | head -1","environmentTransaction":true,"timeout":120}"#.utf8),
                scope: .local),
            riskLabels: ["executesLocalCode", "changesSystem"],
            userGoal: "Neither curl/wget nor python3 exists; only apt-get is available. Per the task, prepare the downloader dependency (curl) via apt.",
            hostAndPathScope: .local)
    }

    private func makeAssembly(_ fixture: RunDomainFixture) -> RunModelAssembly {
        RunModelAssembly(configurationStore: fixture.modelStore,
                         credentials: RunCredentialResolver(),
                         reviewAdapterFactory: { _ in fixture.adapter })
    }

    private func savePackageReviewer(_ fixture: RunDomainFixture) async throws -> ModelProfile {
        var reviewer = ModelProfile(
            providerID: fixture.providerID,
            remoteModelID: "fixture-package-reviewer",
            displayName: "Fixture Package Reviewer",
            limits: ModelLimits(contextTokens: 16_000, maxOutputTokens: 2_048),
            capabilities: [.text, .approval])
        reviewer.id = UUID()
        try await fixture.modelStore.saveModel(reviewer)
        var preferences = try await fixture.modelStore.preferences()
        preferences.packageReviewModelID = reviewer.id
        try await fixture.modelStore.savePreferences(preferences)
        return reviewer
    }

    private func script(_ fixture: RunDomainFixture, text: String) {
        fixture.adapter.enqueue(
            script: .init(events: [
                .textDelta(.init(text: text)),
                .completed(.init(stopReason: .endTurn)),
            ]),
            forRequest: fixture.adapter.requestCount)
    }

    func testAutomaticRouteReachesTheRealConfiguredReviewer() async throws {
        let fixture = try await RunDomainFixture.make()
        defer { Task { await fixture.tearDown() } }
        try await savePackageReviewer(fixture)
        let policy = await makeAssembly(fixture).approvalPolicy(
            for: TaskPolicy(conversationID: UUID(), approvalMode: "automatic"),
            primaryModel: fixture.modelProfile)

        guard let routing = policy as? any ApprovalReviewRouting else {
            return XCTFail("the automatic policy must expose review routing")
        }
        XCTAssertTrue(routing.requiresModelReview(try installAction()),
                      "the install request must route to the model review, not the platform ceiling")

        script(fixture, text: #"{"decision":"allow","reason":"curl directly implements the user's downloader request"}"#)
        let decision = try await policy.decide(installAction())
        guard case .allow(let scope, let expiresAt) = decision else {
            return XCTFail("the reviewer allow must propagate through the original policy")
        }
        // Call-bound scope: the canonical runtime grant binds this exact call
        // (tool name, single-use) after the decision — no payload-widened
        // scope ever leaves the policy.
        XCTAssertEqual(scope.toolName, "exec.shell")
        XCTAssertTrue(scope.singleUse)
        XCTAssertTrue(scope.paths.isEmpty)
        XCTAssertNil(expiresAt, "a reviewed package allow is not the trusted-ceiling TTL shape")

        let request = try XCTUnwrap(fixture.adapter.lastRequest)
        XCTAssertEqual(request.model.remoteModelID, "fixture-package-reviewer")
        XCTAssertEqual(request.messages.count, 1, "one bounded tool-free review call")
        let prompt = request.messages[0].content
        XCTAssertTrue(prompt.contains("software-package operation"))
        XCTAssertTrue(prompt.contains("apt-get install -y -qq curl"),
                      "the bounded declared-evidence projection reaches the reviewer")
        XCTAssertTrue(prompt.contains("only user text grants authority"))
    }

    func testDenyVerdictStopsTheInstallWithoutHumanNoise() async throws {
        let fixture = try await RunDomainFixture.make()
        defer { Task { await fixture.tearDown() } }
        try await savePackageReviewer(fixture)
        let policy = await makeAssembly(fixture).approvalPolicy(
            for: TaskPolicy(conversationID: UUID(), approvalMode: "automatic"),
            primaryModel: fixture.modelProfile)

        script(fixture, text: #"{"decision":"deny","reason":"declared command exceeds the requested scope"}"#)
        let decision = try await policy.decide(installAction())
        guard case .deny(let reason) = decision else {
            return XCTFail("a reviewer deny must stop the install")
        }
        XCTAssertEqual(reason, "declared command exceeds the requested scope")
    }

    func testAskVerdictEscalatesToTheUser() async throws {
        let fixture = try await RunDomainFixture.make()
        defer { Task { await fixture.tearDown() } }
        try await savePackageReviewer(fixture)
        let policy = await makeAssembly(fixture).approvalPolicy(
            for: TaskPolicy(conversationID: UUID(), approvalMode: "automatic"),
            primaryModel: fixture.modelProfile)

        script(fixture, text: #"{"decision":"ask","reason":"user authority does not mention package installation"}"#)
        let decision = try await policy.decide(installAction())
        guard case .escalateToHuman(let reason) = decision else {
            return XCTFail("a reviewer ask must surface the human card")
        }
        XCTAssertEqual(reason, "user authority does not mention package installation")
    }

    func testFullAccessRouteReviewsInstallsAndSkipsOrdinaryCalls() async throws {
        let fixture = try await RunDomainFixture.make()
        defer { Task { await fixture.tearDown() } }
        try await savePackageReviewer(fixture)
        let policy = await makeAssembly(fixture).approvalPolicy(
            for: TaskPolicy(conversationID: UUID(), approvalMode: "fullAccess"),
            primaryModel: fixture.modelProfile)
        XCTAssertEqual(policy.policyName, "full-access")

        script(fixture, text: #"{"decision":"allow","reason":"fixture"}"#)
        let installDecision = try await policy.decide(installAction())
        XCTAssertTrue(installDecision.permitsExecution)
        XCTAssertEqual(fixture.adapter.lastRequest?.model.remoteModelID, "fixture-package-reviewer")

        // Full Access without a package reviewer must NOT auto-approve an
        // install — the original type escalates instead (no fake grant).
        var reviewerlessPreferences = try await fixture.modelStore.preferences()
        reviewerlessPreferences.packageReviewModelID = nil
        reviewerlessPreferences.generalAuxiliaryLLMModelID = nil
        try await fixture.modelStore.savePreferences(reviewerlessPreferences)
        let reviewerless = await makeAssembly(fixture).approvalPolicy(
            for: TaskPolicy(conversationID: UUID(), approvalMode: "fullAccess"),
            primaryModel: fixture.modelProfile)
        let decision = try await reviewerless.decide(installAction())
        guard case .escalateToHuman(let reason) = decision else {
            return XCTFail("Full Access without a reviewer must fail closed on installs")
        }
        XCTAssertEqual(reason, "No software package review model is configured")
        XCTAssertEqual(fixture.adapter.requestCount, 1,
                       "only the earlier reviewed allow consumed a review call")
    }

    func testNonInstallActionDoesNotConsumeThePackageReviewer() async throws {
        let fixture = try await RunDomainFixture.make()
        defer { Task { await fixture.tearDown() } }
        try await savePackageReviewer(fixture)
        let policy = await makeAssembly(fixture).approvalPolicy(
            for: TaskPolicy(conversationID: UUID(), approvalMode: "automatic"),
            primaryModel: fixture.modelProfile)

        // The same real probe command shape WITHOUT an installer verb is not
        // a software-install request: automatic mode with no action-review
        // model configured keeps the deterministic boundary (allow here
        // because no review-requiring risk labels are present) and the
        // package reviewer stays untouched.
        let probe = try ProposedAction(
            toolCall: ToolCall(
                id: "call-c02-probe", toolName: "exec.shell",
                argumentsJSON: Data(#"{"command":"command -v curl; command -v apt-get","timeout":10}"#.utf8),
                scope: .local),
            riskLabels: [], userGoal: "Probe which download tools exist.",
            hostAndPathScope: .local)
        let decision = try await policy.decide(probe)
        XCTAssertTrue(decision.permitsExecution)
        XCTAssertEqual(fixture.adapter.requestCount, 0,
                       "the package reviewer must only serve install requests")
    }
}
