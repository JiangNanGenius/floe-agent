// FloePersistence — exact-run durable user-file output projection (S3-D).
//
// One dedicated read projection over the existing completion-critical
// `.toolResult` events. The C terminal-tail scan (last 24×4 events) can only
// describe how a run ENDED; a file produced early in a long run sits far
// below that tail and would silently disappear from the answer. This reader
// therefore queries the WHOLE ascending thread for manifest-bearing rows,
// bound to the exact run AND the caller's expected conversation in one SQL
// predicate, and strictly parses the nested `outputFilesJSON` string inside
// the long-standing [String: String] payload map.
//
// Bounded by construction (primary spot-review correction): the pass runs in
// TWO SQL stages. Stage one returns only integers (sequence, payload byte
// length, JSON validity) so the row count, the per-row serialized size and
// the total serialized size are all capped BEFORE any payload text is
// allocated in Swift. Stage two projects only the five small durable fields
// through `json_extract`/`json_type` for rows the first stage already proved
// valid and bounded, fenced below the first stage's watermark so concurrent
// appends can neither slip uncounted rows in nor mutate anything (the thread
// is append-only).
//
// The reader is deliberately honest and all-or-error:
//   * a row whose payload claims a manifest (the key really exists in the
//     string map) but cannot be decoded precisely fails with the sequence it
//     came from — never a skipped "best effort" file list;
//   * a row that merely QUOTES `"outputFilesJSON"` inside redacted prose has
//     no such top-level key and is a legacy/ordinary no-output row;
//   * more manifest-bearing rows, a larger single row, or more total
//     serialized bytes than the bounds is an explicit overflow error, never
//     a silently truncated result;
//   * every receipt must carry the sealed exact run AND the expected
//     conversation as its taskID: a manifest with a nil/unbound task fails
//     as foreign ownership. (The publisher never produces one without a
//     real conversation binding.)
// It never touches snapshot bytes (the caller verifies canonical snapshots
// at retrieval), never infers a role from prose, namespaces or summary
// strings, and never aggregates another (or a child) run's receipts.

import Foundation
import GRDB
import FloeModels

/// One durable `.toolResult` event that carries a user-file output manifest,
/// with its persisted enclosing identity fields kept so the caller can prove
/// the receipts against the real recorded call.
public struct RunOutputManifestRow: Sendable, Hashable {
    /// Durable event sequence (ascending within the exact run).
    public var sequence: Int
    /// Persisted enclosing tool name from the string-map payload.
    public var tool: String?
    /// Persisted enclosing provider call id from the string-map payload.
    public var callID: String?
    /// Persisted enclosing tool status from the string-map payload.
    public var status: String?
    /// Receipts exactly as decoded from `outputFilesJSON` (validated shape).
    public var receipts: [RunOutputFile]

    public init(
        sequence: Int,
        tool: String?,
        callID: String?,
        status: String?,
        receipts: [RunOutputFile]
    ) {
        self.sequence = sequence
        self.tool = tool
        self.callID = callID
        self.status = status
        self.receipts = receipts
    }
}

/// Why an exact-run output projection cannot be trusted. Each case names the
/// precise durable evidence (sequence and/or output identity) so the caller
/// can report an accurate cause instead of a generic failure.
public enum RunOutputManifestFailure: Error, Hashable, Sendable {
    /// More manifest-bearing rows exist than the bounded read allows.
    case manifestRowOverflow(bound: Int)
    /// Serialized manifest rows exceed the per-row or total byte bounds
    /// before any payload text is allocated.
    case payloadOverLimit(detail: String)
    /// The row matched the manifest probe but its payload is not valid JSON
    /// or is not the durable string-map shape the runtime writes (a present
    /// `tool`/`id`/`status`/`outputFilesJSON` member that is not a JSON
    /// string is a damaged outer payload).
    case corruptOuterPayload(sequence: Int)
    /// The payload map carries the `outputFilesJSON` key, but its nested
    /// string is not a decodable receipt list.
    case corruptManifestJSON(sequence: Int)
    /// A decoded receipt is not canonical for its own identity (role/path/
    /// digest/basename/field bounds) or its sealed identity does not
    /// re-derive from run+call+slot.
    case invalidReceipt(sequence: Int, outputID: String, detail: String)
    /// A receipt claims a run or conversation different from the exact one
    /// this projection is bound to (foreign/forged/unbound ownership).
    case foreignBinding(sequence: Int, outputID: String, detail: String)
    /// A receipt's producer call/tool does not match the persisted enclosing
    /// `.toolResult` identity fields recorded with it.
    case enclosingMismatch(sequence: Int, outputID: String, detail: String)
    /// The same output identity appeared twice with different metadata.
    /// Metadata-equal duplicates are idempotent and never raise this.
    case duplicateConflict(outputID: String, sequences: [Int])
}

/// Exact-run durable output projection without loading conversation history
/// or the full event thread. Same read-projection pattern as
/// `SQLiteRunReplyReader`: the ownership predicate lives inside the SQL, so
/// no filesystem work can ever start against an unproven run.
public struct SQLiteRunOutputReader: Sendable {
    /// Maximum number of manifest-bearing rows one projection returns. The
    /// extra SQL row is a sentinel: exceeding the bound is an explicit
    /// overflow error, never a truncated success.
    public static let defaultManifestRowBound = 4_096
    /// Upper bound for one manifest-bearing row's serialized JSON. A real
    /// row is a bounded summary plus a ≤32-receipt manifest whose fields are
    /// individually capped; anything larger is anomalous and fails before
    /// its text is fetched.
    public static let defaultManifestRowMaxBytes = 4 * 1024 * 1024
    /// Upper bound for the total serialized size of one projection, checked
    /// against integer SQL lengths before any payload is allocated.
    public static let defaultManifestTotalMaxBytes = 64 * 1024 * 1024

    /// The nested string-map key the runtime persists for sealed outputs.
    static let manifestPayloadKey = "outputFilesJSON"

    /// Bound overrides for this reader instance. Production wiring uses the
    /// defaults; focused guard tests shrink them to exercise the explicit
    /// overflow paths without allocating gigabytes. They are clamped to
    /// positive values and can only TIGHTEN behavior relative to the
    /// defaults, never silently enlarge a production bound elsewhere.
    public let manifestRowBound: Int
    public let manifestRowMaxBytes: Int
    public let manifestTotalMaxBytes: Int

    private let database: DatabaseManager

    public init(
        database: DatabaseManager,
        rowBound: Int? = nil,
        rowMaxBytes: Int? = nil,
        totalMaxBytes: Int? = nil
    ) {
        self.database = database
        self.manifestRowBound = min(
            Self.defaultManifestRowBound, max(1, rowBound ?? Self.defaultManifestRowBound)
        )
        self.manifestRowMaxBytes = min(
            Self.defaultManifestRowMaxBytes, max(64, rowMaxBytes ?? Self.defaultManifestRowMaxBytes)
        )
        self.manifestTotalMaxBytes = min(
            Self.defaultManifestTotalMaxBytes,
            max(64, totalMaxBytes ?? Self.defaultManifestTotalMaxBytes)
        )
    }

    /// Ascending manifest rows for exactly this run AND this expected
    /// conversation. The join against `runs` binds both identifiers in the
    /// query itself: a wrong conversation returns zero rows, so ownership is
    /// proven before any result (and any later filesystem verification by
    /// the caller) exists. A run with no output-bearing tool results yields
    /// an empty projection — an honest no-files outcome, never another run's.
    public func manifestRows(
        runID: UUID,
        expectedConversationID: UUID
    ) async throws -> [RunOutputManifestRow] {
        // Stage 1 — integers only. No payload text is allocated here, so
        // row count, per-row size and total size are all proven bounded (or
        // rejected) before the projection stage runs. The probe pattern is
        // a bound SQL parameter, never interpolated SQL text. `length()` on
        // TEXT counts CHARACTERS; the contract bounds the SERIALIZED BYTES,
        // so the size goes through the BLOB cast (real UTF-8 byte length).
        struct Probe: Sendable {
            var sequence: Int
            var length: Int
            var jsonValid: Int
        }
        let probes: [Probe] = try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT e.sequence AS seq,
                       length(CAST(e.payload_json AS BLOB)) AS len,
                       json_valid(e.payload_json) AS valid
                FROM run_events e
                JOIN runs r ON r.id = e.run_id
                WHERE e.run_id = ? AND r.conversation_id = ?
                  AND e.kind = 'toolResult'
                  AND instr(e.payload_json, ?) > 0
                ORDER BY e.sequence ASC
                LIMIT ?
                """, arguments: [
                    runID.uuidString,
                    expectedConversationID.uuidString,
                    "\"\(Self.manifestPayloadKey)\"",
                    manifestRowBound + 1
                ])
            .map { row in
                let sequence: Int = row["seq"]
                let length: Int = row["len"]
                let valid: Int = row["valid"]
                return Probe(sequence: sequence, length: length, jsonValid: valid)
            }
        }
        guard probes.count <= manifestRowBound else {
            throw RunOutputManifestFailure.manifestRowOverflow(bound: manifestRowBound)
        }
        var totalBytes = 0
        for probe in probes {
            guard probe.length <= manifestRowMaxBytes else {
                throw RunOutputManifestFailure.payloadOverLimit(detail: String(
                    format: "manifest row %d is %d bytes (per-row bound %d)",
                    probe.sequence, probe.length, manifestRowMaxBytes
                ))
            }
            totalBytes += probe.length
            guard totalBytes <= manifestTotalMaxBytes else {
                throw RunOutputManifestFailure.payloadOverLimit(detail: String(
                    format: "manifest rows exceed the %d-byte projection bound at row %d",
                    manifestTotalMaxBytes, probe.sequence
                ))
            }
            // The first (lowest-sequence) structurally damaged row is the
            // accurate cause. Invalid JSON could also be prose that merely
            // quotes the key; it matched the durable manifest probe, so a
            // well-formed string map is required exactly when it claims the
            // key.
            guard probe.jsonValid == 1 else {
                throw RunOutputManifestFailure.corruptOuterPayload(sequence: probe.sequence)
            }
        }
        guard let watermark = probes.last?.sequence else { return [] }

        // Stage 2 — bounded field projection. `json_type` enforces the
        // durable [String: String] shape without allocating the payload;
        // `json_extract` returns only the small member texts. The watermark
        // keeps the fetched set exactly the counted set (append-only thread;
        // newer rows belong to a later projection).
        let projection: [(
            sequence: Int,
            tool: (type: String?, value: String?),
            callID: (type: String?, value: String?),
            status: (type: String?, value: String?),
            manifest: (type: String?, value: String?)
        )] = try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT e.sequence AS seq,
                       json_type(e.payload_json, '$.tool') AS tool_type,
                       json_extract(e.payload_json, '$.tool') AS tool_value,
                       json_type(e.payload_json, '$.id') AS id_type,
                       json_extract(e.payload_json, '$.id') AS id_value,
                       json_type(e.payload_json, '$.status') AS status_type,
                       json_extract(e.payload_json, '$.status') AS status_value,
                       json_type(e.payload_json, '$.' || ?) AS manifest_type,
                       json_extract(e.payload_json, '$.' || ?) AS manifest_value
                FROM run_events e
                JOIN runs r ON r.id = e.run_id
                WHERE e.run_id = ? AND r.conversation_id = ?
                  AND e.kind = 'toolResult'
                  AND instr(e.payload_json, ?) > 0
                  AND e.sequence <= ?
                ORDER BY e.sequence ASC
                LIMIT ?
                """, arguments: [
                    Self.manifestPayloadKey,
                    Self.manifestPayloadKey,
                    runID.uuidString,
                    expectedConversationID.uuidString,
                    "\"\(Self.manifestPayloadKey)\"",
                    watermark,
                    manifestRowBound + 1
                ])
            .map { row in
                let sequence: Int = row["seq"]
                let toolType: String? = row["tool_type"]
                let idType: String? = row["id_type"]
                let statusType: String? = row["status_type"]
                let manifestType: String? = row["manifest_type"]
                // Values are converted ONLY when the member is proven a
                // JSON text: a numeric or object member keeps its raw
                // DatabaseValue untouched (decoding those as String is a
                // fatal GRDB conversion, not a nil) and the shape guard
                // below reports the damaged outer payload precisely.
                func textValue(_ type: String?, _ column: String) -> String? {
                    guard type == "text" else { return nil }
                    let raw: DatabaseValue = row[column]
                    return String.fromDatabaseValue(raw)
                }
                return (
                    sequence,
                    (toolType, textValue(toolType, "tool_value")),
                    (idType, textValue(idType, "id_value")),
                    (statusType, textValue(statusType, "status_value")),
                    (manifestType, textValue(manifestType, "manifest_value"))
                )
            }
        }
        guard projection.count <= manifestRowBound else {
            throw RunOutputManifestFailure.manifestRowOverflow(bound: manifestRowBound)
        }

        var result: [RunOutputManifestRow] = []
        result.reserveCapacity(projection.count)
        // outputID -> (first-seen receipt, first-seen sequence). Metadata-
        // equal repeats are idempotent and stay listed per row (each row's
        // own enclosing status matters to the caller's policy); different
        // metadata under one identity is a conflict.
        var seen: [String: (first: RunOutputFile, sequence: Int)] = [:]
        for row in projection {
            // String-map shape: a present member that is not a JSON string
            // (number, object, array, explicit null, …) is a damaged outer
            // payload. A missing member (NULL json_type) stays allowed —
            // legacy rows may not carry every field.
            func claimsString(_ member: (type: String?, value: String?)) -> Bool {
                member.type == nil || member.type == "text"
            }
            guard claimsString(row.tool), claimsString(row.callID),
                  claimsString(row.status), claimsString(row.manifest) else {
                throw RunOutputManifestFailure.corruptOuterPayload(sequence: row.sequence)
            }
            // The instr probe is a candidate filter only. Absence of the
            // top-level key means this row never claimed a manifest (prose
            // quote or ordinary result): not a defect.
            guard let manifestJSON = row.manifest.value else { continue }
            let receipts: [RunOutputFile]
            guard let data = manifestJSON.data(using: .utf8) else {
                throw RunOutputManifestFailure.corruptManifestJSON(sequence: row.sequence)
            }
            do {
                receipts = try JSONDecoder().decode([RunOutputFile].self, from: data)
            } catch {
                throw RunOutputManifestFailure.corruptManifestJSON(sequence: row.sequence)
            }
            let tool = row.tool.value
            let callID = row.callID.value
            let status = row.status.value
            for receipt in receipts {
                try Self.validate(
                    receipt,
                    sequence: row.sequence,
                    runID: runID,
                    expectedConversationID: expectedConversationID,
                    enclosingTool: tool,
                    enclosingCallID: callID
                )
                if let previous = seen[receipt.outputID] {
                    guard previous.first == receipt else {
                        throw RunOutputManifestFailure.duplicateConflict(
                            outputID: receipt.outputID,
                            sequences: [previous.sequence, row.sequence]
                        )
                    }
                    // Metadata-equal duplicate: idempotent. The row still
                    // lists it so the caller sees every enclosing status
                    // this identity legitimately appears under.
                } else {
                    seen[receipt.outputID] = (receipt, row.sequence)
                }
            }
            guard !receipts.isEmpty else { continue }
            result.append(RunOutputManifestRow(
                sequence: row.sequence,
                tool: tool,
                callID: callID,
                status: status,
                receipts: receipts
            ))
        }
        return result
    }

    /// Structural receipt validation only — on-disk bytes are verified by
    /// the snapshot verifier at retrieval, never here.
    private nonisolated static func validate(
        _ receipt: RunOutputFile,
        sequence: Int,
        runID: UUID,
        expectedConversationID: UUID,
        enclosingTool: String?,
        enclosingCallID: String?
    ) throws {
        guard receipt.isCanonicalForCurrentRun else {
            throw RunOutputManifestFailure.invalidReceipt(
                sequence: sequence,
                outputID: receipt.outputID,
                detail: "receipt is not canonical for its own identity (role, path, digest, basename or field bounds)"
            )
        }
        guard receipt.hasRuntimeConsistentIdentity else {
            throw RunOutputManifestFailure.invalidReceipt(
                sequence: sequence,
                outputID: receipt.outputID,
                detail: "output identity does not re-derive from the sealed run, producer call and slot"
            )
        }
        guard receipt.runID == runID else {
            throw RunOutputManifestFailure.foreignBinding(
                sequence: sequence,
                outputID: receipt.outputID,
                detail: "receipt names a run other than the requested exact run"
            )
        }
        // A consumable run-file receipt must carry the sealed task binding.
        // The publisher requires a real conversation binding, so a nil or
        // foreign taskID on a manifest row is unbound/foreign ownership —
        // never accepted as "probably this conversation".
        guard receipt.taskID == expectedConversationID else {
            throw RunOutputManifestFailure.foreignBinding(
                sequence: sequence,
                outputID: receipt.outputID,
                detail: receipt.taskID == nil
                    ? "receipt carries no task binding for the exact run's conversation"
                    : "receipt task identity differs from the run's conversation"
            )
        }
        // The durable enclosing fields must be present and agree with the
        // sealed producer identity: a manifest may not travel on an event
        // whose recorded call belongs to a different tool invocation.
        guard let enclosingCallID, !enclosingCallID.isEmpty,
              enclosingCallID == receipt.producerCallID else {
            throw RunOutputManifestFailure.enclosingMismatch(
                sequence: sequence,
                outputID: receipt.outputID,
                detail: "persisted enclosing call id is missing or differs from the sealed producer call"
            )
        }
        guard let enclosingTool, !enclosingTool.isEmpty,
              enclosingTool == receipt.producerTool else {
            throw RunOutputManifestFailure.enclosingMismatch(
                sequence: sequence,
                outputID: receipt.outputID,
                detail: "persisted enclosing tool name is missing or differs from the sealed producer tool"
            )
        }
    }
}
