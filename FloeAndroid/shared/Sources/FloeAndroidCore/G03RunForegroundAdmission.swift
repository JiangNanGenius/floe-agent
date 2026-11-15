// SPDX-License-Identifier: MPL-2.0
//
// G03-R4 — real App-host foreground admission for an AUTOMATIC parent run
// resume (job-7b4afa8bc6784bce).
//
// A parked run whose required background dependency settled is continued
// WITHOUT a UI action. Before this seam existed the automatic resume went
// straight from `beginUserResume` to `ownedLaunchTasks`, so a resumed
// provider/tool turn ran with NO real foreground-service protection: the
// job's own durable lease had just been retired and `RunForegroundBinding`
// only ever SETTLED leases on a trusted zero (it never acquires from counts).
//
// This file adds the missing trusted handshake over the EXISTING generic
// `LinuxShellMailbox` host-operation lane (the same lane `host.jobOwnership`,
// `host.serviceReadiness` and the workspace preflights already use):
//
//   Swift run domain  --host.runOwnership{epoch,runID,conversationID,action}-->
//   trusted Kotlin host pump --RunForegroundBinding.agentRunStarted(runID)-->
//   ORIGINAL RunForegroundController (AGENT_RUN lease, exact Stop callback)
//
// Rules (unchanged authorities):
//  * The host performs the REAL acquisition; the reply is a typed decision,
//    never an inference from counts. Unbound/fenced/refused is a truthful
//    refusal and the run stays parked with all of its data intact.
//  * Only the trusted host mailbox sees this operation. It is NOT a BridgeV3
//    command, NOT a model tool and NOT a public action/schema value.
//  * The lease is keyed by the ORIGINAL native run UUID in Swift canonical
//    form, so a notification Stop for the resumed run reaches the existing
//    `run.cancel` route exactly like a user-launched run.
//  * A resume that abandons its committed admission releases the exact lease
//    through `action:release`; a handed-off run keeps it until the original
//    owned-work settlement (terminal/ledger-zero) releases it.

import Foundation
import CoreFoundation
import FloeCore
import FloeAndroidJobTools
import FloeAndroidShellTools

/// Closed outcome of ONE foreground reservation request for an automatic
/// parent-run resume. `unbound` (no live host pump / no binding) is kept
/// distinct from a typed refusal so the caller can report the truth without
/// guessing and without a blind retry loop.
public enum RunForegroundAdmissionOutcome: Sendable, Equatable {
    /// The App host holds a REAL foreground lease for this exact run.
    case admitted
    /// The host answered and refused (OS restriction, owner conflict, fence).
    case refused
    /// No trusted host pump/binding answered this generation.
    case unbound
}

/// Trusted-host-only foreground reservation port for the automatic resume.
/// Implemented by the LinuxShellMailbox host operation in production and by
/// focused fakes in the regression suite.
public protocol RunForegroundAdmissionPort: Sendable {
    func admit(epoch: UInt64, runID: UUID, conversationID: UUID) async
        -> RunForegroundAdmissionOutcome
    func release(epoch: UInt64, runID: UUID) async
}

/// Strict, bounded production client over the ORIGINAL `LinuxShellMailbox`.
public struct MailboxRunForegroundAdmission: RunForegroundAdmissionPort {
    public static let operation = "host.runOwnership"
    /// A foreground-service start is bounded exactly like the job-ownership
    /// handshake (15 s). A budget expiry is an honest UNCONFIRMED refusal:
    /// the parked run keeps its data and an explicit Continue may retry.
    public static let timeoutMillis = 15_000

    public init() {}

    public func admit(epoch: UInt64, runID: UUID,
                      conversationID: UUID) async -> RunForegroundAdmissionOutcome {
        await submit(epoch: epoch, runID: runID,
                     conversationID: conversationID, action: "acquire")
    }

    public func release(epoch: UInt64, runID: UUID) async {
        _ = await submit(epoch: epoch, runID: runID,
                         conversationID: nil, action: "release")
    }

    private func submit(epoch: UInt64, runID: UUID,
                        conversationID: UUID?, action: String) async
        -> RunForegroundAdmissionOutcome {
        let payload: Data
        do {
            var fields: [String: Any] = [
                "epoch": epoch,
                "runID": runID.uuidString,
                "action": action,
            ]
            if let conversationID { fields["conversationID"] = conversationID.uuidString }
            payload = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        } catch {
            return .refused
        }
        let reply: Data
        do {
            reply = try await LinuxShellMailbox.shared.submit(
                operation: Self.operation, payload: payload,
                timeoutMillis: Self.timeoutMillis, expectedEpoch: epoch)
        } catch let error as LinuxShellTransportError {
            switch error {
            case .notBound, .hostFenced, .waitBudgetExpired:
                // No trustworthy answer from THIS generation (or no answer in
                // the bounded window): never a fabricated admission.
                return .unbound
            default:
                return .refused
            }
        } catch {
            return .refused
        }
        guard reply.count <= LinuxShellMailboxLimits.maximumFrameBytes,
              let object = (try? JSONSerialization.jsonObject(with: reply))
                as? [String: Any] else {
            return .unbound
        }
        // The host echoes the accepted epoch inside the reply; a foreign
        // generation's answer is unknown, never admitted.
        guard let echoed = object["epoch"] as? NSNumber,
              CFGetTypeID(echoed) == CFNumberGetTypeID(),
              echoed.uint64Value == epoch else {
            return .unbound
        }
        if action == "release" { return .admitted }
        switch object["state"] as? String {
        case "admitted":
            return object["accepted"] as? Bool == true ? .admitted : .refused
        case "unbound":
            return .unbound
        case "fenced", "refused":
            return .refused
        default:
            return .unbound
        }
    }
}
