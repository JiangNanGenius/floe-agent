// SPDX-License-Identifier: MPL-2.0
//
// Authored host tests for the P1 global-defaults adapter. These tests are
// SOURCE ONLY in this package: no compiler, SwiftPM, XCTest, device or runtime
// execution was performed by the authoring job. When Main admits compilation,
// they must run against the ORIGINAL file-backed DatabaseManager/migrations and
// the ORIGINAL SQLiteSettingsStore.

import XCTest
import Foundation
import GRDB
import FloeCore
import FloePersistence
@testable import FloeAndroidCore

final class SettingsDefaultsAdapterTests: XCTestCase {
    private struct RawRow: Equatable, Sendable {
        let value: String
        let updatedAt: String
    }

    private struct InjectedFailure: Error {}

    private enum SaveOutcome: Sendable {
        case success(SettingsDomainV1.DefaultsReply)
        case stale
        case failure
    }

    // MARK: - File-backed original database

    private func makeDatabase() async throws -> (DatabaseManager, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-settings-defaults-\(UUID().uuidString).sqlite")
        let manager = try DatabaseManager(path: url)
        try await manager.migrate()
        return (manager, url)
    }

    private func cleanup(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: url.path + suffix)
            )
        }
    }

    private func rawRows(_ manager: DatabaseManager) async throws -> [String: RawRow] {
        try await manager.reader { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT key, value_json, updated_at FROM app_settings"
            )
            var result: [String: RawRow] = [:]
            for row in rows {
                let key: String = row["key"]
                let value: String = row["value_json"]
                let updatedAt: String = row["updated_at"]
                result[key] = RawRow(value: value, updatedAt: updatedAt)
            }
            return result
        }
    }

    private func modelPreferencesRow(_ manager: DatabaseManager) async throws -> [String: String] {
        try await manager.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, onboarding_status, auxiliary_image_mode,
                           updated_at, sync_revision
                    FROM model_preferences WHERE id = 'default'
                    """
            ) else { return [:] }
            let syncRevision: Int = row["sync_revision"]
            return [
                "id": row["id"],
                "onboarding_status": row["onboarding_status"],
                "auxiliary_image_mode": row["auxiliary_image_mode"],
                "updated_at": row["updated_at"],
                "sync_revision": String(syncRevision),
            ]
        }
    }

    private func assertCorruptValue(_ key: String, _ json: String) async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        try await manager.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO app_settings (key, value_json, updated_at)
                    VALUES (?, ?, ?)
                    """,
                arguments: [key, json, "2026-10-19T08:00:00.123Z"]
            )
        }
        let adapter = FacadeSettingsDefaultsAdapter(database: manager)
        do {
            _ = try await adapter.read()
            XCTFail("corrupt row must not be silently defaulted: \(key)=\(json)")
        } catch let error as SettingsDefaultsAdapterError {
            XCTAssertEqual(error.wireCode, "persistenceUnavailable")
            XCTAssertEqual(error.wireReason, "corruptSettingsKey:\(key)")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - Absent / existing / explicit

    func testAbsentStateReturnsTypedDefaultsAndCanonicalDigest() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let adapter = FacadeSettingsDefaultsAdapter(database: manager)

        let reply = try await adapter.read()
        XCTAssertEqual(reply.values.defaultAgentMode, .human)
        XCTAssertEqual(reply.values.runningInputMode, .queue)
        XCTAssertEqual(reply.values.verifyFinalAnswer, false)
        XCTAssertFalse(reply.explicit.defaultAgentMode)
        XCTAssertFalse(reply.explicit.runningInputMode)
        XCTAssertFalse(reply.explicit.verifyFinalAnswer)

        let records: [[SettingsDomainV1.CanonicalDigest.Field]] =
            SettingsGlobalDefaultsKeys.whitelist.map {
                [.text($0), .integer(0), .null, .null]
            }
        XCTAssertEqual(
            reply.revision,
            SettingsDomainV1.CanonicalDigest.token(
                domain: SettingsDomainV1.CanonicalDigest.domainSettingsDefaults,
                records: records
            )
        )
    }

    func testOriginalStoreRowsDecodeWithExplicitFlagsAndFractionalTimestamp() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = SQLiteSettingsStore(database: manager)
        try await store.setValue(FloeCore.AgentMode.approvalModel,
                                 forKey: AppSettingsKey.defaultAgentMode)
        try await store.setValue(FloeCore.RunningInputMode.steer,
                                 forKey: AppSettingsKey.runningInputMode)
        try await store.setValue(true,
                                 forKey: AppSettingsKey.verifyFinalAnswer)

        let adapter = FacadeSettingsDefaultsAdapter(database: manager)
        let reply = try await adapter.read()
        XCTAssertEqual(reply.values.defaultAgentMode, .approvalModel)
        XCTAssertEqual(reply.values.runningInputMode, .steer)
        XCTAssertEqual(reply.values.verifyFinalAnswer, true)
        XCTAssertTrue(reply.explicit.defaultAgentMode)
        XCTAssertTrue(reply.explicit.runningInputMode)
        XCTAssertTrue(reply.explicit.verifyFinalAnswer)

        let rows = try await rawRows(manager)
        let updatedAt = try XCTUnwrap(rows[AppSettingsKey.defaultAgentMode]?.updatedAt)
        XCTAssertNotNil(
            updatedAt.range(
                of: #"T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#,
                options: .regularExpression
            ),
            "updated_at must use PersistenceCodec fractional-second ISO-8601: \(updatedAt)"
        )
    }

    func testSaveWritesOnlyRequestedKeyAndNativeBytesAreReadable() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = SQLiteSettingsStore(database: manager)
        try await store.setValue(FloeCore.AgentMode.human,
                                 forKey: AppSettingsKey.defaultAgentMode)
        try await store.setValue(false,
                                 forKey: AppSettingsKey.verifyFinalAnswer)

        let adapter = FacadeSettingsDefaultsAdapter(database: manager)
        let before = try await rawRows(manager)
        let first = try await adapter.read()
        let saved = try await adapter.save(
            expectedRevision: first.revision,
            patch: SettingsDefaultsPatch(runningInputMode: .steer)
        )
        XCTAssertEqual(saved.values.defaultAgentMode, .human)
        XCTAssertEqual(saved.values.runningInputMode, .steer)
        XCTAssertEqual(saved.values.verifyFinalAnswer, false)
        XCTAssertTrue(saved.explicit.defaultAgentMode)
        XCTAssertTrue(saved.explicit.runningInputMode)
        XCTAssertTrue(saved.explicit.verifyFinalAnswer)

        let typed: FloeCore.RunningInputMode? = try await store.value(
            forKey: AppSettingsKey.runningInputMode,
            as: FloeCore.RunningInputMode.self
        )
        XCTAssertEqual(typed, .steer)
        let after = try await rawRows(manager)
        XCTAssertEqual(after[AppSettingsKey.defaultAgentMode],
                       before[AppSettingsKey.defaultAgentMode])
        XCTAssertEqual(after[AppSettingsKey.verifyFinalAnswer],
                       before[AppSettingsKey.verifyFinalAnswer])
        XCTAssertNotEqual(after[AppSettingsKey.runningInputMode],
                          before[AppSettingsKey.runningInputMode])
    }

    func testExplicitDefaultStoredDiffersFromAbsentState() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let adapter = FacadeSettingsDefaultsAdapter(database: manager)
        let absent = try await adapter.read()
        let saved = try await adapter.save(
            expectedRevision: absent.revision,
            patch: SettingsDefaultsPatch(defaultAgentMode: .human)
        )
        XCTAssertTrue(saved.explicit.defaultAgentMode)
        XCTAssertFalse(saved.explicit.runningInputMode)
        XCTAssertFalse(saved.explicit.verifyFinalAnswer)
        XCTAssertNotEqual(saved.revision, absent.revision)
        let rows = try await rawRows(manager)
        XCTAssertEqual(rows[AppSettingsKey.defaultAgentMode]?.value, "\"human\"")
    }

    func testSaveSameValuesIsNoOpAndKeepsTimestamp() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = SQLiteSettingsStore(database: manager)
        try await store.setValue(FloeCore.AgentMode.approvalModel,
                                 forKey: AppSettingsKey.defaultAgentMode)
        try await store.setValue(FloeCore.RunningInputMode.steer,
                                 forKey: AppSettingsKey.runningInputMode)
        try await store.setValue(true,
                                 forKey: AppSettingsKey.verifyFinalAnswer)

        let adapter = FacadeSettingsDefaultsAdapter(database: manager)
        let first = try await adapter.read()
        let before = try await rawRows(manager)
        let saved = try await adapter.save(
            expectedRevision: first.revision,
            patch: SettingsDefaultsPatch(
                defaultAgentMode: .approvalModel,
                runningInputMode: .steer,
                verifyFinalAnswer: true
            )
        )
        XCTAssertEqual(saved.revision, first.revision)
        let after = try await rawRows(manager)
        XCTAssertEqual(after, before)
    }

    // MARK: - Corrupt / typed persistence failure

    func testCorruptPresentRowIsTypedPersistenceUnavailable() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        try await manager.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO app_settings (key, value_json, updated_at)
                    VALUES (?, ?, ?)
                    """,
                arguments: [AppSettingsKey.runningInputMode, "not-json",
                            "2026-10-19T08:00:00.123Z"]
            )
        }
        let adapter = FacadeSettingsDefaultsAdapter(database: manager)
        do {
            _ = try await adapter.read()
            XCTFail("a corrupt whitelist row must not be silently defaulted")
        } catch let error as SettingsDefaultsAdapterError {
            XCTAssertEqual(error.wireCode, "persistenceUnavailable")
            XCTAssertEqual(error.wireReason,
                           "corruptSettingsKey:\(AppSettingsKey.runningInputMode)")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testPresentNullAndWrongTypesAreCorrupt() async throws {
        try await assertCorruptValue(AppSettingsKey.defaultAgentMode, "null")
        try await assertCorruptValue(AppSettingsKey.defaultAgentMode, "1")
        try await assertCorruptValue(AppSettingsKey.defaultAgentMode, "\"Human\"")
        try await assertCorruptValue(AppSettingsKey.runningInputMode, "null")
        try await assertCorruptValue(AppSettingsKey.runningInputMode, "1")
        try await assertCorruptValue(AppSettingsKey.verifyFinalAnswer, "null")
        try await assertCorruptValue(AppSettingsKey.verifyFinalAnswer, "1")
        try await assertCorruptValue(AppSettingsKey.verifyFinalAnswer, "\"true\"")
    }

    func testNonWhitelistedCorruptRowIsIgnored() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        try await manager.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO app_settings (key, value_json, updated_at)
                    VALUES (?, ?, ?)
                    """,
                arguments: ["speech.rate", "not-json", "2026-10-19T08:00:00.123Z"]
            )
        }
        let adapter = FacadeSettingsDefaultsAdapter(database: manager)
        let reply = try await adapter.read()
        XCTAssertFalse(reply.explicit.defaultAgentMode)
        XCTAssertFalse(reply.explicit.runningInputMode)
        XCTAssertFalse(reply.explicit.verifyFinalAnswer)
    }

    // MARK: - Canonical digest

    func testDigestUsesExactRawTextAndTimestamp() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let updatedAt = "2026-10-19T08:00:00.123Z"
        try await manager.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO app_settings (key, value_json, updated_at)
                    VALUES (?, ?, ?)
                    """,
                arguments: [AppSettingsKey.defaultAgentMode, "\"human\" ", updatedAt]
            )
        }
        let adapter = FacadeSettingsDefaultsAdapter(database: manager)
        let reply = try await adapter.read()
        let expected: [[SettingsDomainV1.CanonicalDigest.Field]] = [
            [.text(AppSettingsKey.defaultAgentMode), .integer(1),
             .text("\"human\" "), .text(updatedAt)],
            [.text(AppSettingsKey.runningInputMode), .integer(0), .null, .null],
            [.text(AppSettingsKey.verifyFinalAnswer), .integer(0), .null, .null],
        ]
        XCTAssertEqual(
            reply.revision,
            SettingsDomainV1.CanonicalDigest.token(
                domain: SettingsDomainV1.CanonicalDigest.domainSettingsDefaults,
                records: expected
            )
        )

        try await manager.writer { db in
            try db.execute(
                sql: "UPDATE app_settings SET value_json = ? WHERE key = ?",
                arguments: ["\"human\"", AppSettingsKey.defaultAgentMode]
            )
        }
        let second = try await adapter.read()
        XCTAssertNotEqual(second.revision, reply.revision)
        XCTAssertEqual(second.values.defaultAgentMode, .human)
    }

    func testCanonicalDigestSharedVectorsAtAdapterBoundary() {
        let domain = SettingsDomainV1.CanonicalDigest.domainSettingsDefaults
        func token(_ fields: [SettingsDomainV1.CanonicalDigest.Field]) -> String {
            SettingsDomainV1.CanonicalDigest.rowToken(domain: domain, fields: fields)
        }
        XCTAssertNotEqual(token([.null]), token([.text("NULL")]))
        XCTAssertNotEqual(token([.text("NULL")]), token([.text("<null>")]))
        XCTAssertNotEqual(token([.text("<null>")]), token([.text("")]))
        XCTAssertNotEqual(token([.text("a\u{1F}b")]),
                          token([.text("a"), .text("b")]))
        XCTAssertNotEqual(token([.text("a|b")]),
                          token([.text("a"), .text("b")]))
        XCTAssertNotEqual(token([.integer(1)]), token([.real(1.0)]))
        XCTAssertNotEqual(token([.integer(1)]), token([.text("1")]))
        XCTAssertNotEqual(token([.real(-0.0)]), token([.real(0.0)]))
        XCTAssertEqual(token([.text("记忆 🧪")]), token([.text("记忆 🧪")]))
    }

    // MARK: - CAS / concurrency / same-second

    func testStaleRevisionWritesNothing() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = SQLiteSettingsStore(database: manager)
        try await store.setValue(FloeCore.AgentMode.human,
                                 forKey: AppSettingsKey.defaultAgentMode)
        let adapter = FacadeSettingsDefaultsAdapter(database: manager)
        let first = try await adapter.read()

        try await manager.writer { db in
            try db.execute(
                sql: "UPDATE app_settings SET value_json = ? WHERE key = ?",
                arguments: ["\"approvalModel\"", AppSettingsKey.defaultAgentMode]
            )
        }
        let before = try await rawRows(manager)
        do {
            _ = try await adapter.save(
                expectedRevision: first.revision,
                patch: SettingsDefaultsPatch(verifyFinalAnswer: true)
            )
            XCTFail("stale expected revision must be rejected")
        } catch let error as SettingsDefaultsAdapterError {
            XCTAssertEqual(error, .staleRevision)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        let after = try await rawRows(manager)
        XCTAssertEqual(after, before)
        XCTAssertEqual(before[AppSettingsKey.defaultAgentMode]?.value,
                       "\"approvalModel\"")
    }

    func testSameUpdatedAtRawRowChangeStillInvalidatesDigest() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = SQLiteSettingsStore(database: manager)
        try await store.setValue(FloeCore.AgentMode.human,
                                 forKey: AppSettingsKey.defaultAgentMode)
        let adapter = FacadeSettingsDefaultsAdapter(database: manager)
        let first = try await adapter.read()
        let before = try await rawRows(manager)
        let timestamp = try XCTUnwrap(before[AppSettingsKey.defaultAgentMode]?.updatedAt)

        // Same second/timestamp, different raw row: a timestamp-only CAS would
        // accept this; the canonical row digest must reject it.
        try await manager.writer { db in
            try db.execute(
                sql: """
                    UPDATE app_settings SET value_json = ?
                    WHERE key = ? AND updated_at = ?
                    """,
                arguments: ["\"fullControl\"", AppSettingsKey.defaultAgentMode, timestamp]
            )
        }
        do {
            _ = try await adapter.save(
                expectedRevision: first.revision,
                patch: SettingsDefaultsPatch(runningInputMode: .steer)
            )
            XCTFail("same-timestamp raw row change must be stale")
        } catch let error as SettingsDefaultsAdapterError {
            XCTAssertEqual(error, .staleRevision)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        let after = try await rawRows(manager)
        XCTAssertEqual(after[AppSettingsKey.defaultAgentMode]?.updatedAt, timestamp)
        XCTAssertEqual(after[AppSettingsKey.defaultAgentMode]?.value, "\"fullControl\"")
    }

    func testConcurrentSavesWithSameRevisionCommitExactlyOne() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let adapter = FacadeSettingsDefaultsAdapter(database: manager)
        let first = try await adapter.read()
        let revision = first.revision

        let outcomes: [SaveOutcome] = await withTaskGroup(of: SaveOutcome.self) { group in
            group.addTask {
                do {
                    return .success(try await adapter.save(
                        expectedRevision: revision,
                        patch: SettingsDefaultsPatch(verifyFinalAnswer: true)
                    ))
                } catch SettingsDefaultsAdapterError.staleRevision {
                    return .stale
                } catch {
                    return .failure
                }
            }
            group.addTask {
                do {
                    return .success(try await adapter.save(
                        expectedRevision: revision,
                        patch: SettingsDefaultsPatch(verifyFinalAnswer: false)
                    ))
                } catch SettingsDefaultsAdapterError.staleRevision {
                    return .stale
                } catch {
                    return .failure
                }
            }
            var result: [SaveOutcome] = []
            for await outcome in group { result.append(outcome) }
            return result
        }

        var winners: [SettingsDomainV1.DefaultsReply] = []
        var stale = 0
        for outcome in outcomes {
            switch outcome {
            case .success(let reply):
                winners.append(reply)
            case .stale:
                stale += 1
            case .failure:
                XCTFail("a concurrent save failed without a typed CAS outcome")
            }
        }
        XCTAssertEqual(winners.count, 1)
        XCTAssertEqual(stale, 1)
        let final = try await adapter.read()
        guard let winner = winners.first else {
            XCTFail("no successful concurrent save")
            return
        }
        XCTAssertEqual(final.values.verifyFinalAnswer,
                       winner.values.verifyFinalAnswer)
        XCTAssertEqual(final.explicit.verifyFinalAnswer, true)
    }

    func testWriterFailureRollsBackEveryKey() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = SQLiteSettingsStore(database: manager)
        try await store.setValue(FloeCore.AgentMode.human,
                                 forKey: AppSettingsKey.defaultAgentMode)
        try await store.setValue(false,
                                 forKey: AppSettingsKey.verifyFinalAnswer)
        let adapter = FacadeSettingsDefaultsAdapter(database: manager)
        let first = try await adapter.read()
        let before = try await rawRows(manager)

        let faulty = FacadeSettingsDefaultsAdapter(
            database: manager,
            faultInjection: { writeCount in
                if writeCount == 1 { throw InjectedFailure() }
            }
        )
        do {
            _ = try await faulty.save(
                expectedRevision: first.revision,
                patch: SettingsDefaultsPatch(
                    defaultAgentMode: .approvalModel,
                    verifyFinalAnswer: true
                )
            )
            XCTFail("injected writer failure must surface")
        } catch let error as SettingsDefaultsAdapterError {
            XCTAssertEqual(error.wireCode, "persistenceUnavailable")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        let rolledBackRows = try await rawRows(manager)
        XCTAssertEqual(rolledBackRows, before)
        let after = try await adapter.read()
        XCTAssertEqual(after.values, first.values)
        XCTAssertEqual(after.revision, first.revision)
    }

    // MARK: - Isolation / commit visibility / validation

    func testUnrelatedModelPreferencesAndSettingsStayByteIdentical() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        try await manager.writer { db in
            try db.execute(sql: """
                UPDATE model_preferences
                SET onboarding_status = 'ready', sync_revision = 7,
                    updated_at = 'fixed-model-preferences-row'
                WHERE id = 'default'
                """)
            try db.execute(
                sql: """
                    INSERT INTO app_settings (key, value_json, updated_at)
                    VALUES (?, ?, ?)
                    """,
                arguments: ["speech.rate", "0.5", "fixed-speech-row"]
            )
        }
        let beforePreferences = try await modelPreferencesRow(manager)
        let beforeRows = try await rawRows(manager)
        let adapter = FacadeSettingsDefaultsAdapter(database: manager)
        let first = try await adapter.read()
        _ = try await adapter.save(
            expectedRevision: first.revision,
            patch: SettingsDefaultsPatch(
                defaultAgentMode: .fullControl,
                runningInputMode: .steer,
                verifyFinalAnswer: true
            )
        )
        let afterPreferences = try await modelPreferencesRow(manager)
        XCTAssertEqual(afterPreferences, beforePreferences)
        let afterRows = try await rawRows(manager)
        XCTAssertEqual(afterRows["speech.rate"], beforeRows["speech.rate"])
    }

    func testCommittedSaveIsVisibleToSecondConnection() async throws {
        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let adapter = FacadeSettingsDefaultsAdapter(database: manager)
        let first = try await adapter.read()
        _ = try await adapter.save(
            expectedRevision: first.revision,
            patch: SettingsDefaultsPatch(verifyFinalAnswer: true)
        )

        let second = try DatabaseManager(path: url)
        try await second.migrate()
        let secondAdapter = FacadeSettingsDefaultsAdapter(database: second)
        let reply = try await secondAdapter.read()
        XCTAssertEqual(reply.values.verifyFinalAnswer, true)
        XCTAssertTrue(reply.explicit.verifyFinalAnswer)
    }

    func testSavePayloadValidationRejectsBeforeEffect() async throws {
        func reason(_ value: SettingsDomainV1.JSONValue) -> String? {
            do {
                _ = try SettingsDefaultsPatch.parse(value)
                return nil
            } catch let error as SettingsDefaultsAdapterError {
                return error.wireReason
            } catch {
                return "unexpected"
            }
        }

        XCTAssertEqual(
            reason(.object(["values": .object(["extra": .boolean(true)])])),
            "unknownDefaultsField"
        )
        XCTAssertEqual(
            reason(.object(["values": .object(["defaultAgentMode": .string("god")])])),
            "invalidDefaultsValue:defaultAgentMode"
        )
        XCTAssertEqual(
            reason(.object(["values": .object(["verifyFinalAnswer": .integer(1)])])),
            "invalidDefaultsValue:verifyFinalAnswer"
        )
        XCTAssertEqual(
            reason(.object(["values": .object([:])])),
            "invalidPayloadField:values"
        )

        let (manager, url) = try await makeDatabase()
        defer { cleanup(url) }
        let adapter = FacadeSettingsDefaultsAdapter(database: manager)
        let first = try await adapter.read()
        do {
            _ = try await adapter.save(expectedRevision: first.revision,
                                       patch: SettingsDefaultsPatch())
            XCTFail("empty patch must be rejected")
        } catch let error as SettingsDefaultsAdapterError {
            XCTAssertEqual(error.wireReason, "invalidPayloadField:values")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        let rows = try await rawRows(manager)
        XCTAssertTrue(rows.isEmpty)
    }
}
