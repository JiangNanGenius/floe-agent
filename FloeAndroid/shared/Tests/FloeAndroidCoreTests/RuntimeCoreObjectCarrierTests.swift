// SPDX-License-Identifier: MPL-2.0
//
// G02 ordinary BASE — Core object-carrier qualification (Main decision
// MAIN_CORE_OBJECT_CARRIER_DECISION_20261020).
//
// Scope proven HERE, on the REAL default Bootstrap generation (one accepted
// DatabaseManager, the full-owner ordinary composition installed) through the
// ACTUAL `AndroidBridge.exchange` canonical Bridge V3 ingress:
//
//  * `config.providers.list` / `config.models.list` empty pages complete as
//    the frozen OBJECT carrier `{"rows":[]}` — the former bare LIST document
//    was refused by the OBJECT-only carrier (encodedBytes=Int.max ->
//    carrier=payloadTooLarge) even though the page was 2 bytes;
//  * a fresh `conversation.get` completes and carries EXPLICIT JSON null for
//    `archivedAt` (the boxed Optional.none previously settled
//    frameBudgetExceeded), while the archived contrast carries the exact
//    string; pending-input/run-summary nullable members behave the same;
//  * exact numeric classification at the actual carrier boundary: JSON and
//    constructed 0/1 stay integers (never Bool), CFBoolean stays Bool, signed
//    and unsigned integers beyond 2^53 keep their digits, decimals stay
//    exact, non-finite numbers still refuse typed, and unknown Foundation
//    types still refuse instead of being stringified;
//  * the frozen carrier itself is NOT widened: a raw top-level ARRAY is still
//    an illegal document and a true oversized rows object is still refused,
//    so the binder wrapper cannot smuggle anything past the byte budgets.
import XCTest
import Foundation
import FloeCore
import FloeModels
@testable import FloeAndroidCore

final class RuntimeCoreObjectCarrierTests: XCTestCase {

    private var tracked: [Boot] = []

    // MARK: - Fixtures

    private final class Boot {
        let epoch: UInt64
        let token: String
        let rootPath: String
        var retired = false
        init(epoch: UInt64, token: String, rootPath: String) {
            self.epoch = epoch
            self.token = token
            self.rootPath = rootPath
        }
    }

    /// Monotonic epoch that dominates BOTH the Date-millisecond and the
    /// DispatchTime-uptime bases other fixtures use (same discipline as the
    /// G02 composition suite: a lower epoch is refused as `epochNotNewer`).
    private enum FixtureEpoch {
        nonisolated(unsafe) static var lock = NSLock()
        nonisolated(unsafe) static var value: UInt64 =
            UInt64(DispatchTime.now().uptimeNanoseconds)
        static func allocate() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            let now = UInt64(DispatchTime.now().uptimeNanoseconds)
            value = Swift.max(value &+ 1, now)
            return value
        }
    }

    override func tearDown() async throws {
        for boot in tracked.reversed() where !boot.retired {
            await shutdownAndAwaitClosed(boot)
        }
        tracked.removeAll()
        G02RuntimeComposition.shared.resetForTesting()
        AndroidRuntimeBootstrap.resetForTesting()
        try await super.tearDown()
    }

    /// Boots one REAL generation over a synthetic trusted root and returns
    /// ONLY after the ACTUAL accepted bootstrap terminal settled AND the
    /// same-owner ordinary graph installed (never storeReady alone).
    @discardableResult
    private func bootInstalledGeneration(
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> Boot {
        let root = NSTemporaryDirectory()
            .appending("g02-carrier-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root,
                                                withIntermediateDirectories: true)
        let token = String((0..<16).map { _ in "0123456789abcdef".randomElement()! })
        let epoch = FixtureEpoch.allocate()
        guard case .accepted(let receipt) = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: token, epoch: epoch) else {
            XCTFail("bootstrap not accepted (root preserved: \(root))",
                    file: file, line: line)
            throw TestError.bootstrap
        }
        let boot = Boot(epoch: epoch, token: token, rootPath: root)
        tracked.append(boot)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard let gen = AndroidRuntimeBootstrap.currentGenerationForTesting(),
                  gen.epoch == epoch else {
                XCTFail("generation vanished before its accepted terminal: "
                            + AndroidRuntimeBootstrap.statusSnapshotJSON(),
                        file: file, line: line)
                throw TestError.bootstrap
            }
            // `poll` is a NON-ADVANCING peek; later polls still see the stream.
            guard case .page(let effects, _, _, _) =
                    gen.effects.poll(receipt: receipt, afterSequence: 0),
                  let terminal = effects.first(where: { $0.isTerminal }) else {
                try await Task.sleep(nanoseconds: 10_000_000)
                continue
            }
            guard terminal.kind == .accepted else {
                XCTFail("bootstrap terminal not accepted: \(terminal.kind)",
                        file: file, line: line)
                throw TestError.bootstrap
            }
            guard let installed = G02RuntimeComposition.shared.installedComposition,
                  installed.epoch == epoch else {
                try await Task.sleep(nanoseconds: 10_000_000)
                continue
            }
            return boot
        }
        XCTFail("bootstrap terminal did not settle", file: file, line: line)
        throw TestError.bootstrap
    }

    private func shutdownAndAwaitClosed(_ boot: Boot) async {
        guard !boot.retired else { return }
        boot.retired = true
        switch AndroidRuntimeBootstrap.shutdown(expectedEpoch: boot.epoch,
                                                ownerToken: boot.token) {
        case .accepted, .idempotent:
            break
        case .rejected(let code):
            if code == .notInstalled,
               AndroidRuntimeBootstrap.currentGenerationForTesting() == nil {
                return
            }
            XCTFail("shutdown not accepted for epoch \(boot.epoch): \(code.rawValue)")
            return
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if AndroidRuntimeBootstrap.currentGenerationForTesting() == nil {
                let status = AndroidRuntimeBootstrap.statusSnapshotJSON()
                if status.contains("\"ownedStorePhase\":\"closed\"")
                    || !status.contains("\"generation\"") {
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("generation did not reach closed/gone for epoch \(boot.epoch)")
    }

    private enum TestError: Error {
        case bootstrap
    }

    // MARK: - Canonical V3 ingress helpers

    private func exchange(_ request: String) -> [String: Any]? {
        let data = AndroidBridge.exchange(Data(request.utf8))
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object,
                                               options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// The frozen outer v3 `command.submit` request the REAL App emits
    /// (e20 canonical shape): version/operation/requestID + inner envelope
    /// with a STRING scope, configuration label OR owner, command,
    /// stateful/createIntent/revision, payload and correlationID.
    private func submitEnvelope(
        correlation: String, command: String, scope: String,
        configurationScope: String? = nil, owner: [String: String]? = nil,
        revision: (resourceID: String, version: String)? = nil,
        createIntent: Bool = false, stateful: Bool = false,
        payload: [String: Any]? = nil
    ) -> String {
        var envelope: [String: Any] = [
            "schema": BridgeV3.commandSchema,
            "scope": scope,
            "command": command,
            "stateful": stateful,
            "correlationID": correlation,
        ]
        if let configurationScope {
            envelope["configurationScope"] = configurationScope
        }
        if let owner { envelope["owner"] = owner }
        if let revision {
            envelope["revision"] = ["resourceID": revision.resourceID,
                                    "version": revision.version]
        }
        if createIntent { envelope["createIntent"] = true }
        if let payload { envelope["payload"] = payload }
        return json([
            "version": BridgeV3.version,
            "operation": BridgeV3.Operation.submit.rawValue,
            "requestID": correlation,
            "envelope": envelope,
        ])
    }

    private func effectEnvelope(correlation: String, receipt: String,
                                sequence: Int) -> String {
        json([
            "version": BridgeV3.version,
            "operation": BridgeV3.Operation.effectPoll.rawValue,
            "requestID": correlation,
            "envelope": [
                "schema": BridgeV3.effectSchema,
                "scope": BridgeV3.Scope.applicationConfiguration.rawValue,
                "configurationScope": "system",
                "command": BridgeV3.Operation.effectPoll.rawValue,
                "stateful": false,
                "correlationID": correlation,
                "effect": ["operationReceiptID": receipt, "sequence": sequence],
            ],
        ])
    }

    /// Submits one canonical envelope and returns the minted receipt.
    private func submit(_ request: String,
                        file: StaticString = #filePath, line: UInt = #line)
        throws -> String {
        let answer = try XCTUnwrap(exchange(request), file: file, line: line)
        XCTAssertEqual(answer["ok"] as? Bool, true, "\(answer)", file: file, line: line)
        XCTAssertEqual(answer["queued"] as? Bool, true, "\(answer)", file: file, line: line)
        let receipt = try XCTUnwrap(answer["operationReceiptID"] as? String,
                                    "\(answer)", file: file, line: line)
        XCTAssertTrue(RuntimeOperationReceipt.isValid(receipt), receipt,
                      file: file, line: line)
        return receipt
    }

    /// Polls the REAL native effect route until the typed terminal settles.
    private func pollUntilTerminal(receipt: String,
                                   timeout: TimeInterval = 20,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while Date() < deadline {
            attempt += 1
            let page = try XCTUnwrap(
                exchange(effectEnvelope(correlation: "carrier-poll-\(attempt)",
                                        receipt: receipt, sequence: 0)),
                "effect.poll unavailable", file: file, line: line)
            if let effects = page["effects"] as? [[String: Any]],
               let terminal = effects.last(where: { item in
                   ["accepted", "failed", "rejected", "cancelled",
                    "replaced", "closed"].contains(item["kind"] as? String ?? "")
               }) {
                return terminal
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("no terminal settled for \(receipt)", file: file, line: line)
        throw TestError.bootstrap
    }

    private func assertAccepted(_ terminal: [String: Any],
                                _ label: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(terminal["kind"] as? String, "accepted",
                       "\(label): \(terminal)", file: file, line: line)
        if let detail = terminal["detail"] as? [[String: Any]] {
            XCTAssertFalse(detail.contains { ($0["key"] as? String) == "carrier" },
                           "\(label) carried a refusal detail: \(terminal)",
                           file: file, line: line)
        }
    }

    // MARK: - 1. Empty provider/model pages are OBJECT rows through real V3

    func testEmptyProviderAndModelListsDeliverRowsObjectThroughActualV3Ingress() async throws {
        try await bootInstalledGeneration()

        let providersReceipt = try submit(submitEnvelope(
            correlation: "carrier-providers-1",
            command: "config.providers.list",
            scope: BridgeV3.Scope.applicationConfiguration.rawValue,
            configurationScope: "providers",
            payload: ["operation": "snapshot"]))
        let providersTerminal = try await pollUntilTerminal(receipt: providersReceipt)
        assertAccepted(providersTerminal, "config.providers.list")
        let providersValue = try XCTUnwrap(providersTerminal["value"] as? [String: Any],
                                           "\(providersTerminal)")
        let providerRows = try XCTUnwrap(providersValue["rows"] as? [Any],
                                         "\(providersValue)")
        XCTAssertEqual(providerRows.count, 0)
        let providersBytes = try XCTUnwrap(providersTerminal["valueBytes"] as? Int)
        // The EMPTY page is `{"rows":[]}` — ten UTF-8 bytes, far below the
        // 47,616 item bound. The former carrier refusal was an OBJECT-shape
        // refusal mislabeled payloadTooLarge, never a size refusal.
        let canonical = try XCTUnwrap(
            FacadeFrameBudget.canonicalSerializedBytes(providersValue))
        XCTAssertEqual(providersBytes, canonical)
        XCTAssertEqual(canonical, 11, "{\"rows\":[]} must be exactly 11 UTF-8 bytes")

        let modelsReceipt = try submit(submitEnvelope(
            correlation: "carrier-models-1",
            command: "config.models.list",
            scope: BridgeV3.Scope.applicationConfiguration.rawValue,
            configurationScope: "models"))
        let modelsTerminal = try await pollUntilTerminal(receipt: modelsReceipt)
        assertAccepted(modelsTerminal, "config.models.list")
        let modelsValue = try XCTUnwrap(modelsTerminal["value"] as? [String: Any],
                                        "\(modelsTerminal)")
        XCTAssertEqual((modelsValue["rows"] as? [Any])?.count, 0)
    }

    // MARK: - 2. Fresh conversation.get: explicit null + archived contrast

    func testFreshConversationGetDeliversExplicitJsonNullAndArchivedContrast() async throws {
        try await bootInstalledGeneration()

        let createReceipt = try submit(submitEnvelope(
            correlation: "carrier-create-1",
            command: "conversation.create",
            scope: BridgeV3.Scope.launch.rawValue,
            createIntent: true, stateful: true,
            payload: ["title": "carrier-qa-fresh"]))
        let createTerminal = try await pollUntilTerminal(receipt: createReceipt)
        assertAccepted(createTerminal, "conversation.create")
        let created = try XCTUnwrap(createTerminal["value"] as? [String: Any],
                                    "\(createTerminal)")
        let conversationID = try XCTUnwrap(created["conversationID"] as? String)
        let resourceID = try XCTUnwrap(created["resourceID"] as? String)
        let createdRevision = try XCTUnwrap(created["revision"] as? String)
        XCTAssertNotNil(UUID(uuidString: conversationID))

        // FRESH (unarchived) get: previously settled frameBudgetExceeded with
        // an EMPTY detail because archivedAt boxed Optional.none.
        let freshReceipt = try submit(submitEnvelope(
            correlation: "carrier-get-fresh-1",
            command: "conversation.get",
            scope: BridgeV3.Scope.conversationLifecycle.rawValue,
            owner: ["taskID": conversationID]))
        let freshTerminal = try await pollUntilTerminal(receipt: freshReceipt)
        assertAccepted(freshTerminal, "conversation.get(fresh)")
        let fresh = try XCTUnwrap(freshTerminal["value"] as? [String: Any],
                                  "\(freshTerminal)")
        XCTAssertEqual(fresh["conversationID"] as? String, conversationID)
        XCTAssertTrue(fresh.keys.contains("archivedAt"),
                      "archivedAt member must be present (explicit null, not omitted)")
        XCTAssertTrue(fresh["archivedAt"] is NSNull,
                      "fresh conversation archivedAt must be JSON null: \(fresh)")
        XCTAssertEqual((fresh["runs"] as? [Any])?.count, 0)
        XCTAssertEqual((fresh["pendingInputs"] as? [Any])?.count, 0)
        XCTAssertEqual(fresh["messagesTotalCount"] as? Int, 0)
        XCTAssertEqual(fresh["runsTotalCount"] as? Int, 0)
        XCTAssertEqual(fresh["pendingInputsTotalCount"] as? Int, 0)
        // The terminal raw JSON really contains `null` (never "null", never
        // a vanished key): re-serialize the delivered object.
        let freshJSON = json(fresh)
        XCTAssertTrue(freshJSON.contains("\"archivedAt\":null"), freshJSON)

        // Archive, then the identical read carries the exact string.
        let archiveReceipt = try submit(submitEnvelope(
            correlation: "carrier-archive-1",
            command: "conversation.archive",
            scope: BridgeV3.Scope.conversationLifecycle.rawValue,
            owner: ["taskID": conversationID],
            revision: (resourceID, createdRevision),
            stateful: true,
            payload: ["archived": true]))
        let archiveTerminal = try await pollUntilTerminal(receipt: archiveReceipt)
        assertAccepted(archiveTerminal, "conversation.archive")

        let archivedReceipt = try submit(submitEnvelope(
            correlation: "carrier-get-archived-1",
            command: "conversation.get",
            scope: BridgeV3.Scope.conversationLifecycle.rawValue,
            owner: ["taskID": conversationID]))
        let archivedTerminal = try await pollUntilTerminal(receipt: archivedReceipt)
        assertAccepted(archivedTerminal, "conversation.get(archived)")
        let archived = try XCTUnwrap(archivedTerminal["value"] as? [String: Any],
                                     "\(archivedTerminal)")
        let archivedAt = try XCTUnwrap(archived["archivedAt"] as? String,
                                       "archived conversation must carry the exact string: \(archived)")
        XCTAssertFalse(archivedAt.isEmpty)
        XCTAssertNotEqual(archivedAt, "null")
    }

    // MARK: - 3. Nullable projections compose explicit JSON nulls

    func testNullableConversationProjectionsComposeExplicitJsonNulls() throws {
        let conversationID = UUID()
        let startedAt = "2026-10-20T00:00:00.000Z"
        let present = ConversationRunSummaryWire(
            runID: UUID(), state: "completed", startedAtRaw: startedAt,
            endedAtRaw: "2026-10-20T00:00:05.000Z", providerName: "provider-x",
            modelName: "model-y", conversationMode: "agent")
        let missing = ConversationRunSummaryWire(
            runID: UUID(), state: "running", startedAtRaw: startedAt,
            endedAtRaw: nil, providerName: nil, modelName: nil,
            conversationMode: nil)

        let missingResult = G02DomainBinder.completedWireObject(missing.wireObject)
        XCTAssertEqual(missingResult.kind, .accepted)
        guard case .object(let missingObject)? = missingResult.value else {
            return XCTFail("nullable run summary must compose an object")
        }
        for key in ["endedAt", "providerName", "modelName", "conversationMode"] {
            XCTAssertEqual(missingObject[key], .null,
                           "\(key) must be explicit null, not a boxed/omitted value")
        }
        XCTAssertEqual(missingObject["state"], .string("running"))

        let presentResult = G02DomainBinder.completedWireObject(present.wireObject)
        guard case .object(let presentObject)? = presentResult.value else {
            return XCTFail("present run summary must compose an object")
        }
        XCTAssertEqual(presentObject["endedAt"], .string("2026-10-20T00:00:05.000Z"))
        XCTAssertEqual(presentObject["providerName"], .string("provider-x"))
        XCTAssertEqual(presentObject["modelName"], .string("model-y"))
        XCTAssertEqual(presentObject["conversationMode"], .string("agent"))

        // Pending input: nil target run stays JSON null; present stays exact.
        let pendingMissing = PendingUserInputWire(input: PendingUserInput(
            conversationID: conversationID, targetRunID: nil,
            content: "queued while idle"))
        guard case .object(let pendingMissingObject)? =
                G02DomainBinder.completedWireObject(pendingMissing.wireObject).value
        else { return XCTFail("pending input must compose an object") }
        XCTAssertEqual(pendingMissingObject["targetRunID"], .null)
        let runID = UUID()
        let pendingPresent = PendingUserInputWire(input: PendingUserInput(
            conversationID: conversationID, targetRunID: runID,
            content: "steer target"))
        guard case .object(let pendingPresentObject)? =
                G02DomainBinder.completedWireObject(pendingPresent.wireObject).value
        else { return XCTFail("pending input must compose an object") }
        XCTAssertEqual(pendingPresentObject["targetRunID"], .string(runID.uuidString))

        // The FULL fresh snapshot (the exact failing device read shape):
        // nil archivedAt + runs/pending rows exercising every nullable.
        let reply = ConversationSessionReply(
            conversationID: conversationID,
            resourceID: "conversation.\(conversationID.uuidString)",
            revision: "sha256:carrier-fixture",
            title: "carrier-qa",
            createdAtRaw: startedAt, updatedAtRaw: startedAt,
            titleOrigin: "user",
            archivedAtRaw: nil,
            firstScreen: ConversationMessagePageReply(
                rows: [], earlierCursor: nil, hasEarlier: false,
                usesContentHandles: false),
            messagesTotalCount: 0,
            runs: [missing, present],
            runsTotalCount: 2, runsTruncated: false,
            pendingInputs: [pendingMissing],
            pendingInputsTotalCount: 1, pendingInputsTruncated: false,
            taskPolicy: TaskPolicy(conversationID: conversationID))
        let snapshotResult = G02DomainBinder.completedWireObject(reply.wireObject)
        XCTAssertEqual(snapshotResult.kind, .accepted,
                       "fresh snapshot must compose (was frameBudgetExceeded)")
        guard case .object(let snapshot)? = snapshotResult.value else {
            return XCTFail("snapshot must compose an object")
        }
        XCTAssertEqual(snapshot["archivedAt"] as? DesignJSONValue, DesignJSONValue.null)
        guard case .array(let runs)? = snapshot["runs"] else {
            return XCTFail("runs must stay an array")
        }
        XCTAssertEqual(runs.count, 2)
        guard case .object(let firstRun) = runs[0],
              case .object(let secondRun) = runs[1] else {
            return XCTFail("run summaries must stay objects")
        }
        XCTAssertEqual(firstRun["endedAt"] as? DesignJSONValue, DesignJSONValue.null)
        XCTAssertEqual(secondRun["endedAt"] as? DesignJSONValue,
                       DesignJSONValue.string("2026-10-20T00:00:05.000Z"))
        guard case .array(let pending)? = snapshot["pendingInputs"],
              case .object(let pendingRow) = pending[0] else {
            return XCTFail("pending inputs must stay objects")
        }
        XCTAssertEqual(pendingRow["targetRunID"] as? DesignJSONValue, DesignJSONValue.null)

        // Same class, other projection sites in the conversation lane.
        let searchRow = ConversationSearchRow(
            conversationID: conversationID, messageID: UUID(),
            workspaceID: nil, conversationTitle: "t", snippet: "s",
            createdAtRaw: startedAt)
        guard case .object(let searchObject)? =
                G02DomainBinder.completedWireObject(searchRow.wireObject).value
        else { return XCTFail("search row must compose an object") }
        XCTAssertEqual(searchObject["workspaceID"], .null)
        let messageRow = ConversationMessageRowWire(
            messageID: UUID(), role: "user", createdAtRaw: startedAt,
            runID: nil, content: nil, contentHandle: nil, totalBytes: 0,
            contentInlineComplete: false, partCount: 1)
        guard case .object(let messageObject)? =
                G02DomainBinder.completedWireObject(messageRow.wireObject).value
        else { return XCTFail("message row must compose an object") }
        XCTAssertEqual(messageObject["runID"], .null)

        // STRICT refusal is intact for genuinely unknown Foundation types —
        // the domain emits NSNull for absence; it never stringifies a
        // non-JSON value and never lets a boxed Optional through.
        XCTAssertNil(G02DomainBinder.designValue(Date()))
        XCTAssertNil(G02DomainBinder.designValue(UUID()))
        XCTAssertNil(G02DomainBinder.designValue(Optional<String>.none as Any))
        XCTAssertNil(G02DomainBinder.designValue(NSObject()))
    }

    // MARK: - 4. Exact numeric classification at the carrier boundary

    func testDesignValueNumericClassificationIsExactAtCarrierBoundary() throws {
        // JSON the router actually parses (JSONSerialization -> NSNumber).
        let raw = Data("""
        {"i1":1,"i0":0,"t":true,"f":false,
         "big":9007199254740993,"negBig":-9007199254740993,
         "u":18446744073709551615,"frac":1.5}
        """.utf8)
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let document = try XCTUnwrap(G02DomainBinder.designValue(parsed))
        guard case .object(let values) = document else {
            return XCTFail("parsed document must be an object")
        }
        // 0/1 MUST stay integers: `as? Bool` succeeds for them on this
        // Foundation, which is exactly the misclassification this repair
        // removed (checked before the NSNumber branch previously).
        XCTAssertEqual(values["i1"], .integer(1))
        XCTAssertEqual(values["i0"], .integer(0))
        XCTAssertEqual(values["t"], .bool(true))
        XCTAssertEqual(values["f"], .bool(false))
        // No double round trip beyond 2^53: digits must survive exactly.
        XCTAssertEqual(values["big"], .integer(9_007_199_254_740_993))
        XCTAssertEqual(values["negBig"], .integer(-9_007_199_254_740_993))
        XCTAssertEqual(values["u"], .unsigned(UInt64.max))
        guard case .number(let frac)? = values["frac"] else {
            // NSDecimalNumber / exact-decimal representations are fine too,
            // but never an integer.
            return XCTFail("1.5 must stay numeric: \(String(describing: values["frac"]))")
        }
        XCTAssertEqual(frac, 1.5)

        // Constructed numbers: narrow integers, booleans, native primitives.
        XCTAssertEqual(G02DomainBinder.designValue(NSNumber(value: Int8(1))), .integer(1))
        XCTAssertEqual(G02DomainBinder.designValue(NSNumber(value: Int8(0))), .integer(0))
        XCTAssertEqual(G02DomainBinder.designValue(NSNumber(value: UInt8(1))), .integer(1))
        XCTAssertEqual(G02DomainBinder.designValue(NSNumber(value: Int64.max)),
                       .integer(Int64.max))
        XCTAssertEqual(G02DomainBinder.designValue(NSNumber(value: UInt64.max)),
                       .unsigned(UInt64.max))
        XCTAssertEqual(G02DomainBinder.designValue(NSNumber(value: true)), .bool(true))
        XCTAssertEqual(G02DomainBinder.designValue(NSNumber(value: false)), .bool(false))
        XCTAssertEqual(G02DomainBinder.designValue(true as Any), .bool(true))
        XCTAssertEqual(G02DomainBinder.designValue(false as Any), .bool(false))
        XCTAssertEqual(G02DomainBinder.designValue(42 as Any), .integer(42))
        XCTAssertEqual(G02DomainBinder.designValue(Int64(Int64.max) as Any),
                       .integer(Int64.max))
        XCTAssertEqual(G02DomainBinder.designValue(Double(1.5) as Any), .number(1.5))
        XCTAssertEqual(G02DomainBinder.designValue(NSDecimalNumber(decimal: Decimal(string: "1.25")!)),
                       .decimal(Decimal(string: "1.25")!))

        // Reuse check: the canonical classifier agrees on every numeric/bool
        // case above (same branch order, proven on-device by
        // QualificationSeam); G02 keeps its STRICTER unknown-value refusal.
        let samples: [Any] = [NSNumber(value: Int8(1)), NSNumber(value: Int8(0)),
                              NSNumber(value: UInt64.max), NSNumber(value: true),
                              NSNumber(value: false), NSNumber(value: 1.5), 42 as Any]
        for sample in samples {
            XCTAssertEqual(G02DomainBinder.designValue(sample),
                           DesignJSONValue.from(foundation: sample),
                           "canonical classification divergence for \(sample)")
        }
        // Unknown object: canonical maps to `.null` for canvas preservation,
        // while the G02 strict validator keeps the typed refusal.
        XCTAssertEqual(DesignJSONValue.from(foundation: Date()), .null)
        XCTAssertNil(G02DomainBinder.designValue(Date()))

        // Lossless digit encoding: the exact integers serialize back to their
        // original decimal text (a Double round trip would print 9007199254740992).
        let roundTrip = try XCTUnwrap(
            FacadeFrameBudget.canonicalSerializedBytes(
                RuntimeEffectDocumentTestProjection.foundationObject(
                    .object(["big": values["big"]!, "u": values["u"]!]))))
        XCTAssertGreaterThan(roundTrip, 0)
        let encoded = try JSONSerialization.data(
            withJSONObject: RuntimeEffectDocumentTestProjection.foundationObject(
                .object(["big": values["big"]!, "u": values["u"]!])),
            options: [.sortedKeys])
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("9007199254740993"), text)
        XCTAssertTrue(text.contains("18446744073709551615"), text)

        // Non-finite numbers still refuse TYPED at the carrier (never a
        // silently truncated document, never a crash).
        let nan = try XCTUnwrap(G02DomainBinder.designValue(
            ["value": NSNumber(value: Double.nan)] as [String: Any]))
        guard case .object(let nanObject) = nan,
              case .number(let nanValue)? = nanObject["value"] else {
            return XCTFail("NaN must be carried as a number for the refusal check")
        }
        XCTAssertTrue(nanValue.isNaN)
        let item = RuntimeEffectItem(sequence: 1, kind: .accepted, code: nil,
                                     detail: nil, value: nan)
        XCTAssertEqual(item.encodedBytes, Int.max,
                       "non-finite carrier must stay un-appendable")
        let pump = FacadeEffectPump(generation: 1)
        let receipt = try XCTUnwrap(pump.register(correlationID: "carrier-nan"))
        guard case .refused(.payloadTooLarge) =
                pump.append(receipt: receipt, kind: .accepted, code: nil,
                            detail: nil, page: nil, value: nan) else {
            return XCTFail("non-finite value must be refused typed")
        }
    }

    // MARK: - 5. Frozen carrier and byte budgets stay intact

    func testRowsWrapperCannotBypassCarrierOrByteBudgets() throws {
        // The carrier itself is NOT widened: a top-level ARRAY (or any
        // scalar) is still an illegal carrier document.
        let arrayItem = RuntimeEffectItem(sequence: 1, kind: .accepted, code: nil,
                                          detail: nil, value: .array([.integer(1)]))
        XCTAssertEqual(arrayItem.encodedBytes, Int.max)
        let scalarItem = RuntimeEffectItem(sequence: 1, kind: .accepted, code: nil,
                                           detail: nil, value: .string("bare"))
        XCTAssertEqual(scalarItem.encodedBytes, Int.max)
        XCTAssertTrue(RuntimeEffectDocumentProjection.isValidObject(
            .object(["rows": .array([])])))
        XCTAssertFalse(RuntimeEffectDocumentProjection.isValidObject(.array([])))

        // A genuinely oversized LIST is still refused (the {rows} wrapper is
        // a shape composition, never a budget bypass).
        let huge = (0..<40).map { index in
            DesignJSONValue.object([
                "id": .string("row-\(index)"),
                "content": .string(String(repeating: "中", count: 800)),
            ])
        }
        let wrapped = G02DomainBinder.completedValue(.array(huge))
        XCTAssertEqual(wrapped.kind, .accepted)
        guard case .object(let wrappedObject)? = wrapped.value,
              case .array(let wrappedRows)? = wrappedObject["rows"] else {
            return XCTFail("oversized list must still compose the rows object")
        }
        XCTAssertEqual(wrappedRows.count, 40)
        let pump = FacadeEffectPump(generation: 1)
        let receipt = try XCTUnwrap(pump.register(correlationID: "carrier-huge"))
        guard case .refused(.payloadTooLarge(let encoded, let available)) =
                pump.append(receipt: receipt, kind: .accepted, code: nil,
                            detail: nil, page: nil, value: wrapped.value) else {
            return XCTFail("true oversized rows object must be refused")
        }
        XCTAssertGreaterThan(encoded, available)
        XCTAssertLessThanOrEqual(available, FacadeFrameBudget.pageBudgetBytes)
        XCTAssertFalse(pump.isTerminal(receipt: receipt))

        // A small list inside the wrapper stays a real, measured carrier.
        let small = DesignJSONValue.array([
            .object(["id": .string("a"), "syncRevision": .integer(1),
                     "isEnabled": .bool(true), "secret": .object(["configured": .bool(false)])]),
        ])
        let composed = G02DomainBinder.completedValue(small)
        let item = RuntimeEffectItem(sequence: 1, kind: .accepted, code: nil,
                                     detail: nil, value: try XCTUnwrap(composed.value))
        XCTAssertNotEqual(item.encodedBytes, Int.max)
        XCTAssertGreaterThan(item.encodedBytes, 0)
        XCTAssertEqual(item.valueBytes,
                       FacadeFrameBudget.canonicalSerializedBytes(
                           RuntimeEffectDocumentTestProjection.foundationObject(
                               try XCTUnwrap(composed.value))))
    }

    // MARK: - 6. Real delete lifecycle outcome after the get repair

    /// The parent report claimed the trusted deletion lifecycle is
    /// unregistered; Main's correction requires reaching the REAL delete and
    /// observing the actual outcome instead of coding around that claim.
    /// This test performs the real V3 `conversation.delete` with the CURRENT
    /// post-archive revision and records the typed result:
    ///  * accepted  -> the snapshot/list must no longer carry the row;
    ///  * refused   -> the row stays readable and the exact typed code is
    ///                 recorded (no SQL direct delete, no guard bypass).
    func testConversationDeleteReachesRealOutcomeAfterGetRepair() async throws {
        try await bootInstalledGeneration()

        func createConversation(_ title: String) async throws -> (String, String, String) {
            let receipt = try submit(submitEnvelope(
                correlation: "delete-create-\(UUID().uuidString)",
                command: "conversation.create",
                scope: BridgeV3.Scope.launch.rawValue,
                createIntent: true, stateful: true,
                payload: ["title": title]))
            let terminal = try await pollUntilTerminal(receipt: receipt)
            assertAccepted(terminal, "conversation.create(\(title))")
            let value = try XCTUnwrap(terminal["value"] as? [String: Any])
            return (try XCTUnwrap(value["conversationID"] as? String),
                    try XCTUnwrap(value["resourceID"] as? String),
                    try XCTUnwrap(value["revision"] as? String))
        }

        let (conversationID, resourceID, createdRevision) =
            try await createConversation("carrier-delete-qa")

        // Fresh get first (the repaired read), then archive to force a new
        // revision, then re-read the CURRENT revision exactly as an operator
        // would before deleting.
        let freshReceipt = try submit(submitEnvelope(
            correlation: "delete-get-\(UUID().uuidString)",
            command: "conversation.get",
            scope: BridgeV3.Scope.conversationLifecycle.rawValue,
            owner: ["taskID": conversationID]))
        let freshTerminal = try await pollUntilTerminal(receipt: freshReceipt)
        let fresh = try XCTUnwrap(freshTerminal["value"] as? [String: Any])
        XCTAssertTrue(fresh["archivedAt"] is NSNull)

        let archiveReceipt = try submit(submitEnvelope(
            correlation: "delete-archive-\(UUID().uuidString)",
            command: "conversation.archive",
            scope: BridgeV3.Scope.conversationLifecycle.rawValue,
            owner: ["taskID": conversationID],
            revision: (resourceID, createdRevision), stateful: true,
            payload: ["archived": true]))
        assertAccepted(try await pollUntilTerminal(receipt: archiveReceipt),
                       "conversation.archive")

        let currentReceipt = try submit(submitEnvelope(
            correlation: "delete-get-current-\(UUID().uuidString)",
            command: "conversation.get",
            scope: BridgeV3.Scope.conversationLifecycle.rawValue,
            owner: ["taskID": conversationID]))
        let currentTerminal = try await pollUntilTerminal(receipt: currentReceipt)
        assertAccepted(currentTerminal, "conversation.get(current)")
        let current = try XCTUnwrap(currentTerminal["value"] as? [String: Any])
        let currentRevision = try XCTUnwrap(current["revision"] as? String)
        XCTAssertNotEqual(currentRevision, createdRevision,
                          "archive must advance the raw-row revision")

        let deleteReceipt = try submit(submitEnvelope(
            correlation: "delete-real-\(UUID().uuidString)",
            command: "conversation.delete",
            scope: BridgeV3.Scope.conversationLifecycle.rawValue,
            owner: ["taskID": conversationID],
            revision: (resourceID, currentRevision), stateful: true))
        let deleteTerminal = try await pollUntilTerminal(receipt: deleteReceipt)
        // Structural invariants either way: a typed terminal (no crash/fake
        // success), and the observable store state matches the outcome.
        let kind = try XCTUnwrap(deleteTerminal["kind"] as? String)
        if kind == "accepted" {
            let listedReceipt = try submit(submitEnvelope(
                correlation: "delete-list-\(UUID().uuidString)",
                command: "conversation.list",
                scope: BridgeV3.Scope.applicationConfiguration.rawValue,
                configurationScope: "conversations",
                payload: ["includeArchived": true, "limit": 50,
                          "includeRevision": true]))
            let listedTerminal = try await pollUntilTerminal(receipt: listedReceipt)
            let listed = try XCTUnwrap(listedTerminal["value"] as? [String: Any],
                                       "\(listedTerminal)")
            let rowsAny = try XCTUnwrap(listed["rows"] as? [Any],
                                        "conversation.list rows missing: \(listed)")
            let rows = rowsAny.compactMap { $0 as? [String: Any] }
            XCTAssertEqual(rows.count, rowsAny.count,
                           "every list row must be an object: \(listed)")
            XCTAssertFalse(rows.contains { ($0["conversationID"] as? String) == conversationID },
                           "accepted delete must remove the row from conversation.list")
        } else {
            XCTAssertTrue(["failed", "rejected"].contains(kind),
                          "real delete must settle a typed outcome: \(deleteTerminal)")
            // The row survives a refused delete and stays readable.
            let afterReceipt = try submit(submitEnvelope(
                correlation: "delete-get-after-\(UUID().uuidString)",
                command: "conversation.get",
                scope: BridgeV3.Scope.conversationLifecycle.rawValue,
                owner: ["taskID": conversationID]))
            let after = try await pollUntilTerminal(receipt: afterReceipt)
            assertAccepted(after, "conversation.get(after refused delete)")
            XCTAssertEqual((after["value"] as? [String: Any])?["conversationID"] as? String,
                           conversationID)
        }
        // Persist the exact observed outcome for the private evidence record.
        let evidence: [String: Any] = [
            "conversationID": conversationID,
            "createdRevision": createdRevision,
            "currentRevision": currentRevision,
            "deleteKind": kind,
            "deleteCode": deleteTerminal["code"] as? String ?? "none",
            "deleteDetail": deleteTerminal["detail"] ?? [],
        ]
        let directory = ProcessInfo.processInfo
            .environment["FLOE_CORE_CARRIER_EVIDENCE_DIR"]
        if let directory {
            try FileManager.default.createDirectory(atPath: directory,
                                                    withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
                .write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("host-conversation-delete-outcome.json"))
        }
    }
}
