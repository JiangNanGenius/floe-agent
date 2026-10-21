// SPDX-License-Identifier: MPL-2.0
//
// RB2 — config command binding handoff for the future RB1 registry. REPAIR
// successor of job-d02beb16bd1840a9 (MC-R1 advanced revision + honest sidecar
// stage; MC-R3 clear/delete projection never claims "provablyAbsent" from a
// validation rejection; MC-R4 physical settlement + pendingReconciliation
// surfaced as closed typed fields). (private source candidate; NOT compiled,
// NOT executed).
//
// This file REGISTERS NOTHING. Synchronous binder handlers on JNI threads are
// the mailbox/receipt domain of RB-1 (contract asyncJniDesign: a handler may
// only validate + enqueue + return the queue receipt; it must never await an
// actor). RB2 instead provides the concrete typed async processor RB1's
// mailbox drain calls:
//
//   `ModelConfigurationCommandRouter.handle(command:envelope:) -> Data`
//
// returning ONE terminal response object per accepted command:
//   {"state":"completed", "value": ...}              reads + settled writes
//   {"errorCode": ..., "reason": ...}                typed rejection
// (BridgeEnvelopeV3 responseStates: completed in-frame for pure reads; the
// stateful/async families surface the SAME object through effect.poll under
// the applicationConfiguration scope — receipt/queue/pump semantics stay
// entirely outside RB2.)
//
// Command names are copied VERBATIM from the frozen 57-entry matrix
// (BridgeEnvelopeV3.swift:106-128); nothing here adds a name, label or ID.
// credential.status is already bound in v2 and is NOT re-advertised here.
// MCP/Skills (capability.* families) belong to RB6 and are NOT implemented
// or claimed by this package. Global agent defaults/usage belong to the
// separate FacadeSettingsDefaultsAdapter/FacadeUsageAdapter sources and are
// excluded here.
//
// Shape never grants authority: this router RE-PARSES only the closed fields
// it consumes and re-checks every domain revision against the actual stores
// (files 5/6). Model-authored JSON cannot mint provider identity, route,
// revision or ingress tokens with any effect.

import Foundation
import FloeCore
import FloeProviders
import FloePersistence
import FloeAndroidWebTools

// MARK: - Command identity

public enum ModelConfigurationCommand: String, Sendable, CaseIterable {
    case providersList = "config.providers.list"
    case providerSave = "config.provider.save"
    case providerDelete = "config.provider.delete"
    case providerProbe = "config.provider.probe"
    case modelsList = "config.models.list"
    case modelSave = "config.model.save"
    case catalogSearch = "config.catalog.search"
    case preferencesGet = "config.preferences.get"
    case preferencesSave = "config.preferences.save"
    case websearchGet = "config.websearch.get"
    case websearchSave = "config.websearch.save"

    /// The EXACT frozen handler keys RB1 registers (BridgeV3.handlerKey
    /// format "v3.command.<scope>.<command>", BridgeEnvelopeV3.swift:233-235).
    public var bridgeV3HandlerKey: String {
        "v3.command.applicationConfiguration.\(rawValue)"
    }

    /// Closed vocabulary of this domain; anything else is
    /// unsupportedOperation fail-closed, never opportunistically parsed.
    public static var supportedCommandNames: [String] {
        allCases.map { $0.rawValue }
    }
}

// MARK: - Router

public actor ModelConfigurationCommandRouter {
    private let facade: ModelConfigurationFacade

    public init(facade: ModelConfigurationFacade) {
        self.facade = facade
    }

    // MARK: Envelope field access (closed; defensive)

    private struct EnvelopeView {
        let payload: [String: Any]?
        let payloadRaw: Data?
        let revision: ConfigRevision?
        let cursor: String?

        init(envelope: [String: Any]) throws {
            var payload: [String: Any]?
            var payloadRaw: Data?
            if let payloadObject = envelope["payload"] as? [String: Any] {
                payload = payloadObject
                // payloadRaw re-serializes the parsed object with sorted
                // keys — canonical and stable for the closed DTOs below.
                if JSONSerialization.isValidJSONObject(payloadObject),
                   let data = try? JSONSerialization.data(withJSONObject: payloadObject,
                                                          options: [.sortedKeys]) {
                    payloadRaw = data
                }
            }
            var revision: ConfigRevision?
            if let revisionObject = envelope["revision"] as? [String: Any] {
                guard let resourceID = revisionObject["resourceID"] as? String,
                      let version = revisionObject["version"] as? String,
                      !resourceID.isEmpty, !version.isEmpty,
                      resourceID.utf8.count <= 256, version.utf8.count <= 256 else {
                    throw ConfigDomainError(code: .invalidEnvelope, reason: "revisionShape")
                }
                revision = ConfigRevision(resourceID: resourceID, version: version)
            } else if envelope["revision"] != nil {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "revisionPresentUnreadable")
            }
            var cursor: String?
            if let cursorObject = envelope["cursor"] as? [String: Any] {
                cursor = cursorObject["sequence"] as? String ?? cursorObject["cursor"] as? String
            } else if envelope["cursor"] != nil {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "cursorPresentUnreadable")
            }
            self.payload = payload
            self.payloadRaw = payloadRaw
            self.revision = revision
            self.cursor = cursor
        }

        /// Retained for documentation only: the frozen V3 validator refuses
        /// the envelope `cursor` role on `command.submit` (run-event poll
        /// only), so config read paging NEVER uses it — the authorized
        /// payload continuation (`pageCursor`) is the sole seam.
        var cursorIndex: Int? {
            guard let cursor else { return nil }
            guard let value = Int(cursor), value >= 0 else {
                return nil
            }
            return value
        }
    }

    private static func completed(_ valueJSON: Data) -> Data {
        let object: [String: Any] = [
            "state": "completed",
            "value": (try? JSONSerialization.jsonObject(with: valueJSON)) ?? NSNull(),
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{\"errorCode\":\"invalidJSON\",\"reason\":\"resultEncode\"}".utf8)
    }

    private static func completed(_ object: [String: Any]) -> Data {
        let wrapped: [String: Any] = ["state": "completed", "value": object]
        return (try? JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys]))
            ?? Data("{\"errorCode\":\"invalidJSON\",\"reason\":\"resultEncode\"}".utf8)
    }

    private static func rejected(_ error: ConfigDomainError) -> Data {
        let object: [String: Any] = ["errorCode": error.code.rawValue,
                                     "reason": error.reason]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{\"errorCode\":\"invalidJSON\",\"reason\":\"rejectEncode\"}".utf8)
    }

    // MARK: Single entry point

    /// Handles ONE applicationConfiguration command envelope; returns the
    /// terminal response bytes. Never throws: every failure is a typed
    /// rejected object (frozen wire codes). RB1 records/polls this result;
    /// RB2 never mints receipts and never claims queue acceptance.
    public func handle(command: String, envelope: [String: Any]) async -> Data {
        guard let op = ModelConfigurationCommand(rawValue: command) else {
            return Self.rejected(ConfigDomainError(code: .unsupportedOperation,
                                                  reason: "commandOutsideRB2"))
        }
        let view: EnvelopeView
        do {
            view = try EnvelopeView(envelope: envelope)
        } catch let error as ConfigDomainError {
            return Self.rejected(error)
        } catch {
            return Self.rejected(ConfigDomainError(code: .invalidEnvelope, reason: "envelopeView"))
        }
        do {
            let value: Data
            switch op {
            case .providersList:
                // Closed read payload: optional host snapshot operation plus
                // the single OPTIONAL bounded continuation cursor (Main
                // MAIN_CONFIG_READ_PAGING_DECISION_20261021). First-page
                // payloads stay valid; the envelope cursor role is unchanged
                // (run-event only) and the facade re-checks the original
                // composer bounds.
                var providersCursor: Int?
                if let payload = view.payload {
                    try ConfigJSON.closed(payload,
                                          allowed: ["operation", "cursor"],
                                          context: "providersList")
                    providersCursor = try ModelConfigurationFacade.pageCursor(from: payload)
                }
                value = try await facade.listProviders(cursor: providersCursor)
                return Self.completed(value)
            case .modelsList:
                var providerID: UUID?
                var modelsCursor: Int?
                var modelRead: ConfigModelReadRequest?
                if let payload = view.payload {
                    // ADDITIVE closed opt-in member `modelRead` (job-
                    // 7d4d4e41017f4391): `modelRead:{}` starts an original
                    // full-row detail read and
                    // `modelRead:{id,digest,offset}` continues it on the
                    // SAME provider filter and row-index cursor. Without it
                    // the page grammar and behavior are EXACTLY the legacy
                    // ones (including the bounded `itemDoesNotFitPage`
                    // refusal); no new command tuple, no scope change, no
                    // envelope-cursor reinterpretation. A malformed or
                    // unknown-member modelRead refuses typed and is NEVER
                    // silently downgraded to a legacy page.
                    try ConfigJSON.closed(payload,
                                          allowed: ["providerID", "cursor", "modelRead"],
                                          context: "modelsList")
                    if let raw = payload["providerID"] as? String {
                        guard let parsed = UUID(uuidString: raw) else {
                            throw ConfigDomainError(code: .invalidEnvelope,
                                                    reason: "modelsListProviderID")
                        }
                        providerID = parsed
                    }
                    modelsCursor = try ModelConfigurationFacade.pageCursor(from: payload)
                    modelRead = try ConfigModelReadPayload.parse(payload["modelRead"])
                }
                value = try await facade.listModels(providerID: providerID,
                                                    cursor: modelsCursor,
                                                    modelRead: modelRead)
                return Self.completed(value)
            case .catalogSearch:
                guard let payload = view.payload,
                      let query = payload["query"] as? String else {
                    throw ConfigDomainError(code: .invalidEnvelope, reason: "catalogQueryMissing")
                }
                try ConfigJSON.closed(payload,
                                      allowed: ["query", "filter", "cursor"],
                                      required: ["query"],
                                      context: "catalogSearch")
                let filter = try ModelConfigurationFacade.catalogFilter(from: payload["filter"] as? String)
                let catalogCursor = try ModelConfigurationFacade.pageCursor(from: payload)
                value = try await facade.catalogSearch(query: query,
                                                       filter: filter,
                                                       cursor: catalogCursor)
                return Self.completed(value)
            case .preferencesGet:
                let reply = try await facade.getPreferences()
                return Self.completed([
                    "revision": ["resourceID": reply.revision.resourceID,
                                 "version": reply.revision.version],
                    "preferences": try JSONSerialization.jsonObject(with: reply.valueJSON),
                ])
            case .preferencesSave:
                guard let revision = view.revision,
                      let payload = view.payloadRaw else {
                    throw ConfigDomainError(code: .invalidEnvelope, reason: "preferencesSaveInputs")
                }
                let reply = try await facade.savePreferences(payload: payload, revision: revision)
                return Self.completed([
                    "revision": ["resourceID": reply.revision.resourceID,
                                 "version": reply.revision.version],
                    "preferences": try JSONSerialization.jsonObject(with: reply.valueJSON),
                ])
            case .modelSave:
                guard let revision = view.revision,
                      let payload = view.payloadRaw else {
                    throw ConfigDomainError(code: .invalidEnvelope, reason: "modelSaveInputs")
                }
                let reply = try await facade.saveModel(payload: payload, revision: revision)
                return Self.completed([
                    "revision": ["resourceID": reply.revision.resourceID,
                                 "version": reply.revision.version],
                    "model": try ConfigModelSnapshot.jsonObject(reply.canonicalModel),
                ])
            case .websearchGet:
                let reply = try await facade.getWebSearch()
                let objects = reply.states.map { $0.jsonObject() }
                return Self.completed([
                    "revision": ["resourceID": reply.revision.resourceID,
                                 "version": reply.revision.version],
                    "providers": objects,
                ])
            case .websearchSave:
                guard let revision = view.revision,
                      let payload = view.payloadRaw else {
                    throw ConfigDomainError(code: .invalidEnvelope, reason: "websearchSaveInputs")
                }
                let reply = try await facade.saveWebSearch(payload: payload, revision: revision)
                let objects = reply.states.map { $0.jsonObject() }
                return Self.completed([
                    "revision": ["resourceID": reply.revision.resourceID,
                                 "version": reply.revision.version],
                    "providers": objects,
                ])
            case .providerSave:
                return await handleProviderSave(view)
            case .providerDelete:
                guard let revision = view.revision else {
                    throw ConfigDomainError(code: .invalidEnvelope, reason: "deleteRevisionMissing")
                }
                let result = try await facade.deleteProvider(revision: revision)
                var cleanup: String
                var reason: String?
                switch result.secretCleanup {
                case .noneConfigured: cleanup = "noneConfigured"
                case .removed: cleanup = "removed"
                case .provablyAbsent(let r): cleanup = "provablyAbsent"; reason = r
                case .queuedForRetry(let r): cleanup = "queuedForRetry"; reason = r
                }
                var object: [String: Any] = [
                    "providerID": result.providerID.uuidString,
                    "secretCleanup": cleanup,
                ]
                object["secretCleanupReason"] = reason as Any
                return Self.completed(object)
            case .providerProbe:
                guard let payload = view.payload,
                      let raw = payload["providerID"] as? String,
                      let providerID = UUID(uuidString: raw) else {
                    throw ConfigDomainError(code: .invalidEnvelope, reason: "probeProviderID")
                }
                try ConfigJSON.closed(payload,
                                      allowed: ["providerID"],
                                      required: ["providerID"],
                                      context: "providerProbe")
                // Runs under the facade service lifetime; the drain Task is
                // RB1's owned operation. Cancellation yields the typed
                // cancelled outcome (read-only probe: provably no local
                // effect; nothing is auto-installed either way).
                let outcome = await facade.probeForEffect(providerID: providerID)
                return Self.completed(try outcome.jsonObject())
            }
        } catch let error as ConfigDomainError {
            return Self.rejected(error)
        } catch is CancellationError {
            return Self.rejected(ConfigDomainError(code: .runtimeUnavailable, reason: "cancelled"))
        } catch {
            return Self.rejected(ConfigDomainError(code: .runtimeUnavailable,
                                                   reason: "unclassifiedRefusal"))
        }
    }

    // MARK: provider.save closed request forms

    /// Set / Keep / Clear — one command name, three full forms — PLUS the
    /// CLOSED existing-row KEEP metadata variant (Main decision
    /// MAIN_PROVIDER_COMPACT_METADATA_DECISION_20261021), all bound to the
    /// ACTUAL ingress semantics (file 5). The form is decided ONLY from the
    /// closed payload shape:
    ///   set:      {"secretIntent":"set","ingressToken":"int:v1:<32hex>"}
    ///   keep:     {"secretIntent":"keep","candidate":{...}}
    ///   keep-meta:{"secretIntent":"keep","metadata":{"id":<uuid>,"isEnabled":<bool>}}
    ///   clear:    {"secretIntent":"clear","candidate":{...}}
    /// Raw candidate/secret JSON is refused by ConfigJSON's credential-name
    /// scan; the Set candidate body NEVER appears in the envelope (it lives
    /// only in the one-shot lease). `metadata` is mutually exclusive with
    /// candidate/ingressToken and valid ONLY under `keep`: any mixed form
    /// refuses BEFORE any effect. Large profiles reach the full-fidelity
    /// edit through the closed `modelSetRef` INSIDE the candidate (staged
    /// trusted-host set; exactly one of selectedModels/modelSetRef there).
    private func handleProviderSave(_ view: EnvelopeView) async -> Data {
        guard let payload = view.payload else {
            return Self.rejected(ConfigDomainError(code: .invalidEnvelope,
                                                   reason: "providerSaveMissingPayload"))
        }
        do {
            // Credential-name scan at the ACTUAL save-payload boundary, before
            // the closed-form whitelist: a smuggled `apiKey`/`api_key`/`token`
            // is reported as rawCredentialInputRejected rather than a generic
            // unknown-field refusal. (camelCase is folded by the scanner.)
            try ConfigJSON.assertNoCredentialNames(payload)
            try ConfigJSON.closed(payload,
                                  allowed: ["secretIntent", "ingressToken", "candidate",
                                            "metadata"],
                                  required: ["secretIntent"],
                                  context: "providerSave")
            guard let intent = payload["secretIntent"] as? String else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "providerSaveIntentShape")
            }
            let hasMetadata = payload["metadata"] != nil
            switch intent {
            case "set":
                guard let token = payload["ingressToken"] as? String,
                      payload["candidate"] == nil, !hasMetadata else {
                    throw ConfigDomainError(code: .invalidEnvelope, reason: "providerSaveSetInputs")
                }
                let execution = await facade.saveProviderSet(ingressToken: token,
                                                             envelopeRevision: view.revision)
                return Self.project(execution)
            case "keep":
                if hasMetadata {
                    // Mixed forms refuse PRE-EFFECT, before any ownership,
                    // DB or vault step.
                    guard payload["candidate"] == nil,
                          payload["ingressToken"] == nil else {
                        throw ConfigDomainError(code: .invalidEnvelope,
                                                reason: "providerSaveMixedForm")
                    }
                    let metadata = try requireMetadata(payload)
                    let execution = await facade.saveProviderMetadataEnabled(
                        providerID: metadata.providerID,
                        isEnabled: metadata.isEnabled,
                        envelopeRevision: view.revision)
                    return Self.project(execution)
                }
                let candidate = try requireCandidate(payload)
                let execution = await facade.saveProviderKeep(candidateJSON: candidate,
                                                              envelopeRevision: view.revision)
                return Self.project(execution)
            case "clear":
                guard !hasMetadata else {
                    throw ConfigDomainError(code: .invalidEnvelope,
                                            reason: "providerSaveMixedForm")
                }
                let candidate = try requireCandidate(payload)
                let execution = await facade.saveProviderClear(candidateJSON: candidate,
                                                               envelopeRevision: view.revision)
                return Self.project(execution)
            default:
                throw ConfigDomainError(code: .invalidEnvelope, reason: "providerSaveIntentUnknown")
            }
        } catch let error as ConfigDomainError {
            return Self.rejected(error)
        } catch {
            return Self.rejected(ConfigDomainError(code: .invalidEnvelope,
                                                   reason: "providerSaveUnreadable"))
        }
    }

    /// The closed metadata variant: exactly `{id,isEnabled}` with a real
    /// UUID string and an explicit JSON boolean. No generic record patch,
    /// no extra field, no coerced shape (Main approvedBoundary).
    private func requireMetadata(_ payload: [String: Any]) throws
        -> (providerID: UUID, isEnabled: Bool)
    {
        guard let metadataObject = payload["metadata"] as? [String: Any] else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "providerSaveMetadataShape")
        }
        try ConfigJSON.closed(metadataObject,
                              allowed: ["id", "isEnabled"],
                              required: ["id", "isEnabled"],
                              context: "providerSaveMetadata")
        guard let raw = metadataObject["id"] as? String,
              let providerID = UUID(uuidString: raw) else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "providerSaveMetadataID")
        }
        guard let isEnabled = metadataObject["isEnabled"] as? Bool else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "providerSaveMetadataFlag")
        }
        return (providerID, isEnabled)
    }

    private func requireCandidate(_ payload: [String: Any]) throws -> Data {
        guard let candidateObject = payload["candidate"] as? [String: Any],
              JSONSerialization.isValidJSONObject(candidateObject),
              let data = try? JSONSerialization.data(withJSONObject: candidateObject,
                                                     options: [.sortedKeys]) else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "providerSaveCandidateMissing")
        }
        // Scan the candidate subtree for raw-credential field names too
        // (ConfigJSON.object inside the executor re-checks, this is belt
        // for the wire boundary).
        let probe = try ConfigJSON.object(from: data)
        _ = probe
        return data
    }

    /// Frame budget for the committed VALUE document (Main's 2026-10-21
    /// full-fidelity output review). The ACTUAL effect-item ceiling is
    /// `RuntimeEffectItem.Limits.maximumItemEncodedBytes = 47_616`
    /// (FacadeEffectPump.swift:275 = 49_152 page - 1_536), and the mailbox
    /// converts an item that cannot fit into
    /// `failed(frameBudgetExceeded)` (FacadeCommandMailbox.swift:728-741) —
    /// which would FALSELY report an already-committed, readback-verified
    /// large save. This router does not own the item wrapper or the
    /// consumer-side escaping, so it bounds the completed VALUE object at
    /// 47_616 - 1_536 = 46_080 bytes of max(wire, canonical) serialized
    /// UTF-8. NO frame/page/payload budget changes: only the projection
    /// shape adapts (full list when it fits; otherwise an explicit bounded
    /// summary whose models live behind the existing authoritative
    /// `config.models.list` readback).
    static let maximumCommittedValueBytes = 46_080

    /// Terminal projection of the save execution. NEVER presents queue
    /// acceptance as saved state; `committed` carries ONLY post-readback
    /// canonical models + the honest sync flags; failures keep the recorded
    /// C0/C1 disposition so later lanes/UI can explain retry truthfully.
    /// A large commit is projected as an EXPLICIT summary (counts + the
    /// actual persisted revision + all settlement flags) rather than an
    /// oversized item the transport would have to refuse — Main's rule: a
    /// projection problem must never masquerade as a DB rollback or a lost
    /// terminal.
    static func project(_ execution: ProviderSaveExecution) -> Data {
        switch execution {
        case .committed(let committed):
            var models: [[String: Any]] = []
            for model in committed.canonicalModels {
                models.append((try? ConfigModelSnapshot.jsonObject(model)) ?? [:])
            }
            var object: [String: Any] = [
                "state": "committed",
                "providerID": committed.providerID.uuidString,
                "canonicalModels": models,
                "deletedModelIDs": committed.deletedModelIDs.map { $0.uuidString },
                "disabledModelIDs": committed.disabledModelIDs.map { $0.uuidString },
                // Explicit totals in EVERY committed shape (Main: expose
                // counts, never silently truncate; small saves keep the
                // full legacy arrays alongside).
                "canonicalModelCount": models.count,
                "deletedModelCount": committed.deletedModelIDs.count,
                "disabledModelCount": committed.disabledModelIDs.count,
                "syncPending": committed.syncPending,
                // MC-R1: the ACTUAL PERSISTED (advanced) provider revision.
                "revision": ["resourceID": committed.providerRevision.resourceID,
                             "version": committed.providerRevision.version],
                "leaseAdmissionCloseFailed": committed.leaseAdmissionCloseFailed,
                // MC-R1/R4 honest stage flags (never relabeled failures).
                "presetSidecarRecorded": committed.presetSidecarRecorded,
                "writeIntentFinalized": committed.writeIntentFinalized,
            ]
            // syncError stays an explicit JSON null when absent (never a
            // phantom string on ordinary local saves).
            object["syncError"] = committed.syncError ?? NSNull()
            if committed.metadataOnly {
                // Compact existing-row metadata commit (the models arrays
                // are legitimately empty here: NOTHING model-side was
                // written). Additive marker only; legacy consumers read
                // the same revision/flags.
                object["metadataOnly"] = true
            }
            let fullWire = FacadeFrameBudget.serializedBytes(object)
            let fullCanonical = FacadeFrameBudget.canonicalSerializedBytes(object) ?? fullWire
            if max(fullWire, fullCanonical) <= maximumCommittedValueBytes {
                return completedValue(object)
            }
            // Bounded, truthful summary for a proven-committed large
            // result: every settlement/ownership flag survives; the model
            // identity sets are reported as COUNTS with an explicit
            // projection marker and empty inline arrays. The authoritative
            // rows are already durable (the runner reached `committed`
            // only after the ORIGINAL readback passed), and both editors
            // re-read them through the existing bounded
            // `config.models.list` continuation — no new command, no
            // invented offset, no silent drop.
            var summary: [String: Any] = [
                "state": "committed",
                "projection": "summary",
                "providerID": committed.providerID.uuidString,
                "canonicalModels": [Any](),
                "deletedModelIDs": [Any](),
                "disabledModelIDs": [Any](),
                "canonicalModelCount": models.count,
                "deletedModelCount": committed.deletedModelIDs.count,
                "disabledModelCount": committed.disabledModelIDs.count,
                "syncPending": committed.syncPending,
                "revision": ["resourceID": committed.providerRevision.resourceID,
                             "version": committed.providerRevision.version],
                "leaseAdmissionCloseFailed": committed.leaseAdmissionCloseFailed,
                "presetSidecarRecorded": committed.presetSidecarRecorded,
                "writeIntentFinalized": committed.writeIntentFinalized,
            ]
            summary["syncError"] = committed.syncError ?? NSNull()
            if committed.metadataOnly { summary["metadataOnly"] = true }
            return completedValue(summary)
        case .failed(let failed):
            var object: [String: Any] = [
                "errorCode": failed.error.code.rawValue,
                "reason": failed.error.reason,
                "phase": failed.phase ?? NSNull(),
                "databaseRowWritten": failed.databaseRowWritten,
                "leaseAdmissionCloseFailed": failed.leaseAdmissionCloseFailed,
                // MC-R4: owner gate/registry lease retained (pending) — the
                // caller learns providerPendingReconciliation semantics.
                "pendingReconciliation": failed.pendingReconciliation,
            ]
            if let settlement = failed.physicalSettlement {
                object["physicalSettlement"] = Self.settlementName(settlement)
            }
            if let disposition = failed.secretDisposition {
                switch disposition {
                case .committed:
                    object["secretDisposition"] = "committed"
                case .effectAbsent(let reason):
                    object["secretDisposition"] = "effectAbsent"
                    object["secretDispositionReason"] = reason
                case .outcomeUnknown(let reason):
                    object["secretDisposition"] = "outcomeUnknown"
                    object["secretDispositionReason"] = reason
                }
            }
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data("{\"errorCode\":\"runtimeUnavailable\",\"reason\":\"rejectEncode\"}".utf8)
            return encoded
        case .cleared(let cleared):
            var object: [String: Any] = [
                "state": "cleared",
                "providerID": cleared.providerID.uuidString,
                "cleanupQueuedForRetry": cleared.cleanupQueuedForRetry,
                "leaseAdmissionCloseFailed": cleared.leaseAdmissionCloseFailed,
                "pendingReconciliation": cleared.pendingReconciliation,
            ]
            if let settlement = cleared.physicalSettlement {
                object["physicalSettlement"] = Self.settlementName(settlement)
            }
            switch cleared.cleanupDisposition {
            case .committed: object["secretCleanup"] = "removed"
            case .effectAbsent(let reason):
                // MC-R3: "this attempt did not mutate anything" is NOT
                // "the secret is absent"; the entry stays queued for honest
                // retry and the projection says so.
                object["secretCleanup"] = "attemptRejectedNoEffect"
                object["secretCleanupReason"] = reason
            case .outcomeUnknown(let reason):
                object["secretCleanup"] = "outcomeUnknown"
                object["secretCleanupReason"] = reason
            }
            return completedValue(object)
        }
    }

    /// MC-R4 closed settlement names (no raw status leakage; the numeric
    /// status is diagnostic detail kept in the reason channels only).
    static func settlementName(_ settlement: PhysicalSettlement) -> String {
        switch settlement {
        case .neverExecuted: return "neverExecuted"
        case .executionSettled: return "executionSettled"
        case .executionOutstanding: return "executionOutstanding"
        case .unobserved: return "unobserved"
        }
    }

    private static func completedValue(_ object: [String: Any]) -> Data {
        let wrapped: [String: Any] = ["state": "completed", "value": object]
        return (try? JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys]))
            ?? Data("{\"errorCode\":\"invalidJSON\",\"reason\":\"resultEncode\"}".utf8)
    }
}
