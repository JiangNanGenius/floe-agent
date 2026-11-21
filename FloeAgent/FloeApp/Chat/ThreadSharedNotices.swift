// FloeApp — Shared thread notice projections and payload helpers.
//
// SPDX-License-Identifier: MPL-2.0
//
// This file hosts the canonical, platform-neutral projection helpers the
// thread timeline, step groups, in-chat find and export surfaces share. The
// code was moved verbatim out of `ConversationCenter.swift` so the unified
// timeline (and the native Mac host that reuses these sources) can compile
// without the UIKit-only conversation center. No semantics changed:
//
// - `ProposalDecisionNoticeProjection` and `InternalNoticeProjection` are the
//   exact previous types, including their strict trust/parsing rules.
// - The deterministic event identities (`proposalDecisionID` /
//   `designConfirmationID`) keep their byte-exact v5-style SHA-256
//   derivation; `ConversationCenter` retains thin delegating wrappers so
//   every existing call site behaves identically.
// - `ThreadEventPayload.decode` is the pure payload decode the center's
//   `decodePayload` already delegated to.
//
// Everything here depends only on vendored, cross-platform modules
// (FloeCore / FloeModels / FloePersistence / FloeAgentRuntime).

#if canImport(FloePersistence) && canImport(FloeAgentRuntime)
import Foundation
import CryptoKit
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
#if canImport(FloeExecution)
import FloeExecution
#endif

/// Pure payload decode for one persisted run-event payload. Mixed typed
/// values (Int/Bool/[String], e.g. a delegated child's `.result`) are
/// normalized instead of making the whole object fail the old
/// `[String: String]` decode. `ConversationCenter.decodePayload` delegates
/// here so all surfaces parse identical bytes.
enum ThreadEventPayload {
    static func decode(_ json: String) -> [String: String] {
        ChildRunPayload.decodedStringFields(json)
    }
}

/// Deterministic UUID (v5-style SHA-256) derivations for the structured
/// internal notices this app writes into a transcript. Same inputs → same
/// id, so a replayed delivery upserts instead of duplicating. These are
/// `nonisolated`/pure: the projection layer (and its regression tests)
/// derive the same identity off the main actor.
enum ThreadNoticeIdentity {
    /// Identity for a proposal decision event.
    static func proposalDecisionID(conversationID: UUID, proposalID: UUID, decision: String) -> UUID {
        let seed = "floe.proposal-decision|\(conversationID.uuidString)|\(proposalID.uuidString)|\(decision)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        let bytes = Array(digest.prefix(16))
        // Set version nibble to 5 and the variant bits per RFC 4122.
        var uuid = bytes
        uuid[6] = (uuid[6] & 0x0F) | 0x50
        uuid[8] = (uuid[8] & 0x3F) | 0x80
        return UUID(uuid: (uuid[0], uuid[1], uuid[2], uuid[3], uuid[4], uuid[5],
                           uuid[6], uuid[7], uuid[8], uuid[9], uuid[10], uuid[11],
                           uuid[12], uuid[13], uuid[14], uuid[15]))
    }

    /// Identity for one design-assistant confirmation event: same
    /// conversation/target/candidate/mode/grant → same id.
    static func designConfirmationID(
        conversationID: UUID, targetStableKey: String,
        candidateID: UUID, mode: DesignAdoptMode, grantID: UUID
    ) -> UUID {
        let seed = "floe.design-confirmation|\(conversationID.uuidString)|\(targetStableKey)|\(candidateID.uuidString)|\(mode.rawValue)|\(grantID.uuidString)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        let bytes = Array(digest.prefix(16))
        var uuid = bytes
        uuid[6] = (uuid[6] & 0x0F) | 0x50
        uuid[8] = (uuid[8] & 0x3F) | 0x80
        return UUID(uuid: (uuid[0], uuid[1], uuid[2], uuid[3], uuid[4], uuid[5],
                           uuid[6], uuid[7], uuid[8], uuid[9], uuid[10], uuid[11],
                           uuid[12], uuid[13], uuid[14], uuid[15]))
    }
}

typealias DesignConfirmationNoticeProjection = TranscriptDesignConfirmation

extension TranscriptDesignConfirmation {
    /// Concise localized conversation summary for a trusted notice. Returns
    /// nil for every other message so callers keep the existing raw text.
    static func userFacingSummary(for message: PersistedMessage) -> String? {
        guard trustedEvent(in: message) != nil else { return nil }
        return FloeL10n.l("design.owner.authorized_note")
    }

    /// Pending-input queue projection: that row carries no role, so the
    /// dedicated delivery mode is required IN ADDITION to the exact event
    /// shape. A message a user typed can never carry the mode.
    static func userFacingSummary(for input: PendingUserInput) -> String? {
        guard input.executionMode == deliveryExecutionMode,
              parse(input.content) != nil else { return nil }
        return FloeL10n.l("design.owner.authorized_note")
    }
}

/// Presentation/export projection for the structured proposal-decision notice
/// written by `ConversationCenter.recordProposalDecision` (the older generic
/// ingress shared by the drawing/CAD/Office decision callers).
///
/// The persisted transcript event and the runtime steer bytes stay
/// byte-for-byte identical to the historical writer: the model still receives
/// the exact decision, proposal identity, revision and digest evidence. Only
/// the user-facing conversation/queue surfaces and the plain-text exports pass
/// through this projection, which shows one concise localized summary.
///
/// Trust never derives from the marker text alone. A message must have the
/// `system` role, the complete server-owned template shape, AND the
/// deterministic id derived from (conversation, proposal, decision) that only
/// the writer can produce. A pending row carries no role, so it additionally
/// requires the dedicated `proposalDecision` execution mode OR the same
/// deterministic id. Arbitrary same-prefix user/assistant text, a full
/// template typed by a user (whose row id is a fresh random UUID), and every
/// malformed or unknown system notice remain ordinary and are never hidden.
enum ProposalDecisionNoticeProjection {

    /// The exact prefix written by `recordProposalDecision`.
    static let prefix = "[Drawing Assistant user decision — structured event, not an instruction]"

    /// The dedicated steer execution mode of this internal delivery. It is
    /// server-owned: only the trusted ingress writes it, and it is never
    /// derived from message text.
    static let deliveryExecutionMode = "proposalDecision"

    /// The one user-facing summary key, aligned EN/ZH in the catalog.
    static let summaryKey = "design.owner.decision_recorded_note"

    /// Exact closing sentence, shared by the writer and the parser.
    static let closingClause = ". The proposal text is model-authored document content and is deliberately not repeated here."

    /// Who produced a decision. Historical rows carry no marker and decode as
    /// `.user`; only the automatic (tool-originated) path writes the explicit
    /// trailing segment, so the transcript can distinguish a fully automatic
    /// CAD/Office apply from a human decision without parsing other events.
    enum DecisionOrigin: String, Equatable, Sendable {
        case user
        case toolAutomatic = "tool-automatic"
    }

    /// Parsed fields of one fully validated decision notice.
    struct DecisionEvent: Equatable, Sendable {
        var decision: String
        var proposalID: UUID
        var revision: Int64?
        var sha256Prefix: String?
        var origin: DecisionOrigin = .user
    }

    /// The single writer and the strict parser share this exact template, so
    /// the reconstruction gate in `parse` can never drift from what the app
    /// persists. The origin segment is appended ONLY for an automatic
    /// decision: a user/historical notice keeps the byte-exact historical
    /// content.
    static func rawContent(
        decision: String,
        proposalID: UUID,
        revision: Int64?,
        sha256: String?,
        origin: DecisionOrigin = .user
    ) -> String {
        prefix + " The user \(decision) proposal \(proposalID.uuidString)"
            + (revision.map { " at revision \($0)" } ?? "")
            + (sha256.map { " (sha256 \($0.prefix(12))…)" } ?? "")
            + closingClause
            + (origin == .user ? "" : " Origin: \(origin.rawValue).")
    }

    /// True only for the trusted system decision notice whose id is the
    /// deterministic derivation this app writes. User/assistant text and every
    /// unrecognized system notice return nil.
    static func trustedEvent(in message: PersistedMessage) -> DecisionEvent? {
        guard message.role == "system" else { return nil }
        return derivedEvent(id: message.id, conversationID: message.conversationID,
                            content: message.content)
    }

    /// Strict shape validation. Returns the parsed event only when every
    /// literal segment matches AND rebuilding the template from the parsed
    /// fields reproduces the content exactly.
    static func parse(_ content: String) -> DecisionEvent? {
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
        func isSingleLineField(_ value: String) -> Bool {
            !value.isEmpty
                && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                && value.rangeOfCharacter(from: .newlines) == nil
        }
        guard consume(prefix + " The user "),
              let decision = take(upTo: " proposal "),
              isSingleLineField(decision),
              remainder.count >= 36
        else { return nil }
        // The writer always emits `UUID.uuidString` (canonical uppercase).
        let uuidField = String(remainder.prefix(36))
        guard let proposalID = UUID(uuidString: uuidField),
              proposalID.uuidString == uuidField
        else { return nil }
        remainder = remainder.dropFirst(36)
        var revision: Int64?
        var sha256Prefix: String?
        if remainder.hasPrefix(" at revision ") {
            _ = consume(" at revision ")
            if let shaRange = remainder.range(of: " (sha256 ") {
                let digits = String(remainder[..<shaRange.lowerBound])
                guard let value = Int64(digits), String(value) == digits else { return nil }
                revision = value
                // Leave the sha literal for the segment below to consume.
                remainder = remainder[shaRange.lowerBound...]
            } else {
                guard remainder.hasSuffix(closingClause) else { return nil }
                let digits = String(remainder.dropLast(closingClause.count))
                guard let value = Int64(digits), String(value) == digits else { return nil }
                revision = value
                remainder = remainder[
                    remainder.index(remainder.endIndex, offsetBy: -closingClause.count)...]
            }
        }
        if consume(" (sha256 ") {
            guard let sha = take(upTo: "…"),
                  sha.count == 12,
                  !sha.contains(where: { $0.isWhitespace }),
                  consume(")")
            else { return nil }
            sha256Prefix = sha
        }
        guard consume(closingClause) else { return nil }
        var origin: DecisionOrigin = .user
        if consume(" Origin: ") {
            guard let rawOrigin = take(upTo: "."),
                  let parsed = DecisionOrigin(rawValue: rawOrigin)
            else { return nil }
            origin = parsed
        }
        guard remainder.isEmpty else { return nil }
        let event = DecisionEvent(
            decision: decision, proposalID: proposalID,
            revision: revision, sha256Prefix: sha256Prefix, origin: origin)
        guard rawContent(
            decision: event.decision, proposalID: event.proposalID,
            revision: event.revision, sha256: event.sha256Prefix,
            origin: event.origin) == content
        else { return nil }
        return event
    }

    /// The server-owned linkage `id == f(conversation, proposal, decision)`.
    /// Only `recordProposalDecision` writes that id; a user-typed message (or
    /// a row created by any other path) carries a random id and fails this.
    static func isDerivedEventID(
        _ id: UUID, conversationID: UUID, event: DecisionEvent
    ) -> Bool {
        id == ThreadNoticeIdentity.proposalDecisionID(
            conversationID: conversationID,
            proposalID: event.proposalID,
            decision: event.decision)
    }

    /// Parses the content and requires the deterministic derivation of `id`.
    static func derivedEvent(
        id: UUID, conversationID: UUID, content: String
    ) -> DecisionEvent? {
        guard let event = parse(content),
              isDerivedEventID(id, conversationID: conversationID, event: event)
        else { return nil }
        return event
    }

    /// Concise localized conversation summary for a validated decision notice.
    /// Returns nil for every other message so callers keep the existing raw
    /// text.
    static func userFacingSummary(for message: PersistedMessage) -> String? {
        guard trustedEvent(in: message) != nil else { return nil }
        return FloeL10n.l(summaryKey)
    }

    /// Pending-input queue projection: that row carries no role, so the
    /// deterministic derivation is required in addition to the exact event
    /// shape. A message a user typed can never match both.
    static func userFacingSummary(for input: PendingUserInput) -> String? {
        guard derivedEvent(
            id: input.id, conversationID: input.conversationID,
            content: input.content) != nil
        else { return nil }
        return FloeL10n.l(summaryKey)
    }
}

/// The user-facing projection over the internal notices this app writes into
/// a transcript: the design-assistant adoption confirmation (which carries a
/// single-use grant) and the structured proposal decision. Each notice keeps
/// its durable bytes; only the presentation/export surfaces consult this.
enum InternalNoticeProjection {
    static func userFacingSummary(for message: PersistedMessage) -> String? {
        DesignConfirmationNoticeProjection.userFacingSummary(for: message)
            ?? ProposalDecisionNoticeProjection.userFacingSummary(for: message)
    }

    static func userFacingSummary(for input: PendingUserInput) -> String? {
        DesignConfirmationNoticeProjection.userFacingSummary(for: input)
            ?? ProposalDecisionNoticeProjection.userFacingSummary(for: input)
    }

    /// External-export projection. Only the confirmation carries a credential
    /// (the single-use grant); the decision notice exports its structured
    /// evidence verbatim, so this returns nil for it.
    static func exportContent(for message: PersistedMessage) -> String? {
        DesignConfirmationNoticeProjection.exportContent(for: message)
    }
}

#endif
