// SPDX-License-Identifier: MPL-2.0
//
// Authored-only regressions for the trusted ordinary-automatic admission
// snapshot (N02 canonical automatic permission issuance). NOT executed by
// this lane (Main runs the combined batch). Every fixture is synthetic:
// no device, ADB, root, real package, user file, credential or network
// target is touched.
//
// What these tests prove:
//   * the closed admission parser accepts only the settled ABI shape and
//     refuses malformed/oversized publications atomically;
//   * the mailbox publishes the snapshot only for the live bound epoch and
//     clears it on rebind/close (revocation stays host-driven);
//   * the C export is fail-closed without a live native generation;
//   * the pure eligibility rule admits exactly: the four ordinary package
//     tools under the package ceiling, the three file mutations under the
//     write ceiling + exact selected root, and individually opted-in
//     advanced tools that are also bound+available;
//   * the ordinary automatic policy turns an admitted call into a REAL
//     bounded allow (single-use scope, ~20 min TTL, no model review, no
//     backend call) while non-admitted calls keep every original gate;
//   * only the nine settled package batch names get the 18 min mailbox
//     ticket budget and the grant TTL covers it;
//   * the mailbox's global nonnil approvalGrantID guard is unchanged:
//     admission alone authorizes nothing at the dispatch boundary.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeSecurity
import FloeTools
@testable import FloeAndroidCore

final class G08PlatformToolAutoAdmissionTests: XCTestCase {

    private let taskID = UUID(uuidString: "30000000-0000-4000-8000-000000000013")!
    private let runID = UUID(uuidString: "40000000-0000-4000-8000-000000000014")!
    private let grantID = UUID(uuidString: "50000000-0000-4000-8000-000000000015")!

    // MARK: - Fixtures

    private final class EpochBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64?
        init(_ value: UInt64?) { self.value = value }
        var current: UInt64? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func set(_ newValue: UInt64?) {
            lock.lock(); value = newValue; lock.unlock()
        }
    }

    private final class RecordingBackend: ModelApprovalPolicy.DecisionBackend,
                                          @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
        func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
            lock.withLock { count += 1 }
            return .allow(
                scope: ApprovalScope(toolName: action.toolCall.toolName,
                                     singleUse: true),
                expiresAt: nil)
        }
    }

    private var emptySchema: [String: Any] {
        ["type": "object", "properties": [String: Any](), "additionalProperties": false]
    }

    private func makeEntry(name: String, sideEffecting: Bool = true) -> [String: Any] {
        [
            "name": name,
            "description": "Synthetic public platform tool.",
            "schema": emptySchema,
            "riskLabels": sideEffecting ? ["modifiesRemoteSystem"] : [],
            "effect": sideEffecting ? "mutating" : "readOnly",
            "isSideEffecting": sideEffecting,
            "hostScope": false,
            "executionBoundary": "mainRunOnly",
            "supportsConcurrentBatchDispatch": false,
        ]
    }

    private func catalogData(_ tools: [[String: Any]]) -> Data {
        try! JSONSerialization.data(
            withJSONObject: ["version": 1, "tools": tools],
            options: [.sortedKeys])
    }

    private func availabilityData(_ names: [String]) -> Data {
        try! JSONSerialization.data(withJSONObject: names, options: [.sortedKeys])
    }

    private func mailbox(_ box: EpochBox,
                         registry: ToolRunnerRegistry = ToolRunnerRegistry())
        -> PlatformToolHostMailbox {
        PlatformToolHostMailbox(registry: registry, currentEpoch: { box.current })
    }

    @discardableResult
    private func bindAndExpose(_ mailbox: PlatformToolHostMailbox,
                               epoch: UInt64,
                               tools: [[String: Any]]) -> Int32 {
        let result = mailbox.bind(epoch: epoch, catalogJSON: catalogData(tools))
        guard result == 0 else { return result }
        let names = tools.compactMap { $0["name"] as? String }
        return mailbox.setAvailability(epoch: epoch,
                                       namesJSON: availabilityData(names))
    }

    private func call(_ tool: String, arguments: [String: Any] = [:]) throws -> ToolCall {
        try ToolCall(id: "call-fixture", toolName: tool,
                     argumentsJSON: JSONSerialization.data(withJSONObject: arguments),
                     scope: .local)
    }

    private func action(_ tool: String, arguments: [String: Any] = [:],
                        risks: Set<String> = ["modifiesRemoteSystem"]) throws -> ProposedAction {
        try ProposedAction(toolCall: call(tool, arguments: arguments),
                           riskLabels: risks,
                           userGoal: "Fixture ordinary automatic platform request.",
                           hostAndPathScope: .local)
    }

    private func admissionJSON(packageManagement: Bool = false,
                               fileWrites: Bool = false,
                               fileRootIds: [String] = [],
                               advancedTools: [String]? = nil) -> Data {
        var object: [String: Any] = [
            "version": 1,
            "packageManagement": packageManagement,
            "fileWrites": fileWrites,
            "fileRootIds": fileRootIds,
        ]
        if let advancedTools { object["advancedTools"] = advancedTools }
        return try! JSONSerialization.data(withJSONObject: object,
                                           options: [.sortedKeys])
    }

    private func publishedAdmission(packageManagement: Bool = true,
                                    fileWrites: Bool = true,
                                    fileRootIds: Set<String> = ["downloads"],
                                    advancedTools: Set<String> = []) -> PlatformToolAutoAdmission {
        PlatformToolAutoAdmission(
            packageManagement: packageManagement,
            fileWrites: fileWrites,
            fileRootIds: fileRootIds,
            advancedTools: advancedTools)
    }

    // MARK: - Closed parser

    func testParserAcceptsMinimalAndFullSnapshots() throws {
        let minimal = try PlatformToolAutoAdmissionParser.parse(
            admissionJSON(packageManagement: false, fileWrites: false))
        XCTAssertEqual(minimal, PlatformToolAutoAdmission(
            packageManagement: false, fileWrites: false, fileRootIds: []))

        let full = try PlatformToolAutoAdmissionParser.parse(
            admissionJSON(packageManagement: true, fileWrites: true,
                          fileRootIds: ["downloads", "docs_1", "appdata:0123456789abcdef"],
                          advancedTools: ["system.settings.write",
                                          "system.appOps.manage"]))
        XCTAssertEqual(full, PlatformToolAutoAdmission(
            packageManagement: true, fileWrites: true,
            fileRootIds: ["downloads", "docs_1", "appdata:0123456789abcdef"],
            advancedTools: ["system.settings.write", "system.appOps.manage"]))
    }

    func testParserRejectsMalformedSnapshotsAtomically() {
        let closedAdvanced = PlatformToolAutoAdmissionParser.advancedToolNames
            .sorted().map { "\"\($0)\"" }.joined(separator: ",")
        var cases: [String: Data] = [
            "version2": Data(
                #"{"version":2,"packageManagement":false,"fileWrites":false,"fileRootIds":[]}"#.utf8),
            "versionString": Data(
                #"{"version":"1","packageManagement":false,"fileWrites":false,"fileRootIds":[]}"#.utf8),
            "missingFileWrites": Data(
                #"{"version":1,"packageManagement":false,"fileRootIds":[]}"#.utf8),
            "unknownKey": Data(
                #"{"version":1,"packageManagement":false,"fileWrites":false,"fileRootIds":[],"extra":true}"#.utf8),
            "rootsNotArray": Data(
                #"{"version":1,"packageManagement":false,"fileWrites":false,"fileRootIds":"downloads"}"#.utf8),
            "rootNotString": Data(
                #"{"version":1,"packageManagement":false,"fileWrites":false,"fileRootIds":[7]}"#.utf8),
            "rootBadCharacters": Data(
                #"{"version":1,"packageManagement":false,"fileWrites":false,"fileRootIds":["../etc"]}"#.utf8),
            "appDataBadDigest": Data(
                #"{"version":1,"packageManagement":false,"fileWrites":true,"fileRootIds":["appdata:0123456789abcdeg"]}"#.utf8),
            "appDataPath": Data(
                #"{"version":1,"packageManagement":false,"fileWrites":true,"fileRootIds":["appdata:/data/user/0/example"]}"#.utf8),
            "duplicateRoots": Data(
                #"{"version":1,"packageManagement":false,"fileWrites":false,"fileRootIds":["downloads","downloads"]}"#.utf8),
            "advancedUnknownName": Data(
                #"{"version":1,"packageManagement":false,"fileWrites":false,"fileRootIds":[],"advancedTools":["phone.observe"]}"#.utf8),
            "advancedNotString": Data(
                #"{"version":1,"packageManagement":false,"fileWrites":false,"fileRootIds":[],"advancedTools":[true]}"#.utf8),
            "advancedDuplicate": Data(
                #"{"version":1,"packageManagement":false,"fileWrites":false,"fileRootIds":[],"advancedTools":["system.settings.write","system.settings.write"]}"#.utf8),
            "fileWritesNumber": Data(
                #"{"version":1,"packageManagement":false,"fileWrites":1,"fileRootIds":[]}"#.utf8),
            "nonObject": Data(#"["version"]"#.utf8),
            "emptyObject": Data(#"{}"#.utf8),
            "garbage": Data(#"not json"#.utf8),
        ]
        cases["rootTooLong"] = Data((
            #"{"version":1,"packageManagement":false,"fileWrites":false,"fileRootIds":[""#
                + String(repeating: "a", count: 65) + "\"]}").utf8)
        cases["tooManyRoots"] = Data((
            #"{"version":1,"packageManagement":false,"fileWrites":false,"fileRootIds":[""#
                + (0..<33).map { "\"r\($0)\"" }.joined(separator: ",") + "]}").utf8)
        cases["advancedTooMany"] = Data((
            #"{"version":1,"packageManagement":false,"fileWrites":false,"fileRootIds":[],"advancedTools":[""#
                + closedAdvanced + #",""system.settings.write"]}"#).utf8)
        for (name, data) in cases {
            XCTAssertThrowsError(
                try PlatformToolAutoAdmissionParser.parse(data),
                "fixture '\(name)' must refuse") { error in
                guard case PlatformToolAutoAdmissionError.malformed = error else {
                    XCTFail("fixture '\(name)' must refuse as malformed, got \(error)")
                    return
                }
            }
        }
    }

    func testParserRejectsOversizedBodyBeforeDecoding() {
        let oversized = Data(
            repeating: 0x20,
            count: PlatformToolHostLimits.maximumAutoAdmissionBytes + 1)
        XCTAssertThrowsError(
            try PlatformToolAutoAdmissionParser.parse(oversized)) { error in
            XCTAssertEqual(error as? PlatformToolAutoAdmissionError, .oversized)
        }
    }

    // MARK: - Mailbox publication lifecycle

    func testMailboxPublishesAdmissionOnlyForLiveBoundEpoch() {
        let box = EpochBox(5)
        let mailbox = mailbox(box)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5, tools: [
            makeEntry(name: "system.packages.install"),
        ]), 0)

        // Unpublished: fail closed.
        XCTAssertNil(mailbox.autoAdmissionForCurrentEpoch())

        XCTAssertEqual(mailbox.setAutoAdmission(
            epoch: 5, admissionJSON: admissionJSON(packageManagement: true)), 0)
        XCTAssertEqual(mailbox.autoAdmissionForCurrentEpoch(),
                       PlatformToolAutoAdmission(
                           packageManagement: true, fileWrites: false,
                           fileRootIds: []))

        // Stale/future epochs are fenced, never retargeted.
        XCTAssertEqual(mailbox.setAutoAdmission(
            epoch: 4, admissionJSON: admissionJSON()), -102)
        XCTAssertEqual(mailbox.setAutoAdmission(
            epoch: 6, admissionJSON: admissionJSON()), -102)
        // A fenced publish must not disturb the live snapshot.
        XCTAssertEqual(mailbox.autoAdmissionForCurrentEpoch(),
                       PlatformToolAutoAdmission(
                           packageManagement: true, fileWrites: false,
                           fileRootIds: []))

        // Malformed/oversized/empty publications are refused atomically and
        // leave the previous snapshot intact.
        XCTAssertEqual(mailbox.setAutoAdmission(
            epoch: 5, admissionJSON: Data(#"{"version":1}"#.utf8)), -108)
        XCTAssertEqual(mailbox.setAutoAdmission(
            epoch: 5,
            admissionJSON: Data(repeating: 0x20,
                                count: PlatformToolHostLimits.maximumAutoAdmissionBytes + 1)),
            -107)
        XCTAssertEqual(mailbox.setAutoAdmission(
            epoch: 5, admissionJSON: Data()), -105)
        XCTAssertEqual(mailbox.setAutoAdmission(
            epoch: 0, admissionJSON: admissionJSON()), -105)
        XCTAssertEqual(mailbox.autoAdmissionForCurrentEpoch(),
                       PlatformToolAutoAdmission(
                           packageManagement: true, fileWrites: false,
                           fileRootIds: []))

        // Live-epoch observation surfaces the publication.
        let readiness = try! JSONSerialization.jsonObject(
            with: Data(mailbox.readinessJSON().utf8)) as! [String: Any]
        XCTAssertEqual(readiness["autoAdmissionPublished"] as? Bool, true)
    }

    func testAdmissionIsClearedOnCloseAndRebind() {
        let box = EpochBox(5)
        let mailbox = mailbox(box)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5, tools: [
            makeEntry(name: "system.packages.install"),
        ]), 0)
        XCTAssertEqual(mailbox.setAutoAdmission(
            epoch: 5, admissionJSON: admissionJSON(packageManagement: true)), 0)
        XCTAssertNotNil(mailbox.autoAdmissionForCurrentEpoch())

        mailbox.close(epoch: 5)
        XCTAssertNil(mailbox.autoAdmissionForCurrentEpoch(),
                     "close must revoke the ceiling snapshot with the generation")

        XCTAssertEqual(bindAndExpose(mailbox, epoch: 6, tools: [
            makeEntry(name: "system.packages.install"),
        ]), -102, "the native generation must advance before rebinding")
        box.set(6)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 6, tools: [
            makeEntry(name: "system.packages.install"),
        ]), 0)
        XCTAssertNil(mailbox.autoAdmissionForCurrentEpoch(),
                     "a rebind must never inherit the old generation's ceiling")
    }

    func testEligibilitySnapshotRequiresTheSameAvailableGeneration() {
        let box = EpochBox(5)
        let mailbox = mailbox(box)
        let name = "system.packages.install"
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5,
                                     tools: [makeEntry(name: name)]), 0)
        XCTAssertEqual(mailbox.setAutoAdmission(
            epoch: 5, admissionJSON: admissionJSON(packageManagement: true)), 0)
        XCTAssertNotNil(mailbox.autoAdmissionEligibilitySnapshot(named: name))
        XCTAssertNil(mailbox.autoAdmissionEligibilitySnapshot(named: "system.packages.restore"))

        XCTAssertEqual(mailbox.setAvailability(epoch: 5, namesJSON: availabilityData([])), 0)
        XCTAssertNotNil(mailbox.autoAdmissionForCurrentEpoch())
        XCTAssertNil(mailbox.autoAdmissionEligibilitySnapshot(named: name))
        XCTAssertEqual(mailbox.setAvailability(epoch: 5, namesJSON: availabilityData([name])), 0)
        box.set(6)
        XCTAssertNil(mailbox.autoAdmissionEligibilitySnapshot(named: name))

        XCTAssertEqual(bindAndExpose(mailbox, epoch: 6,
                                     tools: [makeEntry(name: name)]), 0)
        XCTAssertNil(mailbox.autoAdmissionEligibilitySnapshot(named: name))
        XCTAssertEqual(mailbox.setAutoAdmission(
            epoch: 6, admissionJSON: admissionJSON(packageManagement: true)), 0)
        XCTAssertNotNil(mailbox.autoAdmissionEligibilitySnapshot(named: name))
        mailbox.close(epoch: 6)
        XCTAssertNil(mailbox.autoAdmissionEligibilitySnapshot(named: name))
    }

    func testCExportFailsClosedWithoutLiveNativeGeneration() {
        let bytes = Array(admissionJSON().prefix(64))
        bytes.withUnsafeBufferPointer { raw in
            // No bootstrap pumps in unit tests: readback() is nil, so every
            // non-zero epoch is generation-fenced and epoch 0 is a shape
            // refusal. Never 0-as-epoch, never a fabricated acceptance.
            XCTAssertEqual(floePlatformToolSetAutoAdmission(9, raw.baseAddress, 64), -102)
            XCTAssertEqual(floePlatformToolSetAutoAdmission(0, raw.baseAddress, 64), -105)
            XCTAssertEqual(floePlatformToolSetAutoAdmission(9, nil, 64), -105)
        }
    }

    // MARK: - Eligibility (pure rule over injected trusted sources)

    func testEligibilityAdmitsOnlyPublishedCeilingCalls() throws {
        let admission = publishedAdmission(
            packageManagement: true, fileWrites: true,
            fileRootIds: ["downloads"],
            advancedTools: ["system.settings.write"])

        // Ordinary package tools: category ceiling only.
        XCTAssertTrue(try eligible("system.packages.install", admission: admission))
        XCTAssertTrue(try eligible("system.packages.uninstall", admission: admission))
        XCTAssertTrue(try eligible("system.packages.stage", admission: admission))
        XCTAssertTrue(try eligible("system.packages.forceStop", admission: admission))

        // Selected-root file mutations: write ceiling + EXACT root.
        XCTAssertTrue(try eligible("system.files.write",
                                   arguments: ["root": "downloads"],
                                   admission: admission))
        XCTAssertFalse(try eligible("system.files.write",
                                    arguments: ["root": "documents"],
                                    admission: admission),
                       "a root outside the durable selection keeps the gate")
        XCTAssertFalse(try eligible("system.files.move",
                                    arguments: ["root": "downloads"],
                                    admission: publishedAdmission(fileWrites: false)))
        XCTAssertFalse(try eligible("system.files.delete",
                                    arguments: [:], admission: admission),
                       "a missing root fails closed")

        // Advanced tools: individual opt-in only.
        XCTAssertTrue(try eligible("system.settings.write", admission: admission))
        for other in ["system.appOps.manage", "system.permissions.manage",
                      "system.packages.setEnabled", "system.packages.removeForUser",
                      "system.packages.restore"] {
            XCTAssertFalse(try eligible(other, admission: admission),
                           "\(other) was not opted in")
        }

        // Everything outside the closed sets is never admitted. The
        // canonical device-interaction names and the bounded legacy phone.*
        // spellings are equally foreign to the admission ceiling: device
        // tools keep their own approval lifecycle and are never auto-admitted.
        for foreign in ["device.observe", "device.act", "device.screenshot",
                        "phone.observe", "phone.act", "phone.screenshot",
                        "system.packages.query",
                        "system.access.status", "workspace.listDirectory"] {
            XCTAssertFalse(try eligible(foreign, admission: admission))
        }
    }

    func testEligibilityFailsClosedWithoutAvailableToolOrSnapshot() throws {
        let admission = publishedAdmission()
        // Not available even though the ceiling is published.
        XCTAssertFalse(try eligible("system.packages.install", available: false,
                                    admission: admission))
        // Available but no snapshot published.
        XCTAssertFalse(try eligible("system.packages.install", available: true,
                                    admission: nil))
        // Package ceiling disabled: revoked category keeps the gate.
        XCTAssertFalse(try eligible("system.packages.install",
                                    admission: publishedAdmission(packageManagement: false)))
        // Advanced name requires its individual opt-in.
        XCTAssertFalse(try eligible("system.appOps.manage",
                                    admission: publishedAdmission(advancedTools: ["system.settings.write"])))
    }

    private func eligible(_ tool: String, arguments: [String: Any] = [:],
                          available: Bool = true,
                          admission: PlatformToolAutoAdmission?) throws -> Bool {
        try PlatformToolAutomaticAdmission.admits(
            action(tool, arguments: arguments),
            admissionForTool: { _ in available ? admission : nil })
    }

    // MARK: - Policy decisions (runtime grant issuance is separate)

    func testAutomaticPolicyReturnsBoundedAllowForAdmittedCall() async throws {
        let backend = RecordingBackend()
        let policy = AutomaticApprovalPolicy(
            backend: backend, packageReviewBackend: nil,
            trustedAutomaticGrant: { _ in true })
        let proposed = try action("system.packages.install")

        XCTAssertFalse(policy.requiresModelReview(proposed),
                       "an admitted ordinary call must not burn a model review")
        guard case .allow(let scope, let expiresAt) = try await policy.decide(proposed) else {
            return XCTFail("admitted call must receive a real allow decision")
        }
        XCTAssertEqual(scope.toolName, "system.packages.install")
        XCTAssertTrue(scope.singleUse, "the grant stays bound to this one call")
        XCTAssertNil(scope.hostID)
        let ttl = try XCTUnwrap(expiresAt).timeIntervalSinceNow
        XCTAssertGreaterThan(ttl, 18 * 60.0, "grant must outlive the 18 min ticket budget")
        XCTAssertLessThanOrEqual(ttl, 20 * 60.0)
        XCTAssertEqual(backend.callCount, 0,
                       "the trusted ceiling must not consume the review backend")
    }

    func testAutomaticPolicyKeepsEveryOriginalGateOutsideTheCeiling() async throws {
        let backend = RecordingBackend()
        let policy = AutomaticApprovalPolicy(
            backend: backend, packageReviewBackend: nil,
            trustedAutomaticGrant: { _ in false })
        let proposed = try action("system.packages.install")

        XCTAssertTrue(policy.requiresModelReview(proposed))
        guard case .allow = try await policy.decide(proposed) else {
            return XCTFail("the configured backend must still decide non-admitted calls")
        }
        XCTAssertEqual(backend.callCount, 1)
    }

    func testAutomaticPolicyWithoutHookIsByteIdenticalInBehavior() async throws {
        // No hook: sensitive package action, no backend -> original
        // deterministic escalation to the human card (fail closed).
        let policy = AutomaticApprovalPolicy(packageReviewBackend: nil)
        let proposed = try action("system.packages.install")
        XCTAssertFalse(policy.requiresModelReview(proposed),
                       "without a backend the original policy reviews nothing")
        guard case .escalateToHuman = try await policy.decide(proposed) else {
            return XCTFail("the original fail-closed escalation must remain")
        }
    }

    func testGrantTTLCoversTheLongestPackageTicketBudget() {
        XCTAssertGreaterThanOrEqual(
            AutomaticApprovalPolicy.trustedAutomaticGrantTTL,
            TimeInterval(PlatformToolHostLimits.packageTicketBudgetMillis) / 1000,
            "a canonical grant must never expire mid-authorized batch call")
        XCTAssertEqual(PlatformToolHostLimits.ticketBudgetMillis, 30_000,
                       "the ordinary budget stays 30s")
    }

    // MARK: - Mailbox ticket budget (settled packageBudgets.tools)

    func testBudgetMillisOnlyWidensTheNinePackageBatchNames() {
        let long = PlatformToolHostLimits.packageLongBudgetTools
        XCTAssertEqual(long, [
            "system.packages.stage", "system.packages.install",
            "system.packages.uninstall", "system.packages.setEnabled",
            "system.packages.removeForUser", "system.packages.restore",
            "system.permissions.manage", "system.appOps.manage",
            "system.settings.write",
        ])
        for name in long.sorted() {
            XCTAssertEqual(PlatformToolHostLimits.budgetMillis(toolName: name), 1_080_000,
                           "\(name) carries the 18 min bounded-batch budget")
        }
        // Exact-name negatives: reads, device interaction (canonical and
        // legacy spellings), single-package stop, file mutations and unknown
        // names all keep the ordinary 30s budget.
        for name in ["system.packages.forceStop", "system.packages.staged",
                     "system.packages.query", "system.files.write",
                     "system.access.status", "device.observe", "device.act",
                     "device.screenshot", "phone.observe", "phone.act",
                     "phone.screenshot", "ghost.tool"] {
            XCTAssertEqual(PlatformToolHostLimits.budgetMillis(toolName: name), 30_000,
                           "\(name) must keep the 30s budget")
        }
    }

    func testCatalogCapacityFitsCurrentAndPlannedTools() {
        XCTAssertEqual(PlatformToolHostLimits.maximumTools, 32,
                       "18 current + 9 planned advanced tools fit under the bound")
    }

    // MARK: - Unchanged global nonnil grant guard at dispatch

    func testAdmissionAloneNeverSatisfiesTheDispatchGrantGuard() async throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        let mailbox = mailbox(box, registry: registry)
        let installEntry: [String: Any] = [
            "name": "system.packages.install",
            "description": "Synthetic public platform tool.",
            "schema": [
                "type": "object",
                "properties": [
                    "stagedIds": [
                        "type": "array",
                        "items": ["type": "string"],
                        "minItems": 1,
                        "maxItems": 8,
                    ],
                ],
                "required": ["stagedIds"],
                "additionalProperties": false,
            ],
            "riskLabels": ["modifiesRemoteSystem"],
            "effect": "mutating",
            "isSideEffecting": true,
            "hostScope": false,
            "executionBoundary": "mainRunOnly",
            "supportsConcurrentBatchDispatch": false,
        ]
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5, tools: [installEntry]), 0)
        // The trusted host published the package ceiling, and the tool is
        // bound+available — yet a dispatch WITHOUT a canonical grant is
        // refused exactly like before.
        XCTAssertEqual(mailbox.setAutoAdmission(
            epoch: 5, admissionJSON: admissionJSON(packageManagement: true)), 0)
        XCTAssertTrue(mailbox.isToolAvailable(named: "system.packages.install"))

        let context = ToolContext(
            runID: runID,
            toolCallID: "call-fixture",
            toolIdempotencyKey: "idem-fixture",
            approvalGrantID: nil,
            scope: .local,
            cancellation: CancellationToken(),
            conversationID: taskID)
        do {
            _ = try await mailbox.execute(
                toolName: "system.packages.install",
                argumentsJSON: Data(#"{"stagedIds":["s1"]}"#.utf8),
                context: context)
            XCTFail("the global nonnil grant guard must stay authoritative")
        } catch let error as FloeError {
            XCTAssertEqual(error, .validationFailed(
                "This device action requires an approved task grant"))
        }
        XCTAssertEqual(mailbox.nextClaim(timeoutMillis: 0), 0)

        // A synthetic approved context verifies grant propagation. Actual
        // canonical issuance is exercised through the App runtime.
        let granted = ToolContext(
            runID: runID,
            toolCallID: "call-fixture",
            toolIdempotencyKey: "idem-fixture",
            approvalGrantID: grantID,
            scope: .local,
            cancellation: CancellationToken(),
            conversationID: taskID)
        let args = Data(#"{"stagedIds":["s1"]}"#.utf8)
        let task = Task {
            try await mailbox.execute(
                toolName: "system.packages.install",
                argumentsJSON: args, context: granted)
        }
        let claim = await waitForClaim(mailbox)
        XCTAssertGreaterThan(claim, 0)
        var buffer = [CChar](repeating: 0,
                             count: PlatformToolHostLimits.maximumTicketDescriptorBytes + 1)
        let length = mailbox.describe(claim: claim, buffer: &buffer,
                                      capacity: Int32(buffer.count))
        XCTAssertGreaterThan(length, 0)
        let descriptor = try JSONSerialization.jsonObject(
            with: Data(bytes: buffer, count: Int(length))) as! [String: Any]
        XCTAssertEqual(descriptor["approvalGrantID"] as? String,
                       grantID.uuidString)
        XCTAssertEqual(descriptor["tool"] as? String, "system.packages.install")
        XCTAssertEqual(descriptor["epoch"] as? String, "5")
        XCTAssertEqual(descriptor["taskID"] as? String, taskID.uuidString)
        XCTAssertEqual(descriptor["runID"] as? String, runID.uuidString)
        let reply = Data(#"{"version":1,"summary":"ok","exitStatus":0}"#.utf8)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: reply), 0)
        let output = try await task.value
        XCTAssertEqual(output.exitStatus, 0)
    }

    private func waitForClaim(_ mailbox: PlatformToolHostMailbox) async -> Int64 {
        for _ in 0..<100 {
            let claim = mailbox.nextClaim(timeoutMillis: 20)
            if claim > 0 { return claim }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return 0
    }
}
