// SPDX-License-Identifier: MPL-2.0
//
// RB-4 RunDomain — ordinary run lifecycle owner + operation-owned delete
// guard + the v3 binder composition (private source candidate; NOT
// compiled, NOT executed, NOT registered).
//
// REPAIR SUCCESSOR (job-047bee7a3eff4941) of the frozen parent lane
// runtime-runs-approvals-source (job-f6772d4de1584403, pure archive
// 6c36124e7860433430c8fc898b19cbc69f6e57a02544c0524e04eda691b1b443,
// 11 files/60 authored tests — parent bytes stay immutable under
// Local/Private/android-g02-20261018/runtime-runs-approvals-source).
// Main review MAIN_SOURCE_REVIEW_20261019.json found four finite defects,
// repaired HERE in bounded form (no broad audit, no frozen matrix change):
//   RUN-S1 — the parent CALLED makeService with no declaration anywhere,
//     never inserted into liveServices, never called runAdapter(for:) or
//     tools.registerDelegate(_:for:), and never invoked the bound
//     credential normalizer. The REAL factory now lives in
//     RuntimeFacadeRunAssembly.swift (original ConversationRunService /
//     FloeAgentRuntime construction, original adapter/credentials/policy/
//     gate/executor/context engine, real toolCallNormalizer binding, real
//     SubagentRunner registration), liveServices is populated BEFORE the
//     control-visible handoff (and the unsafe nonisolated exposure is
//     removed: the map is plain actor state), and the missing owned
//     tool/child exact-token accounting (attachTool/detachTool/
//     attachChild/detachChild) is implemented there as well.
//   RUN-S2 — the parent froze bundleOverride but prepared through
//     durable.launches and read history/existence/markings through the
//     ordinary singleton. ONE immutable operational bundle now rides
//     RunOwnership from before the first await through the ORIGINAL
//     prepare, history load, service construction, track projection and
//     every cancel/stop/retire/final write; the ordinary wire refuses a
//     temporary identity structurally; the create-intent post-commit remap
//     keeps the exact owned evidence; temporary launches reuse the hosted
//     identity for the ORIGINAL EphemeralRunLaunchStore validation (RB5
//     T1) and touch no durable table or filesystem location.
//   RUN-S3 — the parent awaited the P8 message feed inline before
//     makeService/launchTaskAttach and the terminal feed inline on the
//     producer path. Both feeds are now dispatched as REAL owned
//     maintenance Tasks with the root+per-conversation lease ACQUIRED
//     before the dispatching await returns (RuntimeFacadeRunAssembly.swift);
//     the delete drain and root retirement wait the exact tokens; live
//     bookkeeping is bounded and pruned at the trusted terminal.
//   RUN-S4 — the parent consumed RunStagedAttachmentAuthority.resolve only
//     and refused every image. The launch path now reserves an exact owned
//     lease per staged handle (typed double-launch refusal), commits the
//     acknowledgement exactly once AFTER the ORIGINAL atomic prepare binds
//     the real message/conversation ids, releases the reservation on any
//     pre-commit failure while PRESERVING the staged bytes, and loads
//     ORIGINAL ConversationImagePart values through the trusted bounded
//     image-loader port (honest typed refusal while unbound; temporary
//     denies images before any IO). See RuntimeFacadeRunIngress.swift for
//     the proposed lease/loader seam handed to Main for reconciliation
//     with job-0f62537568df4d87's final staging authority API.
//
// This is the REAL engine adapter, not a port sketch: every command binds
// the ORIGINAL `ConversationRunService` / `FloeAgentRuntime` /
// `SQLiteRunLaunchStore.prepare` / `SQLiteRunningInputStore` /
// `SQLiteRunStore` durable pages / `SQLiteChildRunStore` /
// `FileCheckpointStore` / `SQLiteWorkspaceStore` task-policy objects. No
// Kotlin agent loop, no new business DB, no manually synthesized
// answerDelta/toolRequest, no fake streamed engine, no invented IDs.
// ConversationCenter is an ORDERING reference only (startRun :3657-3825,
// deferred pipeline :4986-5242/:5351-5461, submitRunningInput :4548-4582,
// promoteToSteer, retry/resume :6196-6295, approval resolve :6510-6545,
// policy update :5995/:7203-7217, track :7296-7366, launchFence
// :1101/:3704/:3726, delete fence :1976/:5926/:5942/:6070,
// stopRunsAndDelete :6106-6176, waitForLaunches :7498-7516 — its 15-second
// timer is NOT mirrored: destructive deletes require REAL quiescence per
// the RB3 admission and Main's CH-R2 correction).
//
// Ownership model (Main RB1/RB3/RB4 rulings):
// * A run is owned by the trusted root/epoch + conversation/run, NEVER by
//   an Activity/Compose/destination lifetime. Ordinary navigation, archive
//   and background do NOT cancel a run; only explicit run.cancel,
//   conversation delete (through `RunDomainDeletionLifecycle`) or real
//   generation retirement close owned producers.
// * Real `Task` wrappers own the work: one launch Task (blocking
//   `startPrepared`/`resumePrepared`) plus one per-run track Task
//   (`events()` subscription + bounded durable-window refresh + live-pump
//   ingest) — implemented in RuntimeFacadeRunEvents.swift. Cancellation
//   closes the ACTUAL producer through the runtime cancel cascade
//   (children/tools included), never merely a UI poller.
// * `RuntimeOwnedWorkRegistry` is the real drain gate. `.run`
//   (ownerID=runID) attaches BEFORE the first await of actual work;
//   `.tool` (ownerID=provider callID) attaches at the runtime's
//   toolLifecycle .requested and detaches at .finished; `.childRun`
//   (ownerID=childRunID) attaches when the graph first shows the child
//   non-terminal and detaches at its terminal. Detach happens ONLY at real
//   completion / final writes — never on caller cancellation, UI teardown
//   or a timeout. A registry refusal (saturation/epoch fence) is handled
//   CONSERVATIVELY (launch refused pre-effect; mid-run tool saturation
//   raises a degraded block that keeps a later delete from under-counting).
//   The `.conversation` kind belongs to the vault/RB3 composition, not to
//   the drain itself (the delete job already occupies a real mailbox slot;
//   root retirement keeps the GLOBAL counts gate — reviewed RB1).
// * Deletion quiescence implements Main CH-R2/CH-R3 exactly: REAL
//   per-conversation owned-token mapping with exact-token
//   `RuntimeOwnedWorkRegistry.isAttached(_:)` proof and an explicit
//   conversationID+epoch report; unrelated conversation B's live work never
//   blocks deletion A and is never cancelled by it; the deleting guard is
//   operation-owned (fence issue/validate + finish/abort/commit release at
//   every exit); an old abort cannot clear a newer guard; after an abort
//   the surviving conversation becomes launchable again once the aborted
//   operation's real work settled.
// * C0/C1 cancellation windows are truthful:
//     C0 (before the atomic prepare commits): provable no-effect — no
//        durable row; typed refusal; nothing detached early;
//     C1 (after the commit, before/after service handoff): the
//        conversation/run/user-message rows ARE durable; the failed launch
//        stage is marked through the ORIGINAL runStore state CAS plus
//        durable status/terminal events, remains observable through
//        snapshot/event.poll, and owned tokens detach only after those
//        final writes. A lost process boundary is never claimed
//        failed/no-effect; the durable rows are reconciled via run.retry.
// * Native process death: the reviewed RB1 bootstrap recovery already
//   marks durable interrupted runs/children/transient inputs through the
//   ORIGINAL store APIs. This package resurrects NO old Task: after
//   restart the ownership maps are empty, the durable thread tells the
//   truth, and run.retry reopens the ORIGINAL run through the checkpoint
//   identity check + bounded durable-history fallback.
//
// Temporary seam (RB5 job-21ee86c6798b4e20): `start(query:…bundleOverride:)`
// accepts an EXPLICIT immutable `RunPersistenceBundle` (the ORIGINAL
// Ephemeral* stores) plus the frozen temporary identity BEFORE the first
// await; RB5's temp.start pipeline composes this same actor through its
// lifecycle ports. The WIRE handlers for run.start/run.startTask carry the
// durable ordinary bundle only: a temporary presentation through the
// ordinary wire surface is structurally impossible, and goal mode without
// an intelligence store, vault normalizer rules per the ORIGINAL
// temporary policy (nil normalizer ONLY for temporary — ordinary never
// launches without the bound vault-backed normalizer), and the
// intelligence feed hooks NEVER fire from a temporary bundle.
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloePersistence
import FloeAgentRuntime
import FloeSecurity

// MARK: - Conversation revision port (RB3-owned digest authority)

/// Host-bound full-row revision reader. The trusted host glue binds this to
/// `ConversationRowRevision.digest(db:conversationID:)` (floe.conversation-
/// row.v1, Main settled) over the ONE owner `DatabaseManager` — the same
/// injection point through which the RB3 domain already receives
/// `database:` (Main integration/API reconciliation note). This package
/// never re-implements the canonical digest and never reads a second DB.
public protocol RunConversationRevisionReading: Sendable {
    /// The opaque full-row digest, or nil when the row is absent.
    func digest(conversationID: UUID) async throws -> String?
    /// True when the row exists AND is an ordinary (non-Notes,
    /// non-temporary-persistent — purpose 'ordinary') conversation. Purpose
    /// violations answer exactly like absence (RB3 indistinguishability).
    func ordinaryExists(conversationID: UUID) async throws -> Bool
}

// MARK: - Components

/// Everything one generation's run domain composes: the trusted ingress
/// context, the ORIGINAL durable store bundle, the original checkpoint
/// store, the reviewed RB1 pumps, and the honest dependency ports. An
/// unregistered port is never a silent noop — the typed admission rules
/// refuse the affected command family before any effect.
public struct RunDomainComponents: Sendable {
    public var context: RunIngressContext
    public var durable: RunPersistenceBundle
    public var checkpoints: any CheckpointStore
    public var modelStore: ModelConfigurationStore
    public var workspaceStore: SQLiteWorkspaceStore
    /// Effects channel (reviewed `FacadeEffectPump`, per generation).
    /// prepared/started are the NON-terminal live stages appended BEFORE
    /// the command's single terminal; terminal results ride the SAME
    /// `effect.poll` route (no parallel receipt store).
    public var effects: FacadeEffectPump
    /// Reviewed `FacadeEventPump`. The `event.poll` binder key stays owned
    /// by RB1; this package feeds its durable windows and live consumers.
    public var events: FacadeEventPump
    /// Reviewed `FacadeContentReader`, per generation, for oversized
    /// snapshot text continuation handles.
    public var content: FacadeContentReader
    public var conversationRevisions: any RunConversationRevisionReading
    /// Ordinary vault-backed credential-argument normalizer. Composition
    /// target: vault-07 `AndroidCredentialVault.joinRuntimeOwnership(
    /// database:identity:ownedWork:gateway:now:)` + the overlay mirror
    /// `CredentialArgumentNormalizer` (constructor names consumed for
    /// compatible handoff; the MAIN-QUALIFIED body wins — this source stage
    /// never marks the real normalizer ready). Unbound => ordinary launches
    /// refuse with needsConfiguration{normalizerUnbound} BEFORE effects.
    public var credentialNormalizer: (any RunCredentialArgumentNormalizing)?
    /// Attachment lane (job-0f62537568df4d87): exact owned staged-lease
    /// resolution consumed ONLY through the original atomic prepare (the
    /// sole atomic attachment insertion/normalization with real
    /// message/conversation ids stays inside
    /// `SQLiteRunLaunchStore.prepare`). Unbound => any staged handle in a
    /// launch payload is refused pre-prepare; unknown lease typed; never
    /// auto-send, never binary JSON, never a fabricated AttachmentRef.
    public var stagedAttachments: (any RunStagedAttachmentAuthority)?
    /// RUN-S4 repair: trusted bounded image loader (the attachment lane
    /// owns the staged bytes and the app-private IO). Unbound => image
    /// handles are refused BEFORE any staged IO; bound => ORIGINAL
    /// ConversationImagePart values are loaded from validated bounded
    /// staged data for the selected model's effective vision route.
    public var stagedImages: (any RunStagedImageLoading)?
    /// RB6 skill/MCP registry binding for `run.skillcancel`.
    public var toolCancellation: (any RunOwnedToolCancellation)?
    /// Trusted ownership proof for OPTIONAL environment/job roles.
    public var environmentProof: (any RunEnvironmentOwnershipProving)?
    /// RB3b personalization/memory processor (P8 hooks, exact-once at the
    /// real sites below).
    public var intelligenceFeed: (any RunIntelligencePostCommitFeeding)?
    /// Optional ORIGINAL live-personalization seam (P8). nil keeps the
    /// service's own no-personalization semantics (a constructor default,
    /// not a fabricated ready state).
    public var personalizationProvider:
        (@Sendable () async throws -> LivePersonalizationSnapshot)?
    /// Test/qualification seam: the ORIGINAL `ProviderAdapterFactory` is the
    /// production adapter source; a host may inject a controlled stream
    /// factory for behavior tests (NEVER a production fallback path).
    public var adapterFactoryOverride:
        (@Sendable (ProviderProfile) -> any ProviderAdapter)?
    /// Run-scoped tool registry. `.shared` in production; isolated
    /// instances in tests so registrations never leak across cases.
    public var registry: ToolRunnerRegistry

    public init(context: RunIngressContext,
                durable: RunPersistenceBundle,
                checkpoints: any CheckpointStore,
                modelStore: ModelConfigurationStore,
                workspaceStore: SQLiteWorkspaceStore,
                effects: FacadeEffectPump,
                events: FacadeEventPump,
                content: FacadeContentReader,
                conversationRevisions: any RunConversationRevisionReading,
                credentialNormalizer: (any RunCredentialArgumentNormalizing)?,
                stagedAttachments: (any RunStagedAttachmentAuthority)?,
                stagedImages: (any RunStagedImageLoading)? = nil,
                toolCancellation: (any RunOwnedToolCancellation)?,
                environmentProof: (any RunEnvironmentOwnershipProving)?,
                intelligenceFeed: (any RunIntelligencePostCommitFeeding)?,
                personalizationProvider:
                    (@Sendable () async throws -> LivePersonalizationSnapshot)?,
                adapterFactoryOverride:
                    (@Sendable (ProviderProfile) -> any ProviderAdapter)? = nil,
                registry: ToolRunnerRegistry = .shared) {
        self.context = context
        self.durable = durable
        self.checkpoints = checkpoints
        self.modelStore = modelStore
        self.workspaceStore = workspaceStore
        self.effects = effects
        self.events = events
        self.content = content
        self.conversationRevisions = conversationRevisions
        self.credentialNormalizer = credentialNormalizer
        self.stagedAttachments = stagedAttachments
        self.stagedImages = stagedImages
        self.toolCancellation = toolCancellation
        self.environmentProof = environmentProof
        self.intelligenceFeed = intelligenceFeed
        self.personalizationProvider = personalizationProvider
        self.adapterFactoryOverride = adapterFactoryOverride
        self.registry = registry
    }
}

// MARK: - Ownership records

public enum RunLaunchPhase: String, Sendable, Equatable {
    case admitting        // ingress/fence stage; no durable row yet (C0)
    case prepared         // original prepare committed (C1 begins)
    case handedOff        // service + launch/track Tasks live; producer running
    case terminating      // real close requested; awaiting actual settlement
    case retired          // final writes done; every exact token detached
}

/// One facade-owned run projection. Mutable ONLY through the domain actor;
/// the Task/actor references live in the parallel `liveServices` map so the
/// struct itself stays value-typed.
public struct RunOwnership: Sendable, Equatable {
    public var conversationID: UUID
    public var runID: UUID
    public var epoch: UInt64
    public var identity: RunExecutionIdentity
    public var phase: RunLaunchPhase
    /// The IMMUTABLE operational bundle this run executes against (store
    /// protocols + identity), frozen BEFORE the first await and carried
    /// through every stage — the ordinary singleton is never a fallback
    /// for a supplied temporary bundle (RUN-S2 repair).
    public var bundle: RunPersistenceBundle
    /// The scoped launch fence token frozen before the first await. A
    /// failed stage after invalidation must stay observable and NEVER
    /// resurrect the old route.
    public var launchToken: LaunchEpochFence.Token
    /// The command receipt whose stream carries this launch's
    /// prepared/started stages (appended BEFORE the command terminal).
    public var commandReceipt: String?
    public var preparedEffectEmitted: Bool
    public var startedEffectEmitted: Bool
    public var cancelRequested: Bool
    /// Owned-work exact tokens, keyed by kind raw value (+ ":" + provider
    /// call identity for tool/child entries).
    public var ownedTokens: [String: RuntimeOwnedWorkToken]
    /// Children observed non-terminal; pending their durable terminal.
    public var pendingChildRunIDs: Set<UUID>
    /// The live projection consumer attached for this run (RB1 pump token).
    public var consumerToken: RuntimeLiveConsumerToken?
    /// Tool/child attach saturation: conservative delete/drain blocking
    /// until the run REALLY retires (never an under-counted quiescence).
    public var degradedToolAccounting: Bool
    public var intelligenceUserMessageFed: Bool
    public var intelligenceTerminalFed: Bool
    /// The EXACT admitted environment identity for this launch (nil when the
    /// host requested none). Kept immutable through handoff/cancel/retire and
    /// forwarded to the ORIGINAL runtime Configuration — an accepted proof is
    /// never silently dropped to nil/default.
    public var environmentID: String?
    /// The EXACT admitted job identity (nil when not requested).
    public var jobID: String?

    public init(conversationID: UUID, runID: UUID, epoch: UInt64,
                identity: RunExecutionIdentity,
                launchToken: LaunchEpochFence.Token,
                bundle: RunPersistenceBundle) {
        self.conversationID = conversationID
        self.runID = runID
        self.epoch = epoch
        self.identity = identity
        self.phase = .admitting
        self.launchToken = launchToken
        self.commandReceipt = nil
        self.preparedEffectEmitted = false
        self.startedEffectEmitted = false
        self.cancelRequested = false
        self.ownedTokens = [:]
        self.pendingChildRunIDs = []
        self.consumerToken = nil
        self.degradedToolAccounting = false
        self.intelligenceUserMessageFed = false
        self.intelligenceTerminalFed = false
        self.environmentID = nil
        self.jobID = nil
        self.bundle = bundle
    }

    /// Value equality covers the owned projection only; the operational
    /// bundle is implied by (runID, epoch) identity — the stores are
    /// reference-typed protocols and are never compared.
    public static func == (lhs: RunOwnership, rhs: RunOwnership) -> Bool {
        lhs.conversationID == rhs.conversationID
            && lhs.runID == rhs.runID
            && lhs.epoch == rhs.epoch
            && lhs.identity == rhs.identity
            && lhs.phase == rhs.phase
            && lhs.launchToken == rhs.launchToken
            && lhs.commandReceipt == rhs.commandReceipt
            && lhs.preparedEffectEmitted == rhs.preparedEffectEmitted
            && lhs.startedEffectEmitted == rhs.startedEffectEmitted
            && lhs.cancelRequested == rhs.cancelRequested
            && lhs.ownedTokens == rhs.ownedTokens
            && lhs.pendingChildRunIDs == rhs.pendingChildRunIDs
            && lhs.consumerToken == rhs.consumerToken
            && lhs.degradedToolAccounting == rhs.degradedToolAccounting
            && lhs.intelligenceUserMessageFed == rhs.intelligenceUserMessageFed
            && lhs.intelligenceTerminalFed == rhs.intelligenceTerminalFed
            && lhs.environmentID == rhs.environmentID
            && lhs.jobID == rhs.jobID
    }
}

/// Operation-owned global admission-fence identity (privacy-clear port).
public struct GlobalAdmissionFenceToken: Sendable, Equatable {
    public var epoch: UInt64
    public var generation: UInt64
    public init(epoch: UInt64, generation: UInt64) {
        self.epoch = epoch
        self.generation = generation
    }
}

/// Operation-owned deleting-guard registration (RB3-repair CH-R3 exact
/// API). The authorityReceipt is a REAL reviewed RB1 owned-work receipt
/// (`work:v1:` …) minted at begin and detached only at settlement; the
/// deletion drain never waits on or reports its own fence receipt (no
/// self-count deadlock).
struct DeleteGuardState: Sendable {
    let fence: ConversationDeletionFence
    let generation: UInt64
    let authorityToken: RuntimeOwnedWorkToken
}

// MARK: - Parsed envelope

/// The re-read of an ALREADY-validated v3 envelope inside an async
/// processor. BridgeV3 owns structural validation; this only extracts the
/// stable identity fields, never re-parsing authority.
public struct RunCommandEnvelope: Sendable {
    public var taskID: UUID?
    public var runID: UUID?
    public var environmentID: UUID?
    public var jobID: UUID?
    public var revision: (resourceID: String, version: String)?
    public var grantID: String?
    public var payloadValue: SettingsDomainV1.JSONValue?

    public init(object: [String: Any]) {
        if let owner = object["owner"] as? [String: Any] {
            taskID = (owner["taskID"] as? String).flatMap(UUID.init(uuidString:))
            runID = (owner["runID"] as? String).flatMap(UUID.init(uuidString:))
            environmentID = (owner["environmentID"] as? String).flatMap(UUID.init(uuidString:))
            jobID = (owner["jobID"] as? String).flatMap(UUID.init(uuidString:))
        }
        if let revisionObject = object["revision"] as? [String: Any],
           let resourceID = revisionObject["resourceID"] as? String,
           let version = revisionObject["version"] as? String {
            revision = (resourceID, version)
        }
        grantID = object["grantID"] as? String
        if let payload = object["payload"],
           JSONSerialization.isValidJSONObject(payload),
           let data = try? JSONSerialization.data(withJSONObject: payload) {
            payloadValue = SettingsDomainV1.JSONValue.decode(data)
        }
    }

    public enum ExtractionError: Error { case shape }

    public func requireTask() throws -> UUID {
        guard let taskID else { throw RunDomainError(.invalidState, .payloadInvalid) }
        return taskID
    }

    public func requireTaskAndRun() throws -> OwnerIdentity {
        guard let taskID, let runID else {
            throw RunDomainError(.invalidState, .payloadInvalid)
        }
        return OwnerIdentity(taskID: taskID, runID: runID,
                             environmentID: environmentID, jobID: jobID)
    }

    /// Revision CAS against the CURRENTLY computed opaque version. The
    /// envelope grammar already proved both members non-blank.
    public func revisionMatches(resourceID expectedResource: String,
                                version expectedVersion: String) throws {
        guard let revision else {
            throw RunDomainError(.staleRevision, .revisionAbsent)
        }
        guard revision.resourceID == expectedResource,
              revision.version == expectedVersion else {
            throw RunDomainError(.staleRevision, .revisionMismatch)
        }
    }
}

// MARK: - The run domain actor

/// One instance per accepted generation epoch (NOT MainActor, NOT an
/// Android Looper). Synchronous JNI threads never call it directly; the
/// reviewed mailbox dispatches processor Tasks onto the cooperative pool.
public actor FacadeRunDomain {
    /// States that may legally be cancelled/retried (the ORIGINAL durable
    /// AgentState.name vocabulary).
    public static let activeRunStates: Set<String> = [
        "preparing", "streamingModel", "waitingApproval", "executingTool",
        "compacting", "paused", "interrupted", "verifying", "cancelling",
    ]
    static let terminalRunStates: Set<String> = [
        "completed", "failed", "checkpointed", "idle",
    ]

    // Short-lived ordinary wire admission, not a service-lifetime lock.
    // A second start is allowed once the first start returns, even while
    // its service is still live (the original parallel-run contract).
    private var ordinaryWireAdmissions: Set<UUID> = []

    public let epoch: UInt64
    internal let components: RunDomainComponents
    internal let ingress: RunCredentialResolver
    internal let assembly: RunModelAssembly
    internal let tools: RunToolAssembly

    internal var owners: [UUID: RunOwnership] = [:]
    internal var conversationRuns: [UUID: Set<UUID>] = [:]
    internal var deleteGuards: [UUID: DeleteGuardState] = [:]
    internal var guardCounter: UInt64 = 0
    internal var globalFence: GlobalAdmissionFenceToken?
    internal var globalFenceCounter: UInt64 = 0
    /// True after `beginGenerationRetirement`: new admissions refuse,
    /// already-owned producers settle through the real drain.
    internal var retirementFenced = false
    /// The scoped launch fence — RB4-owned runtime state reached by the
    /// conversation lane ONLY through `RunDomainDeletionLifecycle`.
    internal var launchFence = LaunchEpochFence()
    /// The LIVE original service per facade-owned run, populated BEFORE the
    /// control-visible handoff and cleared at retirement. Plain actor
    /// state: every access runs on the domain actor (the unsafe
    /// nonisolated exposure of the parent is removed — RUN-S1 repair).
    internal var liveServices: [UUID: ConversationRunService] = [:]
    /// Snapshot continuation handles owned by (run, conversation, epoch).
    internal var contentHandles: [String: (runID: UUID, conversationID: UUID,
                                           epoch: UInt64)] = [:]
    internal var contentHandleOrder: [String] = []
    internal var lastObservedState: [UUID: String] = [:]
    /// P8 feed operation leases: per-conversation exact tokens held until
    /// the REAL handler returns (Main P8 correction). Kind is the registry's
    /// `.conversation`; the per-conversation delete drain includes these.
    internal var feedLeases: [UUID: [String: RuntimeOwnedWorkToken]] = [:]
    internal var feedTerminalsDone: Set<UUID> = []
    /// Run ids THIS domain retired in the current generation (bounded
    /// bookkeeping so a late cancel for a just-retired run answers
    /// `alreadyRequested` instead of a misleading `runMissing`).
    internal var retiredRuns: [UUID] = []
    internal var retiredRunSet: Set<UUID> = []
    /// Bounded per-conversation evidence windows drained by delete guards
    /// and the root drain (RUN-S3 repair; pruned by `pruneFeedBookkeeping`).
    internal var feedEvidence: [UUID: [RuntimeOwnedWorkToken]] = [:]
    internal var drainEvidence: [UUID: [RuntimeOwnedWorkToken]] = [:]
    internal var feedStats = (delivered: 0, fenceSkipped: 0, saturatedSkipped: 0)
    /// In-flight owned feed maintenance Tasks keyed by run (RUN-S3 repair):
    /// handles are dropped by the completion hook; the delete drain and
    /// root shutdown wait the exact LEASE tokens in `feedLeases`, never a
    /// timer, and a caller cancel never detaches them.
    internal var feedMaintenanceTasks: [UUID: [UUID: Task<Void, Never>]] = [:]

    public init(components: RunDomainComponents) {
        self.epoch = components.context.epoch
        self.components = components
        self.ingress = RunCredentialResolver()
        self.assembly = RunModelAssembly(configurationStore: components.modelStore,
                                         credentials: ingress)
        self.tools = RunToolAssembly(registry: components.registry,
                                     runners: SubagentRunnerRegistry())
    }

    func runAdapter(for provider: ProviderProfile) -> any ProviderAdapter {
        components.adapterFactoryOverride?(provider)
            ?? ProviderAdapterFactory().adapter(for: provider)
    }

    internal var durable: RunPersistenceBundle { components.durable }

    // MARK: Guard/fence helpers

    private func requireNoGuard(conversationID: UUID) throws {
        if retirementFenced {
            throw RunDomainError(.sessionFenced, .generationRetired)
        }
        if globalFence != nil {
            throw RunDomainError(.sessionFenced, .deletingGuarded)
        }
        if deleteGuards[conversationID] != nil {
            throw RunDomainError(.sessionFenced, .deletingGuarded)
        }
    }

    /// CH-R3 (successor API): registering a guard bumps a per-conversation
    /// guard generation and invalidates the conversation's launch scope, so
    /// NEW launches are refused and every in-flight launch re-checks its
    /// token at its own boundaries (native :3726/:5010/:5045 parity).
    /// BEGIN IS ATOMIC: either the exact operation guard registers (with a
    /// REAL RB1 authority receipt) or nothing happens — a rejection never
    /// leaves a half-registered guard.
    func beginDeleteGuard(conversationID: UUID, epoch expectedEpoch: UInt64,
                          operationID: UUID) async throws
        -> ConversationDeletionFence {
        guard expectedEpoch == epoch else {
            throw ConversationDeletionLifecycleFailure.epochMismatch
        }
        guard deleteGuards[conversationID] == nil else {
            throw ConversationDeletionLifecycleFailure.fenceHeld
        }
        let ownerID = conversationID.uuidString + ":delete:" + operationID.uuidString
        guard case .attached(let authorityToken) = RuntimeOwnedWorkRegistry.shared.attach(
            epoch: epoch, kind: .conversation, ownerID: ownerID) else {
            throw ConversationDeletionLifecycleFailure.ownerUnavailable("admissionFenced")
        }
        let fence = ConversationDeletionFence(conversationID: conversationID,
                                              epoch: epoch,
                                              operationID: operationID,
                                              authorityReceipt: authorityToken.receipt)
        guardCounter &+= 1
        deleteGuards[conversationID] = DeleteGuardState(
            fence: fence, generation: guardCounter, authorityToken: authorityToken)
        launchFence.invalidate(scope: conversationID)
        return fence
    }

    /// Settlement shared by abort/commit. ONLY the exact current fence's
    /// guard clears; old or foreign tokens answer `.alreadySettled` /
    /// `.refusedForeignToken` and can NEVER clear a newer guard. The fence
    /// authority token itself detaches at settlement (the operation is
    /// over); target owned-work tokens detach only at REAL completion —
    /// settlement here never releases outstanding I/O.
    private func settleFence(_ fence: ConversationDeletionFence,
                             committed: Bool) -> ConversationDeletionFenceSettlement {
        guard let state = deleteGuards[fence.conversationID] else {
            if retirementFenced {
                // The owning generation retired (shutdown/restart): the
                // authority is unavailable in THIS process. Durable queues
                // remain recoverable; never pretend a settlement.
                return .unavailable("generationRetired")
            }
            return .alreadySettled
        }
        guard state.fence == fence else {
            return .refusedForeignToken
        }
        deleteGuards[fence.conversationID] = nil
        RuntimeOwnedWorkRegistry.shared.detach(state.authorityToken)
        if committed {
            // Post-DB-commit cleanup for the removed conversation: any
            // residual bookkeeping maps must not outlive the row.
            for runID in conversationRuns[fence.conversationID] ?? [] {
                owners[runID] = nil
                lastObservedState[runID] = nil
            }
            conversationRuns[fence.conversationID] = nil
            feedEvidence[fence.conversationID] = nil
            drainEvidence[fence.conversationID] = nil
        }
        return .released
    }

    func abortDeleteGuard(_ fence: ConversationDeletionFence)
        -> ConversationDeletionFenceSettlement {
        settleFence(fence, committed: false)
    }

    func commitDeleteGuard(_ fence: ConversationDeletionFence)
        -> ConversationDeletionFenceSettlement {
        settleFence(fence, committed: true)
    }

    func fenceGuardState(_ conversationID: UUID) -> DeleteGuardState? {
        deleteGuards[conversationID]
    }

    // MARK: Global launch admission fence (privacy.history.clear port)

    /// Operation/conversation-free GLOBAL fence for the privacy-clear lane
    /// (job-c61a08d0162544ce): fences NEW launches (start/retry/steer-
    /// promote paths) while an enumerated history clear snapshots and
    /// recounts. Identity is the same generation-counter discipline as the
    /// per-conversation guard: a stale finish/abort can never clear a newer
    /// fence, refusal paths leave FUTURE ordinary launches usable once the
    /// real pending work settled, and there is NO timeout detach — pending
    /// in-flight launches are AWAITED to their real C0/C1 settlements first.
    /// Unrelated conversations' live runs are never cancelled by this fence
    /// (only the enumerated targets go through `RunDomainDeletionLifecycle`).
    /// BEGIN IS EXCLUSIVE (Main privacy-lane correction): while ANY fence is
    /// held a second begin refuses typed `duplicateInFlight` and the
    /// existing owner's token is left untouched — never replaced or
    /// invalidated across two facades.
    func beginGlobalAdmissionFence(expectedEpoch: UInt64) throws
        -> GlobalAdmissionFenceToken {
        guard expectedEpoch == epoch else {
            throw RunDomainError(.sessionFenced, .generationRetired)
        }
        // The retirement global block is DISTINCT and stays fenced: a new
        // operation fence never begins under a retired generation.
        guard !retirementFenced else {
            throw RunDomainError(.sessionFenced, .generationRetired)
        }
        guard globalFence == nil else {
            throw RunDomainError(.duplicateInFlight, .launchAlreadyInFlight)
        }
        globalFenceCounter &+= 1
        let token = GlobalAdmissionFenceToken(epoch: epoch,
                                              generation: globalFenceCounter)
        globalFence = token
        return token
    }

    /// True only for the CURRENT holder. Abort/commit of an old token is a
    /// classified false — it can never clear a newer fence (same rule as
    /// CH-R3 conversation guards, elevated to the global scope).
    @discardableResult
    func finishGlobalAdmissionFence(_ token: GlobalAdmissionFenceToken,
                                    committed: Bool) -> Bool {
        guard globalFence == token else { return false }
        globalFence = nil
        _ = committed // both exits release admission; commit/clear differ
                      // in the CALLER's durable steps, not in fence state.
        return true
    }

    func isGlobalAdmissionFencedNow() -> Bool { globalFence != nil }

    /// Real pending-launch quiescence for the fenced admission: launches in
    /// `.admitting`/`.prepared` (no live service yet) must reach their
    /// honest C0 refusal or C1 durable settlement BEFORE a privacy snapshot
    /// claims the run set is stable. Live `.handedOff` runs keep running
    /// unless individually drained — this function never cancels anything.
    /// No timer release: cancellation of the waiting caller keeps ownership
    /// intact and the fence stays held for the caller to finish/abort.
    func awaitPendingLaunchesSettled(expectedEpoch: UInt64) async throws {
        guard expectedEpoch == epoch else {
            throw RunDomainError(.sessionFenced, .generationRetired)
        }
        while true {
            let pending = owners.values.filter {
                $0.phase == .admitting || $0.phase == .prepared
            }
            if pending.isEmpty { return }
            if Task.isCancelled {
                throw RunDomainError(.sessionFenced, .generationRetired)
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Count of facade-owned live runs EXCLUDING the enumerated drain set —
    /// the privacy lane reports this honestly (it does NOT cancel unrelated
    /// ordinary runs for modelConfiguration.clear or history.clear).
    func liveRunCount(excluding conversationIDs: Set<UUID>) -> Int {
        owners.values.filter {
            ($0.phase == .handedOff || $0.phase == .terminating)
                && !conversationIDs.contains($0.conversationID)
        }.count
    }

    private func issueFence(_ conversationID: UUID) -> LaunchEpochFence.Token {
        launchFence.issue(scope: conversationID)
    }

    private func fenceIsValid(_ token: LaunchEpochFence.Token) -> Bool {
        launchFence.isValid(token)
    }

    // MARK: Ownership helpers

    func register(_ ownership: RunOwnership) {
        owners[ownership.runID] = ownership
        conversationRuns[ownership.conversationID, default: []].insert(ownership.runID)
        if retiredRunSet.remove(ownership.runID) != nil {
            retiredRuns.removeAll { $0 == ownership.runID }
        }
    }

    func unregister(_ ownership: RunOwnership) {
        owners[ownership.runID] = nil
        conversationRuns[ownership.conversationID]?.remove(ownership.runID)
        liveServices[ownership.runID] = nil
    }

    func ownership(runID: UUID) -> RunOwnership? { owners[runID] }

    func owners(conversationID: UUID) -> [RunOwnership] {
        (conversationRuns[conversationID] ?? []).compactMap { owners[$0] }
    }

    func liveService(_ runID: UUID) -> ConversationRunService? { liveServices[runID] }

    /// Trusted ordinary wire-launch CAS, executed inside the original
    /// launch writer before configuration or launch effects. This does not
    /// prohibit multiple live services on an already established task.
    static func verifyExistingLaunchRow(db: Database, row: Row?,
                                        conversationID: UUID,
                                        expectedRevision: String) throws {
        guard let row, (row["purpose"] as String?) == "ordinary" else {
            throw RunDomainError(.notFound, .conversationMissing)
        }
        guard ConversationRowRevision.digest(of: row) == expectedRevision else {
            throw RunDomainError(.staleRevision, .revisionMismatch)
        }
    }

    // MARK: - run.start / run.startTask

    /// The single launch pipeline. `conversationTitle` is used only by the
    /// create-intent path (run.startTask). `bundleOverride` is the RB5
    /// temporary seam; the wire handlers never pass it.
    public func start(query: RunStartQuery,
                      conversationTitle: String = "",
                      receipt: String?,
                      conversationID: UUID?,
                      bundleOverride: RunPersistenceBundle? = nil,
                      expectedConversationRevision: String? = nil) async
        -> RunDomainReply {
        let bundle = bundleOverride ?? durable
        let isCreateIntent = conversationID == nil
        // C0 window: nothing before the atomic prepare has a durable effect.
        let effectiveConversation = conversationID ?? query.conversationID
        let runID = UUID()
        // Frozen BEFORE the first await: execution identity (bundle),
        // conversation scope, minted runID, scoped fence token.
        let launchToken = issueFence(effectiveConversation)
        switch RuntimeOwnedWorkRegistry.shared.attach(epoch: epoch, kind: .run,
                                                      ownerID: runID.uuidString) {
        case .attached(let token):
            var ownership = RunOwnership(conversationID: effectiveConversation,
                                         runID: runID, epoch: epoch,
                                         identity: bundle.identity,
                                         launchToken: launchToken,
                                         bundle: bundle)
            ownership.commandReceipt = receipt
            ownership.ownedTokens[RuntimeOwnedWorkKind.run.rawValue] = token
            register(ownership)
            recordDrainEvidence(conversationID: effectiveConversation, token: token)
        case .rejected(let code):
            let mapped: RunDomainError
            switch code {
            case .receiptSaturated: mapped = RunDomainError(.duplicateInFlight, .internal)
            default: mapped = RunDomainError(.sessionFenced, .generationRetired)
            }
            return RunDomainReply(.rejected(mapped))
        case .invalidIdentity:
            return RunDomainReply(.rejected(RunDomainError(.internalError, .internal)))
        }

        // 1. Guard/fence admission + C0 cancel check (per-conversation
        //    delete guard AND the operation-owned global admission fence).
        do {
            if isGlobalAdmissionFencedNow() {
                throw RunDomainError(.sessionFenced, .deletingGuarded)
            }
            if !isCreateIntent { try requireNoGuard(conversationID: effectiveConversation) }
        } catch let error as RunDomainError {
            return refuseLaunch(runID: runID, error: error)
        } catch {
            return refuseLaunch(runID: runID,
                                error: RunDomainError(.internalError, .internal))
        }
        if shouldAbortBeforeEffects(runID) || !fenceIsValid(launchToken) {
            return refuseLaunch(runID: runID,
                                error: RunDomainError(.sessionFenced, .deletingGuarded))
        }

        // 2. Ingress scan (ORIGINAL scanner first). Captured raw secrets
        //    without the bound vault normalizer are refused BEFORE effects.
        let scanned = RunIngressScan.scan(query.goal)
        guard !scanned.isBlank else {
            return refuseLaunch(runID: runID,
                                error: RunDomainError(.invalidState, .payloadInvalid))
        }
        if scanned.captureCount > 0, components.credentialNormalizer == nil,
           bundle.identity == .ordinary {
            return refuseLaunch(runID: runID,
                                error: RunDomainError(.needsConfiguration, .normalizerUnbound))
        }

        // 3. Existing-conversation proof + full-row revision CAS (pre-effect
        //    rejection; the original transaction still proves FK existence
        //    atomically inside prepare). The durable ordinary proof is
        //    skipped ONLY for the RB5 temporary presentation, whose hosted
        //    identity the ORIGINAL EphemeralRunLaunchStore validates inside
        //    prepare (RB5 T1). The ordinary wire never carries a temporary
        //    bundle, so the durable singleton is never a fallback here.
        if !isCreateIntent, bundle.identity == .ordinary {
            do {
                guard try await components.conversationRevisions
                    .ordinaryExists(conversationID: effectiveConversation) else {
                    throw RunDomainError(.notFound, .conversationMissing)
                }
            } catch let error as RunDomainError {
                return refuseLaunch(runID: runID,
                                    error: error.addingPhase(.conversationProof))
            } catch {
                return refuseLaunch(runID: runID, error: RunDomainError(
                    .persistenceUnavailable, .storeReadFailed,
                    phase: .conversationProof,
                    storePrimaryCode: Self.storePrimaryCode(of: error),
                    storeExtendedCode: Self.storeExtendedCode(of: error)))
            }
        }

        // 4. Model/auth/gate/transport admission BEFORE effects. The
        //    validated gate instance is kept for the service assembly —
        //    never re-loaded, never an empty fake gate.
        let launch: RunModelAssembly.ResolvedPair
        let gate: CatastrophicActionGate?
        // Admission-proven role identities (set ONLY after the trusted proof
        // answered YES; forwarded below into ownership AND the runtime).
        var provenEnvironmentID: String?
        var provenJobID: String?
        // Bounded localization phase for the storeOpenFailed/storeReadFailed
        // diagnosis: advanced before each admission step so the refusal
        // carries WHICH step failed (closed static enum; default nil
        // preserves every existing exact error).
        var admissionPhase: RunDomainError.Phase? = nil
        do {
            admissionPhase = .modelResolution
            if bundle.identity == .ordinary, components.credentialNormalizer == nil {
                throw RunDomainError(.needsConfiguration, .normalizerUnbound)
            }
            launch = try await assembly.resolveSelected(providerID: query.providerID,
                                                        modelID: query.modelID)
            admissionPhase = .credentialResolution
            switch await ingress.resolve(provider: launch.provider) {
            case .resolved, .explicitNoAuth: break
            case .gatewayUnregistered:
                throw RunDomainError(.credentialUnavailable, .gatewayUnregistered)
            case .secretMissing:
                throw RunDomainError(.credentialUnavailable, .secretMissing)
            case .secretInvalidated:
                throw RunDomainError(.credentialUnavailable, .secretInvalidated)
            }
            admissionPhase = .gateAdmission
            switch RunGateAdmission.admit(context: components.context) {
            case .usable(let admittedGate):
                gate = admittedGate
            case .needsCorpus:
                throw RunDomainError(.needsConfiguration, .corpusAbsent)
            }
            admissionPhase = .transportAdmission
            if !components.context.isTransportQualified {
                // Provider dispatch would fail at the socket; refusing
                // BEFORE the durable commit keeps C0 honest and never
                // leaves an orphan preparing row.
                throw RunDomainError(.transportUnavailable, .transportNotQualified)
            }
            admissionPhase = .capabilityAdmission
            if query.mode == .goal, bundle.intelligence == nil {
                throw RunDomainError(.invalidState, .goalModeUnsupportedStore)
            }
            if let env = query.requestedEnvironmentID {
                admissionPhase = .environmentProof
                guard let proof = components.environmentProof,
                      await proof.proveEnvironment(env,
                                                   conversationID: effectiveConversation,
                                                   epoch: epoch) else {
                    throw RunDomainError(.unsupportedRole, .environmentRoleUnresolvable)
                }
                provenEnvironmentID = env
            }
            if let job = query.requestedJobID {
                admissionPhase = .environmentProof
                guard let proof = components.environmentProof,
                      await proof.proveJob(job, runID: runID, epoch: epoch) else {
                    throw RunDomainError(.unsupportedRole, .jobRoleUnresolvable)
                }
                provenJobID = job
            }
            admissionPhase = nil
        } catch let error as RunDomainError {
            return refuseLaunch(runID: runID,
                                error: error.addingPhase(admissionPhase))
        } catch {
            return refuseLaunch(runID: runID, error: RunDomainError(
                .persistenceUnavailable, .storeReadFailed,
                phase: admissionPhase,
                storePrimaryCode: Self.storePrimaryCode(of: error),
                storeExtendedCode: Self.storeExtendedCode(of: error)))
        }

        // 4b. The accepted identities are ADMISSION truth: keep them on the
        //     immutable run ownership from here on (never accept-then-drop).
        if provenEnvironmentID != nil || provenJobID != nil,
           var admitted = owners[runID] {
            admitted.environmentID = provenEnvironmentID
            admitted.jobID = provenJobID
            register(admitted)
        }

        // 5. Staged attachment LEASES before the transaction (RUN-S4
        //    repair): each handle is RESERVED for this exact launch owner
        //    (typed double-launch refusal); the ORIGINAL prepare stays the
        //    sole atomic attachment insertion/normalization with real
        //    message/conversation ids. A reservation is released on any
        //    pre-commit failure (staged bytes preserved); after the commit
        //    it is acknowledged exactly once and never discarded.
        let leases: [RunAttachmentLease]
        do {
            leases = try await reserveStagedHandles(
                query.stagedAttachmentHandles,
                conversationID: isCreateIntent ? nil : effectiveConversation,
                runID: runID)
        } catch let error as RunDomainError {
            return refuseLaunch(runID: runID,
                                error: error.addingPhase(.stagedReservation))
        } catch {
            return refuseLaunch(runID: runID, error: RunDomainError(
                .persistenceUnavailable, .storeReadFailed,
                phase: .stagedReservation,
                storePrimaryCode: Self.storePrimaryCode(of: error),
                storeExtendedCode: Self.storeExtendedCode(of: error)))
        }
        let hasImages = leases.contains { $0.ref.kind == .image }
        if hasImages, bundle.identity == .temporary {
            // Temporary denies images BEFORE any staged IO (RAM-only
            // contract; nothing binary crosses the temporary path).
            await releaseReservations(leases)
            return refuseLaunch(runID: runID,
                                error: RunDomainError(.capabilityNotUsable,
                                                      .imageLoaderUnbound))
        }
        if hasImages, components.stagedImages == nil {
            // The trusted bounded image loader is unbound: honest typed
            // refusal BEFORE any loader IO and before the transaction.
            await releaseReservations(leases)
            return refuseLaunch(runID: runID,
                                error: RunDomainError(.capabilityNotUsable,
                                                      .imageLoaderUnbound))
        }
        // Mode/capability admission now sees the REAL image presence: the
        // primary model must carry .vision or the ORIGINAL preferences must
        // provide an enabled text+vision auxiliary route.
        do {
            try await assembly.admit(mode: query.mode, model: launch.model,
                                     hasImages: hasImages)
        } catch let error as RunDomainError {
            await releaseReservations(leases)
            return refuseLaunch(runID: runID,
                                error: error.addingPhase(.capabilityAdmission))
        } catch {
            await releaseReservations(leases)
            return refuseLaunch(runID: runID, error: RunDomainError(
                .persistenceUnavailable, .storeReadFailed,
                phase: .capabilityAdmission,
                storePrimaryCode: Self.storePrimaryCode(of: error),
                storeExtendedCode: Self.storeExtendedCode(of: error)))
        }

        // 6. Final pre-commit window re-check (concurrent cancel/fence/
        //    delete/steer interleave honestly). A refusal here releases the
        //    staged leases: the launch never happened, so nothing may keep
        //    an exclusive claim — while the staged bytes stay untouched.
        if shouldAbortBeforeEffects(runID) || !fenceIsValid(launchToken) {
            await releaseReservations(leases)
            return refuseLaunch(runID: runID,
                                error: RunDomainError(.sessionFenced, .deletingGuarded))
        }

        // 7. The ORIGINAL atomic launch commit against the RUN'S OWN bundle
        //    (RUN-S2 repair): ordinary → SQLiteRunLaunchStore.prepare in the
        //    one writer transaction; temporary → the ORIGINAL
        //    EphemeralRunLaunchStore RAM mirror with hosted-identity
        //    validation. No real ID exists until this returns; a throw
        //    rolls the WHOLE launch back (provable C0 no-effect) and
        //    releases the staged reservations (bytes preserved).
        //    A temporary create-intent reuses the HOSTED identity frozen in
        //    the query (RB5 T1); an ordinary create-intent mints fresh.
        //    G02 first activation: an ORDINARY launch against an existing
        //    header opts in so a genuinely empty header created through the
        //    conversation domain (no ownership yet) establishes its own
        //    canonical workspace + policy in the SAME transaction; every
        //    non-ordinary caller and every nonempty/header-ineligible case
        //    keeps the exact original refusal.
        var request = RunLaunchRequest(
            conversationID: isCreateIntent ? nil : effectiveConversation,
            newConversationID: isCreateIntent
                ? (bundle.identity == .temporary ? effectiveConversation : UUID())
                : nil,
            conversationTitle: isCreateIntent ? conversationTitle : "",
            runID: runID,
            goal: scanned.sanitizedText
                .trimmingCharacters(in: .whitespacesAndNewlines),
            initialState: "preparing",
            workspaceID: nil,
            attachments: leases.map(\.ref),
            conversationMode: query.mode.rawValue,
            initialPolicy: query.policy,
            messageRole: "user",
            providerID: launch.provider.id,
            modelID: launch.model.id,
            providerName: launch.provider.displayName,
            modelName: launch.model.displayName,
            providerProfile: launch.provider,
            modelProfile: launch.model)
        request.activatesEmptyOrdinaryHeader = bundle.identity == .ordinary
        let prepared: PreparedRun
        do {
            if bundle.identity == .ordinary, !isCreateIntent,
               let expectedConversationRevision {
                guard let validating = bundle.launches as? any ExistingConversationRunLaunchStore else {
                    throw RunDomainError(.persistenceUnavailable, .storeReadFailed)
                }
                prepared = try await validating.prepare(request, expectedRow: { db, row in
                    try Self.verifyExistingLaunchRow(
                        db: db, row: row, conversationID: effectiveConversation,
                        expectedRevision: expectedConversationRevision)
                })
            } else {
                // New identity and temporary RAM launches preserve the
                // original preparation protocol and lifetime exactly.
                prepared = try await bundle.launches.prepare(request)
            }
        } catch {
            await releaseReservations(leases)
            return refuseLaunch(runID: runID,
                                error: mapPrepareError(error, phase: .launchPrepare))
        }
        // The ORIGINAL prepare committed: acknowledge every staged lease
        // EXACTLY ONCE with the REAL committed ids. From here the staged
        // bytes belong to the committed message — after commit no discard
        // ever happens, including the C1-abandon path below.
        for lease in leases {
            await commitReservation(lease, conversationID: prepared.conversation.id,
                                    messageID: prepared.userMessage.id)
        }
        // Identity publication timing (settled): REAL conversation/run IDs
        // appear for the FIRST time now, in the async prepared effect —
        // never in the queue receipt. The exact owned evidence (ownership
        // maps, bundle, scoped token) remaps from the pre-commit identity
        // to the committed one in this single register step.
        var current = owners[runID] ?? RunOwnership(
            conversationID: prepared.conversation.id, runID: runID, epoch: epoch,
            identity: bundle.identity, launchToken: launchToken, bundle: bundle)
        unregister(current)
        current.conversationID = prepared.conversation.id
        current.phase = .prepared
        if let receipt {
            current.preparedEffectEmitted = components.effects.append(
                receipt: receipt, kind: .prepared,
                detail: [
                    "conversationID": prepared.conversation.id.uuidString,
                    "runID": prepared.run.id.uuidString,
                    "resourceID": RunWireRevision.runResourceID(prepared.run.id),
                    "version": RunWireRevision.runVersion(state: prepared.run.state),
                ])
        }
        register(current)

        // Intelligence hook #1: PERSISTED ORDINARY user-message commit,
        // once per real commit, only for ordinary identity. The feed is
        // dispatched as a REAL owned maintenance Task whose exact lease is
        // acquired BEFORE this pipeline continues — the launch NEVER waits
        // on a stalled source-index/organize/generation feed (RUN-S3
        // repair), and a temporary identity never feeds anything (T4).
        if bundle.identity == .ordinary, components.intelligenceFeed != nil,
           !current.intelligenceUserMessageFed {
            current.intelligenceUserMessageFed = true
            register(current)
            dispatchIntelligenceFeed(
                runID: prepared.run.id,
                .userMessage(RunIntelligenceEvent(
                    rootEpoch: epoch, conversationID: prepared.conversation.id,
                    runID: prepared.run.id, messageID: prepared.userMessage.id)))
        }

        // C1 cancel: a cancel/fence that arrived during prepare must fail
        // the COMMITTED launch truthfully (durable rows exist and stay;
        // staged attachments were committed above and are never discarded).
        if shouldAbortBeforeEffects(runID) || !fenceIsValid(launchToken) {
            await markCommittedLaunchAbandoned(runID: prepared.run.id,
                                               reason: "cancelledBeforeStart",
                                               bundle: bundle)
            await retire(runID: prepared.run.id, terminalSucceeded: false,
                         feedTerminal: false)
            return RunDomainReply(.rejected(RunDomainError(.sessionFenced, .deletingGuarded)))
        }

        // 8. Build the ORIGINAL service (embedded runtime + harness channel)
        //    against the RUN'S OWN bundle and hand execution to REAL owned
        //    Tasks. The command slot ends with the accepted terminal; the
        //    run keeps living under this service owner independent of any
        //    view.
        let service: ConversationRunService
        var assemblyPhase: RunDomainError.Phase? = .historyLoad
        do {
            let history = try await loadRunHistory(
                conversationID: prepared.conversation.id,
                excludingRun: prepared.run.id,
                bundle: bundle)
            assemblyPhase = .imageLoad
            let images = try await loadLaunchImages(leases)
            assemblyPhase = .serviceAssembly
            service = try await makeService(
                runID: prepared.run.id,
                conversationID: prepared.conversation.id,
                goal: prepared.run.goal,
                mode: ConversationMode(rawValue: prepared.run.conversationMode ?? "chat")
                    ?? .chat,
                launch: launch,
                history: history,
                images: images,
                bundle: bundle,
                draftPolicy: query.policy,
                gate: gate,
                workspaceName: prepared.workspace.name,
                hostToolCeiling: query.hostToolCeiling,
                environmentID: provenEnvironmentID)
            assemblyPhase = nil
        } catch let error as RunDomainError {
            await markCommittedLaunchAbandoned(runID: prepared.run.id,
                                               reason: "serviceAssemblyFailed",
                                               bundle: bundle)
            await retire(runID: prepared.run.id, terminalSucceeded: false,
                         feedTerminal: false)
            return RunDomainReply(.rejected(error.addingPhase(assemblyPhase)))
        } catch {
            await markCommittedLaunchAbandoned(runID: prepared.run.id,
                                               reason: "serviceAssemblyFailed",
                                               bundle: bundle)
            await retire(runID: prepared.run.id, terminalSucceeded: false,
                         feedTerminal: false)
            return RunDomainReply(.rejected(RunDomainError(
                .persistenceUnavailable, .storeWriteFailed,
                phase: assemblyPhase,
                storePrimaryCode: Self.storePrimaryCode(of: error),
                storeExtendedCode: Self.storeExtendedCode(of: error))))
        }
        // The REAL service registry is populated BEFORE the control-visible
        // handoff (RUN-S1 repair): cancel/steer/policy/snapshot reach the
        // live producer from this point; removal happens ONLY at retirement
        // under actor state.
        liveServices[prepared.run.id] = service
        var handed = owners[runID] ?? current
        handed.phase = .handedOff
        if let receipt, !handed.startedEffectEmitted {
            // `started` = the owned producer Tasks are dispatched and the
            // ORIGINAL service is live-backed. The long run then releases
            // the command slot; the run lifecycle is owned separately (the
            // track Task), never by mailbox continuation slots.
            handed.startedEffectEmitted = components.effects.append(
                receipt: receipt, kind: .started,
                detail: ["runID": prepared.run.id.uuidString])
        }
        register(handed)
        launchTaskAttach(prepared: prepared, service: service, domain: self)
        return RunDomainReply(.mutationAccepted(detail: [
            "launched": "true",
            "runID": prepared.run.id.uuidString,
        ]))
    }

    /// Wire surface for `run.start` (existing conversation, createIntent
    /// FORBIDDEN by the frozen matrix; revision CAS against the settled
    /// floe.conversation-row.v1 full-row digest).
    public func start(envelope: RunCommandEnvelope, receipt: String,
                      correlation: String) async -> RunDomainReply {
        let query: RunStartQuery
        let conversationID: UUID
        var admittedConversation: UUID?
        defer {
            if let admittedConversation { ordinaryWireAdmissions.remove(admittedConversation) }
        }
        do {
            conversationID = try envelope.requireTask()
            if envelope.runID != nil {
                // A launch envelope carrying a run role can only be a
                // misroute; the grammar rejects it, defense-in-depth here.
                throw RunDomainError(.invalidState, .payloadInvalid)
            }
            query = try RunStartQuery.parse(payload: envelope.payloadValue,
                                            conversationID: conversationID)
            // Reserve before the FIRST await. This fences only overlapping
            // admission of two ordinary wire sends. The defer releases on
            // every success/refusal; it never holds for service lifetime.
            if durable.identity == .ordinary {
                guard ordinaryWireAdmissions.insert(conversationID).inserted else {
                    throw RunDomainError(.duplicateInFlight, .launchAlreadyInFlight)
                }
                admittedConversation = conversationID
            }
            // Ineligible (non-ordinary/invisible) conversations answer
            // exactly like absence BEFORE any revision proof (RB3
            // indistinguishability): a Notes row must never leak a
            // staleRevision for a chat-only envelope.
            guard try await components.conversationRevisions
                .ordinaryExists(conversationID: conversationID) else {
                throw RunDomainError(.notFound, .conversationMissing)
            }
            let digest = try await components.conversationRevisions
                .digest(conversationID: conversationID) ?? ""
            try envelope.revisionMatches(
                resourceID: ConversationRowRevision.resourceID(conversationID: conversationID),
                version: digest)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error.addingPhase(.conversationProof)))
        } catch {
            return RunDomainReply(.rejected(
                RunDomainError(.persistenceUnavailable, .storeReadFailed,
                               phase: .conversationProof,
                               storePrimaryCode: Self.storePrimaryCode(of: error),
                               storeExtendedCode: Self.storeExtendedCode(of: error))))
        }
        return await start(query: query, receipt: receipt,
                           conversationID: conversationID,
                           expectedConversationRevision: envelope.revision?.version)
    }

    /// Wire surface for `run.startTask` (explicit create intent, NO owner
    /// and NO revision per the frozen grammar). The minted conversation
    /// identity exists ONLY after the atomic commit; the probe identity is
    /// never exposed or persisted.
    public func startTask(envelope: RunCommandEnvelope, receipt: String,
                          correlation: String) async -> RunDomainReply {
        let query: RunStartTaskQuery
        do {
            if envelope.taskID != nil {
                throw RunDomainError(.invalidState, .payloadInvalid)
            }
            query = try RunStartTaskQuery.parse(payload: envelope.payloadValue)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        return await start(query: query.inner,
                           conversationTitle: query.conversationTitle,
                           receipt: receipt, conversationID: nil)
    }

    // MARK: - run.cancel

    public func cancel(envelope: RunCommandEnvelope) async -> RunDomainReply {
        let owner: OwnerIdentity
        let query: RunCancelQuery
        do {
            owner = try envelope.requireTaskAndRun()
            query = try RunCancelQuery.parse(payload: envelope.payloadValue, owner: owner)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        let record: RunRecord
        do {
            record = try await durableRecord(query.runID, conversationID: query.conversationID)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                           .storeReadFailed)))
        }
        guard query.expectedState == record.state else {
            return RunDomainReply(.rejected(RunDomainError(.staleRevision, .revisionMismatch)))
        }
        do {
            try envelope.revisionMatches(
                resourceID: RunWireRevision.runResourceID(query.runID),
                version: record.state)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.staleRevision, .revisionAbsent)))
        }
        if owners[query.runID] == nil, retiredRunSet.contains(query.runID) {
            // THIS domain retired this run in the current generation: the
            // cancel was already requested and settled; answering honestly
            // (never a fake re-owning, never a runMissing for known work).
            return RunDomainReply(.mutationAccepted(detail: ["cancel": "alreadyRequested"]))
        }
        if Self.terminalRunStates.contains(record.state), owners[query.runID] == nil {
            // Already durable-terminal and unowned: nothing to cancel and
            // NO fake "cancelled" claim.
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .runNotRetryable)))
        }
        guard var ownership = owners[query.runID] else {
            // Non-terminal durable row without a facade owner: either a
            // crashed generation's leftover (bootstrap marked it
            // interrupted — then it IS terminal vocabulary) or another
            // process's work this facade must not pretend to own.
            return RunDomainReply(.rejected(RunDomainError(.notFound, .runMissing)))
        }
        switch ownership.phase {
        case .admitting:
            // C0: the launch re-checks this flag before prepare; provable
            // no-effect.
            ownership.cancelRequested = true
            register(ownership)
            return RunDomainReply(.mutationAccepted(detail: ["cancel": "pendingC0"]))
        case .prepared:
            // C1 before handoff: the committed launch fails truthfully.
            // The run's own bundle performs the marking (the ordinary
            // singleton is never a fallback for a supplied bundle).
            ownership.cancelRequested = true
            ownership.phase = .terminating
            let bundle = ownership.bundle
            register(ownership)
            await markCommittedLaunchAbandoned(runID: query.runID,
                                               reason: "cancelledDuringPrepare",
                                               bundle: bundle)
            await retire(runID: query.runID, terminalSucceeded: false, feedTerminal: false)
            return RunDomainReply(.mutationAccepted(detail: [
                "cancel": "appliedC1", "resourceID": RunWireRevision.runResourceID(query.runID)]))
        case .handedOff:
            ownership.phase = .terminating
            register(ownership)
            // Close the ACTUAL owned producer. The runtime cancel cascade
            // (stream + in-flight tool + approval expiry + final
            // checkpoint) is the ORIGINAL engine path.
            if let service = liveServices[query.runID] {
                await service.cancel()
            }
            return RunDomainReply(.mutationAccepted(detail: [
                "cancel": "requested", "resourceID": RunWireRevision.runResourceID(query.runID)]))
        case .terminating, .retired:
            return RunDomainReply(.mutationAccepted(detail: ["cancel": "alreadyRequested"]))
        }
    }

    // MARK: - run.retry

    public func retry(envelope: RunCommandEnvelope, receipt: String) async -> RunDomainReply {
        if isGlobalAdmissionFencedNow() {
            return RunDomainReply(.rejected(RunDomainError(.sessionFenced, .deletingGuarded)))
        }
        let owner: OwnerIdentity
        let query: RunRetryQuery
        do {
            owner = try envelope.requireTaskAndRun()
            query = try RunRetryQuery.parse(payload: envelope.payloadValue, owner: owner)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        // A per-conversation delete guard refuses EVERY new run admission
        // (retry included) BEFORE the live-owner duplicate check: the fence
        // verdict is the operation truth for the guarded conversation.
        do {
            try requireNoGuard(conversationID: query.conversationID)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.internalError, .internal)))
        }
        guard owners[query.runID] == nil else {
            return RunDomainReply(.rejected(RunDomainError(.duplicateInFlight,
                                                           .launchAlreadyInFlight)))
        }
        let record: RunRecord
        do {
            record = try await durableRecord(query.runID, conversationID: query.conversationID)
            if record.state != query.expectedState {
                throw RunDomainError(.staleRevision, .revisionMismatch)
            }
            try envelope.revisionMatches(
                resourceID: RunWireRevision.runResourceID(query.runID),
                version: record.state)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                           .storeReadFailed)))
        }
        guard Self.activeRunStates.contains(record.state)
                || record.state == "failed" || record.state == "interrupted"
                || record.state == "checkpointed" else {
            // completed is FINAL; retrying success would fabricate a new
            // answer turn on a closed thread. checkpointed is the ORIGINAL
            // recoverable resume source (cancel/pause park), never final.
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .runNotRetryable)))
        }
        // A parked awaiting-dependency run is NOT finished; refuse Continue
        // exactly like the native guard (its resumption belongs to the job
        // callback path, out of G02 facade scope).
        if await isAwaitingDependency(record: record) {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .runAwaitingDependency)))
        }
        do {
            try requireNoGuard(conversationID: record.conversationID)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        }
        catch {
            return RunDomainReply(.rejected(RunDomainError(.internalError, .internal)))
        }
        // Preserve native retry identity: the ORIGINAL durable provider/
        // model row first; missing identity columns are a typed refusal
        // (never an inferred first provider).
        let launch: RunModelAssembly.ResolvedPair
        do {
            guard let modelID = record.modelID, let providerID = record.providerID else {
                throw RunDomainError(.needsConfiguration, .modelDisabled)
            }
            launch = try await assembly.resolveSelected(providerID: providerID, modelID: modelID)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.needsConfiguration,
                                                           .providerDisabled)))
        }
        // Checkpoint identity check FIRST (native :6270-6295): foreign or
        // unreadable checkpoint files are IGNORED (bounded warning class)
        // and the durable-history fallback resumes the SAME run. No blind
        // stale resume; the model never chooses a file path.
        let loaded = try? await components.checkpoints.load(runID: record.id)
        let checkpoint: AgentCheckpoint?
        if let loaded, loaded.runID == record.id,
           loaded.conversationID == record.conversationID {
            checkpoint = loaded
        } else {
            checkpoint = nil
        }
        switch RuntimeOwnedWorkRegistry.shared.attach(epoch: epoch, kind: .run,
                                                      ownerID: record.id.uuidString) {
        case .attached(let token):
            var ownership = RunOwnership(conversationID: record.conversationID,
                                         runID: record.id, epoch: epoch,
                                         identity: .ordinary,
                                         launchToken: issueFence(record.conversationID),
                                         bundle: durable)
            ownership.commandReceipt = receipt
            ownership.phase = .prepared
            ownership.ownedTokens[RuntimeOwnedWorkKind.run.rawValue] = token
            register(ownership)
            recordDrainEvidence(conversationID: record.conversationID, token: token)
            // A delete/retirement guard that appeared during admission must
            // stop this resume BEFORE any service handoff (no late owner).
            if retirementFenced || globalFence != nil
                || deleteGuards[record.conversationID] != nil {
                await retire(runID: record.id, terminalSucceeded: false,
                             feedTerminal: false)
                return RunDomainReply(.rejected(
                    RunDomainError(.sessionFenced, .deletingGuarded)))
            }
        case .rejected:
            return RunDomainReply(.rejected(RunDomainError(.sessionFenced, .generationRetired)))
        case .invalidIdentity:
            return RunDomainReply(.rejected(RunDomainError(.internalError, .internal)))
        }
        // A resume is a REAL new dispatch: the same admission truths as a
        // launch (corpus gate, transport qualification, vault normalizer)
        // must hold BEFORE the engine resumes — never a silent downgrade.
        let gate: CatastrophicActionGate
        do {
            if components.credentialNormalizer == nil {
                throw RunDomainError(.needsConfiguration, .normalizerUnbound)
            }
            switch RunGateAdmission.admit(context: components.context) {
            case .usable(let admittedGate):
                gate = admittedGate
            case .needsCorpus:
                throw RunDomainError(.needsConfiguration, .corpusAbsent)
            }
            if !components.context.isTransportQualified {
                throw RunDomainError(.transportUnavailable, .transportNotQualified)
            }
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(
                .persistenceUnavailable, .storeReadFailed)))
        }
        let history: [ConversationMessage]
        do {
            history = try await loadRunHistory(
                conversationID: record.conversationID,
                excludingRun: record.id,
                bundle: durable)
        } catch let error as RunDomainError {
            await retire(runID: record.id, terminalSucceeded: false, feedTerminal: false)
            return RunDomainReply(.rejected(error))
        } catch {
            await retire(runID: record.id, terminalSucceeded: false, feedTerminal: false)
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                           .storeReadFailed)))
        }
        guard let mode = ConversationMode(rawValue: record.conversationMode ?? "chat") else {
            await retire(runID: record.id, terminalSucceeded: false, feedTerminal: false)
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        let service: ConversationRunService
        do {
            service = try await makeService(
                runID: record.id, conversationID: record.conversationID,
                goal: record.goal, mode: mode, launch: launch,
                history: history, images: [], bundle: durable,
                draftPolicy: nil,   // ordinary retry: durable policy row
                gate: gate, workspaceName: nil, hostToolCeiling: nil,
                // The retry envelope carries no requested environment/job
                // role; there is no accepted binding to forward here (the
                // original launch's admission was not durable state).
                environmentID: nil)
        } catch let error as RunDomainError {
            await markCommittedLaunchAbandoned(runID: record.id,
                                               reason: "serviceAssemblyFailed",
                                               bundle: durable)
            await retire(runID: record.id, terminalSucceeded: false, feedTerminal: false)
            return RunDomainReply(.rejected(error))
        } catch {
            await markCommittedLaunchAbandoned(runID: record.id,
                                               reason: "serviceAssemblyFailed",
                                               bundle: durable)
            await retire(runID: record.id, terminalSucceeded: false, feedTerminal: false)
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                           .storeWriteFailed)))
        }
        // Retry re-owns the SAME run id: the live registry must answer
        // cancel/steer/policy/snapshot for it exactly like a fresh launch.
        liveServices[record.id] = service
        var handed = owners[record.id]!
        handed.phase = .handedOff
        handed.startedEffectEmitted = components.effects.append(
            receipt: receipt, kind: .started,
            detail: ["runID": record.id.uuidString,
                     "resumed": checkpoint != nil ? "checkpoint" : "history"])
        register(handed)
        ownedLaunchTasks(preparedRunID: record.id, service: service,
                         goal: record.goal, resumeFrom: checkpoint)
        return RunDomainReply(.mutationAccepted(detail: [
            "resumed": "true",
            "source": checkpoint != nil ? "checkpoint" : "history",
        ]))
    }

    // MARK: - run.steer / run.queue

    public func queue(envelope: RunCommandEnvelope) async -> RunDomainReply {
        let owner: OwnerIdentity
        let query: RunQueueQuery
        do {
            owner = try envelope.requireTaskAndRun()
            query = try RunQueueQuery.parse(payload: envelope.payloadValue, owner: owner)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        guard query.mode == .queue else {
            // steer-mode submission flows through run.steer against the
            // durable row; a direct steer payload here is a shape error.
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        do {
            let digest = try await components.conversationRevisions
                .digest(conversationID: query.conversationID) ?? ""
            try envelope.revisionMatches(
                resourceID: ConversationRowRevision.resourceID(conversationID: query.conversationID),
                version: digest)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                           .storeReadFailed)))
        }
        let scanned = RunIngressScan.scan(query.content)
        guard !scanned.isBlank else {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        if scanned.captureCount > 0, components.credentialNormalizer == nil {
            return RunDomainReply(.rejected(RunDomainError(.needsConfiguration,
                                                           .normalizerUnbound)))
        }
        do {
            try requireNoGuard(conversationID: query.conversationID)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        }
        catch {
            return RunDomainReply(.rejected(RunDomainError(.internalError, .internal)))
        }
        let attachments: [AttachmentRef]
        do {
            attachments = try await resolveStagedHandles(
                query.stagedAttachmentHandles, conversationID: nil)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                           .storeReadFailed)))
        }
        do {
            let stored = try await durable.runningInputs.enqueue(PendingUserInput(
                conversationID: query.conversationID,
                targetRunID: query.runID,
                content: scanned.sanitizedText
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                mode: .queue,
                attachments: attachments,
                selectedModelID: query.selectedModelID,
                workspaceID: nil,
                executionMode: "agent"))
            // Queue accepted is NOT approval resolved, NOT secret committed
            // and NOT a started run; the durable row + position are the
            // truth, and consumption stays the service's exactly-once
            // receipt (consumedRunID).
            return RunDomainReply(.mutationAccepted(detail: [
                "inputID": stored.id.uuidString,
                "position": String(stored.position),
                "status": stored.status.rawValue,
                "inputVersion": RunWireRevision.inputVersion(updatedAt: stored.updatedAt),
            ]))
        } catch {
            let detail = (error as? FloeError).map { "\($0)" } ?? ""
            if detail.contains("queue is full") {
                return RunDomainReply(.rejected(RunDomainError(.invalidState, .queueFull)))
            }
            if detail.contains("empty") {
                return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
            }
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                           .storeWriteFailed)))
        }
    }

    public func steer(envelope: RunCommandEnvelope) async -> RunDomainReply {
        let owner: OwnerIdentity
        let query: RunSteerQuery
        do {
            owner = try envelope.requireTaskAndRun()
            query = try RunSteerQuery.parse(payload: envelope.payloadValue, owner: owner)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        do {
            try requireNoGuard(conversationID: query.conversationID)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        }
        catch {
            return RunDomainReply(.rejected(RunDomainError(.internalError, .internal)))
        }
        let liveService = (owners[query.runID]?.phase == .handedOff
                            || owners[query.runID]?.phase == .terminating)
            ? liveServices[query.runID] : nil
        guard let service = liveService else {
            // Native steerTargetEndedQueued parity: keep the durable row
            // queued; NEVER fabricate a promotion and never auto-launch.
            let row = try? await durable.runningInputs.input(id: query.inputID)
            if row == nil {
                return RunDomainReply(.rejected(RunDomainError(.notFound, .inputMissing)))
            }
            return RunDomainReply(.mutationAccepted(detail: [
                "promoted": "false", "reason": "steerTargetEndedQueued",
            ]))
        }
        let promoted: PendingUserInput?
        do {
            promoted = try await durable.runningInputs.beginSteerPromotion(
                id: query.inputID, expectedRunID: query.runID)
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                           .storeWriteFailed)))
        }
        guard let input = promoted else {
            // The row is not `queued`: when THIS run already holds the steer
            // (steerPending/promoting), the ORIGINAL service's ledger owns
            // the exactly-once truth — a same-id replay surfaces
            // alreadyAccepted from the REAL runtime instead of a misleading
            // staleRevision.
            if let existing = try? await durable.runningInputs.input(id: query.inputID),
               existing.targetRunID == query.runID,
               (existing.status == .steerPending || existing.status == .promoting),
               let service = liveService {
                let replay = await service.steer(RuntimeSteerInput(
                    id: existing.id,
                    content: existing.content,
                    images: ConversationHistoryAssembler.inlineImages(existing.attachments),
                    attachments: existing.attachments,
                    createdAt: existing.createdAt),
                    expectedRunID: query.runID)
                if case .alreadyAccepted = replay {
                    return RunDomainReply(.mutationAccepted(detail: [
                        "accepted": "true", "alreadyAccepted": "true",
                        "inputID": existing.id.uuidString]))
                }
            }
            return RunDomainReply(.rejected(RunDomainError(.staleRevision, .revisionMismatch)))
        }
        guard input.conversationID == query.conversationID else {
            try? await durable.runningInputs.restoreQueued(id: input.id)
            return RunDomainReply(.rejected(RunDomainError(.notFound, .inputMissing)))
        }
        let record: RunRecord?
        do {
            record = try await durable.runs.run(id: query.runID)
        } catch {
            try? await durable.runningInputs.restoreQueued(id: input.id)
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                           .storeReadFailed)))
        }
        guard let record else {
            try? await durable.runningInputs.restoreQueued(id: input.id)
            return RunDomainReply(.rejected(RunDomainError(.notFound, .runMissing)))
        }
        guard query.expectedState == record.state else {
            try? await durable.runningInputs.restoreQueued(id: input.id)
            return RunDomainReply(.rejected(RunDomainError(.staleRevision, .revisionMismatch)))
        }
        do {
            try envelope.revisionMatches(
                resourceID: RunWireRevision.runResourceID(query.runID),
                version: record.state)
        } catch let error as RunDomainError {
            try? await durable.runningInputs.restoreQueued(id: input.id)
            return RunDomainReply(.rejected(error))
        } catch {
            try? await durable.runningInputs.restoreQueued(id: input.id)
            return RunDomainReply(.rejected(RunDomainError(.staleRevision, .revisionAbsent)))
        }
        let steerImages = ConversationHistoryAssembler.inlineImages(input.attachments)
        let acceptance = await service.steer(RuntimeSteerInput(
            id: input.id,
            content: input.content,
            images: steerImages,
            attachments: input.attachments,
            createdAt: input.createdAt),
            expectedRunID: query.runID)
        switch acceptance {
        case .accepted:
            do {
                try await durable.runningInputs.markSteerAccepted(id: input.id,
                                                                  runID: query.runID)
            } catch {
                // Durable status write failed after the runtime accepted:
                // withdraw the in-memory steer and restore the row. The
                // consumed exactly-once receipt (consumedRunID) is written
                // ONLY by the original service path, never here.
                _ = await service.withdrawSteer(id: input.id)
                try? await durable.runningInputs.restoreQueued(id: input.id)
                return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                               .storeWriteFailed)))
            }
            return RunDomainReply(.mutationAccepted(detail: [
                "accepted": "true", "inputID": input.id.uuidString]))
        case .alreadyAccepted:
            return RunDomainReply(.mutationAccepted(detail: [
                "accepted": "true", "alreadyAccepted": "true",
                "inputID": input.id.uuidString]))
        case .rejected(let reason):
            try? await durable.runningInputs.restoreQueued(id: input.id)
            let closed = reason.contains("no longer accepting")
            return RunDomainReply(.rejected(RunDomainError(
                .invalidState, closed ? .steerAlreadyConsumed : .steerRaceConsumed)))
        }
    }

    // MARK: - run.input.edit / remove / reorder

    public func inputEdit(envelope: RunCommandEnvelope) async -> RunDomainReply {
        let owner: OwnerIdentity
        let query: RunInputEditQuery
        do {
            owner = try envelope.requireTaskAndRun()
            query = try RunInputEditQuery.parse(payload: envelope.payloadValue, owner: owner)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        do {
            let digest = try await components.conversationRevisions
                .digest(conversationID: query.conversationID) ?? ""
            try envelope.revisionMatches(
                resourceID: ConversationRowRevision.resourceID(conversationID: query.conversationID),
                version: digest)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                           .storeReadFailed)))
        }
        let scanned = RunIngressScan.scan(query.content)
        guard !scanned.isBlank else {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        return await mutateInput(conversationID: query.conversationID, inputID: query.inputID,
                                 expectedVersion: query.expectedInputVersion,
                                 envelope: envelope) { [weak self] in
            guard let self else { return .failure(.internal) }
            let row = $0
            if row.status == .steerPending {
                guard await self.withdrawSteerIfPossible(row) else {
                    return .failure(.steerAlreadyConsumed)
                }
            }
            do {
                try await self.durable.runningInputs.updateContent(
                    id: row.id,
                    content: scanned.sanitizedText
                        .trimmingCharacters(in: .whitespacesAndNewlines))
                return .success(())
            } catch {
                return .failure(.inputNotQueued)
            }
        }
    }

    public func inputRemove(envelope: RunCommandEnvelope) async -> RunDomainReply {
        let owner: OwnerIdentity
        let query: RunInputRemoveQuery
        do {
            owner = try envelope.requireTaskAndRun()
            query = try RunInputRemoveQuery.parse(payload: envelope.payloadValue, owner: owner)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        return await mutateInput(conversationID: query.conversationID, inputID: query.inputID,
                                 expectedVersion: query.expectedInputVersion,
                                 envelope: envelope) { [weak self] in
            guard let self else { return .failure(.internal) }
            if $0.status == .steerPending {
                guard await self.withdrawSteerIfPossible($0) else {
                    return .failure(.steerAlreadyConsumed)
                }
            }
            do {
                try await self.durable.runningInputs.cancel(id: $0.id)
                return .success(())
            } catch {
                return .failure(.inputNotQueued)
            }
        }
    }

    public func inputReorder(envelope: RunCommandEnvelope) async -> RunDomainReply {
        let owner: OwnerIdentity
        let query: RunInputReorderQuery
        do {
            owner = try envelope.requireTaskAndRun()
            query = try RunInputReorderQuery.parse(payload: envelope.payloadValue, owner: owner)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        do {
            try requireNoGuard(conversationID: query.conversationID)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        }
        catch {
            return RunDomainReply(.rejected(RunDomainError(.internalError, .internal)))
        }
        let pending: [PendingUserInput]
        do {
            pending = try await durable.runningInputs.pending(
                conversationID: query.conversationID)
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                           .storeReadFailed)))
        }
        let currentOrder = pending.filter { $0.status == .queued }.map(\.id)
        guard Set(currentOrder) == Set(query.orderedIDs),
              currentOrder.count == query.orderedIDs.count,
              RunWireRevision.queueVersion(orderedIDs: currentOrder)
                == query.expectedQueueVersion else {
            return RunDomainReply(.rejected(RunDomainError(.staleRevision, .revisionMismatch)))
        }
        do {
            try envelope.revisionMatches(
                resourceID: RunWireRevision.pendingQueueResourceID(query.conversationID),
                version: query.expectedQueueVersion)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.staleRevision, .revisionAbsent)))
        }
        do {
            try await durable.runningInputs.reorder(conversationID: query.conversationID,
                                                    orderedIDs: query.orderedIDs)
            return RunDomainReply(.mutationAccepted(detail: [
                "reordered": "true",
                "queueVersion": RunWireRevision.queueVersion(orderedIDs: query.orderedIDs)]))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.staleRevision, .revisionMismatch)))
        }
    }

    private func mutateInput(
        conversationID: UUID, inputID: UUID, expectedVersion: String,
        envelope: RunCommandEnvelope,
        body: @escaping @Sendable (PendingUserInput) async -> Result<Void, RunDomainError.Reason>
    ) async -> RunDomainReply {
        do {
            try requireNoGuard(conversationID: conversationID)
            try envelope.revisionMatches(
                resourceID: RunWireRevision.pendingInputResourceID(inputID),
                version: expectedVersion)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.staleRevision, .revisionAbsent)))
        }
        let row: PendingUserInput?
        do {
            row = try await durable.runningInputs.input(id: inputID)
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                           .storeReadFailed)))
        }
        guard let row, row.conversationID == conversationID else {
            return RunDomainReply(.rejected(RunDomainError(.notFound, .inputMissing)))
        }
        guard RunWireRevision.inputVersion(updatedAt: row.updatedAt) == expectedVersion else {
            return RunDomainReply(.rejected(RunDomainError(.staleRevision, .revisionMismatch)))
        }
        let result = await body(row)
        switch result {
        case .success:
            return RunDomainReply(.mutationAccepted(detail: [
                "inputID": inputID.uuidString, "mutated": "true"]))
        case .failure(let reason):
            return RunDomainReply(.rejected(RunDomainError(.invalidState, reason)))
        }
    }

    /// The ORIGINAL withdrawPendingGuidance ordering rule: a steerPending
    /// row must retract the live runtime steer BEFORE any edit/remove; a
    /// consumed steer can NEVER be rewound (consumedRunID is the durable
    /// exactly-once proof). Restoring `queued` preserves the content first.
    private func withdrawSteerIfPossible(_ row: PendingUserInput) async -> Bool {
        guard row.status == .steerPending else { return true }
        guard row.consumedRunID == nil else { return false }
        let service = row.targetRunID.flatMap { liveServices[$0] }
        if let service {
            guard await service.withdrawSteer(id: row.id) else {
                return false   // consumption won the race — never pretend
            }
        }
        do {
            try await durable.runningInputs.restoreQueued(id: row.id)
            return true
        } catch {
            return false
        }
    }

    // MARK: - run.approval.resolve

    public func resolveApproval(envelope: RunCommandEnvelope) async -> RunDomainReply {
        let owner: OwnerIdentity
        let query: RunApprovalResolveQuery
        do {
            owner = try envelope.requireTaskAndRun()
            query = try RunApprovalResolveQuery.parse(payload: envelope.payloadValue,
                                                      owner: owner)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        guard owners[query.runID] != nil, let service = liveServices[query.runID],
              service.conversationID == query.conversationID else {
            return RunDomainReply(.rejected(RunDomainError(.notFound, .runMissing)))
        }
        let snapshot = await service.snapshot()
        guard let waiting = snapshot.pendingApproval else {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .approvalNotPending)))
        }
        guard waiting.toolCall.id == query.callID else {
            return RunDomainReply(.rejected(RunDomainError(.invalidState,
                                                           .approvalGenerationMismatch)))
        }
        guard RunWireRevision.approvalVersion(requestedAt: waiting.requestedAt)
                == query.expectedApprovalVersion else {
            return RunDomainReply(.rejected(RunDomainError(.staleRevision, .revisionMismatch)))
        }
        do {
            try envelope.revisionMatches(
                resourceID: RunWireRevision.approvalResourceID(callID: waiting.toolCall.id),
                version: query.expectedApprovalVersion)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.staleRevision, .revisionAbsent)))
        }
        // Grant scope is re-DERIVED from the LIVE request (call-bound +
        // descriptor identity); the payload never carries scope/host/paths.
        let decision: ApprovalDecision
        switch query.branch {
        case .deny:
            decision = .deny(reason: query.denyReason ?? "User denied the action")
        case .allow:
            let ownershipChanged = await workspaceOwnershipChanged(
                conversationID: query.conversationID,
                toolName: waiting.toolCall.toolName)
            if ownershipChanged {
                // An unverifiable workspace grant NEVER becomes an allow.
                decision = .deny(reason: "task workspace ownership changed after approval was requested")
            } else {
                decision = .allow(
                    scope: RunApprovalScopeBinding.scope(
                        for: waiting.toolCall,
                        descriptorLookup: { tools.registry.descriptor(named: $0) }),
                    expiresAt: nil)
            }
        }
        let accepted = await service.resolveApproval(decision, for: waiting.toolCall.id)
        guard accepted else {
            let still = await service.snapshot().pendingApproval?.toolCall.id
            if still != waiting.toolCall.id {
                return RunDomainReply(.rejected(RunDomainError(.invalidState, .approvalNotPending)))
            }
            return RunDomainReply(.rejected(RunDomainError(.invalidState,
                                                           .approvalGenerationMismatch)))
        }
        // TRUE exactly when accepted into the run. Card retirement happens
        // ONLY on the durable/live approvalResolved receipt for this same
        // run+call (event.poll); this reply never claims that record
        // already exists.
        return RunDomainReply(.mutationAccepted(detail: [
            "bound": "true", "awaitReceipt": "approvalResolved",
            "callID": waiting.toolCall.id]))
    }

    private func workspaceOwnershipChanged(conversationID: UUID, toolName: String) async -> Bool {
        guard toolName.hasPrefix("workspace.") else { return false }
        // Canonical ownership proof through the ORIGINAL workspace store:
        // missing owner row (or store failure) counts as CHANGED (fail
        // closed — an unverifiable ownership grant is never honored).
        do {
            _ = try await components.workspaceStore.taskPolicy(conversationID: conversationID)
            return false
        } catch {
            return true
        }
    }

    // MARK: - run.policy.update

    public func policyUpdate(envelope: RunCommandEnvelope) async -> RunDomainReply {
        let owner: OwnerIdentity
        let query: RunPolicyUpdateQuery
        do {
            owner = try envelope.requireTaskAndRun()
            query = try RunPolicyUpdateQuery.parse(payload: envelope.payloadValue, owner: owner)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        let current: TaskPolicy
        do {
            current = try await components.workspaceStore.taskPolicy(
                conversationID: query.conversationID)
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                           .storeReadFailed)))
        }
        guard RunWireRevision.taskPolicyVersion(updatedAt: current.updatedAt)
                == query.expectedPolicyVersion else {
            return RunDomainReply(.rejected(RunDomainError(.staleRevision, .revisionMismatch)))
        }
        do {
            try envelope.revisionMatches(
                resourceID: RunWireRevision.taskPolicyResourceID(query.conversationID),
                version: query.expectedPolicyVersion)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.staleRevision, .revisionAbsent)))
        }
        var updated = current
        updated.approvalMode = query.approvalMode.rawValue
        updated.networkAllowed = query.networkAllowed ?? current.networkAllowed
        updated.uploadAllowed = query.uploadAllowed ?? current.uploadAllowed
        updated.credentialsAllowed = query.credentialsAllowed ?? current.credentialsAllowed
        updated.remoteExecutionAllowed = query.remoteExecutionAllowed ?? current.remoteExecutionAllowed
        updated.browserControlAllowed = query.browserControlAllowed ?? current.browserControlAllowed
        updated.updatedAt = Date()
        do {
            try await components.workspaceStore.saveTaskPolicy(updated)
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                           .storeWriteFailed)))
        }
        var applied = "false"
        if let service = liveServices[query.runID],
           service.conversationID == query.conversationID {
            let policy = await assembly.approvalPolicy(for: updated,
                                                       primaryModel: service.primaryModel)
            await service.updateApprovalPolicy(policy)
            applied = "true"
        }
        return RunDomainReply(.mutationAccepted(detail: [
            "appliedToLiveRun": applied,
            "policyVersion": RunWireRevision.taskPolicyVersion(updatedAt: updated.updatedAt)]))
    }

    // MARK: - run.skillcancel

    public func skillCancel(envelope: RunCommandEnvelope) async -> RunDomainReply {
        let owner: OwnerIdentity
        let query: RunSkillCancelQuery
        do {
            owner = try envelope.requireTaskAndRun()
            query = try RunSkillCancelQuery.parse(payload: envelope.payloadValue, owner: owner)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        guard owners[query.runID] != nil else {
            return RunDomainReply(.rejected(RunDomainError(.notFound, .runMissing)))
        }
        guard let port = components.toolCancellation else {
            // RB6 registry binding pending: an honest typed refusal — never
            // an invented Linux job id, never a silent success.
            return RunDomainReply(.rejected(RunDomainError(.capabilityNotUsable,
                                                           .skillCancellationUnbound)))
        }
        let record: RunRecord
        do {
            record = try await durableRecord(query.runID, conversationID: query.conversationID)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                           .storeReadFailed)))
        }
        guard query.expectedState == record.state else {
            return RunDomainReply(.rejected(RunDomainError(.staleRevision, .revisionMismatch)))
        }
        do {
            try envelope.revisionMatches(
                resourceID: RunWireRevision.runResourceID(query.runID),
                version: record.state)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.staleRevision, .revisionAbsent)))
        }
        let cancelled = await port.cancelOwnedTool(runID: query.runID,
                                                   callID: query.callID,
                                                   epoch: epoch)
        guard cancelled else {
            return RunDomainReply(.rejected(RunDomainError(.notFound, .childMissing)))
        }
        return RunDomainReply(.mutationAccepted(detail: ["cancelled": "true"]))
    }

    // MARK: - reads

    public func snapshot(envelope: RunCommandEnvelope) async -> RunDomainReply {
        let owner: OwnerIdentity
        do {
            owner = try envelope.requireTaskAndRun()
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        return await RunSnapshotWireBuilder.build(
            domain: self, components: components,
            query: SnapshotQuery(conversationID: owner.taskID, runID: owner.runID),
            ownership: owners[owner.runID],
            liveService: liveServices[owner.runID])
    }

    public func childList(envelope: RunCommandEnvelope) async -> RunDomainReply {
        let owner: OwnerIdentity
        do {
            owner = try envelope.requireTaskAndRun()
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        return await RunSnapshotWireBuilder.childList(
            domain: self, components: components,
            query: ChildListQuery(conversationID: owner.taskID, parentRunID: owner.runID))
    }

    public func childEntries(envelope: RunCommandEnvelope) async -> RunDomainReply {
        let owner: OwnerIdentity
        let query: ChildEntriesQuery
        do {
            owner = try envelope.requireTaskAndRun()
            query = try ChildEntriesQuery.parse(payload: envelope.payloadValue, owner: owner)
        } catch let error as RunDomainError {
            return RunDomainReply(.rejected(error))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
        }
        return await RunSnapshotWireBuilder.childEntries(domain: self,
                                                         components: components,
                                                         query: query)
    }

    /// Run-scoped continuation reads (snapshot handles). Validation is
    /// owner-bound: a foreign/retired handle is a typed notFound, and the
    /// content itself came from the ORIGINAL stores (never model-staged
    /// bytes). The future shared `content.read` composition binds this
    /// reader (Main typed-carrier decision 6: compose by owner scope, never
    /// overwrite a sibling lane's handler).
    public func readRunContent(handle: String, offset: Int, maxBytes: Int,
                               runID: UUID, conversationID: UUID) async
        -> FacadeContentReader.ReadOutcome {
        guard let owner = contentHandles[handle],
              owner.runID == runID, owner.conversationID == conversationID,
              owner.epoch == epoch else { return .notFound }
        return components.content.read(handle: handle, offset: offset, maxBytes: maxBytes)
    }

    // MARK: - Shared internals (used by RunTrack + lifecycle)

    private func shouldAbortBeforeEffects(_ runID: UUID) -> Bool {
        guard let ownership = owners[runID] else { return true }
        return ownership.cancelRequested
    }

    private func refuseLaunch(runID: UUID, error: RunDomainError) -> RunDomainReply {
        if var ownership = owners[runID] {
            if let token = ownership.ownedTokens.removeValue(
                forKey: RuntimeOwnedWorkKind.run.rawValue) {
                RuntimeOwnedWorkRegistry.shared.detach(token)
            }
            unregister(ownership)
        }
        return RunDomainReply(.rejected(error))
    }

    /// C1: durable marking of an abandoned committed launch through the
    /// RUN'S OWN bundle (ordinary → SQLite store; temporary → the RAM
    /// store, which is the authority there), using ONLY the original APIs
    /// and a `preparing`-scoped state CAS (never overwriting a real
    /// terminal the runtime already published). The failed stage stays
    /// observable through the run's own event thread.
    func markCommittedLaunchAbandoned(runID: UUID, reason: String,
                                      bundle: RunPersistenceBundle) async {
        do {
            guard let record = try await bundle.runs.run(id: runID),
                  record.state == "preparing" else { return }
            try await bundle.runs.updateRunState(id: runID, state: "failed", endedAt: Date())
            _ = try await bundle.runs.appendEvent(
                runID: runID, kind: .status,
                payloadJSON: Self.jsonString(["state": "failed", "reason": reason]))
            _ = try await bundle.runs.appendEvent(
                runID: runID, kind: .terminal,
                payloadJSON: Self.jsonString(["terminal": "failed", "recoverable": "true"]))
            lastObservedState[runID] = "failed"
        } catch {
            // Marking failed: the state remains `preparing`; the retry path
            // and the bootstrap recovery (next open) handle it honestly.
        }
    }

    /// The single retirement path. The caller runs AFTER the final durable
    /// writes are visible. Detaches exact tokens LAST, retires the delegate
    /// registry and consumer, feeds the P8 terminal-success hook exactly
    /// once, and clears ownership. A late callback for a retired/foreign
    /// epoch re-registers nothing.
    func retire(runID: UUID, terminalSucceeded: Bool, feedTerminal: Bool) async {
        guard let ownership = owners[runID] else { return }
        await tools.retireDelegate(runID: runID)
        if let token = ownership.consumerToken {
            components.events.detachConsumer(token)
        }
        // Release every continuation handle owned by this run.
        for handle in contentHandleOrder where contentHandles[handle]?.runID == runID {
            components.content.release(handle: handle)
            contentHandles[handle] = nil
        }
        contentHandleOrder.removeAll { contentHandles[$0] == nil }
        // Detach the remaining exact owned tokens (tool/child/run) — the
        // final writes above already landed, so this is real completion.
        for token in ownership.ownedTokens.values {
            RuntimeOwnedWorkRegistry.shared.detach(token)
        }
        unregister(ownership)
        // Honest late-cancel bookkeeping (bounded): remember the id this
        // generation retired so a cancel arriving after retirement answers
        // alreadyRequested rather than runMissing.
        if !retiredRunSet.contains(runID) {
            retiredRunSet.insert(runID)
            retiredRuns.append(runID)
            if retiredRuns.count > 8_192 {
                let evicted = retiredRuns.removeFirst()
                retiredRunSet.remove(evicted)
            }
        }
        RunTaskBox.clear(runID: runID)
        lastObservedState[runID] = nil
        // Intelligence hook #2: the ACTUAL terminal truth for an ORDINARY
        // run, exactly once per run identity (restart never re-feeds an
        // old epoch). The feed is DISPATCHED as a real owned maintenance
        // Task (lease acquired now, released when the handler returns) —
        // retirement itself NEVER blocks on a stalled source-index /
        // organize / generation feed, so the terminal is visible and the
        // ownership tokens settle immediately (RUN-S3 repair). A temporary
        // identity never feeds anything.
        if feedTerminal, ownership.identity == .ordinary,
           !feedTerminalsDone.contains(runID),
           components.intelligenceFeed != nil {
            feedTerminalsDone.insert(runID)
            dispatchIntelligenceFeed(
                runID: runID,
                .terminal(RunIntelligenceCompletionEvent(
                    rootEpoch: epoch, runID: runID, conversationID: ownership.conversationID,
                    temporaryAtStart: false, frozenTemporaryRun: false,
                    ordinarySurface: true, succeeded: terminalSucceeded)))
        }
    }

    /// Launch-call failure landing after the durable commit: the blocking
    /// service call threw. If the runtime already reached its own terminal
    /// (the track task observes it), this defers to that retirement. The
    /// run's OWN bundle performs the marking and record read.
    func launchCallFailed(runID: UUID, error: Error) async {
        guard let ownership = owners[runID] else { return }
        let bundle = ownership.bundle
        let record = try? await bundle.runs.run(id: runID)
        if let record, !Self.activeRunStates.contains(record.state) {
            return   // terminal already durable; track task retires
        }
        await markCommittedLaunchAbandoned(
            runID: runID,
            reason: error is CancellationError ? "cancelledDuringStart" : "startCallFailed",
            bundle: bundle)
        await retire(runID: runID, terminalSucceeded: false, feedTerminal: false)
    }

    /// Live P8 feed leases for one conversation (the delete drain waits
    /// for this to reach zero — the REAL completion proof, never a timer).
    /// The acquire/release pair lives in RuntimeFacadeRunAssembly.swift
    /// (RUN-S3 repair: lease acquired before the dispatching await, held
    /// by a real owned maintenance Task until the handler returns).
    func feedLeaseCount(conversationID: UUID) -> Int {
        feedLeases[conversationID]?.count ?? 0
    }

    /// Feed leases that THIS drain watched through to real handler return.
    /// The release hook removed each entry when the handler returned; a
    /// monotonic per-conversation counter records how many were observed
    /// (pruned at the trusted terminal when no guard is open).
    func drainCompletedFeedLeaseCount(conversationID: UUID) -> Int {
        feedDeliveredObserved[conversationID] ?? 0
    }

    internal var feedDeliveredObserved: [UUID: Int] = [:]

    func durableRecord(_ runID: UUID, conversationID: UUID) async throws -> RunRecord {
        // Wire control paths (cancel/retry/skillcancel) are ordinary-only:
        // a temporary run is cancelled through the RB5 port's injected
        // closure (T5), never through these wire handlers.
        let record: RunRecord?
        do { record = try await durable.runs.run(id: runID) }
        catch { throw RunDomainError(.persistenceUnavailable, .storeReadFailed) }
        guard let record, record.conversationID == conversationID else {
            throw RunDomainError(.notFound, .runMissing)
        }
        return record
    }

    func isAwaitingDependency(record: RunRecord) async -> Bool {
        guard record.state == "checkpointed" else { return false }
        guard let checkpoint = try? await components.checkpoints.load(runID: record.id),
              case .checkpointed(let reference) = checkpoint.state else { return false }
        return (reference.reason ?? "").hasPrefix(FloeAgentRuntime.dependencyWaitReasonPrefix)
    }

    /// Conversation history for one run read from the RUN'S OWN bundle
    /// (RUN-S2 repair): ordinary → the durable conversation store with the
    /// bundle's compaction intelligence; temporary → the session's RAM
    /// store with no compaction projection (no memory feed exists there).
    func loadRunHistory(conversationID: UUID, excludingRun runID: UUID,
                        bundle: RunPersistenceBundle) async throws
        -> [ConversationMessage] {
        let messages: [PersistedMessage]
        do {
            messages = try await bundle.conversations.messages(conversationID: conversationID)
        } catch {
            throw RunDomainError(.persistenceUnavailable, .storeReadFailed)
        }
        // The CURRENT run's user turn was already committed by the original
        // prepare; seeding it again would double the turn.
        var history = messages
            .filter { $0.runID != runID }
            .map { message in
                ConversationMessage(id: message.id, role: message.role,
                                    content: message.content,
                                    createdAt: message.createdAt,
                                    images: [],
                                    reasoningContent: nil)
            }
        if let intelligence = bundle.intelligence {
            history = (try? await intelligence.applyingCompactions(
                history, conversationID: conversationID)) ?? history
        }
        return history
    }

    /// Trusted bounded image parts for the launch's reserved image leases:
    /// bytes come ONLY from the validated app-private staged data through
    /// the bound loader port — never a wire binary, a URI authority or a
    /// model-chosen path. Unbound callers are refused BEFORE any IO at the
    /// reservation stage, so this only ever sees a bound loader.
    func loadLaunchImages(_ leases: [RunAttachmentLease]) async throws
        -> [ConversationImagePart] {
        // No image handle in this launch: the loader is irrelevant and its
        // absence must NOT refuse an ordinary text-only launch (the typed
        // unbound refusal stays for launches that really carry images).
        guard leases.contains(where: { $0.ref.kind == .image }) else { return [] }
        guard let loader = components.stagedImages else {
            // Defensive: reservation admission already refuses unbound.
            throw RunDomainError(.capabilityNotUsable, .imageLoaderUnbound)
        }
        var parts: [ConversationImagePart] = []
        for lease in leases where lease.ref.kind == .image {
            do {
                parts.append(try await loader.imagePart(
                    for: lease, maxBytes: Self.maximumImagePartBytes))
            } catch let error as RunDomainError {
                throw error
            } catch {
                throw RunDomainError(.capabilityNotUsable, .imageLoaderUnbound)
            }
        }
        return parts
    }

    /// Bounded image payload ceiling for one staged image (the loader
    /// enforces it; the wire/model never sees the raw path).
    static let maximumImagePartBytes = 8 * 1024 * 1024

    /// RESERVE one exact owned lease per staged handle for THIS launch
    /// (RUN-S4 repair). A handle already reserved for another in-flight
    /// launch is a typed duplicateInFlight refusal — never a silent merge.
    /// iOS-only bookmark storage is not an Android ingress authority;
    /// validated app-private refs only.
    private func reserveStagedHandles(_ handles: [String],
                                      conversationID: UUID?,
                                      runID: UUID) async throws
        -> [RunAttachmentLease] {
        guard !handles.isEmpty else { return [] }
        guard let authority = components.stagedAttachments else {
            // Staging authority unbound: refuse ANY staged handle before
            // the transaction. Staged files themselves stay untouched.
            throw RunDomainError(.capabilityNotUsable, .payloadInvalid)
        }
        var leases: [RunAttachmentLease] = []
        leases.reserveCapacity(handles.count)
        do {
            for handle in handles {
                let lease = try await authority.reserve(
                    handle: handle, conversationID: conversationID,
                    runID: runID, epoch: epoch)
                // The ORIGINAL ref shape is the only durable form; a ref
                // claiming iOS security-scoped bookmarks is refused here —
                // Android consumes app-private relativePath refs only.
                switch lease.ref.storage {
                case .securityScopedBookmark:
                    throw RunDomainError(.unsupportedRole, .payloadInvalid)
                case .none, .applicationSupport:
                    break
                }
                leases.append(lease)
            }
        } catch let error as RunDomainError {
            // Admission interleave failed: this launch owns nothing; drop
            // every lease it DID acquire (staged bytes preserved).
            await releaseReservations(leases)
            throw error
        } catch let error as RunStagingError {
            await releaseReservations(leases)
            throw Self.mapStagingError(error)
        } catch {
            await releaseReservations(leases)
            throw RunDomainError(.persistenceUnavailable, .storeReadFailed)
        }
        return leases
    }

    /// Release reservations for a launch that failed BEFORE the atomic
    /// commit. The staged BYTES are preserved for the compose surface —
    /// only the launch's exclusive claim is dropped; after a real commit
    /// this is never called (commitAcknowledged owns the bytes instead).
    private func releaseReservations(_ leases: [RunAttachmentLease]) async {
        guard let authority = components.stagedAttachments else { return }
        for lease in leases {
            await authority.releaseReservation(lease, epoch: epoch)
        }
    }

    /// Acknowledge the ORIGINAL atomic commit exactly once per lease with
    /// the REAL committed ids. After this call the staged bytes belong to
    /// the committed message; the authority must never discard them.
    private func commitReservation(_ lease: RunAttachmentLease,
                                   conversationID: UUID,
                                   messageID: UUID) async {
        guard let authority = components.stagedAttachments else { return }
        await authority.commitAcknowledged(lease, conversationID: conversationID,
                                           messageID: messageID, epoch: epoch)
    }

    /// Closed mapping of the staging authority's typed errors.
    static func mapStagingError(_ error: RunStagingError) -> RunDomainError {
        switch error {
        case .unbound:
            return RunDomainError(.capabilityNotUsable, .payloadInvalid)
        case .handleUnknown:
            return RunDomainError(.notFound, .payloadInvalid)
        case .generationFenced:
            return RunDomainError(.sessionFenced, .generationRetired)
        case .handleAlreadyReserved:
            return RunDomainError(.duplicateInFlight, .launchAlreadyInFlight)
        }
    }

    /// Queue-time document resolution (the durable queue row carries the
    /// ORIGINAL ref; consumption stays the service's exactly-once path).
    /// Image handles on the QUEUE surface wait for the attachment owner's
    /// consumption-time loader semantics (typed refusal, never a silent
    /// binary into a durable row); the LAUNCH surface carries the real
    /// image seam above.
    private func resolveStagedHandles(_ handles: [String],
                                      conversationID: UUID?) async throws
        -> [AttachmentRef] {
        guard !handles.isEmpty else { return [] }
        guard let authority = components.stagedAttachments else {
            throw RunDomainError(.capabilityNotUsable, .payloadInvalid)
        }
        var resolved: [AttachmentRef] = []
        resolved.reserveCapacity(handles.count)
        for handle in handles {
            do {
                let ref = try await authority.resolve(handle: handle,
                                                      conversationID: conversationID,
                                                      epoch: epoch)
                switch ref.storage {
                case .securityScopedBookmark:
                    throw RunDomainError(.unsupportedRole, .payloadInvalid)
                case .none, .applicationSupport:
                    break
                }
                if ref.kind == .image {
                    throw RunDomainError(.capabilityNotUsable, .payloadInvalid)
                }
                resolved.append(ref)
            } catch let error as RunDomainError {
                throw error
            } catch let error as RunStagingError {
                throw Self.mapStagingError(error)
            }
        }
        return resolved
    }

    /// Typed SQLite primary result code for a GRDB DatabaseError, else nil.
    /// Numeric codes ONLY — never message/sql/args (Main cloud-diagnosis
    /// contract).
    static func storePrimaryCode(of error: Error) -> Int32? {
        guard let databaseError = error as? DatabaseError else { return nil }
        return databaseError.resultCode.rawValue
    }

    /// Typed SQLite extended result code for a GRDB DatabaseError, else nil.
    static func storeExtendedCode(of error: Error) -> Int32? {
        guard let databaseError = error as? DatabaseError else { return nil }
        return databaseError.extendedResultCode.rawValue
    }

    private func mapPrepareError(_ error: Error,
                                 phase: RunDomainError.Phase? = nil) -> RunDomainError {
        func withStoreCodes(_ domain: RunDomainError) -> RunDomainError {
            RunDomainError(domain.code, domain.reason, phase: phase ?? domain.phase,
                           storePrimaryCode: Self.storePrimaryCode(of: error),
                           storeExtendedCode: Self.storeExtendedCode(of: error))
        }
        if let domain = error as? RunDomainError {
            return domain.addingPhase(phase)
        }
        if let floe = error as? FloeError {
            switch floe {
            case .notFound(let what):
                return withStoreCodes(RunDomainError(.notFound, what.contains("conversation")
                                        ? .conversationMissing : .runMissing))
            case .validationFailed(let detail):
                if detail.contains("queue") { return withStoreCodes(RunDomainError(.invalidState, .queueFull)) }
                return withStoreCodes(RunDomainError(.invalidState, .payloadInvalid))
            case .invalidConfiguration:
                return withStoreCodes(RunDomainError(.needsConfiguration, .providerDisabled))
            case .storageCorrupted:
                return withStoreCodes(RunDomainError(.persistenceUnavailable, .storeReadFailed))
            default:
                return withStoreCodes(RunDomainError(.persistenceUnavailable, .storeWriteFailed))
            }
        }
        return withStoreCodes(RunDomainError(.persistenceUnavailable, .storeWriteFailed))
    }

    /// JSONValue → JSONSerialization-compatible tree (measurement and
    /// future carrier encoding share this exact conversion).
    static func unwrap(_ value: SettingsDomainV1.JSONValue) -> Any {
        switch value {
        case .object(let object):
            return object.mapValues { unwrap($0) }
        case .array(let array):
            return array.map { unwrap($0) }
        case .string(let text): return text
        case .integer(let number): return number
        case .fractional(let number): return number
        case .boolean(let flag): return flag
        case .null: return NSNull()
        }
    }

    /// Bounded durable child summary — the wire identity for `child.list`
    /// and snapshot children arrays (durable graph; never UI-emulated).
    static func childJSON(_ child: ChildRunRecord) -> [String: SettingsDomainV1.JSONValue] {
        [
            "childRunID": .string(child.id.uuidString),
            "parentRunID": .string(child.parentRunID.uuidString),
            "rootRunID": .string(child.rootRunID.uuidString),
            "kind": .string(child.kind),
            "taskSummary": .string(child.taskSummary),
            "state": .string(child.state.rawValue),
            "terminal": .boolean(child.state.isTerminal),
            "iterationCount": .integer(Int64(child.iterationCount)),
            "startedAt": .string(RunWireDate.encode(child.startedAt)),
            "endedAt": child.endedAt.map { .string(RunWireDate.encode($0)) } ?? .null,
            "resultSummary": child.resultSummary.map { .string(boundText($0, 512)) } ?? .null,
        ]
    }

    static func boundText(_ value: String, _ maxBytes: Int) -> String {
        let bytes = Array(value.utf8)
        guard bytes.count > maxBytes else { return value }
        var length = maxBytes
        while length > 0, (bytes[length - 1] & 0xC0) == 0x80 { length -= 1 }
        return String(decoding: bytes.prefix(length), as: UTF8.self)
    }

    static func jsonString(_ object: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

}

// MARK: - Owned Task dispatch (launch + track wiring)

extension FacadeRunDomain {
    /// Dispatches the two REAL owned Tasks for one prepared run. The launch
    /// Task performs the blocking original start/resume call; the track
    /// Task owns the live projection + durable-window refresh and closes
    /// ownership at real settlement.
    func launchTaskAttach(prepared: PreparedRun, service: ConversationRunService,
                          domain: FacadeRunDomain) {
        let runID = prepared.run.id
        let goal = prepared.run.goal
        // The run's OWN bundle (never the durable singleton as fallback) is
        // frozen into the track; a vanished ownership means the launch was
        // already settled and nothing dispatches.
        guard let bundle = owners[runID]?.bundle else { return }
        let task = Task { [weak domain, service] in
            do {
                try await service.startPrepared(goal: goal)
            } catch {
                await domain?.launchCallFailed(runID: runID, error: error)
            }
        }
        if var ownership = owners[runID] {
            ownership.launchTaskRef(task)
            register(ownership)
        }
        ownershipStartTrack(domain: domain, service: service, runID: runID,
                            conversationID: prepared.conversation.id, bundle: bundle)
    }

    func ownedLaunchTasks(preparedRunID runID: UUID, service: ConversationRunService,
                          goal: String, resumeFrom checkpoint: AgentCheckpoint?) {
        let conversationID = (owners[runID]?.conversationID) ?? service.conversationID
        guard let bundle = owners[runID]?.bundle else { return }
        let task = Task { [weak self, service] in
            do {
                if let checkpoint {
                    try await service.resumePrepared(from: checkpoint)
                } else {
                    // Bounded durable-history fallback: the ORIGINAL run is
                    // continued WITHOUT a second user turn.
                    try await service.startPrepared(goal: goal)
                }
            } catch {
                await self?.launchCallFailed(runID: runID, error: error)
            }
        }
        if var ownership = owners[runID] {
            ownership.launchTaskRef(task)
            register(ownership)
        }
        ownershipStartTrack(domain: self, service: service, runID: runID,
                            conversationID: conversationID, bundle: bundle)
    }

    func ownershipStartTrack(domain: FacadeRunDomain, service: ConversationRunService,
                             runID: UUID, conversationID: UUID,
                             bundle: RunPersistenceBundle) {
        let track = RunTrack.start(domain: domain, service: service, runID: runID,
                                   conversationID: conversationID, epoch: epoch,
                                   bundle: bundle, components: components)
        if var ownership = owners[runID] {
            ownership.trackTaskRef(track)
            register(ownership)
        }
    }
}

extension RunOwnership {
    // Task handles live OUTSIDE the value struct's identity checks (in the
    // process-bounded RunTaskBox below), so RunOwnership stays a comparable
    // value type while the drain still reaches the REAL owned Tasks.
    mutating func launchTaskRef(_ task: Task<Void, Never>) {
        RunTaskBox.put(runID: runID, value: task)
    }
    mutating func trackTaskRef(_ task: Task<Void, Never>) {
        RunTaskBox.putTrack(runID: runID, value: task)
    }
    var ownedTaskHandles: (launch: Task<Void, Never>?, track: Task<Void, Never>?) {
        (RunTaskBox.take(runID: runID), RunTaskBox.track(runID: runID))
    }
}

/// Process-bounded Task box keyed by runID, so `RunOwnership` remains a
/// comparable value type (Equatable) while the drain still reaches the
/// REAL owned Tasks. Entries clear at retirement; a foreign/late write is
/// epoch-checked by the caller.
enum RunTaskBox {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var launches: [UUID: Task<Void, Never>] = [:]
    nonisolated(unsafe) private static var tracks: [UUID: Task<Void, Never>] = [:]

    static func put(runID: UUID, value: Task<Void, Never>?) {
        lock.lock(); launches[runID] = value; lock.unlock()
    }
    static func take(runID: UUID) -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }; return launches[runID]
    }
    static func putTrack(runID: UUID, value: Task<Void, Never>?) {
        lock.lock(); tracks[runID] = value; lock.unlock()
    }
    static func track(runID: UUID) -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }; return tracks[runID]
    }
    static func clear(runID: UUID) {
        lock.lock(); launches[runID] = nil; tracks[runID] = nil; lock.unlock()
    }
}

// MARK: - The concrete conversation-delete lifecycle adapter (CH-R2/R3)

/// The REAL implementation of the RB3-repair `ConversationDeletionLifecycle`
/// port (successor API job-aed8622f70a54f02; Main-verified source, not
/// compiled proof), composed with the reviewed RB1 owned-work registry.
/// Exact semantics:
/// * `beginDeletionFence` is atomic — register the operation guard (scoped
///   launch epoch invalidated + deleting guard keyed by operationID, NEW
///   launches refused) with a REAL nonblank `work:v1:` authority receipt,
///   or throw with NO guard; a second live guard throws `.fenceHeld`; an
///   old receipt is never reused.
/// * `drainOwnedWork(fence:)` validates the EXACT fence, waits for the
///   TARGET conversation's committed pending launches to settle,
///   cancels/awaits ONLY its owned run/childRun/tool/final-write work plus
///   the real P8 maintenance leases (never conversation B, never the
///   deletion fence's own receipt), and returns exact tokens + the real
///   `isAttached` truth. Failure/timeout retains ownership and throws;
///   nothing detaches on caller cancel.
/// * `abortDeletionFence`/`commitDeletionFence` settle ONLY the exact
///   current fence: old/already-settled → `.alreadySettled`, foreign →
///   `.refusedForeignToken`. Abort releases only the guard; target owned
///   work detaches only at REAL completion. Commit runs only after the
///   original DB commit and clears residual bookkeeping; unavailable
///   authority answers `.unavailable` honestly.
/// * `endCountsByKind` carries the GLOBAL epoch registry snapshot as
///   diagnostics only (root retirement keeps that gate, reviewed RB1); the
///   per-conversation blocking truth is `targetOwnedWork` +
///   `pendingLaunchCount == 0` with `RuntimeOwnedWorkRegistry
///   .shared.isAttached(_:)` cross-checked per exact token.
public actor RunDomainDeletionLifecycle: ConversationDeletionLifecycle {
    private let domain: FacadeRunDomain
    private let registry = RuntimeOwnedWorkRegistry.shared

    public init(domain: FacadeRunDomain) {
        self.domain = domain
    }

    public func beginDeletionFence(conversationID: UUID, epoch: UInt64,
                                   operationID: UUID) async throws
        -> ConversationDeletionFence {
        try await domain.beginDeleteGuard(conversationID: conversationID,
                                          epoch: epoch, operationID: operationID)
    }

    public func drainOwnedWork(fence: ConversationDeletionFence) async throws
        -> ConversationQuiescenceReport {
        // Validate the EXACT fence first (a foreign token must never drive
        // another operation's drain).
        guard let state = await domain.fenceGuardState(fence.conversationID),
              state.fence == fence else {
            throw ConversationDeletionLifecycleFailure.fenceTokenRefused
        }
        // Snapshot target ownership BEFORE cancellation so every exact
        // token that gets detached during the window is reportable.
        let owned = await domain.owners(conversationID: fence.conversationID)
        var cancelled = 0
        for ownership in owned {
            if ownership.phase == .handedOff,
               let service = await domain.liveService(ownership.runID) {
                await service.cancel()
                cancelled += 1
            } else {
                _ = await domain.markLaunchCancelRequested(ownership.runID)
            }
        }
        let childReconciled = owned.reduce(0) { $0 + $1.pendingChildRunIDs.count }
        var drained = owned.reduce(0) { $0 + $1.ownedTokens.count }
        let launchesAwaited = owned.count
        // Await REAL settlement only: exact tokens for THIS conversation
        // must report isAttached false, and pending launches must reach
        // their honest C0/C1 outcomes. No timer release; caller
        // cancellation is NOT quiescence (ownership stays attached and the
        // guard survives for the caller to abort).
        while true {
            let remaining = await domain.owners(conversationID: fence.conversationID)
            let liveTokensPending = remaining.contains { ownership in
                ownership.ownedTokens.values.contains { registry.isAttached($0) }
            }
            let feedsPending = await domain.feedLeaseCount(
                conversationID: fence.conversationID) > 0
            let pendingLaunches = remaining.contains {
                $0.phase == .admitting || $0.phase == .prepared
            }
            if !liveTokensPending, !feedsPending, !pendingLaunches, remaining.isEmpty {
                break
            }
            if Task.isCancelled {
                throw ConversationDeletionLifecycleFailure.drainUnavailable("callerCancelled")
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // Exact per-conversation evidence: all tokens observed for the
        // target during this drain, cross-checked live. The deletion
        // fence's OWN receipt is excluded by construction (it is tracked
        // in the guard state, never in ownership/feed maps).
        let evidenceTokens = await domain.drainEvidenceTokens(
            conversationID: fence.conversationID)
        var observations: [ConversationOwnedWorkObservation] = []
        for token in evidenceTokens {
            observations.append(ConversationOwnedWorkObservation(
                conversationID: fence.conversationID,
                token: token,
                stillAttached: registry.isAttached(token)))
        }
        guard observations.allSatisfy({ !$0.stillAttached }) else {
            throw ConversationDeletionLifecycleFailure.reportUnavailable("attachedEvidence")
        }
        let pendingLaunchCount = await domain.owners(conversationID: fence.conversationID)
            .filter { $0.phase == .admitting || $0.phase == .prepared }
            .count
        guard pendingLaunchCount == 0 else {
            throw ConversationDeletionLifecycleFailure.reportUnavailable("pendingLaunches")
        }
        // Global counts: diagnostics ONLY (never a per-conversation block).
        let global = registry.countsByKind(for: fence.epoch)
        return ConversationQuiescenceReport(
            conversationID: fence.conversationID,
            launchesFenced: true,
            inFlightLaunchesAwaited: launchesAwaited,
            runServicesCancelled: cancelled,
            ownedTasksDrained: drained,
            childRunsReconciled: childReconciled,
            endCountsByKind: global,
            countsEpoch: fence.epoch,
            targetOwnedWork: observations,
            pendingLaunchCount: pendingLaunchCount)
    }

    public func abortDeletionFence(_ fence: ConversationDeletionFence) async
        -> ConversationDeletionFenceSettlement {
        await domain.abortDeleteGuard(fence)
    }

    public func commitDeletionFence(_ fence: ConversationDeletionFence) async
        -> ConversationDeletionFenceSettlement {
        await domain.commitDeleteGuard(fence)
    }
}

extension FacadeRunDomain {
    func markLaunchCancelRequested(_ runID: UUID) -> Bool {
        guard var ownership = owners[runID] else { return false }
        ownership.cancelRequested = true
        register(ownership)
        return true
    }

    /// Every exact token observed for a conversation across launches,
    /// tools, children and P8 maintenance during the delete window
    /// (evidence source for the quiescence report; entries are pruned at
    /// fence commit).
    func drainEvidenceTokens(conversationID: UUID) -> [RuntimeOwnedWorkToken] {
        var seen = Set<String>()
        var out: [RuntimeOwnedWorkToken] = []
        for token in (drainEvidence[conversationID] ?? []) + (feedEvidence[conversationID] ?? [])
                + owners(conversationID: conversationID).flatMap(\.ownedTokens.values) {
            if seen.insert(token.receipt).inserted { out.append(token) }
        }
        return out
    }

    func recordDrainEvidence(conversationID: UUID, token: RuntimeOwnedWorkToken) {
        drainEvidence[conversationID, default: []].append(token)
    }

    func recordFeedEvidence(conversationID: UUID, token: RuntimeOwnedWorkToken) {
        feedEvidence[conversationID, default: []].append(token)
    }

    /// TRUSTED validation of one delivered P8 lease (MEM-P8-LIFETIME): the
    /// exact token must still be the SAME conversation lease held by THIS
    /// generation, registry-attached, with no delete guard, no global
    /// admission fence and no retirement. Used by the real personalization
    /// handler immediately before its first mutation; never a boolean-only
    /// pre-await proxy (the handler re-queries live Run state).
    func validatePersonalizationEventLease(
        _ lease: PersonalizationEventOperationLease) -> Bool {
        guard lease.rootEpoch == epoch, !retirementFenced,
              globalFence == nil,
              deleteGuards[lease.conversationID] == nil,
              let token = feedLeases[lease.conversationID]?[lease.token],
              token.receipt == lease.token,
              token.kind == .conversation,
              token.epoch == epoch,
              RuntimeOwnedWorkRegistry.shared.isAttached(token) else {
            return false
        }
        return true
    }
}
