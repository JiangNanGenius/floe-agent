// SPDX-License-Identifier: MPL-2.0
//
// F-R1 / F-R2 production-wire regressions.
//
// These exercise the REAL registered processors (G02InstalledComposition
// over a REAL production bootstrap) through the REAL mailbox + effect pump:
//
//   F-R1: memory.delete / memory.candidate.resolve must read the entry id
//         from the CLOSED PAYLOAD of an owner-less applicationConfiguration
//         envelope (the App can never send an owner in this scope). Before
//         the repair both processors read envelope.owner.taskID and every
//         delete/resolve answered the typed missingRevisionForStatefulCommand
//         refusal although the App had sent the id.
//   F-R2: memory.organize.start must carry the REAL typed
//         MemoryOrganizeStartEffect (proposalHandle + scannedCount) in its
//         completed value; the previous identifier-only .accepted() made the
//         App report organize_malformed after every real scan.
//
// Synthetic roots/data only; no device, key or network.
import XCTest
import Foundation
@testable import FloeCore
@testable import FloeAndroidCore

/// The live-generation snapshot tuple exposed for tests
/// (AndroidRuntimeBootstrap.currentGenerationForTesting).
private typealias TestGeneration = (
    epoch: UInt64, effects: FacadeEffectPump, events: FacadeEventPump,
    content: FacadeContentReader, mailbox: FacadeCommandMailbox,
    registry: RuntimeDomainRegistry, owner: AndroidRuntimeStoreOwner,
    bootstrapReceipt: String)

final class G02SettingsWireRepairTests: XCTestCase {

    private var tracked: [Boot] = []

    override func tearDown() async throws {
        for boot in tracked.reversed() where !boot.retired {
            await shutdownAndAwaitClosed(boot)
        }
        tracked.removeAll()
        G02RuntimeComposition.shared.resetForTesting()
        AndroidRuntimeBootstrap.resetForTesting()
        try await super.tearDown()
    }

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

    private final class Boot {
        let epoch: UInt64
        let receipt: String
        let rootPath: String
        let token: String
        var retired = false
        init(epoch: UInt64, receipt: String, rootPath: String, token: String) {
            self.epoch = epoch
            self.receipt = receipt
            self.rootPath = rootPath
            self.token = token
        }
    }

    private enum TestError: Error {
        case bootstrap
        case submit
    }

    @discardableResult
    private func bootInstalledGeneration(
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> (Boot, TestGeneration) {
        let root = NSTemporaryDirectory()
            .appending("wire-repair-tests-\(UUID().uuidString)")
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
        let boot = Boot(epoch: epoch, receipt: receipt, rootPath: root,
                        token: token)
        tracked.append(boot)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard let gen = AndroidRuntimeBootstrap.currentGenerationForTesting(),
                  gen.epoch == epoch else {
                XCTFail("generation vanished before its accepted terminal",
                        file: file, line: line)
                throw TestError.bootstrap
            }
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
            return (boot, gen)
        }
        XCTFail("bootstrap terminal did not settle", file: file, line: line)
        throw TestError.bootstrap
    }

    private func shutdownAndAwaitClosed(_ boot: Boot) async {
        guard !boot.retired else { return }
        defer { boot.retired = true }
        switch AndroidRuntimeBootstrap.shutdown(
            expectedEpoch: boot.epoch, ownerToken: boot.token) {
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

    // MARK: - Wire helpers

    private func envelopeJSON(command: String,
                              payload: [String: Any],
                              revision: [String: Any]? = nil,
                              createIntent: Bool = false) throws -> Data {
        var object: [String: Any] = [
            "schema": BridgeV3.commandSchema,
            "scope": BridgeV3.Scope.applicationConfiguration.rawValue,
            "configurationScope": "memory",
            "command": command,
            "stateful": true,
            "correlationID": "wire-repair",
            "payload": payload,
        ]
        if let revision { object["revision"] = revision }
        if createIntent { object["createIntent"] = true }
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Submit one memory-domain envelope through the REAL mailbox and return
    /// its terminal effect item.
    private func submitMemory(
        _ gen: TestGeneration,
        command: String,
        payload: [String: Any],
        revision: [String: Any]? = nil,
        createIntent: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> RuntimeEffectItem {
        let correlation = "wire-\(UUID().uuidString)"
        let receipt = try XCTUnwrap(
            gen.effects.register(correlationID: correlation), file: file, line: line)
        let data = try envelopeJSON(command: command, payload: payload,
                                    revision: revision, createIntent: createIntent)
        let job = RuntimeCommandEnvelopeJob(
            correlationID: correlation,
            handlerKey: BridgeV3.handlerKey(scope: .applicationConfiguration,
                                            command: command),
            command: command,
            scope: .applicationConfiguration,
            configurationScope: "memory",
            receipt: receipt,
            envelope: data)
        guard case .queued = gen.mailbox.submit(job) else {
            XCTFail("job not queued", file: file, line: line)
            throw TestError.submit
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if case .page(let effects, _, _, _) =
                    gen.effects.poll(receipt: receipt, afterSequence: 0),
               let terminal = effects.last(where: { $0.isTerminal }) {
                return terminal
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("terminal never settled for \(command)", file: file, line: line)
        throw TestError.submit
    }

    private func valueObject(_ item: RuntimeEffectItem) -> [String: DesignJSONValue]? {
        guard case .object(let object)? = item.value else { return nil }
        return object
    }

    private func stringField(_ object: [String: DesignJSONValue], _ key: String) -> String? {
        guard case .string(let value)? = object[key] else { return nil }
        return value
    }

    private func boolField(_ object: [String: DesignJSONValue], _ key: String) -> Bool? {
        guard case .bool(let value)? = object[key] else { return nil }
        return value
    }

    private func intField(_ object: [String: DesignJSONValue], _ key: String) -> Int? {
        guard case .integer(let value)? = object[key] else { return nil }
        return Int(value)
    }

    @discardableResult
    private func addEntry(_ gen: TestGeneration,
                          content: String) async throws -> (id: String, revision: String) {
        let added = try await submitMemory(gen, command: "memory.add", payload: [
            "content": content,
            "scope": ["kind": "user"],
        ])
        XCTAssertEqual(added.kind, .accepted, "memory.add must complete")
        let object = try XCTUnwrap(valueObject(added), "add must carry a value")
        guard case .object(let entry)? = object["entry"] else {
            XCTFail("add value must carry the entry")
            throw TestError.submit
        }
        let id = try XCTUnwrap(stringField(entry, "id"))
        let revision = try XCTUnwrap(stringField(entry, "revision"))
        return (id, revision)
    }

    private func entryCount(_ gen: TestGeneration) async throws -> Int {
        let listed = try await submitMemory(gen, command: "memory.list", payload: [
            "limit": 50,
        ])
        XCTAssertEqual(listed.kind, .accepted)
        let object = try XCTUnwrap(valueObject(listed))
        guard case .array(let entries)? = object["entries"] else { return 0 }
        return entries.count
    }

    // MARK: - F-R1: memory.delete reads the closed payload id

    func testMemoryDeleteUsesClosedPayloadIdWithoutOwner() async throws {
        let (_, gen) = try await bootInstalledGeneration()
        let entry = try await addEntry(gen, content: "delete me via payload id")

        // The App's exact envelope: NO owner (the configuration scope forbids
        // it), the id in the closed payload, the digest CAS on the revision.
        let deleted = try await submitMemory(
            gen, command: "memory.delete",
            payload: ["id": entry.id],
            revision: [
                "resourceID": "memory.\(entry.id)",
                "version": entry.revision,
            ])
        XCTAssertEqual(deleted.kind, .accepted,
                       "delete must complete from the payload id, not fail on a missing owner")
        let object = try XCTUnwrap(valueObject(deleted))
        XCTAssertEqual(boolField(object, "deleted"), true)
        let remaining = try await entryCount(gen)
        XCTAssertEqual(remaining, 0, "the entry must actually be gone")
    }

    func testMemoryDeleteWithoutPayloadIdRefusesTypedNotRevisionAbsent() async throws {
        let (_, gen) = try await bootInstalledGeneration()
        let entry = try await addEntry(gen, content: "payload id missing case")
        // Owner-less envelope WITHOUT the payload id: the repair must surface
        // the envelope-shape refusal (invalidEnvelope), NOT the old
        // owner-dependent missingRevisionForStatefulCommand/revisionAbsent.
        let refused = try await submitMemory(
            gen, command: "memory.delete",
            payload: [:],
            revision: [
                "resourceID": "memory.\(entry.id)",
                "version": entry.revision,
            ])
        XCTAssertEqual(refused.kind, .failed)
        let object = try XCTUnwrap(valueObject(refused))
        XCTAssertEqual(stringField(object, "errorCode"), "invalidEnvelope")
        XCTAssertEqual(stringField(object, "reason"), "unknownMemoryField")
        // Nothing was deleted by the refusal.
        let countAfterRefusal = try await entryCount(gen)
        XCTAssertEqual(countAfterRefusal, 1)
    }

    // MARK: - F-R1: memory.candidate.resolve reads the closed payload id

    func testCandidateResolveUsesClosedPayloadIdWithoutOwner() async throws {
        let (_, gen) = try await bootInstalledGeneration()
        let candidateID = UUID().uuidString
        // No candidate exists for this id: the important fact is that the
        // processor got PAST the owner-reading gate and answered a DOMAIN
        // refusal, not the old owner-dependent revisionAbsent envelope error.
        let resolved = try await submitMemory(
            gen, command: "memory.candidate.resolve",
            payload: ["id": candidateID, "activate": false],
            revision: [
                "resourceID": "memory.candidate.\(candidateID)",
                "version": "0".padding(toLength: 64, withPad: "0", startingAt: 0),
            ])
        XCTAssertEqual(resolved.kind, .failed)
        let object = try XCTUnwrap(valueObject(resolved))
        let errorCode = stringField(object, "errorCode")
        XCTAssertNotEqual(errorCode, "missingRevisionForStatefulCommand",
                          "the refusal must not come from the removed owner read")
        XCTAssertNotEqual(stringField(object, "reason"), "revisionAbsent")
    }

    // MARK: - F-R2: organize.start carries the typed effect

    func testOrganizeStartCarriesTypedProposalEffect() async throws {
        let (_, gen) = try await bootInstalledGeneration()
        try await addEntry(gen, content: "organize scan entry one")
        try await addEntry(gen, content: "organize scan entry two")

        let started = try await submitMemory(
            gen, command: "memory.organize.start",
            payload: ["mode": "reviewFirst", "includeSemantic": false],
            createIntent: true)
        XCTAssertEqual(started.kind, .accepted,
                       "organize.start must complete with its typed effect")
        let object = try XCTUnwrap(valueObject(started),
                                   "the start effect must be a completed VALUE")
        let handle = try XCTUnwrap(stringField(object, "proposalHandle"),
                                   "proposalHandle must be present (was discarded before)")
        XCTAssertFalse(handle.isEmpty)
        XCTAssertGreaterThanOrEqual(intField(object, "scannedCount") ?? 0, 2)

        // The handle must be consumable by the proposal read the App performs
        // next (the previous .accepted() value made this unreachable).
        let proposal = try await submitMemory(
            gen, command: "memory.organize.proposal.read",
            payload: ["handle": handle])
        XCTAssertEqual(proposal.kind, .accepted)
        let proposalObject = try XCTUnwrap(valueObject(proposal))
        XCTAssertNotNil(proposalObject["suggestions"])
    }
}
