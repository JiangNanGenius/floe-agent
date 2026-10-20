// SPDX-License-Identifier: MPL-2.0
//
// G02 production composition — domain command binder + typed result mapper.
//
// `RuntimeFacadeBridge.install` binds only the foundation
// system/effect/event handlers. Every full G02 command in the frozen
// `planning/bridge-v3-command-matrix.golden.json` (84 rules / 19 labels)
// needs the same honest synchronous ingress: strict envelope field re-read,
// correlation dedupe, bounded receipt mint, bounded mailbox enqueue, and an
// immediate receipt-only JSON answer — plus an async mailbox processor that
// dispatches to the real domain service. This file provides that shared
// plumbing for the domains that do not self-install (model configuration,
// conversation history, memory/personalization, defaults/usage, privacy,
// attachment staging). Domains that DO self-install keep their own binder
// (RB4 runs, RB5 temporary, RB6 skills/MCP/capabilities).
//
// Honesty invariants preserved from RB1:
//   * queue acceptance is never a domain commit;
//   * no conversation/run/environment/job identity in the receipt answer;
//   * typed page/value results ride the RB1 `RuntimeEffectPayload` carrier
//     (48 KiB page budget / 64 KiB frame) — never JSON-as-detail-string and
//     never an empty success substitute;
//   * unregistered keys keep the unchanged fail-closed `runtimeUnavailable`
//     refusal — the frozen 84/19 matrix counts are not widened.
//
// This source is NOT compiled/executed by the authoring package.
import Foundation
import CoreFoundation
import FloeCore

enum G02DomainBinder {

    /// Registers the synchronous submit handler for one matrix command.
    /// `configurationScope` disambiguates the shared `content.read` key.
    static func registerSubmitHandler(scope: BridgeV3.Scope, command: String,
                                      configurationScope: String?) {
        let binderKey = BridgeV3.handlerKey(scope: scope, command: command)
        RuntimeCommandBinder.shared.register(
            binderKey,
            makeSubmitHandler(scope: scope, command: command,
                              configurationScope: configurationScope))
    }

    /// Registers the async mailbox processor for one matrix command.
    static func registerProcessor(_ registry: RuntimeDomainRegistry,
                                  handlerKey: String,
                                  body: @escaping @Sendable (RuntimeCommandEnvelopeJob) async -> RuntimeCommandResult) {
        registry.register(handlerKey: handlerKey,
                          processor: RuntimeAsyncProcessor(execute: body))
    }

    /// Registers one CONFIGURATION-SCOPE owner under a shared handler key
    /// (current RB1 registry API): the shared `content.read`
    /// applicationConfiguration key composes `conversations` and
    /// `personalization` owners without overwrite, and an unregistered
    /// label fails closed via the registry's scoped dispatch.
    static func registerScopedProcessor(_ registry: RuntimeDomainRegistry,
                                        handlerKey: String,
                                        configurationScope: String,
                                        body: @escaping @Sendable (RuntimeCommandEnvelopeJob) async -> RuntimeCommandResult) {
        registry.register(handlerKey: handlerKey,
                          configurationScope: configurationScope,
                          processor: RuntimeAsyncProcessor(execute: body))
    }

    // MARK: - Synchronous ingress (validate + enqueue + immediate receipt)

    /// Mirrors `RuntimeFacadeBridge.makeCommandSubmitHandler` exactly: a
    /// synchronous binder handler running on any JNI thread does ONLY
    /// bounded validation/dedupe/receipt/enqueue and returns promptly.
    private static func makeSubmitHandler(
        scope: BridgeV3.Scope, command: String,
        configurationScope: String?
    ) -> RuntimeCommandBinder.Handler {
        let binderKey = BridgeV3.handlerKey(scope: scope, command: command)
        return { data in
            guard let envelope = parseObject(data),
                  let correlation = envelope["correlationID"] as? String,
                  !correlation.isEmpty else {
                return errorJSON(error: "invalidEnvelope",
                                 reason: "malformedAfterValidation")
            }
            // Lifecycle-payload discipline applies to every G02 domain
            // command too: a payload can never select a host root/owner/
            // generation. (Domain body DTOs are validated again by the
            // async processor against their closed grammars.)
            guard let pumps = AndroidRuntimeBootstrap.currentPumps() else {
                return errorJSON(error: "runtimeUnavailable",
                                 reason: "bootstrapNotInstalled")
            }
            if pumps.mailbox.isAdmissionFenced {
                return errorJSON(error: "runtimeUnavailable",
                                 reason: RuntimeFacadeCode.alreadyDraining.rawValue)
            }
            if let existing = pumps.mailbox.liveReceipt(correlationID: correlation) {
                return receiptJSON(correlation: correlation, receipt: existing)
            }
            guard let receipt = pumps.effects.register(correlationID: correlation)
            else {
                return errorJSON(error: "runtimeUnavailable",
                                 reason: RuntimeFacadeCode.receiptSaturated.rawValue)
            }
            // The shared `content.read` key serves several configuration
            // labels: stamp the job with the ENVELOPE's validated label so
            // one processor can dispatch honestly per label.
            let envelopeScope = envelope["configurationScope"] as? String
                ?? configurationScope
            let job = RuntimeCommandEnvelopeJob(
                correlationID: correlation,
                handlerKey: binderKey,
                command: command,
                scope: scope,
                configurationScope: envelopeScope,
                receipt: receipt,
                envelope: data)
            switch pumps.mailbox.submit(job) {
            case .queued:
                return receiptJSON(correlation: correlation, receipt: receipt)
            case .duplicate(let existing):
                return receiptJSON(correlation: correlation, receipt: existing)
            case .rejected(let code):
                return errorJSON(error: "runtimeUnavailable", reason: code.rawValue)
            }
        }
    }

    // MARK: - Typed result mapping

    /// Frozen carrier contract (Main decision 2026-10-20): the effect
    /// `value`/`page` documents are OBJECT-only
    /// (`RuntimeEffectDocumentProjection.isValidObject`); the carrier itself
    /// is never widened. A bare LIST document from the direct domain page
    /// APIs (the `ConfigPageComposer` provider/model/catalog shape) is
    /// therefore composed into the explicit OBJECT wrapper
    /// `{"rows":[…]}` HERE, at the domain-to-carrier binding boundary.
    /// Command names, scopes, labels, the direct domain API and its paging
    /// schema stay unchanged; only the already-required carrier composition
    /// is explicit. Scalars, unknown documents and true oversize pages keep
    /// their existing typed refusals (an oversized list never smuggles
    /// through: the composer still measures actual serialized bytes before
    /// this point and the frame budget still applies after it).
    static func listCarrierDocument(_ value: DesignJSONValue) -> DesignJSONValue {
        guard case .array(let items) = value else { return value }
        return .object(["rows": .array(items)])
    }

    /// Maps one domain router/service reply to the settlement result.
    /// Completed values/pages ride the typed carrier; typed wire errors stay
    /// honest typed terminals (never a fabricated empty success).
    static func completedValue(_ value: DesignJSONValue,
                               detail: [String: String]? = nil) -> RuntimeCommandResult {
        RuntimeCommandResult(kind: .accepted, detail: detail,
                             value: listCarrierDocument(value))
    }

    static func completedPage(_ page: DesignJSONValue,
                              detail: [String: String]? = nil) -> RuntimeCommandResult {
        RuntimeCommandResult(kind: .accepted, detail: detail,
                             page: listCarrierDocument(page))
    }

    /// Decode a router `Data` reply of the frozen shape
    /// `{"state":"completed","value":…}` / `{"state":"completed","page":…}`
    /// or `{"errorCode":…,"reason":…}` into a typed settlement. Unknown
    /// shapes fail closed with the typed persistenceUnavailable-class code.
    static func resultFromRouterReply(_ data: Data) -> RuntimeCommandResult {
        guard let object = parseObject(data) else {
            return .failed(.internal)
        }
        if let state = object["state"] as? String, state == "completed" {
            if let value = object["value"],
               let document = designValue(value) {
                return completedValue(document)
            }
            if let page = object["page"], let document = designValue(page) {
                return completedPage(document)
            }
            // Completed with no body is still a real completion of a
            // mutation command; keep the identifier-only detail honest.
            return .accepted()
        }
        if let errorCode = object["errorCode"] as? String {
            // The typed wire code + reason travel INSIDE the value carrier
            // so the App decode path stays exactly the frozen one.
            let body = DesignJSONValue.object([
                "errorCode": .string(errorCode),
                "reason": .string((object["reason"] as? String) ?? ""),
            ])
            return RuntimeCommandResult(kind: .failed, code: .ordinaryRuntimeBlocked,
                                        detail: ["wire": errorCode],
                                        value: body)
        }
        return .failed(.internal)
    }

    /// Strict Foundation-object → `DesignJSONValue` conversion (Bool is never
    /// bridged to integer; null stays null; no lossy number rewriting).
    ///
    /// Number classification follows the proven canonical order already
    /// device-verified for `DesignJSONValue.from(foundation:)`
    /// (FloeCore/DesignCanvasMetadata.swift:82-139 + the on-device
    /// QualificationSeam json-kind smoke): the public CF Boolean type ID is
    /// checked BEFORE any `as? Bool`/`as? NSNumber` conditional cast,
    /// because on this toolchain an NSNumber holding 0/1 satisfies
    /// `as? Bool` (the historical misclassification Main's decision called
    /// out), while a genuine Int8 and a CFBoolean both report objCType "c"
    /// and are only separated by the CF runtime type. Signed/unsigned
    /// integer encodings stay exact (`int64Value`/`uint64Value` — no
    /// `doubleValue` round trip, so values beyond 2^53 and UInt64 above
    /// Int64.max keep their digits); decimals stay exact; only true
    /// floating encodings may use the lossless-when-integral integer
    /// normalization. Unknown encodings and unknown values (including a
    /// boxed `Optional.none`, which must instead be projected as an
    /// explicit `NSNull()` by the domain) still refuse typed — never a
    /// string/description fallback.
    static func designValue(_ any: Any) -> DesignJSONValue? {
        if any is NSNull { return .null }
        if let number = any as? NSNumber {
            #if canImport(CoreFoundation)
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            #endif
            if let decimal = number as? NSDecimalNumber,
               !decimal.isEqual(to: NSDecimalNumber.notANumber) {
                return .decimal(decimal.decimalValue)
            }
            switch String(cString: number.objCType) {
            case "c", "i", "s", "l", "q":
                return .integer(number.int64Value)
            case "C", "I", "S", "L", "Q":
                let unsigned = number.uint64Value
                if unsigned <= UInt64(Int64.max) {
                    return .integer(Int64(unsigned))
                }
                return .unsigned(unsigned)
            case "f", "d":
                let double = number.doubleValue
                if double == double.rounded(), double.isFinite,
                   abs(double) <= 9_007_199_254_740_991 {
                    return .integer(number.int64Value)
                }
                return .number(double)
            default:
                return nil
            }
        }
        if let flag = any as? Bool { return .bool(flag) }
        if let string = any as? String { return .string(string) }
        if let array = any as? [Any] {
            var items: [DesignJSONValue] = []
            items.reserveCapacity(array.count)
            for item in array {
                guard let converted = designValue(item) else { return nil }
                items.append(converted)
            }
            return .array(items)
        }
        if let object = any as? [String: Any] {
            var pairs: [String: DesignJSONValue] = [:]
            pairs.reserveCapacity(object.count)
            for (key, item) in object {
                guard let converted = designValue(item) else { return nil }
                pairs[key] = converted
            }
            return .object(pairs)
        }
        return nil
    }

    // MARK: - Envelope field helpers for domain processors

    /// The typed payload of one job envelope (nil when absent). Converts
    /// through the strict JSON union so Bool/number/null distinctions are
    /// preserved for the closed settings-domain grammars.
    static func settingsPayload(_ job: RuntimeCommandEnvelopeJob)
        -> SettingsDomainV1.JSONValue? {
        guard let object = parseObject(job.envelope) else { return nil }
        guard let payload = object["payload"] else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys]) else {
            return nil
        }
        return RunPayloadReader.decode(data)
    }

    /// The envelope owner taskID as a UUID (conversation identity).
    static func taskID(_ job: RuntimeCommandEnvelopeJob) -> UUID? {
        guard let object = parseObject(job.envelope),
              let owner = object["owner"] as? [String: Any],
              let raw = owner["taskID"] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    /// The envelope revision as a BaseRevision (resourceID + version).
    static func baseRevision(_ job: RuntimeCommandEnvelopeJob) -> BaseRevision? {
        guard let object = parseObject(job.envelope),
              let revision = object["revision"] as? [String: Any],
              let resourceID = revision["resourceID"] as? String,
              let version = revision["version"] as? String else { return nil }
        return BaseRevision(resourceID: resourceID, version: version)
    }

    /// Typed domain-error settlement: the exact wire code + reason travel in
    /// the value carrier; the settlement itself is a typed `failed` (never a
    /// fabricated success, never a JSON-as-detail-string).
    static func wireError(_ errorCode: String, reason: String?) -> RuntimeCommandResult {
        let body: [String: DesignJSONValue] = [
            "errorCode": .string(errorCode),
            "reason": .string(reason ?? ""),
        ]
        return RuntimeCommandResult(kind: .failed, code: .ordinaryRuntimeBlocked,
                                    detail: ["wire": errorCode],
                                    value: .object(body))
    }

    static func internalError() -> RuntimeCommandResult {
        RuntimeCommandResult(kind: .failed, code: .internal)
    }

    /// Encode one Codable P0 DTO reply into the typed value carrier.
    static func completedEncodable<T: Encodable>(_ value: T,
                                                 detail: [String: String]? = nil) -> RuntimeCommandResult {
        guard let data = try? JSONEncoder().encode(value),
              let any = try? JSONSerialization.jsonObject(with: data),
              let document = designValue(any) else {
            return .failed(.frameBudgetExceeded)
        }
        return completedValue(document, detail: detail)
    }

    /// Encode one wire-object reply (the RB3 reply shape) into the carrier.
    static func completedWireObject(_ wireObject: [String: Any],
                                    detail: [String: String]? = nil) -> RuntimeCommandResult {
        guard let document = designValue(wireObject) else {
            return .failed(.frameBudgetExceeded)
        }
        return completedValue(document, detail: detail)
    }

    // MARK: - JSON helpers (frozen shapes, same as RB1)

    static func parseObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func receiptJSON(correlation: String, receipt: String) -> Data {
        let object: [String: Any] = [
            "ok": true,
            "schema": BridgeV3.commandSchema,
            "correlationID": correlation,
            "queued": true,
            "operationReceiptID": receipt,
        ]
        return (try? JSONSerialization.data(withJSONObject: object,
                                            options: [.sortedKeys]))
            ?? Data("{\"ok\":false,\"error\":\"runtimeUnavailable\",\"reason\":\"frameBudgetExceeded\"}".utf8)
    }

    static func errorJSON(error: String, reason: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": error,
                                                      "reason": reason],
                                     options: [.sortedKeys]))
            ?? Data("{\"ok\":false,\"error\":\"runtimeUnavailable\"}".utf8)
    }
}
