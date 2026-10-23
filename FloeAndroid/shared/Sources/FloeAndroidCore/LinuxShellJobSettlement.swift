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
            let proof = try JSONDecoder().decode(Reply.self, from: bytes)
            guard proof.epoch == epoch else { return .unconfirmed(reason: "foreign-generation") }
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
                let recoveryObject = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
                let recovery = LinuxShellWorkspaceRecovery.parse(recoveryObject?["workspaceRecovery"])
                return .released(sessionID: session, cancelled: cancelled, stopReason: proof.stopReason,
                    exitCode: proof.exitCode, termSig: proof.termSig, waitErrno: proof.waitErrno,
                    workspaceStatus: proof.workspaceStatus, workspaceRecoveryRef: proof.workspaceRecoveryRef,
                    recovery: recovery)
            case "quiescent": return .quiescent(note: "Runtime recovery proved no owned workload; command outcome is unknown.")
            default: return .unconfirmed(reason: "runtime-work-unresolved")
            }
        } catch { return .unconfirmed(reason: "runtime-proof-unavailable") }
    }
}
