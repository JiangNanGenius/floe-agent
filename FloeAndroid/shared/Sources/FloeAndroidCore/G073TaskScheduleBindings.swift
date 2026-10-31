// SPDX-License-Identifier: MPL-2.0
//
// G07.3B — scheduled-task binding surface.
//
// This file is the ONE stable seam between the epoch-owned scheduling
// service and (a) the trusted host command table, (b) the process-wide
// `task.schedule` agent tool, and (c) the real run domain. It deliberately
// contains no scheduler business logic: every mutation goes through
// `G073TaskScheduleService` over the durable SQLite occurrence ledger.
//
// Command matrix (Main adds the entries; scope is the existing
// `applicationConfiguration` with label `schedule`):
//
//   schedule.list            (read,  bounded 50)
//   schedule.get             (read,  one record)
//   schedule.options         (read,  workspaces/models/environments/runs)
//   schedule.create          (create intent)
//   schedule.update          (revision)
//   schedule.enable          (revision)
//   schedule.disable         (revision)
//   schedule.delete          (revision)
//   schedule.runNow          (revision)
//   schedule.history         (read,  bounded 50)
//   schedule.dispatch        (platform wake; no revision)
//   schedule.rearm           (platform boot/init plans)
//   schedule.dispatchPending (app-alive after-success drain)
//
// `schedule.dispatch`/`rearm`/`dispatchPending` are platform/worker entries,
// not user content: every value they accept is validated and every launch
// still re-enters the ordinary run admission and permission system.
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloePersistence

// MARK: - Facade (one service per accepted epoch)

public enum G073TaskScheduleFacade {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var live:
        (epoch: UInt64, service: G073TaskScheduleService)?

    @discardableResult
    public static func install(epoch: UInt64,
                               service: G073TaskScheduleService) -> Bool {
        guard service.epoch == epoch else { return false }
        lock.lock()
        live = (epoch, service)
        lock.unlock()
        return true
    }

    public static func current(epoch: UInt64) -> G073TaskScheduleService? {
        lock.lock(); defer { lock.unlock() }
        guard let live, live.epoch == epoch else { return nil }
        return live.service
    }

    public static func uninstall(epoch: UInt64) {
        lock.lock()
        if live?.epoch == epoch { live = nil }
        lock.unlock()
    }

    internal static func clearForTesting() {
        lock.lock(); live = nil; lock.unlock()
    }
}

// MARK: - Real run-domain launch port

/// Bridges the scheduling service to the accepted `FacadeRunDomain`. The
/// lookup happens at launch time so the composition can install the service
/// before the run domain without creating a cycle; a retired epoch refuses
/// typed and never falls back to another generation.
public struct G073RunDomainLaunchPort: G073ScheduledRunLaunching {
    public let epoch: UInt64
    public init(epoch: UInt64) { self.epoch = epoch }

    public func launchScheduled(_ request: G073ScheduledLaunchRequest) async
        -> G073ScheduledLaunchResult {
        guard let domain = RunDomainFacade.current(epoch: epoch)?.0 else {
            return .refused(code: "runDomainUnbound",
                            reason: "The task runtime is not ready.")
        }
        let reply = await domain.startScheduled(request)
        switch reply.outcome {
        case .mutationAccepted:
            return .accepted()
        case .rejected(let error):
            return .refused(code: "\(error.code.rawValue):\(error.reason.rawValue)",
                            reason: error.reason.rawValue)
        case .completedPage:
            return .refused(code: "invalidState:payloadInvalid",
                            reason: "The scheduled launch returned a read reply.")
        }
    }
}

// MARK: - Wire parsing helpers

enum G073WireDate {
    static func parse(_ value: SettingsDomainV1.JSONValue?) -> Date? {
        guard let value else { return nil }
        switch value {
        case .integer(let millis):
            return Date(timeIntervalSince1970: Double(millis) / 1_000)
        case .fractional(let seconds):
            return Date(timeIntervalSince1970: seconds)
        case .string(let raw):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)
        default:
            return nil
        }
    }

    static func string(_ date: Date?) -> DesignJSONValue {
        guard let date else { return .null }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .string(formatter.string(from: date))
    }
}

enum G073WireValue {
    /// Conservative serialized budget for ONE schedule command VALUE
    /// document. The effect body budget is the 48 KiB page budget minus the
    /// actual frame wrapper; 40 KiB leaves room for that wrapper and for the
    /// canonical/wire encoding difference. Every measurement below uses the
    /// ACTUAL serialized UTF-8 size (JSON escaping included), never character
    /// counts, so a Unicode/quote-heavy label cannot overflow the 64 KiB
    /// bridge frame into an opaque carrier failure.
    static let maximumValueBytes = 40 * 1024

    static func serializedBytes(_ value: DesignJSONValue) -> Int {
        FacadeFrameBudget.serializedBytes(
            RuntimeEffectDocumentProjection.foundationObject(value))
    }

    /// Whole-item budget for one array section. Items are added only while
    /// their ACTUAL serialized size fits; the remainder is reported through
    /// the caller's count/truncation fields (never a partial/broken row and
    /// never a truncated identifier).
    static func boundedItems<T>(_ items: [T], capBytes: Int,
                                encode: (T) -> DesignJSONValue)
        -> (items: [DesignJSONValue], truncated: Bool) {
        var encoded: [DesignJSONValue] = []
        var used = 2 // brackets
        for item in items {
            let value = encode(item)
            let size = serializedBytes(value) + 1
            if used + size > capBytes { return (encoded, true) }
            used += size
            encoded.append(value)
        }
        return (encoded, false)
    }

    static func optional(_ value: String?) -> DesignJSONValue {
        guard let value else { return .null }
        return .string(value)
    }

    static func optional(_ value: UUID?) -> DesignJSONValue {
        guard let value else { return .null }
        return .string(value.uuidString)
    }

    static func summary(_ value: G073ScheduleSummary) -> DesignJSONValue {
        .object([
            "id": .string(value.id.uuidString),
            "title": .string(G073WireText.truncated(value.title, 160)),
            "promptPreview": .string(value.promptPreview),
            "cadence": .string(value.cadence.rawValue),
            "enabled": .bool(value.isEnabled),
            "scheduledAt": G073WireDate.string(value.scheduledAt),
            "weekday": value.weekday.map { DesignJSONValue.integer(Int64($0)) } ?? .null,
            "intervalSeconds": value.intervalSeconds.map { .integer(Int64($0)) } ?? .null,
            "anchorTimezone": optional(value.anchorTimezone),
            "nextFireAt": G073WireDate.string(value.nextFireAt),
            "lastStartedAt": G073WireDate.string(value.lastStartedAt),
            "modelID": optional(value.modelID),
            "modelName": value.modelName.map {
                .string(G073WireText.truncated($0, 120))
            } ?? .null,
            "environmentID": optional(value.environmentID),
            "environmentName": value.environmentName.map {
                .string(G073WireText.truncated($0, 120))
            } ?? .null,
            "workspaceID": optional(value.workspaceID),
            "workspaceName": value.workspaceName.map {
                .string(G073WireText.truncated($0, 120))
            } ?? .null,
            "approvalMode": .string(value.policy.approvalMode.rawValue),
            "recoveryPolicy": .string(value.policy.recoveryPolicy.rawValue),
            "notificationPolicy": .string(value.policy.notificationPolicy.rawValue),
            "upstreamRunID": optional(value.upstreamRunID),
            "revision": .string(value.revision),
            "needsAttention": .bool(value.needsAttention),
            "lastOccurrence": value.lastOccurrence.map(occurrence) ?? .null,
        ])
    }

    static func occurrence(_ value: G073ScheduleOccurrenceSummary) -> DesignJSONValue {
        .object([
            "id": .string(value.id.uuidString),
            "state": .string(value.state.rawValue),
            "scheduledFor": G073WireDate.string(value.scheduledFor),
            "startedAt": G073WireDate.string(value.startedAt),
            "finishedAt": G073WireDate.string(value.finishedAt),
            "runID": optional(value.runID),
            "conversationID": optional(value.conversationID),
            "summary": optional(value.summary),
            "errorText": optional(value.errorText),
        ])
    }

    static func detail(_ value: G073ScheduleDetail) -> DesignJSONValue {
        .object([
            "summary": summary(value.summary),
            "prompt": .string(value.prompt),
            "createdAt": G073WireDate.string(value.createdAt),
            "updatedAt": G073WireDate.string(value.updatedAt),
            "policyJSON": .string(value.policyJSON),
        ])
    }

    static func options(_ value: G073ScheduleOptions) -> DesignJSONValue {
        // Per-section actual-byte caps keep the whole document well inside
        // the effect frame even with 100 models + 50 workspaces + 50
        // environments + 20 runs of escaped Unicode labels. Each section
        // reports its TRUE total in `counts`; `truncated` is true when any
        // visible section is shorter than the authority list.
        let workspaces = boundedItems(value.workspaces, capBytes: 8 * 1024) {
            .object(["id": .string($0.id.uuidString),
                     "name": .string(G073WireText.truncated($0.name, 120))])
        }
        let models = boundedItems(value.models, capBytes: 12 * 1024) {
            .object(["id": .string($0.id.uuidString),
                     "providerID": .string($0.providerID.uuidString),
                     "displayName": .string(G073WireText.truncated($0.displayName, 120)),
                     "providerName": .string(G073WireText.truncated($0.providerName, 120))])
        }
        let environments = boundedItems(value.environments, capBytes: 8 * 1024) {
            .object(["id": .string($0.id),
                     "name": .string(G073WireText.truncated($0.name, 120))])
        }
        let runChoices = boundedItems(value.upstreamRunChoices, capBytes: 8 * 1024) {
            .object(["runID": .string($0.runID.uuidString),
                     "conversationID": .string($0.conversationID.uuidString),
                     "label": .string(G073WireText.truncated($0.label, 160)),
                     "state": .string($0.state),
                     "startedAt": G073WireDate.string($0.startedAt),
                     "workspaceID": optional($0.workspaceID)])
        }
        let truncated = workspaces.truncated || models.truncated
            || environments.truncated || runChoices.truncated
        return .object([
            "workspaces": .array(workspaces.items),
            "models": .array(models.items),
            "environments": .array(environments.items),
            "runChoices": .array(runChoices.items),
            "counts": .object([
                "workspaces": .integer(Int64(value.workspaces.count)),
                "models": .integer(Int64(value.models.count)),
                "environments": .integer(Int64(value.environments.count)),
                "runChoices": .integer(Int64(value.upstreamRunChoices.count)),
            ]),
            "truncated": .bool(truncated),
            "defaultModelID": optional(value.defaultModelID),
            "currentTimezone": .string(value.currentTimezone),
            "environmentSelectionAvailable": .bool(value.environmentSelectionAvailable),
        ])
    }

    static func mutation(_ value: G073ScheduleMutationResult,
                         scheduleID: UUID) -> DesignJSONValue {
        let full = DesignJSONValue.object([
            "accepted": .bool(value.accepted),
            "schedule": value.detail.map(detail) ?? .null,
            "revision": optional(value.revision),
            "scheduleID": .string(scheduleID.uuidString),
        ])
        guard serializedBytes(full) > maximumValueBytes else { return full }
        // The mutation ALREADY committed. Report the same success with the
        // bounded summary projection instead of allowing an oversized
        // prompt/policy escape to turn a real commit into an opaque carrier
        // failure (which the UI could wrongly retry as a create).
        return .object([
            "accepted": .bool(value.accepted),
            "schedule": value.detail.map { summary($0.summary) } ?? .null,
            "revision": optional(value.revision),
            "scheduleID": .string(scheduleID.uuidString),
            "projection": .string("summary"),
        ])
    }

    static func outcome(_ value: G073ScheduleDispatchOutcome) -> DesignJSONValue {
        .object([
            "state": .string(value.state.rawValue),
            "scheduleID": .string(value.scheduleID.uuidString),
            "occurrenceID": optional(value.occurrenceID),
            "runID": optional(value.runID),
            "conversationID": optional(value.conversationID),
            "nextFireAt": G073WireDate.string(value.nextFireAt),
            "code": optional(value.code?.rawValue),
            "reason": value.reason.map { .string(G073WireText.truncated($0, 240)) } ?? .null,
        ])
    }

    static func armPlan(_ value: G073ScheduleArmPlan) -> DesignJSONValue {
        .object([
            "scheduleID": .string(value.scheduleID.uuidString),
            "nextFireAt": G073WireDate.string(value.nextFireAt),
            "cadence": .string(value.cadence.rawValue),
            "eventDriven": .bool(value.eventDriven),
            "enabled": .bool(value.isEnabled),
        ])
    }
}

enum G073WireText {
    static func truncated(_ raw: String, _ limit: Int) -> String {
        guard raw.utf8.count > limit else { return raw }
        var result = ""
        var count = 0
        for character in raw {
            let bytes = String(character).utf8.count
            if count + bytes > limit { break }
            result.append(character)
            count += bytes
        }
        return result
    }
}

// MARK: - Envelope + payload

struct G073ParsedEnvelope: Sendable {
    var payload: SettingsDomainV1.JSONValue?
    var revision: (resourceID: String, version: String)?
}

enum G073ScheduleEnvelope {
    static func parse(_ data: Data) -> G073ParsedEnvelope? {
        guard let object = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any] else { return nil }
        var payload: SettingsDomainV1.JSONValue?
        if let raw = object["payload"],
           JSONSerialization.isValidJSONObject(raw),
           let payloadData = try? JSONSerialization.data(withJSONObject: raw) {
            payload = SettingsDomainV1.JSONValue.decode(payloadData)
        }
        var revision: (String, String)?
        if let raw = object["revision"] as? [String: Any],
           let resourceID = raw["resourceID"] as? String,
           let version = raw["version"] as? String,
           !resourceID.isEmpty, !version.isEmpty {
            revision = (resourceID, version)
        }
        return G073ParsedEnvelope(payload: payload, revision: revision)
    }

    static func object(_ payload: SettingsDomainV1.JSONValue?,
                       allowed: Set<String>) -> RunPayloadReader.Object? {
        try? RunPayloadReader.Object(payload ?? .object([:]), allowed: allowed)
    }
}

// MARK: - Command plan + registration

public enum G073TaskScheduleBindings {
    public static let configurationScope = "schedule"

    public struct CommandSpec: Sendable, Equatable {
        public var name: String
        public var revisionRequired: Bool
        public var createIntent: Bool
        public init(name: String, revisionRequired: Bool = false,
                    createIntent: Bool = false) {
            self.name = name
            self.revisionRequired = revisionRequired
            self.createIntent = createIntent
        }
    }

    /// The exact closed command list Main adds to the frozen matrix.
    public static let commands: [CommandSpec] = [
        CommandSpec(name: "schedule.list"),
        CommandSpec(name: "schedule.get"),
        CommandSpec(name: "schedule.options"),
        CommandSpec(name: "schedule.create", revisionRequired: true, createIntent: true),
        CommandSpec(name: "schedule.update", revisionRequired: true),
        CommandSpec(name: "schedule.enable", revisionRequired: true),
        CommandSpec(name: "schedule.disable", revisionRequired: true),
        CommandSpec(name: "schedule.delete", revisionRequired: true),
        CommandSpec(name: "schedule.runNow", revisionRequired: true),
        CommandSpec(name: "schedule.history"),
        CommandSpec(name: "schedule.dispatch"),
        CommandSpec(name: "schedule.rearm"),
        CommandSpec(name: "schedule.dispatchPending"),
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installedKeys: [UInt64: [String]] = [:]

    /// Registers the synchronous submit handlers and async processors for the
    /// epoch. Returns the exact keys installed (Main records them for its
    /// retirement bookkeeping, mirroring every other domain lane).
    @discardableResult
    public static func install(epoch: UInt64,
                               registry: RuntimeDomainRegistry) -> [String] {
        var keys: [String] = []
        for spec in commands {
            let key = BridgeV3.handlerKey(scope: .applicationConfiguration,
                                          command: spec.name)
            RuntimeCommandBinder.shared.register(key, makeSubmitHandler(command: spec.name))
            registry.register(handlerKey: key,
                              configurationScope: configurationScope,
                              processor: RuntimeAsyncProcessor { job in
                await handle(job: job, epoch: epoch)
            })
            keys.append(key)
        }
        lock.lock()
        installedKeys[epoch] = keys
        lock.unlock()
        return keys
    }

    public static func uninstall(epoch: UInt64) {
        lock.lock()
        let keys = installedKeys.removeValue(forKey: epoch) ?? []
        lock.unlock()
        for key in keys {
            RuntimeCommandBinder.shared.unregister(key)
            // RuntimeDomainRegistry has no scoped unregister for processors;
            // the registry is generation-owned and discarded with the epoch,
            // so only the binder key must be removed synchronously.
        }
    }

    private static func makeSubmitHandler(command: String) -> RuntimeCommandBinder.Handler {
        let key = BridgeV3.handlerKey(scope: .applicationConfiguration,
                                      command: command)
        return { data in
            guard let object = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any],
                  let correlation = object["correlationID"] as? String,
                  !correlation.isEmpty else {
                return errorJSON(error: "invalidEnvelope",
                                 reason: "malformedAfterValidation")
            }
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
            guard let receipt = pumps.effects.register(correlationID: correlation) else {
                return errorJSON(error: "runtimeUnavailable",
                                 reason: RuntimeFacadeCode.receiptSaturated.rawValue)
            }
            let job = RuntimeCommandEnvelopeJob(
                correlationID: correlation,
                handlerKey: key,
                command: command,
                scope: .applicationConfiguration,
                configurationScope: configurationScope,
                receipt: receipt,
                envelope: data)
            switch pumps.mailbox.submit(job) {
            case .queued(let queuedReceipt):
                return receiptJSON(correlation: correlation, receipt: queuedReceipt)
            case .duplicate(let existing):
                return receiptJSON(correlation: correlation, receipt: existing)
            case .rejected(let code):
                return errorJSON(error: "runtimeUnavailable", reason: code.rawValue)
            }
        }
    }

    private static func receiptJSON(correlation: String, receipt: String) -> Data {
        let object: [String: Any] = [
            "ok": true,
            "schema": BridgeV3.commandSchema,
            "correlationID": correlation,
            "queued": true,
            "operationReceiptID": receipt,
        ]
        return (try? JSONSerialization.data(withJSONObject: object,
                                            options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"error":"runtimeUnavailable"}"#.utf8)
    }

    private static func errorJSON(error: String, reason: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": error,
                                                      "reason": reason],
                                     options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"error":"runtimeUnavailable"}"#.utf8)
    }

    // MARK: Async command dispatch

    public static func handle(job: RuntimeCommandEnvelopeJob,
                              epoch: UInt64) async -> RuntimeCommandResult {
        guard let envelope = G073ScheduleEnvelope.parse(job.envelope) else {
            return failure(.invalidPayload, "The schedule payload could not be read.")
        }
        guard let service = G073TaskScheduleFacade.current(epoch: epoch) else {
            return failure(.storeUnavailable, "The scheduling service is not ready.")
        }
        switch job.command {
        case "schedule.list":
            return await handleList(envelope, service: service)
        case "schedule.get":
            return await handleGet(envelope, service: service)
        case "schedule.options":
            return await handleOptions(envelope, service: service)
        case "schedule.create":
            return await handleCreate(envelope, service: service)
        case "schedule.update":
            return await handleUpdate(envelope, service: service)
        case "schedule.enable":
            return await handleEnabled(envelope, service: service, enabled: true)
        case "schedule.disable":
            return await handleEnabled(envelope, service: service, enabled: false)
        case "schedule.delete":
            return await handleDelete(envelope, service: service)
        case "schedule.runNow":
            return await handleRunNow(envelope, service: service)
        case "schedule.history":
            return await handleHistory(envelope, service: service)
        case "schedule.dispatch":
            return await handleDispatch(envelope, service: service)
        case "schedule.rearm":
            return await handleRearm(service: service)
        case "schedule.dispatchPending":
            return await handleDispatchPending(envelope, service: service)
        default:
            return failure(.invalidPayload, "Unknown schedule command.")
        }
    }

    // MARK: Command bodies

    private static func handleList(_ envelope: G073ParsedEnvelope,
                                   service: G073TaskScheduleService) async
        -> RuntimeCommandResult {
        guard let object = G073ScheduleEnvelope.object(
            envelope.payload, allowed: ["limit", "offset"]) else {
            return failure(.invalidPayload, "Invalid schedule list payload.")
        }
        let requested = ((try? object.optionalInteger("limit", min: 1, max: 50)) ?? nil)
        let requestedOffset = ((try? object.optionalInteger(
            "offset", min: 0, max: 10_000)) ?? nil)
        let page = await service.listPage(limit: Int(requested ?? 50),
                                          offset: Int(requestedOffset ?? 0))
        // Whole summaries only; a pathological escape-heavy page is cut with
        // TRUE totals so the App can continue from the next offset instead of
        // receiving an opaque frame-budget failure.
        let bounded = G073WireValue.boundedItems(
            page.schedules, capBytes: 34 * 1024, encode: G073WireValue.summary)
        let offset = Int(requestedOffset ?? 0)
        let returned = bounded.items.count
        return success(.object([
            "schedules": .array(bounded.items),
            "count": .integer(Int64(returned)),
            "totalCount": .integer(Int64(page.totalCount)),
            "offset": .integer(Int64(offset)),
            "nextOffset": .integer(Int64(offset + returned)),
            "hasMore": .bool(offset + returned < page.totalCount),
            "truncated": .bool(bounded.truncated),
        ]))
    }

    private static func handleGet(_ envelope: G073ParsedEnvelope,
                                  service: G073TaskScheduleService) async
        -> RuntimeCommandResult {
        guard let object = G073ScheduleEnvelope.object(envelope.payload,
                                                       allowed: ["scheduleID"]),
              let id = try? object.uuid("scheduleID"),
              let detail = await service.detail(id: id) else {
            return failure(.notFound, "No schedule with that identifier.")
        }
        let value = G073WireValue.detail(detail)
        guard G073WireValue.serializedBytes(value)
                <= G073WireValue.maximumValueBytes else {
            // The stored record is valid but cannot be carried whole inside
            // the bounded frame. Never truncate the prompt/policy silently;
            // return an actionable typed refusal the App can explain.
            return failure(.payloadTooLarge,
                           "This scheduled task is too large to display in the editor.")
        }
        return success(value)
    }

    private static func handleOptions(_ envelope: G073ParsedEnvelope,
                                      service: G073TaskScheduleService) async
        -> RuntimeCommandResult {
        guard let object = G073ScheduleEnvelope.object(
            envelope.payload, allowed: ["environments"]) else {
            return failure(.invalidPayload, "Invalid schedule options payload.")
        }
        if object.optional("environments") != nil {
            guard let metadata = parseEnvironmentMetadata(object) else {
                return failure(.invalidPayload, "Invalid environment metadata.")
            }
            await service.registerEnvironmentMetadata(metadata)
        }
        return success(G073WireValue.options(await service.options()))
    }

    private static func handleCreate(_ envelope: G073ParsedEnvelope,
                                     service: G073TaskScheduleService) async
        -> RuntimeCommandResult {
        guard let object = G073ScheduleEnvelope.object(envelope.payload,
                                                       allowed: draftKeys),
              let draft = parseDraft(object) else {
            return failure(.invalidPayload, "Invalid schedule draft.")
        }
        let result = await service.create(draft)
        guard result.accepted, let detail = result.detail else {
            return failure(result.code ?? .invalidPayload,
                           result.reason ?? "The schedule could not be created.")
        }
        return success(G073WireValue.mutation(result, scheduleID: detail.summary.id))
    }

    private static func handleUpdate(_ envelope: G073ParsedEnvelope,
                                     service: G073TaskScheduleService) async
        -> RuntimeCommandResult {
        guard let object = G073ScheduleEnvelope.object(
            envelope.payload, allowed: draftKeys.union(["scheduleID"])),
            let id = try? object.uuid("scheduleID"),
            let draft = parseDraft(object),
            let revision = envelope.revision,
            revision.resourceID == G073ScheduleRevision.resourceID(scheduleID: id) else {
            return failure(.revisionMismatch, "The schedule revision is required.")
        }
        let result = await service.update(id: id, draft: draft,
                                          expectedRevision: revision.version)
        guard result.accepted else {
            return failure(result.code ?? .invalidPayload,
                           result.reason ?? "The schedule could not be updated.")
        }
        return success(G073WireValue.mutation(result, scheduleID: id))
    }

    private static func handleEnabled(_ envelope: G073ParsedEnvelope,
                                      service: G073TaskScheduleService,
                                      enabled: Bool) async -> RuntimeCommandResult {
        guard let object = G073ScheduleEnvelope.object(envelope.payload,
                                                       allowed: ["scheduleID"]),
              let id = try? object.uuid("scheduleID"),
              let revision = envelope.revision,
              revision.resourceID == G073ScheduleRevision.resourceID(scheduleID: id) else {
            return failure(.revisionMismatch, "The schedule revision is required.")
        }
        let result = await service.setEnabled(id: id, enabled: enabled,
                                              expectedRevision: revision.version)
        guard result.accepted else {
            return failure(result.code ?? .invalidPayload,
                           result.reason ?? "The schedule could not be updated.")
        }
        return success(G073WireValue.mutation(result, scheduleID: id))
    }

    private static func handleDelete(_ envelope: G073ParsedEnvelope,
                                     service: G073TaskScheduleService) async
        -> RuntimeCommandResult {
        guard let object = G073ScheduleEnvelope.object(envelope.payload,
                                                       allowed: ["scheduleID"]),
              let id = try? object.uuid("scheduleID"),
              let revision = envelope.revision,
              revision.resourceID == G073ScheduleRevision.resourceID(scheduleID: id) else {
            return failure(.revisionMismatch, "The schedule revision is required.")
        }
        let result = await service.delete(id: id,
                                          expectedRevision: revision.version)
        guard result.accepted else {
            return failure(result.code ?? .invalidPayload,
                           result.reason ?? "The schedule could not be deleted.")
        }
        return success(G073WireValue.mutation(result, scheduleID: id))
    }

    private static func handleRunNow(_ envelope: G073ParsedEnvelope,
                                     service: G073TaskScheduleService) async
        -> RuntimeCommandResult {
        guard let object = G073ScheduleEnvelope.object(envelope.payload,
                                                       allowed: ["scheduleID"]),
              let id = try? object.uuid("scheduleID"),
              let revision = envelope.revision,
              revision.resourceID == G073ScheduleRevision.resourceID(scheduleID: id) else {
            return failure(.revisionMismatch, "The schedule revision is required.")
        }
        let outcome = await service.runNow(id: id,
                                           expectedRevision: revision.version)
        // Explicit "run now" reports a truthful QUEUED occurrence: the App's
        // foreground-admitted dispatcher performs the actual claim/launch.
        // Accepting `.launched` too is defensive for a same-actor caller that
        // already settled the occurrence; no other state is a success.
        switch outcome.state {
        case .queued, .launched:
            return success(G073WireValue.outcome(outcome))
        default:
            return failure(outcome.code ?? .launchRefused,
                           outcome.reason ?? "The scheduled task could not be started.")
        }
    }

    private static func handleHistory(_ envelope: G073ParsedEnvelope,
                                      service: G073TaskScheduleService) async
        -> RuntimeCommandResult {
        guard let object = G073ScheduleEnvelope.object(
            envelope.payload, allowed: ["scheduleID", "limit"]),
              let id = try? object.uuid("scheduleID") else {
            return failure(.invalidPayload, "A schedule identifier is required.")
        }
        let requested = ((try? object.optionalInteger("limit", min: 1, max: 50)) ?? nil)
        let items = await service.history(id: id, limit: Int(requested ?? 20))
        let bounded = G073WireValue.boundedItems(
            items, capBytes: 34 * 1024, encode: G073WireValue.occurrence)
        return success(.object([
            "occurrences": .array(bounded.items),
            "count": .integer(Int64(bounded.items.count)),
            "totalCount": .integer(Int64(items.count)),
            "truncated": .bool(bounded.truncated),
        ]))
    }

    private static func handleDispatch(_ envelope: G073ParsedEnvelope,
                                       service: G073TaskScheduleService) async
        -> RuntimeCommandResult {
        guard let object = G073ScheduleEnvelope.object(
            envelope.payload,
            allowed: ["scheduleID", "trigger", "exactAlarmAllowed",
                      "flexibleChosen", "environments", "stopPending",
                      "occurrenceID"]),
              let id = try? object.uuid("scheduleID") else {
            return failure(.invalidPayload, "A valid dispatch request is required.")
        }
        // Additive internal Stop seam (same command, no new command name):
        // a pre-submit user Stop must durably cancel the intended pending
        // occurrence so no observer can launch it later. A PRESENT but
        // malformed stop field is refused; it is never silently treated as
        // a normal launch.
        var stopPending = false
        if object.optional("stopPending") != nil {
            guard let parsed = ((try? object.optionalBool("stopPending")) ?? nil)
            else { return failure(.invalidPayload, "Invalid stop request.") }
            stopPending = parsed
        }
        if stopPending {
            var occurrenceID: UUID?
            if object.optional("occurrenceID") != nil {
                guard let parsed = ((try? object.optionalUUID("occurrenceID")) ?? nil)
                else { return failure(.invalidPayload, "Invalid stop occurrence.") }
                occurrenceID = parsed
            }
            return success(G073WireValue.outcome(
                await service.cancelPendingOccurrence(
                    scheduleID: id, occurrenceID: occurrenceID)))
        }
        guard let triggerRaw = try? object.string("trigger", maxBytes: 24),
              let trigger = G073TaskScheduleService.DispatchRequest.Trigger(
                rawValue: triggerRaw) else {
            return failure(.invalidPayload, "A valid dispatch request is required.")
        }
        var metadata: [G073EnvironmentMetadata] = []
        if object.optional("environments") != nil {
            guard let parsed = parseEnvironmentMetadata(object) else {
                return failure(.invalidPayload, "Invalid environment metadata.")
            }
            metadata = parsed
        }
        let exactAllowed = ((try? object.optionalBool("exactAlarmAllowed")) ?? nil) ?? false
        let flexibleChosen = ((try? object.optionalBool("flexibleChosen")) ?? nil) ?? false
        let request = G073TaskScheduleService.DispatchRequest(
            scheduleID: id,
            trigger: trigger,
            exactAlarmAllowed: exactAllowed,
            flexibleChosen: flexibleChosen,
            environmentMetadata: metadata)
        return success(G073WireValue.outcome(await service.dispatch(request)))
    }

    private static func handleRearm(service: G073TaskScheduleService) async
        -> RuntimeCommandResult {
        let plans = await service.armPlans()
        let pending = await service.pendingScheduleIDs()
        return success(.object([
            "plans": .array(plans.map(G073WireValue.armPlan)),
            "count": .integer(Int64(plans.count)),
            "pendingScheduleIDs": .array(pending.map { .string($0.uuidString) }),
        ]))
    }

    private static func handleDispatchPending(_ envelope: G073ParsedEnvelope,
                                              service: G073TaskScheduleService) async
        -> RuntimeCommandResult {
        guard let object = G073ScheduleEnvelope.object(envelope.payload,
                                                       allowed: ["limit"]) else {
            return failure(.invalidPayload, "Invalid pending-dispatch payload.")
        }
        let requested = ((try? object.optionalInteger("limit", min: 1, max: 20)) ?? nil)
        let outcomes = await service.dispatchPending(limit: Int(requested ?? 3))
        return success(.object([
            "outcomes": .array(outcomes.map(G073WireValue.outcome)),
            "dispatched": .integer(Int64(outcomes.filter { $0.state == .launched }.count)),
        ]))
    }

    // MARK: Draft + metadata parsing

    private static let draftKeys: Set<String> = [
        "title", "prompt", "cadence", "scheduledAt", "weekday",
        "intervalSeconds", "anchorTimezone", "upstreamRunID",
        "workspaceID", "modelID", "environmentID", "approvalMode",
        "recoveryPolicy", "notificationPolicy",
    ]

    private static func parseDraft(_ object: RunPayloadReader.Object)
        -> G073ScheduleDraft? {
        guard let prompt = try? object.string("prompt",
                                              maxBytes: G073ScheduleLimits.maximumPromptBytes,
                                              nonBlank: true, trimmed: true),
              let cadenceRaw = try? object.string("cadence", maxBytes: 24),
              let cadence = TaskScheduleCadence(rawValue: cadenceRaw),
              let scheduledAtValue = object.optional("scheduledAt"),
              let scheduledAt = G073WireDate.parse(scheduledAtValue) else {
            return nil
        }
        let title = ((try? object.optionalString(
            "title", maxBytes: G073ScheduleLimits.maximumTitleBytes)) ?? nil) ?? ""
        let weekday = ((try? object.optionalInteger("weekday", min: 1, max: 7)) ?? nil)
        let interval = ((try? object.optionalInteger(
            "intervalSeconds", min: 60, max: 31_536_000)) ?? nil)
        let timezone = ((try? object.optionalString(
            "anchorTimezone", maxBytes: G073ScheduleLimits.maximumTimezoneBytes)) ?? nil)
        let upstream = ((try? object.optionalUUID("upstreamRunID")) ?? nil)
        let workspace = ((try? object.optionalUUID("workspaceID")) ?? nil)
        let model = ((try? object.optionalUUID("modelID")) ?? nil)
        let environment = ((try? object.optionalString("environmentID", maxBytes: 128)) ?? nil)
        let approvalRaw = ((try? object.optionalString("approvalMode", maxBytes: 24)) ?? nil)
        let recoveryRaw = ((try? object.optionalString("recoveryPolicy", maxBytes: 24)) ?? nil)
        let notificationRaw = ((try? object.optionalString(
            "notificationPolicy", maxBytes: 24)) ?? nil)
        let approval: TaskApprovalMode
        switch approvalRaw {
        case nil, "ask": approval = .ask
        case "automatic": approval = .automatic
        case "fullAccess": approval = .fullAccess
        default: return nil
        }
        let recovery: TaskRecoveryPolicy
        if let recoveryRaw {
            guard let parsed = TaskRecoveryPolicy(rawValue: recoveryRaw) else { return nil }
            recovery = parsed
        } else {
            recovery = .safePoint
        }
        let notification: TaskNotificationPolicy
        if let notificationRaw {
            guard let parsed = TaskNotificationPolicy(rawValue: notificationRaw) else {
                return nil
            }
            notification = parsed
        } else {
            notification = .stages
        }
        return G073ScheduleDraft(
            title: title,
            prompt: prompt,
            cadence: cadence,
            scheduledAt: scheduledAt,
            weekday: weekday,
            intervalSeconds: interval,
            anchorTimezone: timezone,
            upstreamRunID: upstream,
            workspaceID: workspace,
            modelID: model,
            environmentID: environment,
            policy: DraftTaskPolicy(approvalMode: approval,
                                    recoveryPolicy: recovery,
                                    notificationPolicy: notification))
    }

    /// Returns nil when the key is absent; `.some(nil)` when it is present but
    /// malformed (distinguished by the caller checking the raw key).
    private static func parseEnvironmentMetadata(_ object: RunPayloadReader.Object)
        -> [G073EnvironmentMetadata]? {
        guard let raw = try? object.optionalArray("environments", maxItems: 100) else {
            return nil
        }
        var result: [G073EnvironmentMetadata] = []
        for item in raw {
            guard case .object(let fields) = item else { return nil }
            let allowed: Set<String> = ["id", "kind", "ownerID", "name", "state",
                                        "requiresRebuild", "executionBackend",
                                        "parentID", "templateID"]
            guard Set(fields.keys).isSubset(of: allowed),
                  case .string(let id)? = fields["id"], !id.isEmpty,
                  id.utf8.count <= 128,
                  case .string(let kindRaw)? = fields["kind"],
                  let kind = G073EnvironmentMetadata.Kind(rawValue: kindRaw),
                  case .string(let state)? = fields["state"],
                  case .boolean(let rebuild)? = fields["requiresRebuild"] else {
                return nil
            }
            func optionalString(_ key: String) -> String? {
                if case .string(let value)? = fields[key] { return value }
                return nil
            }
            result.append(G073EnvironmentMetadata(
                id: id,
                kind: kind,
                ownerID: optionalString("ownerID"),
                name: optionalString("name"),
                state: state,
                requiresRebuild: rebuild,
                executionBackend: optionalString("executionBackend"),
                parentID: optionalString("parentID"),
                templateID: optionalString("templateID")))
        }
        return result
    }

    // MARK: Result helpers

    private static func success(_ value: DesignJSONValue,
                                detail: [String: String]? = nil)
        -> RuntimeCommandResult {
        RuntimeCommandResult(kind: .accepted, detail: detail, value: value)
    }

    private static func failure(_ code: G073ScheduleErrorCode,
                                _ reason: String) -> RuntimeCommandResult {
        RuntimeCommandResult(
            kind: .failed,
            code: .ordinaryRuntimeBlocked,
            detail: ["wire": code.rawValue],
            value: .object([
                "errorCode": .string(code.rawValue),
                "reason": .string(G073WireText.truncated(reason, 240)),
            ]))
    }
}

// MARK: - task.schedule agent tool

/// Trusted bindings frozen onto a schedule created from a running task. The
/// App resolves the ACTUAL run context; the model cannot choose them.
public struct G073TaskScheduleToolBinding: Sendable {
    /// A `.project` workspace, or nil for a NEW independent workspace per
    /// occurrence. A private task workspace is deliberately never frozen.
    public var workspaceID: UUID?
    public var modelID: UUID
    public var environmentID: String?
    public var policy: DraftTaskPolicy

    public init(workspaceID: UUID?, modelID: UUID,
                environmentID: String?, policy: DraftTaskPolicy) {
        self.workspaceID = workspaceID
        self.modelID = modelID
        self.environmentID = environmentID
        self.policy = policy
    }
}

public typealias G073TaskScheduleBindingResolver =
    @Sendable (ToolContext) async -> G073TaskScheduleToolBinding?

public struct G073TaskScheduleTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var action: String
        public var id: String?
        public var title: String?
        public var prompt: String?
        public var cadence: String?
        public var scheduledAt: String?
        public var intervalHours: Int?
        public var intervalSeconds: Int?
        public var upstreamRunID: String?
        public var enable: Bool?
        public var limit: Int?

        public init(action: String, id: String? = nil, title: String? = nil,
                    prompt: String? = nil, cadence: String? = nil,
                    scheduledAt: String? = nil, intervalHours: Int? = nil,
                    intervalSeconds: Int? = nil, upstreamRunID: String? = nil,
                    enable: Bool? = nil, limit: Int? = nil) {
            self.action = action
            self.id = id
            self.title = title
            self.prompt = prompt
            self.cadence = cadence
            self.scheduledAt = scheduledAt
            self.intervalHours = intervalHours
            self.intervalSeconds = intervalSeconds
            self.upstreamRunID = upstreamRunID
            self.enable = enable
            self.limit = limit
        }
    }

    public static let name = "task.schedule"
    public static let toolDescription = """
    Manage this app's scheduled Agent tasks (the same durable schedules the \
    user sees in Scheduled Tasks). Actions: list, create, update, enable, \
    disable, delete, runNow, history. Cadences: once, daily, weekly, interval \
    (fixed absolute duration; pass intervalHours or intervalSeconds), \
    afterSuccess (fires exactly once after the selected upstream run \
    completes SUCCESSFULLY; never on failure, cancellation or a delegated \
    child). Daily/weekly times stay anchored to the stored timezone. Missed \
    occurrences coalesce to the most recent one. Every occurrence starts a new \
    independent task with an explicit model, policy and environment; neither \
    the schedule nor this tool grants permissions, and a missing or disabled \
    model/environment is refused rather than substituted. Android exact-time \
    alarms can require a user-granted system permission; when it is missing the \
    schedule shows a waiting state instead of silently becoming best-effort.
    """
    public static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["list","create","update","enable","disable","delete","runNow","history"]},"id":{"type":"string","description":"Schedule UUID (required for update/enable/disable/delete/runNow/history)"},"title":{"type":"string","maxLength":160},"prompt":{"type":"string","maxLength":16384,"description":"The task instruction that will run (required on create)"},"cadence":{"type":"string","enum":["once","daily","weekly","interval","afterSuccess"]},"scheduledAt":{"type":"string","description":"ISO-8601 start/anchor time"},"intervalHours":{"type":"integer","minimum":1,"maximum":8760},"intervalSeconds":{"type":"integer","minimum":60},"upstreamRunID":{"type":"string","description":"For afterSuccess: the concrete upstream run UUID whose SUCCESSFUL completion triggers this schedule exactly once"},"enable":{"type":"boolean"},"limit":{"type":"integer","minimum":1,"maximum":50}},"required":["action"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.persistsPersonalData, .changesAgentBehavior]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let service: G073TaskScheduleService
    private let bindingResolver: G073TaskScheduleBindingResolver?

    public init(service: G073TaskScheduleService,
                bindingResolver: G073TaskScheduleBindingResolver? = nil) {
        self.service = service
        self.bindingResolver = bindingResolver
    }

    public func validate(_ args: Arguments) throws {
        let actions: Set<String> = ["list", "create", "update", "enable",
                                    "disable", "delete", "runNow", "history"]
        guard actions.contains(args.action) else {
            throw FloeError.validationFailed("Unsupported task.schedule action '\(args.action)'")
        }
        if ["update", "enable", "disable", "delete", "runNow", "history"]
            .contains(args.action) {
            guard let raw = args.id, UUID(uuidString: raw) != nil else {
                throw FloeError.validationFailed("A valid schedule id is required for \(args.action)")
            }
        }
        if args.action == "create" {
            let prompt = args.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !prompt.isEmpty else {
                throw FloeError.validationFailed("prompt is required for create")
            }
        }
        if let cadence = args.cadence, TaskScheduleCadence(rawValue: cadence) == nil {
            throw FloeError.validationFailed("Unknown cadence '\(cadence)'")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws
        -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        switch args.action {
        case "list":
            let schedules = await service.list(limit: 50)
            return output("status=ok count=\(schedules.count)\n"
                + schedules.map(describe).joined(separator: "\n"))
        case "history":
            guard let id = UUID(uuidString: args.id ?? "") else {
                throw FloeError.validationFailed("A valid schedule id is required")
            }
            let items = await service.history(
                id: id, limit: max(1, min(args.limit ?? 20, 50)))
            return output("status=ok count=\(items.count)\n"
                + items.map { occurrence in
                    "id=\(occurrence.id.uuidString) state=\(occurrence.state.rawValue)"
                        + " scheduledFor=\(G073WireDate.iso(occurrence.scheduledFor))"
                        + (occurrence.runID.map { " run=\($0.uuidString)" } ?? "")
                        + (occurrence.summary.map { " summary=\(G073WireText.truncated($0, 160))" } ?? "")
                        + (occurrence.errorText.map { " error=\(G073WireText.truncated($0, 160))" } ?? "")
                }.joined(separator: "\n"))
        case "delete":
            guard let detail = await detail(args) else {
                throw FloeError.validationFailed("No schedule with that id")
            }
            let result = await service.delete(id: detail.summary.id,
                                              expectedRevision: detail.summary.revision)
            guard result.accepted else {
                throw FloeError.validationFailed(result.reason ?? "The schedule could not be deleted")
            }
            return output("status=ok action=delete id=\(detail.summary.id.uuidString) note=run history is retained")
        case "enable", "disable":
            guard let detail = await detail(args) else {
                throw FloeError.validationFailed("No schedule with that id")
            }
            let enable = args.action == "enable" ? true : (args.enable ?? false)
            let result = await service.setEnabled(id: detail.summary.id,
                                                  enabled: enable,
                                                  expectedRevision: detail.summary.revision)
            guard result.accepted, let updated = result.detail else {
                throw FloeError.validationFailed(result.reason ?? "The schedule could not be updated")
            }
            return output("status=ok action=\(args.action) id=\(updated.summary.id.uuidString)"
                + " enabled=\(updated.summary.isEnabled)"
                + " next=\(updated.summary.nextFireAt.map(G073WireDate.iso) ?? "none")")
        case "runNow":
            guard let detail = await detail(args) else {
                throw FloeError.validationFailed("No schedule with that id")
            }
            let outcome = await service.runNow(id: detail.summary.id,
                                               expectedRevision: detail.summary.revision)
            // A queued occurrence is the honest result of an explicit run
            // request: the App-owned foreground dispatcher performs the only
            // launch. Reporting "launched" here would be a lie, and waiting
            // for a launch would race the worker.
            guard outcome.state == .queued || outcome.state == .launched else {
                throw FloeError.validationFailed(
                    outcome.reason ?? "The scheduled task could not be started")
            }
            return output("status=ok action=runNow state=\(outcome.state.rawValue)"
                + " id=\(detail.summary.id.uuidString)"
                + " occurrence=\(outcome.occurrenceID?.uuidString ?? "none")"
                + " run=\(outcome.runID?.uuidString ?? "none")"
                + " note=the task starts when the background dispatcher admits it")
        case "create", "update":
            return try await createOrUpdate(args, context: context)
        default:
            throw FloeError.validationFailed("Unsupported task.schedule action '\(args.action)'")
        }
    }

    private func detail(_ args: Arguments) async -> G073ScheduleDetail? {
        guard let id = UUID(uuidString: args.id ?? "") else { return nil }
        return await service.detail(id: id)
    }

    private func createOrUpdate(_ args: Arguments, context: ToolContext) async throws
        -> ToolExecutionOutput {
        if args.action == "update" {
            guard let current = await detail(args) else {
                throw FloeError.validationFailed("No schedule with that id")
            }
            var draft = G073ScheduleDraft(
                title: current.summary.title,
                prompt: current.prompt,
                cadence: current.summary.cadence,
                scheduledAt: current.summary.scheduledAt,
                weekday: current.summary.weekday,
                intervalSeconds: current.summary.intervalSeconds,
                anchorTimezone: current.summary.anchorTimezone,
                upstreamRunID: current.summary.upstreamRunID,
                workspaceID: current.summary.workspaceID,
                modelID: current.summary.modelID,
                environmentID: current.summary.environmentID,
                policy: current.summary.policy)
            applyOverrides(args, to: &draft)
            let result = await service.update(id: current.summary.id, draft: draft,
                                              expectedRevision: current.summary.revision)
            guard result.accepted, let detail = result.detail else {
                throw FloeError.validationFailed(result.reason ?? "The schedule could not be updated")
            }
            return output(describeMutation("update", detail))
        }
        let prompt = args.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else {
            throw FloeError.validationFailed("prompt is required for create")
        }
        guard let resolver = bindingResolver,
              let binding = await resolver(context) else {
            throw FloeError.validationFailed(
                "Scheduled tasks require the app's trusted binding resolver; no schedule was created.")
        }
        let cadence = args.cadence.flatMap(TaskScheduleCadence.init(rawValue:)) ?? .once
        let anchor = try parseDate(args.scheduledAt) ?? Date().addingTimeInterval(300)
        var draft = G073ScheduleDraft(
            title: args.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            prompt: prompt,
            cadence: cadence,
            scheduledAt: anchor,
            weekday: cadence == .weekly
                ? Calendar.current.component(.weekday, from: anchor) : nil,
            intervalSeconds: args.intervalSeconds ?? args.intervalHours.map { $0 * 3_600 },
            anchorTimezone: TimeZone.current.identifier,
            upstreamRunID: args.upstreamRunID.flatMap(UUID.init(uuidString:)),
            workspaceID: binding.workspaceID,
            modelID: binding.modelID,
            environmentID: binding.environmentID,
            policy: binding.policy)
        applyOverrides(args, to: &draft)
        let result = await service.create(draft)
        guard result.accepted, let detail = result.detail else {
            throw FloeError.validationFailed(result.reason ?? "The schedule could not be created")
        }
        return output(describeMutation("create", detail))
    }

    private func applyOverrides(_ args: Arguments, to draft: inout G073ScheduleDraft) {
        if let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            draft.title = title
        }
        if let prompt = args.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            draft.prompt = prompt
        }
        if let cadence = args.cadence.flatMap(TaskScheduleCadence.init(rawValue:)) {
            draft.cadence = cadence
        }
        if let parsed = try? parseDate(args.scheduledAt), let anchor = parsed {
            draft.scheduledAt = anchor
            if draft.cadence == .weekly {
                draft.weekday = Calendar.current.component(.weekday, from: anchor)
            }
        }
        if let seconds = args.intervalSeconds {
            draft.intervalSeconds = seconds
        } else if let hours = args.intervalHours {
            draft.intervalSeconds = hours * 3_600
        }
        if let upstream = args.upstreamRunID.flatMap(UUID.init(uuidString:)) {
            draft.upstreamRunID = upstream
        }
        if draft.cadence != .afterSuccess {
            draft.upstreamRunID = nil
        }
    }

    private func parseDate(_ raw: String?) throws -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return date }
        throw FloeError.validationFailed("scheduledAt must be an ISO-8601 timestamp")
    }

    private func describeMutation(_ action: String, _ detail: G073ScheduleDetail) -> String {
        let summary = detail.summary
        return "status=ok action=\(action) id=\(summary.id.uuidString)"
            + " cadence=\(summary.cadence.rawValue) enabled=\(summary.isEnabled)"
            + " next=\(summary.nextFireAt.map(G073WireDate.iso) ?? "none")"
            + " boundModel=\(summary.modelID?.uuidString ?? "default")"
            + " boundEnvironment=\(summary.environmentID ?? "workspace resolution")"
            + " workspace=\(summary.workspaceID?.uuidString ?? "new independent workspace per occurrence")"
            + " upstreamRun=\(summary.upstreamRunID?.uuidString ?? "none")"
    }

    private func describe(_ summary: G073ScheduleSummary) -> String {
        "id=\(summary.id.uuidString) enabled=\(summary.isEnabled)"
            + " cadence=\(summary.cadence.rawValue)"
            + " next=\(summary.nextFireAt.map(G073WireDate.iso) ?? "none")"
            + " last=\(summary.lastStartedAt.map(G073WireDate.iso) ?? "never")"
            + " upstreamRun=\(summary.upstreamRunID?.uuidString ?? "none")"
            + " model=\(summary.modelID?.uuidString ?? "default")"
            + " title=\(G073WireText.truncated(summary.title, 120))"
    }

    private func output(_ summary: String) -> ToolExecutionOutput {
        ToolExecutionOutput(
            summary: summary,
            fullOutputSHA256: FloeDigest.sha256Hex(Data(summary.utf8)))
    }
}

extension G073WireDate {
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Registers the `task.schedule` tool against the same epoch service. The
/// resolver freezes the ACTUAL run's trusted workspace/model/policy/
/// environment; a build without it refuses create instead of freezing empty
/// bindings. Registration is performed by the composition only after the
/// scheduling service is installed.
@discardableResult
public func registerG073TaskScheduleTools(
    service: G073TaskScheduleService,
    registry: ToolRunnerRegistry = .shared,
    bindingResolver: G073TaskScheduleBindingResolver? = nil
) -> G073TaskScheduleTool {
    ToolCatalog.register(G073TaskScheduleTool.self)
    let tool = G073TaskScheduleTool(service: service,
                                   bindingResolver: bindingResolver)
    registry.register(tool)
    return tool
}
