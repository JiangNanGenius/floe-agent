// SPDX-License-Identifier: MPL-2.0
//
// Background Linux dependency preparation — trusted PRoot review route.
// AUTHORED, NOT EXECUTED — compilation and the unified test run stay with the
// primary coordinator.
//
// Verified Full12 defect (885c16cc5 / public 1.0.9): a direct exec.shell apt
// request was approved by the package reviewer, but the same dependency work
// submitted as `jobs.submit` around `exec.shell` escalated to the human card.
// Two independent gaps are pinned here:
//
//   1. isSoftwareInstallRequest only recognized a direct exec.shell/apt call;
//      the exact one-level wrapper around exec.shell reached the generic
//      action reviewer instead of the package reviewer.
//   2. trustedExecutionContext classified every Android local call as
//      `localNative` because `localLinuxGuestEnvironment` is deliberately
//      false, losing the app-resolved `localLinuxShellTarget` PRoot route
//      fact that the direct shell path already carried.
//
// The fix keeps the two facts separate: the new `.localLinuxPRoot` route
// class is ONLY a trusted review fact and is NOT a guest/VM claim, so the
// deterministic local-guest carve-outs (which require `.localLinuxVM`) stay
// exactly as narrow as before. Native, remote, unknown, malformed, unknown
// target and multilevel wrappers keep their previous policy.
//
// Argument-shape evidence: `AgentRuntime.handleStreamEvent` emits the raw
// `.toolRequest` to the sink BEFORE it canonicalizes the call for execution,
// and the durable projection stores `input` as a JSON STRING. The
// task-transcript exporter then re-parses JSON-looking strings
// (C08TaskTranscript.scrub), so an exported `arguments` object is NOT proof of
// successful runtime normalization. The runtime ingress normalizes only the
// supported nested object shape BEFORE approval so approved and dispatched
// bytes are equal; the strict tool decoder still refuses anything that
// bypasses that ingress.

import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
@testable import FloeSecurity
@testable import FloeAndroidCore
@testable import FloeAgentRuntime

final class BackgroundPackageReviewRouteTests: XCTestCase {
    private let profile = ProviderProfile(
        kind: .openAI,
        wireProtocol: .openAIChatCompletions,
        baseURL: URL(string: "https://fixtures.invalid/v1")!
    )

    private var model: ModelProfile {
        ModelProfile(
            providerID: profile.id,
            remoteModelID: "background-package-route-fixture",
            displayName: "Background Package Route Fixture",
            limits: ModelLimits(contextTokens: 16_000, maxOutputTokens: 1_024),
            capabilities: [.text, .tools]
        )
    }

    // MARK: - Fixtures

    private func innerObject() -> [String: Any] {
        [
            "command": "set -eu\napt-get update\nDEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-pil ffmpeg fonts-noto-cjk\npython3 -c \"from PIL import Image; print('Pillow OK')\"\n",
            "environmentTransaction": true,
            "maxOutputBytes": 30_000,
            "timeout": 600,
        ]
    }

    private func wrapperJSONStringShape(
        inner: [String: Any]? = nil,
        purpose: String = "安装图片与视频批处理依赖"
    ) throws -> Data {
        let innerData = try JSONSerialization.data(
            withJSONObject: inner ?? innerObject(), options: [.sortedKeys])
        let outer: [String: Any] = [
            "tool": "exec.shell",
            "arguments": String(decoding: innerData, as: UTF8.self),
            "purpose": purpose,
        ]
        return try JSONSerialization.data(withJSONObject: outer, options: [.sortedKeys])
    }

    private func wrapperJSONObjectShape() throws -> Data {
        let outer: [String: Any] = [
            "tool": "exec.shell",
            "arguments": innerObject(),
            "purpose": "安装图片与视频批处理依赖",
        ]
        return try JSONSerialization.data(withJSONObject: outer, options: [.sortedKeys])
    }

    private func action(
        tool: String,
        argumentsJSON: Data,
        goal: String = "在手机 Linux 环境批量处理图片、海报和视频，需要 Pillow、ffmpeg 和中文字体。",
        trustedContext: TrustedExecutionContext? = nil
    ) throws -> ProposedAction {
        try ProposedAction(
            toolCall: ToolCall(
                id: "call-background-package",
                toolName: tool,
                argumentsJSON: argumentsJSON,
                scope: .local),
            riskLabels: ["executesLocalCode", "changesSystem"],
            userGoal: goal,
            hostAndPathScope: .local,
            trustedContext: trustedContext)
    }

    private func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - 1. Classification

    func testDirectShellInstallerIsStillAClassifiedPackageRequest() throws {
        let install = try action(
            tool: "exec.shell",
            argumentsJSON: Data(#"{"command":"apt-get install -y curl","environmentTransaction":true}"#.utf8))
        XCTAssertTrue(install.isSoftwareInstallRequest)

        let probe = try action(
            tool: "exec.shell",
            argumentsJSON: Data(#"{"command":"command -v curl; command -v ffmpeg"}"#.utf8))
        XCTAssertFalse(probe.isSoftwareInstallRequest)
    }

    func testBackgroundStringWrapperIsClassifiedAndKeepsExactInnerBytes() throws {
        let data = try wrapperJSONStringShape()
        let wrapper = try action(tool: "jobs.submit", argumentsJSON: data)
        XCTAssertTrue(
            wrapper.isSoftwareInstallRequest,
            "the exact jobs.submit→exec.shell installer must reach the package reviewer")

        let declaration = try XCTUnwrap(
            SoftwarePackageRequest.backgroundExecShellDeclaration(argumentsJSON: data))
        XCTAssertEqual(declaration.command, innerObject()["command"] as? String)
        XCTAssertTrue(declaration.declaresSoftwareInstall)
        XCTAssertTrue(declaration.packageNames.isEmpty,
                      "the verified Full12 shape declares packages through the installer command")
        XCTAssertEqual(declaration.declaredPackageCount, 0)
        let approvedOuter = try XCTUnwrap(jsonObject(data))
        let approvedInnerString = try XCTUnwrap(approvedOuter["arguments"] as? String)
        XCTAssertEqual(
            declaration.innerArgumentsJSON, Data(approvedInnerString.utf8),
            "the declared projection is the exact approved inner string, never a re-serialization")
    }

    func testBackgroundNonInstallerIsNotAClassifiedPackageRequest() throws {
        let probe = try wrapperJSONStringShape(inner: ["command": "command -v ffmpeg; fc-list"])
        let wrapper = try action(tool: "jobs.submit", argumentsJSON: probe)
        XCTAssertFalse(wrapper.isSoftwareInstallRequest)
    }

    func testBackgroundMalformedUnknownServiceAndMultilevelWrappersFailClosed() throws {
        let malformedInner = try wrapperJSONStringShape(inner: ["command": "echo '{"])
        XCTAssertFalse(try action(tool: "jobs.submit", argumentsJSON: malformedInner).isSoftwareInstallRequest)

        let arrayArguments = try JSONSerialization.data(withJSONObject: [
            "tool": "exec.shell", "arguments": ["command": "apt-get install -y curl"],
        ])
        XCTAssertFalse(try action(tool: "jobs.submit", argumentsJSON: arrayArguments).isSoftwareInstallRequest)

        let unknownKey = try JSONSerialization.data(withJSONObject: [
            "tool": "exec.shell",
            "arguments": #"{"command":"apt-get install -y curl"}"#,
            "purpose": "deps",
            "modelConfirmed": true,
        ])
        XCTAssertFalse(try action(tool: "jobs.submit", argumentsJSON: unknownKey).isSoftwareInstallRequest)

        let serviceMode = try JSONSerialization.data(withJSONObject: [
            "tool": "exec.shell",
            "arguments": #"{"command":"apt-get install -y curl"}"#,
            "service": ["runtime": "shell", "entry": "server.sh", "port": 8080],
        ])
        XCTAssertFalse(try action(tool: "jobs.submit", argumentsJSON: serviceMode).isSoftwareInstallRequest)

        let wrongTarget = try JSONSerialization.data(withJSONObject: [
            "tool": "web.fetch",
            "arguments": #"{"command":"apt-get install -y curl"}"#,
        ])
        XCTAssertFalse(try action(tool: "jobs.submit", argumentsJSON: wrongTarget).isSoftwareInstallRequest)

        // A level-2 wrapper is an unknown inner payload; it is never
        // recursively unwrapped into a package declaration.
        let nestedInner = try JSONSerialization.data(withJSONObject: [
            "tool": "jobs.submit",
            "arguments": #"{"tool":"exec.shell","arguments":"{\"command\":\"apt-get install -y curl\"}"}"#,
        ])
        let nestedOuter = try JSONSerialization.data(withJSONObject: [
            "tool": "exec.shell", "arguments": String(decoding: nestedInner, as: UTF8.self),
        ])
        XCTAssertFalse(try action(tool: "jobs.submit", argumentsJSON: nestedOuter).isSoftwareInstallRequest)

        let emptyCommand = try wrapperJSONStringShape(inner: ["command": "   "])
        XCTAssertFalse(try action(tool: "jobs.submit", argumentsJSON: emptyCommand).isSoftwareInstallRequest)
    }

    // MARK: - 2. Argument shape (string schema vs supported object ingress)

    func testSchemaStringShapeNormalizationIsByteIdentical() throws {
        let data = try wrapperJSONStringShape()
        let call = try ToolCall(
            id: "call-string", toolName: "jobs.submit", argumentsJSON: data, scope: .local)
        let normalized = try SoftwarePackageRequest.normalizedJobSubmitCall(call)
        XCTAssertEqual(normalized.argumentsJSON, data,
                       "the published string shape must never be re-encoded by normalization")
    }

    func testObjectShapeIsOnlySupportedThroughCanonicalIngressNormalization() throws {
        let objectShape = try wrapperJSONObjectShape()
        // Raw object shape is not the schema: the policy must not call it a
        // package request before the canonical ingress can normalize it.
        XCTAssertFalse(
            try action(tool: "jobs.submit", argumentsJSON: objectShape).isSoftwareInstallRequest)
        XCTAssertNil(
            SoftwarePackageRequest.backgroundExecShellDeclaration(argumentsJSON: objectShape))

        let call = try ToolCall(
            id: "call-object", toolName: "jobs.submit", argumentsJSON: objectShape, scope: .local)
        let normalized = try SoftwarePackageRequest.normalizedJobSubmitCall(call)
        let outer = try XCTUnwrap(jsonObject(normalized.argumentsJSON))
        let normalizedInnerString = try XCTUnwrap(outer["arguments"] as? String)
        let expectedInner = try JSONSerialization.data(
            withJSONObject: innerObject(), options: [.sortedKeys])
        XCTAssertEqual(Data(normalizedInnerString.utf8), expectedInner,
                       "the inner declaration is the deterministic canonical JSON object")
        XCTAssertTrue(
            try action(tool: "jobs.submit", argumentsJSON: normalized.argumentsJSON).isSoftwareInstallRequest,
            "after canonical ingress normalization the same declared work is classified consistently")
        // Idempotent: a second normalization cannot drift the approved bytes.
        let twice = try SoftwarePackageRequest.normalizedJobSubmitCall(normalized)
        XCTAssertEqual(twice.argumentsJSON, normalized.argumentsJSON)

        // The raw tool remains strict: an object that bypasses the runtime
        // ingress is refused by the schema decoder, never silently accepted.
        struct SchemaMirror: Decodable { let arguments: String }
        XCTAssertThrowsError(try JSONDecoder().decode(SchemaMirror.self, from: objectShape))
        XCTAssertNoThrow(try JSONDecoder().decode(SchemaMirror.self, from: normalized.argumentsJSON))
    }

    func testNormalizedOuterDigestMatchesTheJobCanonicalPayloadDigest() throws {
        // The runtime mints its authority from the normalized outer call; the
        // jobs.submit consumer rebuilds the canonical payload from the
        // decoded tool arguments. For the ordinary wrapper (no service) these
        // must hash to the same bytes, so approval cannot cover a different
        // payload than the job records and executes.
        let objectShape = try wrapperJSONObjectShape()
        let call = try ToolCall(
            id: "call-digest", toolName: "jobs.submit",
            argumentsJSON: objectShape, scope: .local)
        let normalized = try SoftwarePackageRequest.normalizedJobSubmitCall(call)
        let outer = try XCTUnwrap(jsonObject(normalized.argumentsJSON))
        var canonical: [String: Any] = [
            "tool": try XCTUnwrap(outer["tool"] as? String),
            "arguments": try XCTUnwrap(outer["arguments"] as? String),
        ]
        if let purpose = outer["purpose"] as? String { canonical["purpose"] = purpose }
        if let wait = outer["wait"] as? Bool { canonical["wait"] = wait }
        let canonicalData = try JSONSerialization.data(withJSONObject: canonical)
        XCTAssertEqual(
            RuntimeAuthorityDigest.payloadDigest(normalized.argumentsJSON),
            RuntimeAuthorityDigest.payloadDigest(canonicalData),
            "the approved outer bytes and the job consumer payload must bind the same digest")
    }

    func testExportScrubExplainsTheRecordedObjectShape() throws {
        // Two independent facts: the durable projection stores `input` as a
        // String (ConversationRunService.jsonPayload(["input": input])), and
        // the runtime emits `.toolRequest` before its ingress normalization,
        // so the stored row may legitimately hold either wire shape. The
        // exporter re-parses JSON-looking strings on top of that.
        let storedInput = String(decoding: try wrapperJSONStringShape(), as: UTF8.self)
        let storedRow: [String: Any] = [
            "tool": "jobs.submit",
            "id": "call_43y53z3th9w1ocwk505ca8u2",
            "input": storedInput,
            "status": "pending",
        ]
        struct SchemaMirror: Decodable { let arguments: String }
        XCTAssertNoThrow(
            try JSONDecoder().decode(SchemaMirror.self, from: Data(storedInput.utf8)),
            "the stored runtime shape is the schema string")

        let scrubbed = try XCTUnwrap(C08TaskTranscript.scrub(storedRow) as? [String: Any])
        let scrubbedInput = try XCTUnwrap(scrubbed["input"] as? [String: Any])
        XCTAssertTrue(scrubbedInput["arguments"] is [String: Any],
                      "the exporter parses JSON-looking strings into nested objects")
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SchemaMirror.self,
                from: JSONSerialization.data(withJSONObject: scrubbedInput)),
            "the exported object shape is not a runtime-supported schema shape")
    }

    // MARK: - 3. Trusted environment route

    func testPRootRouteIsClaimedOnlyForRealTaskShellCalls() throws {
        let direct = try ToolCall(
            id: "call-direct", toolName: "exec.shell",
            argumentsJSON: Data(#"{"command":"apt-get install -y curl"}"#.utf8),
            scope: .local)
        XCTAssertEqual(
            SoftwarePackageRequest.trustedEnvironmentClass(
                for: direct, localLinuxGuestEnvironment: false,
                localLinuxShellTarget: true, environmentID: "env-task"),
            .localLinuxPRoot)

        let wrapper = try ToolCall(
            id: "call-wrapper", toolName: "jobs.submit",
            argumentsJSON: try wrapperJSONStringShape(), scope: .local)
        XCTAssertEqual(
            SoftwarePackageRequest.trustedEnvironmentClass(
                for: wrapper, localLinuxGuestEnvironment: false,
                localLinuxShellTarget: true, environmentID: "env-task"),
            .localLinuxPRoot)

        // Object shape becomes the route only after the canonical ingress.
        let objectWrapper = try ToolCall(
            id: "call-object-wrapper", toolName: "jobs.submit",
            argumentsJSON: try wrapperJSONObjectShape(), scope: .local)
        XCTAssertEqual(
            SoftwarePackageRequest.trustedEnvironmentClass(
                for: objectWrapper, localLinuxGuestEnvironment: false,
                localLinuxShellTarget: true, environmentID: "env-task"),
            .localNative)
        let normalizedObject = try SoftwarePackageRequest.normalizedJobSubmitCall(objectWrapper)
        XCTAssertEqual(
            SoftwarePackageRequest.trustedEnvironmentClass(
                for: normalizedObject, localLinuxGuestEnvironment: false,
                localLinuxShellTarget: true, environmentID: "env-task"),
            .localLinuxPRoot)

        // Separate `.linuxVM` class keeps precedence and its original meaning.
        XCTAssertEqual(
            SoftwarePackageRequest.trustedEnvironmentClass(
                for: direct, localLinuxGuestEnvironment: true,
                localLinuxShellTarget: true, environmentID: "env-task"),
            .localLinuxVM)

        // No resolved route, no environment binding, non-shell tool, empty
        // command -> native; a host/host-path scope is remote regardless.
        XCTAssertEqual(
            SoftwarePackageRequest.trustedEnvironmentClass(
                for: direct, localLinuxGuestEnvironment: false,
                localLinuxShellTarget: false, environmentID: "env-task"),
            .localNative)
        XCTAssertEqual(
            SoftwarePackageRequest.trustedEnvironmentClass(
                for: direct, localLinuxGuestEnvironment: false,
                localLinuxShellTarget: true, environmentID: nil),
            .localNative)
        let apt = try ToolCall(
            id: "call-apt", toolName: "apt",
            argumentsJSON: Data(#"{"action":"install","name":"curl"}"#.utf8),
            scope: .local)
        XCTAssertEqual(
            SoftwarePackageRequest.trustedEnvironmentClass(
                for: apt, localLinuxGuestEnvironment: false,
                localLinuxShellTarget: true, environmentID: "env-task"),
            .localNative)
        let emptyShell = try ToolCall(
            id: "call-empty", toolName: "exec.shell",
            argumentsJSON: Data("{}".utf8), scope: .local)
        XCTAssertEqual(
            SoftwarePackageRequest.trustedEnvironmentClass(
                for: emptyShell, localLinuxGuestEnvironment: false,
                localLinuxShellTarget: true, environmentID: "env-task"),
            .localNative)
        let nonShellJob = try ToolCall(
            id: "call-web-job", toolName: "jobs.submit",
            argumentsJSON: Data(#"{"tool":"web.fetch","arguments":"{\"url\":\"https://example.invalid\"}"}"#.utf8),
            scope: .local)
        XCTAssertEqual(
            SoftwarePackageRequest.trustedEnvironmentClass(
                for: nonShellJob, localLinuxGuestEnvironment: false,
                localLinuxShellTarget: true, environmentID: "env-task"),
            .localNative)
        let remote = try ToolCall(
            id: "call-remote", toolName: "exec.shell",
            argumentsJSON: Data(#"{"command":"apt-get install -y curl","hostID":"00000000-0000-0000-0000-000000000001"}"#.utf8),
            scope: .host(UUID()))
        XCTAssertEqual(
            SoftwarePackageRequest.trustedEnvironmentClass(
                for: remote, localLinuxGuestEnvironment: false,
                localLinuxShellTarget: true, environmentID: "env-task"),
            .remote)
    }

    func testPRootRouteDoesNotEnableDeterministicGuestCarveOuts() throws {
        let readOnly = try action(
            tool: "exec.shell",
            argumentsJSON: Data(#"{"command":"ls -la"}"#.utf8),
            trustedContext: TrustedExecutionContext(environmentClass: .localLinuxPRoot))
        XCTAssertFalse(
            DeterministicLocalApprovalPolicy.isExempt(readOnly),
            "PRoot is not a VM/guest class; the reduced-review guest tier stays .linuxVM-only")

        let guest = try action(
            tool: "exec.shell",
            argumentsJSON: Data(#"{"command":"ls -la"}"#.utf8),
            trustedContext: TrustedExecutionContext(environmentClass: .localLinuxVM))
        XCTAssertTrue(
            DeterministicLocalApprovalPolicy.isExempt(guest),
            "the original resolved-guest read-only carve-out is unchanged")

        // The separate optional-cleanup corrective path (one-shot113) keeps
        // working for a real PRoot shell command: PRoot is still not remote.
        let cleanup = try action(
            tool: "exec.shell",
            argumentsJSON: Data(
                #"{"command":"mkdir -p sources && rm -rf 'sources/images'"}"#.utf8),
            trustedContext: TrustedExecutionContext(environmentClass: .localLinuxPRoot))
        XCTAssertNotNil(
            LocalGuestCleanupReplan.denialReason(
                for: cleanup, localLinuxShellTarget: true),
            "the existing non-dispatched cleanup replan is unchanged")
    }

    // MARK: - 4. Reviewer prompt / evidence

    func testSoftwarePackagePromptExplainsPRootAndShowsInnerDeclaration() throws {
        let pr = try action(
            tool: "jobs.submit",
            argumentsJSON: try wrapperJSONStringShape(),
            trustedContext: TrustedExecutionContext(
                environmentClass: .localLinuxPRoot,
                workspaceRootPath: "/workspace/task"))
        let prompt = try RunApprovalModelBackend.softwarePackagePrompt(for: pr)
        XCTAssertTrue(prompt.contains("local Linux PRoot shell engine"))
        XCTAssertTrue(prompt.contains("NOT the Android host"))
        XCTAssertTrue(prompt.contains("Background job wrapper: jobs.submit -> exec.shell"))
        XCTAssertTrue(prompt.contains("apt-get install -y --no-install-recommends python3-pil"))
        XCTAssertTrue(prompt.contains("trustedContext"))
        XCTAssertFalse(prompt.contains("trustedContext is absent"))

        // Native/remote/unknown facts never receive the PRoot wording.
        for environment in [ApprovalEnvironmentClass.localNative, .remote, .unknown] {
            var nativeAction = try action(
                tool: "jobs.submit",
                argumentsJSON: try wrapperJSONStringShape())
            nativeAction.trustedContext = TrustedExecutionContext(
                environmentClass: environment)
            let nativePrompt = try RunApprovalModelBackend.softwarePackagePrompt(
                for: nativeAction)
            XCTAssertFalse(nativePrompt.contains("local Linux PRoot shell engine"))
        }
    }

    func testWrapperEvidenceProjectionIsBounded() throws {
        let longCommand = "apt-get install -y pkg && " + String(repeating: "echo filler; ", count: 2_000)
        let manyPackages = (0..<40).map { "pkg\($0)" }
        let data = try wrapperJSONStringShape(
            inner: ["command": longCommand, "packages": manyPackages])
        let evidence = RunApprovalModelBackend.declaredPackageEvidence(
            for: try action(tool: "jobs.submit", argumentsJSON: data))
        XCTAssertTrue(evidence.contains("first 400 bytes"))
        XCTAssertTrue(evidence.contains("(+16 more, truncated)"))
        XCTAssertLessThanOrEqual(evidence.utf8.count, 4_096)
    }

    // MARK: - 5. Policy routing

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

    private func makeAssembly(_ fixture: RunDomainFixture) -> RunModelAssembly {
        RunModelAssembly(configurationStore: fixture.modelStore,
                         credentials: RunCredentialResolver(),
                         reviewAdapterFactory: { _ in fixture.adapter })
    }

    func testAutomaticPolicyRoutesBackgroundWrapperToPackageReviewer() async throws {
        let fixture = try await RunDomainFixture.make()
        defer { Task { await fixture.tearDown() } }
        _ = try await savePackageReviewer(fixture)
        let policy = await makeAssembly(fixture).approvalPolicy(
            for: TaskPolicy(conversationID: UUID(), approvalMode: "automatic"),
            primaryModel: fixture.modelProfile)

        let wrapper = try action(
            tool: "jobs.submit",
            argumentsJSON: try wrapperJSONStringShape(),
            trustedContext: TrustedExecutionContext(
                environmentClass: .localLinuxPRoot,
                workspaceRootPath: "/workspace/task"))
        guard let routing = policy as? any ApprovalReviewRouting else {
            return XCTFail("automatic policy must expose review routing")
        }
        XCTAssertTrue(routing.requiresModelReview(wrapper),
                      "background dependency work must reach the package reviewer")

        fixture.adapter.enqueue(
            script: .init(events: [
                .textDelta(.init(text: #"{"decision":"allow","reason":"bounded Pillow/ffmpeg/font dependencies match the batch media goal"}"#)),
                .completed(.init(stopReason: .endTurn)),
            ]),
            forRequest: fixture.adapter.requestCount)
        let decision = try await policy.decide(wrapper)
        guard case .allow(let scope, let expiresAt) = decision else {
            return XCTFail("the package reviewer allow must propagate")
        }
        XCTAssertEqual(scope.toolName, "jobs.submit",
                       "the grant stays bound to the EXACT outer jobs.submit call")
        XCTAssertTrue(scope.singleUse)
        XCTAssertTrue(scope.paths.isEmpty)
        XCTAssertNil(expiresAt)

        let prompt = try XCTUnwrap(fixture.adapter.lastRequest?.messages.first?.content)
        XCTAssertTrue(prompt.contains("software-package operation"))
        XCTAssertTrue(prompt.contains("jobs.submit -> exec.shell"))
        XCTAssertTrue(prompt.contains("local Linux PRoot shell engine"))
    }

    func testTrustedAutomaticGrantCannotBypassThePackageReviewer() async throws {
        // Structural "no grant bypass": even a permissive trusted grant must
        // not run before the dedicated package review for declared installs.
        let wrapper = try action(
            tool: "jobs.submit",
            argumentsJSON: try wrapperJSONStringShape())
        let policy = AutomaticApprovalPolicy(
            backend: nil,
            packageReviewBackend: DenyingPackageReviewBackend(),
            trustedAutomaticGrant: { _ in true })
        XCTAssertTrue(policy.requiresModelReview(wrapper))
        guard case .deny(let reason) = try await policy.decide(wrapper) else {
            return XCTFail("the package reviewer, not the trusted grant, must decide")
        }
        XCTAssertEqual(reason, "package-reviewer-decided")
    }

    func testFullAccessDoesNotSilentlyAutoAllowBackgroundInstalls() async throws {
        let wrapper = try action(
            tool: "jobs.submit",
            argumentsJSON: try wrapperJSONStringShape())
        let policy = TaskFullAccessPolicy(packageReviewBackend: nil)
        let decision = try await policy.decide(wrapper)
        guard case .escalateToHuman(let reason) = decision else {
            return XCTFail("Full Access without a package reviewer must fail closed")
        }
        XCTAssertEqual(reason, "No software package review model is configured")
    }

    func testNonInstallerBackgroundWrapperDoesNotConsumeThePackageReviewer() async throws {
        let fixture = try await RunDomainFixture.make()
        defer { Task { await fixture.tearDown() } }
        _ = try await savePackageReviewer(fixture)
        let policy = await makeAssembly(fixture).approvalPolicy(
            for: TaskPolicy(conversationID: UUID(), approvalMode: "automatic"),
            primaryModel: fixture.modelProfile)
        let probe = try action(
            tool: "jobs.submit",
            argumentsJSON: try wrapperJSONStringShape(
                inner: ["command": "command -v ffmpeg; fc-list | head"]))
        _ = try await policy.decide(probe)
        XCTAssertEqual(fixture.adapter.requestCount, 0,
                       "the package reviewer only serves declared installer work")
    }

    // MARK: - 6. Runtime wiring (canonical ingress + trusted facts)

    func testRuntimeNormalizesObjectWrapperBeforeApprovalAndPassesPRootRoute() async throws {
        let objectShape = try wrapperJSONObjectShape()
        let call = try ToolCall(
            id: "call-runtime-wrapper", toolName: "jobs.submit",
            argumentsJSON: objectShape, scope: .local)
        let provider = ScriptedWrapperProvider([
            [.toolRequest(call), .completed(.init(stopReason: .endTurn))],
            [.textDelta(.init(text: "依赖安装已提交。")), .completed(.init(stopReason: .endTurn))],
        ])
        let executor = WrapperIngressExecutor()
        let policy = CapturingAllowPolicy()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                conversationID: UUID(),
                provider: profile,
                model: model,
                maxProviderRetries: 0,
                environmentID: "env-task",
                localLinuxShellTarget: true),
            adapter: provider,
            policy: policy,
            executor: executor,
            runID: UUID())

        try await runtime.start(goal: "在手机 Linux 环境准备 Pillow、ffmpeg 和字体依赖。")

        let action = try XCTUnwrap(policy.actions.first)
        XCTAssertEqual(action.toolCall.toolName, "jobs.submit")
        XCTAssertEqual(action.trustedContext?.environmentClass, .localLinuxPRoot,
                       "the background shell must carry the actual task PRoot route")
        let approvedOuter = try XCTUnwrap(jsonObject(action.toolCall.argumentsJSON))
        XCTAssertTrue(approvedOuter["arguments"] is String,
                      "approval must see the canonical schema string, not the raw object")
        let executed = try XCTUnwrap(executor.executed.first)
        XCTAssertEqual(executed.argumentsJSON, action.toolCall.argumentsJSON,
                       "the dispatched bytes are exactly the approved bytes")
    }

    func testRuntimeKeepsNativeClassWhenNoPRootRouteWasResolved() async throws {
        let call = try ToolCall(
            id: "call-runtime-direct", toolName: "exec.shell",
            argumentsJSON: Data(#"{"command":"apt-get install -y curl"}"#.utf8),
            scope: .local)
        let provider = ScriptedWrapperProvider([
            [.toolRequest(call), .completed(.init(stopReason: .endTurn))],
            [.textDelta(.init(text: "需要先解析 Linux 执行目标。")), .completed(.init(stopReason: .endTurn))],
        ])
        let executor = WrapperIngressExecutor(toolName: "exec.shell")
        let policy = CapturingAllowPolicy()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                conversationID: UUID(),
                provider: profile,
                model: model,
                maxProviderRetries: 0,
                environmentID: "env-task",
                localLinuxShellTarget: false),
            adapter: provider,
            policy: policy,
            executor: executor,
            runID: UUID())

        try await runtime.start(goal: "安装 curl。")
        XCTAssertEqual(policy.actions.first?.trustedContext?.environmentClass, .localNative,
                       "without the app-resolved PRoot route the native class is unchanged")
    }
}

// MARK: - Runtime fixtures (test-only)

private final class ScriptedWrapperProvider: ProviderAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[AgentEvent]]

    init(_ scripts: [[AgentEvent]]) { self.scripts = scripts }

    var protocolKind: ModelProtocol { .openAIChatCompletions }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let events = lock.withLock { () -> [AgentEvent] in
            guard !scripts.isEmpty else {
                return [.completed(.init(stopReason: .endTurn))]
            }
            return scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] { [] }
}

private final class WrapperIngressExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [ToolCall] = []
    private let descriptor: ToolCatalog.Descriptor

    init(toolName: String = "jobs.submit") {
        descriptor = ToolCatalog.Descriptor(
            name: toolName,
            toolDescription: "Synthetic background wrapper fixture",
            riskLabels: [.executesLocalCode],
            isSideEffecting: true)
    }

    var executed: [ToolCall] { lock.withLock { calls } }
    var allDescriptors: [ToolCatalog.Descriptor] { [descriptor] }

    func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        name == descriptor.name ? descriptor : nil
    }

    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        lock.withLock { calls.append(call) }
        return ToolResult(
            callID: call.id,
            status: .ok,
            outputSummary: "synthetic background submit accepted",
            outputDigest: "")
    }
}

private struct DenyingPackageReviewBackend: ModelApprovalPolicy.DecisionBackend {
    func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        .deny(reason: "package-reviewer-decided")
    }
}

private final class CapturingAllowPolicy: ApprovalPolicy, ApprovalReviewRouting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ProposedAction] = []

    var policyName: String { "approval-model" }
    var actions: [ProposedAction] { lock.withLock { stored } }

    func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        lock.withLock { stored.append(action) }
        return .allow(
            scope: ApprovalScope(toolName: action.toolCall.toolName, singleUse: true),
            expiresAt: nil)
    }

    func requiresModelReview(_ action: ProposedAction) -> Bool { true }
}
