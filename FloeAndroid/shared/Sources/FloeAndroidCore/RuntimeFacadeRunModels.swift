// SPDX-License-Identifier: MPL-2.0
//
// RB-4 RunDomain — wire models, opaque revisions and the EXACT v3 handler
// binding plan for the 16 frozen run/child/event matrix commands
// (private source candidate; NOT compiled, NOT executed, NOT registered).
//
// Authority chain (READ FIRST):
// * BRIDGE_V3_MAIN_DECISIONS.json + runtime-facade-contract/{contract.json,
//   service-map.json,MAIN_REVIEW_ADDENDUM.md}: scope/identity/revision rules,
//   receipt honesty (`acceptedQueue{operationReceiptID, correlationID}` only;
//   `prepared{real minted IDs}` / `started{runID}` appear ONLY after the
//   ORIGINAL atomic prepare commits; `completed{page|value}` for pure reads),
//   and the closed errorCode vocabulary. `run.skillcancel` is taskExecution;
//   `event.poll` keeps `floe.event-cursor/3` and stays separate from the
//   pre-run `effect.poll` / `floe.effect-cursor/3`.
// * FloeAndroid/shared/Sources/FloeAndroidCore/BridgeEnvelopeV3.swift
//   (live, frozen v3 grammar): taskExecution requires owner.taskID+runID;
//   launch `run.start` requires an existing-conversation taskID + revision
//   (no createIntent), `run.startTask` requires explicit createIntent and
//   forbids owner/revision; env/job roles are OPTIONAL REAL identities only
//   and shape never proves existence. Handler keys are
//   `BridgeV3.handlerKey(scope:command:)`. No new wire commands, labels,
//   operation IDs or status promotion are introduced here.
// * runtime-bootstrap-main-reviewed-source/ (Main-reviewed frozen RB1 API,
//   archive e975c8a0089a4807d1ed9bcbd22325a52013ba84cf69bbce5f5f1e6da6ae5529;
//   21-file MANIFEST): `RuntimeCommandEnvelopeJob` / `RuntimeCommandResult` /
//   `RuntimeAsyncProcessor` / `RuntimeDomainRegistry` /
//   `FacadeCommandMailbox` / `FacadeEffectPump` (`RuntimeEffectItem.Kind
//   .prepared/.started` are the NON-terminal live stages Main's overlay kept
//   `isTerminal == false`) / `FacadeEventPump` / `FacadeContentReader` /
//   `FacadeFrameBudget` / `RuntimeOwnedWorkRegistry` (attach/detach/
//   isAttached/count/countsByKind/waitForDrain; kinds run/childRun/tool/
//   conversation/vaultMaintenance) / `AndroidRuntimeBootstrap
//   .MissingBinding.runDomain` (the typed admission barrier THIS package
//   binds; source alone registers nothing and flips nothing).
// * runtime-conversation-history-source/ (RB3 candidate) —
//   `ConversationRowRevision` (floe.conversation-row.v1 FULL RAW-ROW digest;
//   Main settled, NOT updatedAt-only) and the `ConversationDeletionLifecycle`
//   port. Main review 2026-10-19 CH-R2/CH-R3 corrections are BINDING for the
//   RB4 concrete adapter: the registry `countsByKind(for:)` is GLOBAL per
//   epoch, so deletion quiescence must be proven with the REAL
//   per-conversation owned-token mapping plus exact-token
//   `RuntimeOwnedWorkRegistry.isAttached(_:)` and explicit
//   conversationID+epoch proof — never by blocking conversation A on
//   unrelated conversation B; the deleting guard must be operation-owned
//   with finish/abort/commit release at every exit (CH-R3). Root retirement
//   keeps the global counts gate (RB1) — only per-conversation DELETION
//   uses the scoped proof.
//
// What this package binds (real original APIs, never a parallel engine):
// FloePersistence.SQLiteRunLaunchStore.prepare (:124-446, ONE writer
// transaction), FloeAgentRuntime.ConversationRunService
// (startPrepared :514 / resumePrepared :543 / cancel :570 / resolveApproval
// :585 / updateApprovalPolicy :592 / steer :599 / withdrawSteer :606 /
// snapshot :378 / events() nonisolated :455), FloePersistence
// .SQLiteRunningInputStore (queue/edit/remove/reorder/claim/
// beginSteerPromotion/markSteerAccepted/markConsumed/restoreQueued),
// SQLiteRunStore durable event pages (:499 `events(runID:afterSequence:
// limit:)`, per-run monotonic sequence), SQLiteChildRunStore
// children(:359)/entries(:383 -> ChildRunEntryPage), FileCheckpointStore
// (AgentRuntime.swift:315-341, atomic <runID>.checkpoint.json under the
// trusted app-private checkpointDirectory), SQLiteWorkspaceStore
// taskPolicy(:459)/saveTaskPolicy(:470), ModelConfigurationStore and the
// original AdapterFactory/gate/ingress seams (see RuntimeFacadeRunIngress).
// ConversationCenter remains an ios-reference for ORDERING behavior only
// (launch :3657-3825, submitRunningInput :4548-4582, promoteToSteer,
// retry/resume :6196-6295, resolve :6480-6545, track :7296-7366); its
// MainActor/UIKit/CloudKit/Keychain couplings are NOT copied.
//
// Temporary identity: this package implements ORDINARY runs only. The exact
// seam RB5 needs is typed below (`RunExecutionIdentity.temporary` is
// structurally rejected with `temporaryDomainUnbound`, so a temporary launch
// can never be silently persisted as ordinary, and no RAM store is invented
// here). `RunContext`/stores stay original types.
import Foundation
import Crypto
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime

// MARK: - Closed domain error vocabulary (wire-visible)

/// Typed refusal/failure identifiers for run-domain replies. `code` is the
/// wire `error` member (contract errorCodeVocabulary: facade additions only;
/// envelope grammar codes stay owned by BridgeV3/RB1) and `reason` is a
/// closed machine string — never path, envelope bytes, provider text or
/// secret material. Ordinary UI copy maps these in Kotlin; raw reasons are
/// diagnostic detail only.
public struct RunDomainError: Error, Sendable, Equatable {
    public enum Code: String, Sendable, CaseIterable {
        case notFound                   // unknown conversation/run/input/child
        case staleRevision              // opaque revision CAS mismatch
        case duplicateInFlight          // run already owned by a live launch/service
        case persistenceUnavailable     // original store threw (typed, never silent)
        case needsConfiguration         // no enabled provider/model route yet
        case credentialUnavailable      // gateway/secret state blocks the run
        case transportUnavailable       // provider transport not Main-qualified
        case gateFailClosed             // catastrophic corpus invalid/unloadable
        case sessionFenced              // deleting guard / retired generation
        case unsupportedRole            // env/job/local/temporary role requested
        case capabilityNotUsable        // RB6-owned binding not registered
        case payloadTooLarge            // decoded payload over domain bound
        case invalidState               // command illegal for the durable state
        case internalError              // invariant broken (classified, never fatal)
    }
    public enum Reason: String, Error, Sendable, CaseIterable {
        case conversationMissing, runMissing, inputMissing, childMissing
        case revisionMismatch, revisionAbsent
        case launchAlreadyInFlight, serviceAlreadyLive
        case storeWriteFailed, storeReadFailed
        case providerDisabled, modelDisabled, modelBelongsToOtherProvider
        case gatewayUnregistered, secretMissing, secretInvalidated, secretLocked
        case transportNotQualified
        case corpusInvalid, corpusAbsent
        case deletingGuarded, generationRetired, epochFenced
        case environmentRoleUnresolvable, jobRoleUnresolvable, localInferenceUnsupported
        case temporaryDomainUnbound
        case skillCancellationUnbound
        case queueFull, inputNotQueued, steerAlreadyConsumed, steerRaceConsumed
        case runNotRetryable, runAwaitingDependency
        case approvalNotPending, approvalGenerationMismatch, approvalWorkspaceOwnershipChanged
        case goalModeUnsupportedStore, intelligenceStoreUnbound
        case payloadInvalid, payloadTooLarge
        case normalizerUnbound, checkpointIdentityMismatch
        // RUN-S4 repair: an image handle was presented while the trusted
        // bounded image loader is unbound (refusal lands BEFORE any staged
        // IO); also used by the temporary surface, which denies images
        // before any IO by the RAM-only contract.
        case imageLoaderUnbound
        // goal-core code batch (2026-10-21, ledger-counted ONE additive
        // reason): the ordinary conversation currently holds a live run,
        // an in-flight launch admission or an in-flight manual compaction,
        // so a quiescence-requiring control (`conversation.compact`
        // admission, its launch-side reciprocal refusal, and the
        // goal.confirm no-live-run proof) refuses honestly. Existing
        // reasons stay exactly as before; no existing case changed.
        case conversationActive
        // post-run stop wiring (Main review 2026-10-21, SECOND explicit
        // ledger-counted additive INTERNAL reason): an in-process goal
        // CONTINUATION launch admits under its parent review's permit; once
        // the user's explicit run.cancel invalidated that permit (stop set +
        // reservation removed synchronously), a continuation still inside
        // the launch pipeline's admission window refuses honestly at the
        // next fence re-check instead of racing the Stop. Internal machine
        // vocabulary only: no new public command, payload or code.
        case continuationStopped
        case `internal`
    }
    public let code: Code
    public let reason: Reason

    /// Bounded static localization phase for the launch pipeline (the
    /// storeOpenFailed/storeReadFailed vocabulary has many catch sites; the
    /// phase says WHICH one refused). Diagnostic metadata ONLY: default nil
    /// preserves every existing exact error byte-for-byte; a phase is a
    /// closed static enum string, never a path, SQL, payload or free text.
    /// Added for Main's ready-cloud diagnosis; the App debug FloeRunFailure
    /// whitelist already prints `phase`.
    public enum Phase: String, Sendable, CaseIterable {
        case conversationProof    // ordinaryExists / row digest / revision CAS
        case modelResolution      // RunModelAssembly.resolveSelected
        case credentialResolution // ingress.resolve (gateway state)
        case gateAdmission        // catastrophic corpus gate
        case transportAdmission   // qualified transport gate
        case environmentProof     // optional env/job ownership proof
        case stagedReservation    // staged attachment lease reservation
        case capabilityAdmission  // mode/vision capability admit
        case launchPrepare        // the atomic launch commit
        case historyLoad          // conversation history assembly
        case imageLoad            // staged image loading
        case serviceAssembly      // ConversationRunService construction
    }
    public let phase: Phase?
    /// Typed SQLite result codes when the underlying error was a GRDB
    /// DatabaseError (numeric codes ONLY — never message/sql/args).
    public let storePrimaryCode: Int32?
    public let storeExtendedCode: Int32?

    public init(_ code: Code, _ reason: Reason, phase: Phase? = nil,
                storePrimaryCode: Int32? = nil, storeExtendedCode: Int32? = nil) {
        self.code = code
        self.reason = reason
        self.phase = phase
        self.storePrimaryCode = storePrimaryCode
        self.storeExtendedCode = storeExtendedCode
    }

    /// Returns a copy carrying the bounded phase (never replaces an error's
    /// exact code/reason; never attaches store codes after the fact).
    public func addingPhase(_ phase: Phase?) -> RunDomainError {
        guard let phase, self.phase == nil else { return self }
        return RunDomainError(code, reason, phase: phase,
                              storePrimaryCode: storePrimaryCode,
                              storeExtendedCode: storeExtendedCode)
    }

    /// Business error identity is EXACTLY (code, reason) — the only fields
    /// before the additive diagnostic metadata. The optional phase/store
    /// codes NEVER participate in equality (Main decision: diagnostics must
    /// not change business error identity); they are asserted explicitly and
    /// through `wireObject` where annotated.
    public static func == (lhs: RunDomainError, rhs: RunDomainError) -> Bool {
        lhs.code == rhs.code && lhs.reason == rhs.reason
    }

    /// Wire object: {"error": <code raw>, "reason": <reason raw>} — settled
    /// async effect carrier for rejected outcomes. The optional bounded
    /// diagnostic members appear ONLY when set (default-nil errors keep the
    /// exact original two-key shape).
    public var wireObject: [String: String] {
        var object = ["error": code.rawValue, "reason": reason.rawValue]
        if let phase { object["phase"] = phase.rawValue }
        if let storePrimaryCode { object["storePrimary"] = String(storePrimaryCode) }
        if let storeExtendedCode { object["storeExtended"] = String(storeExtendedCode) }
        return object
    }
}

// MARK: - Opaque revisions (settled identities for the stateful commands)

/// Canonical resourceID spelling for run-domain revisions. Values mirror the
/// contract binding table exactly: `run.<runID>/state`,
/// `approval.<callID>/requestedAt`, `taskPolicy.<conversationID>/updatedAt`,
/// plus the conversation-row CAS (`ConversationRowRevision.resourceID`,
/// floe.conversation-row.v1) reused from RB3 for `run.start` / `run.queue`.
/// `pendingInput.<inputID>` / `pendingQueue.<conversationID>` are the closed
/// input-mutation identities (Main reconciliation point: the contract left
/// `run.input.*` resource naming implicit; these are opaque identity
/// strings, not new schema or counters).
public enum RunWireRevision {
    public static func runResourceID(_ runID: UUID) -> String { "run.\(runID.uuidString)" }
    public static func approvalResourceID(callID: String) -> String { "approval.\(callID)" }
    public static func taskPolicyResourceID(_ conversationID: UUID) -> String {
        "taskPolicy.\(conversationID.uuidString)"
    }
    public static func pendingInputResourceID(_ inputID: UUID) -> String {
        "pendingInput.\(inputID.uuidString)"
    }
    public static func pendingQueueResourceID(_ conversationID: UUID) -> String {
        "pendingQueue.\(conversationID.uuidString)"
    }

    /// goal-core code batch (2026-10-21, additive identities): the durable
    /// goal row's opaque revision identity for `goal.confirm`. The version
    /// is the ORIGINAL monotonic goal `revision` integer (ConversationGoal.
    /// revision, IntelligenceStore CAS), never a facade-invented counter.
    public static func goalResourceID(_ goalID: UUID) -> String {
        "goal.\(goalID.uuidString)"
    }

    public static func goalVersion(revision: Int) -> String { "rev:\(revision)" }

    /// Accepted-plan revision identity for the plan card (`plan.accept`
    /// proves the conversation-row digest in the envelope; this bounded
    /// descriptor is the plan's own display identity — id + revision + the
    /// ORIGINAL plan digest string — never an authority token).
    public static func planVersion(revision: Int, digest: String) -> String {
        "rev:\(revision):\(digest)"
    }

    /// Run revision version = the ORIGINAL durable `RunRecord.state` string.
    /// It is the native state vocabulary (preparing/streamingModel/...;
    /// AgentState.name) — never a facade-invented status promotion.
    public static func runVersion(state: String) -> String { state }

    /// Approval revision version = requestedAt wire date (fractional-second
    /// ISO-8601, the mirrored original PersistenceCodec shape).
    public static func approvalVersion(requestedAt: Date) -> String {
        RunWireDate.encode(requestedAt)
    }

    public static func taskPolicyVersion(updatedAt: Date) -> String {
        RunWireDate.encode(updatedAt)
    }

    public static func inputVersion(updatedAt: Date) -> String {
        RunWireDate.encode(updatedAt)
    }

    /// Queue-order version = SHA-256 hex of the exact ordered queued-id list.
    /// `run.input.reorder` CAS: the host must prove the order it observed.
    public static func queueVersion(orderedIDs: [UUID]) -> String {
        let joined = orderedIDs.map { $0.uuidString }.joined(separator: ",")
        return RunWireDigest.sha256Hex(Data(joined.utf8))
    }
}

/// Local mirror of the ORIGINAL PersistenceCodec fractional-seconds date
/// format (FloePersistence/PersistenceCodec.swift:9-25 — internal to that
/// module, so the two PURE format lines are mirrored EXACTLY as the accepted
/// RB3/settings-defaults adapters do; no shared source is edited and no new
/// format is invented).
public enum RunWireDate {
    // ISO8601DateFormatter is documented thread-safe for formatting/parsing;
    // the shared instances are immutable after this initialization.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()
    nonisolated(unsafe) private static let fallback: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime]
        return value
    }()

    public static func encode(_ date: Date) -> String { formatter.string(from: date) }

    /// Strict decode; accepts only the exact original encodings (fractional
    /// required — a second-precision stamp proves a different writer and the
    /// CAS must refuse rather than silently normalize).
    public static func decode(_ value: String) -> Date? {
        formatter.date(from: value) ?? fallbackDate(from: value)
    }

    private static func fallbackDate(from value: String) -> Date? { nil }
}

/// Shared hex helper. Canonical digests for conversation-row revisions stay
/// owned by RB3 `ConversationRowRevision` (floe.conversation-row.v1 with the
/// accepted P0 `SettingsDomainV1.CanonicalDigest`); this helper is only used
/// for opaque queue-order identities, never re-implementing those helpers.
/// `Crypto.SHA256` is the same module dependency the reviewed RB1 files use.
public enum RunWireDigest {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Frame budget (actual serialized UTF-8; contract frameBudget)

/// Snapshot/page budgets. The hard bound is the frozen envelope (65_536);
/// the normal serialized payload budget is 48 KiB including JSON escaping
/// (measured with `FacadeFrameBudget.serializedBytes` — never `.count`), and
/// inline current answer/reasoning chunks get a bounded 32 KiB allowance
/// before the rest rides durable pages/content handles.
public enum RunDomainLimits {
    public static let hardEnvelopeBytes = 65_536
    public static let pageBudgetBytes = 49_152          // 48 KiB normal
    public static let snapshotInlineBudgetBytes = 32_768 // 32 KiB chunk allowance
    public static let durablePageSize = 200              // RunStore.events limit
    public static let maximumBoundedArrayItems = 64
    public static let maximumRecentToolItems = 16
    public static let maximumPendingInputItems = 64
    public static let maximumChildItems = 32
    public static let maximumChunkReadBytes = 49_152     // FacadeContentReader bound
    /// Steer/queue content bound per input row (original store trims; this is
    /// the facade admission ceiling inside one 64 KiB envelope with slack).
    public static let maximumInputContentBytes = 32_768
    public static let maximumGoalBytes = 16_384
    /// Live consumer attach ceiling: one consumer per run; attached runs are
    /// bounded by FacadeEventPump.Limits.maximumConsumers (32) — the domain
    /// never attaches more (typed `sessionFenced`/backpressure refusal for
    /// NEW snapshots-only pollers beyond that bound; existing pollers use
    /// durable pages + snapshot regardless).
}

// MARK: - Strict payload parsing (closed keys; SettingsDomainV1.JSONValue)

/// The accepted P0 JSON value + strict reader helpers are consumed BY NAME
/// (`SettingsDomainV1.JSONValue`, final accepted P0 source; the a8 publisher
/// may repair bounded encoding — the integration must consume the qualified
/// helper AS PUBLISHED, per settings-defaults dependencyHashEvolution). This
/// package never copies or restores an older helper body and never invents a
/// parallel JSON type.
public enum RunPayloadReader {
    /// JSONValue → typed reader with closed-key enforcement. `object(keys:)`
    /// rejects unknown keys and wrong types with RunDomainError
    /// (.payloadTooLarge or .invalidState carrying `payloadInvalid`; callers
    /// map to the wire `invalidEnvelope`-adjacent rejected effects).
    public struct Object {
        let value: SettingsDomainV1.JSONValue
        let fields: [String: SettingsDomainV1.JSONValue]

        init(_ value: SettingsDomainV1.JSONValue, allowed: Set<String>) throws {
            guard case .object(let object) = value else {
                throw RunDomainError(.invalidState, .payloadInvalid)
            }
            for key in object.keys where !allowed.contains(key) {
                throw RunDomainError(.invalidState, .payloadInvalid)
            }
            self.value = value
            self.fields = object
        }

        func take(_ key: String) throws -> SettingsDomainV1.JSONValue {
            guard let field = fields[key] else {
                throw RunDomainError(.invalidState, .payloadInvalid)
            }
            return field
        }

        func optional(_ key: String) -> SettingsDomainV1.JSONValue? { fields[key] }

        func string(_ key: String, maxBytes: Int = 16_384,
                    nonBlank: Bool = true, trimmed: Bool = false) throws -> String {
            guard case .string(let raw)? = fields[key] else {
                throw RunDomainError(.invalidState, .payloadInvalid)
            }
            let candidate = trimmed ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : raw
            guard !candidate.isEmpty || !nonBlank else {
                throw RunDomainError(.invalidState, .payloadInvalid)
            }
            guard candidate.utf8.count <= maxBytes else {
                throw RunDomainError(.payloadTooLarge, .payloadTooLarge)
            }
            return candidate
        }

        func optionalString(_ key: String, maxBytes: Int = 16_384) throws -> String? {
            guard fields[key] != nil else { return nil }
            return try string(key, maxBytes: maxBytes, nonBlank: true)
        }

        func uuid(_ key: String) throws -> UUID {
            let raw = try string(key, maxBytes: 64)
            guard let id = UUID(uuidString: raw),
                  id != UUID(uuidString: "00000000-0000-0000-0000-000000000000")
            else { throw RunDomainError(.invalidState, .payloadInvalid) }
            return id
        }

        func optionalUUID(_ key: String) throws -> UUID? {
            guard fields[key] != nil else { return nil }
            return try uuid(key)
        }

        func integer(_ key: String, min: Int64, max: Int64) throws -> Int64 {
            guard case .integer(let raw)? = fields[key], raw >= min, raw <= max else {
                throw RunDomainError(.invalidState, .payloadInvalid)
            }
            return raw
        }

        func optionalInteger(_ key: String, min: Int64, max: Int64) throws -> Int64? {
            guard fields[key] != nil else { return nil }
            return try integer(key, min: min, max: max)
        }

        func bool(_ key: String) throws -> Bool {
            guard case .boolean(let raw)? = fields[key] else {
                throw RunDomainError(.invalidState, .payloadInvalid)
            }
            return raw
        }

        func optionalBool(_ key: String) throws -> Bool? {
            guard fields[key] != nil else { return nil }
            return try bool(key)
        }

        func array(_ key: String, maxItems: Int) throws -> [SettingsDomainV1.JSONValue] {
            guard case .array(let raw)? = fields[key], raw.count <= maxItems else {
                throw RunDomainError(.invalidState, .payloadInvalid)
            }
            return raw
        }

        func optionalArray(_ key: String, maxItems: Int) throws
            -> [SettingsDomainV1.JSONValue]? {
            guard fields[key] != nil else { return nil }
            return try array(key, maxItems: maxItems)
        }

        func object(_ key: String, allowed: Set<String>) throws -> Object {
            guard let field = fields[key] else {
                throw RunDomainError(.invalidState, .payloadInvalid)
            }
            return try Object(field, allowed: allowed)
        }
    }

    public static func decode(_ data: Data) -> SettingsDomainV1.JSONValue? {
        SettingsDomainV1.JSONValue.decode(data)
    }
}

// MARK: - Run start queries

/// Frozen execution identity of one launch. G02 ordinary only; the RB5
/// temporary atomic Keep/lifecycle package reuses the SAME command surface
/// with the RAM store/context seam (exposed, never persisted here).
public enum RunExecutionIdentity: String, Sendable, Equatable {
    case ordinary
    case temporary
}

public struct RunStartQuery: Sendable, Equatable {
    /// Existing conversation (owner.taskID) — proven separately from the
    /// envelope by the domain against the durable row.
    public var conversationID: UUID
    /// The goal text AFTER the ingress scan (placeholders preserved).
    public var goal: String
    /// chat | plan | goal — the original RunLaunchStore vocabulary. Plan and
    /// goal are ACTUAL supported modes of the same engine, not new commands.
    public var mode: RunLaunchMode
    public var providerID: UUID
    public var modelID: UUID
    /// Opaque host-issued staging handles for already-owned staged
    /// attachments (P8/RB7 owns the compose route). This package consumes ONLY
    /// handle identities through the original atomic prepare via the bound
    /// staging authority; bytes never cross the JSON envelope and an
    /// unregistered staging authority is a typed refusal before prepare.
    public var stagedAttachmentHandles: [String]
    /// Task-relative file scope / tool ceiling authored by the HOST (never by
    /// model or user text). nil keeps the persisted task policy ceiling.
    public var hostToolCeiling: [String]?
    public var policy: DraftTaskPolicy
    /// Optional REAL environment/job identities. When present the domain
    /// proves them against the trusted ownership ports; G02 cannot resolve
    /// Linux roles, so a REQUESTED role that cannot be proven real is
    /// rejected with unsupportedRole (never a sentinel).
    public var requestedEnvironmentID: String?
    public var requestedJobID: String?
    /// goal-core code batch (2026-10-21, ADDITIVE optional grammar): the
    /// structured durable goal the trusted App producer created through the
    /// ORIGINAL GoalBuilder semantics, riding the EXISTING ordinary
    /// `run.start` goal-mode launch. nil keeps every previous launch
    /// byte-identical (original `ensureDurableGoal` behavior). Only
    /// mode == .goal accepts this key; the create-intent surface
    /// (`run.startTask`) refuses it structurally. The domain commits the
    /// goal identity + criteria/steps rows in the SAME C1 writer
    /// transaction as the run/message/launch — no flattened prompt
    /// substitute, no confirmation flags, no model-authored writer.
    public var goalDefinition: StructuredGoalDefinition?

    public init(conversationID: UUID, goal: String, mode: RunLaunchMode,
                providerID: UUID, modelID: UUID,
                stagedAttachmentHandles: [String] = [],
                hostToolCeiling: [String]? = nil,
                policy: DraftTaskPolicy = DraftTaskPolicy(),
                requestedEnvironmentID: String? = nil,
                requestedJobID: String? = nil,
                goalDefinition: StructuredGoalDefinition? = nil) {
        self.conversationID = conversationID
        self.goal = goal
        self.mode = mode
        self.providerID = providerID
        self.modelID = modelID
        self.stagedAttachmentHandles = stagedAttachmentHandles
        self.hostToolCeiling = hostToolCeiling
        self.policy = policy
        self.requestedEnvironmentID = requestedEnvironmentID
        self.requestedJobID = requestedJobID
        self.goalDefinition = goalDefinition
    }

    public static let allowedKeys: Set<String> = [
        "goal", "mode", "providerID", "modelID", "stagedAttachments",
        "toolCeiling", "approvalMode", "recoveryPolicy", "notificationPolicy",
        "environmentID", "jobID", "goalDefinition",
    ]

    public static func parse(payload: SettingsDomainV1.JSONValue?,
                             conversationID: UUID) throws -> RunStartQuery {
        let object = try RunPayloadReader.Object(
            payload ?? .object([:]), allowed: allowedKeys)
        return try parseFields(object, conversationID: conversationID)
    }

    /// Field-level parse shared by `run.start` (existing conversation) and
    /// `run.startTask` (create intent, whose closed `title` key is consumed
    /// one level up). Nothing is double-parsed or re-checked.
    static func parseFields(_ object: RunPayloadReader.Object,
                            conversationID: UUID) throws -> RunStartQuery {
        let goal = try object.string("goal", maxBytes: RunDomainLimits.maximumGoalBytes,
                                     trimmed: true)
        guard let mode = RunLaunchMode(rawValue: try object.string("mode", maxBytes: 12))
        else { throw RunDomainError(.invalidState, .payloadInvalid) }
        let policy = DraftTaskPolicy(
            approvalMode: try Self.approvalMode(object),
            recoveryPolicy: try Self.recoveryPolicy(object),
            notificationPolicy: try Self.notificationPolicy(object))
        var ceiling: [String]?
        if let raw = try object.optionalArray("toolCeiling", maxItems: 256) {
            ceiling = try raw.map { item in
                guard case .string(let name) = item,
                      name.utf8.count <= 128, !name.contains(" ") else {
                    throw RunDomainError(.invalidState, .payloadInvalid)
                }
                return name
            }
        }
        var handles: [String] = []
        if let raw = try object.optionalArray("stagedAttachments", maxItems: 64) {
            handles = try raw.map { item in
                guard case .string(let handle) = item,
                      handle.utf8.count <= 128, !handle.isEmpty else {
                    throw RunDomainError(.invalidState, .payloadInvalid)
                }
                return handle
            }
        }
        let goalDefinition = try StructuredGoalDefinition.parseOptional(object)
        if goalDefinition != nil, mode != .goal {
            // Structured goals are an ADDITIVE option of the EXISTING
            // goal-mode launch only — chat/plan launches keep the exact
            // original grammar and behavior (unknown-for-mode keys refuse).
            throw RunDomainError(.invalidState, .payloadInvalid)
        }
        return RunStartQuery(
            conversationID: conversationID,
            goal: goal,
            mode: mode,
            providerID: try object.uuid("providerID"),
            modelID: try object.uuid("modelID"),
            stagedAttachmentHandles: handles,
            hostToolCeiling: ceiling,
            policy: policy,
            requestedEnvironmentID: try object.optionalString("environmentID", maxBytes: 64),
            requestedJobID: try object.optionalString("jobID", maxBytes: 64),
            goalDefinition: goalDefinition)
    }

    static func approvalMode(_ object: RunPayloadReader.Object) throws -> TaskApprovalMode {
        // Optional with the ORIGINAL DraftTaskPolicy default (.ask).
        guard let raw = try object.optionalString("approvalMode", maxBytes: 24) else {
            return .ask
        }
        switch raw {
        case TaskApprovalMode.ask.rawValue: return .ask
        case TaskApprovalMode.automatic.rawValue: return .automatic
        case TaskApprovalMode.fullAccess.rawValue: return .fullAccess
        default: throw RunDomainError(.invalidState, .payloadInvalid)
        }
    }

    static func recoveryPolicy(_ object: RunPayloadReader.Object) throws -> TaskRecoveryPolicy {
        guard let raw = try object.optionalString("recoveryPolicy", maxBytes: 24) else {
            return .safePoint
        }
        guard let value = TaskRecoveryPolicy(rawValue: raw) else {
            throw RunDomainError(.invalidState, .payloadInvalid)
        }
        return value
    }

    static func notificationPolicy(_ object: RunPayloadReader.Object) throws -> TaskNotificationPolicy {
        guard let raw = try object.optionalString("notificationPolicy", maxBytes: 24) else {
            return .stages
        }
        guard let value = TaskNotificationPolicy(rawValue: raw) else {
            throw RunDomainError(.invalidState, .payloadInvalid)
        }
        return value
    }
}

/// The ORIGINAL RunLaunchStore mode vocabulary (chat|plan|goal).
public enum RunLaunchMode: String, Sendable, CaseIterable {
    case chat
    case plan
    case goal
}

/// goal-core code batch (2026-10-21, additive bounded grammar): the
/// structured goal carried by the EXISTING trusted ordinary `run.start`
/// goal-mode launch. Mirrors the ORIGINAL iOS GoalBuilder producer fields
/// (`ThreadDetailViewModel.createGoal`: objective + criteria +
/// blockingConditions + stoppingConditions, each trimmed with empty
/// entries dropped by the producer before sending). This payload can create
/// no authority: it rides only the launch scope's existing-conversation
/// row-digest CAS through the trusted host ingress (model/tool/imported
/// JSON has no route here), accepts NO approval/confirmation/review flags,
/// and is persisted by the domain as the ORIGINAL
/// `ConversationGoal`/`GoalCriterion` rows plus ONE `Advance goal`
/// inProgress step with the original initializer defaults inside the same
/// C1 writer transaction (never a flattened prompt substitute).
public struct StructuredGoalDefinition: Sendable, Equatable {
    public var objective: String
    public var criteria: [String]
    public var blockingConditions: [String]
    public var stoppingConditions: [String]

    public init(objective: String, criteria: [String],
                blockingConditions: [String], stoppingConditions: [String]) {
        self.objective = objective
        self.criteria = criteria
        self.blockingConditions = blockingConditions
        self.stoppingConditions = stoppingConditions
    }

    /// Bounded grammar ceiling (one 64 KiB envelope with slack; the run
    /// goal text keeps its OWN separate bound).
    public static let maximumCriteriaItems = 32
    public static let maximumConditionItems = 16
    public static let maximumCriterionItemBytes = 2_048
    public static let maximumConditionItemBytes = 2_048
    public static let allowedKeys: Set<String> = [
        "objective", "criteria", "blockingConditions", "stoppingConditions",
    ]

    /// Closed nested parse shared with `RunStartQuery.parseFields`. Absent
    /// key => nil (every previous launch keeps byte-identical behavior).
    /// Malformed / unknown nested keys / oversize => typed payload refusal
    /// BEFORE any durable effect (no residue).
    static func parseOptional(_ object: RunPayloadReader.Object) throws -> StructuredGoalDefinition? {
        guard object.optional("goalDefinition") != nil else { return nil }
        let definition = try object.object("goalDefinition", allowed: Self.allowedKeys)
        let objective = try definition.string("objective",
                                              maxBytes: RunDomainLimits.maximumGoalBytes,
                                              trimmed: true)
        func items(_ key: String, maxItems: Int, itemBytes: Int) throws -> [String] {
            guard let raw = try definition.optionalArray(key, maxItems: maxItems) else {
                return []
            }
            var values: [String] = []
            values.reserveCapacity(raw.count)
            for item in raw {
                guard case .string(let text) = item else {
                    throw RunDomainError(.invalidState, .payloadInvalid)
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.utf8.count <= itemBytes else {
                    throw RunDomainError(.payloadTooLarge, .payloadTooLarge)
                }
                // Original producer semantics: empty entries are dropped.
                if !trimmed.isEmpty { values.append(trimmed) }
            }
            return values
        }
        return StructuredGoalDefinition(
            objective: objective,
            criteria: try items("criteria", maxItems: Self.maximumCriteriaItems,
                                itemBytes: Self.maximumCriterionItemBytes),
            blockingConditions: try items("blockingConditions",
                                          maxItems: Self.maximumConditionItems,
                                          itemBytes: Self.maximumConditionItemBytes),
            stoppingConditions: try items("stoppingConditions",
                                          maxItems: Self.maximumConditionItems,
                                          itemBytes: Self.maximumConditionItemBytes))
    }
}

/// New-conversation launch (createIntent): title is host-authored, optional;
/// the minted conversation/run IDs exist only after the atomic commit.
public struct RunStartTaskQuery: Sendable, Equatable {
    public var conversationTitle: String
    public var inner: RunStartQuery

    public init(conversationTitle: String, inner: RunStartQuery) {
        self.conversationTitle = conversationTitle
        self.inner = inner
    }

    public static let allowedKeys: Set<String> = RunStartQuery.allowedKeys.union(["title"])

    public static func parse(payload: SettingsDomainV1.JSONValue?) throws -> RunStartTaskQuery {
        let object = try RunPayloadReader.Object(
            payload ?? .object([:]), allowed: allowedKeys)
        let title = try object.string("title", maxBytes: 160, nonBlank: true,
                                      trimmed: true)
        // conversationID is minted by the domain after prepare commits; the
        // inner query carries a reserved non-persistable probe identity that
        // the domain MUST replace with the real committed identity before it
        // is exposed anywhere.
        let inner = try RunStartQuery.parseFields(object, conversationID: Self.mintProbe)
        if inner.goalDefinition != nil {
            // goal-core code batch: the structured goal binds a DURABLE
            // conversation identity inside the C1 transaction; a
            // create-intent launch has no proven identity before the
            // commit, and the original GoalBuilder flow requires the
            // existing task. Refuse structurally (no half goal, no probe
            // row) — the producer uses `run.start` on the existing
            // conversation.
            throw RunDomainError(.invalidState, .payloadInvalid)
        }
        return RunStartTaskQuery(conversationTitle: title, inner: inner)
    }

    /// Non-persistable placeholder so `RunStartQuery.parse` can share the
    /// closed-key reader; the domain overwrites it with the REAL minted
    /// identity only after `SQLiteRunLaunchStore.prepare` commits.
    static let mintProbe = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}

// MARK: - Control / input / approval / policy queries

public struct RunCancelQuery: Sendable, Equatable {
    public var conversationID: UUID
    public var runID: UUID
    /// Opaque revision {run.<runID>, state}: refuses a cancel against a
    /// stale projection.
    public var expectedState: String

    public static let allowedKeys: Set<String> = ["expectedState"]

    public init(conversationID: UUID, runID: UUID, expectedState: String) {
        self.conversationID = conversationID
        self.runID = runID
        self.expectedState = expectedState
    }

    public static func parse(payload: SettingsDomainV1.JSONValue?, owner: OwnerIdentity) throws
        -> RunCancelQuery {
        let object = try RunPayloadReader.Object(
            payload ?? .object([:]), allowed: allowedKeys)
        return RunCancelQuery(conversationID: owner.taskID, runID: owner.runID,
                              expectedState: try object.string("expectedState", maxBytes: 48))
    }
}

public struct RunRetryQuery: Sendable, Equatable {
    public var conversationID: UUID
    public var runID: UUID
    public var expectedState: String

    public static let allowedKeys: Set<String> = ["expectedState"]

    public init(conversationID: UUID, runID: UUID, expectedState: String) {
        self.conversationID = conversationID
        self.runID = runID
        self.expectedState = expectedState
    }

    public static func parse(payload: SettingsDomainV1.JSONValue?, owner: OwnerIdentity) throws
        -> RunRetryQuery {
        let object = try RunPayloadReader.Object(
            payload ?? .object([:]), allowed: allowedKeys)
        return RunRetryQuery(conversationID: owner.taskID, runID: owner.runID,
                             expectedState: try object.string("expectedState", maxBytes: 48))
    }
}

public struct RunSteerQuery: Sendable, Equatable {
    public var conversationID: UUID
    public var runID: UUID
    /// The durable pending-input row identity: steer ALWAYS targets an
    /// already-queued row (original promoteToSteer ordering), so a bare text
    /// steer cannot bypass the durable exactly-once receipt.
    public var inputID: UUID
    public var expectedState: String

    public static let allowedKeys: Set<String> = ["inputID", "expectedState"]

    public init(conversationID: UUID, runID: UUID, inputID: UUID, expectedState: String) {
        self.conversationID = conversationID
        self.runID = runID
        self.inputID = inputID
        self.expectedState = expectedState
    }

    public static func parse(payload: SettingsDomainV1.JSONValue?, owner: OwnerIdentity) throws
        -> RunSteerQuery {
        let object = try RunPayloadReader.Object(
            payload ?? .object([:]), allowed: allowedKeys)
        return RunSteerQuery(conversationID: owner.taskID, runID: owner.runID,
                             inputID: try object.uuid("inputID"),
                             expectedState: try object.string("expectedState", maxBytes: 48))
    }
}

public struct RunQueueQuery: Sendable, Equatable {
    public var conversationID: UUID
    public var runID: UUID
    public var content: String
    public var mode: RunningInputMode
    public var selectedModelID: UUID?
    public var stagedAttachmentHandles: [String]
    /// G04R2 queue-input repair: the composer's REAL execution mode
    /// (`agent|chat|plan|goal` — the ORIGINAL iOS AgentExecutionMode raw
    /// vocabulary persisted with the row). The terminal drain launches the
    /// row under exactly this mode instead of a silent default. An absent
    /// key keeps the historical `agent` default, so old envelopes are
    /// unchanged.
    public var executionMode: String

    /// The CLOSED execution-mode vocabulary a queued row may carry.
    public static let allowedExecutionModes: Set<String> = [
        "agent", "chat", "plan", "goal",
    ]

    public static let allowedKeys: Set<String> = [
        "content", "mode", "selectedModelID", "stagedAttachments",
        "executionMode",
    ]

    public init(conversationID: UUID, runID: UUID, content: String,
                mode: RunningInputMode, selectedModelID: UUID?,
                stagedAttachmentHandles: [String],
                executionMode: String = "agent") {
        self.conversationID = conversationID
        self.runID = runID
        self.content = content
        self.mode = mode
        self.selectedModelID = selectedModelID
        self.stagedAttachmentHandles = stagedAttachmentHandles
        self.executionMode = executionMode
    }

    public static func parse(payload: SettingsDomainV1.JSONValue?, owner: OwnerIdentity) throws
        -> RunQueueQuery {
        let object = try RunPayloadReader.Object(
            payload ?? .object([:]), allowed: allowedKeys)
        let content = try object.string("content",
                                        maxBytes: RunDomainLimits.maximumInputContentBytes,
                                        trimmed: true)
        let rawMode = try object.string("mode", maxBytes: 12)
        guard let mode = RunningInputMode(rawValue: rawMode) else {
            throw RunDomainError(.invalidState, .payloadInvalid)
        }
        var handles: [String] = []
        if let raw = try object.optionalArray("stagedAttachments", maxItems: 64) {
            handles = try raw.map { item in
                guard case .string(let handle) = item, handle.utf8.count <= 128,
                      !handle.isEmpty else {
                    throw RunDomainError(.invalidState, .payloadInvalid)
                }
                return handle
            }
        }
        let executionMode = try object.optionalString("executionMode", maxBytes: 12) ?? "agent"
        guard allowedExecutionModes.contains(executionMode) else {
            throw RunDomainError(.invalidState, .payloadInvalid)
        }
        return RunQueueQuery(conversationID: owner.taskID, runID: owner.runID,
                             content: content, mode: mode,
                             selectedModelID: try object.optionalUUID("selectedModelID"),
                             stagedAttachmentHandles: handles,
                             executionMode: executionMode)
    }
}

public struct RunInputEditQuery: Sendable, Equatable {
    public var conversationID: UUID
    public var runID: UUID
    public var inputID: UUID
    public var content: String
    public var expectedInputVersion: String


    public init(conversationID: UUID, runID: UUID, inputID: UUID, content: String, expectedInputVersion: String) {
        self.conversationID = conversationID
        self.runID = runID
        self.inputID = inputID
        self.content = content
        self.expectedInputVersion = expectedInputVersion
    }

    public static let allowedKeys: Set<String> = ["inputID", "content", "expectedInputVersion"]

    public static func parse(payload: SettingsDomainV1.JSONValue?, owner: OwnerIdentity) throws
        -> RunInputEditQuery {
        let object = try RunPayloadReader.Object(
            payload ?? .object([:]), allowed: allowedKeys)
        return RunInputEditQuery(
            conversationID: owner.taskID, runID: owner.runID,
            inputID: try object.uuid("inputID"),
            content: try object.string("content",
                                       maxBytes: RunDomainLimits.maximumInputContentBytes,
                                       trimmed: true),
            expectedInputVersion: try object.string("expectedInputVersion", maxBytes: 64))
    }
}

public struct RunInputRemoveQuery: Sendable, Equatable {
    public var conversationID: UUID
    public var runID: UUID
    public var inputID: UUID
    public var expectedInputVersion: String


    public init(conversationID: UUID, runID: UUID, inputID: UUID, expectedInputVersion: String) {
        self.conversationID = conversationID
        self.runID = runID
        self.inputID = inputID
        self.expectedInputVersion = expectedInputVersion
    }

    public static let allowedKeys: Set<String> = ["inputID", "expectedInputVersion"]

    public static func parse(payload: SettingsDomainV1.JSONValue?, owner: OwnerIdentity) throws
        -> RunInputRemoveQuery {
        let object = try RunPayloadReader.Object(
            payload ?? .object([:]), allowed: allowedKeys)
        return RunInputRemoveQuery(
            conversationID: owner.taskID, runID: owner.runID,
            inputID: try object.uuid("inputID"),
            expectedInputVersion: try object.string("expectedInputVersion", maxBytes: 64))
    }
}

public struct RunInputReorderQuery: Sendable, Equatable {
    public var conversationID: UUID
    public var runID: UUID
    public var orderedIDs: [UUID]
    public var expectedQueueVersion: String


    public init(conversationID: UUID, runID: UUID, orderedIDs: [UUID], expectedQueueVersion: String) {
        self.conversationID = conversationID
        self.runID = runID
        self.orderedIDs = orderedIDs
        self.expectedQueueVersion = expectedQueueVersion
    }

    public static let allowedKeys: Set<String> = ["orderedIDs", "expectedQueueVersion"]

    public static func parse(payload: SettingsDomainV1.JSONValue?, owner: OwnerIdentity) throws
        -> RunInputReorderQuery {
        let object = try RunPayloadReader.Object(
            payload ?? .object([:]), allowed: allowedKeys)
        let raw = try object.array("orderedIDs", maxItems: 100)
        let ids: [UUID] = try raw.map { item in
            guard case .string(let value) = item, let id = UUID(uuidString: value),
                  id != RunWireNilUUID.value else {
                throw RunDomainError(.invalidState, .payloadInvalid)
            }
            return id
        }
        return RunInputReorderQuery(
            conversationID: owner.taskID, runID: owner.runID, orderedIDs: ids,
            expectedQueueVersion: try object.string("expectedQueueVersion", maxBytes: 128))
    }
}

enum RunWireNilUUID {
    static let value = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

/// `run.approval.resolve`. The decision scope is NEVER accepted as free
/// payload: `allow` re-derives the canonical ApprovalScope from the LIVE
/// pending request's actual ToolCall (call-bound grant, single use, exact
/// toolAuthorizationIdentity). User approval must not grant unconstrained new
/// tool/host scope, so paths/hostID/expiresAt come from the bound request and
/// the persisted task policy only — the payload may ONLY choose the decision
/// branch (allow / deny) plus an opaque deny reason.
public struct RunApprovalResolveQuery: Sendable, Equatable {
    public enum Branch: String, Sendable {
        case allow
        case deny
    }
    public var conversationID: UUID
    public var runID: UUID
    public var callID: String
    public var expectedApprovalVersion: String
    public var branch: Branch
    public var denyReason: String?


    public init(conversationID: UUID, runID: UUID, callID: String, expectedApprovalVersion: String, branch: Branch, denyReason: String?) {
        self.conversationID = conversationID
        self.runID = runID
        self.callID = callID
        self.expectedApprovalVersion = expectedApprovalVersion
        self.branch = branch
        self.denyReason = denyReason
    }

    public static let allowedKeys: Set<String> = [
        "callID", "decision", "reason", "expectedApprovalVersion",
    ]

    public static func parse(payload: SettingsDomainV1.JSONValue?, owner: OwnerIdentity) throws
        -> RunApprovalResolveQuery {
        let object = try RunPayloadReader.Object(
            payload ?? .object([:]), allowed: allowedKeys)
        let rawBranch = try object.string("decision", maxBytes: 12)
        guard let branch = Branch(rawValue: rawBranch) else {
            throw RunDomainError(.invalidState, .payloadInvalid)
        }
        return RunApprovalResolveQuery(
            conversationID: owner.taskID, runID: owner.runID,
            callID: try object.string("callID", maxBytes: 128, nonBlank: true),
            expectedApprovalVersion: try object.string("expectedApprovalVersion", maxBytes: 64),
            branch: branch,
            denyReason: try object.optionalString("reason", maxBytes: 512))
    }
}

/// `run.policy.update` (HOST-authored only — untrusted content never reaches
/// this command). Updates the persisted TaskPolicy row (approval mode +
/// explicit ceilings/flags) under an updatedAt CAS, then applies the rebuilt
/// policy to the live service through the ORIGINAL `updateApprovalPolicy`.
public struct RunPolicyUpdateQuery: Sendable, Equatable {
    public var conversationID: UUID
    public var runID: UUID
    public var expectedPolicyVersion: String
    public var approvalMode: TaskApprovalMode
    public var networkAllowed: Bool?
    public var uploadAllowed: Bool?
    public var credentialsAllowed: Bool?
    public var remoteExecutionAllowed: Bool?
    public var browserControlAllowed: Bool?


    public init(conversationID: UUID, runID: UUID, expectedPolicyVersion: String, approvalMode: TaskApprovalMode, networkAllowed: Bool?, uploadAllowed: Bool?, credentialsAllowed: Bool?, remoteExecutionAllowed: Bool?, browserControlAllowed: Bool?) {
        self.conversationID = conversationID
        self.runID = runID
        self.expectedPolicyVersion = expectedPolicyVersion
        self.approvalMode = approvalMode
        self.networkAllowed = networkAllowed
        self.uploadAllowed = uploadAllowed
        self.credentialsAllowed = credentialsAllowed
        self.remoteExecutionAllowed = remoteExecutionAllowed
        self.browserControlAllowed = browserControlAllowed
    }

    public static let allowedKeys: Set<String> = [
        "approvalMode", "expectedPolicyVersion", "networkAllowed", "uploadAllowed",
        "credentialsAllowed", "remoteExecutionAllowed", "browserControlAllowed",
    ]

    public static func parse(payload: SettingsDomainV1.JSONValue?, owner: OwnerIdentity) throws
        -> RunPolicyUpdateQuery {
        let object = try RunPayloadReader.Object(
            payload ?? .object([:]), allowed: allowedKeys)
        let rawMode = try object.string("approvalMode", maxBytes: 24)
        guard let mode = TaskApprovalMode(rawValue: rawMode) else {
            throw RunDomainError(.invalidState, .payloadInvalid)
        }
        return RunPolicyUpdateQuery(
            conversationID: owner.taskID, runID: owner.runID,
            expectedPolicyVersion: try object.string("expectedPolicyVersion", maxBytes: 64),
            approvalMode: mode,
            networkAllowed: try object.optionalBool("networkAllowed"),
            uploadAllowed: try object.optionalBool("uploadAllowed"),
            credentialsAllowed: try object.optionalBool("credentialsAllowed"),
            remoteExecutionAllowed: try object.optionalBool("remoteExecutionAllowed"),
            browserControlAllowed: try object.optionalBool("browserControlAllowed"))
    }
}

/// `run.skillcancel` — cancels ACTUAL owned tool work for one in-flight call
/// of the addressed run through the RB6-owned tool-cancellation port. NEVER a
/// fabricated Linux job id; no new status vocabulary.
public struct RunSkillCancelQuery: Sendable, Equatable {
    public var conversationID: UUID
    public var runID: UUID
    /// The provider call identity of the in-flight tool attempt (from the
    /// durable toolRequest event / live toolLifecycle frame). Optional: nil
    /// cancels ALL cancellable owned tool work for the run.
    public var callID: String?
    public var expectedState: String


    public init(conversationID: UUID, runID: UUID, callID: String?, expectedState: String) {
        self.conversationID = conversationID
        self.runID = runID
        self.callID = callID
        self.expectedState = expectedState
    }

    public static let allowedKeys: Set<String> = ["callID", "expectedState"]

    public static func parse(payload: SettingsDomainV1.JSONValue?, owner: OwnerIdentity) throws
        -> RunSkillCancelQuery {
        let object = try RunPayloadReader.Object(
            payload ?? .object([:]), allowed: allowedKeys)
        return RunSkillCancelQuery(
            conversationID: owner.taskID, runID: owner.runID,
            callID: try object.optionalString("callID", maxBytes: 128),
            expectedState: try object.string("expectedState", maxBytes: 48))
    }
}

// MARK: - Read queries

public struct SnapshotQuery: Sendable, Equatable {
    public var conversationID: UUID
    public var runID: UUID

    public init(conversationID: UUID, runID: UUID) {
        self.conversationID = conversationID
        self.runID = runID
    }

    public static func parse(owner: OwnerIdentity) -> SnapshotQuery {
        SnapshotQuery(conversationID: owner.taskID, runID: owner.runID)
    }
}

public struct ChildListQuery: Sendable, Equatable {
    public var conversationID: UUID
    public var parentRunID: UUID

    public init(conversationID: UUID, parentRunID: UUID) {
        self.conversationID = conversationID
        self.parentRunID = parentRunID
    }

    public static func parse(owner: OwnerIdentity) -> ChildListQuery {
        ChildListQuery(conversationID: owner.taskID, parentRunID: owner.runID)
    }
}

public struct ChildEntriesQuery: Sendable, Equatable {
    public var conversationID: UUID
    public var childRunID: UUID
    public var afterSequence: Int
    public var limit: Int


    public init(conversationID: UUID, childRunID: UUID, afterSequence: Int, limit: Int) {
        self.conversationID = conversationID
        self.childRunID = childRunID
        self.afterSequence = afterSequence
        self.limit = limit
    }

    public static let allowedKeys: Set<String> = ["childRunID", "afterSequence", "limit"]

    public static func parse(payload: SettingsDomainV1.JSONValue?, owner: OwnerIdentity) throws
        -> ChildEntriesQuery {
        let object = try RunPayloadReader.Object(
            payload ?? .object([:]), allowed: allowedKeys)
        return ChildEntriesQuery(
            conversationID: owner.taskID,
            childRunID: try object.uuid("childRunID"),
            afterSequence: Int(try object.integer("afterSequence", min: 0, max: 1 << 40)),
            limit: Int(try object.integer("limit", min: 1, max: 200)))
    }
}

/// Parsed owner roles shared by all taskExecution handlers.
public struct OwnerIdentity: Sendable, Equatable {
    public var taskID: UUID
    public var runID: UUID
    public var environmentID: UUID?
    public var jobID: UUID?
}

// MARK: - Replies (typed values; the binder carrier is Main-reconciled)

/// A settled bounded page/value. Carrier per Main's
/// RB1_TYPED_RESULT_CARRIER_MAIN_DECISION_20261019.json: identifier-only
/// `[String:String]` detail CANNOT carry encoded JSON, and this lane never
/// serializes a page into a string detail. The domain's public methods
/// return this typed reply DIRECTLY; Main's future binding adapter places
/// `page` into the typed result/effect payload added by the RB1 qualifier
/// lane. `commandResult()` below is the interim settlement: closed
/// identifier/reason detail ONLY (typed IDs, byte counts, cursors as opaque
/// strings) plus the frame-honest classification, so an oversized or
/// unencodable page fails typed instead of being silently dropped as
/// success. `pageBytes` is the ACTUAL encoded UTF-8/JSON-escaped size of the
/// complete page object measured by the shared escape-aware helper.
public struct RunTypedPage: Sendable, Equatable {
    public let object: SettingsDomainV1.JSONValue
    public let pageBytes: Int
    public init(object: SettingsDomainV1.JSONValue, pageBytes: Int) {
        self.object = object
        self.pageBytes = pageBytes
    }
}

public struct RunDomainReply: Sendable {
    public enum Outcome: Sendable, Equatable {
        case completedPage(page: RunTypedPage, nextCursor: String?)
        case mutationAccepted(detail: [String: String])
        case rejected(RunDomainError)
    }
    public let outcome: Outcome
    public init(_ outcome: Outcome) { self.outcome = outcome }

    /// The typed page for Main's binding adapter (direct until the qualifier
    /// lands the typed payload slot; never a parallel pump or a string
    /// carrier).
    public var typedPage: RunTypedPage? {
        if case .completedPage(let page, _) = outcome { return page }
        return nil
    }

    /// The mailbox-settlement projection: a completed page settles as
    /// `accepted` carrying BOTH the closed identifier detail AND the ACTUAL
    /// measured typed page through the frozen `RuntimeCommandResult.page`
    /// OBJECT slot (F7). The carrier keeps its own frame budget (48 KiB page
    /// / 64 KiB frame): an over-budget page still settles the typed
    /// `payloadTooLarge` refusal path instead of dropping content silently.
    /// `rejected` maps to typed effect classifications; no fabricated
    /// identity ever appears before a real commit.
    public func commandResult() -> RuntimeCommandResult {
        switch outcome {
        case .completedPage(let page, let nextCursor):
            guard page.pageBytes <= RunDomainLimits.pageBudgetBytes,
                  page.pageBytes > 0 else {
                return RuntimeCommandResult(kind: .failed, code: .frameBudgetExceeded)
            }
            var detail: [String: String] = [
                "result": "page",
                "pageBytes": String(page.pageBytes),
            ]
            if let nextCursor { detail["nextCursor"] = nextCursor }
            return RuntimeCommandResult(kind: .accepted, detail: detail,
                                        page: RunDomainReply.designValue(page.object))
        case .mutationAccepted(let detail):
            return RuntimeCommandResult(kind: .accepted, detail: detail)
        case .rejected(let error):
            return RunDomainReply.terminalResult(for: error)
        }
    }

    /// Exact SettingsDomainV1.JSONValue → canonical DesignJSONValue bridge
    /// (integer stays integer, fractional stays numeric, nothing is
    /// stringified). The canonical carrier then applies its own exact
    /// type/budget rules.
    static func designValue(_ value: SettingsDomainV1.JSONValue) -> DesignJSONValue {
        switch value {
        case .object(let members):
            return .object(members.mapValues(designValue))
        case .array(let items):
            return .array(items.map(designValue))
        case .string(let text):
            return .string(text)
        case .integer(let number):
            return .integer(number)
        case .fractional(let number):
            return .number(number)
        case .boolean(let flag):
            return .bool(flag)
        case .null:
            return .null
        }
    }

    static func terminalResult(for error: RunDomainError) -> RuntimeCommandResult {
        switch error.code {
        case .notFound: return RuntimeCommandResult(kind: .rejected, code: .runRecordNotFound,
                                                    detail: error.wireObject)
        case .staleRevision, .duplicateInFlight, .invalidState:
            return RuntimeCommandResult(kind: .rejected, code: .ordinaryRuntimeBlocked,
                                        detail: error.wireObject)
        case .persistenceUnavailable: return RuntimeCommandResult(kind: .failed, code: .storeOpenFailed,
                                                                  detail: error.wireObject)
        default: return RuntimeCommandResult(kind: .rejected, code: .ordinaryRuntimeBlocked,
                                             detail: error.wireObject)
        }
    }
}

// MARK: - goal-core controls (2026-10-21 additive queries)

/// Execution recommendation carried by `plan.accept`: the two original
/// buttons ("Execute on the normal plan" / "Convert to goal",
/// ThreadDetailView.swift:346-357). Closed vocabulary; a missing key falls
/// back to the plan row's OWN recommendation exactly like the original
/// (`execution ?? latestPlan.executionRecommendation ?? .normal`).
public enum PlanAcceptExecution: String, Sendable, Equatable, CaseIterable {
    case normal
    case goal
}

/// `plan.accept` — the single wire action that accepts the EXACT plan
/// revision the human saw and launches it (iOS performs accept + startRun as
/// ONE user action; accept+start are never split into two wire ops).
/// `goal`/`mode` keys are FORBIDDEN: the execution prompt is composed
/// host-side from the ACCEPTED durable row (never UI-supplied text, so no
/// prompt injection can ride the wire), and the launch mode derives from the
/// execution choice (normal -> the ordinary chat-engine launch, goal ->
/// goal mode). The conversation-row digest CAS rides the envelope exactly
/// like `run.start`.
public struct PlanAcceptQuery: Sendable, Equatable {
    public var conversationID: UUID
    public var planID: UUID
    public var planRevision: Int
    public var planDigest: String
    public var execution: PlanAcceptExecution?
    public var providerID: UUID
    public var modelID: UUID
    public var policy: DraftTaskPolicy

    public static let allowedKeys: Set<String> = [
        "planID", "planRevision", "planDigest", "execution",
        "providerID", "modelID",
        "approvalMode", "recoveryPolicy", "notificationPolicy",
    ]

    public static func parse(payload: SettingsDomainV1.JSONValue?,
                             conversationID: UUID) throws -> PlanAcceptQuery {
        let object = try RunPayloadReader.Object(
            payload ?? .object([:]), allowed: allowedKeys)
        let revision = try object.integer("planRevision", min: 1, max: 1_048_576)
        let digest = try object.string("planDigest", maxBytes: 128)
        let executionRaw = try object.optionalString("execution", maxBytes: 12)
        var execution: PlanAcceptExecution?
        if let executionRaw {
            guard let value = PlanAcceptExecution(rawValue: executionRaw) else {
                throw RunDomainError(.invalidState, .payloadInvalid)
            }
            execution = value
        }
        return PlanAcceptQuery(
            conversationID: conversationID,
            planID: try object.uuid("planID"),
            planRevision: Int(revision),
            planDigest: digest,
            execution: execution,
            providerID: try object.uuid("providerID"),
            modelID: try object.uuid("modelID"),
            policy: DraftTaskPolicy(
                approvalMode: try RunStartQuery.approvalMode(object),
                recoveryPolicy: try RunStartQuery.recoveryPolicy(object),
                notificationPolicy: try RunStartQuery.notificationPolicy(object)))
    }
}

/// `goal.confirm` — the EXPLICIT human completion confirmation for a goal
/// the durable lanes moved to `.verifying`. Identity + revision ONLY: no
/// caller boolean, no approval flag, no review text can ride this payload
/// (the trusted wire command itself is the human-intent proof; models,
/// imported documents and tool output have no route to this writer).
public struct GoalConfirmQuery: Sendable, Equatable {
    public var conversationID: UUID
    public var goalID: UUID
    public var expectedGoalRevision: Int

    public static let allowedKeys: Set<String> = ["goalID", "expectedGoalRevision"]

    public static func parse(payload: SettingsDomainV1.JSONValue?,
                             conversationID: UUID) throws -> GoalConfirmQuery {
        let object = try RunPayloadReader.Object(
            payload ?? .object([:]), allowed: allowedKeys)
        return GoalConfirmQuery(
            conversationID: conversationID,
            goalID: try object.uuid("goalID"),
            expectedGoalRevision: Int(try object.integer("expectedGoalRevision",
                                                          min: 1, max: 1_048_576)))
    }
}

/// `conversation.compact` — the manual context compaction trigger
/// (original `/`-palette item). The ONLY payload key is an OPTIONAL model
/// identity; the CORE resolves provider + model through the trusted
/// model-config projection (default-agent preferences + providers store),
/// validates a caller-supplied modelID against the REAL catalog and never
/// assumes it. No localized strings cross the bridge.
public struct ConversationCompactQuery: Sendable, Equatable {
    public var conversationID: UUID
    public var preferredModelID: UUID?

    public static let allowedKeys: Set<String> = ["modelID"]

    public static func parse(payload: SettingsDomainV1.JSONValue?,
                             conversationID: UUID) throws -> ConversationCompactQuery {
        let object = try RunPayloadReader.Object(
            payload ?? .object([:]), allowed: allowedKeys)
        return ConversationCompactQuery(
            conversationID: conversationID,
            preferredModelID: try object.optionalUUID("modelID"))
    }
}

// MARK: - Handler binding plan (documentation for the future binder)

/// The EXACT v3 handler keys this domain is designed to serve, computed with
/// the LIVE frozen helper `BridgeV3.handlerKey(scope:command:)` — the 15
/// command.submit keys of the frozen matrix (event.poll stays bound by RB1's
/// `FacadeEventPump` handler; this package feeds it real durable windows and
/// live consumers through per-run track tasks and MUST NOT re-register or
/// replace the pump key). This plan registers NOTHING by itself.
/// goal-core code batch (2026-10-21): THREE additive bindings
/// (`plan.accept` under launch, `goal.confirm` + `conversation.compact`
/// under conversationLifecycle — the matrices gained exactly those three
/// tuples; no existing binding changed).
public enum RunDomainHandlerPlan {
    public struct Binding: Sendable, Equatable {
        public let handlerKey: String
        public let command: String
        public let scope: BridgeV3.Scope
        public let configurationScope: String?
        public let serviceMethod: String
        public let integrationNote: String
    }

    public static var bindings: [Binding] {
        [
            Binding(handlerKey: BridgeV3.handlerKey(scope: .launch, command: "run.start"),
                    command: "run.start", scope: .launch, configurationScope: nil,
                    serviceMethod: "FacadeRunDomain.start",
                    integrationNote: "existing-conversation taskID + floe.conversation-row.v1 revision CAS BEFORE effects; receipt carries no ids; prepared{conversationID,runID,runResource,runVersion} + started{runID} effects ONLY after SQLiteRunLaunchStore.prepare commits"),
            Binding(handlerKey: BridgeV3.handlerKey(scope: .launch, command: "run.startTask"),
                    command: "run.startTask", scope: .launch, configurationScope: nil,
                    serviceMethod: "FacadeRunDomain.startTask",
                    integrationNote: "explicit createIntent, no owner/revision; conversation+workspace+run+userMessage committed in the SAME original prepare transaction; minted IDs surface only in async prepared/started"),
            Binding(handlerKey: BridgeV3.handlerKey(scope: .taskExecution, command: "run.cancel"),
                    command: "run.cancel", scope: .taskExecution, configurationScope: nil,
                    serviceMethod: "FacadeRunDomain.cancel",
                    integrationNote: "revision run.<runID>/state CAS; cancels the facade-OWNED producer (service + track + children via runtime cancel cascade), never merely the UI poller; C0/C1 pre/post-prepare windows truthful"),
            Binding(handlerKey: BridgeV3.handlerKey(scope: .taskExecution, command: "run.retry"),
                    command: "run.retry", scope: .taskExecution, configurationScope: nil,
                    serviceMethod: "FacadeRunDomain.retry",
                    integrationNote: "duplicateInFlight guard; awaiting-dependency refuses Continue; checkpoint identity check (runID+conversationID) then bounded durable-history fallback like native resumeExistingRun; never a fake start id"),
            Binding(handlerKey: BridgeV3.handlerKey(scope: .taskExecution, command: "run.steer"),
                    command: "run.steer", scope: .taskExecution, configurationScope: nil,
                    serviceMethod: "FacadeRunDomain.steer",
                    integrationNote: "targets a durable queued row via beginSteerPromotion CAS + ConversationRunService.steer(expectedRunID:); RuntimeSteerAcceptance surfaced truthfully; consumedRunID is the durable exactly-once receipt owned by the service"),
            Binding(handlerKey: BridgeV3.handlerKey(scope: .taskExecution, command: "run.queue"),
                    command: "run.queue", scope: .taskExecution, configurationScope: nil,
                    serviceMethod: "FacadeRunDomain.queue",
                    integrationNote: "SQLiteRunningInputStore.enqueue original bounds; queue accepted is NOT approval resolved, secret committed or run started"),
            Binding(handlerKey: BridgeV3.handlerKey(scope: .taskExecution, command: "run.input.edit"),
                    command: "run.input.edit", scope: .taskExecution, configurationScope: nil,
                    serviceMethod: "FacadeRunDomain.inputEdit",
                    integrationNote: "withdrawSteer guard FIRST for steerPending rows (native withdrawPendingGuidance ordering); consumed race fails honestly; updateContent only for queued"),
            Binding(handlerKey: BridgeV3.handlerKey(scope: .taskExecution, command: "run.input.remove"),
                    command: "run.input.remove", scope: .taskExecution, configurationScope: nil,
                    serviceMethod: "FacadeRunDomain.inputRemove",
                    integrationNote: "same withdraw guard; store.cancel proves queued-only removal"),
            Binding(handlerKey: BridgeV3.handlerKey(scope: .taskExecution, command: "run.input.reorder"),
                    command: "run.input.reorder", scope: .taskExecution, configurationScope: nil,
                    serviceMethod: "FacadeRunDomain.inputReorder",
                    integrationNote: "exact ordered-set CAS through queueVersion then original reorder ('Queue changed while it was being reordered' refusal preserved)"),
            Binding(handlerKey: BridgeV3.handlerKey(scope: .taskExecution, command: "run.approval.resolve"),
                    command: "run.approval.resolve", scope: .taskExecution, configurationScope: nil,
                    serviceMethod: "FacadeRunDomain.resolveApproval",
                    integrationNote: "revision approval.<callID>/requestedAt; only a matching LIVE request resolves; scope re-derived from the bound ToolCall (call-bound + toolAuthorizationIdentity), card retires only on durable approvalResolved"),
            Binding(handlerKey: BridgeV3.handlerKey(scope: .taskExecution, command: "run.policy.update"),
                    command: "run.policy.update", scope: .taskExecution, configurationScope: nil,
                    serviceMethod: "FacadeRunDomain.policyUpdate",
                    integrationNote: "host-authored only; saveTaskPolicy + service.updateApprovalPolicy through the original DynamicApprovalPolicy; live approval re-evaluation is the runtime's job"),
            Binding(handlerKey: BridgeV3.handlerKey(scope: .taskExecution, command: "run.skillcancel"),
                    command: "run.skillcancel", scope: .taskExecution, configurationScope: nil,
                    serviceMethod: "FacadeRunDomain.skillCancel",
                    integrationNote: "delegates to the RB6-owned RunOwnedToolCancellation port bound to this generation; unregistered => capabilityNotUsable refusal; NEVER an invented Linux job id"),
            Binding(handlerKey: BridgeV3.handlerKey(scope: .taskExecution, command: "run.snapshot"),
                    command: "run.snapshot", scope: .taskExecution, configurationScope: nil,
                    serviceMethod: "FacadeRunDomain.snapshot",
                    integrationNote: "stateful=false pure read: real durable state/answer/reasoning/tools/plan/goal/child/pendingInput/usage/liveness/providerAttempt/review + honest partial/continuation handles within 48KiB"),
            Binding(handlerKey: BridgeV3.handlerKey(scope: .taskExecution, command: "child.list"),
                    command: "child.list", scope: .taskExecution, configurationScope: nil,
                    serviceMethod: "FacadeRunDomain.childList",
                    integrationNote: "SQLiteChildRunStore.children(parentRunID:) — the durable graph; no UI-emulated children"),
            Binding(handlerKey: BridgeV3.handlerKey(scope: .taskExecution, command: "child.entries"),
                    command: "child.entries", scope: .taskExecution, configurationScope: nil,
                    serviceMethod: "FacadeRunDomain.childEntries",
                    integrationNote: "SQLiteChildRunStore.entries -> ChildRunEntryPage{entries,nextSequence} with stop-at-budget"),
            // goal-core code batch (2026-10-21): the three additive controls.
            Binding(handlerKey: BridgeV3.handlerKey(scope: .launch, command: "plan.accept"),
                    command: "plan.accept", scope: .launch, configurationScope: nil,
                    serviceMethod: "FacadeRunDomain.planAccept",
                    integrationNote: "existing-conversation taskID + floe.conversation-row.v1 digest CAS; proves the EXACT plan revision the human saw, commits accepted plan (+ optional GoalFromPlanFactory goal) with run/message/launch in the SAME C1 writer transaction before any network, then falls through the REAL run.start pipeline (normal->chat-engine launch, goal->goal mode); host-composed canonical prompt; reply {runID,acceptedPlanRevision,goalID?}"),
            Binding(handlerKey: BridgeV3.handlerKey(scope: .conversationLifecycle, command: "goal.confirm"),
                    command: "goal.confirm", scope: .conversationLifecycle, configurationScope: nil,
                    serviceMethod: "FacadeRunDomain.goalConfirm",
                    integrationNote: "identity+revision-only payload; ORIGINAL GoalCompletionGate over the durable verifying goal with the userConfirmation evidence transform; NO live run/launch may hold the conversation; saveGoalIfRevisionMatches CAS (late/parallel writers lose honestly); blockers refuse with bounded codes and persist NO confirmation evidence on refusal"),
            Binding(handlerKey: BridgeV3.handlerKey(scope: .conversationLifecycle, command: "conversation.compact"),
                    command: "conversation.compact", scope: .conversationLifecycle, configurationScope: nil,
                    serviceMethod: "FacadeRunDomain.conversationCompact",
                    integrationNote: "original ConversationCenter.requestManualCompaction guard chain verbatim: one-per-conversation reservation SHARED with every real run launch admission; original engine/assembler/settings/model resolution; real cancel/drain; final history + live-launch proof and the summary INSERT commit atomically in the ONE original DB writer (compactionHistoryChanged/refusal windows closed); truthful shortHistory/noHistory no-ops; reply {compacted,reason,beforeTokens,afterTokens,recordID?}"),
        ]
    }

    /// The 16th matrix command: `event.poll` under taskExecution with the
    /// run-bound cursor. RB1 owns the binder key
    /// (`BridgeV3.runEventPumpHandlerKey`, already installed and NOT to be
    /// re-registered here); RB4 owns the PRODUCERS: per-run track tasks that
    /// attach one live consumer, refresh the bounded durable window through
    /// the ORIGINAL `SQLiteRunStore.events(runID:afterSequence:limit:)` and
    /// detach exactly at retirement. The cursor's numeric value always
    /// corresponds to the real native per-run event sequence; no global
    /// sequence is fabricated. The pre-run effect channel
    /// (`floe.effect-cursor/3`) remains RB1's `effect.poll` — no event.poll
    /// is ever used for pre-run receipts.
    public static let eventPollIntegrationNote = "producers owned here; binder key owned by RB1"
}
