// SPDX-License-Identifier: MPL-2.0
//
// RB-1 runtime bootstrap — trusted root, owner identity and the ONE original
// store cluster.
//
// Direction (Main RB1 admission, runtime-facade-contract service-map rev2):
// one MainActor-free Swift actor owns ONE actual original `DatabaseManager`
// plus the real original SQLite store/service objects the approved map lists.
// The exact app-private storage root is supplied by the trusted Android
// Application/service host over the internal JNI seam — NEVER by a model,
// tool, imported document or command envelope. There is no host interpreter,
// no first-project/temporary fallback, no RAM business DB and no second
// durable store. The original 46 migrations and pinned schema are the only
// schema authority; this package adds none.
//
// This source is NOT compiled and NOT executed by the source-authoring
// package; see the private HANDOFF.md for the serialized qualification lane.
import Foundation
import Crypto
import GRDB
import FloePersistence
import FloeAgentRuntime
// D04 (job-3135f83ef97c4a21): the trusted run-output store binding, the
// durable cleanup queue and the readiness retry pass are the shared core
// (FloeTools) surface; the owned persistent root of THIS generation is the
// only artifact authority Android publishes/cleans under.
import FloeTools

// MARK: - Typed bootstrap error vocabulary

/// Closed, path-free typed codes shared by mailbox, pumps, owner and ABI.
/// Diagnostics across JNI/prompt/log use ONLY these identifiers — never a
/// raw storage path, envelope content or secret material.
public enum RuntimeFacadeCode: String, Sendable, Codable, CaseIterable {
    // Trusted host / identity admission
    case invalidStorageRoot
    case invalidOwnerToken
    case epochNotNewer
    case ownerMismatch
    case alreadyDraining
    case notInstalled
    case alreadyStopped
    // Owned-store bootstrap
    case storeOpenFailed
    case migrationFailed
    case schemaVersionMismatch
    case recoveryFailed
    case checkpointDirectoryFailed
    // Bounded mailbox
    case mailboxSaturated
    case mailboxClosed
    case envelopeTooLarge
    case duplicateCorrelation
    case receiptSaturated
    // Domain admission (fail-closed until the real package lands)
    case domainNotBound
    case ordinaryRuntimeBlocked
    // Pump / cursor / frame
    case effectReceiptNotFound
    case effectReceiptExpired
    case resyncRequired
    case durableWindowAbsent
    case runRecordNotFound
    case consumerDetached
    case frameBudgetExceeded
    // Content handles
    case contentHandleNotFound
    case contentHandleExpired
    case contentSaturated
    case contentOffsetInvalid
    // Lifecycle
    case shutdownTimeout
    // RB1-M5: conflicting concurrent owner-actor lifecycle call
    case lifecycleConflict
    // RB1-M2: same-owner newer-epoch attempt while owned work lives
    case rebindWhileOwned
    case `internal`
}

/// JNI-visible numeric statuses for the runtime owner ABI. Distinct from the
/// frozen gateway mailbox -1xx space; the runtime seam owns -2xx.
public enum RuntimeFacadeStatus {
    public static let ok: Int32 = 0
    public static let idempotentOk: Int32 = 1
    public static let invalidStorageRoot: Int32 = -201
    public static let invalidOwnerToken: Int32 = -202
    public static let epochNotNewer: Int32 = -203
    public static let ownerMismatch: Int32 = -204
    public static let alreadyDraining: Int32 = -205
    public static let bootstrapSaturated: Int32 = -206
    public static let notInstalled: Int32 = -207
    public static let alreadyStopped: Int32 = -208
    public static let draining: Int32 = -209
    public static let rebindWhileOwned: Int32 = -210
    public static let bufferTooSmall: Int32 = -106   // shared ASCII-copy rule
    public static let invalidArguments: Int32 = -105  // shared shape rule
    public static let `internal`: Int32 = -299

    public static func code(for error: RuntimeFacadeCode) -> Int32 {
        switch error {
        case .invalidStorageRoot: return invalidStorageRoot
        case .invalidOwnerToken: return invalidOwnerToken
        case .epochNotNewer: return epochNotNewer
        case .ownerMismatch: return ownerMismatch
        case .alreadyDraining: return alreadyDraining
        case .notInstalled: return notInstalled
        case .alreadyStopped: return alreadyStopped
        case .rebindWhileOwned: return rebindWhileOwned
        case .mailboxSaturated, .receiptSaturated, .contentSaturated: return bootstrapSaturated
        default: return Self.`internal`
        }
    }
}

// MARK: - Trusted storage root

/// Validated app-private absolute storage root supplied by the trusted host.
/// Validation is path-syntax only; existence/creation happens on the owner
/// actor (off the JNI and UI threads). A model envelope can never select or
/// widen this root.
public struct RuntimeStorageRoot: Sendable, Equatable, Hashable {
    /// The standardized absolute directory path. Original DB filename and
    /// checkpoint directory are derived, never caller-chosen
    /// (`floe.sqlite` — proven by AppEnvironment.swift:1631).
    public let path: String
    /// Short non-reversible fingerprint for diagnostics. The raw root path
    /// never enters status JSON, prompts or logs.
    public let fingerprint: String

    public init?(validatingAbsoluteDirectory path: String) {
        guard !path.isEmpty, path.hasPrefix("/"),
              path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { $0 == "\u{0}" }),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        // Accept the common trailing-slash spelling exactly once; reject any
        // other non-normalized form (traversal, doubled slashes, dot dirs).
        if path.hasSuffix("/") {
            guard standardized != "/", path == standardized + "/" else { return nil }
        } else {
            guard path == standardized else { return nil }
        }
        guard standardized != "/" else { return nil }
        self.path = standardized
        let digest = SHA256.hash(data: Data(standardized.utf8))
        self.fingerprint = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    public var databaseURL: URL {
        URL(fileURLWithPath: path).appendingPathComponent("floe.sqlite")
    }

    public var checkpointDirectoryURL: URL {
        URL(fileURLWithPath: path).appendingPathComponent("checkpoints")
    }

    /// D04 (job-3135f83ef97c4a21): the FLOE-owned artifact store root for
    /// this persistent generation — the Android stand-in for iOS's
    /// `<Application Support>/FloeAgent`. It lives INSIDE the already
    /// validated owned root (never `$HOME`, never a temporary directory),
    /// holds the `RunOutputs/` snapshot namespace and the durable
    /// `RunOutputCleanupRequests/` tombstones, and is the only root the
    /// trusted composition may bind into `RuntimeFacadeRunOutput`.
    public var artifactStoreURL: URL {
        URL(fileURLWithPath: path).appendingPathComponent("FloeAgent", isDirectory: true)
    }
}

/// Process-local owner identity. The token is a host-generated random hex
/// string (never persisted, never a credential); it exists so a rebind from
/// a different owner instance is a typed rejection, not a silent takeover.
public struct RuntimeOwnerIdentity: Sendable, Equatable {
    public let root: RuntimeStorageRoot
    public let token: String
    public let epoch: UInt64

    public init?(root: RuntimeStorageRoot, token: String, epoch: UInt64) {
        guard epoch > 0 else { return nil }
        guard token.utf8.count >= 8, token.utf8.count <= 64,
              token.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) })
        else { return nil }
        self.root = root
        self.token = token
        self.epoch = epoch
    }

    /// RB1-M1: ownership equality uses the EXACT normalized root path and the
    /// full owner token — never the 4-byte diagnostic fingerprint (whose
    /// collision absence cannot be relied on for admission).
    public func matchesOwnership(of other: RuntimeOwnerIdentity) -> Bool {
        root.path == other.root.path && token == other.token
    }
}

// MARK: - Owned store cluster (ONE DatabaseManager + original stores)

/// Durable bootstrap recovery facts from the ORIGINAL store APIs. Counts and
/// typed flags only — never row content. RB1 never drains the deletion queue
/// itself (`credentialDeletionsDrained` stays 0): the queue is durable V11
/// state owned by the later vault-recovery binding.
public struct RuntimeRecoverySummary: Sendable, Equatable {
    public var transientInputsRecovered: Bool = false
    public var interruptedChildrenMarked: Int = 0
    public var interruptedRunsMarked: Int = 0
    public var credentialDeletionsPending: Int = 0
    public var credentialDeletionsDrained: Int = 0
    public var credentialDeletionsDeferred: Int = 0
    /// D04 (job-3135f83ef97c4a21): counts from the ONE run-output tombstone
    /// retry pass of this readiness (mirrors the iOS performBootstrap pass).
    /// Zero when the run-output store was never bound or nothing persisted.
    /// `runOutputCleanupRetainedLiveConversations` /
    /// `runOutputCleanupRetainedLiveOwners` keep their tombstones AND their
    /// snapshot trees for a later pass — never a partial delete.
    public var runOutputCleanupCompleted: Int = 0
    public var runOutputCleanupRetainedLiveConversations: Int = 0
    public var runOutputCleanupRetainedLiveOwners: Int = 0
    public var runOutputCleanupFailed: Int = 0
    public init() {}
}

/// The one owner of the original persistence authority on Android.
///
/// Isolation note: this is a plain Swift actor on the cooperative pool, NOT
/// the MainActor and NOT an Android Looper. Synchronous JNI/binder callers
/// never await it — they enqueue through the bounded mailbox and the mailbox
/// worker drives these async steps.
public actor AndroidRuntimeStoreOwner {

    public enum Phase: String, Sendable {
        case created
        case opening
        case migrated
        case recovered
        case ready
        case closing
        case closed
        case failed
    }

    public private(set) var phase: Phase = .created

    private var identity: RuntimeOwnerIdentity?
    /// RB1-M5 lifecycle token: the epoch of the CURRENT open lifecycle. Every
    /// await boundary re-checks it; `close()` invalidates it first so a
    /// concurrent open/recover can never resurrect stores after teardown.
    private var lifecycleToken: UInt64?
    private var database: DatabaseManager?
    private(set) var conversationStore: SQLiteConversationStore?
    private(set) var runStore: SQLiteRunStore?
    private(set) var runningInputStore: SQLiteRunningInputStore?
    private(set) var childRunStore: SQLiteChildRunStore?
    private(set) var runLaunchStore: SQLiteRunLaunchStore?
    private(set) var modelConfigurationStore: ModelConfigurationStore?
    private(set) var credentialRecordStore: CredentialStore?
    private(set) var workspaceStore: SQLiteWorkspaceStore?
    private(set) var settingsStore: SQLiteSettingsStore?
    private(set) var skillStore: SQLiteSkillStore?
    private(set) var checkpointStore: FileCheckpointStore?

    public private(set) var recoverySummary = RuntimeRecoverySummary()
    public private(set) var lastFailure: RuntimeFacadeCode?

    public init() {}

    // MARK: Open / migrate

    /// Opens the ONE original `DatabaseManager` on the host-supplied root and
    /// applies the pinned migration chain. Fails closed on a schema version
    /// that is ABOVE the binary's current constant (never downgrade, never
    /// "best effort"); no fallback DB, no in-memory business store.
    ///
    /// RB1-M5: no precondition crash on a conflicting call — a typed
    /// `lifecycleConflict`. Every await re-checks the lifecycle token, and
    /// an abandoned manager is closed by the task that created it before
    /// releasing ownership, so a concurrent `close()` can never resurrect a
    /// migrated/ready cluster.
    public func openAndMigrate(with identity: RuntimeOwnerIdentity) async {
        // Pre-await check is single-hop atomic.
        guard phase == .created, lifecycleToken == nil else {
            lastFailure = .lifecycleConflict
            return
        }
        lifecycleToken = identity.epoch
        self.identity = identity
        phase = .opening
        let token = identity.epoch
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: identity.root.path),
                withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: identity.root.checkpointDirectoryURL,
                withIntermediateDirectories: true)
        } catch {
            failOpen(token: token, code: .checkpointDirectoryFailed)
            return
        }
        let manager: DatabaseManager
        do {
            // ORIGINAL constructor; `floe.sqlite` is the proven original name.
            manager = try DatabaseManager(path: identity.root.databaseURL)
        } catch {
            failOpen(token: token, code: .storeOpenFailed)
            return
        }
        // Token recheck BEFORE any further await would be pointless (no
        // await yet); every await below re-checks and closes `manager` itself.
        do {
            try await manager.migrate()
        } catch {
            await abandon(manager, token: token, code: .migrationFailed)
            return
        }
        let userVersion: Int
        do {
            userVersion = try await manager.userVersion()
        } catch {
            await abandon(manager, token: token, code: .migrationFailed)
            return
        }
        guard lifecycleToken == token else {
            // A close() (or retirement) won during an await: it does not own
            // THIS unpublished manager, so we close it ourselves.
            try? await manager.close()
            return
        }
        guard userVersion == DatabaseManager.currentSchemaVersion else {
            // The pinned chain must land exactly on 46; anything else is an
            // honest stop, never a partial-serve state.
            await abandon(manager, token: token, code: .schemaVersionMismatch)
            return
        }
        self.database = manager
        // The approved service-map constructors — all `init(database:)`.
        self.conversationStore = SQLiteConversationStore(database: manager)
        self.runStore = SQLiteRunStore(database: manager)
        self.runningInputStore = SQLiteRunningInputStore(database: manager)
        self.childRunStore = SQLiteChildRunStore(database: manager)
        self.runLaunchStore = SQLiteRunLaunchStore(database: manager)
        self.modelConfigurationStore = ModelConfigurationStore(database: manager)
        self.credentialRecordStore = CredentialStore(database: manager)
        self.workspaceStore = SQLiteWorkspaceStore(database: manager)
        self.settingsStore = SQLiteSettingsStore(database: manager)
        self.skillStore = SQLiteSkillStore(database: manager)
        self.checkpointStore = FileCheckpointStore(
            directory: identity.root.checkpointDirectoryURL)
        phase = .migrated
    }

    private func failOpen(token: UInt64, code: RuntimeFacadeCode) {
        guard lifecycleToken == token else { return }
        lastFailure = code
        lifecycleToken = nil
        identity = nil
        phase = .failed
    }

    private func abandon(_ manager: DatabaseManager, token: UInt64,
                         code: RuntimeFacadeCode) async {
        try? await manager.close()
        failOpen(token: token, code: code)
    }

    // MARK: Recovery (original store APIs only)

    /// Mirrors the ORIGINAL bootstrap recovery steps (AppEnvironment
    /// bootstrap():1681-1722): transient-input recovery, child reconcile and
    /// interrupted-run marking. The credential deletion queue is COUNTED
    /// only — its drain belongs to the dedicated vault-recovery binding,
    /// never to a duplicated bootstrap path.
    ///
    /// RB1-M5: runs only under the CURRENT lifecycle token; a concurrent
    /// close() invalidates the token and this method returns without touching
    /// the (already closing) lifecycle.
    public func recover(token: UInt64) async {
        guard phase == .migrated, database != nil, lifecycleToken == token else {
            // A migrated cluster under a DIFFERENT token is a real conflict;
            // any other state (closing/closed/failed) retires quietly.
            if phase == .migrated, database != nil {
                lastFailure = .lifecycleConflict
            }
            return
        }
        var summary = RuntimeRecoverySummary()
        do {
            try await runningInputStore?.recoverTransientInputs()
            summary.transientInputsRecovered = true
        } catch {
            failRecover(token: token, code: .recoveryFailed)
            return
        }
        guard lifecycleToken == token else { return }
        do {
            summary.interruptedChildrenMarked =
                try await childRunStore?.reconcileInterruptedOnLaunch() ?? 0
        } catch {
            failRecover(token: token, code: .recoveryFailed)
            return
        }
        guard lifecycleToken == token else { return }
        // Interrupted-run marking uses the ORIGINAL durable state vocabulary
        // ("interrupted" — ConversationRunService.swift:449; nonTerminalRuns
        // excludes it — RunStore.swift:400-409).
        do {
            if let runStore {
                let stale = try await runStore.nonTerminalRuns()
                for run in stale {
                    try await runStore.updateRunState(
                        id: run.id, state: "interrupted", endedAt: Date())
                    try await runStore.appendEvent(
                        runID: run.id, kind: .status,
                        payloadJSON: "{\"reason\":\"bootstrapInterrupted\"}")
                    summary.interruptedRunsMarked += 1
                    guard lifecycleToken == token else { return }
                }
            }
        } catch {
            failRecover(token: token, code: .recoveryFailed)
            return
        }
        guard lifecycleToken == token else { return }
        // RB1 does NOT drain the credential deletion queue. Durable
        // write-ahead cleanup rides the ORIGINAL V11 credential_deletion_queue
        // inside the dedicated vault-recovery binding (job
        // 06f6addd2fdb4271, runtime-credential-vault-recovery-source) with
        // its own atomic live-reference protection; reimplementing that here
        // would be a duplicate recovery path. Bootstrap only COUNTS the
        // pending queue honestly and marks it deferred to that real binding.
        do {
            // Bounded count only: an exact `COUNT(*)` through the ALREADY
            // owned original DatabaseManager reader. This deliberately does
            // NOT materialise every pending row (the parent called
            // `pendingDeletions()` and discarded the array after `.count`).
            // No schema/index/second DB and no duplicate vault recovery: the
            // durable queue remains for the dedicated vault-owned operation
            // package (job-07f0d672e3854e17); bootstrap only counts/defers.
            if let database {
                let pending = try await database.reader { db in
                    try Int.fetchOne(db,
                        sql: "SELECT COUNT(*) FROM credential_deletion_queue") ?? 0
                }
                summary.credentialDeletionsPending = pending
                summary.credentialDeletionsDeferred = pending
            }
        } catch {
            failRecover(token: token, code: .recoveryFailed)
            return
        }
        guard lifecycleToken == token else { return }
        // D04 (job-3135f83ef97c4a21; lifetime fix per the 2026-10-27 API
        // review): bind the run-output store to THIS generation's owned
        // persistent root and retry exactly the persisted cleanup tombstones
        // — once per readiness pass, no timer, no global scan (the iOS
        // performBootstrap placement). A run-output publication without
        // this binding fails closed, so the binding is installed here and
        // nowhere else; `close()` retires it under the monotonic epoch
        // fence (a retired epoch can never be re-installed). The retry
        // consults two trusted proofs before deleting anything: the
        // conversation row is truly gone (a pre-DB-failure tombstone can
        // never delete a live run's output) and NO live operation lease
        // names the run (`RunOutputLeaseLiveOwnership`). The runs TABLE is
        // deliberately NOT consulted: the conversation cascade itself
        // deletes those rows BEFORE post-cascade cleanup, so a row probe
        // could never see a publisher/download/native owner that survived
        // the cascade — leases are the authoritative in-process signal and
        // resumed durable job owners join the same acquire/release seam.
        // Counts ride the honest recovery summary; failures keep requests.
        if let identity = self.identity, let database, identity.epoch == token {
            if RuntimeFacadeRunOutput.shared.install(
                artifactRootPath: identity.root.artifactStoreURL.path,
                epoch: identity.epoch
            ) {
                let outcome = await RunOutputCleanupQueue.retryPersistedTombstones(
                    storeRoot: identity.root.artifactStoreURL,
                    artifactRoot: identity.root.artifactStoreURL,
                    liveOwnership: RunOutputLeaseLiveOwnership(),
                    operationGate: RuntimeFacadeRunOutput.shared
                ) { conversationID in
                    // A read failure is unknown, not proof of deletion: the
                    // queue retains the request and the user's snapshots.
                    try await database.reader { db in
                        try Row.fetchOne(
                            db,
                            sql: "SELECT 1 FROM conversations WHERE id = ?",
                            arguments: [conversationID.uuidString]
                        ) != nil
                    }
                }
                summary.runOutputCleanupCompleted = outcome.completedRequests
                summary.runOutputCleanupRetainedLiveConversations =
                    outcome.retainedLiveConversationRequests
                summary.runOutputCleanupRetainedLiveOwners =
                    outcome.retainedLiveOutputRequests
                summary.runOutputCleanupFailed = outcome.failedRequestCount
            }
        }
        guard lifecycleToken == token else {
            // The generation was torn down during the retry pass: retire OUR
            // binding under its own epoch and fail closed like any other
            // late-boundary exit.
            if let epoch = identity?.epoch { RuntimeFacadeRunOutput.shared.retire(epoch: epoch) }
            return
        }
        recoverySummary = summary
        // The cluster is ready for bootstrap-scope commands only. Ordinary
        // runtime admission stays blocked until the real RB2b/RB3/RB4
        // dependencies are installed; the owner never fabricates that.
        phase = .ready
    }

    private func failRecover(token: UInt64, code: RuntimeFacadeCode) {
        guard lifecycleToken == token else { return }
        lastFailure = code
        phase = .failed
    }

    /// Real stop: drains NOTHING implicitly. The bootstrap lifecycle drains
    /// the mailbox FIRST and then closes the DB exactly here — last.
    ///
    /// RB1-M5: the lifecycle token is invalidated BEFORE the first await so
    /// a concurrent open/recover sees it at its next boundary and closes its
    /// own unpublished manager; close is idempotent and never reopens.
    public func close() async {
        guard phase != .closed else { return }
        lifecycleToken = nil
        phase = .closing
        // D04 (job-3135f83ef97c4a21): retire THIS generation's run-output
        // binding under its own epoch first, so a late publish/verify/
        // cleanup caller fails closed (the store then refuses any implicit
        // Android root). Durable snapshot trees and tombstones on disk are
        // untouched; a newer generation's binding is never torn down.
        if let identity = self.identity {
            RuntimeFacadeRunOutput.shared.retire(epoch: identity.epoch)
        }
        // Drop store references before closing so no later job can reach them.
        conversationStore = nil
        runStore = nil
        runningInputStore = nil
        childRunStore = nil
        runLaunchStore = nil
        modelConfigurationStore = nil
        credentialRecordStore = nil
        workspaceStore = nil
        settingsStore = nil
        skillStore = nil
        checkpointStore = nil
        if let database {
            try? await database.close()
        }
        self.database = nil
        identity = nil
        phase = .closed
    }

    /// Live user_version read for the status/diagnostics seam (never a
    /// fallback constant): nil while no database is open under a current
    /// lifecycle token.
    public func currentUserVersion() async -> Int? {
        guard let database, lifecycleToken != nil else { return nil }
        return try? await database.userVersion()
    }

    /// Owner-side phase read for tests and later domains. Synchronous JNI
    /// callers use the bootstrap lifecycle snapshot instead and never await
    /// this actor.
    public var currentPhase: Phase { phase }

    // MARK: G02 trusted root/epoch checked store access hook
    // (job-7cd349b4cd6d4b55 narrow additive delta). Hands the immutable
    // owned cluster to the in-module production composition ONLY after
    // re-validating the EXACT accepted identity + lifecycle token + ready
    // phase on this actor. Returns nil on any drift: the composition fails
    // closed and never opens a second DatabaseManager by the same URL.
    func g02OwnedCluster(expected identity: RuntimeOwnerIdentity)
        -> G02OwnedStoreCluster? {
        guard let current = self.identity,
              current.matchesOwnership(of: identity),
              current.epoch == identity.epoch,
              lifecycleToken == identity.epoch,
              phase == .ready,
              let database,
              let conversationStore, let runStore, let runningInputStore,
              let childRunStore, let runLaunchStore,
              let modelConfigurationStore,
              let workspaceStore, let settingsStore, let skillStore,
              let checkpointStore else {
            return nil
        }
        return G02OwnedStoreCluster(
            identity: identity,
            database: database,
            conversationStore: conversationStore,
            runStore: runStore,
            runningInputStore: runningInputStore,
            childRunStore: childRunStore,
            runLaunchStore: runLaunchStore,
            modelConfigurationStore: modelConfigurationStore,
            workspaceStore: workspaceStore,
            settingsStore: settingsStore,
            skillStore: skillStore,
            checkpointStore: checkpointStore)
    }
}

// MARK: - D04 live-ownership note (lifetime fix, 2026-10-27 review)

// An earlier candidate probed the runs TABLE for liveness. That signal is
// wrong for post-cascade cleanup: the deletion's own cascade removes the
// run rows BEFORE cleanup runs, so a still-running publisher/download/
// native owner is invisible to it. The authoritative probes are now
// `RunOutputLeaseLiveOwnership` (readiness path) and
// `OwnedRunOutputWorkProbe` (deletion path) in RuntimeFacadeRunOutput.swift,
// both composed from real runtime-issued leases and exact RB1 owned-work
// tokens. No path/permission parallel system exists.

// MARK: - Test-only probes (no production caller)

extension AndroidRuntimeStoreOwner {
    /// Narrow trusted accessor for host qualification of domains that MUST
    /// use the SAME owned manager (never a second business DB). Test-only
    /// callers; production code consumes the published store properties.
    func ownedDatabaseForTesting() -> DatabaseManager? { database }

    /// Exact SQL count through the SAME owned reader; used by the authored
    /// count/equivalence test. It never drains or mutates the queue.
    func credentialDeletionQueueCountForTesting() async -> Int? {
        guard let database else { return nil }
        return try? await database.reader { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM credential_deletion_queue") ?? 0
        }
    }
}
