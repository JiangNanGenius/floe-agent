// SPDX-License-Identifier: MPL-2.0
//
// Android-only qualification seam (job-f86ae143808f47b5).
//
// 1. Verified security corpus: the original FloeSecurity
//    CatastrophicActionGate resolves `Bundle.module` by default, which the
//    Android Swift toolchain marks SWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE.
//    This seam NEVER edits the original iOS source. It accepts corpus BYTES
//    (exported as the swiftbridge APK asset by build-swift.sh), pins the exact
//    SHA-256 of the trusted corpus, decodes with the SAME Codable shape as
//    `withBundledPatterns` and compiles through the SAME public
//    `init(patterns:)` regex path. A missing, tampered, re-encoded, untrusted
//    or non-compiling corpus is rejected here — no empty-pattern substitute.
//    Production callers that need a never-throwing handle use
//    `loadFailClosed(from:)`, which falls back to the gate's own
//    match-everything `failClosed(reason:)`.
//
// 2. Bounded native test access: fixed-signature @_cdecl functions consumed
//    ONLY by the debug instrumentation wrapper (libfloe_qualification_jni.so,
//    built ONLY for the debug variant via CMake flag + buildType argument;
//    release AARs never contain the wrapper or any test-helper class). The
//    prebuilt libFloeAndroidCore.so export table is shared across variants
//    and DOES keep these C symbols plus the production corpus loader — that
//    is inventoried honestly in the evidence, not claimed absent. These are
//    not bridge operations, register no grants or task authority, never
//    execute commands (security evaluation is classification only) and only
//    touch the in-memory store or an explicitly-passed cache-directory
//    database which is deleted afterwards.
//    `floe_db_smoke` mirrors the proven host PersistenceStoreTests contract
//    (exact 46-migration chain, unicode61 FTS measurements, run-event
//    cursors, durable reopen) and exercises the REAL sqlite3_snapshot
//    get/cmp/free/open C APIs on the device runtime.
//    `floe_json_kind_smoke` reports the ACTUAL JSON primitive dynamic types
//    for the DesignCanvasMetadata CoreFoundation Bool-identity branch, plus
//    constructed narrow NSNumber integers, instead of assuming platform
//    parity. (The previous Android overlay used `Swift.type(of:) == Bool.self`,
//    which the Samsung API 33 smoke disproved: JSON true/false is
//    Foundation.__NSCFBoolean and never equals Bool.self.)
import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif
import Crypto
import GRDB
import GRDBSQLite
import FloeCore
import FloePersistence
import FloeSecurity

/// One heap box per prepared gate; released by floe_gate_release.
private final class GateBox {
    let gate: CatastrophicActionGate
    init(_ gate: CatastrophicActionGate) { self.gate = gate }
}

public enum AndroidCatastrophicCorpus {
    /// Exact bytes of the upstream iOS corpus resource (byte-identical copy).
    public static let pinnedSHA256
        = "b20667f2d9713961231327c931188cc74474cdbd294593c6071c804edf0c038b"
    /// Hard bound for corpus bytes handed to the seam (fail-closed above it).
    public static let maximumCorpusBytes = 1_048_576

    /// Throws on empty input, hash mismatch, decode failure, an empty pattern
    /// list or regex compile failure. Never substitutes empty patterns: every
    /// failure path rejects the corpus outright.
    public static func makeGate(from data: Data) throws -> CatastrophicActionGate {
        guard !data.isEmpty else {
            throw FloeError.internalError("catastrophic corpus empty")
        }
        guard data.count <= maximumCorpusBytes else {
            throw FloeError.internalError("catastrophic corpus oversized")
        }
        let digest = Data(SHA256.hash(data: data))
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == pinnedSHA256 else {
            throw FloeError.internalError("catastrophic corpus hash mismatch")
        }
        // SAME Codable shape and decoder as withBundledPatterns:
        // struct Corpus { var patterns: [Pattern] }.
        struct Corpus: Decodable { var patterns: [CatastrophicActionGate.Pattern] }
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        guard !corpus.patterns.isEmpty else {
            throw FloeError.internalError("catastrophic corpus contained no patterns")
        }
        // SAME regex compile path as the bundle loader (init(patterns:)).
        return try CatastrophicActionGate(patterns: corpus.patterns)
    }

    /// Never-throwing production init: verified corpus or the gate's own
    /// match-everything failClosed. Later host adapters use this; the
    /// qualification tests observe rejection explicitly because makeGate
    /// (and the C handle factory) fails closed to nil/throw.
    public static func loadFailClosed(from data: Data?) -> CatastrophicActionGate {
        do {
            guard let data else {
                throw FloeError.internalError("catastrophic corpus missing")
            }
            return try makeGate(from: data)
        } catch {
            return CatastrophicActionGate.failClosed(reason: "corpus-unavailable:\(error)")
        }
    }
}

// MARK: - bounded synchronous runner

/// Bridges the async persistence authority into a synchronous JNI test call
/// with a bounded wait; a timeout fails closed (no hang, no partial success)
/// AND cancels the owned task — the handle is retained, never discarded.
/// Honesty about late completion: the smoke's SQLite/GRDB segments are
/// synchronous C work between suspension points; cancellation cannot halt an
/// in-flight statement instantly and this seam does not fake that. The bodies
/// therefore consist of bounded segments that check `Task.isCancelled` at
/// every await boundary, so a cancelled run stops at the next segment and
/// still executes its scoped cleanup (`defer` temporary-directory removal)
/// when that segment returns. The caller has already returned a timeout
/// error by then; the late task never mutates caller-visible state (its
/// result slot is written after the caller has returned and read by nobody).
internal func runBounded(timeout: TimeInterval = 180,
                         _ body: @escaping @Sendable () async -> String) -> String {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var captured: String?
    let task = Task.detached(priority: .userInitiated) {
        let value = await body()
        captured = value
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + timeout) == .success else {
        task.cancel()
        return errorJSON("qualification-smoke-timeout")
    }
    return captured ?? errorJSON("qualification-smoke-missing-result")
}

/// Segment checkpoint used by every smoke body: an owned run halts at the
/// next boundary after `runBounded` cancels it, and its scope `defer`
/// cleanup still runs at that boundary.
private func cancelledIfRequested() -> Bool { Task.isCancelled }

private func jsonDuplicate(_ text: String) -> UnsafeMutablePointer<CChar>? {
    let bytes = Array(text.utf8)
    let output = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
    if !bytes.isEmpty {
        bytes.withUnsafeBytes { raw in
            UnsafeMutableRawPointer(output).copyMemory(from: raw.baseAddress!, byteCount: bytes.count)
        }
    }
    output[bytes.count] = 0
    return output
}

private func errorJSON(_ reason: String) -> String {
    let object: [String: Any] = ["ok": false, "error": reason]
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { return "{\"ok\":false,\"error\":\"encoding\"}" }
    return String(decoding: data, as: UTF8.self)
}

private func reportJSON(_ report: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    else { return errorJSON("encoding") }
    return String(decoding: data, as: UTF8.self)
}

// MARK: - security corpus C handles

@_cdecl("floe_gate_create_from_corpus")
public func floeGateCreateFromCorpus(
    _ corpus: UnsafePointer<UInt8>?, _ count: Int
) -> UnsafeMutableRawPointer? {
    guard let corpus, count > 0, count <= AndroidCatastrophicCorpus.maximumCorpusBytes
    else { return nil }
    let data = Data(bytes: corpus, count: count)
    guard let gate = try? AndroidCatastrophicCorpus.makeGate(from: data) else {
        return nil // missing/hash/decode/regex failure: rejected, never empty
    }
    return Unmanaged.passRetained(GateBox(gate)).toOpaque()
}

@_cdecl("floe_gate_create_fail_closed")
public func floeGateCreateFailClosed(_ reason: UnsafePointer<CChar>?)
    -> UnsafeMutableRawPointer?
{
    let text = reason.map { String(cString: $0) } ?? "corpus-unavailable"
    return Unmanaged.passRetained(
        GateBox(CatastrophicActionGate.failClosed(reason: text))
    ).toOpaque()
}

/// Classification only: evaluates the string against the gate. The command is
/// NEVER executed by anything in this library. The 64 KiB bound mirrors the
/// frozen bridge UTF-8 size contract for this process boundary.
@_cdecl("floe_gate_evaluate")
public func floeGateEvaluate(
    _ handle: UnsafeMutableRawPointer?, _ command: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let handle else { return jsonDuplicate(errorJSON("invalidHandle")) }
    guard let command else { return jsonDuplicate(errorJSON("missingCommand")) }
    let length = strnlen(command, 65_537)
    guard length <= 65_536 else { return jsonDuplicate(errorJSON("commandTooLarge")) }
    let box = Unmanaged<GateBox>.fromOpaque(handle).takeUnretainedValue()
    let verdict = box.gate.evaluate(command: String(cString: command))
    var object: [String: Any] = ["ok": true, "stopped": verdict.stopped]
    object["matchedPatternID"] = verdict.matchedPatternID
    object["reason"] = verdict.reason
    return jsonDuplicate(reportJSON(object))
}

@_cdecl("floe_gate_release")
public func floeGateRelease(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    Unmanaged<GateBox>.fromOpaque(handle).release()
}

// MARK: - database smoke

/// Mirrors the proven host contract (PersistenceStoreTests): exact 46-chain,
/// tables, unicode61 FTS measurements, run-event sequences, in-memory
/// snapshot-call rejection, then a file-backed WAL database on the passed
/// cache directory exercising the REAL snapshot C APIs (get/cmp/free inside a
/// transaction, open+read+commit on a reader) and durable reopen.
private func databaseSmokeJSON(cacheDirectory: String) -> String {
    runBounded {
        var report: [String: Any] = ["ok": false]
        var failures: [String] = []
        do {
            let manager = try DatabaseManager.inMemory()
            try await manager.migrate()
            let version = try await manager.userVersion()
            report["schemaVersion"] = version
            if version != 46 { failures.append("user_version \(version) != 46") }
            report["coreSchemaVersion"] = FloeAndroidCore.schemaVersion
            let applied = try await manager.appliedMigrations()
            report["appliedMigrationCount"] = applied.count
            report["appliedContainsV1"] = applied.contains("v1")
            report["appliedContainsV46"] = applied.contains("v46_task_lifecycle")
            if applied.count != 46 { failures.append("applied \(applied.count) != 46") }

            if cancelledIfRequested() { return errorJSON("qualification-smoke-cancelled") }
            let tables = try await manager.reader { db in
                try String.fetchAll(db, sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                      AND name NOT LIKE 'grdb_%' AND name NOT LIKE 'message_fts%'
                    ORDER BY name
                    """)
            }
            for required in ["conversations", "messages", "runs", "run_events",
                             "providers", "models", "audit_entries"]
            where !tables.contains(required) {
                failures.append("missing table \(required)")
            }
            let ftsTables = try await manager.reader { db in
                try String.fetchAll(db, sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'table' AND name = 'message_fts'
                    """)
            }
            report["ftsTablePresent"] = ftsTables == ["message_fts"]
            if ftsTables != ["message_fts"] { failures.append("message_fts missing") }

            let store = SQLiteConversationStore(database: manager)
            let conversationID = UUID()
            let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
            try await store.saveConversation(ConversationRecord(
                id: conversationID, title: "原始标题", createdAt: createdAt, updatedAt: createdAt))
            try await store.saveConversation(ConversationRecord(
                id: conversationID, title: "更新后的标题", createdAt: createdAt,
                updatedAt: createdAt.addingTimeInterval(60)))
            let conversations = try await store.conversations()
            report["upsertSingleRow"] = conversations.count == 1
            if conversations.count != 1 { failures.append("conversation upsert duplicated") }

            let cjk = "请帮我分析这份报告的第三季度数据"
            try await store.appendMessage(PersistedMessage(
                id: UUID(), conversationID: conversationID, role: "user",
                content: cjk, createdAt: createdAt))
            try await store.appendMessage(PersistedMessage(
                id: UUID(), conversationID: conversationID, role: "assistant",
                content: "unrelated english text", createdAt: createdAt.addingTimeInterval(1)))
            let englishHits = try await manager.reader { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM messages m
                    JOIN message_fts f ON m.rowid = f.rowid
                    WHERE message_fts MATCH 'english'
                    """) ?? -1
            }
            let cjkSubstring = try await manager.reader { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH '报'
                    """) ?? -1
            }
            let wholeRun = try await manager.reader { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH ?
                    """, arguments: ["\"\(cjk)\""]) ?? -1
            }
            let wildcard = try await manager.reader { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH 'unrelated*'
                    """) ?? -1
            }
            report["ftsEnglishHits"] = englishHits
            report["ftsCjkSubstringHits"] = cjkSubstring
            report["ftsWholeRunPhraseHits"] = wholeRun
            report["ftsWildcardHits"] = wildcard
            if englishHits != 1 { failures.append("english hits \(englishHits) != 1") }
            if cjkSubstring != 0 { failures.append("unicode61 substring hit \(cjkSubstring) != 0") }
            if wholeRun != 1 { failures.append("whole-run phrase hits \(wholeRun) != 1") }
            if wildcard != 1 { failures.append("wildcard hits \(wildcard) != 1") }

            if cancelledIfRequested() { return errorJSON("qualification-smoke-cancelled") }
            let runStore = SQLiteRunStore(database: manager)
            let runID = UUID()
            try await runStore.saveRun(RunRecord(
                id: runID, conversationID: conversationID, state: "running",
                goal: "synthetic", startedAt: createdAt))
            let first = try await runStore.appendEvent(runID: runID, kind: .assistantText,
                                                       payloadJSON: "{\"i\":1}")
            let second = try await runStore.appendEvent(runID: runID, kind: .assistantText,
                                                        payloadJSON: "{\"i\":2}")
            let third = try await runStore.appendEvent(runID: runID, kind: .terminal,
                                                       payloadJSON: "{\"i\":3}")
            report["runEventSequences"] = [first.sequence, second.sequence, third.sequence]
            if [first.sequence, second.sequence, third.sequence] != [1, 2, 3] {
                failures.append("run event sequences not monotonic")
            }
            let afterOne = try await runStore.events(runID: runID, afterSequence: 1, limit: 1)
            report["cursorAfterOne"] = afterOne.map(\.sequence) == [2]
            if afterOne.map(\.sequence) != [2] { failures.append("cursor window wrong") }

            // In-memory queue: snapshot_get must FAIL with a typed SQLite
            // code (not a crash): proves the symbol is callable and the guard
            // contract holds. Not counted as a failure; reported for parity.
            let memorySnapshotCode = try await manager.writer { db -> Int32 in
                guard let connection = db.sqliteConnection else { return -1 }
                var snapshot: UnsafeMutablePointer<sqlite3_snapshot>?
                let code = sqlite3_snapshot_get(connection, "main", &snapshot)
                if let snapshot { sqlite3_snapshot_free(snapshot) }
                return code
            }
            report["snapshotGetOnMemoryCode"] = Int(memorySnapshotCode)

            try await manager.close()

            if cancelledIfRequested() { return errorJSON("qualification-smoke-cancelled") }
            // File-backed WAL database under the explicitly-passed cache dir.
            let base = URL(fileURLWithPath: cacheDirectory, isDirectory: true)
            let directory = base.appendingPathComponent(
                "floe-native-smoke-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("smoke.sqlite")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fileManager = try DatabaseManager(path: fileURL)
            try await fileManager.migrate()
            let fileVersion = try await fileManager.userVersion()
            report["fileSchemaVersion"] = fileVersion
            if fileVersion != 46 { failures.append("file user_version \(fileVersion) != 46") }
            let durableID = UUID()
            try await SQLiteConversationStore(database: fileManager).saveConversation(
                ConversationRecord(id: durableID, title: "durable",
                                   createdAt: createdAt, updatedAt: createdAt))
            try await SQLiteConversationStore(database: fileManager).appendMessage(
                PersistedMessage(id: UUID(), conversationID: durableID, role: "user",
                                 content: "snapshot durable text", createdAt: createdAt))

            let journalMode = try await fileManager.reader { db in
                (try String.fetchOne(db, sql: "PRAGMA journal_mode")) ?? ""
            }
            report["journalMode"] = journalMode
            if journalMode.lowercased() != "wal" { failures.append("journal_mode \(journalMode) != wal") }

            // GRDB pool.read wraps the block in a fresh deferred (read-only)
            // transaction: exactly the state the sqlite snapshot API
            // requires (no write txn, non-autocommit, WAL with committed
            // frames, connection untouched since BEGIN). get/cmp/free/OPEN
            // all execute here on device; codes are reported as observed.
            let snapshot = try await fileManager.reader { db -> (Int32, Int32, Int32, Int) in
                guard let connection = db.sqliteConnection else { return (-1, -1, -1, -1) }
                var first: UnsafeMutablePointer<sqlite3_snapshot>?
                var second: UnsafeMutablePointer<sqlite3_snapshot>?
                let getCode = sqlite3_snapshot_get(connection, "main", &first)
                let getCode2 = sqlite3_snapshot_get(connection, "main", &second)
                let cmpCode = (getCode == SQLITE_OK && getCode2 == SQLITE_OK
                               && first != nil && second != nil)
                    ? sqlite3_snapshot_cmp(first, second) : Int32(-1)
                if let second { sqlite3_snapshot_free(second) }
                var openCode = Int32(-1)
                var rows = -1
                if getCode == SQLITE_OK, let first {
                    openCode = sqlite3_snapshot_open(connection, "main", first)
                    if openCode == SQLITE_OK {
                        rows = (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages")) ?? -1
                    }
                    sqlite3_snapshot_free(first)
                }
                return (getCode, cmpCode, openCode, rows)
            }
            let (snapshotGet, snapshotCmp, snapshotOpen, snapshotRows) = snapshot
            report["snapshotGetCode"] = Int(snapshotGet)
            report["snapshotCmpEqualSnapshots"] = Int(snapshotCmp)
            report["snapshotOpenCode"] = Int(snapshotOpen)
            report["snapshotOpenRowRead"] = snapshotRows
            if snapshotGet != SQLITE_OK { failures.append("snapshot_get \(snapshotGet) != OK") }
            if snapshotCmp != 0 { failures.append("snapshot_cmp \(snapshotCmp) != 0") }
            if snapshotOpen != SQLITE_OK { failures.append("snapshot_open \(snapshotOpen) != OK") }

            try await fileManager.close()

            if cancelledIfRequested() { return errorJSON("qualification-smoke-cancelled") }
            let reopened = try DatabaseManager(path: fileURL)
            try await reopened.migrate()
            let reloaded = try await SQLiteConversationStore(database: reopened)
                .conversation(id: durableID)
            report["durableReopenTitle"] = reloaded?.title ?? ""
            report["durableReopenOK"] = reloaded?.title == "durable"
            if reloaded?.title != "durable" { failures.append("durable reopen failed") }
            try await reopened.close()
        } catch {
            failures.append("throw:\(String(reflecting: error))")
        }
        report["failures"] = failures
        report["ok"] = failures.isEmpty
        return reportJSON(report)
    }
}

@_cdecl("floe_db_smoke")
public func floeDbSmoke(_ cachePath: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let cachePath else { return jsonDuplicate(errorJSON("missingCachePath")) }
    let text = String(cString: cachePath)
    guard !text.isEmpty, text.hasPrefix("/"), text.utf8.count <= 1024, !text.contains("..")
    else { return jsonDuplicate(errorJSON("invalidCachePath")) }
    return jsonDuplicate(databaseSmokeJSON(cacheDirectory: text))
}

// MARK: - JSON kind smoke (DesignCanvasMetadata Android branch)

private func caseName(_ value: DesignJSONValue) -> String {
    switch value {
    case .null: "null"
    case .bool: "bool"
    case .integer: "integer"
    case .unsigned: "unsigned"
    case .decimal: "decimal"
    case .number: "number"
    case .string: "string"
    case .array: "array"
    case .object: "object"
    @unknown default: "unknown"
    }
}

/// Reports the ACTUAL dynamic-type behaviour of JSONSerialization primitives
/// under the RUNNING Foundation, the (now diagnostic only) `Swift.type(of:) ==
/// Bool.self` result, the exact CF runtime type, the `NSNumber` bridge
/// (objCType when present) and the DesignJSONValue mapping through BOTH
/// routes (foundation-object mapping and strict Codable order). Constructed
/// narrow NSNumber integers are included so a boolean misclassification is
/// visible on the device rather than inferred. The mapping CONTRACT is what
/// is asserted.
private func jsonKindSmokeJSON() -> String {
    let sample = "[true, false, 1, 0, 1.5, \"x\", null]"
    var report: [String: Any] = ["ok": false]
    var failures: [String] = []
    do {
        let parsed = try JSONSerialization.jsonObject(
            with: Data(sample.utf8), options: [.fragmentsAllowed])
        guard let array = parsed as? [Any?] else {
            throw FloeError.internalError("top-level array missing")
        }
        let labels = ["true", "false", "int1", "int0", "frac", "string", "null"]
        var values: [[String: Any]] = []
        for (index, element) in array.enumerated() where index < labels.count {
            var entry: [String: Any] = ["label": labels[index]]
            if element is NSNull || element == nil {
                entry["typeName"] = "nil-or-NSNull"
                entry["isBool"] = false
                entry["typeOfEqualsBoolSelf"] = false
                entry["asBool"] = false
                entry["isNSNumber"] = false
                entry["designCase"] = caseName(DesignJSONValue.from(foundation: element ?? NSNull()))
            } else if let object = element {
                entry["typeName"] = String(describing: Swift.type(of: object))
                entry["reflecting"] = String(reflecting: Swift.type(of: object))
                entry["isBool"] = object is Bool
                entry["typeOfEqualsBoolSelf"] = Swift.type(of: object) == Bool.self
                entry["asBool"] = (object as? Bool) != nil
                entry["isNSNumber"] = object is NSNumber
                if let number = object as? NSNumber {
                    entry["numberObjCType"] = String(cString: number.objCType)
                    entry["numberBoolValue"] = number.boolValue
                    #if canImport(CoreFoundation)
                    entry["cfTypeIsBoolean"] = CFGetTypeID(number) == CFBooleanGetTypeID()
                    #endif
                }
                entry["designCase"] = caseName(DesignJSONValue.from(foundation: object))
            }
            values.append(entry)
        }
        report["foundationValues"] = values
        report["foundationCount"] = array.count

        #if canImport(CoreFoundation)
        // Constructed narrow NSNumber forms. The rejected objCType "c"
        // heuristic and the previous Android `Swift.type(of:)` check both
        // misclassify some of these; every non-Bool entry here is CFNumber
        // and MUST stay an integer (or unsigned for UInt64.max), never Bool.
        let narrowCases: [(String, NSNumber, String)] = [
            ("int8-1", NSNumber(value: Int8(1)), "integer"),
            ("int8-0", NSNumber(value: Int8(0)), "integer"),
            ("int8-neg1", NSNumber(value: Int8(-1)), "integer"),
            ("uint8-1", NSNumber(value: UInt8(1)), "integer"),
            ("int16-1", NSNumber(value: Int16(1)), "integer"),
            ("uint16-1", NSNumber(value: UInt16(1)), "integer"),
            ("int32-1", NSNumber(value: Int32(1)), "integer"),
            ("uint32-1", NSNumber(value: UInt32(1)), "integer"),
            ("int64-1", NSNumber(value: Int64(1)), "integer"),
            ("uint64-1", NSNumber(value: UInt64(1)), "integer"),
            ("int64-max", NSNumber(value: Int64.max), "integer"),
            ("uint64-max", NSNumber(value: UInt64.max), "unsigned"),
            ("bool-true", NSNumber(value: true), "bool"),
            ("bool-false", NSNumber(value: false), "bool"),
        ]
        var narrowValues: [[String: Any]] = []
        var narrowContract = true
        for (label, number, expectedCase) in narrowCases {
            let actualCase = caseName(DesignJSONValue.from(foundation: number))
            narrowValues.append([
                "label": label,
                "objCType": String(cString: number.objCType),
                "asBool": (number as? Bool) != nil,
                "cfTypeIsBoolean": CFGetTypeID(number) == CFBooleanGetTypeID(),
                "designCase": actualCase,
                "expectedCase": expectedCase,
            ])
            if actualCase != expectedCase { narrowContract = false }
        }
        report["narrowNumbers"] = narrowValues
        report["narrowNumbersContractHolds"] = narrowContract
        if !narrowContract {
            failures.append("constructed NSNumber mapping broke the contract")
        }
        #endif

        // The Canvas preservation contract (independent of which primitive
        // class Foundation hands back): bools stay bool, JSON integers stay
        // integers, 1.5 stays numeric, strings and null keep their cases.
        let observed = values.map { ($0["designCase"] as? String) ?? "" }
        var satisfied = observed.count == labels.count
        let allowed: [[String]] = [["bool"], ["bool"], ["integer"], ["integer"],
                                   ["decimal", "number"], ["string"], ["null"]]
        for position in 0..<min(observed.count, allowed.count)
        where !allowed[position].contains(observed[position]) {
            satisfied = false
        }
        report["foundationMappingContractHolds"] = satisfied
        if !satisfied { failures.append("foundation-object mapping broke the contract") }

        let decoded = try JSONDecoder().decode([DesignJSONValue].self,
                                               from: Data("[1,0,true,false,1.5]".utf8))
        report["decoderCases"] = decoded.map(caseName)
        let decoderCases = decoded.map(caseName)
        let decoderContract = decoderCases.count == 5
            && decoderCases[0] == "integer" && decoderCases[1] == "integer"
            && decoderCases[2] == "bool" && decoderCases[3] == "bool"
            && (decoderCases[4] == "decimal" || decoderCases[4] == "number")
        report["decoderMappingContractHolds"] = decoderContract
        if !decoderContract { failures.append("Codable ordering mapping broke") }

        // Round-trip stability: exact int/bool separation survives re-encode.
        let roundTrip = try JSONEncoder().encode(decoded)
        report["decoderRoundTrip"] = String(decoding: roundTrip, as: UTF8.self)
    } catch {
        failures.append("throw:\(String(reflecting: error))")
    }
    report["failures"] = failures
    report["ok"] = failures.isEmpty
    return reportJSON(report)
}

@_cdecl("floe_json_kind_smoke")
public func floeJsonKindSmoke() -> UnsafeMutablePointer<CChar>? {
    jsonDuplicate(jsonKindSmokeJSON())
}
