// SPDX-License-Identifier: MPL-2.0
import Foundation
import GRDB
import FloeCore

/// Consistency proof over original trusted user activations. This is not
/// authorization and introduces no table, clock, counter or model authority.
public enum RunActivationIdentity {
    private struct Envelope: Decodable { var floeActivation: Marker? }
    private struct Marker: Decodable {
        var version: Int
        var kind: String
        var proof: String?
    }

    private static func marker(_ payload: String) -> Marker? {
        guard payload.utf8.count <= 65_536,
              let value = try? JSONDecoder().decode(Envelope.self, from: Data(payload.utf8)).floeActivation,
              value.version == 1,
              ["user", "goalContinuation", "userResume"].contains(value.kind) else { return nil }
        return value
    }

    private static func uuid(_ raw: String) throws -> String {
        guard let value = UUID(uuidString: raw) else {
            throw FloeError.validationFailed("Invalid durable activation identity")
        }
        return value.uuidString
    }

    /// Streaming folds use bounded per-row memory. Internal continuation,
    /// child work, tool output and Goal revision changes are not user starts.
    public static func current(db: Database, conversationID: UUID) throws -> String? {
        guard let owner = try Row.fetchOne(db,
            sql: "SELECT id, purpose FROM conversations WHERE id = ?",
            arguments: [conversationID.uuidString]) else { return nil }
        let purpose: String? = owner["purpose"]
        var proof = FloeDigest.sha256Hex(Data(
            ("floe.goal-activation.v1|" + conversationID.uuidString + "|" + (purpose ?? "<nil>")).utf8))
        let messages = try Row.fetchCursor(db, sql: """
            SELECT id, run_id FROM messages
            WHERE conversation_id = ? AND role = 'user' AND run_id IS NOT NULL ORDER BY id
            """, arguments: [conversationID.uuidString])
        while let row = try messages.next() {
            let id: String = row["id"]
            let runID: String = row["run_id"]
            proof = FloeDigest.sha256Hex(Data(
                (proof + "|user|" + (try uuid(id)) + "|" + (try uuid(runID))).utf8))
        }
        let resumes = try Row.fetchCursor(db, sql: """
            SELECT e.id, e.run_id, e.payload_json FROM run_events e
            JOIN runs r ON r.id = e.run_id
            WHERE r.conversation_id = ? AND e.kind = 'status' ORDER BY e.id
            """, arguments: [conversationID.uuidString])
        while let row = try resumes.next() {
            let payload: String = row["payload_json"]
            guard marker(payload)?.kind == "userResume" else { continue }
            let id: String = row["id"]
            let runID: String = row["run_id"]
            proof = FloeDigest.sha256Hex(Data(
                (proof + "|resume|" + (try uuid(id)) + "|" + (try uuid(runID))).utf8))
        }
        return proof
    }

    /// Read the immutable proof recorded by the actual original C1/resume
    /// writer for this run; never capture whatever happens to be current.
    public static func frozen(db: Database, runID: UUID, conversationID: UUID) throws -> String? {
        let events = try String.fetchCursor(db, sql: """
            SELECT e.payload_json FROM run_events e JOIN runs r ON r.id = e.run_id
            WHERE e.run_id = ? AND r.conversation_id = ? AND e.kind = 'status'
            ORDER BY e.sequence DESC
            """, arguments: [runID.uuidString, conversationID.uuidString])
        while let payload = try events.next() {
            guard let value = marker(payload), let proof = value.proof,
                  proof.utf8.count == 64,
                  proof.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
            return proof
        }
        return nil
    }
}
