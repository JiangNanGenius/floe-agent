// SPDX-License-Identifier: MPL-2.0
//
// G04LanguageSettingsTests — SOURCE-ONLY host tests for the durable language
// settings (job-bdebb54ff6ff4403). Authored in the package; NOT executed by
// the authoring job. They run against the ORIGINAL file-backed
// DatabaseManager/migrations + the ORIGINAL app_settings row shape, exactly
// like the accepted SettingsDefaultsAdapterTests precedent. All fixtures are
// synthetic; no shared source is edited.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloePersistence
@testable import FloeAndroidCore

final class G04LanguageSettingsTests: XCTestCase {
    private struct InjectedFault: Error {}

    /// Decodes the REAL capabilityPayload Data? JSON envelope (the production
    /// actor boundary now answers `Data?`, exactly what TerminalHostAPI
    /// decodes). Every field assertion below stays byte-for-byte unchanged;
    /// only the transport representation is decoded before asserting.
    private func decodeCapability(_ data: Data?) throws -> [String: Any] {
        let bytes = try XCTUnwrap(data, "capabilityPayload must answer with JSON bytes")
        let object = try JSONSerialization.jsonObject(with: bytes)
        return try XCTUnwrap(object as? [String: Any],
                             "capabilityPayload must decode as a JSON object")
    }

    // MARK: - File-backed original database helpers

    private func makeDatabase() async throws -> (DatabaseManager, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-language-settings-\(UUID().uuidString).sqlite")
        let manager = try DatabaseManager(path: url)
        try await manager.migrate()
        return (manager, url)
    }

    private func cleanup(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    private func rawRow(_ manager: DatabaseManager) async throws -> String? {
        try await manager.reader { db in
            try String.fetchOne(db,
                sql: "SELECT value_json FROM app_settings WHERE key = ?",
                arguments: [G04LanguageSettingsRecord.storageKey])
        }
    }

    // MARK: - Store: defaults, round trip, CAS, rollback

    func testLoadDefaultsWhenRowAbsent() async throws {
        let (db, url) = try await makeDatabase(); defer { cleanup(url) }
        let snapshot = try await G04LanguageSettingsStore(database: db).load()
        XCTAssertEqual(snapshot, .defaults)
        XCTAssertEqual(snapshot.revision, 0)
        XCTAssertEqual(Set(snapshot.enabled.keys),
                       Set(G04LanguageServerCatalog.servers.map { $0.languageID }))
        XCTAssertEqual(snapshot.enabled.count, 8)
        XCTAssertTrue(snapshot.enabled.values.allSatisfy { $0 })
        let absentRow = try await rawRow(db)
        XCTAssertNil(absentRow)
    }

    func testTogglePersistsThroughTheOriginalStoreAndRoundTrips() async throws {
        let (db, url) = try await makeDatabase(); defer { cleanup(url) }
        let store = G04LanguageSettingsStore(database: db)
        let committed = try await store.toggle(language: "css", enabled: false, expectedRevision: 0)
        XCTAssertEqual(committed.revision, 1)
        XCTAssertEqual(committed.enabled["css"], false)
        // The write landed on the ORIGINAL generic settings authority: the
        // exact row is readable through the untouched SQLiteSettingsStore.
        let raw = try await SQLiteSettingsStore(database: db)
            .value(forKey: G04LanguageSettingsRecord.storageKey)
        XCTAssertNotNil(raw)
        XCTAssertEqual(try G04LanguageSettingsCodec.decode(XCTUnwrap(raw)), committed)
        // A fresh store (new Root generation) reads the persisted truth back.
        let second = G04LanguageSettingsStore(database: db)
        let reloaded = try await second.load()
        XCTAssertEqual(reloaded, committed)
        XCTAssertEqual(reloaded.disabled, ["css"])
    }

    func testStaleRevisionRefusedWithZeroOverwrite() async throws {
        let (db, url) = try await makeDatabase(); defer { cleanup(url) }
        let store = G04LanguageSettingsStore(database: db)
        let first = try await store.toggle(language: "python", enabled: false, expectedRevision: 0)
        do {
            _ = try await store.toggle(language: "html", enabled: false, expectedRevision: 0)
            XCTFail("stale CAS token must refuse")
        } catch let error as G04LanguageSettingsError {
            XCTAssertEqual(error, .staleRevision)
        }
        // The row is EXACTLY the first committed snapshot; the refused
        // second write changed nothing (html still enabled).
        let raw = try await SQLiteSettingsStore(database: db)
            .value(forKey: G04LanguageSettingsRecord.storageKey)
        XCTAssertEqual(try G04LanguageSettingsCodec.decode(XCTUnwrap(raw)), first)
        XCTAssertEqual(first.enabled["html"], true)
    }

    func testFaultInsideTransactionRollsBackDurableBytes() async throws {
        let (db, url) = try await makeDatabase(); defer { cleanup(url) }
        let store = G04LanguageSettingsStore(database: db, faultInjection: { throw InjectedFault() })
        do {
            _ = try await store.toggle(language: "yaml", enabled: false, expectedRevision: 0)
            XCTFail("injected fault must fail the write")
        } catch let error as G04LanguageSettingsError {
            XCTAssertEqual(error, .persistenceUnavailable)
        }
        // REAL rollback: no row was committed (the upsert inside the failed
        // transaction left NOTHING behind).
        let rolledBackRaw = try await rawRow(db)
        let rolledBackViaStore = try await SQLiteSettingsStore(database: db)
            .value(forKey: G04LanguageSettingsRecord.storageKey)
        XCTAssertNil(rolledBackRaw)
        XCTAssertNil(rolledBackViaStore)
    }

    func testCorruptRowRefusesAndIsNeverBulldozed() async throws {
        let (db, url) = try await makeDatabase(); defer { cleanup(url) }
        try await SQLiteSettingsStore(database: db)
            .setValue("{not our record", forKey: G04LanguageSettingsRecord.storageKey)
        let store = G04LanguageSettingsStore(database: db)
        do {
            _ = try await store.load()
            XCTFail("a corrupt row must be typed, never treated as 'no user choice'")
        } catch let error as G04LanguageSettingsError {
            XCTAssertEqual(error, .corruptRecord)
        }
        do {
            _ = try await store.toggle(language: "json", enabled: true, expectedRevision: 0)
            XCTFail("toggle over a corrupt row must refuse")
        } catch let error as G04LanguageSettingsError {
            XCTAssertEqual(error, .corruptRecord)
        }
        // The unreadable row survives untouched: no silent reset wrote over
        // a state the app did not author.
        let corruptRaw = try await rawRow(db)
        XCTAssertEqual(corruptRaw, "{not our record")
    }

    func testUnknownLanguageRefusedWithoutAnyWrite() async throws {
        let (db, url) = try await makeDatabase(); defer { cleanup(url) }
        let store = G04LanguageSettingsStore(database: db)
        do {
            _ = try await store.toggle(language: "kotlin", enabled: false, expectedRevision: 0)
            XCTFail("whitelist must refuse non-catalog ids")
        } catch let error as G04LanguageSettingsError {
            XCTAssertEqual(error, .unknownLanguage)
        }
        let unknownRaw = try await rawRow(db)
        XCTAssertNil(unknownRaw)
    }

    // MARK: - Center: durable toggle, honest mirror, lifecycle apply

    private func makeCenter(_ store: G04LanguageSettingsStore, epoch: UInt64 = 9001)
        -> (G04LanguageServerCenter, RecordingLspSink) {
        let sink = RecordingLspSink()
        return (G04LanguageServerCenter(epoch: epoch, sink: sink, settingsStore: store), sink)
    }

    func testCenterToggleCommitsDurablyAndMirrorsOnlyCommittedState() async throws {
        let (db, url) = try await makeDatabase(); defer { cleanup(url) }
        let (center, sink) = makeCenter(G04LanguageSettingsStore(database: db))
        await center.setLanguageEnabled(language: "css", enabled: false, requestID: "t1")
        let reply = try XCTUnwrap(sink.reply(requestID: "t1"))
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["persisted"] as? Bool, true)
        XCTAssertEqual((reply["revision"] as? NSNumber)?.int64Value, 1)
        let payload = try decodeCapability(await center.capabilityPayload(conversationID: nil))
        XCTAssertEqual(payload["settingsKnown"] as? Bool, true)
        XCTAssertEqual((payload["settingsRevision"] as? NSNumber)?.int64Value, 1)
        let enabled = try XCTUnwrap(payload["languageEnabled"] as? [String: Bool])
        XCTAssertEqual(enabled["css"], false)
        XCTAssertEqual(enabled.count, 8)
        // Durable proof: the SAME canonical bytes through both entry points.
        let committedRaw = try await rawRow(db)
        let committedViaStore = try await SQLiteSettingsStore(database: db)
            .value(forKey: G04LanguageSettingsRecord.storageKey)
        XCTAssertEqual(committedRaw, committedViaStore)
        let decodedCommit = try G04LanguageSettingsCodec.decode(XCTUnwrap(committedRaw))
        XCTAssertEqual(decodedCommit.enabled["css"], false)
    }

    func testNextGenerationCenterReadsPersistedChoiceOnBind() async throws {
        let (db, url) = try await makeDatabase(); defer { cleanup(url) }
        let (first, firstSink) = makeCenter(G04LanguageSettingsStore(database: db), epoch: 9101)
        await first.setLanguageEnabled(language: "shell", enabled: false, requestID: "t")
        XCTAssertEqual(firstSink.reply(requestID: "t")?["ok"] as? Bool, true)
        // A brand-new center for the NEXT generation preloads from the same
        // durable row (load-on-Root-bind) — the user choice survives.
        let (second, _) = makeCenter(G04LanguageSettingsStore(database: db), epoch: 9102)
        await second.preloadSettings()
        let payload = try decodeCapability(await second.capabilityPayload(conversationID: nil))
        XCTAssertEqual(payload["settingsKnown"] as? Bool, true)
        let enabled = try XCTUnwrap(payload["languageEnabled"] as? [String: Bool])
        XCTAssertEqual(enabled["shell"], false)
    }

    func testStaleCenterMirrorIsRefusedAndKeepsLastKnownPersistedMirror() async throws {
        let (db, url) = try await makeDatabase(); defer { cleanup(url) }
        let store = G04LanguageSettingsStore(database: db)
        let (stale, staleSink) = makeCenter(store, epoch: 9201)
        let (fresh, _) = makeCenter(store, epoch: 9202)
        await stale.preloadSettings()                        // reads revision 0
        await fresh.setLanguageEnabled(language: "python", enabled: false, requestID: "p")
        await stale.setLanguageEnabled(language: "html", enabled: false, requestID: "h")
        let refusal = try XCTUnwrap(staleSink.reply(requestID: "h"))
        XCTAssertEqual(refusal["ok"] as? Bool, false)
        XCTAssertEqual(refusal["reason"] as? String, "staleRevision")
        // Rejected write leaked NOTHING into the mirror: it still shows the
        // revision it last saw, with html unchanged.
        let payload = try decodeCapability(await stale.capabilityPayload(conversationID: nil))
        XCTAssertEqual((payload["settingsRevision"] as? NSNumber)?.int64Value, 0)
        let enabled = try XCTUnwrap(payload["languageEnabled"] as? [String: Bool])
        XCTAssertEqual(enabled["html"], true)
        // The durable row is the FRESH commit, untouched by the refusal.
        let durableRaw = try await rawRow(db)
        let row = try G04LanguageSettingsCodec.decode(XCTUnwrap(durableRaw))
        XCTAssertEqual(row.revision, 1)
        XCTAssertEqual(row.enabled["python"], false)
        XCTAssertEqual(row.enabled["html"], true)
    }

    func testFailedWriteKeepsMirrorAndSurfacesTypedReason() async throws {
        let (db, url) = try await makeDatabase(); defer { cleanup(url) }
        let store = G04LanguageSettingsStore(database: db, faultInjection: { throw InjectedFault() })
        let (center, sink) = makeCenter(store)
        await center.setLanguageEnabled(language: "json", enabled: false, requestID: "f")
        let refusal = try XCTUnwrap(sink.reply(requestID: "f"))
        XCTAssertEqual(refusal["ok"] as? Bool, false)
        XCTAssertEqual(refusal["reason"] as? String, "persistenceUnavailable")
        let payload = try decodeCapability(await center.capabilityPayload(conversationID: nil))
        XCTAssertEqual(payload["settingsKnown"] as? Bool, true)   // the read DID succeed
        let enabled = try XCTUnwrap(payload["languageEnabled"] as? [String: Bool])
        XCTAssertEqual(enabled["json"], true)                     // unchanged mirror
        let failedWriteRaw = try await rawRow(db)
        XCTAssertNil(failedWriteRaw)                              // nothing persisted
    }

    func testUnknownAndRetiredTogglesRefuseWithoutDurableChange() async throws {
        let (db, url) = try await makeDatabase(); defer { cleanup(url) }
        let (center, sink) = makeCenter(G04LanguageSettingsStore(database: db))
        await center.setLanguageEnabled(language: "kotlin", enabled: false, requestID: "u")
        XCTAssertEqual(sink.reply(requestID: "u")?["code"] as? String, "languageUnsupported")
        await center.retireAll(reason: "test-retire")
        await center.setLanguageEnabled(language: "css", enabled: false, requestID: "r")
        XCTAssertEqual(sink.reply(requestID: "r")?["code"] as? String, "retired")
        let refusedRaw = try await rawRow(db)
        XCTAssertNil(refusedRaw)
    }

    func testDisabledChoiceRefusesEnsureAndEnableNeverAutoStarts() async throws {
        let (db, url) = try await makeDatabase(); defer { cleanup(url) }
        let (center, sink) = makeCenter(G04LanguageSettingsStore(database: db))
        await center.setLanguageEnabled(language: "css", enabled: false, requestID: "off")
        XCTAssertEqual(sink.reply(requestID: "off")?["ok"] as? Bool, true)
        let conversation = UUID()
        await center.ensureServer(conversationID: conversation, workspaceID: nil,
                                  language: "css", requestID: "e1")
        XCTAssertEqual(sink.reply(requestID: "e1")?["code"] as? String, "languageDisabled")
        await center.setLanguageEnabled(language: "css", enabled: true, requestID: "on")
        XCTAssertEqual(sink.reply(requestID: "on")?["ok"] as? Bool, true)
        // Enabling did NOT fabricate a server: without a live composition the
        // next ensure stops at admission, and no session state appears.
        await center.ensureServer(conversationID: conversation, workspaceID: nil,
                                  language: "css", requestID: "e2")
        XCTAssertEqual(sink.reply(requestID: "e2")?["code"] as? String, "workspaceUnbound")
        let payload = try decodeCapability(await center.capabilityPayload(conversationID: conversation))
        XCTAssertEqual((payload["serverStates"] as? [[String: Any]])?.count ?? -1, 0)
    }

    func testDisableSettlesLiveServerThroughOriginalClose() async throws {
        let (db, url) = try await makeDatabase(); defer { cleanup(url) }
        let transport = FakeLspTransport()
        let authority = FakeAuthority()
        let sink = RecordingLspSink()
        let conversation = UUID()
        let session = G04LanguageServerSession(conversationID: conversation, workspaceID: UUID(),
                                               languageID: "css", transport: transport,
                                               authority: authority, sink: sink)
        let (center, centerSink) = makeCenter(G04LanguageSettingsStore(database: db))
        await center.seedSessionForTests(session, conversationID: conversation, language: "css")
        await center.setLanguageEnabled(language: "css", enabled: false, requestID: "off")
        XCTAssertEqual(centerSink.reply(requestID: "off")?["persisted"] as? Bool, true)
        // The committed disable applied to the REAL lifecycle: explicit
        // shutdown/close rode the ORIGINAL transport close path (a stop
        // REQUEST; the original close owns settlement).
        XCTAssertTrue(transport.closed)
        // The session emits its OWN lifecycle states to the sink it was
        // constructed with (the center answers the toggle actionReply on
        // centerSink; lspStatus rides the session sink). Assert against the
        // real routing without weakening the final-state check.
        let finalStatus = try XCTUnwrap(sink.events(type: "lspStatus").last)
        XCTAssertEqual(finalStatus["code"] as? String, "language-disabled")
        XCTAssertEqual(finalStatus["state"] as? String, "stopped")
    }

    func testCapabilityPayloadHonestUnknownMirrorWithoutStore() async throws {
        // Production init with NO composition at all (this unit environment):
        // the mirror must answer settingsKnown=false + default-all-enabled,
        // never pretend a durable read happened.
        let sink = RecordingLspSink()
        let center = G04LanguageServerCenter(epoch: 9301, sink: sink)
        let payload = try decodeCapability(await center.capabilityPayload(conversationID: UUID()))
        XCTAssertEqual(payload["settingsKnown"] as? Bool, false)
        XCTAssertEqual((payload["settingsRevision"] as? NSNumber)?.int64Value, -1)
        let enabled = try? XCTUnwrap(payload["languageEnabled"] as? [String: Bool])
        XCTAssertEqual(enabled?.count, 8)
        XCTAssertTrue(enabled?.values.allSatisfy { $0 } ?? false)
        XCTAssertEqual((payload["serverStates"] as? [[String: Any]])?.count, 0)
    }
}
