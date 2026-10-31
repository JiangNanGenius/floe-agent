// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Bridge protocol v3 — explicit integer wire version with typed scopes,
/// asynchronous operation effects and an honest pre-run lifecycle.
///
/// Authority (Main decisions, 2026-10-19):
/// * Version 1 dispatch stays frozen; existing v2 (`BridgeEnvelope.swift`)
///   stays byte-identical. This file is a separate version-3 branch only.
/// * No version minor alias: a version-2 client still gets exactly the v2
///   validator (four non-nil execution roles) and a v3 envelope can never be
///   silently reinterpreted as v2 or the reverse.
/// * Every v3 envelope declares `schema` explicitly. `command.submit` requires
///   `floe.command-envelope/3`, `event.poll` requires `floe.event-cursor/3`
///   and `effect.poll` requires `floe.effect-cursor/3`. A schema/operation
///   mismatch is a typed rejection; the three channels never share a schema.
/// * Scopes carry genuine semantic roles and a closed command matrix:
///   - `applicationConfiguration` has a closed host-owned vocabulary and no
///     execution owner; changing a label cannot carry run/config authority.
///   - `conversationLifecycle` needs a real taskID (conversation or ephemeral
///     session) and structurally rejects run/environment/job roles.
///   - `launch` is either an existing-conversation start (`run.start`, taskID
///     required) or an explicit new-identity create intent (taskID absent).
///   - `taskExecution` requires taskID+runID and allows optional, syntactically
///     valid environment/job roles. Shape never proves those identities exist.
/// * Queue acceptance is not domain commit. This file validates and routes
///   bytes only; it never mints a run/conversation ID, never invents an
///   operation receipt and never synthesises a task result.
/// * `effect.poll` is an async operation-lifecycle channel
///   (`floe.effect-cursor/3`) under the configuration scope with an opaque
///   host `operationReceiptID` and a nonnegative sequence. It has no
///   run/environment/job roles: an operation outcome is not a run event.
/// * With no host handler registered the only outcome is `runtimeUnavailable`
///   with an exact unbound reason. Tests register controlled synthetic
///   handlers under v3-scoped keys and always unregister them.
public enum BridgeV3 {
    /// The all-zero UUID; explicitly declared because `UUID.uuidNil` is not
    /// available across every Foundation overlay used by the Android build.
    static let nilUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    public static let version = 3
    public static let commandSchema = "floe.command-envelope/3"
    public static let runEventSchema = "floe.event-cursor/3"
    public static let effectSchema = "floe.effect-cursor/3"

    /// Same strict request bound as v1/v2. Attachments/binary data never enter
    /// this JSON channel; they use separate bounded streams.
    public static let maximumBytes = 65_536

    // MARK: - Closed scope vocabulary

    public enum Scope: String, Sendable, CaseIterable {
        case applicationConfiguration
        case conversationLifecycle
        case launch
        case taskExecution
    }

    /// Closed host-owned configuration labels. `operations` is reserved for
    /// operation-lifecycle scoping (for example `effect.poll`); it does not
    /// grant any execution authority. `attachmentStaging` is the host-owned
    /// pre-conversation staging vocabulary (never a fake run).
    public static let configurationScopes: [String] = [
        "providers", "models", "preferences", "catalog", "credentials",
        "skills", "mcp", "settings.approval", "settings.websearch",
        "conversations", "capabilities", "system", "operations",
        "attachmentStaging",
        // Settings-domain P0 additive labels (accepted rev3 contract,
        // 2026-10-19). Declaring a label never activates a command by itself;
        // the closed matrix below remains the only authority.
        "settings.defaults", "memory", "personalization", "usage", "privacy",
        // G07.3B: host-owned schedule configuration; not execution authority.
        "schedule",
    ]

    public enum Operation: String, Sendable {
        case submit = "command.submit"
        case runEventPoll = "event.poll"
        case effectPoll = "effect.poll"
    }

    /// A single entry of the closed operation → scope matrix.
    ///
    /// `revisionRequired` is the stateful/revision contract for an existing
    /// resource. `allowsCreateIntent` marks the only commands that may create
    /// a new host-owned identity without a fabricated revision.
    public struct CommandRule: Sendable, Equatable {
        public let command: String
        public let scope: Scope
        public let configurationScope: String?
        public let revisionRequired: Bool
        public let allowsCreateIntent: Bool
        public let isRunEventPoll: Bool

        public init(command: String, scope: Scope, configurationScope: String? = nil,
                    revisionRequired: Bool, allowsCreateIntent: Bool = false,
                    isRunEventPoll: Bool = false) {
            self.command = command
            self.scope = scope
            self.configurationScope = configurationScope
            self.revisionRequired = revisionRequired
            self.allowsCreateIntent = allowsCreateIntent
            self.isRunEventPoll = isRunEventPoll
        }
    }

    /// The closed matrix. A command absent from this table is unknown; a
    /// command presented under a different scope or configuration label is a
    /// typed rejection. Labels never widen authority.
    public static let commandRules: [CommandRule] = [
        // applicationConfiguration — host-owned configuration vocabulary.
        CommandRule(command: "config.providers.list", scope: .applicationConfiguration,
                    configurationScope: "providers", revisionRequired: false),
        CommandRule(command: "config.provider.save", scope: .applicationConfiguration,
                    configurationScope: "providers", revisionRequired: true,
                    allowsCreateIntent: true),
        CommandRule(command: "config.provider.delete", scope: .applicationConfiguration,
                    configurationScope: "providers", revisionRequired: true),
        CommandRule(command: "config.provider.probe", scope: .applicationConfiguration,
                    configurationScope: "providers", revisionRequired: false),
        CommandRule(command: "config.models.list", scope: .applicationConfiguration,
                    configurationScope: "models", revisionRequired: false),
        CommandRule(command: "config.model.save", scope: .applicationConfiguration,
                    configurationScope: "models", revisionRequired: true),
        CommandRule(command: "config.catalog.search", scope: .applicationConfiguration,
                    configurationScope: "catalog", revisionRequired: false),
        CommandRule(command: "config.preferences.get", scope: .applicationConfiguration,
                    configurationScope: "preferences", revisionRequired: false),
        CommandRule(command: "config.preferences.save", scope: .applicationConfiguration,
                    configurationScope: "preferences", revisionRequired: true),
        CommandRule(command: "config.websearch.get", scope: .applicationConfiguration,
                    configurationScope: "settings.websearch", revisionRequired: false),
        CommandRule(command: "config.websearch.save", scope: .applicationConfiguration,
                    configurationScope: "settings.websearch", revisionRequired: true),
        CommandRule(command: "conversation.list", scope: .applicationConfiguration,
                    configurationScope: "conversations", revisionRequired: false),
        CommandRule(command: "conversation.search", scope: .applicationConfiguration,
                    configurationScope: "conversations", revisionRequired: false),
        CommandRule(command: "capability.tools.list", scope: .applicationConfiguration,
                    configurationScope: "capabilities", revisionRequired: false),
        CommandRule(command: "skills.list", scope: .applicationConfiguration,
                    configurationScope: "skills", revisionRequired: false),
        CommandRule(command: "skills.install", scope: .applicationConfiguration,
                    configurationScope: "skills", revisionRequired: true,
                    allowsCreateIntent: true),
        CommandRule(command: "skills.uninstall", scope: .applicationConfiguration,
                    configurationScope: "skills", revisionRequired: true),
        CommandRule(command: "mcp.servers.list", scope: .applicationConfiguration,
                    configurationScope: "mcp", revisionRequired: false),
        CommandRule(command: "mcp.connect", scope: .applicationConfiguration,
                    configurationScope: "mcp", revisionRequired: true,
                    allowsCreateIntent: true),
        CommandRule(command: "mcp.disconnect", scope: .applicationConfiguration,
                    configurationScope: "mcp", revisionRequired: true),
        CommandRule(command: "system.bootstrap", scope: .applicationConfiguration,
                    configurationScope: "system", revisionRequired: false),
        CommandRule(command: "system.shutdown", scope: .applicationConfiguration,
                    configurationScope: "system", revisionRequired: false),
        CommandRule(command: "system.lifecycle", scope: .applicationConfiguration,
                    configurationScope: "system", revisionRequired: false),
        // Host-owned pre-conversation staging. The receipt/handle is the
        // identity; no revision or run is fabricated for it.
        CommandRule(command: "attachment.stage", scope: .applicationConfiguration,
                    configurationScope: "attachmentStaging", revisionRequired: false),
        CommandRule(command: "attachment.staging.read", scope: .applicationConfiguration,
                    configurationScope: "attachmentStaging", revisionRequired: false),
        CommandRule(command: "attachment.staging.cancel", scope: .applicationConfiguration,
                    configurationScope: "attachmentStaging", revisionRequired: false),
        CommandRule(command: "attachment.staging.discard", scope: .applicationConfiguration,
                    configurationScope: "attachmentStaging", revisionRequired: false),

        // conversationLifecycle — real task identity, no run/env/job roles.
        CommandRule(command: "conversation.get", scope: .conversationLifecycle,
                    revisionRequired: false),
        CommandRule(command: "conversation.rename", scope: .conversationLifecycle,
                    revisionRequired: true),
        CommandRule(command: "conversation.archive", scope: .conversationLifecycle,
                    revisionRequired: true),
        CommandRule(command: "conversation.delete", scope: .conversationLifecycle,
                    revisionRequired: true),
        CommandRule(command: "conversation.messagePage", scope: .conversationLifecycle,
                    revisionRequired: false),
        CommandRule(command: "conversation.messageSearch", scope: .conversationLifecycle,
                    revisionRequired: false),
        CommandRule(command: "conversation.messageWindow", scope: .conversationLifecycle,
                    revisionRequired: false),
        CommandRule(command: "question.pending", scope: .conversationLifecycle,
                    revisionRequired: false),
        CommandRule(command: "question.answer", scope: .conversationLifecycle,
                    revisionRequired: false),
        CommandRule(command: "question.cancel", scope: .conversationLifecycle,
                    revisionRequired: false),
        CommandRule(command: "temp.end", scope: .conversationLifecycle,
                    revisionRequired: true),
        CommandRule(command: "temp.keep", scope: .conversationLifecycle,
                    revisionRequired: true),
        CommandRule(command: "attachment.commit", scope: .conversationLifecycle,
                    revisionRequired: true),
        CommandRule(command: "attachment.read", scope: .conversationLifecycle,
                    revisionRequired: false),
        CommandRule(command: "attachment.cancel", scope: .conversationLifecycle,
                    revisionRequired: true),
        CommandRule(command: "content.read", scope: .conversationLifecycle,
                    revisionRequired: false),
        // `content.read` is the one dual-scope read in the contract: a
        // conversation-scoped read or a configuration/conversations read.
        CommandRule(command: "content.read", scope: .applicationConfiguration,
                    configurationScope: "conversations", revisionRequired: false),

        // launch — existing conversation vs explicit new identity.
        CommandRule(command: "run.start", scope: .launch, revisionRequired: true),
        CommandRule(command: "run.startTask", scope: .launch, revisionRequired: true,
                    allowsCreateIntent: true),
        CommandRule(command: "conversation.create", scope: .launch,
                    revisionRequired: true, allowsCreateIntent: true),
        CommandRule(command: "temp.start", scope: .launch, revisionRequired: true,
                    allowsCreateIntent: true),

        // taskExecution — real run scope; env/job optional but typed.
        CommandRule(command: "run.cancel", scope: .taskExecution, revisionRequired: true),
        CommandRule(command: "run.retry", scope: .taskExecution, revisionRequired: true),
        CommandRule(command: "run.steer", scope: .taskExecution, revisionRequired: true),
        CommandRule(command: "run.queue", scope: .taskExecution, revisionRequired: true),
        CommandRule(command: "run.input.edit", scope: .taskExecution, revisionRequired: true),
        CommandRule(command: "run.input.remove", scope: .taskExecution, revisionRequired: true),
        CommandRule(command: "run.input.reorder", scope: .taskExecution, revisionRequired: true),
        CommandRule(command: "run.approval.resolve", scope: .taskExecution,
                    revisionRequired: true),
        CommandRule(command: "run.policy.update", scope: .taskExecution,
                    revisionRequired: true),
        CommandRule(command: "run.skillcancel", scope: .taskExecution,
                    revisionRequired: true),
        CommandRule(command: "run.snapshot", scope: .taskExecution, revisionRequired: false),
        CommandRule(command: "child.list", scope: .taskExecution, revisionRequired: false),
        CommandRule(command: "child.entries", scope: .taskExecution, revisionRequired: false),
        CommandRule(command: "event.poll", scope: .taskExecution, revisionRequired: false,
                    isRunEventPoll: true),

        // Settings-domain P0 additive matrix (accepted rev3 contract,
        // 2026-10-19). APPEND-ONLY: the 57 entries above are byte-identical;
        // the labels above are the only new host-owned vocabulary. These
        // commands have no registered handler in this package: every
        // structurally and payload-valid envelope still terminates at the
        // existing typed `runtimeUnavailable` seam.
        //
        // settings.defaults — typed global defaults.
        CommandRule(command: "config.defaults.get", scope: .applicationConfiguration,
                    configurationScope: "settings.defaults", revisionRequired: false),
        CommandRule(command: "config.defaults.save", scope: .applicationConfiguration,
                    configurationScope: "settings.defaults", revisionRequired: true),
        // memory — original SQLiteIntelligenceStore/personalization services.
        CommandRule(command: "memory.list", scope: .applicationConfiguration,
                    configurationScope: "memory", revisionRequired: false),
        CommandRule(command: "memory.get", scope: .applicationConfiguration,
                    configurationScope: "memory", revisionRequired: false),
        CommandRule(command: "memory.add", scope: .applicationConfiguration,
                    configurationScope: "memory", revisionRequired: true,
                    allowsCreateIntent: true),
        CommandRule(command: "memory.update", scope: .applicationConfiguration,
                    configurationScope: "memory", revisionRequired: true),
        CommandRule(command: "memory.delete", scope: .applicationConfiguration,
                    configurationScope: "memory", revisionRequired: true),
        CommandRule(command: "memory.delete.bulk", scope: .applicationConfiguration,
                    configurationScope: "memory", revisionRequired: true,
                    allowsCreateIntent: true),
        CommandRule(command: "memory.search", scope: .applicationConfiguration,
                    configurationScope: "memory", revisionRequired: false),
        CommandRule(command: "memory.candidates.list", scope: .applicationConfiguration,
                    configurationScope: "memory", revisionRequired: false),
        CommandRule(command: "memory.candidate.resolve", scope: .applicationConfiguration,
                    configurationScope: "memory", revisionRequired: true),
        CommandRule(command: "memory.organize.start", scope: .applicationConfiguration,
                    configurationScope: "memory", revisionRequired: true,
                    allowsCreateIntent: true),
        CommandRule(command: "memory.organize.proposal.read", scope: .applicationConfiguration,
                    configurationScope: "memory", revisionRequired: false),
        CommandRule(command: "memory.organize.apply", scope: .applicationConfiguration,
                    configurationScope: "memory", revisionRequired: true,
                    allowsCreateIntent: true),
        CommandRule(command: "memory.organize.cancel", scope: .applicationConfiguration,
                    configurationScope: "memory", revisionRequired: false),
        // personalization — original SQLitePersonalizationStore documents.
        CommandRule(command: "personalization.get", scope: .applicationConfiguration,
                    configurationScope: "personalization", revisionRequired: false),
        CommandRule(command: "personalization.revision.read", scope: .applicationConfiguration,
                    configurationScope: "personalization", revisionRequired: false),
        CommandRule(command: "personalization.save", scope: .applicationConfiguration,
                    configurationScope: "personalization", revisionRequired: true),
        CommandRule(command: "personalization.rollback", scope: .applicationConfiguration,
                    configurationScope: "personalization", revisionRequired: true),
        CommandRule(command: "personalization.automatic.set", scope: .applicationConfiguration,
                    configurationScope: "personalization", revisionRequired: true),
        CommandRule(command: "personalization.generate", scope: .applicationConfiguration,
                    configurationScope: "personalization", revisionRequired: true,
                    allowsCreateIntent: true),
        CommandRule(command: "personalization.generate.cancel", scope: .applicationConfiguration,
                    configurationScope: "personalization", revisionRequired: false),
        // Third entry for the existing content.read command. The label-aware
        // applicationConfiguration lookup keeps this separate from the
        // existing conversations entry; the shared handler key dispatches on
        // configurationScope and rejects every other label.
        CommandRule(command: "content.read", scope: .applicationConfiguration,
                    configurationScope: "personalization", revisionRequired: false),
        // usage — bounded projections of the original RunStore aggregates.
        CommandRule(command: "usage.statistics.get", scope: .applicationConfiguration,
                    configurationScope: "usage", revisionRequired: false),
        // privacy — exact identity/state snapshots and destructive clears.
        CommandRule(command: "privacy.summary.get", scope: .applicationConfiguration,
                    configurationScope: "privacy", revisionRequired: false),
        CommandRule(command: "privacy.history.clear", scope: .applicationConfiguration,
                    configurationScope: "privacy", revisionRequired: true),
        CommandRule(command: "privacy.modelConfiguration.clear", scope: .applicationConfiguration,
                    configurationScope: "privacy", revisionRequired: true),

        // goal-core code batch (2026-10-21, job-7efd60bb51d14f02): THREE
        // additive run-control tuples decided by MAIN_RUN_CONTROL_CLOSURE_
        // DECISION_20261020.json (ordinary-run-control-gap-review §1-§3).
        // APPEND-ONLY again: the 57 legacy tuples and the 27 accepted
        // settings-domain tuples above stay byte-identical; no existing
        // identity is renamed, deleted or relabeled; the mailbox bounds
        // (64 queued / 16 active / 64 KiB envelope) are unchanged; there is
        // NO child.create (the original has no human child-creation feature).
        // `plan.accept` rides the launch scope with the SAME existing-
        // conversation digest CAS as run.start (accept + start is ONE user
        // action; createIntent stays forbidden). `goal.confirm` proves a
        // conversation-scoped identity+revision and needs NO run role (the
        // original confirm works after the run is terminal).
        // `conversation.compact` mutates durable compaction history, not a
        // single row: no per-row revision; core-side quiescence + atomic
        // writer proof guard it (conversationLifecycle scope, taskID only).
        CommandRule(command: "plan.accept", scope: .launch, revisionRequired: true),
        CommandRule(command: "goal.confirm", scope: .conversationLifecycle,
                    revisionRequired: true),
        CommandRule(command: "conversation.compact", scope: .conversationLifecycle,
                    revisionRequired: false),

        // G04 workspace domain additive ledger (Main decisions D12/D14,
        // 2026-10-24). APPEND-ONLY: the 57 legacy tuples, the 27 accepted
        // settings tuples and the 3 goal-core tuples above stay
        // byte-identical; no existing identity is renamed, deleted or
        // relabeled; the mailbox bounds are unchanged. The three tuples ride
        // conversationLifecycle (REAL envelope taskID only, NO run/env/job
        // role) and are the ONLY ingress for the root-owned workspace facade.
        // Both document-command outer revisions stay NOT required because the
        // explicit native per-document token (opaque `revision` inside the
        // closed payload grammar) governs edits; `workspace.activate` carries
        // no revision because it establishes the exact durable ownership
        // binding. Payload unknown-field/absolute-root/permission rejection
        // and the per-operation whitelist are enforced by G04WorkspaceWire,
        // re-validated AGAIN by the real facade before any side effect. No
        // handler is registered in the ordinary base: only a successful
        // G04WorkspaceDomainExtension.attach binds these keys; the frozen
        // fail-closed `runtimeUnavailable` refusal otherwise is unchanged.
        CommandRule(command: "workspace.read", scope: .conversationLifecycle,
                    revisionRequired: false),
        CommandRule(command: "workspace.write", scope: .conversationLifecycle,
                    revisionRequired: false),
        CommandRule(command: "workspace.activate", scope: .conversationLifecycle,
                    revisionRequired: false),

        // G07.3B: additive scheduled-task configuration and wake reconciliation.
        CommandRule(command: "schedule.list", scope: .applicationConfiguration,
                    configurationScope: "schedule", revisionRequired: false),
        CommandRule(command: "schedule.get", scope: .applicationConfiguration,
                    configurationScope: "schedule", revisionRequired: false),
        CommandRule(command: "schedule.options", scope: .applicationConfiguration,
                    configurationScope: "schedule", revisionRequired: false),
        CommandRule(command: "schedule.create", scope: .applicationConfiguration,
                    configurationScope: "schedule", revisionRequired: true, allowsCreateIntent: true),
        CommandRule(command: "schedule.update", scope: .applicationConfiguration,
                    configurationScope: "schedule", revisionRequired: true),
        CommandRule(command: "schedule.enable", scope: .applicationConfiguration,
                    configurationScope: "schedule", revisionRequired: true),
        CommandRule(command: "schedule.disable", scope: .applicationConfiguration,
                    configurationScope: "schedule", revisionRequired: true),
        CommandRule(command: "schedule.delete", scope: .applicationConfiguration,
                    configurationScope: "schedule", revisionRequired: true),
        CommandRule(command: "schedule.runNow", scope: .applicationConfiguration,
                    configurationScope: "schedule", revisionRequired: true),
        CommandRule(command: "schedule.history", scope: .applicationConfiguration,
                    configurationScope: "schedule", revisionRequired: false),
        CommandRule(command: "schedule.dispatch", scope: .applicationConfiguration,
                    configurationScope: "schedule", revisionRequired: false),
        CommandRule(command: "schedule.rearm", scope: .applicationConfiguration,
                    configurationScope: "schedule", revisionRequired: false),
        CommandRule(command: "schedule.dispatchPending", scope: .applicationConfiguration,
                    configurationScope: "schedule", revisionRequired: false),
    ]

    public enum BinderChannel: String, Sendable {
        case command = "v3.command"
        case runEvent = "v3.runEvent"
        case effect = "v3.effect"
    }

    /// Handler registration key. v3 keys are namespaced by channel so a v2
    /// handler (`chat.send`) or a config handler can never serve another
    /// channel merely because a label changed.
    public static func handlerKey(scope: Scope, command: String) -> String {
        "v3.command.\(scope.rawValue).\(command)"
    }

    public static let runEventPumpHandlerKey = "v3.runEvent.event.poll"
    public static let effectPumpHandlerKey = "v3.effect.poll"

    // MARK: - Dispatch

    static func handle(request: [String: Any], requestID: String?) -> [String: Any] {
        switch request["operation"] as? String {
        case "handshake":
            return handshakeResponse()
        case "credential.status":
            // Unchanged fail-closed status: with no registered JNI gateway the
            // core reports NEEDS_CONFIGURATION and there is no memory fallback.
            let registered = SecretGatewayRegistry.shared.isRegistered
            return ["ok": true, "secretBackend": [
                "registered": registered,
                "availability": registered ? "AVAILABLE" : "NEEDS_CONFIGURATION",
                "memoryFallback": false,
            ]]
        case Operation.submit.rawValue:
            return route(request: request, requestID: requestID, operation: .submit)
        case Operation.runEventPoll.rawValue:
            return route(request: request, requestID: requestID, operation: .runEventPoll)
        case Operation.effectPoll.rawValue:
            return route(request: request, requestID: requestID, operation: .effectPoll)
        default:
            return ["ok": false, "error": "unsupportedOperation"]
        }
    }

    /// Explicit negotiation cannot advertise working business capabilities:
    /// only `handshake`/`credential.status` execute, every envelope operation
    /// is staged with `bound: false` until a real host binder is registered.
    public static func handshakeResponse() -> [String: Any] {
        [
            "ok": true,
            "core": "FloeAndroidCore",
            "supportedVersions": [1, 2, 3],
            "schemas": [
                "command": commandSchema,
                "runEvents": runEventSchema,
                "operationEffects": effectSchema,
            ],
            "operations": ["handshake", "credential.status"],
            "stagedOperations": [
                ["operation": Operation.submit.rawValue, "bound": false,
                 "schema": commandSchema],
                ["operation": Operation.runEventPoll.rawValue, "bound": false,
                 "schema": runEventSchema],
                ["operation": Operation.effectPoll.rawValue, "bound": false,
                 "schema": effectSchema],
            ],
            // Validation support is not a business capability. No provider,
            // model, task, run, conversation or credential operation is
            // claimed as usable by this source package.
            "businessCapabilities": [],
            "envelopeValidation": "structuralOnly",
            "localLLM": false,
        ]
    }

    private static func route(request: [String: Any], requestID: String?,
                              operation: Operation) -> [String: Any] {
        func failure(_ code: String, _ reason: String? = nil) -> [String: Any] {
            var value: [String: Any] = ["ok": false, "error": code]
            if let reason { value["reason"] = reason }
            return value
        }
        guard let envelopeObject = request["envelope"],
              JSONSerialization.isValidJSONObject(envelopeObject),
              let envelopeData = try? JSONSerialization.data(withJSONObject: envelopeObject),
              let envelope = (try? JSONSerialization.jsonObject(with: envelopeData)) as? [String: Any]
        else { return failure("invalidEnvelope", "missingEnvelopeObject") }

        let validation = validate(envelope: envelope, requestID: requestID,
                                  operation: operation)
        guard validation.isValid else {
            return failure(validation.errorCode, validation.reason)
        }

        let handlerKey: String
        let unboundReason: String
        switch operation {
        case .submit:
            let scope = (envelope["scope"] as? String) ?? ""
            let command = (envelope["command"] as? String) ?? ""
            handlerKey = self.handlerKey(scope: Scope(rawValue: scope) ?? .applicationConfiguration,
                                         command: command)
            unboundReason = "commandBinderUnbound"
        case .runEventPoll:
            handlerKey = runEventPumpHandlerKey
            unboundReason = "eventPumpUnbound"
        case .effectPoll:
            handlerKey = effectPumpHandlerKey
            unboundReason = "effectPumpUnbound"
        }

        guard let handler = RuntimeCommandBinder.shared.handler(for: handlerKey) else {
            // Fail-closed seam: a structurally valid envelope is not a
            // committed operation, receipt or run.
            return failure("runtimeUnavailable", unboundReason)
        }
        return execute(handler, envelopeData: envelopeData, failure: failure)
    }

    /// Handler bytes stay inside the same strict bound. An oversized or
    /// structurally invalid host result is a typed failure, never parsed
    /// opportunistically into a successful response.
    private static func execute(_ handler: RuntimeCommandBinder.Handler,
                                envelopeData: Data,
                                failure: (String, String?) -> [String: Any]) -> [String: Any] {
        let output = handler(envelopeData)
        guard output.count <= maximumBytes else {
            return failure("invalidBinderOutput", "binderOutputTooLarge")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any] else {
            return failure("invalidBinderOutput", "malformedBinderOutput")
        }
        return object
    }

    // MARK: - Validation

    public struct ValidationResult: Sendable, Equatable {
        public var isValid: Bool
        public var errorCode: String
        public var reason: String
        public init(isValid: Bool, errorCode: String, reason: String) {
            self.isValid = isValid
            self.errorCode = errorCode
            self.reason = reason
        }
    }

    /// Validation is structural: it proves shape, explicit roles, closed
    /// labels and revision/cursor rules. It never proves that any identity
    /// exists, that a grant is valid, or that a domain handler will succeed.
    public static func validate(envelope: [String: Any], requestID: String?,
                                operation: Operation) -> ValidationResult {
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope),
              let root = try? JSONDecoder().decode(StrictJSONValue.self, from: data),
              case .object(let object) = root else {
            return invalid("malformedEnvelope")
        }
        return validateTyped(object, requestID: requestID, operation: operation)
    }

    /// Explicit typed union so JSON `true` is never bridged to `1`, integers
    /// are not confused with fractions, and null is distinguishable from
    /// absence. Duplicated locally rather than touching the frozen v2 file.
    private enum StrictJSONValue: Decodable {
        case object([String: StrictJSONValue])
        case array([StrictJSONValue])
        case string(String)
        case integer(Int)
        case fractional(Double)
        case boolean(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .boolean(value)
            } else if let value = try? container.decode(Int.self) {
                self = .integer(value)
            } else if let value = try? container.decode(Double.self) {
                self = .fractional(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([StrictJSONValue].self) {
                self = .array(value)
            } else if let value = try? container.decode([String: StrictJSONValue].self) {
                self = .object(value)
            } else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unsupported JSON value"))
            }
        }
    }

    private static let allowedEnvelopeKeys: Set<String> = [
        "schema", "scope", "command", "stateful", "revision", "cursor", "grantID",
        "correlationID", "payload", "configurationScope", "owner", "effect",
        "createIntent",
    ]

    private static func invalid(_ reason: String) -> ValidationResult {
        ValidationResult(isValid: false, errorCode: "invalidEnvelope", reason: reason)
    }

    private static func stringValue(_ value: StrictJSONValue?) -> String? {
        guard let value, case .string(let string) = value else { return nil }
        return string
    }

    private static func objectValue(_ value: StrictJSONValue?) -> [String: StrictJSONValue]? {
        guard let value, case .object(let object) = value else { return nil }
        return object
    }

    private static func integerValue(_ value: StrictJSONValue?) -> Int? {
        guard let value, case .integer(let integer) = value else { return nil }
        return integer
    }

    private static func booleanValue(_ value: StrictJSONValue?) -> Bool? {
        guard let value, case .boolean(let boolean) = value else { return nil }
        return boolean
    }

    private static func isNonBlank(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Converts the frozen v3 strict value union into the settings-domain
    /// vocabulary. The conversion preserves every JSON type distinction (Bool
    /// vs integer vs fractional, null vs absence) and never stringifies.
    private static func settingsJSONValue(_ value: StrictJSONValue)
        -> SettingsDomainV1.JSONValue? {
        switch value {
        case .object(let object):
            var converted: [String: SettingsDomainV1.JSONValue] = [:]
            converted.reserveCapacity(object.count)
            for (key, item) in object {
                guard let item = settingsJSONValue(item) else { return nil }
                converted[key] = item
            }
            return .object(converted)
        case .array(let array):
            var converted: [SettingsDomainV1.JSONValue] = []
            converted.reserveCapacity(array.count)
            for item in array {
                guard let item = settingsJSONValue(item) else { return nil }
                converted.append(item)
            }
            return .array(converted)
        case .string(let string):
            return .string(string)
        case .integer(let integer):
            return .integer(Int64(integer))
        case .fractional(let double):
            return .fractional(double)
        case .boolean(let boolean):
            return .boolean(boolean)
        case .null:
            return .null
        }
    }

    private struct EnvelopeIdentity {
        var taskID: String?
        var runID: String?
        var environmentID: String?
        var jobID: String?
    }

    private static func validateTyped(_ envelope: [String: StrictJSONValue],
                                      requestID: String?,
                                      operation: Operation) -> ValidationResult {
        // Closed envelope shape: unknown fields are never forward-parsed.
        for key in envelope.keys where !allowedEnvelopeKeys.contains(key) {
            return invalid("unknownEnvelopeField")
        }
        guard let schema = stringValue(envelope["schema"]) else {
            return invalid("missingSchema")
        }
        let expectedSchema: String
        switch operation {
        case .submit: expectedSchema = commandSchema
        case .runEventPoll: expectedSchema = runEventSchema
        case .effectPoll: expectedSchema = effectSchema
        }
        if schema != expectedSchema {
            // All three known channel schemas are recognised, but using one
            // on another channel is a role mismatch, never a silent reinterpretation.
            if schema == commandSchema || schema == runEventSchema || schema == effectSchema {
                return invalid("schemaRoleMismatch")
            }
            return invalid("schemaMismatch")
        }

        guard let scopeRaw = stringValue(envelope["scope"]) else {
            return invalid("missingScope")
        }
        guard let scope = Scope(rawValue: scopeRaw) else {
            return invalid("unknownScope")
        }
        if operation == .effectPoll, scope != .applicationConfiguration {
            return invalid("effectPollRequiresConfigurationScope")
        }
        if operation == .runEventPoll, scope != .taskExecution {
            return invalid("eventPollRequiresTaskScope")
        }

        // Configuration label: required exactly in the configuration scope,
        // structurally rejected everywhere else. Validate before matching the
        // matrix so a missing label is not misreported as a scope mismatch.
        var configurationScope: String?
        if let labelValue = envelope["configurationScope"] {
            guard let label = stringValue(labelValue), isNonBlank(label), label.count <= 64 else {
                return invalid("invalidConfigurationScope")
            }
            guard configurationScopes.contains(label) else {
                return invalid("invalidConfigurationScope")
            }
            guard scope == .applicationConfiguration else {
                return invalid("configurationScopeInWrongScope")
            }
            configurationScope = label
        } else if scope == .applicationConfiguration {
            return invalid("missingConfigurationScope")
        }

        guard let command = stringValue(envelope["command"]),
              isNonBlank(command), command.count <= 128, !command.contains(" ") else {
            return invalid("invalidCommand")
        }
        var matrixRule: CommandRule?
        if operation == .effectPoll {
            guard command == Operation.effectPoll.rawValue else {
                return invalid("effectPollRequiresEffectCommand")
            }
        } else {
            let candidates = commandRules.filter { $0.command == command && $0.scope == scope }
            if let matched = candidates.first(where: { candidate in
                candidate.configurationScope == configurationScope
            }) {
                matrixRule = matched
            } else if !candidates.isEmpty {
                // The command is valid in this scope under another host label.
                return invalid("configurationScopeMismatch")
            } else if commandRules.contains(where: { $0.command == command }) {
                // Known command, relabelled scope: never reinterpret authority.
                return invalid("commandScopeMismatch")
            } else {
                return invalid("unknownCommand")
            }
        }
        if operation == .runEventPoll, matrixRule?.isRunEventPoll != true {
            return invalid("eventPollRequiresEventCommand")
        }
        if operation == .submit, matrixRule?.isRunEventPoll == true {
            return invalid("eventPollRequiresPollOperation")
        }

        guard let statefulRaw = envelope["stateful"] else {
            return invalid("missingStatefulFlag")
        }
        guard let stateful = booleanValue(statefulRaw) else {
            return invalid("invalidStatefulFlag")
        }

        // Explicit create intent is the only way to omit a revision for a new
        // resource. It is never implied by absent identities.
        var createIntent = false
        if let createValue = envelope["createIntent"] {
            guard let typedCreate = booleanValue(createValue) else {
                return invalid("invalidCreateIntent")
            }
            createIntent = typedCreate
        }

        let rule: CommandRule?
        if let matrixRule {
            rule = matrixRule
        } else if operation == .effectPoll {
            rule = CommandRule(command: command, scope: scope, revisionRequired: false)
        } else {
            rule = nil
        }
        let revisionRequired = rule?.revisionRequired ?? false
        let allowsCreateIntent = rule?.allowsCreateIntent ?? false

        if operation == .effectPoll || operation == .runEventPoll {
            if stateful { return invalid("invalidStatefulFlag") }
        } else {
            // A create intent is a stateful mutation of a brand-new resource;
            // an existing-resource command is stateful exactly when its
            // revision is required. Anything else would skip revision rules.
            let expectedStateful = createIntent ? true : revisionRequired
            if stateful != expectedStateful {
                return invalid("statefulMismatch")
            }
        }

        if createIntent {
            guard operation == .submit, allowsCreateIntent else {
                return invalid("createIntentNotAllowed")
            }
            guard stateful else { return invalid("createIntentRequiresStateful") }
        }

        // Identity roles, per scope.
        var identity = EnvelopeIdentity()
        if let ownerValue = envelope["owner"] {
            guard let owner = objectValue(ownerValue) else {
                return invalid("malformedOwner")
            }
            let allowedOwnerKeys: Set<String> = ["taskID", "runID", "environmentID", "jobID"]
            for key in owner.keys where !allowedOwnerKeys.contains(key) {
                return invalid("unknownOwnerField")
            }
            func identifier(_ key: String) -> String? {
                guard let raw = stringValue(owner[key]), let id = UUID(uuidString: raw),
                      id != nilUUID else { return nil }
                return raw
            }
            switch scope {
            case .taskExecution:
                guard let taskID = identifier("taskID") else {
                    return invalid("invalidOwnertaskID")
                }
                identity.taskID = taskID
                guard let runID = identifier("runID") else {
                    return invalid("invalidOwnerrunID")
                }
                identity.runID = runID
                if owner["environmentID"] != nil {
                    guard let environmentID = identifier("environmentID") else {
                        return invalid("invalidOwnerenvironmentID")
                    }
                    identity.environmentID = environmentID
                }
                if owner["jobID"] != nil {
                    guard let jobID = identifier("jobID") else {
                        return invalid("invalidOwnerjobID")
                    }
                    identity.jobID = jobID
                }
            case .conversationLifecycle:
                if owner.keys.contains(where: { $0 != "taskID" }) {
                    return invalid("conversationLifecycleMustNotCarryRunIdentity")
                }
                guard let taskID = identifier("taskID") else {
                    return invalid("invalidOwnertaskID")
                }
                identity.taskID = taskID
            case .launch:
                if let rule, rule.allowsCreateIntent {
                    // New identity: no owner is the explicit shape; a taskID
                    // here would claim a not-yet-created conversation.
                    return invalid("newIdentityMustNotCarryOwner")
                }
                if owner.keys.contains(where: { $0 != "taskID" }) {
                    return invalid("launchMustNotCarryExecutionRoles")
                }
                guard let taskID = identifier("taskID") else {
                    return invalid("invalidOwnertaskID")
                }
                identity.taskID = taskID
            case .applicationConfiguration:
                return invalid("configurationScopeMustNotCarryOwner")
            }
        } else {
            switch scope {
            case .taskExecution:
                return invalid("missingExecutionOwner")
            case .conversationLifecycle:
                return invalid("missingTaskIdentity")
            case .launch:
                if let rule, rule.allowsCreateIntent {
                    // New identity: absent owner is required.
                } else {
                    return invalid("missingTaskIdentity")
                }
            case .applicationConfiguration:
                break
            }
        }

        if scope == .launch, let rule, rule.allowsCreateIntent {
            guard createIntent else {
                // A new-identity command without explicit create intent would
                // otherwise have to fabricate a revision or a taskID.
                return invalid("createIntentRequired")
            }
        }

        // Revision rules.
        if let revisionValue = envelope["revision"] {
            guard operation == .submit else {
                return invalid("revisionNotAllowedForPollOperation")
            }
            guard let revision = objectValue(revisionValue),
                  let resourceID = stringValue(revision["resourceID"]),
                  isNonBlank(resourceID),
                  let version = stringValue(revision["version"]),
                  isNonBlank(version) else {
                return invalid("invalidRevision")
            }
            if createIntent { return invalid("revisionForNewIdentity") }
            if !revisionRequired { return invalid("revisionNotAllowed") }
            // Revision values are opaque identities: never trimmed.
        } else {
            if operation == .submit, revisionRequired, !createIntent {
                return invalid("missingRevisionForStatefulCommand")
            }
        }

        // Settings-domain payloads are closed typed vocabularies. This check
        // runs after the envelope identity/revision/stateful rules and before
        // any handler lookup, so an invalid payload can never dispatch a side
        // effect. Existing labels keep their frozen behaviour: only the five
        // additive labels (and the third content.read entry under
        // personalization) are validated here.
        if let rule = matrixRule, rule.scope == .applicationConfiguration,
           let label = rule.configurationScope,
           SettingsDomainV1.owns(command: command, label: label) {
            let payloadValue: SettingsDomainV1.JSONValue?
            if let rawPayload = envelope["payload"] {
                guard let converted = settingsJSONValue(rawPayload) else {
                    return invalid("invalidPayload")
                }
                payloadValue = converted
            } else {
                payloadValue = nil
            }
            if let failure = SettingsDomainV1.validate(
                payload: payloadValue,
                command: command,
                label: label,
                createIntent: createIntent,
                revisionPresent: envelope["revision"] != nil
            ) {
                return ValidationResult(isValid: false, errorCode: failure.code,
                                        reason: failure.reason)
            }
        }

        // Cursor rules: a run cursor is never accepted as an operation cursor
        // and vice versa. The cursor role is part of the command's identity.
        if let cursorValue = envelope["cursor"] {
            guard operation == .runEventPoll else {
                return invalid("cursorRoleMismatch")
            }
            guard let cursor = objectValue(cursorValue) else {
                return invalid("invalidEventCursor")
            }
            for key in cursor.keys where key != "runID" && key != "sequence" {
                return invalid("invalidEventCursor")
            }
            guard let rawRunID = stringValue(cursor["runID"]),
                  let runID = UUID(uuidString: rawRunID), runID != nilUUID,
                  let sequence = integerValue(cursor["sequence"]), sequence >= 0 else {
                return invalid("invalidEventCursor")
            }
            // Compare parsed UUID values (not raw spelling), matching the
            // frozen v2 cursor-run rule without weakening identity checks.
            guard let ownerRunID = identity.runID,
                  let ownerUUID = UUID(uuidString: ownerRunID), ownerUUID == runID else {
                return invalid("cursorRunMismatch")
            }
        } else if operation == .runEventPoll {
            return invalid("missingEventCursor")
        }

        // Effect cursor: applicationConfiguration scope, opaque host receipt,
        // nonnegative sequence, no fabricated run/environment/job.
        if let effectValue = envelope["effect"] {
            guard operation == .effectPoll else {
                return invalid("effectIdentityNotAllowed")
            }
            guard let effect = objectValue(effectValue) else {
                return invalid("invalidEffectCursor")
            }
            for key in effect.keys where key != "operationReceiptID" && key != "sequence" {
                return invalid("invalidEffectCursor")
            }
            guard let receipt = stringValue(effect["operationReceiptID"]),
                  isNonBlank(receipt), receipt.count <= 256,
                  !receipt.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let sequence = integerValue(effect["sequence"]), sequence >= 0 else {
                return invalid("invalidEffectCursor")
            }
            // The receipt is opaque; shape cannot prove it exists for the
            // current App instance. The facade owns that check.
        } else if operation == .effectPoll {
            return invalid("missingEffectCursor")
        }

        // Grant references are opaque references, never the grant itself.
        if let grantValue = envelope["grantID"] {
            guard let raw = stringValue(grantValue), let grant = UUID(uuidString: raw),
                  grant != nilUUID else {
                return invalid("invalidGrantReference")
            }
            if operation != .submit { return invalid("grantNotAllowedForPollOperation") }
            // Validation never grants authority; the host binder resolves it.
        }

        guard let correlation = stringValue(envelope["correlationID"]),
              isNonBlank(correlation) else {
            return invalid("missingCorrelation")
        }
        guard correlation == requestID else {
            // Structural-invalid taxonomy for v3: every malformed envelope is
            // error=invalidEnvelope with a specific reason. A correlation that
            // does not equal the request identity is one such structural
            // rejection, and it is decided before any handler lookup, so a
            // mismatch can never dispatch. The frozen v2 path keeps its own
            // correlationMismatch error code unchanged.
            return invalid("correlationMismatch")
        }
        return ValidationResult(isValid: true, errorCode: "", reason: "")
    }
}
