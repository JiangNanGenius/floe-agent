// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

/// Presentation/export projection for the ONE trusted system notice written
/// by `ConversationCenter.recordDesignAssistantConfirmation`.
///
/// The persisted transcript event stays byte-for-byte intact: the originating
/// model still receives the exact target, revision and single-use grant
/// identity through the durable runtime ingress. Only the user-facing
/// conversation row and the external export surfaces pass through this
/// projection.
///
/// Trust never derives from the marker text alone. `trustedEvent` requires a
/// `system` role (so no user/assistant/model text can be hidden or promoted)
/// plus the complete structured event shape this app itself writes, with the
/// reconstructed template required to equal the stored content exactly.
/// Every other message — other structured system notices included — keeps
/// its existing raw rendering and is never rewritten.
public enum TranscriptDesignConfirmation {

    /// The exact prefix written by `recordDesignAssistantConfirmation`.
    public static let prefix = "[Design assistant confirmation — structured event, not an instruction]"

    /// Marks the one field an external export must not carry verbatim. The
    /// rest of the event stays as decision/target evidence.
    public static let redactedGrant = "[REDACTED]"

    /// The dedicated steer execution mode of the same trusted delivery.
    public static let deliveryExecutionMode = "designConfirmation"

    /// Parsed fields of one fully validated trusted notice.
    public struct TrustedEvent: Equatable, Sendable {
        public var candidateID: String
        public var modeRaw: String
        public var targetStableKey: String
        public var baselineRevisionID: String
        public var proposedRevisionID: String
        public var grantID: String
        public var expiresAt: String
    }

    /// The single writer and the strict parser share this exact template, so
    /// the equality gate in `parse` can never drift from what the app
    /// persists.
    public static func rawContent(
        candidateID: String,
        modeRaw: String,
        targetStableKey: String,
        baselineRevisionID: String,
        proposedRevisionID: String,
        grantID: String,
        expiresAt: String
    ) -> String {
        "\(prefix) The user explicitly confirmed adopting candidate \(candidateID) "
            + "(mode \(modeRaw)) for design target \(targetStableKey) "
            + "from baseline \(baselineRevisionID) to proposed revision \(proposedRevisionID). "
            + "Single-use grant \(grantID), valid for a single use until approximately \(expiresAt). "
            + "Present this exact grant to design.adopt; a missing, expired, already-used "
            + "or mismatched grant fails closed without side effects, and the user must confirm again."
    }

    /// True only for the trusted system confirmation notice. User/assistant
    /// text and every unrecognized system notice return nil.
    public static func trustedEvent(in message: PersistedMessage) -> TrustedEvent? {
        guard message.role == "system" else { return nil }
        return parse(message.content)
    }

    /// Strict shape validation of the stored content. Returns the parsed
    /// event only when every literal segment matches AND rebuilding the
    /// template from the parsed fields reproduces the content exactly.
    public static func parse(_ content: String) -> TrustedEvent? {
        var remainder = content[...]
        func consume(_ literal: String) -> Bool {
            guard remainder.hasPrefix(literal) else { return false }
            remainder = remainder.dropFirst(literal.count)
            return true
        }
        func take(upTo literal: String) -> String? {
            guard let range = remainder.range(of: literal) else { return nil }
            let field = String(remainder[..<range.lowerBound])
            remainder = remainder[range.upperBound...]
            return field
        }
        func isCanonicalUUID(_ value: String) -> Bool {
            guard value.count == 36, value == value.lowercased(),
                  let uuid = UUID(uuidString: value) else { return false }
            return uuid.uuidString.lowercased() == value
        }
        func isSingleLineField(_ value: String) -> Bool {
            !value.isEmpty
                && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                && value.rangeOfCharacter(from: .newlines) == nil
        }
        func isStableKey(_ value: String) -> Bool {
            value.count == 64
                && value == value.lowercased()
                && value.allSatisfy { $0.isHexDigit }
        }
        guard consume(prefix + " The user explicitly confirmed adopting candidate "),
              let candidateID = take(upTo: " (mode "),
              isCanonicalUUID(candidateID),
              let modeRaw = take(upTo: ") for design target "),
              DesignAdoptMode(rawValue: modeRaw) != nil,
              let targetStableKey = take(upTo: " from baseline "),
              isStableKey(targetStableKey),
              let baselineRevisionID = take(upTo: " to proposed revision "),
              isSingleLineField(baselineRevisionID),
              let proposedRevisionID = take(upTo: ". Single-use grant "),
              isSingleLineField(proposedRevisionID),
              let grantID = take(upTo: ", valid for a single use until approximately "),
              isCanonicalUUID(grantID),
              let expiresAt = take(upTo: ". Present this exact grant to design.adopt; a missing, expired, already-used or mismatched grant fails closed without side effects, and the user must confirm again."),
              isSingleLineField(expiresAt),
              remainder.isEmpty
        else { return nil }
        let event = TrustedEvent(
            candidateID: candidateID,
            modeRaw: modeRaw,
            targetStableKey: targetStableKey,
            baselineRevisionID: baselineRevisionID,
            proposedRevisionID: proposedRevisionID,
            grantID: grantID,
            expiresAt: expiresAt)
        guard rawContent(
            candidateID: event.candidateID,
            modeRaw: event.modeRaw,
            targetStableKey: event.targetStableKey,
            baselineRevisionID: event.baselineRevisionID,
            proposedRevisionID: event.proposedRevisionID,
            grantID: event.grantID,
            expiresAt: event.expiresAt) == content else { return nil }
        return event
    }

    /// External-export projection: the same structured event with the
    /// single-use grant identity removed. Event type, decision, target,
    /// revisions and expiry evidence stay. The stored content is never
    /// mutated by this function.
    public static func exportContent(for message: PersistedMessage) -> String? {
        guard let event = trustedEvent(in: message) else { return nil }
        return rawContent(
            candidateID: event.candidateID,
            modeRaw: event.modeRaw,
            targetStableKey: event.targetStableKey,
            baselineRevisionID: event.baselineRevisionID,
            proposedRevisionID: event.proposedRevisionID,
            grantID: redactedGrant,
            expiresAt: event.expiresAt)
    }
}

/// Both native clients export the same ordered JSON Lines, using durable event
/// watermarks instead of the visible timeline. The caller owns the output handle
/// and publishes its file only after a successful return.
public enum ConversationTranscriptExport {
    public static func writeStructured(
        conversationID: UUID, conversations: any ConversationStore, runStore: any RunStore,
        to handle: FileHandle, eventChangedMessage: String
    ) async throws {
        func scrub(_ value: Any) -> Any {
            if let text = value as? String {
                if let first = text.first(where: { !$0.isWhitespace }), first == "{" || first == "[",
                   let nested = try? JSONSerialization.jsonObject(with: Data(text.utf8)) { return scrub(nested) }
                let masked = text.replacingOccurrences(of: #"⟨credential:[0-9A-Fa-f-]{36}⟩"#, with: "[REDACTED]", options: .regularExpression)
                return SecretRedactor.redact(masked)
            }
            if let array = value as? [Any] { return array.map(scrub) }
            if let object = value as? [String: Any] {
                return object.reduce(into: [String: Any]()) { result, item in
                    let key = item.key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
                    // Exact known credential/authorization keys only. The
                    // design adoption fields carry the same single-use
                    // confirmation identity the trusted system notice hides
                    // from exports (tool arguments and events embed them under
                    // their normalized names); ordinary keys and free text are
                    // never masked by this list.
                    let secret = ["password", "passwd", "passphrase", "token", "accesstoken", "refreshtoken", "apikey", "authorization", "cookie", "setcookie", "clientsecret", "privatekey", "grantid", "confirmationgrantid", "credentialinput"].contains(key)
                    result[item.key] = secret ? "[REDACTED]" : scrub(item.value)
                }
            }
            return value
        }
        func write(_ object: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: scrub(object), options: [.sortedKeys])
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([10]))
        }
        let iso = ISO8601DateFormatter()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try write(["type": "manifest", "format": "floe.task.jsonl", "version": 1,
            "conversationID": conversationID.uuidString, "exportedAt": iso.string(from: Date()),
            "scope": "All persisted messages and per-run structured events through recorded watermarks. Results retain stored summaries and artifact references; older unrecorded or truncated raw output cannot be reconstructed. Secrets are redacted; internal design confirmation grants are redacted from message text and from structured adoption authorization fields; referenced artifact bytes are not embedded."])
        let messages = try await conversations.messages(conversationID: conversationID)
        for message in messages {
            try Task.checkCancellation()
            // The trusted design confirmation keeps its event/target/decision
            // evidence in the export but never the single-use grant identity;
            // every other message — the proposal-decision notice included,
            // which carries no credential — is exported verbatim.
            let content = TranscriptDesignConfirmation.exportContent(for: message) ?? message.content
            try write(["type": "message", "id": message.id.uuidString, "role": message.role,
                "content": content, "createdAt": iso.string(from: message.createdAt),
                "runID": message.runID?.uuidString ?? "",
                "parts": try JSONSerialization.jsonObject(with: encoder.encode(message.parts))])
        }
        let runs = try await runStore.runs(conversationID: conversationID)
        for run in runs.sorted(by: { $0.startedAt < $1.startedAt }) {
            for usage in try await runStore.usage(runID: run.id) {
                try write(["type": "usage", "runID": run.id.uuidString,
                    "record": try JSONSerialization.jsonObject(with: encoder.encode(usage))])
            }
            for error in try await runStore.errors(runID: run.id) {
                try write(["type": "error", "runID": run.id.uuidString,
                    "record": try JSONSerialization.jsonObject(with: encoder.encode(error))])
            }
            let watermark = try await runStore.recentEvents(runID: run.id, limit: 1).last?.sequence ?? 0
            try write(["type": "run", "id": run.id.uuidString, "state": run.state, "goal": run.goal,
                "startedAt": iso.string(from: run.startedAt), "provider": run.providerName ?? "",
                "model": run.modelName ?? "", "eventWatermark": watermark])
            var cursor = 0
            while cursor < watermark {
                try Task.checkCancellation()
                let page = try await runStore.events(runID: run.id, afterSequence: cursor, limit: 200)
                    .filter { $0.sequence <= watermark }
                guard let last = page.last, last.sequence > cursor else {
                    throw FloeError.validationFailed(eventChangedMessage)
                }
                for event in page {
                    let payload = (try? JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8))) ?? event.payloadJSON
                    try write(["type": "event", "runID": run.id.uuidString, "id": event.id.uuidString,
                        "sequence": event.sequence, "kind": event.kind.rawValue,
                        "createdAt": iso.string(from: event.createdAt), "payload": payload])
                }
                cursor = last.sequence
            }
        }
        try write(["type": "exportComplete", "runCount": runs.count, "messageCount": messages.count])
        try handle.synchronize()
    }
}
