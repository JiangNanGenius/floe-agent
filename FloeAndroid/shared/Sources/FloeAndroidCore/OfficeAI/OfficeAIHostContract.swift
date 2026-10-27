// SPDX-License-Identifier: MPL-2.0
//
// G05-R2 Office AI (job-1db1a7a8d5da457a) — the EXACT Swift<->App-host wire
// contract for the Office AI lane. This file is the single authority for:
//  * the closed operation token set the trusted Kotlin host dispatches;
//  * the descriptor field allowlists + bounds (what travels as bounded JSON
//    control data vs. as staged bytes);
//  * the reply envelope grammar and its typed decode into the JobTools
//    contract types (never a stringly-typed pass-through);
//  * the failure-token vocabulary the host may answer (path-free);
//  * the `OfficeAIHostTransport` seam the bridge executes over (production =
//    `OfficeAIHostMailbox`; tests = a scripted transport).
//
// Nothing here is model-reachable: no V3 handler key, no command name, no
// bridge payload. Only the Core bridge (behind its own context/CAS fences)
// submits tickets, and only the epoch-bound Kotlin pump claims them.
//
// APP-HANDOFF CONTRACT: the Kotlin host package MUST implement exactly these
// operations, descriptors and replies (see API_READY.json for the consumer
// side; the pump/claims/settlement mechanics are delivered by
// floe_office_ai_jni.cpp + OfficeAiNative.kt + the App OfficeAiHostPump).

import Foundation
import FloeCore
import FloeTools
import FloeAndroidJobTools

// MARK: - Operation tokens (closed set)

public enum OfficeAIHostOperation: String, Sendable, Equatable {
    /// Owner-safe resolve-or-open through the EXISTING OfficePreviewController
    /// lifecycle (staging + the existing FloeShell viewer launch effect),
    /// awaited to real owned operation + engine edit readiness.
    case open = "office.open"
    /// Read-only ownedOperationSnapshot join + the ENGINE's own
    /// readGeneration/readState for the exact session token.
    case lookup = "office.lookup"
    /// One typed precision command (capture / read / selection / navigation /
    /// content apply) through OfficePrecisionClient on the exact
    /// session/generation/opId fence. The text parameter travels as STAGED
    /// bytes, never inside the descriptor.
    case command = "office.command"
    /// One typed save operation (WORKING_COPY_FLUSH or STAGED_EXPORT) over the
    /// App save-copy host's OWN transaction-20 binding, awaited to its REAL
    /// terminal receipt through the owned observer.
    case save = "office.save"
    /// Owned OOXML semantic inspection of a host-named package (fresh export
    /// or adopted durable artifact). Expectation text travels as STAGED bytes.
    case verify = "office.verify"
    /// Launch-reconciliation scan: find a real verified engine output of the
    /// exact export opId (never a summary string, never the newest guess).
    case reconcile = "office.reconcile"
    /// Provider original push through the EXISTING journal ladder on a
    /// headless runtime-owned lane.
    case pushOriginal = "office.pushOriginal"
}

// MARK: - Bounds

public enum OfficeAIHostLimits {
    public static let maximumDescriptorBytes = 2048
    /// Engine MAX_TEXT_BYTES + framing slack; staged bytes cap per ticket.
    public static let maximumStagedBytes = 96 * 1024
    /// Success reply JSON cap (a 256 KiB selection answer fits with room).
    public static let maximumReplyBytes = 1_048_576
    /// Failure reply body cap (code + bounded detail only).
    public static let maximumFailureReplyBytes = 256
    public static let maximumLiveTickets = 16
    public static let maximumRetired = 256
    public static let maximumCodeChars = 64
    /// Per-operation claim budgets (an unclaimed expiry is typed hostBudget).
    public static func budgetMillis(for operation: OfficeAIHostOperation) -> Int {
        switch operation {
        case .open: return 150_000
        case .lookup: return 30_000
        case .command: return 120_000
        case .save: return 180_000
        case .verify: return 120_000
        case .reconcile: return 60_000
        case .pushOriginal: return 300_000
        }
    }
}

// MARK: - Descriptor keys (allowlist per operation)

public enum OfficeAIHostField {
    public static let operation = "operation"
    public static let epoch = "epoch"
    public static let taskID = "taskID"
    public static let workspaceID = "workspaceID"
    public static let workspacePresent = "workspacePresent"
    public static let nativeEpoch = "nativeEpoch"
    public static let hostGeneration = "hostGeneration"
    public static let logicalPath = "logicalPath"
    public static let requestID = "requestID"
    public static let sessionToken = "sessionToken"
    public static let generation = "generation"
    public static let opId = "opId"
    public static let action = "action"
    public static let targetHandle = "targetHandle"
    public static let cellAddress = "cellAddress"
    public static let partId = "partId"
    public static let contentKind = "contentKind"
    public static let saveOperation = "saveOperation"
    public static let format = "format"
    public static let suggestedName = "suggestedName"
    public static let path = "path"
    public static let sha256 = "sha256"
    public static let byteCount = "byteCount"
    public static let expectCommand = "expectCommand"
    public static let expectPartIndex = "expectPartIndex"
    public static let preEditSha256 = "preEditSha256"
    public static let exportOpId = "exportOpId"
    /// Amendment/2 owned verification identity (verify descriptor only):
    /// which proof class this inspection belongs to plus the deterministic
    /// ORIGINAL stage opIds / captured native handle the host binds its proof
    /// to (never a collect/reconcile call's own identity, never model data).
    public static let verificationMode = "verificationMode"
    public static let effectOpId = "effectOpId"

    /// The closed descriptor key set per operation. The Kotlin host MUST
    /// refuse any descriptor containing a key outside this set (the delivered
    /// WorkspaceSourcePump `descriptor(...)` rule, mirrored).
    public static func allowedKeys(for operation: OfficeAIHostOperation) -> Set<String> {
        switch operation {
        case .open:
            return [operation.rawValue, epoch, taskID, workspaceID, nativeEpoch, hostGeneration,
                    logicalPath, requestID]
        case .lookup:
            return [operation.rawValue, epoch, taskID, workspaceID, workspacePresent, nativeEpoch]
        case .command:
            return [operation.rawValue, epoch, sessionToken, generation, opId, action, targetHandle,
                    cellAddress, partId, contentKind, taskID]
        case .save:
            return [operation.rawValue, epoch, sessionToken, generation, opId, saveOperation, format,
                    suggestedName]
        case .verify:
            // Amendment/2: additive owned-proof keys. `sessionToken`/
            // `generation`/`targetHandle` are required for a `liveEffect`
            // inspection (bound from the captured context by the bridge);
            // `taskID`/`verificationMode`/`effectOpId`/`exportOpId` bind the
            // proof to the owning operation's REAL original stage identities.
            return [operation.rawValue, epoch, path, sha256, format, expectCommand, cellAddress,
                    contentKind, expectPartIndex, preEditSha256,
                    taskID, verificationMode, effectOpId, exportOpId,
                    sessionToken, generation, targetHandle]
        case .reconcile:
            return [operation.rawValue, epoch, exportOpId, format]
        case .pushOriginal:
            return [operation.rawValue, epoch, taskID, workspaceID, nativeEpoch, hostGeneration,
                    logicalPath]
        }
    }
}

// MARK: - Transport seam

/// Typed settlement of one host ticket. Mirrors the delivered source-mailbox
/// vocabulary with the Office AI additions.
public enum OfficeAIHostTransportError: Error, Sendable, Equatable {
    case hostUnbound
    case hostClosed
    case hostFenced
    case saturated
    case hostBudget
    case remoteFailed(code: String, detail: String?)
    case oversized
}

extension OfficeAIHostTransportError {
    /// Map a transport settlement failure onto the JobTools typed error.
    public func relayed() -> OfficeEditHostError {
        switch self {
        case .hostUnbound, .hostClosed, .hostFenced:
            return .hostLaneUnavailable
        case .saturated:
            return .transport(code: "hostSaturated")
        case .hostBudget:
            // The host never claimed the ticket: NO effect was dispatched.
            return .rejected(code: "hostBudget",
                             detail: "The Office document host did not claim this operation; "
                                 + "nothing was dispatched.")
        case .oversized:
            return .rejected(code: "requestTooLarge",
                             detail: "This operation exceeds the bounded host transport.")
        case .remoteFailed(let code, let detail):
            return OfficeAIHostReply.failureError(code: code, detail: detail)
        }
    }
}

/// The seam the bridge executes over. Production = the epoch-bound
/// `OfficeAIHostMailbox`; tests inject a scripted transport.
public protocol OfficeAIHostTransport: Sendable {
    func isBound(to epoch: UInt64) -> Bool
    /// Submit one ticket. `descriptor` keys MUST already be restricted to
    /// `OfficeAIHostField.allowedKeys(for:)`; `staged` carries only the text
    /// parameter bytes (empty otherwise). Returns the raw success reply body.
    func submit(operation: OfficeAIHostOperation, descriptor: [String: String],
                staged: Data, cancellation: CancellationToken) async throws -> Data
}

// MARK: - Reply grammar

public enum OfficeAIHostReplyKey {
    public static let ok = "ok"
    public static let code = "code"
    public static let detail = "detail"
}

/// Typed failure-token mapping shared by BOTH sides (the Kotlin host answers
/// exactly these tokens; unknown tokens map to a retained, path-free
/// generic failure, never to a fabricated success).
public enum OfficeAIHostReply {
    /// Map one host failure token onto the JobTools typed error. The mapping
    /// is total: nothing decodes into success.
    public static func failureError(code: String, detail: String?) -> OfficeEditHostError {
        let boundedDetail = detail.map { String($0.prefix(240)) }
        switch code {
        // Transport / lifecycle
        case "transport", "bindingDead":
            return .transport(code: code)
        // Identity / fencing
        case "notOwner", "ownerMismatch", "sessionMismatch", "sessionEnding", "generationFenced",
             "laneFenced":
            return .rejected(code: code,
                             detail: boundedDetail ?? "The document host refused this operation: "
                                 + "the exact owner/session fence did not match a live owned document.")
        // Edit context
        case "editContextMissing", "editContextStale", "editContextConsumed":
            return .rejected(code: code,
                             detail: boundedDetail ?? "The captured edit context is no longer valid; "
                                 + "run document.office.edit read again. Nothing was dispatched.")
        // Document realm
        case "noOwnedDocument", "busy":
            return .noOwnedDocument(detail: boundedDetail ?? "No editable Office document owned by this "
                                    + "task is currently open and no explicit workspace document was "
                                    + "requested")
        case "notEditable", "engineNotReady":
            return .notEditable(detail: boundedDetail ?? "The open Office document is not editable-ready")
        case "unsupportedFamily", "unsupportedAction":
            return .unsupported(detail: boundedDetail ?? "This command is not supported for the "
                                + "document family")
        // Engine typed states (mirrors OfficePrecisionFailure names)
        case "applyConflict", "targetUnknown", "targetUnverified", "complexSelectionUnavailable",
             "answerTooLarge", "contentUnsafe", "requestTooLarge", "queueFull",
             "mutationInFlight", "saveInFlight", "staleAnswerQuarantine":
            return .failed(code: code,
                           detail: boundedDetail ?? "The precision engine refused or failed this "
                               + "operation before a proven effect")
        case "producerRejected", "internal":
            return .failed(code: code, detail: boundedDetail ?? "The engine reported a failure")
        // Save/export/flush states (mirrors OfficeSaveState/OfficeSaveFailureCode names)
        case "flushUnknown", "saveUnknown", "mountEndedWithoutAck", "timeoutWithoutAck":
            return .unknown(code: code,
                            detail: boundedDetail ?? "The save/export outcome is UNKNOWN inside the "
                                + "bounded window; the working copy and every prior output are "
                                + "retained. Do NOT replay automatically.")
        case "flushFailed", "ackWithoutVerifiableBytes", "outputMissing", "outputEmpty",
             "outputTooLarge", "outputTypeMismatch", "outputUnreadable", "staleAckQuarantine",
             "flushAlreadyInFlight", "exportAlreadyInFlight":
            return .failed(code: code,
                           detail: boundedDetail ?? "The engine reported that the saved bytes did NOT "
                               + "verify; nothing was published.")
        case "cancelledBeforeDispatch":
            return .failed(code: code, detail: boundedDetail ?? "The save was cancelled before dispatch.")
        // Original-save journal tokens (mirrors WorkspaceSourceHostController statuses / mapBodyCode)
        case "conflict", "sourceChangedSinceImport", "driftAtClaim", "rePickRequired", "revoked",
             "readOnly", "unbound", "journalRefused", "providerOffline":
            return .conflict(code: code,
                             detail: boundedDetail ?? "The original-save journal preserved recoverable "
                                 + "copies; nothing was overwritten or discarded.")
        // Semantic / verification
        case "verificationFailed", "semanticNotInspected", "packageUnreadable", "structureInvalid",
             "digestMismatch", "sizeMismatch", "ambiguousArtifact":
            return .verificationFailed(code: code,
                                       detail: boundedDetail ?? "The saved package did not independently "
                                           + "verify; no success is claimed.")
        default:
            return .transport(code: "unknownToken:\(String(code.prefix(OfficeAIHostLimits.maximumCodeChars)))")
        }
    }
}

// MARK: - Descriptor construction helpers (bridge side)

public enum OfficeAIHostDescriptor {
    /// Build one validated descriptor: every key must be in the operation's
    /// allowlist; every value is bounded and NUL/control-free. A violation is
    /// a bridge bug and throws — it must never reach the wire.
    public static func build(operation: OfficeAIHostOperation, epoch: UInt64,
                             fields: [String: String?]) throws -> [String: String] {
        var descriptor: [String: String] = [
            OfficeAIHostField.operation: operation.rawValue,
            OfficeAIHostField.epoch: String(epoch),
        ]
        let allowed = OfficeAIHostField.allowedKeys(for: operation)
        for (key, value) in fields {
            guard key != OfficeAIHostField.operation, key != OfficeAIHostField.epoch,
                  allowed.contains(key) else {
                throw FloeError.internalError("office host descriptor key not allowed: \(key)")
            }
            guard let value else { continue }
            guard value.utf8.count <= 512, !value.contains("\u{0}"),
                  value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
                throw FloeError.internalError("office host descriptor value rejected: \(key)")
            }
            descriptor[key] = value
        }
        let probe = (try? JSONSerialization.data(withJSONObject: descriptor,
                                                 options: [.sortedKeys])) ?? Data()
        guard probe.count <= OfficeAIHostLimits.maximumDescriptorBytes else {
            throw FloeError.internalError("office host descriptor over budget")
        }
        return descriptor
    }

    /// Parse a success reply body into a JSON object (strict, fail-closed).
    public static func parse(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Decode the failure-envelope shape `{"code": "...", "detail": "..."}`.
    public static func failure(from data: Data) -> (code: String, detail: String?) {
        let object = parse(data)
        let code = (object?[OfficeAIHostReplyKey.code] as? String).flatMap {
            !$0.isEmpty && $0.count <= OfficeAIHostLimits.maximumCodeChars ? $0 : nil
        } ?? "failed"
        let detail = object?[OfficeAIHostReplyKey.detail] as? String
        return (code, detail.map { String($0.prefix(240)) })
    }
}
