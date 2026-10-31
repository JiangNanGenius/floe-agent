// SPDX-License-Identifier: MPL-2.0
//
// Authored-only regressions for the G08 generic trusted App-platform tool
// bridge. NOT executed by this lane (Main runs the combined batch). Every
// fixture is synthetic/public: no device, ADB, root, real screenshot, private
// app content, credential or network target is touched.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeSecurity
import FloeTools
@testable import FloeAgentRuntime
@testable import FloeAndroidCore

final class G08PlatformToolTests: XCTestCase {

    private let taskID = UUID(uuidString: "30000000-0000-4000-8000-000000000003")!
    private let runID = UUID(uuidString: "40000000-0000-4000-8000-000000000004")!
    private let grantID = UUID(uuidString: "50000000-0000-4000-8000-000000000005")!
    private let hostID = UUID(uuidString: "60000000-0000-4000-8000-000000000006")!

    /// The ACTUAL owned root in the shape `RuntimeStorageRoot` validates. The
    /// mailbox derives `<owned root>/FloeAgent`; tests never hand it the
    /// already-appended directory.
    private var ownedRoot: URL!

    private var artifactRoot: URL {
        ownedRoot.appendingPathComponent("FloeAgent", isDirectory: true)
    }

    override func setUp() {
        super.setUp()
        ownedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("G08PlatformToolTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(
            at: ownedRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let ownedRoot {
            try? FileManager.default.removeItem(at: ownedRoot)
        }
        super.tearDown()
    }

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

    private var emptySchema: [String: Any] {
        ["type": "object", "properties": [String: Any](), "additionalProperties": false]
    }

    private var labelSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "label": ["type": "string", "minLength": 1, "maxLength": 32],
            ],
            "required": ["label"],
            "additionalProperties": false,
        ]
    }

    private var enumSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "mode": [
                    "type": "string", "enum": ["observe", "tap"],
                ],
                "count": [
                    "type": "integer", "minimum": 1, "maximum": 3,
                ],
            ],
            "required": ["mode"],
            "additionalProperties": false,
        ]
    }

    private func makeEntry(
        name: String,
        description: String = "Synthetic public platform tool.",
        schema: [String: Any]? = nil,
        risks: [String] = ["controlsGUI"],
        effect: String = "readOnly",
        sideEffecting: Bool = false,
        hostScope: Bool = false,
        boundary: String = "mainRunOnly",
        concurrent: Bool = false
    ) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "schema": schema ?? emptySchema,
            "riskLabels": risks,
            "effect": effect,
            "isSideEffecting": sideEffecting,
            "hostScope": hostScope,
            "executionBoundary": boundary,
            "supportsConcurrentBatchDispatch": concurrent,
        ]
    }

    private func catalogData(_ tools: [[String: Any]]) -> Data {
        try! JSONSerialization.data(
            withJSONObject: ["version": 1, "tools": tools],
            options: [.sortedKeys])
    }

    private func mailbox(_ box: EpochBox,
                         registry: ToolRunnerRegistry = ToolRunnerRegistry(),
                         bindArtifactRoot: Bool = true)
        -> PlatformToolHostMailbox {
        let mailbox = PlatformToolHostMailbox(
            registry: registry,
            currentEpoch: { box.current })
        if bindArtifactRoot, let epoch = box.current {
            XCTAssertTrue(
                mailbox.bindArtifactRoot(ownedRootPath: ownedRoot.path,
                                         epoch: epoch),
                "the test-owned root must bind for the live fixture epoch")
        }
        return mailbox
    }

    private func context(
        toolCallID: String = "call-1",
        idempotencyKey: String = "idem-1",
        cancellation: CancellationToken = CancellationToken(),
        temporary: Bool = false,
        publicWebOnly: Bool = false,
        approvalGrantID: UUID? = nil,
        scope: ToolScope = .local,
        allowed: Set<String>? = nil,
        origin: ToolCallOrigin? = nil
    ) -> ToolContext {
        ToolContext(
            runID: runID,
            toolCallID: toolCallID,
            toolIdempotencyKey: idempotencyKey,
            approvalGrantID: approvalGrantID,
            scope: scope,
            allowedToolNames: allowed,
            publicWebOnly: publicWebOnly,
            cancellation: cancellation,
            conversationID: taskID,
            callOrigin: origin,
            temporaryReadOnly: temporary)
    }

    private func mainOrigin(tool: String, callID: String = "call-1")
        -> ToolCallOrigin {
        ToolCallOrigin(kind: .mainRunDelegate, runID: runID,
                       callID: callID, toolName: tool)
    }

    private func waitForClaim(_ mailbox: PlatformToolHostMailbox) async -> Int64 {
        for _ in 0..<100 {
            let claim = mailbox.nextClaim(timeoutMillis: 20)
            if claim > 0 { return claim }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return 0
    }

    private func describe(_ mailbox: PlatformToolHostMailbox,
                          claim: Int64) -> [String: Any]? {
        var buffer = [CChar](repeating: 0,
                             count: PlatformToolHostLimits.maximumTicketDescriptorBytes + 1)
        let length = mailbox.describe(claim: claim, buffer: &buffer,
                                      capacity: Int32(buffer.count))
        guard length > 0 else { return nil }
        return try? JSONSerialization.jsonObject(
            with: Data(bytes: buffer, count: Int(length))) as? [String: Any]
    }

    private func payload(_ mailbox: PlatformToolHostMailbox,
                         claim: Int64) -> Data? {
        let length = mailbox.payloadLength(claim: claim)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(length))
        let copied = mailbox.takePayload(claim: claim, buffer: &buffer,
                                         capacity: length)
        guard copied == length else { return nil }
        return Data(buffer)
    }

    private func availabilityData(_ names: [String]) -> Data {
        try! JSONSerialization.data(withJSONObject: names,
                                    options: [.sortedKeys])
    }

    /// Bind one trusted catalog and publish every declared name as actually
    /// available. Existing behavior fixtures must state the live capability
    /// explicitly; bind alone is intentionally fail-closed for discovery.
    @discardableResult
    private func bindAndExpose(_ mailbox: PlatformToolHostMailbox,
                               epoch: UInt64,
                               tools: [[String: Any]]) -> Int32 {
        let result = mailbox.bind(epoch: epoch,
                                  catalogJSON: catalogData(tools))
        guard result == 0 else { return result }
        let names = tools.compactMap { $0["name"] as? String }
        let published = mailbox.setAvailability(
            epoch: epoch, namesJSON: availabilityData(names))
        XCTAssertEqual(published, 0,
                       "fixture must publish its actual usable subset")
        return result
    }

    private func artifactJSON(relativePath: String, mimeType: String,
                              data: Data) -> [String: Any] {
        [
            "relativePath": relativePath,
            "mimeType": mimeType,
            "byteCount": data.count,
            "sha256": FloeDigest.sha256Hex(data),
        ]
    }

    private func resultData(summary: String = "Synthetic result.",
                            exitStatus: Int? = 0,
                            evidence: [String] = [],
                            artifact: [String: Any]? = nil) -> Data {
        var object: [String: Any] = ["version": 1, "summary": summary]
        if let exitStatus { object["exitStatus"] = exitStatus }
        if !evidence.isEmpty { object["evidence"] = evidence }
        if let artifact { object["artifact"] = artifact }
        return try! JSONSerialization.data(withJSONObject: object,
                                           options: [.sortedKeys])
    }

    private func json(_ string: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(string.utf8)) as! [String: Any]
    }

    // MARK: - Registration

    func testBindInstallsExactMetadataAndHonestReadiness() throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        let mailbox = mailbox(box, registry: registry)

        XCTAssertEqual(mailbox.bind(
            epoch: 5,
            catalogJSON: catalogData([makeEntry(name: "sample.inspect")])), 0)
        XCTAssertTrue(mailbox.isBound(to: 5))
        XCTAssertEqual(mailbox.installedToolNames(), ["sample.inspect"])
        XCTAssertFalse(mailbox.isToolAvailable(named: "sample.inspect"),
                       "bind alone must leave every runner unavailable")
        let unpublished = json(mailbox.readinessJSON())
        XCTAssertEqual(unpublished["reason"] as? String,
                       "availabilityUnpublished")
        XCTAssertEqual(unpublished["availableNames"] as? [String], [])

        XCTAssertEqual(mailbox.setAvailability(
            epoch: 5,
            namesJSON: availabilityData(["sample.inspect"])), 0)
        XCTAssertTrue(mailbox.isToolAvailable(named: "sample.inspect"))
        let descriptor = try XCTUnwrap(
            registry.descriptor(named: "sample.inspect"))
        XCTAssertEqual(descriptor.name, "sample.inspect")
        XCTAssertEqual(descriptor.riskLabels, [.controlsGUI])
        XCTAssertEqual(descriptor.effect, .readOnly)
        XCTAssertFalse(descriptor.isSideEffecting)
        XCTAssertFalse(descriptor.requiresHostScope)
        XCTAssertEqual(descriptor.executionBoundary, .mainRunOnly)
        XCTAssertFalse(descriptor.supportsConcurrentBatchDispatch)
        XCTAssertTrue(descriptor.parametersJSON.contains("additionalProperties"))

        let readiness = json(mailbox.readinessJSON())
        XCTAssertEqual(readiness["bound"] as? Bool, true)
        XCTAssertEqual(readiness["epoch"] as? String, "5")
        XCTAssertEqual(readiness["reason"] as? String, "ready")
        XCTAssertEqual(readiness["registered"] as? [String], ["sample.inspect"])
        XCTAssertEqual(readiness["availableNames"] as? [String], ["sample.inspect"])
        XCTAssertEqual(readiness["availabilityPublished"] as? Bool, true)
        XCTAssertEqual(readiness["installed"] as? Int, 1)

        let stats = json(mailbox.statsJSON())
        let counters = try XCTUnwrap(stats["counters"] as? [String: Any])
        XCTAssertEqual(counters["binds"] as? Int, 1)
        XCTAssertEqual(counters["submitted"] as? Int, 0)
    }

    func testInternalStateMetadataIsAcceptedWithoutSideEffectApproval() throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        let mailbox = mailbox(box, registry: registry)
        let tool = makeEntry(name: "sample.note",
                             risks: ["persistsPersonalData"],
                             effect: "internalState",
                             sideEffecting: false)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5, tools: [tool]), 0)
        let descriptor = try XCTUnwrap(registry.descriptor(named: "sample.note"))
        XCTAssertEqual(descriptor.effect, .internalState)
        XCTAssertFalse(descriptor.isSideEffecting)
        XCTAssertEqual(descriptor.riskLabels, [.persistsPersonalData])
        XCTAssertFalse(descriptor.effect.isAllowedInPlanMode)
    }

    func testRebindReplacesCatalogAndRemovesStaleNames() throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        let mailbox = mailbox(box, registry: registry)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5, tools: [makeEntry(name: "alpha.read")]), 0)
        XCTAssertNotNil(registry.descriptor(named: "alpha.read"))

        box.set(6)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 6, tools: [makeEntry(name: "beta.read")]), 0)
        XCTAssertNil(registry.descriptor(named: "alpha.read"))
        XCTAssertNotNil(registry.descriptor(named: "beta.read"))
        XCTAssertEqual(mailbox.installedToolNames(), ["beta.read"])

        let readiness = json(mailbox.readinessJSON())
        XCTAssertEqual(readiness["registered"] as? [String], ["beta.read"])
    }

    func testCloseRemovesOwnedToolsAndFencesClaimedTicket() async throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        let mailbox = mailbox(box, registry: registry)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5, tools: [makeEntry(name: "alpha.read",
                                            schema: labelSchema)]), 0)

        let args = Data(#"{"label":"synthetic"}"#.utf8)
        let toolContext = context(origin: mainOrigin(tool: "alpha.read"))
        let task = Task {
            try await mailbox.execute(toolName: "alpha.read",
                                      argumentsJSON: args, context: toolContext)
        }
        let claim = await waitForClaim(mailbox)
        XCTAssertGreaterThan(claim, 0)

        mailbox.close(epoch: 5)
        XCTAssertNil(registry.descriptor(named: "alpha.read"))
        XCTAssertFalse(mailbox.isBound)

        do {
            _ = try await task.value
            XCTFail("close must fence the claimed ticket")
        } catch let error as FloeError {
            XCTAssertEqual(error, .invalidConfiguration(
                "Phone and system tools are unavailable for the current runtime generation"))
        }

        XCTAssertEqual(
            mailbox.complete(claim: claim, status: 0, value: resultData()), -101,
            "a closed-generation settle is classified as stale")
        let counters = try XCTUnwrap(
            json(mailbox.statsJSON())["counters"] as? [String: Any])
        XCTAssertEqual(counters["lateSettle"] as? Int, 1)
    }

    func testInvalidOrUnsafeCatalogsAreRefusedWithoutInstallation() throws {
        struct Case {
            let name: String
            let tools: [[String: Any]]
        }
        let cases: [Case] = [
            Case(name: "unknownRisk", tools: [makeEntry(name: "bad.read", risks: ["teleportation"])]),
            Case(name: "codeRisk", tools: [makeEntry(name: "bad.run", risks: ["executesLocalCode"])]),
            Case(name: "unknownEffect", tools: [makeEntry(name: "bad.effect", effect: "sideways")]),
            Case(name: "readOnlySideEffect", tools: [makeEntry(name: "bad.contradiction", effect: "readOnly", sideEffecting: true)]),
            Case(name: "mutatingNotEffectful", tools: [makeEntry(name: "bad.contradiction2", effect: "mutating", sideEffecting: false)]),
            Case(name: "anyBoundary", tools: [makeEntry(name: "bad.boundary", boundary: "any")]),
            Case(name: "concurrent", tools: [makeEntry(name: "bad.concurrent", concurrent: true)]),
            Case(name: "openSchema", tools: [makeEntry(name: "bad.schema", schema: ["type": "object", "properties": [:], "additionalProperties": true])]),
            Case(name: "unsupportedKeyword", tools: [makeEntry(name: "bad.keyword", schema: ["type": "object", "properties": ["x": ["type": "string", "pattern": "^a$"]], "additionalProperties": false])]),
            Case(name: "reservedOwnership", tools: [makeEntry(name: "bad.owner", schema: ["type": "object", "properties": ["taskID": ["type": "string"]], "additionalProperties": false])]),
            Case(name: "reservedNamespace", tools: [makeEntry(name: "mcp.synthetic.tool")]),
            Case(name: "duplicate", tools: [makeEntry(name: "dup.read"), makeEntry(name: "dup.read")]),
            Case(name: "missingField", tools: [[
                "name": "bad.missing", "description": "x",
                "schema": emptySchema, "riskLabels": ["controlsGUI"],
                "effect": "readOnly", "isSideEffecting": false,
                "hostScope": false, "executionBoundary": "mainRunOnly",
            ]]),
        ]
        for item in cases {
            let box = EpochBox(5)
            let registry = ToolRunnerRegistry()
            let mailbox = mailbox(box, registry: registry)
            XCTAssertEqual(mailbox.bind(
                epoch: 5, catalogJSON: catalogData(item.tools)), -108,
                "case \(item.name) must be refused")
            XCTAssertTrue(mailbox.installedToolNames().isEmpty)
            XCTAssertNil(registry.descriptor(named: item.tools.first?["name"] as? String ?? ""))
            let stats = json(mailbox.statsJSON())
            XCTAssertFalse((stats["lastBind"] as? String ?? "").isEmpty,
                           "case \(item.name) must record a bounded reason")
            XCTAssertEqual(stats["installed"] as? Int, 0)
        }
    }

    func testForeignRunnerCollisionIsRefused() throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        var foreign = AnyAgentTool(
            descriptor: ToolCatalog.Descriptor(
                name: "foreign.action", riskLabels: [], isSideEffecting: false),
            run: { _, _ in ToolExecutionOutput(digesting: "foreign") })
        foreign.isAvailable = { true }
        registry.register(foreign)
        let mailbox = mailbox(box, registry: registry)

        XCTAssertEqual(mailbox.bind(
            epoch: 5,
            catalogJSON: catalogData([makeEntry(name: "foreign.action")])), -108)
        XCTAssertNotNil(registry.descriptor(named: "foreign.action"))
        XCTAssertTrue(mailbox.installedToolNames().isEmpty)
    }

    // MARK: - Schema enforcement

    func testClosedBoundedSchemaEnforcesEnumsAndRejectsForgedOwnership() throws {
        let schemaJSON = String(
            data: try JSONSerialization.data(withJSONObject: enumSchema),
            encoding: .utf8)!
        try PlatformToolSchemaValidator.validateArguments(
            Data(#"{"mode":"tap","count":2}"#.utf8), schemaJSON: schemaJSON)

        for invalid in [
            #"{"mode":"shell"}"#,
            #"{"mode":"tap","taskID":"forged"}"#,
            #"{"count":2}"#,
            #"{"mode":"tap","count":9}"#,
            #"{"mode":"tap","count":"2"}"#,
        ] {
            XCTAssertThrowsError(
                try PlatformToolSchemaValidator.validateArguments(
                    Data(invalid.utf8), schemaJSON: schemaJSON),
                "must reject \(invalid)")
        }

        let oversized = Data(repeating: 0x20,
                             count: PlatformToolHostLimits.maximumArgumentsBytes + 1)
        XCTAssertThrowsError(
            try PlatformToolSchemaValidator.validateArguments(
                oversized, schemaJSON: schemaJSON))
    }

    // MARK: - Execution ownership

    func testExecuteCarriesAuthenticatedOwnerAndReturnsBoundedResult() async throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        let mailbox = mailbox(box, registry: registry)
        let entry = makeEntry(name: "sample.act", schema: labelSchema,
                          risks: ["controlsGUI", "persistsPersonalData"],
                          effect: "mutating", sideEffecting: true, hostScope: true)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5, tools: [entry]), 0)

        let args = Data(#"{"label":"synthetic"}"#.utf8)
        let toolContext = context(
            approvalGrantID: grantID, scope: .host(hostID),
            origin: mainOrigin(tool: "sample.act"))
        let task = Task {
            try await mailbox.execute(toolName: "sample.act",
                                      argumentsJSON: args, context: toolContext)
        }
        let claim = await waitForClaim(mailbox)
        XCTAssertGreaterThan(claim, 0)

        let descriptor = try XCTUnwrap(describe(mailbox, claim: claim))
        XCTAssertEqual(descriptor["operation"] as? String, "platformTool.execute")
        XCTAssertEqual(descriptor["tool"] as? String, "sample.act")
        XCTAssertEqual(descriptor["epoch"] as? String, "5")
        XCTAssertEqual(descriptor["taskID"] as? String, taskID.uuidString)
        XCTAssertEqual(descriptor["runID"] as? String, runID.uuidString)
        XCTAssertEqual(descriptor["toolCallID"] as? String, "call-1")
        XCTAssertEqual(descriptor["idempotencyKey"] as? String, "idem-1")
        XCTAssertEqual(descriptor["approvalGrantID"] as? String, grantID.uuidString)
        XCTAssertEqual(descriptor["argumentsSHA256"] as? String,
                       FloeDigest.sha256Hex(args))
        XCTAssertEqual(descriptor["argumentsBytes"] as? Int, args.count)
        XCTAssertEqual(descriptor["riskLabels"] as? [String],
                       ["controlsGUI", "persistsPersonalData"])
        XCTAssertEqual(descriptor["effect"] as? String, "mutating")
        XCTAssertEqual(descriptor["sideEffecting"] as? Bool, true)
        XCTAssertEqual(descriptor["hostScope"] as? Bool, true)
        XCTAssertTrue(descriptor["scope"] is [String: Any])
        XCTAssertEqual(payload(mailbox, claim: claim), args)

        let reply = resultData(summary: "Synthetic action done.",
                               exitStatus: 0,
                               evidence: ["screenGeneration=7"])
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: reply), 0)
        let output = try await task.value
        XCTAssertTrue(output.summary.contains("Synthetic action done."))
        XCTAssertTrue(output.summary.contains("screenGeneration=7"))
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertEqual(output.fullOutputSHA256, FloeDigest.sha256Hex(reply))
        XCTAssertTrue(output.artifacts.isEmpty)
        XCTAssertEqual(mailbox.isLive(claim: claim), 0)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: reply), -101)
    }

    func testSideEffectingToolRequiresApprovalGrant() async throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        let mailbox = mailbox(box, registry: registry)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5, tools: [
            makeEntry(name: "sample.write", schema: labelSchema,
                  effect: "mutating", sideEffecting: true),
        ]), 0)

        let toolContext = context(origin: mainOrigin(tool: "sample.write"))
        do {
            _ = try await mailbox.execute(
                toolName: "sample.write",
                argumentsJSON: Data(#"{"label":"x"}"#.utf8),
                context: toolContext)
            XCTFail("side-effecting host tools require an approved grant")
        } catch let error as FloeError {
            XCTAssertEqual(error, .validationFailed(
                "This phone action requires an approved task grant"))
        }
        XCTAssertEqual(mailbox.nextClaim(timeoutMillis: 0), 0)
    }

    func testTemporaryPublicWebOnlyChildAndCeilingContextsAreRefused() async throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        let mailbox = mailbox(box, registry: registry)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5, tools: [
            makeEntry(name: "alpha.read", schema: labelSchema),
        ]), 0)
        let args = Data(#"{"label":"synthetic"}"#.utf8)

        let delegated = ToolCallOrigin(kind: .delegatedChild, runID: runID,
                                       callID: "call-1", toolName: "alpha.read")
        let cases: [(String, ToolContext)] = [
            ("temporary", context(temporary: true)),
            ("publicWebOnly", context(publicWebOnly: true)),
            ("delegatedChild", context(origin: delegated)),
            ("ceiling", context(allowed: ["other.tool"])),
        ]
        for (name, candidateContext) in cases {
            do {
                _ = try await mailbox.execute(toolName: "alpha.read",
                                              argumentsJSON: args,
                                              context: candidateContext)
                XCTFail("\(name) must be refused before any ticket")
            } catch let error as FloeError {
                XCTAssertNotEqual(error, .cancelled, name)
            }
        }
        XCTAssertEqual(mailbox.nextClaim(timeoutMillis: 0), 0)
    }

    func testForgedCrossRunOriginAndUnknownClaimAreRefused() async throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        let mailbox = mailbox(box, registry: registry)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5, tools: [
            makeEntry(name: "alpha.read", schema: labelSchema),
        ]), 0)

        let otherRun = UUID(uuidString: "70000000-0000-4000-8000-000000000007")!
        let forged = ToolCallOrigin(kind: .mainRunDelegate, runID: otherRun,
                                    callID: "call-1", toolName: "alpha.read")
        let toolContext = context(origin: forged)
        do {
            _ = try await mailbox.execute(
                toolName: "alpha.read",
                argumentsJSON: Data(#"{"label":"synthetic"}"#.utf8),
                context: toolContext)
            XCTFail("a cross-run origin must never authorize a ticket")
        } catch let error as FloeError {
            XCTAssertEqual(error, .validationFailed(
                "Phone and system tools are main-run only"))
        }
        XCTAssertEqual(mailbox.nextClaim(timeoutMillis: 0), 0)
        XCTAssertEqual(mailbox.complete(claim: 987_654_321, status: 0,
                                        value: resultData()), -101,
                       "an unknown claim is classified, never settled")
    }

    // MARK: - Cancellation / malformed settlement

    func testCancellationRefusesSuccessExactlyOnce() async throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        let mailbox = mailbox(box, registry: registry)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5, tools: [
            makeEntry(name: "alpha.read", schema: labelSchema),
        ]), 0)

        let cancellation = CancellationToken()
        let toolContext = context(cancellation: cancellation,
                                  origin: mainOrigin(tool: "alpha.read"))
        let task = Task {
            try await mailbox.execute(
                toolName: "alpha.read",
                argumentsJSON: Data(#"{"label":"synthetic"}"#.utf8),
                context: toolContext)
        }
        let claim = await waitForClaim(mailbox)
        XCTAssertGreaterThan(claim, 0)
        XCTAssertEqual(mailbox.shouldStop(claim: claim), 0)
        cancellation.cancel()
        XCTAssertEqual(mailbox.shouldStop(claim: claim), 1)

        XCTAssertEqual(
            mailbox.complete(claim: claim, status: 0, value: resultData()), -109)
        XCTAssertEqual(
            mailbox.complete(claim: claim, status: 0, value: resultData()), -101,
            "a cancelled ticket settles exactly once")
        do {
            _ = try await task.value
            XCTFail("success after cancellation must never be observed")
        } catch let error as FloeError {
            XCTAssertEqual(error, .cancelled)
        }
        let counters = try XCTUnwrap(
            json(mailbox.statsJSON())["counters"] as? [String: Any])
        XCTAssertEqual(counters["cancelled"] as? Int, 1)
        XCTAssertEqual(counters["completed"] as? Int, 0)
    }

    func testMalformedAndOversizedRepliesAreRejected() async throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        let mailbox = mailbox(box, registry: registry)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5, tools: [
            makeEntry(name: "alpha.read", schema: labelSchema),
        ]), 0)
        let args = Data(#"{"label":"synthetic"}"#.utf8)
        let toolContext = context(origin: mainOrigin(tool: "alpha.read"))

        let task = Task {
            try await mailbox.execute(toolName: "alpha.read",
                                      argumentsJSON: args, context: toolContext)
        }
        let claim = await waitForClaim(mailbox)
        XCTAssertGreaterThan(claim, 0)

        let oversized = Data(repeating: 0x61,
                             count: PlatformToolHostLimits.maximumReplyBytes + 1)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0,
                                        value: oversized), -107)
        XCTAssertEqual(mailbox.isLive(claim: claim), 1,
                       "an oversized settle leaves the claim live for one valid reply")
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0,
                                        value: Data("{not-json".utf8)), -108)
        do {
            _ = try await task.value
            XCTFail("malformed success must never resume success")
        } catch let error as FloeError {
            XCTAssertEqual(error, .internalError(
                "The phone returned an invalid tool result"))
        }
        let counters = try XCTUnwrap(
            json(mailbox.statsJSON())["counters"] as? [String: Any])
        XCTAssertEqual(counters["invalid"] as? Int, 1)
    }

    func testFailureReplyIsBoundedMappedAndNeverEchoesDetail() async throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        let mailbox = mailbox(box, registry: registry)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5, tools: [
            makeEntry(name: "alpha.read", schema: labelSchema),
        ]), 0)
        let toolContext = context(origin: mainOrigin(tool: "alpha.read"))
        let task = Task {
            try await mailbox.execute(
                toolName: "alpha.read",
                argumentsJSON: Data(#"{"label":"synthetic"}"#.utf8),
                context: toolContext)
        }
        let claim = await waitForClaim(mailbox)
        XCTAssertGreaterThan(claim, 0)

        let oversized = Data(repeating: 0x61,
                             count: PlatformToolHostLimits.maximumFailureReplyBytes + 1)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 1,
                                        value: oversized), -107)
        let failure = Data(#"{"code":"permissionRequired","detail":"/private/path\u0000"}"#.utf8)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 1,
                                        value: failure), 0)
        do {
            _ = try await task.value
            XCTFail("typed failure must surface as FloeError")
        } catch let error as FloeError {
            XCTAssertEqual(error, .validationFailed(
                "Android permission or user authorization is required for this action"))
            XCTAssertFalse(error.reason.contains("/private/path"))
        }
    }

    // MARK: - Screenshot evidence

    func testScreenshotArtifactMustBeVerifiedOnDisk() async throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        let mailbox = mailbox(box, registry: registry)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5, tools: [
            makeEntry(name: "alpha.screen", schema: labelSchema),
        ]), 0)

        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )!
        let phoneDirectory = artifactRoot.appendingPathComponent(
            "VNCArtifacts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: phoneDirectory, withIntermediateDirectories: true)
        let pngURL = phoneDirectory.appendingPathComponent("synthetic-shot.png")
        try png.write(to: pngURL)
        let sha = FloeDigest.sha256Hex(png)

        let artifact: [String: Any] = [
            "relativePath": "VNCArtifacts/synthetic-shot.png",
            "mimeType": "image/png",
            "byteCount": png.count,
            "sha256": sha,
        ]
        let screenContext = context(origin: mainOrigin(tool: "alpha.screen"))
        let task = Task {
            try await mailbox.execute(
                toolName: "alpha.screen",
                argumentsJSON: Data(#"{"label":"synthetic"}"#.utf8),
                context: screenContext)
        }
        let claim = await waitForClaim(mailbox)
        XCTAssertGreaterThan(claim, 0)
        XCTAssertEqual(mailbox.complete(
            claim: claim, status: 0,
            value: resultData(summary: "Captured one screen.",
                              artifact: artifact)), 0)
        let output = try await task.value
        let delivered = try XCTUnwrap(output.artifacts.first)
        XCTAssertEqual(delivered.relativePath, "VNCArtifacts/synthetic-shot.png")
        XCTAssertEqual(delivered.mimeType, "image/png")
        XCTAssertEqual(delivered.sha256, sha)
        XCTAssertEqual(delivered.byteCount, png.count)
    }

    func testScreenshotArtifactMetadataCannotLieAboutBytes() async throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        let mailbox = mailbox(box, registry: registry)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5, tools: [
            makeEntry(name: "alpha.screen", schema: labelSchema),
        ]), 0)

        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )!
        let phoneDirectory = artifactRoot.appendingPathComponent(
            "VNCArtifacts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: phoneDirectory, withIntermediateDirectories: true)
        try png.write(to: phoneDirectory.appendingPathComponent("real.png"))
        try png.write(to: phoneDirectory.appendingPathComponent("spoof.jpg"))

        // A real JPEG byte body declared as PNG must be refused as a MIME
        // mismatch, and a real PNG under a `.jpg` name must not silently pass
        // the closed extension/MIME contract.
        try png.write(to: phoneDirectory.appendingPathComponent("real.jpg"))
        let pngSHA = FloeDigest.sha256Hex(png)

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("G08-outside-\(UUID().uuidString).png")
        try png.write(to: outside)
        let symlinkPath = phoneDirectory.appendingPathComponent("linked.png")
        try? FileManager.default.removeItem(at: symlinkPath)
        try FileManager.default.createSymbolicLink(
            at: symlinkPath, withDestinationURL: outside)
        let insideLink = phoneDirectory.appendingPathComponent("linked-inside.png")
        try? FileManager.default.removeItem(at: insideLink)
        try FileManager.default.createSymbolicLink(
            at: insideLink,
            withDestinationURL: phoneDirectory.appendingPathComponent("real.png"))
        defer { try? FileManager.default.removeItem(at: outside) }

        let lies: [[String: Any]] = [
            [
                "relativePath": "VNCArtifacts/real.png",
                "mimeType": "image/png",
                "byteCount": png.count,
                "sha256": String(repeating: "0", count: 64),
            ],
            [
                "relativePath": "VNCArtifacts/missing.png",
                "mimeType": "image/png",
                "byteCount": png.count,
                "sha256": FloeDigest.sha256Hex(png),
            ],
            [
                "relativePath": "VNCArtifacts/../outside.png",
                "mimeType": "image/png",
                "byteCount": png.count,
                "sha256": FloeDigest.sha256Hex(png),
            ],
            [
                "relativePath": "Artifacts/real.png",
                "mimeType": "image/png",
                "byteCount": png.count,
                "sha256": FloeDigest.sha256Hex(png),
            ],
            [
                // Extension/declared-MIME disagreement.
                "relativePath": "VNCArtifacts/real.jpg",
                "mimeType": "image/png",
                "byteCount": png.count,
                "sha256": pngSHA,
            ],
            [
                // Real PNG bytes declared as JPEG.
                "relativePath": "VNCArtifacts/real.png",
                "mimeType": "image/jpeg",
                "byteCount": png.count,
                "sha256": pngSHA,
            ],
            [
                // PNG bytes under a `.jpg` name, declared JPEG.
                "relativePath": "VNCArtifacts/spoof.jpg",
                "mimeType": "image/jpeg",
                "byteCount": png.count,
                "sha256": pngSHA,
            ],
            [
                // A symlink stays inside the lexical root but resolves
                // outside it; it must never be accepted.
                "relativePath": "VNCArtifacts/linked.png",
                "mimeType": "image/png",
                "byteCount": png.count,
                "sha256": pngSHA,
            ],
            [
                // A symlink that resolves to another in-root file is still a
                // symlink and must be refused; only real host-committed bytes
                // count as evidence.
                "relativePath": "VNCArtifacts/linked-inside.png",
                "mimeType": "image/png",
                "byteCount": png.count,
                "sha256": pngSHA,
            ],
        ]

        let screenContext = context(origin: mainOrigin(tool: "alpha.screen"))
        for artifact in lies {
            let task = Task {
                try await mailbox.execute(
                    toolName: "alpha.screen",
                    argumentsJSON: Data(#"{"label":"synthetic"}"#.utf8),
                    context: screenContext)
            }
            let claim = await waitForClaim(mailbox)
            XCTAssertGreaterThan(claim, 0)
            XCTAssertEqual(mailbox.complete(
                claim: claim, status: 0,
                value: resultData(artifact: artifact)), -108,
                "artifact \(artifact["relativePath"] ?? "?") must be refused")
            do {
                _ = try await task.value
                XCTFail("a fabricated artifact must not reach the model")
            } catch let error as FloeError {
                XCTAssertEqual(error, .internalError(
                    "The phone returned an invalid tool result"))
            }
        }
    }


    func testArtifactAcceptanceFailsClosedUntilActualOwnedRootIsBound() async throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        let mailbox = mailbox(box, registry: registry, bindArtifactRoot: false)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5, tools: [
            makeEntry(name: "alpha.screen", schema: labelSchema),
        ]), 0)
        XCTAssertNil(mailbox.artifactRootPathForTrustedHost(),
                     "no ambient root may exist before composition binds one")

        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )!
        let directory = artifactRoot.appendingPathComponent(
            "VNCArtifacts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("unbound.png"))
        let artifact = artifactJSON(
            relativePath: "VNCArtifacts/unbound.png",
            mimeType: "image/png", data: png)

        let screenContext = context(origin: mainOrigin(tool: "alpha.screen"))
        let first = Task {
            try await mailbox.execute(
                toolName: "alpha.screen",
                argumentsJSON: Data(#"{"label":"synthetic"}"#.utf8),
                context: screenContext)
        }
        let firstClaim = await waitForClaim(mailbox)
        XCTAssertGreaterThan(firstClaim, 0)
        XCTAssertEqual(mailbox.complete(
            claim: firstClaim, status: 0,
            value: resultData(artifact: artifact)), -108,
            "a screenshot must be refused while no actual owned root is bound")
        do {
            _ = try await first.value
            XCTFail("an unbound artifact must never reach the model")
        } catch let error as FloeError {
            XCTAssertEqual(error, .internalError(
                "The phone returned an invalid tool result"))
        }

        XCTAssertTrue(mailbox.bindArtifactRoot(
            ownedRootPath: ownedRoot.path, epoch: 5))
        let expected = URL(fileURLWithPath: artifactRoot.path)
            .standardizedFileURL.path
        XCTAssertEqual(mailbox.artifactRootPathForTrustedHost(), expected)

        let second = Task {
            try await mailbox.execute(
                toolName: "alpha.screen",
                argumentsJSON: Data(#"{"label":"synthetic"}"#.utf8),
                context: screenContext)
        }
        let secondClaim = await waitForClaim(mailbox)
        XCTAssertGreaterThan(secondClaim, 0)
        XCTAssertEqual(mailbox.complete(
            claim: secondClaim, status: 0,
            value: resultData(artifact: artifact)), 0)
        let output = try await second.value
        XCTAssertEqual(output.artifacts.first?.relativePath,
                       "VNCArtifacts/unbound.png")
    }

    func testActualOwnedRootYieldsVerifiedPNGAndJPEGProviderImageData() async throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        let mailbox = mailbox(box, registry: registry)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5, tools: [
            makeEntry(name: "alpha.screen", schema: labelSchema),
        ]), 0)

        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )!
        // Real 2x2 JPEG (not a PNG renamed): the Full screenshot backend may
        // emit either PNG or JPEG and the closed wire accepts both.
        let jpeg = Data(base64Encoded:
            "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDk6KKK8I/Vj//Z"
        )!
        let directory = artifactRoot.appendingPathComponent(
            "VNCArtifacts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("real.png"))
        try jpeg.write(to: directory.appendingPathComponent("real.jpg"))

        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://example.invalid")!)
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "model-a",
            displayName: "Model A",
            limits: ModelLimits(contextTokens: 1024, maxOutputTokens: 256))
        let runtime = FloeAgentRuntime(
            configuration: .init(provider: provider, model: model),
            adapter: SilentProviderAdapter(),
            policy: TaskFullAccessPolicy(),
            executor: NoopToolExecutor(),
            artifactRootURL: artifactRoot)

        let screenContext = context(origin: mainOrigin(tool: "alpha.screen"))
        for (path, mime, bytes) in [
            ("VNCArtifacts/real.png", "image/png", png),
            ("VNCArtifacts/real.jpg", "image/jpeg", jpeg),
        ] {
            let task = Task {
                try await mailbox.execute(
                    toolName: "alpha.screen",
                    argumentsJSON: Data(#"{"label":"synthetic"}"#.utf8),
                    context: screenContext)
            }
            let claim = await waitForClaim(mailbox)
            XCTAssertGreaterThan(claim, 0)
            XCTAssertEqual(mailbox.complete(
                claim: claim, status: 0,
                value: resultData(artifact: artifactJSON(
                    relativePath: path, mimeType: mime, data: bytes))), 0)
            let output = try await task.value
            let delivered = try XCTUnwrap(output.artifacts.first)
            XCTAssertEqual(delivered.relativePath, path)
            XCTAssertEqual(delivered.sha256, FloeDigest.sha256Hex(bytes))

            let candidate = await runtime.providerImageEvidenceForDispatch(delivered)
            let part = try XCTUnwrap(candidate)
            guard case .imageData(let deliveredMIME, let base64) = part else {
                XCTFail("verified \(mime) must become provider imageData")
                return
            }
            XCTAssertEqual(deliveredMIME, mime)
            XCTAssertEqual(Data(base64Encoded: base64), bytes)
        }
    }

    func testInjectedOwnedRootNeverFallsBackToLegacyFoundationRoot() throws {
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )!
        let legacyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("G08LegacyRoot-\(UUID().uuidString)/FloeAgent",
                                    isDirectory: true)
        let legacyDirectory = legacyRoot.appendingPathComponent(
            "VNCArtifacts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(
                at: legacyRoot.deletingLastPathComponent())
        }
        try png.write(to: legacyDirectory.appendingPathComponent("legacy.png"))
        let artifact = ToolArtifactReference(
            id: UUID(),
            relativePath: "VNCArtifacts/legacy.png",
            mimeType: "image/png",
            byteCount: png.count,
            sha256: FloeDigest.sha256Hex(png))

        XCTAssertNil(
            FloeAgentRuntime.providerImageEvidence(
                artifact, artifactRootURL: artifactRoot),
            "bytes under a different/legacy root must never satisfy the owned root")

        let ownedDirectory = artifactRoot.appendingPathComponent(
            "VNCArtifacts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: ownedDirectory, withIntermediateDirectories: true)
        try png.write(to: ownedDirectory.appendingPathComponent("legacy.png"))
        let ownedEvidence = FloeAgentRuntime.providerImageEvidence(
            artifact, artifactRootURL: artifactRoot)
        guard case .imageData(let mime, _)? = ownedEvidence else {
            XCTFail("the same relative path under the actual owned root must verify")
            return
        }
        XCTAssertEqual(mime, "image/png")
    }

    func testArtifactRootBindingRequiresLiveEpochAndFencesOnRetire() throws {
        let box = EpochBox(5)
        let mailbox = PlatformToolHostMailbox(currentEpoch: { box.current })
        XCTAssertFalse(mailbox.bindArtifactRoot(
            ownedRootPath: "/tmp/../tmp/not-owned", epoch: 5),
            "a non-normalized root is refused")
        XCTAssertFalse(mailbox.bindArtifactRoot(
            ownedRootPath: ownedRoot.path, epoch: 4),
            "an epoch that is not the live root epoch is refused")
        XCTAssertNil(mailbox.artifactRootPathForTrustedHost())

        XCTAssertTrue(mailbox.bindArtifactRoot(
            ownedRootPath: ownedRoot.path, epoch: 5))
        let firstPath = URL(fileURLWithPath: artifactRoot.path)
            .standardizedFileURL.path
        XCTAssertEqual(mailbox.artifactRootPathForTrustedHost(), firstPath)
        XCTAssertTrue(mailbox.bindArtifactRoot(
            ownedRootPath: ownedRoot.path, epoch: 5),
            "an identical same-epoch rebind is idempotent")

        let otherRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("G08OtherRoot-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: otherRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        XCTAssertFalse(mailbox.bindArtifactRoot(
            ownedRootPath: otherRoot.path, epoch: 5),
            "a different root at the same epoch is a real conflict")

        box.set(6)
        XCTAssertNil(mailbox.artifactRootPathForTrustedHost(),
                     "an epoch change fences the getter before any rebind")
        XCTAssertTrue(mailbox.bindArtifactRoot(
            ownedRootPath: otherRoot.path, epoch: 6))
        let otherPath = otherRoot.appendingPathComponent("FloeAgent")
            .standardizedFileURL.path
        XCTAssertEqual(mailbox.artifactRootPathForTrustedHost(), otherPath)

        mailbox.retireArtifactRoot(epoch: 6)
        XCTAssertNil(mailbox.artifactRootPathForTrustedHost())
        XCTAssertFalse(mailbox.bindArtifactRoot(
            ownedRootPath: otherRoot.path, epoch: 6),
            "a retired epoch can never be rebound")
        XCTAssertFalse(mailbox.bindArtifactRoot(
            ownedRootPath: ownedRoot.path, epoch: 5),
            "an older epoch can never resurrect the retired root")
    }

    // MARK: - Same-epoch availability

    func testAvailabilityIsSameEpochSubsetAndFailsClosedByDefault() throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        let mailbox = mailbox(box, registry: registry)
        let tools = [makeEntry(name: "alpha.one"),
                     makeEntry(name: "beta.two")]
        XCTAssertEqual(mailbox.bind(
            epoch: 5, catalogJSON: catalogData(tools)), 0)
        XCTAssertFalse(mailbox.isAvailable,
                       "bind must not make capabilities discoverable")
        XCTAssertFalse(mailbox.isToolAvailable(named: "alpha.one"))
        XCTAssertEqual(mailbox.availableToolNames(), [])
        let unpublished = json(mailbox.readinessJSON())
        XCTAssertEqual(unpublished["reason"] as? String,
                       "availabilityUnpublished")

        // Wrong/stale epochs are fenced, never retargeted.
        XCTAssertEqual(mailbox.setAvailability(
            epoch: 4, namesJSON: availabilityData(["alpha.one"])), -102)
        XCTAssertEqual(mailbox.setAvailability(
            epoch: 6, namesJSON: availabilityData(["alpha.one"])), -102)
        // Unknown, duplicate and malformed/oversized subsets are refused
        // atomically and leave the previous state untouched.
        XCTAssertEqual(mailbox.setAvailability(
            epoch: 5,
            namesJSON: availabilityData(["alpha.one", "ghost.tool"])), -108)
        XCTAssertEqual(mailbox.setAvailability(
            epoch: 5,
            namesJSON: availabilityData(["alpha.one", "alpha.one"])), -108)
        XCTAssertEqual(mailbox.setAvailability(
            epoch: 5, namesJSON: Data(#"{"names":["alpha.one"]}"#.utf8)), -108)
        XCTAssertEqual(mailbox.setAvailability(
            epoch: 5,
            namesJSON: Data(repeating: 0x20,
                            count: PlatformToolHostLimits.maximumAvailabilityBytes + 1)),
            -107)
        XCTAssertFalse(mailbox.isToolAvailable(named: "alpha.one"))

        XCTAssertEqual(mailbox.setAvailability(
            epoch: 5,
            namesJSON: availabilityData(["alpha.one", "beta.two"])), 0)
        let descriptorBefore = try XCTUnwrap(
            registry.descriptor(named: "alpha.one"))

        // Same epoch, different subset: only discoverability changes.
        XCTAssertEqual(mailbox.setAvailability(
            epoch: 5, namesJSON: availabilityData(["beta.two"])), 0)
        XCTAssertTrue(mailbox.isAvailable)
        XCTAssertFalse(mailbox.isToolAvailable(named: "alpha.one"))
        XCTAssertTrue(mailbox.isToolAvailable(named: "beta.two"))
        XCTAssertEqual(mailbox.availableToolNames(), ["beta.two"])
        XCTAssertNil(registry.descriptor(named: "alpha.one"),
                     "a disabled name must not be advertised")

        XCTAssertEqual(mailbox.setAvailability(
            epoch: 5, namesJSON: availabilityData(["alpha.one"])), 0)
        XCTAssertTrue(mailbox.isToolAvailable(named: "alpha.one"))
        XCTAssertFalse(mailbox.isToolAvailable(named: "beta.two"))
        let descriptorAfter = try XCTUnwrap(
            registry.descriptor(named: "alpha.one"))
        XCTAssertEqual(descriptorAfter.name, descriptorBefore.name)
        XCTAssertEqual(descriptorAfter.effect, descriptorBefore.effect)
        XCTAssertEqual(descriptorAfter.parametersJSON,
                       descriptorBefore.parametersJSON)
        XCTAssertEqual(descriptorAfter.riskLabels, descriptorBefore.riskLabels)
        XCTAssertEqual(mailbox.installedToolNames(),
                       ["alpha.one", "beta.two"])

        // An explicit empty publish is valid and keeps the epoch ready but
        // with zero discoverable capabilities.
        XCTAssertEqual(mailbox.setAvailability(
            epoch: 5, namesJSON: availabilityData([])), 0)
        XCTAssertFalse(mailbox.isToolAvailable(named: "alpha.one"))
        let empty = json(mailbox.readinessJSON())
        XCTAssertEqual(empty["reason"] as? String, "ready")
        XCTAssertEqual(empty["availableNames"] as? [String], [])
        XCTAssertEqual(empty["availabilityPublished"] as? Bool, true)
    }

    func testDisableFencesQueuedTicketWhileClaimedTicketStillSettles() async throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        let mailbox = mailbox(box, registry: registry)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5, tools: [
            makeEntry(name: "alpha.one", schema: labelSchema),
            makeEntry(name: "beta.two", schema: labelSchema),
        ]), 0)

        let alphaContext = context(origin: mainOrigin(tool: "alpha.one"))
        let claimed = Task {
            try await mailbox.execute(
                toolName: "alpha.one",
                argumentsJSON: Data(#"{"label":"synthetic"}"#.utf8),
                context: alphaContext)
        }
        let claim = await waitForClaim(mailbox)
        XCTAssertGreaterThan(claim, 0)

        let betaContext = context(origin: mainOrigin(tool: "beta.two"))
        let queued = Task {
            try await mailbox.execute(
                toolName: "beta.two",
                argumentsJSON: Data(#"{"label":"synthetic"}"#.utf8),
                context: betaContext)
        }
        for _ in 0..<100 {
            let stats = json(mailbox.statsJSON())
            if (stats["queued"] as? Int ?? 0) > 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        // Disable BOTH in the SAME epoch. The never-claimed ticket is fenced;
        // the claimed host operation keeps its original settlement authority.
        XCTAssertEqual(mailbox.setAvailability(
            epoch: 5, namesJSON: availabilityData([])), 0)
        do {
            _ = try await queued.value
            XCTFail("a disabled queued ticket must never start")
        } catch let error as FloeError {
            XCTAssertEqual(error, .invalidConfiguration(
                "Phone and system tools are unavailable for the current runtime generation"))
        }
        XCTAssertEqual(mailbox.isLive(claim: claim), 1)
        XCTAssertEqual(mailbox.complete(
            claim: claim, status: 0, value: resultData()), 0,
            "in-flight host work still settles its original claim")
        _ = try await claimed.value

        do {
            _ = try await mailbox.execute(
                toolName: "alpha.one",
                argumentsJSON: Data(#"{"label":"synthetic"}"#.utf8),
                context: context(origin: mainOrigin(tool: "alpha.one")))
            XCTFail("a disabled name must refuse before any ticket")
        } catch let error as FloeError {
            XCTAssertEqual(error, .invalidConfiguration(
                "Phone and system tools are unavailable for the current runtime generation"))
        }
        XCTAssertEqual(mailbox.nextClaim(timeoutMillis: 0), 0)
    }

    // MARK: - Generation / leakage

    func testRebindFencesClaimedTicketAndRemovesItsName() async throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        let mailbox = mailbox(box, registry: registry)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5, tools: [
            makeEntry(name: "alpha.read", schema: labelSchema),
        ]), 0)
        let args = Data(#"{"label":"synthetic"}"#.utf8)
        let toolContext = context(origin: mainOrigin(tool: "alpha.read"))
        let task = Task {
            try await mailbox.execute(
                toolName: "alpha.read", argumentsJSON: args,
                context: toolContext)
        }
        let claim = await waitForClaim(mailbox)
        XCTAssertGreaterThan(claim, 0)

        box.set(6)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 6, tools: [
            makeEntry(name: "beta.read"),
        ]), 0)
        XCTAssertNil(registry.descriptor(named: "alpha.read"))
        do {
            _ = try await task.value
            XCTFail("a rebind must fence the old generation")
        } catch let error as FloeError {
            XCTAssertEqual(error, .invalidConfiguration(
                "Phone and system tools are unavailable for the current runtime generation"))
        }
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0,
                                        value: resultData()), -101)
        XCTAssertEqual(mailbox.nextClaim(timeoutMillis: 0), 0,
                       "no stale ticket may remain claimable")
    }

    func testStatsAndReadinessNeverExposeArguments() async throws {
        let box = EpochBox(5)
        let registry = ToolRunnerRegistry()
        let mailbox = mailbox(box, registry: registry)
        XCTAssertEqual(bindAndExpose(mailbox, epoch: 5, tools: [
            makeEntry(name: "alpha.read", schema: labelSchema),
        ]), 0)
        let marker = "sensitive-marker-value"
        let args = Data(#"{"label":"sensitive-marker-value"}"#.utf8)
        let toolContext = context(origin: mainOrigin(tool: "alpha.read"))
        let task = Task {
            try await mailbox.execute(
                toolName: "alpha.read", argumentsJSON: args,
                context: toolContext)
        }
        let claim = await waitForClaim(mailbox)
        XCTAssertGreaterThan(claim, 0)

        let stats = mailbox.statsJSON()
        let readiness = mailbox.readinessJSON()
        XCTAssertFalse(stats.contains(marker))
        XCTAssertFalse(readiness.contains(marker))
        XCTAssertTrue(readiness.contains("alpha.read"))
        let parsed = json(stats)
        XCTAssertEqual(parsed["live"] as? Int, 1)

        mailbox.close(epoch: 5)
        do {
            _ = try await task.value
            XCTFail("close must fence the claimed ticket")
        } catch {
            // Expected typed failure.
        }
    }
}
