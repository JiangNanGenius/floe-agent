// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeAndroidJobTools
import FloeAndroidShellTools

/// Private Core-host proof query. Not a runtime completion operation or model tool.
public enum LinuxShellJobSettlement {
    private struct Query: Encodable {
        let epoch: UInt64
        let runID: UUID
        let jobID: UUID?
        let toolCallID: String?
        let sessionID: String?
        let cancellationRequested: Bool
    }
    private struct Reply: Decodable {
        let epoch: UInt64
        let state: String
        let sessionID: String?
        let cancelled: Bool?
        let stopReason: String?
        let exitCode: Int32?
        let termSig: Int32?
        let waitErrno: Int32?
        let workspaceStatus: String?
        let workspaceRecoveryRef: String?
        /// Present on the pump's positive pre-admission proof. Its presence
        /// binds the proof to an exact pump claim; the value itself is opaque
        /// to Core (Core never invents or compares pump-local ids).
        let requestID: String?
        /// Closed pre-admission reason token when the pump observed one.
        let reason: String?
    }

    /// Same bounded grammar the trusted host uses for refusal tokens.
    private static func boundedReason(_ reason: String?) -> String? {
        guard let reason, !reason.isEmpty,
              reason.range(of: "^[a-z][a-z0-9_]{0,47}$", options: .regularExpression) != nil
        else { return nil }
        return reason
    }

    /// Strict decode of ONE pump settlement reply. Extracted from [gate] so the
    /// proof rules are testable without a live mailbox: every semantic refusal
    /// keeps the job nonterminal, and only a positively proven not-started or
    /// quiescent answer may settle it (never a success claim).
    static func decode(proofBytes: Data, expectedEpoch: UInt64) throws -> JobShellSettlement {
        let proof = try JSONDecoder().decode(Reply.self, from: proofBytes)
        guard proof.epoch == expectedEpoch else {
            return .unconfirmed(reason: "foreign-generation")
        }
        switch proof.state {
        case "released":
            guard let session = proof.sessionID, !session.isEmpty,
                  let cancelled = proof.cancelled, proof.waitErrno == 0 else {
                return .unconfirmed(reason: "incomplete-terminal-proof")
            }
            // The typed Reply above decodes legacy and new proofs
            // UNCHANGED; the OPTIONAL recovery projection is strict-
            // parsed from the same raw bytes SEPARATELY, so a malformed
            // supplementary object can never turn a real release into an
            // unconfirmed settlement (it just stays absent).
            let recoveryObject = (try? JSONSerialization.jsonObject(with: proofBytes)) as? [String: Any]
            let recovery = LinuxShellWorkspaceRecovery.parse(recoveryObject?["workspaceRecovery"])
            return .released(sessionID: session, cancelled: cancelled, stopReason: proof.stopReason,
                exitCode: proof.exitCode, termSig: proof.termSig, waitErrno: proof.waitErrno,
                workspaceStatus: proof.workspaceStatus, workspaceRecoveryRef: proof.workspaceRecoveryRef,
                recovery: recovery)
        case "quiescent":
            return .quiescent(note: "Runtime recovery proved this request has no owned workload; command outcome is unknown.")
        case "not_started":
            // Positive proof requires the pump's own claim identity and the
            // ABSENCE of a session: a refused start never produced one. Any
            // other shape is incomplete and stays nonterminal.
            guard let requestID = proof.requestID, !requestID.isEmpty,
                  proof.sessionID == nil, proof.cancelled == nil else {
                return .unconfirmed(reason: "incomplete-not-started-proof")
            }
            return .notStarted(reason: boundedReason(proof.reason))
        default:
            return .unconfirmed(reason: "runtime-work-unresolved")
        }
    }

    public static let gate: JobShellSettlementGate = { query in
        let epoch = RuntimeFacadeLinuxBindings.shared.boundNativeEpoch
        guard epoch > 0 else { return .unconfirmed(reason: "native-generation-unbound") }
        do {
            let payload = try JSONEncoder().encode(Query(epoch: epoch, runID: query.runID,
                jobID: query.jobID, toolCallID: query.toolCallID, sessionID: query.lastKnownSessionID,
                cancellationRequested: query.cancellationRequested))
            let bytes = try await LinuxShellMailbox.shared.submit(operation: "host.shellSettlement",
                payload: payload, timeoutMillis: 15_000)
            return try decode(proofBytes: bytes, expectedEpoch: epoch)
        } catch { return .unconfirmed(reason: "runtime-proof-unavailable") }
    }
}
