// SPDX-License-Identifier: MPL-2.0
//
// RB-7 attachment staging — v3 wire/bridge integration source tests.
//
// AUTHORED, NOT EXECUTED. These cases run the SEVEN EXISTING attachment
// commands through the real validation/dispatch stack (BridgeV3 structural
// validation -> RuntimeCommandBinder -> FacadeCommandMailbox -> async
// processors -> FacadeEffectPump) and the REAL file-backed schema-46
// DatabaseManager (original migration chain, lane's additive store seams),
// plus the staging JNI `_cdecl` surface exercised directly from Swift
// (pointer-calling Swift from Swift; the C TU wraps the same symbols on
// device). NOTHING here is a mock backend: the durable path is the original
// `RunLaunchStore.prepare` atomic insert, and every assertion distinguishes
// the truthful failure classes. Model stream, provider and network remain
// out of scope for this lane (arrival never starts anything).
//
// Synthetic fixtures only: fake URIs/names/bytes; never a real user file.
import XCTest
import Foundation
import Crypto
import GRDB
import FloeModels
import FloePersistence
import FloeCore
@testable import FloeAndroidCore

final class AttachmentStagingBridgeV3Tests: XCTestCase {

    // MARK: - Fixtures

    /// The bridge lane runs on a REAL accepted bootstrap generation (the
    /// MAIN_RUN_REAL_ROOT_FIXTURE_DIAGNOSIS protocol): monotonic epoch, real
    /// storeReady wait, the SAME bootstrap-owned DatabaseManager/store
    /// cluster, the generation's mailbox/effects/registry, and the REAL
    /// `RuntimeOwnedWorkRegistryStagingAttach` adapter — no scripted
    /// always-admitted receipts. Shutdown awaits the real control terminal
    /// plus ownedStorePhase=closed/generation-gone.
    private struct Lane {
        let root: URL
        let database: DatabaseManager
        let store: SQLiteConversationStore
        let service: AttachmentStagingService
        let mailbox: FacadeCommandMailbox
        let effects: FacadeEffectPump
        let registry: RuntimeDomainRegistry
        let grants: AttachmentReadGrantTable
        let epoch: UInt64
        let ownerToken: String
    }
    private var lanes: [Lane] = []

    private func makeLane(epoch requestedEpoch: UInt64? = nil) async throws -> Lane {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-staging-bridge-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let epoch = requestedEpoch ?? DispatchTime.now().uptimeNanoseconds
        let token = String(format: "%016llx", UInt64.random(in: 1...UInt64.max))
        do {
            return try await buildLane(root: root, epoch: epoch, token: token)
        } catch {
            // Structured awaited cleanup: a started generation that fails
            // mid-build is really retired BEFORE the error propagates (no
            // unowned defer Task, no timer-as-success).
            _ = AndroidRuntimeBootstrap.shutdown(expectedEpoch: epoch,
                                                 ownerToken: token)
            let deadline = Date().addingTimeInterval(25)
            while AndroidRuntimeBootstrap.currentGenerationForTesting() != nil,
                  Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            throw error
        }
    }

    private func buildLane(root: URL, epoch: UInt64, token: String) async throws -> Lane {
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root.standardizedFileURL.path, ownerToken: token, epoch: epoch) else {
            throw AttachmentStagingError(.internal)
        }
        var waited = 0
        while AndroidRuntimeBootstrap.currentPumps()?.storeReady != true, waited < 30_000 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 10
        }
        guard AndroidRuntimeBootstrap.currentPumps()?.storeReady == true,
              let generation = AndroidRuntimeBootstrap.currentGenerationForTesting(),
              generation.epoch == epoch,
              let database = await generation.owner.ownedDatabaseForTesting(),
              let conversations = await generation.owner.conversationStore else {
            throw AttachmentStagingError(.internal)
        }
        guard let storageRoot = RuntimeStorageRoot(validatingAbsoluteDirectory: root.path),
              let identity = RuntimeOwnerIdentity(root: storageRoot, token: token,
                                                  epoch: epoch) else {
            throw AttachmentStagingError(.internal)
        }
        let service = AttachmentStagingService(components: .init(
            identity: identity,
            store: conversations,
            ownedWork: RuntimeOwnedWorkRegistryStagingAttach.shared))
        let lane = Lane(root: root, database: database, store: conversations,
                        service: service, mailbox: generation.mailbox,
                        effects: generation.effects, registry: generation.registry,
                        grants: AttachmentReadGrantTable(), epoch: epoch,
                        ownerToken: token)
        lanes.append(lane)
        return lane
    }

    /// REAL fixture retirement: the trusted shutdown only ENQUEUES the
    /// internal control, so await its effect-receipt terminal AND the
    /// authoritative `ownedStorePhase == closed` / generation-gone facts
    /// before closing/removing anything.
    private func retireLanes() async {
        for lane in lanes.reversed() {
            _ = AndroidRuntimeBootstrap.shutdown(expectedEpoch: lane.epoch,
                                                 ownerToken: lane.ownerToken)
            var storeClosed = false
            var generationGone = false
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline {
                if let data = AndroidRuntimeBootstrap.statusSnapshotJSON().data(using: .utf8),
                   let status = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any] {
                    storeClosed = (status["ownedStorePhase"] as? String) == "closed"
                    let phase = status["phase"] as? String
                    generationGone = status["generation"] == nil
                        && (phase == "stopped" || phase == "failed")
                }
                if storeClosed && generationGone { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            if storeClosed && generationGone {
                try? FileManager.default.removeItem(at: lane.root)
            } else {
                // A fixture whose generation cannot really retire leaks owned
                // work into the NEXT test: fail loudly and preserve the root
                // for inspection (never remove live files or reset).
                XCTFail("bridge lane generation did not really retire: "
                            + "storeClosed=\(storeClosed) generationGone=\(generationGone) "
                            + "status=\(AndroidRuntimeBootstrap.statusSnapshotJSON())")
            }
        }
        lanes.removeAll()
    }

    private func install(_ lane: Lane) {
        XCTAssertTrue(AttachmentStagingFacade.install(components: .init(
            epoch: lane.epoch, mailbox: lane.mailbox, effects: lane.effects,
            registry: lane.registry, service: lane.service,
            launchAuthority: AttachmentStagingLaunchAuthority(service: lane.service),
            readGrants: lane.grants)))
    }

    // MARK: - Fixture vs production composition boundary

    /// This component lane owns its REAL staging service installation (the
    /// system under test is the seven-command bridge against the lane's own
    /// service), so it runs with the INTERNAL core-only composition mode:
    /// the bootstrap does NOT auto-install the production ordinary graph.
    /// The production default stays `.ordinaryProduct` and is restored in
    /// tearDown; the composed-root positive/lifecycle coverage lives in
    /// G02CompositionIntegrationTests.
    override func setUp() async throws {
        G02RuntimeComposition.shared.setCompositionModeForTesting(.coreOnly)
        try await super.setUp()
    }

    override func tearDown() async throws {
        AttachmentStagingFacade.uninstallAllForTesting()
        await retireLanes()
        G02RuntimeComposition.shared.setCompositionModeForTesting(.ordinaryProduct)
        try await super.tearDown()
    }

    // MARK: - Envelope builders (closed vocabularies only)

    private func envelope(command: String, scope: String, configurationScope: String?,
                          owner: [String: Any]?, revision: [String: Any]?,
                          payload: [String: Any], correlation: String,
                          stateful: Bool? = nil) -> [String: Any] {
        var env: [String: Any] = [
            "schema": BridgeV3.commandSchema,
            "scope": scope,
            "command": command,
            "stateful": stateful ?? (revision != nil),
            "correlationID": correlation,
            "payload": payload,
        ]
        if let configurationScope { env["configurationScope"] = configurationScope }
        if let owner { env["owner"] = owner }
        if let revision { env["revision"] = revision }
        return env
    }

    @discardableResult
    private func submit(_ env: [String: Any], correlation: String) -> [String: Any] {
        BridgeV3.handle(request: ["operation": "command.submit",
                                  "requestID": correlation,
                                  "envelope": env],
                        requestID: correlation)
    }

    private func pump(_ lane: Lane, receipt: String) async -> [RuntimeEffectItem] {
        var items: [RuntimeEffectItem] = []
        var sequence = 0
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            switch lane.effects.poll(receipt: receipt, afterSequence: sequence) {
            case .page(let page, let next, let hasMore, _):
                items.append(contentsOf: page)
                sequence = max(sequence, next)
                if page.contains(where: { $0.isTerminal }) { return items }
                if !hasMore { try? await Task.sleep(nanoseconds: 20_000_000) }
            default:
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        return items
    }

    private func detail(of item: RuntimeEffectItem) -> [String: String] {
        item.detail ?? [:]
    }

    /// Stage one real ingress through the JNI-visible Swift entry points.
    private func nativeStage(_ lane: Lane, name: String = "doc.bin",
                             mime: String = "application/pdf",
                             bytes: Data) throws -> (ingress: String, stagingID: String,
                                                     route: String) {
        var routeBuf = [CChar](repeating: 0, count: 64)
        let routeStatus = floeStagingRouteOpen(nil, 1, 0, 0, &routeBuf, 64)
        XCTAssertEqual(routeStatus, AttachmentStagingStatus.ok)
        let route = String(cString: routeBuf)
        var ingressBuf = [CChar](repeating: 0, count: 64)
        var stagingBuf = [CChar](repeating: 0, count: 64)
        let beginStatus = route.withCString { r in
            floeStagingBegin(r, nil, &ingressBuf, 64, &stagingBuf, 64)
        }
        XCTAssertEqual(beginStatus, AttachmentStagingStatus.ok)
        let ingress = String(cString: ingressBuf)
        let stagingID = String(cString: stagingBuf)
        // The native byte channel is chunked (bounded chunks only); write
        // the payload in maximumChunkBytes pieces.
        var writeStatus: Int32 = AttachmentStagingStatus.ok
        let limit = Int(AttachmentStagingLimits.maximumChunkBytes)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + limit, bytes.count)
            let piece = bytes[offset..<end]
            let status = piece.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                    return AttachmentStagingStatus.invalidArguments
                }
                return ingress.withCString { key in
                    floeStagingWrite(key, base, Int32(piece.count))
                }
            }
            guard status == AttachmentStagingStatus.ok else {
                writeStatus = status
                break
            }
            offset = end
        }
        XCTAssertEqual(writeStatus, AttachmentStagingStatus.ok)
        let endStatus = ingress.withCString { key in
            name.withCString { n in
                mime.withCString { m in
                    floeStagingEnd(key, n, m, nil)
                }
            }
        }
        XCTAssertEqual(endStatus, AttachmentStagingStatus.ok)
        return (ingress, stagingID, route)
    }

    // MARK: - Fail-closed before install

    func testSevenAttachmentCommandsFailClosedBeforeInstall() async throws {
        let lane = try await makeLane()
        for (command, scope, label) in [
            ("attachment.stage", "applicationConfiguration", "attachmentStaging"),
            ("attachment.staging.read", "applicationConfiguration", "attachmentStaging"),
            ("attachment.staging.cancel", "applicationConfiguration", "attachmentStaging"),
            ("attachment.staging.discard", "applicationConfiguration", "attachmentStaging"),
            ("attachment.commit", "conversationLifecycle", nil),
            ("attachment.read", "conversationLifecycle", nil),
            ("attachment.cancel", "conversationLifecycle", nil),
        ] {
            let correlation = "c-\(command)"
            let owner: [String: Any]? = scope == "conversationLifecycle"
                ? ["taskID": UUID().uuidString] : nil
            let revision: [String: Any]? = command == "attachment.commit"
                || command == "attachment.cancel"
                ? ["resourceID": "x", "version": "1"] : nil
            let response = submit(envelope(command: command, scope: scope,
                                           configurationScope: label,
                                           owner: owner, revision: revision,
                                           payload: [:], correlation: correlation),
                                  correlation: correlation)
            XCTAssertEqual(response["ok"] as? Bool, false, command)
            XCTAssertEqual(response["error"] as? String, "runtimeUnavailable", command)
            XCTAssertEqual(response["reason"] as? String, "commandBinderUnbound", command)
        }
        _ = lane
    }

    // MARK: - Structural rejections (never reach a handler)

    func testStructuralEnvelopeRejectionsForAttachmentCommands() {
        let task = UUID().uuidString
        let cases: [(String, [String: Any], String, String)] = {
            var rows: [(String, [String: Any], String, String)] = []
            rows.append(("stageWrongLabel",
                         envelope(command: "attachment.stage", scope: "applicationConfiguration",
                                  configurationScope: "system", owner: nil, revision: nil,
                                  payload: [:], correlation: "a"),
                         "invalidEnvelope", "configurationScopeMismatch"))
            rows.append(("stageInLifecycleScope",
                         envelope(command: "attachment.stage", scope: "conversationLifecycle",
                                  configurationScope: nil, owner: ["taskID": task],
                                  revision: nil, payload: [:], correlation: "b"),
                         "invalidEnvelope", "commandScopeMismatch"))
            rows.append(("commitWithoutTask",
                         envelope(command: "attachment.commit", scope: "conversationLifecycle",
                                  configurationScope: nil, owner: nil, revision: nil,
                                  payload: [:], correlation: "c", stateful: true),
                         "invalidEnvelope", "missingTaskIdentity"))
            rows.append(("commitCarriesRun",
                         envelope(command: "attachment.commit", scope: "conversationLifecycle",
                                  configurationScope: nil,
                                  owner: ["taskID": task, "runID": UUID().uuidString],
                                  revision: ["resourceID": "conversation.\(task)",
                                              "version": "1"],
                                  payload: [:], correlation: "d"),
                         "invalidEnvelope", "conversationLifecycleMustNotCarryRunIdentity"))
            rows.append(("commitWithoutRevision",
                         envelope(command: "attachment.commit", scope: "conversationLifecycle",
                                  configurationScope: nil, owner: ["taskID": task],
                                  revision: nil, payload: [:], correlation: "e",
                                  stateful: true),
                         "invalidEnvelope", "missingRevisionForStatefulCommand"))
            rows.append(("discardCarriesOwner",
                         envelope(command: "attachment.staging.discard",
                                  scope: "applicationConfiguration",
                                  configurationScope: "attachmentStaging",
                                  owner: ["taskID": task], revision: nil,
                                  payload: [:], correlation: "f"),
                         "invalidEnvelope", "configurationScopeMustNotCarryOwner"))
            rows.append(("unknownAttachmentCommand",
                         envelope(command: "attachment.staging.finish",
                                  scope: "applicationConfiguration",
                                  configurationScope: "attachmentStaging",
                                  owner: nil, revision: nil, payload: [:],
                                  correlation: "g"),
                         "invalidEnvelope", "unknownCommand"))
            return rows
        }()
        for (name, env, error, reason) in cases {
            let response = submit(env, correlation: (env["correlationID"] as? String) ?? "x")
            XCTAssertEqual(response["ok"] as? Bool, false, name)
            XCTAssertEqual(response["error"] as? String, error, name)
            XCTAssertEqual(response["reason"] as? String, reason, name)
        }
    }

    // MARK: - stage command end-to-end (identifiers-only settlement)

    func testStageCommandPublishesAndSettlesIdentifiersOnly() async throws {
        let lane = try await makeLane()
        install(lane)
        let bytes = Data((0..<4_096).map { UInt8($0 % 251) })
        let staged = try nativeStage(lane, name: "doc.bin", mime: "application/pdf",
                                     bytes: bytes)
        let correlation = "stage-1"
        let response = submit(envelope(command: "attachment.stage",
                                       scope: "applicationConfiguration",
                                       configurationScope: "attachmentStaging",
                                       owner: nil, revision: nil,
                                       payload: ["ingressReceipt": staged.ingress],
                                       correlation: correlation),
                              correlation: correlation)
        XCTAssertEqual(response["ok"] as? Bool, true)
        let receipt = try XCTUnwrap(response["operationReceiptID"] as? String)
        let items = await pump(lane, receipt: receipt)
        let terminal = try XCTUnwrap(items.last)
        XCTAssertEqual(terminal.kind, .accepted)
        let detail = detail(of: terminal)
        XCTAssertEqual(detail["result"], "accepted")
        XCTAssertEqual(detail["stagingID"], staged.stagingID)
        XCTAssertEqual(detail["byteCount"], String(bytes.count))
        XCTAssertEqual(detail["sha256"],
                       SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let handle = try XCTUnwrap(detail["stagingHandle"])
        XCTAssertTrue(AttachmentReceipt.isValid(handle,
                                               prefix: AttachmentReceipt.stagingPrefix))
        // Identifier-only: name/MIME NEVER appear in the wire detail.
        XCTAssertNil(detail["displayName"])
        XCTAssertNil(detail["mimeType"])
        // The durable record exists under the app-private attachments root.
        let view = try XCTUnwrap(lane.service.snapshot(handle: handle))
        XCTAssertEqual(view.displayName, "doc.bin")
        let finalURL = lane.root.appendingPathComponent("Attachments")
            .appendingPathComponent(staged.stagingID).appendingPathComponent("doc.bin")
        XCTAssertEqual(try Data(contentsOf: finalURL), bytes)
    }

    func testCorrelationDedupeReplaysOriginalReceiptOnly() async throws {
        let lane = try await makeLane()
        install(lane)
        let bytes = Data("payload".utf8)
        let staged = try nativeStage(lane, bytes: bytes)
        let env = envelope(command: "attachment.stage", scope: "applicationConfiguration",
                           configurationScope: "attachmentStaging", owner: nil, revision: nil,
                           payload: ["ingressReceipt": staged.ingress], correlation: "dup-1")
        let first = submit(env, correlation: "dup-1")
        let second = submit(env, correlation: "dup-1")
        XCTAssertEqual(first["operationReceiptID"] as? String,
                       second["operationReceiptID"] as? String)
    }

    func testForgedUriAndPathPayloadsRefusedWithoutConsumingTheIngress() async throws {
        let lane = try await makeLane()
        install(lane)
        let bytes = Data("still-live".utf8)
        let staged = try nativeStage(lane, bytes: bytes)
        let forgedRows: [(payload: [String: Any], code: String)] = [
            (["uri": "content://fake/provider/1"], "payloadInvalid"),
            (["path": "/data/data/fake/file.bin"], "payloadInvalid"),
            (["ingressReceipt": staged.ingress, "contentUri": "content://fake/2"],
             "payloadInvalid"),
            (["ingressReceipt": "sing:v1:" + String(repeating: "f", count: 32)],
             "ingressUnknown"),
        ]
        for row in forgedRows {
            let correlation = "forged-\(row.code)-\(UUID().uuidString)"
            let response = submit(envelope(command: "attachment.stage",
                                           scope: "applicationConfiguration",
                                           configurationScope: "attachmentStaging",
                                           owner: nil, revision: nil,
                                           payload: row.payload, correlation: correlation),
                                  correlation: correlation)
            let receipt = try XCTUnwrap(response["operationReceiptID"] as? String)
            let items = await pump(lane, receipt: receipt)
            let detail = detail(of: try XCTUnwrap(items.last))
            XCTAssertEqual(detail["result"], "refused", "\(row.payload)")
            XCTAssertEqual(detail["code"], row.code, "\(row.payload)")
        }
        // The REAL ingress is untouched by the forged attempts and still
        // publishes on the valid command.
        let good = envelope(command: "attachment.stage", scope: "applicationConfiguration",
                            configurationScope: "attachmentStaging", owner: nil, revision: nil,
                            payload: ["ingressReceipt": staged.ingress], correlation: "good-1")
        let response = submit(good, correlation: "good-1")
        let items = await pump(lane, receipt: try XCTUnwrap(
            response["operationReceiptID"] as? String))
        XCTAssertEqual(detail(of: try XCTUnwrap(items.last))["stagingID"], staged.stagingID)
    }

    // MARK: - Commit CAS against the REAL schema-46 store

    private func conversationDigest(_ lane: Lane, id: UUID) async throws -> String {
        try await lane.database.writer { db in
            guard let value = try ConversationRowRevision.digest(db: db, conversationID: id)
            else { throw FloeError.notFound("conversation") }
            return value
        }
    }

    private func makeConversation(_ lane: Lane, now: Date) async throws -> UUID {
        let id = UUID()
        try await lane.store.saveConversation(ConversationRecord(
            id: id, title: "Staging CAS", createdAt: now, updatedAt: now))
        return id
    }

    func testCommitWritesRealConversationLevelRowWithNullMessage() async throws {
        let lane = try await makeLane()
        install(lane)
        let conversation = try await makeConversation(lane, now: Date())
        let digest = try await conversationDigest(lane, id: conversation)
        let bytes = Data("commit-me".utf8)
        let staged = try nativeStage(lane, bytes: bytes)
        let stageResponse = submit(envelope(command: "attachment.stage",
                                            scope: "applicationConfiguration",
                                            configurationScope: "attachmentStaging",
                                            owner: nil, revision: nil,
                                            payload: ["ingressReceipt": staged.ingress],
                                            correlation: "s1"),
                                   correlation: "s1")
        let stageItems = await pump(lane, receipt: try XCTUnwrap(
            stageResponse["operationReceiptID"] as? String))
        let handle = try XCTUnwrap(detail(of: try XCTUnwrap(stageItems.last))["stagingHandle"])

        let commitCorr = "commit-1"
        let response = submit(envelope(command: "attachment.commit",
                                       scope: "conversationLifecycle",
                                       configurationScope: nil,
                                       owner: ["taskID": conversation.uuidString],
                                       revision: ["resourceID": "conversation.\(conversation)",
                                                   "version": digest],
                                       payload: ["stagingHandles": [handle]],
                                       correlation: commitCorr),
                              correlation: commitCorr)
        let items = await pump(lane, receipt: try XCTUnwrap(
            response["operationReceiptID"] as? String))
        let terminal = try XCTUnwrap(items.last)
        XCTAssertEqual(terminal.kind, .accepted)
        XCTAssertEqual(detail(of: terminal)["committedCount"], "1")

        // The row is REAL, durable and message-unbound.
        let id = try XCTUnwrap(UUID(uuidString: staged.stagingID))
        let row = try unwrapAsync(await lane.store.attachment(id: id))
        XCTAssertEqual(row.conversationID, conversation)
        XCTAssertNil(row.messageID)
        XCTAssertEqual(row.storage, .applicationSupport)
        XCTAssertEqual(row.sha256,
                       SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(row.byteCount, bytes.count)
        // The handle is retired once committed; a second commit attempt can
        // never double-insert (the RAM truth refuses; the PK guards below).
        let second = submit(envelope(command: "attachment.commit",
                                     scope: "conversationLifecycle",
                                     configurationScope: nil,
                                     owner: ["taskID": conversation.uuidString],
                                     revision: ["resourceID": "conversation.\(conversation)",
                                                 "version": digest],
                                     payload: ["stagingHandles": [handle]],
                                     correlation: "commit-2"),
                            correlation: "commit-2")
        let secondItems = await pump(lane, receipt: try XCTUnwrap(
            second["operationReceiptID"] as? String))
        XCTAssertEqual(detail(of: try XCTUnwrap(secondItems.last))["result"], "refused")
        let count: Int = try await lane.database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attachments WHERE id = ?",
                             arguments: [id.uuidString]) ?? -1
        }
        XCTAssertEqual(count, 1)
    }

    func testCommitStaleConversationDigestRefusesAndKeepsStagedRecoverable() async throws {
        let lane = try await makeLane()
        install(lane)
        let conversation = try await makeConversation(lane, now: Date())
        let bytes = Data("stale".utf8)
        let staged = try nativeStage(lane, bytes: bytes)
        let stageResponse = submit(envelope(command: "attachment.stage",
                                            scope: "applicationConfiguration",
                                            configurationScope: "attachmentStaging",
                                            owner: nil, revision: nil,
                                            payload: ["ingressReceipt": staged.ingress],
                                            correlation: "s2"),
                                   correlation: "s2")
        let stageReceipt = try XCTUnwrap(stageResponse["operationReceiptID"] as? String)
        let stageItems = await pump(lane, receipt: stageReceipt)
        let handle = try XCTUnwrap(detail(of: try XCTUnwrap(stageItems.last))["stagingHandle"])
        let response = submit(envelope(command: "attachment.commit",
                                       scope: "conversationLifecycle",
                                       configurationScope: nil,
                                       owner: ["taskID": conversation.uuidString],
                                       revision: ["resourceID": "conversation.\(conversation)",
                                                   "version": "stale-digest"],
                                       payload: ["stagingHandles": [handle]],
                                       correlation: "commit-stale"),
                              correlation: "commit-stale")
        let items = await pump(lane, receipt: try XCTUnwrap(
            response["operationReceiptID"] as? String))
        let terminalDetail = detail(of: try XCTUnwrap(items.last))
        XCTAssertEqual(terminalDetail["result"], "refused")
        XCTAssertEqual(terminalDetail["code"], "rowChanged")
        // Failed DB commit path: staged bytes remain owned AND discardable.
        XCTAssertNotNil(lane.service.snapshot(handle: handle))
        let finalURL = lane.root.appendingPathComponent("Attachments")
            .appendingPathComponent(staged.stagingID).appendingPathComponent("doc.bin")
        XCTAssertEqual(try? Data(contentsOf: finalURL), bytes)
        XCTAssertNil(lane.service.discard(handle: handle))
    }

    // MARK: - Launch consumes ONLY through the original atomic prepare

    func testLaunchPrepareBindsStagedRefsAtomicallyAndOnce() async throws {
        let lane = try await makeLane()
        install(lane)
        let bytes = Data("launch-bytes".utf8)
        let staged = try nativeStage(lane, name: "file.bin", bytes: bytes)
        let stageResponse = submit(envelope(command: "attachment.stage",
                                            scope: "applicationConfiguration",
                                            configurationScope: "attachmentStaging",
                                            owner: nil, revision: nil,
                                            payload: ["ingressReceipt": staged.ingress],
                                            correlation: "s3"),
                                   correlation: "s3")
        let stageReceipt = try XCTUnwrap(stageResponse["operationReceiptID"] as? String)
        let stageItems = await pump(lane, receipt: stageReceipt)
        let handle = try XCTUnwrap(detail(of: try XCTUnwrap(stageItems.last))["stagingHandle"])
        let authority = AttachmentStagingLaunchAuthority(service: lane.service)
        let newConversation = UUID()
        let ref = try await authority.resolve(handle: handle, conversationID: newConversation,
                                              epoch: lane.epoch)
        let launchStore = SQLiteRunLaunchStore(database: lane.database)
        let prepared = try await launchStore.prepare(RunLaunchRequest(
            newConversationID: newConversation,
            conversationTitle: "Launch staging",
            goal: "hello",
            attachments: [ref]))
        XCTAssertEqual(prepared.attachments.count, 1)
        XCTAssertEqual(prepared.attachments.first?.conversationID, newConversation)
        XCTAssertEqual(prepared.attachments.first?.messageID, prepared.userMessage.id)
        let messageAttachments = prepared.userMessage.parts.compactMap(\.attachmentID)
        XCTAssertEqual(Set(messageAttachments), [ref.id])
        // Ordinary history reopen finds the committed row (survives reopen).
        let reopened = try unwrapAsync(await lane.store.attachment(id: ref.id))
        XCTAssertEqual(reopened.sha256,
                       SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        // A second launch re-resolving the same durable values hits the
        // ORIGINAL PK/transaction backstop and the RAM mark refuses first.
        do {
            _ = try await authority.resolve(handle: handle, conversationID: newConversation,
                                            epoch: lane.epoch)
            XCTFail("same handle must not resolve into a second launch")
        } catch let error as RunStagingError {
            XCTAssertEqual(error, .handleUnknown)
        }
        let rows: Int = try await lane.database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attachments", arguments: []) ?? -1
        }
        XCTAssertEqual(rows, 1, "prepare is the ONLY inserter; no second manual insert")
        let finalURL = lane.root.appendingPathComponent("Attachments")
            .appendingPathComponent(staged.stagingID).appendingPathComponent("file.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
    }

    func testRollbackBeforeCommitKeepsStagedBytesOwned() async throws {
        let lane = try await makeLane()
        install(lane)
        let bytes = Data("rollback".utf8)
        let staged = try nativeStage(lane, bytes: bytes)
        let stageResponse = submit(envelope(command: "attachment.stage",
                                            scope: "applicationConfiguration",
                                            configurationScope: "attachmentStaging",
                                            owner: nil, revision: nil,
                                            payload: ["ingressReceipt": staged.ingress],
                                            correlation: "s4"),
                                   correlation: "s4")
        let stageReceipt = try XCTUnwrap(stageResponse["operationReceiptID"] as? String)
        let stageItems = await pump(lane, receipt: stageReceipt)
        let handle = try XCTUnwrap(detail(of: try XCTUnwrap(stageItems.last))["stagingHandle"])
        guard case .success(let lease) = lane.service.reserveLaunchLease(handles: [handle],
                                                                         conversationID: nil,
                                                                         correlation: "lease-1")
        else { return XCTFail("reserve") }
        let refs = lane.service.refs(forLease: lease)
        XCTAssertEqual(refs.count, 1)
        // The ORIGINAL prepare FAILS pre-transaction (empty goal) — nothing
        // durable is written and nothing is deleted by the failure itself.
        let launchStore = SQLiteRunLaunchStore(database: lane.database)
        do {
            _ = try await launchStore.prepare(RunLaunchRequest(goal: "   ", attachments: refs))
            XCTFail("empty goal must fail")
        } catch is FloeError {
            // expected
        }
        XCTAssertNil(lane.service.rollbackLaunchLease(lease.leaseID))
        let view = try XCTUnwrap(lane.service.snapshot(handle: handle))
        XCTAssertEqual(view.state, StagedState.staged.rawValue)
        let finalURL = lane.root.appendingPathComponent("Attachments")
            .appendingPathComponent(staged.stagingID).appendingPathComponent("doc.bin")
        XCTAssertEqual(try Data(contentsOf: finalURL), bytes,
                       "recoverable staged bytes stay intact after a failed DB commit")
    }

    // MARK: - attachment.read / cancel truths and read grants

    func testAttachmentReadGrantsBoundedBytesAndRevokesOnCancel() async throws {
        let lane = try await makeLane()
        install(lane)
        let bytes = Data((0..<70_000).map { UInt8($0 % 197) })   // > one page
        let staged = try nativeStage(lane, name: "big.bin", mime: "application/octet-stream",
                                     bytes: bytes)
        let stageResponse = submit(envelope(command: "attachment.stage",
                                            scope: "applicationConfiguration",
                                            configurationScope: "attachmentStaging",
                                            owner: nil, revision: nil,
                                            payload: ["ingressReceipt": staged.ingress],
                                            correlation: "s5"),
                                   correlation: "s5")
        let stageReceipt = try XCTUnwrap(stageResponse["operationReceiptID"] as? String)
        let stageItems = await pump(lane, receipt: stageReceipt)
        let handle = try XCTUnwrap(detail(of: try XCTUnwrap(stageItems.last))["stagingHandle"])
        let conversation = UUID()
        let authority = AttachmentStagingLaunchAuthority(service: lane.service)
        let ref = try await authority.resolve(handle: handle, conversationID: conversation,
                                              epoch: lane.epoch)
        let launchStore = SQLiteRunLaunchStore(database: lane.database)
        let prepared = try await launchStore.prepare(RunLaunchRequest(
            newConversationID: conversation, goal: "read me", attachments: [ref]))
        let attachmentID = prepared.attachments[0].id

        // Before any attachment.read: the byte channel refuses (grant
        // missing) — never an unverified read.
        var out = [UInt8](repeating: 0, count: 65_536)
        let early = attachmentID.uuidString.withCString { a in
            conversation.uuidString.withCString { c in
                floeAttachmentRead(a, c, 0, &out, 65_536)
            }
        }
        XCTAssertEqual(early, AttachmentStagingStatus.grantMissing)

        // attachment.read (no revision required): ownership verify + grant.
        let response = submit(envelope(command: "attachment.read",
                                        scope: "conversationLifecycle",
                                        configurationScope: nil,
                                        owner: ["taskID": conversation.uuidString],
                                        revision: nil,
                                        payload: ["attachmentID": attachmentID.uuidString],
                                        correlation: "read-1"),
                               correlation: "read-1")
        let items = await pump(lane, receipt: try XCTUnwrap(
            response["operationReceiptID"] as? String))
        let readDetail = detail(of: try XCTUnwrap(items.last))
        XCTAssertEqual(readDetail["result"], "accepted")
        XCTAssertEqual(readDetail["byteCount"], String(bytes.count))
        let rowDigest = try XCTUnwrap(readDetail["rowDigest"])

        var first = [UInt8](repeating: 0, count: 65_536)
        let copied = attachmentID.uuidString.withCString { a in
            conversation.uuidString.withCString { c in
                floeAttachmentRead(a, c, 0, &first, 65_536)
            }
        }
        XCTAssertEqual(Int(copied), 65_536)
        XCTAssertEqual(Data(first), bytes.prefix(65_536))
        var second = [UInt8](repeating: 0, count: 65_536)
        let copiedSecond = attachmentID.uuidString.withCString { a in
            conversation.uuidString.withCString { c in
                floeAttachmentRead(a, c, 65_536, &second, 65_536)
            }
        }
        XCTAssertEqual(Data(second.prefix(Int(copiedSecond))),
                       bytes.dropFirst(65_536))
        var third = [UInt8](repeating: 0, count: 65_536)
        let eof = attachmentID.uuidString.withCString { a in
            conversation.uuidString.withCString { c in
                floeAttachmentRead(a, c, Int64(bytes.count), &third, 65_536)
            }
        }
        XCTAssertEqual(eof, 0, "clean EOF is zero bytes, not an error")
        // Wrong conversation cannot read even with a valid attachment id.
        var foreign = [UInt8](repeating: 0, count: 16)
        let wrong = attachmentID.uuidString.withCString { a in
            UUID().uuidString.withCString { c in
                floeAttachmentRead(a, c, 0, &foreign, 16)
            }
        }
        XCTAssertEqual(wrong, AttachmentStagingStatus.grantMissing)

        // A MESSAGE-bound row cannot be cancelled by the staging lane.
        let cancelResponse = submit(envelope(command: "attachment.cancel",
                                              scope: "conversationLifecycle",
                                              configurationScope: nil,
                                              owner: ["taskID": conversation.uuidString],
                                              revision: ["resourceID":
                                                            "attachment.\(attachmentID)",
                                                          "version": rowDigest],
                                              payload: ["attachmentID": attachmentID.uuidString],
                                              correlation: "cancel-bound"),
                                     correlation: "cancel-bound")
        let cancelItems = await pump(lane, receipt: try XCTUnwrap(
            cancelResponse["operationReceiptID"] as? String))
        let cancelDetail = detail(of: try XCTUnwrap(cancelItems.last))
        XCTAssertEqual(cancelDetail["result"], "refused")
        XCTAssertEqual(cancelDetail["code"], "rowBoundToMessage")
        // …and the bytes stay.
        let still = attachmentID.uuidString.withCString { a in
            conversation.uuidString.withCString { c in
                floeAttachmentRead(a, c, 0, &first, 65_536)
            }
        }
        XCTAssertEqual(Int(still), 65_536)
    }

    func testConversationLevelCancelRemovesRowThenBytesExactlyOnce() async throws {
        let lane = try await makeLane()
        install(lane)
        let bytes = Data("row-level".utf8)
        let staged = try nativeStage(lane, name: "note.txt", mime: "text/plain", bytes: bytes)
        let stageResponse = submit(envelope(command: "attachment.stage",
                                            scope: "applicationConfiguration",
                                            configurationScope: "attachmentStaging",
                                            owner: nil, revision: nil,
                                            payload: ["ingressReceipt": staged.ingress],
                                            correlation: "s6"),
                                   correlation: "s6")
        let stageReceipt = try XCTUnwrap(stageResponse["operationReceiptID"] as? String)
        let stageItems = await pump(lane, receipt: stageReceipt)
        let handle = try XCTUnwrap(detail(of: try XCTUnwrap(stageItems.last))["stagingHandle"])
        let conversation = try await makeConversation(lane, now: Date())
        let digest = try await conversationDigest(lane, id: conversation)
        let commitResponse = submit(envelope(command: "attachment.commit",
                                              scope: "conversationLifecycle",
                                              configurationScope: nil,
                                              owner: ["taskID": conversation.uuidString],
                                              revision: ["resourceID":
                                                            "conversation.\(conversation)",
                                                          "version": digest],
                                              payload: ["stagingHandles": [handle]],
                                              correlation: "commit-6"),
                                     correlation: "commit-6")
        _ = await pump(lane, receipt: try XCTUnwrap(
            commitResponse["operationReceiptID"] as? String))
        let id = try XCTUnwrap(UUID(uuidString: staged.stagingID))
        let row = try unwrapAsync(await lane.store.attachment(id: id))
        let rowDigest: String = try await lane.database.reader { db in
            guard let raw = try Row.fetchOne(db,
                        sql: "SELECT * FROM attachments WHERE id = ?",
                        arguments: [id.uuidString]) else { throw FloeError.notFound("row") }
            return AttachmentRowRevision.digest(of: raw)
        }
        _ = row
        let cancelResponse = submit(envelope(command: "attachment.cancel",
                                              scope: "conversationLifecycle",
                                              configurationScope: nil,
                                              owner: ["taskID": conversation.uuidString],
                                              revision: ["resourceID": "attachment.\(id)",
                                                          "version": rowDigest],
                                              payload: ["attachmentID": id.uuidString],
                                              correlation: "cancel-6"),
                                     correlation: "cancel-6")
        let items = await pump(lane, receipt: try XCTUnwrap(
            cancelResponse["operationReceiptID"] as? String))
        XCTAssertEqual(detail(of: try XCTUnwrap(items.last))["result"], "accepted")
        let remaining = try await lane.store.attachment(id: id)
        XCTAssertNil(remaining)
        let finalURL = lane.root.appendingPathComponent("Attachments")
            .appendingPathComponent(id.uuidString).appendingPathComponent("note.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path),
                       "bytes removed ONLY after the row delete settled")
        // Re-cancel: the row is gone; the truth is handleUnknown (absent),
        // never a double-success.
        let again = submit(envelope(command: "attachment.cancel",
                                     scope: "conversationLifecycle", configurationScope: nil,
                                     owner: ["taskID": conversation.uuidString],
                                     revision: ["resourceID": "attachment.\(id)",
                                                 "version": rowDigest],
                                     payload: ["attachmentID": id.uuidString],
                                     correlation: "cancel-6b"),
                            correlation: "cancel-6b")
        let againItems = await pump(lane, receipt: try XCTUnwrap(
            again["operationReceiptID"] as? String))
        XCTAssertEqual(detail(of: try XCTUnwrap(againItems.last))["code"], "handleUnknown")
    }

    // MARK: - Generation fence + unbound restore

    func testRetireRestoresFailClosedAndKeepsDurableBytes() async throws {
        let lane = try await makeLane()
        install(lane)
        let bytes = Data("retire".utf8)
        let staged = try nativeStage(lane, name: "keep.bin", bytes: bytes)
        let stageResponse = submit(envelope(command: "attachment.stage",
                                            scope: "applicationConfiguration",
                                            configurationScope: "attachmentStaging",
                                            owner: nil, revision: nil,
                                            payload: ["ingressReceipt": staged.ingress],
                                            correlation: "s7"),
                                   correlation: "s7")
        let stageReceipt = try XCTUnwrap(stageResponse["operationReceiptID"] as? String)
        let stageItems = await pump(lane, receipt: stageReceipt)
        let handle = try XCTUnwrap(detail(of: try XCTUnwrap(stageItems.last))["stagingHandle"])
        AttachmentStagingFacade.retire(epoch: lane.epoch)
        // Wire path fail-closed again…
        let response = submit(envelope(command: "attachment.staging.discard",
                                       scope: "applicationConfiguration",
                                       configurationScope: "attachmentStaging",
                                       owner: nil, revision: nil,
                                       payload: ["stagingHandle": handle],
                                       correlation: "after-retire"),
                              correlation: "after-retire")
        XCTAssertEqual(response["error"] as? String, "runtimeUnavailable")
        // …JNI fail-closed…
        var out = [UInt8](repeating: 0, count: 16)
        let status = handle.withCString { h in
            floeStagingRead(h, 0, &out, 16)
        }
        XCTAssertEqual(status, AttachmentStagingStatus.notInstalled)
        // …and the durable staged file is STILL there for the next
        // generation's reconcile (committed bytes are never pruned).
        let finalURL = lane.root.appendingPathComponent("Attachments")
            .appendingPathComponent(staged.stagingID).appendingPathComponent("keep.bin")
        XCTAssertEqual(try Data(contentsOf: finalURL), bytes)
    }

    // MARK: - Binary never in JSON

    func testStagedBinaryNeverAppearsInAnyJSONChannel() async throws {
        let lane = try await makeLane()
        install(lane)
        // Bytes containing valid UTF-8 text AND JSON punctuation.
        let sneaky = Data("{\"secret\":\"\(UUID().uuidString)\",\"padding\":\"".utf8)
        let staged = try nativeStage(lane, name: "sneaky.json",
                                     mime: "application/json", bytes: sneaky)
        let response = submit(envelope(command: "attachment.stage",
                                       scope: "applicationConfiguration",
                                       configurationScope: "attachmentStaging",
                                       owner: nil, revision: nil,
                                       payload: ["ingressReceipt": staged.ingress],
                                       correlation: "s8"),
                              correlation: "s8")
        let items = await pump(lane, receipt: try XCTUnwrap(
            response["operationReceiptID"] as? String))
        let terminal = try XCTUnwrap(items.last)
        let serialized = String(data: try JSONSerialization.data(
            withJSONObject: terminal.jsonObject), encoding: .utf8) ?? ""
        XCTAssertTrue(serialized.contains(staged.stagingID), "identifier present")
        XCTAssertFalse(serialized.contains("{\"secret\""),
                       "file bytes NEVER inline into settlement JSON")
        var out = [UInt8](repeating: 0, count: 64)
        let handle = try XCTUnwrap(detail(of: terminal)["stagingHandle"])
        let copied = handle.withCString { h in floeStagingRead(h, 0, &out, 64) }
        XCTAssertEqual(Data(out.prefix(Int(copied))), sneaky.prefix(Int(copied)),
                       "bytes come ONLY through the bounded binary channel")
    }

    // MARK: - JNI shape guards

    func testNativeChunkAndReceiptShapeGuards() async throws {
        let lane = try await makeLane()
        install(lane)
        var routeBuf = [CChar](repeating: 0, count: 64)
        // Zero-sized and over-chunk writes are typed refusals, never partial
        // accepts; malformed receipts never resolve.
        var ingressBuf = [CChar](repeating: 0, count: 64)
        var stagingBuf = [CChar](repeating: 0, count: 64)
        let openStatus = floeStagingRouteOpen(nil, 1, 0, 0, &routeBuf, 64)
        XCTAssertEqual(openStatus, AttachmentStagingStatus.ok)
        let beginStatus = String(cString: routeBuf).withCString { r in
            floeStagingBegin(r, nil, &ingressBuf, 64, &stagingBuf, 64)
        }
        XCTAssertEqual(beginStatus, AttachmentStagingStatus.ok)
        let payload = Data(count: 16)
        let zeroWrite = String(cString: ingressBuf).withCString { i in
            payload.withUnsafeBytes { raw in
                floeStagingWrite(i, raw.bindMemory(to: UInt8.self).baseAddress, 0)
            }
        }
        XCTAssertEqual(zeroWrite, AttachmentStagingStatus.invalidArguments)
        let forged = "sing:v1:" + String(repeating: "0", count: 32)
        let forgedStatus = forged.withCString { i in
            payload.withUnsafeBytes { raw in
                floeStagingWrite(i, raw.bindMemory(to: UInt8.self).baseAddress, 16)
            }
        }
        XCTAssertEqual(forgedStatus, AttachmentStagingStatus.ingressUnknown)
        // Temporary route: -304 BEFORE any file effect (double gate).
        var ignored = [CChar](repeating: 0, count: 64)
        let temporaryStatus = floeStagingRouteOpen(nil, 1, 0, 1, &ignored, 64)
        XCTAssertEqual(temporaryStatus, AttachmentStagingStatus.routeTemporary)
    }
}
