// SPDX-License-Identifier: MPL-2.0
//
// macOS composition root for Floe's own runtime. It owns one host-selected
// private SQLite database, one cooperative cross-process authority lock, the
// durable per-conversation admission table, and the real
// ConversationRunService instances launched against that database. The
// durable owner must live in the long-lived host process, not in the
// force-terminated Catalyst UI child.

import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloeSecurity
import FloePersistence
import FloeAgentRuntime

public struct FloeMacSelfRuntimeOptions: Sendable, Hashable {
    /// Per-subscriber event buffer for the host projection. The upstream
    /// channel is also newest-bounded and has no replay.
    public var eventBufferLimit: Int

    public init(eventBufferLimit: Int = 256) {
        self.eventBufferLimit = min(2_048, max(32, eventBufferLimit))
    }
}

private struct FloeMacSelfStores: Sendable {
    let launch: SQLiteRunLaunchStore
    let conversations: SQLiteConversationStore
    let runs: SQLiteRunStore
    let checkpoints: SQLiteRunCheckpointStore
}

public actor FloeMacSelfRuntime {
    public nonisolated let databaseURL: URL
    public nonisolated let owner: FloeMacSelfHostIdentity
    /// Exact lock file this runtime holds beside the database. Diagnostic
    /// only; its path is not a credential.
    public nonisolated let authorityLockURL: URL

    private let database: DatabaseManager
    private let options: FloeMacSelfRuntimeOptions
    private let authorityLock: FloeMacSelfAuthorityLock
    private let claims = FloeMacSelfConversationClaims()

    private var stores: FloeMacSelfStores?
    private var admissions: FloeMacSelfAdmissionStore?
    private var bootstrapReceipt: FloeMacSelfBootstrapReceipt?
    private var bootstrapTask: Task<FloeMacSelfBootstrapReceipt, Error>?
    private var shutdownTask: Task<FloeMacSelfShutdownReceipt, Error>?
    // The durable runtime, not a transient UI handle, owns live sessions.
    private var sessions: [UUID: FloeMacSelfSession] = [:]
    private var activeAdmissions: Set<UUID> = []
    private var closingSessions: Set<UUID> = []
    private var closed = false
    private var shuttingDown = false
    private var authorityCompromised = false
    // Internal scheduling seam for the dispatch/cancel race test. It grants
    // no capability and is inaccessible to clients of the public module.
    private var dispatchTestHook: (@Sendable () async -> Void)?
    private var cancellationAttemptTestHook: (@Sendable () async -> Void)?
    private var preparedInputTestHook: (@Sendable () async -> Void)?

    func setPreparedInputTestHook(_ hook: (@Sendable () async -> Void)?) {
        preparedInputTestHook = hook
    }

    func setCancellationTestHooks(
        beforeServiceStart: (@Sendable () async -> Void)?,
        afterCancellationAttempt: (@Sendable () async -> Void)?
    ) {
        dispatchTestHook = beforeServiceStart
        cancellationAttemptTestHook = afterCancellationAttempt
    }

    /// Fail-closed convenience initializer. It performs the same owner and
    /// location validation as the provenance initializer, then refuses:
    /// without trusted host provenance no authority lease is acquired and no
    /// database is opened. This retains the closed production gate; genuine
    /// composition goes through
    /// `init(databaseURL:owner:provenance:options:)`.
    public init(
        databaseURL: URL,
        owner: FloeMacSelfHostIdentity,
        options: FloeMacSelfRuntimeOptions = FloeMacSelfRuntimeOptions()
    ) throws {
        let validated = try Self.validateLocation(databaseURL, owner: owner)
        _ = validated
        throw FloeMacSelfCoreError.authorityLockUnsafe("host_provenance_missing")
    }

    /// Genuine host-adapter composition. The host supplies trusted provenance
    /// (directory, lock directory and database identities captured before the
    /// runtime starts); the verified authority primitive binds that exact
    /// identity before the database is opened, so two cooperating owners
    /// cannot race the same private store and no trust is derived from the
    /// raw `databaseURL` alone.
    public init(
        databaseURL: URL,
        owner: FloeMacSelfHostIdentity,
        provenance: FloeMacSelfHostProvenance,
        options: FloeMacSelfRuntimeOptions = FloeMacSelfRuntimeOptions()
    ) throws {
        let validated = try Self.validateLocation(databaseURL, owner: owner)
        let standardized = validated.databaseURL
        guard provenance.databaseName == standardized.lastPathComponent,
              provenance.directoryPath == standardized.deletingLastPathComponent().path else {
            throw FloeMacSelfCoreError.hostProvenanceUnavailable("provenance_does_not_match_database_url")
        }
        let lock = try FloeMacSelfAuthorityLock(provenance: provenance, owner: validated.owner)
        do {
            self.database = try DatabaseManager(path: standardized)
        } catch {
            lock.release()
            throw FloeMacSelfCoreError.invalidDatabaseLocation("the database could not be opened")
        }
        self.databaseURL = standardized
        self.owner = validated.owner
        self.authorityLock = lock
        self.authorityLockURL = lock.lockURL
        self.options = options
    }

    private static func validateLocation(
        _ databaseURL: URL,
        owner: FloeMacSelfHostIdentity
    ) throws -> (databaseURL: URL, owner: FloeMacSelfHostIdentity) {
        guard owner.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
            throw FloeMacSelfCoreError.invalidOwner(
                "the runtime must be created by the process that owns durable execution"
            )
        }
        let displayName = owner.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty, displayName.utf8.count <= 80 else {
            throw FloeMacSelfCoreError.invalidOwner("the host display name must be 1...80 bytes")
        }
        guard databaseURL.isFileURL else {
            throw FloeMacSelfCoreError.invalidDatabaseLocation("the database path must be a file URL")
        }
        let standardized = databaseURL.standardizedFileURL
        guard !standardized.path.isEmpty, standardized.path != "/" else {
            throw FloeMacSelfCoreError.invalidDatabaseLocation("the database path is empty")
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw FloeMacSelfCoreError.invalidDatabaseLocation("the database path is a directory")
            }
            guard FileManager.default.isWritableFile(atPath: standardized.path) else {
                throw FloeMacSelfCoreError.invalidDatabaseLocation("the database file is not writable")
            }
        } else {
            let parent = standardized.deletingLastPathComponent()
            var parentIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
                  parentIsDirectory.boolValue else {
                throw FloeMacSelfCoreError.invalidDatabaseLocation(
                    "the parent directory does not exist; the host must create it explicitly"
                )
            }
            guard FileManager.default.isWritableFile(atPath: parent.path) else {
                throw FloeMacSelfCoreError.invalidDatabaseLocation("the parent directory is not writable")
            }
        }
        let validatedOwner = FloeMacSelfHostIdentity(
            hostInstanceID: owner.hostInstanceID,
            processIdentifier: owner.processIdentifier,
            displayName: displayName
        )
        return (standardized, validatedOwner)
    }

    // MARK: - Migration

    /// Explicitly migrates the host-owned database, installs the self-core
    /// admission tables, and only then constructs the stores. Repeated calls
    /// are idempotent and concurrent callers share one bootstrap.
    @discardableResult
    public func bootstrap() async throws -> FloeMacSelfBootstrapReceipt {
        guard !closed, !shuttingDown else { throw FloeMacSelfCoreError.runtimeClosed }
        if let bootstrapReceipt {
            return bootstrapReceipt
        }
        if let bootstrapTask {
            let receipt = try await bootstrapTask.value
            guard !shuttingDown, !closed else { throw FloeMacSelfCoreError.runtimeClosed }
            return receipt
        }
        let task = Task { try await self.performBootstrap() }
        bootstrapTask = task
        do {
            let receipt = try await task.value
            bootstrapTask = nil
            guard !shuttingDown, !closed else { throw FloeMacSelfCoreError.runtimeClosed }
            return receipt
        } catch {
            bootstrapTask = nil
            throw error
        }
    }

    private func performBootstrap() async throws -> FloeMacSelfBootstrapReceipt {
        try ensureOpen()
        if let bootstrapReceipt {
            return bootstrapReceipt
        }
        try requireAuthority()
        // Refuse newer or unrecognized schemas before the migrator can write.
        // This does not by itself bind GRDB's reopened descriptor to the
        // authority primitive; production composition remains unconnected.
        try await FloeMacSelfSchemaGate.validateBeforeMigration(database)
        try requireAuthority()
        do {
            try await database.migrate()
        } catch {
            throw FloeMacSelfCoreError.persistenceUnavailable(
                FloeMacSelfErrorIdentity.render(error)
            )
        }
        let version: Int
        do {
            version = try await database.userVersion()
        } catch {
            throw FloeMacSelfCoreError.persistenceUnavailable(
                FloeMacSelfErrorIdentity.render(error)
            )
        }
        // Upstream's constant currently lags registered V62/V63 migrations.
        // Check the exact pinned schema instead of accepting arbitrary futures.
        guard version == FloeMacSelfSchemaGate.maximumVersion else {
            throw FloeMacSelfCoreError.schemaMismatch(
                expected: FloeMacSelfSchemaGate.maximumVersion,
                actual: version
            )
        }
        let migrations: [String]
        do {
            migrations = try await database.appliedMigrations()
        } catch {
            throw FloeMacSelfCoreError.persistenceUnavailable(
                FloeMacSelfErrorIdentity.render(error)
            )
        }
        do {
            try await database.writer { db in
                try FloeMacSelfAdmissionStore.installSchema(in: db)
            }
        } catch let error as FloeMacSelfCoreError {
            throw error
        } catch {
            throw FloeMacSelfCoreError.authoritySchemaUnsupported(
                FloeMacSelfErrorIdentity.render(error)
            )
        }
        guard !closed, !shuttingDown else { throw FloeMacSelfCoreError.runtimeClosed }
        stores = FloeMacSelfStores(
            launch: SQLiteRunLaunchStore(database: database),
            conversations: SQLiteConversationStore(database: database),
            runs: SQLiteRunStore(database: database),
            checkpoints: SQLiteRunCheckpointStore(database: database, legacyDirectory: nil)
        )
        admissions = FloeMacSelfAdmissionStore(database: database, authorityLock: authorityLock)
        let receipt = FloeMacSelfBootstrapReceipt(
            schemaVersion: version,
            appliedMigrationCount: migrations.count,
            bootstrappedAt: Date()
        )
        bootstrapReceipt = receipt
        return receipt
    }

    // MARK: - Session start

    public func startSession(
        _ request: FloeMacSelfSessionRequest,
        provider: FloeMacSelfProviderBinding,
        tools: FloeMacSelfToolBinding? = nil
    ) async throws -> FloeMacSelfSessionHandle {
        guard !shuttingDown, !closed, !authorityCompromised else {
            throw FloeMacSelfCoreError.runtimeClosed
        }
        let stores = try requireStores()
        let admissions = try requireAdmissions()
        try FloeMacSelfRequestValidator.validate(request)
        // Match the exact normalization used by SQLiteRunLaunchStore.prepare.
        let canonicalGoal = request.goal.trimmingCharacters(in: .whitespacesAndNewlines)

        // A declared boundary and host-gate labels do not prove that this
        // durable workspace owns the supplied filesystem root. Unlike the
        // App's WorkspaceCenter, this host does not yet acquire and retain a
        // task-root lease from the persisted workspace. Refuse before creating
        // an admission or invoking the provider until that integration exists.
        guard tools == nil else {
            throw FloeMacSelfCoreError.toolCapabilityUnavailable(
                "workspace ownership and task-root lease are not connected"
            )
        }
        let resolvedProvider = try FloeMacSelfCapabilityResolver.resolveProvider(provider)
        let resolvedTools = try FloeMacSelfCapabilityResolver.resolveTools(tools, model: resolvedProvider.model)
        try FloeMacSelfRequestValidator.validate(
            toolsEnabled: resolvedTools.enabled,
            request: request,
            boundary: resolvedTools.boundary
        )

        let resolvedConversationID: UUID
        let newConversationID: UUID?
        if let existing = request.conversationID {
            resolvedConversationID = existing
            newConversationID = nil
        } else {
            let newID = request.newConversationID ?? UUID()
            resolvedConversationID = newID
            newConversationID = newID
        }
        let runID = request.runID ?? UUID()

        let operationID = UUID()
        activeAdmissions.insert(operationID)
        defer { activeAdmissions.remove(operationID) }

        guard claims.claim(conversationID: resolvedConversationID, runID: runID) else {
            throw FloeMacSelfCoreError.conversationBusy(resolvedConversationID)
        }
        var sessionOwnsClaim = false
        defer {
            if !sessionOwnsClaim {
                claims.release(conversationID: resolvedConversationID, runID: runID)
            }
        }

        var admission: FloeMacSelfAdmissionRecord?
        var prepareCommitted = false
        do {
            try requireAuthority()
            let admitted = try await admissions.admit(
                conversationID: resolvedConversationID,
                runID: runID,
                owner: owner
            )
            admission = admitted
            let taskEpoch = FloeMacSelfTaskEpoch(
                conversationID: resolvedConversationID,
                runID: runID,
                admissionEpoch: UInt64(admitted.epoch)
            )
            let fence = FloeMacSelfRunFence(taskEpoch: taskEpoch)

            // The existing assembler owns history selection (attachments,
            // images, summaries and wire-neutral projection). It is called
            // before the launch transaction so a history failure creates no
            // durable run.
            var conversationHistory: [ConversationMessage] = []
            if request.conversationID != nil {
                do {
                    conversationHistory = try await ConversationHistoryAssembler(
                        store: stores.conversations
                    ).build(conversationID: resolvedConversationID)
                } catch {
                    throw Self.surface(error)
                }
            }

            try ensureAdmissionStillAllowed()

            let providerName = resolvedProvider.provider.displayName
                ?? resolvedProvider.provider.kind.rawValue
            let launchRequest = RunLaunchRequest(
                conversationID: request.conversationID,
                newConversationID: newConversationID,
                conversationTitle: request.conversationTitle,
                runID: runID,
                goal: request.goal,
                initialState: "preparing",
                workspaceID: request.workspaceID,
                attachments: [],
                conversationMode: ConversationMode.chat.rawValue,
                initialPolicy: request.initialPolicy,
                messageRole: "user",
                providerName: providerName,
                modelName: resolvedProvider.model.displayName,
                providerProfile: resolvedProvider.provider,
                modelProfile: resolvedProvider.model,
                startedAt: request.startedAt
            )
            let prepared: PreparedRun
            do {
                prepared = try await stores.launch.prepare(launchRequest)
                prepareCommitted = true
            } catch {
                throw Self.surface(error)
            }

            guard prepared.conversation.id == resolvedConversationID,
                  prepared.run.id == runID,
                  prepared.run.conversationID == resolvedConversationID,
                  prepared.userMessage.conversationID == resolvedConversationID,
                  prepared.userMessage.runID == runID else {
                throw FloeMacSelfCoreError.preparedIdentityMismatch(
                    "conversation/run/user-message identities changed during launch"
                )
            }
            try FloeMacSelfPreparedInput.verify(
                prepared.userMessage, messageID: prepared.userMessage.id,
                conversationID: resolvedConversationID, runID: runID, goal: canonicalGoal)
            guard prepared.run.goal.utf8.elementsEqual(canonicalGoal.utf8),
                  let savedInput = try await stores.conversations.message(
                    id: prepared.userMessage.id, conversationID: resolvedConversationID) else {
                throw FloeMacSelfCoreError.preparedIdentityMismatch("durable user input is unavailable")
            }
            try FloeMacSelfPreparedInput.verify(
                savedInput, messageID: prepared.userMessage.id,
                conversationID: resolvedConversationID, runID: runID, goal: canonicalGoal)
            guard prepared.run.providerID == resolvedProvider.provider.id,
                  prepared.run.modelID == resolvedProvider.model.id else {
                throw FloeMacSelfCoreError.preparedIdentityMismatch(
                    "the durable provider/model rows differ from the selected profiles; reload them from this database"
                )
            }
            if let boundary = resolvedTools.boundary {
                guard prepared.workspace.id == boundary.workspaceID else {
                    throw FloeMacSelfCoreError.preparedIdentityMismatch(
                        "the prepared workspace is not the tool boundary workspace"
                    )
                }
            }

            // A shutdown that started while history/prepare was awaited must
            // not receive a new session against a closing database.
            try ensureAdmissionStillAllowed()

            let resolvedWorkspaceRoot: URL?
            if resolvedTools.enabled, let boundary = resolvedTools.boundary {
                resolvedWorkspaceRoot = boundary.workspaceRootURL
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
            } else {
                resolvedWorkspaceRoot = nil
            }

            let availableToolNames: Set<String> = resolvedTools.enabled
                ? resolvedTools.allowedToolNames
                : Set<String>()
            let runContext = ConversationRunService.RunContext(
                workspaceName: request.context.workspaceName ?? prepared.workspace.name,
                selectedRelativePath: request.context.selectedRelativePath,
                executionTarget: request.context.executionTarget
                    ?? (resolvedTools.enabled
                        ? "macOS native host"
                        : "macOS chat (tools disabled)"),
                availableToolNames: availableToolNames,
                contentOverlay: .empty,
                workspaceAttachmentPaths: [],
                workspaceNotes: request.context.workspaceNotes,
                workspaceListing: request.context.workspaceListing,
                projectInstructions: request.context.projectInstructions
            )

            let configuration = FloeAgentRuntime.Configuration(
                conversationID: prepared.conversation.id,
                provider: resolvedProvider.provider,
                model: resolvedProvider.model,
                conversationMode: .chat,
                allowedToolNames: availableToolNames,
                workspaceRootURL: resolvedWorkspaceRoot,
                allowedWorkspacePaths: resolvedTools.boundary?.allowedWorkspacePaths ?? [],
                toolsEnabled: resolvedTools.enabled,
                chatFastMode: request.chatFastMode,
                environmentID: nil,
                executionBinding: nil,
                remoteExecutionEnvironment: false,
                localLinuxGuestEnvironment: false
            )

            let executor: any ToolExecutor
            if resolvedTools.enabled {
                executor = FloeMacSelfFencedToolExecutor(
                    wrapping: resolvedTools.executor,
                    allowedToolNames: resolvedTools.allowedToolNames,
                    fence: fence,
                    epoch: taskEpoch
                )
            } else {
                executor = resolvedTools.executor
            }

            let service = ConversationRunService(
                configuration: configuration,
                adapter: resolvedProvider.adapter,
                policy: resolvedTools.policy,
                executor: executor,
                credentials: resolvedProvider.credentials,
                gate: resolvedTools.gate,
                auditSink: resolvedTools.auditSink,
                checkpointStore: stores.checkpoints,
                conversationStore: stores.conversations,
                runStore: stores.runs,
                runID: prepared.run.id,
                conversationHistory: conversationHistory,
                currentUserImages: [],
                runContext: runContext
            )

            // The durable prepared CAS happens before any process object can
            // start the runtime. A crash between this CAS and launch stays
            // unknown; it is never treated as a retryable free conversation.
            try await admissions.markPrepared(
                conversationID: prepared.conversation.id,
                runID: prepared.run.id,
                epoch: admitted.epoch
            )
            guard fence.markPrepared() else {
                throw FloeMacSelfCoreError.admissionConflict(resolvedConversationID)
            }

            let identity = FloeMacSelfSessionIdentity(
                owner: owner,
                conversationID: prepared.conversation.id,
                workspaceID: prepared.workspace.id,
                runID: prepared.run.id,
                userMessageID: prepared.userMessage.id,
                conversationMode: .chat,
                toolsEnabled: resolvedTools.enabled,
                admissionEpoch: UInt64(admitted.epoch),
                startedAt: prepared.run.startedAt
            )
            let session = FloeMacSelfSession(
                identity: identity,
                service: service,
                conversationStore: stores.conversations,
                runStore: stores.runs,
                checkpointStore: stores.checkpoints,
                admissions: admissions,
                admissionEpoch: admitted.epoch,
                claims: claims,
                fence: fence,
                goal: canonicalGoal,
                toolsEnabled: resolvedTools.enabled,
                boundary: resolvedTools.boundary,
                eventBufferLimit: options.eventBufferLimit,
                beforeInputRecheck: preparedInputTestHook,
                beforeServiceStart: dispatchTestHook,
                afterCancellationAttempt: cancellationAttemptTestHook
            )
            sessions[prepared.run.id] = session
            sessionOwnsClaim = true
            await session.launch()
            return FloeMacSelfSessionHandle(runtime: self, session: session, identity: identity)
        } catch {
            if let admission, !sessionOwnsClaim {
                await abortAdmission(
                    admission,
                    prepareCommitted: prepareCommitted,
                    reason: "startSessionAborted"
                )
            }
            throw error
        }
    }

    // MARK: - Session lookup and lifecycle

    public func session(runID: UUID) async -> FloeMacSelfSessionHandle? {
        guard !closed, let session = sessions[runID] else { return nil }
        let tornDown = await session.isTornDown()
        guard !tornDown else { return nil }
        return FloeMacSelfSessionHandle(runtime: self, session: session, identity: session.identity)
    }

    public func sessionSummaries() async -> [FloeMacSelfSessionSummary] {
        guard !closed else { return [] }
        let snapshot = Array(sessions.values)
        var summaries: [FloeMacSelfSessionSummary] = []
        for session in snapshot {
            summaries.append(await session.summary())
        }
        return summaries.sorted { $0.identity.startedAt < $1.identity.startedAt }
    }

    public func activeSessionRunIDs() async -> [UUID] {
        guard !closed else { return [] }
        let snapshot = Array(sessions.values)
        var active: [UUID] = []
        for session in snapshot {
            let phase = await session.phaseValue()
            if phase.isActive {
                active.append(session.identity.runID)
            }
        }
        return active.sorted { $0.uuidString < $1.uuidString }
    }

    public func closeSession(
        runID: UUID,
        allowUnconfirmed: Bool = false
    ) async throws -> FloeMacSelfCloseReceipt {
        try ensureOpen()
        guard !shuttingDown else { throw FloeMacSelfCoreError.runtimeClosed }
        guard let session = sessions[runID] else {
            throw FloeMacSelfCoreError.sessionNotFound(runID)
        }
        closingSessions.insert(runID)
        defer { closingSessions.remove(runID) }
        let receipt = try await session.close(allowUnconfirmed: allowUnconfirmed)
        sessions[runID] = nil
        claims.release(conversationID: receipt.conversationID, runID: runID)
        return receipt
    }

    /// Stops/closes every composed session, then closes the database. Active
    /// sessions are cancelled only when `cancelActive` is true. Unconfirmed
    /// terminal states require `allowUnconfirmed`; otherwise the durable run
    /// and durable admission are preserved and shutdown fails closed.
    ///
    /// Concurrent shutdown callers share one shutdown task. New admissions and
    /// new session closes are blocked, and in-flight admissions/closes are
    /// joined, before the database is closed.
    public func shutdown(
        cancelActive: Bool,
        allowUnconfirmed: Bool = false,
        timeout: TimeInterval = 30
    ) async throws -> FloeMacSelfShutdownReceipt {
        if closed {
            return FloeMacSelfShutdownReceipt(
                closedSessionCount: 0,
                preservedRunIDs: [],
                databaseClosed: true,
                alreadyClosed: true,
                retainedAdmissionConversationIDs: [],
                admissionInventoryAvailable: true
            )
        }
        if let shutdownTask {
            return try await shutdownTask.value
        }
        shuttingDown = true
        let task = Task {
            try await self.performShutdown(
                cancelActive: cancelActive,
                allowUnconfirmed: allowUnconfirmed,
                timeout: timeout
            )
        }
        shutdownTask = task
        do {
            let receipt = try await task.value
            shutdownTask = nil
            return receipt
        } catch {
            shutdownTask = nil
            shuttingDown = false
            throw error
        }
    }

    private func performShutdown(
        cancelActive: Bool,
        allowUnconfirmed: Bool,
        timeout: TimeInterval
    ) async throws -> FloeMacSelfShutdownReceipt {
        if let bootstrapTask {
            _ = try? await bootstrapTask.value
            self.bootstrapTask = nil
        }
        guard !closed else {
            return FloeMacSelfShutdownReceipt(
                closedSessionCount: 0,
                preservedRunIDs: [],
                databaseClosed: true,
                alreadyClosed: true,
                retainedAdmissionConversationIDs: [],
                admissionInventoryAvailable: true
            )
        }
        try await drainOperations(timeout: timeout)

        let snapshot = Array(sessions.values)
        var active: [UUID] = []
        for session in snapshot {
            let phase = await session.phaseValue()
            if phase.isActive {
                active.append(session.identity.runID)
            }
        }
        if !active.isEmpty && !cancelActive {
            throw FloeMacSelfCoreError.activeSessions(active.sorted { $0.uuidString < $1.uuidString })
        }
        for session in snapshot where active.contains(session.identity.runID) {
            let receipt = await session.cancelAndWait(timeout: timeout)
            guard receipt.terminal?.confirmed == true else {
                throw FloeMacSelfCoreError.shutdownIncomplete([session.identity.runID])
            }
        }

        var preserved: [UUID] = []
        var remaining: [UUID] = []
        var closedCount = 0
        for session in snapshot {
            do {
                let receipt = try await session.close(allowUnconfirmed: allowUnconfirmed)
                if receipt.preservedUnconfirmedRun {
                    preserved.append(receipt.runID)
                }
                sessions[receipt.runID] = nil
                claims.release(conversationID: receipt.conversationID, runID: receipt.runID)
                closedCount += 1
            } catch {
                remaining.append(session.identity.runID)
            }
        }
        if !remaining.isEmpty {
            throw FloeMacSelfCoreError.unconfirmedSessions(remaining.sorted { $0.uuidString < $1.uuidString })
        }

        // Inventory unresolved admission rows before closing. Shutdown never
        // clears or settles them.
        var retainedAdmissions: [UUID] = []
        var inventoryAvailable = true
        if let admissions {
            do {
                retainedAdmissions = try await admissions.unresolvedAdmissions()
                    .map(\.conversationID)
                    .sorted { $0.uuidString < $1.uuidString }
            } catch {
                inventoryAvailable = false
            }
        }

        claims.reset()
        do {
            try await database.close()
        } catch {
            throw FloeMacSelfCoreError.persistenceUnavailable(
                FloeMacSelfErrorIdentity.render(error)
            )
        }
        stores = nil
        admissions = nil
        sessions.removeAll()
        activeAdmissions.removeAll()
        closingSessions.removeAll()
        closed = true
        shuttingDown = false
        authorityLock.release()
        return FloeMacSelfShutdownReceipt(
            closedSessionCount: closedCount,
            preservedRunIDs: preserved.sorted { $0.uuidString < $1.uuidString },
            databaseClosed: true,
            alreadyClosed: false,
            retainedAdmissionConversationIDs: retainedAdmissions,
            admissionInventoryAvailable: inventoryAvailable
        )
    }

    // MARK: - Durable admission reads/reconciliation

    public func admissionRecord(conversationID: UUID) async throws -> FloeMacSelfAdmissionRecord? {
        let admissions = try requireAdmissions()
        return try await admissions.record(conversationID: conversationID)
    }

    /// Every non-confirmed admission row. These block automatic retry.
    public func unresolvedAdmissions() async throws -> [FloeMacSelfAdmissionRecord] {
        let admissions = try requireAdmissions()
        return try await admissions.unresolvedAdmissions()
    }

    /// Explicit host reconciliation. Only an admission that provably never
    /// reached prepare (phase admitting, no run/message row) can be removed.
    /// This is never called automatically and does not replay the run.
    public func abandonUnstartedAdmission(
        conversationID: UUID,
        runID: UUID,
        expectedEpoch: Int
    ) async throws {
        try ensureOpen()
        guard !shuttingDown else { throw FloeMacSelfCoreError.runtimeClosed }
        let admissions = try requireAdmissions()
        try await admissions.abandonUnstartedAdmission(
            conversationID: conversationID,
            runID: runID,
            epoch: expectedEpoch
        )
    }

    // MARK: - Read-only archive

    public func runRecord(runID: UUID) async throws -> RunRecord? {
        let stores = try requireStores()
        do {
            return try await stores.runs.run(id: runID)
        } catch {
            throw Self.surface(error)
        }
    }

    public func recentRuns(conversationID: UUID, limit: Int = 20) async throws -> [RunRecord] {
        let stores = try requireStores()
        do {
            return try await stores.runs.recentRuns(
                conversationID: conversationID,
                limit: min(100, max(1, limit))
            )
        } catch {
            throw Self.surface(error)
        }
    }

    public func nonTerminalRuns() async throws -> [RunRecord] {
        let stores = try requireStores()
        do {
            return try await stores.runs.nonTerminalRuns()
        } catch {
            throw Self.surface(error)
        }
    }

    public func conversations() async throws -> [ConversationRecord] {
        let stores = try requireStores()
        do {
            return try await stores.conversations.conversations()
        } catch {
            throw Self.surface(error)
        }
    }

    public func conversationMessages(
        conversationID: UUID,
        limit: Int = 100
    ) async throws -> [PersistedMessage] {
        let stores = try requireStores()
        do {
            return try await stores.conversations.recentMessages(
                conversationID: conversationID, limit: min(500, max(1, limit))
            )
        } catch {
            throw Self.surface(error)
        }
    }

    public func runEvents(
        runID: UUID,
        afterSequence: Int = 0,
        limit: Int = 100
    ) async throws -> [RunEventRecord] {
        let stores = try requireStores()
        do {
            return try await stores.runs.events(
                runID: runID,
                afterSequence: max(0, afterSequence),
                limit: min(500, max(1, limit))
            )
        } catch {
            throw Self.surface(error)
        }
    }

    public func runUsage(runID: UUID) async throws -> [RunUsageRecord] {
        let stores = try requireStores()
        do {
            return try await stores.runs.usage(runID: runID)
        } catch {
            throw Self.surface(error)
        }
    }

    /// Read-only recovery point. This stage does not resume it automatically;
    /// the host must first prove ownership and decide whether to resume.
    public func recoveryPoint(runID: UUID) async throws -> AgentCheckpoint? {
        let stores = try requireStores()
        do {
            return try await stores.checkpoints.load(runID: runID)
        } catch {
            throw Self.surface(error)
        }
    }

    // MARK: - Helpers

    private func ensureOpen() throws {
        if closed {
            throw FloeMacSelfCoreError.runtimeClosed
        }
    }

    private func ensureAdmissionStillAllowed() throws {
        guard !shuttingDown, !closed, !authorityCompromised else {
            throw FloeMacSelfCoreError.runtimeClosed
        }
    }

    private func requireAuthority() throws {
        if authorityCompromised {
            throw FloeMacSelfCoreError.authorityLockUnsafe("compromised")
        }
        do {
            try authorityLock.verifyHeld()
        } catch {
            authorityCompromised = true
            throw error
        }
    }

    private func requireStores() throws -> FloeMacSelfStores {
        try ensureOpen()
        guard let stores else {
            throw FloeMacSelfCoreError.notBootstrapped
        }
        return stores
    }

    private func requireAdmissions() throws -> FloeMacSelfAdmissionStore {
        try ensureOpen()
        guard let admissions else {
            throw FloeMacSelfCoreError.notBootstrapped
        }
        return admissions
    }

    private func drainOperations(timeout: TimeInterval) async throws {
        let deadline = ContinuousClock.now + .seconds(max(1, timeout))
        while !activeAdmissions.isEmpty || !closingSessions.isEmpty {
            if ContinuousClock.now >= deadline {
                let busy = activeAdmissions.union(closingSessions)
                    .sorted { $0.uuidString < $1.uuidString }
                throw FloeMacSelfCoreError.shutdownIncomplete(busy)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Best-effort fail-closed cleanup for an admission that never produced a
    /// session. It never clears a row unless the run/message absence or the
    /// no-dispatch proof allows it.
    private func abortAdmission(
        _ admission: FloeMacSelfAdmissionRecord,
        prepareCommitted: Bool,
        reason: String
    ) async {
        guard let admissions else { return }
        if prepareCommitted {
            do {
                _ = try await admissions.abandonBeforeDispatch(
                    conversationID: admission.conversationID,
                    runID: admission.runID,
                    epoch: admission.epoch,
                    reason: reason,
                    dispatchCommitted: false
                )
                return
            } catch {
                // Keep the row unresolved below.
            }
        } else {
            if let released = try? await admissions.releasePrePrepare(
                conversationID: admission.conversationID,
                runID: admission.runID,
                epoch: admission.epoch
            ), released {
                return
            }
            // Conservative fallback: a run row may exist even though the
            // prepare call threw. Only the durable no-dispatch proof can
            // settle it; otherwise the row stays unknown.
            do {
                _ = try await admissions.abandonBeforeDispatch(
                    conversationID: admission.conversationID,
                    runID: admission.runID,
                    epoch: admission.epoch,
                    reason: reason,
                    dispatchCommitted: false
                )
                return
            } catch {
                // Keep the row unresolved below.
            }
        }
        _ = try? await admissions.markSettled(
            conversationID: admission.conversationID,
            runID: admission.runID,
            epoch: admission.epoch,
            confirmed: false,
            detail: reason
        )
    }

    /// Preserve actionable Floe validation errors; wrap opaque storage
    /// failures with a redacted identity.
    private static func surface(_ error: any Error) -> any Error {
        if error is FloeError || error is FloeMacSelfCoreError {
            return error
        }
        return FloeMacSelfCoreError.persistenceUnavailable(
            FloeMacSelfErrorIdentity.render(error)
        )
    }
}

/// Value handle for one exact run. Every command is scoped to the immutable
/// identity; approval commands additionally echo the conversation, run and
/// workspace so a stale UI cannot target another session.
public struct FloeMacSelfSessionHandle: Sendable {
    public let identity: FloeMacSelfSessionIdentity

    private let runtime: FloeMacSelfRuntime
    private let session: FloeMacSelfSession

    init(
        runtime: FloeMacSelfRuntime,
        session: FloeMacSelfSession,
        identity: FloeMacSelfSessionIdentity
    ) {
        self.runtime = runtime
        self.session = session
        self.identity = identity
    }

    /// Bounded newest-events stream. No replay; reconcile with `snapshot()`
    /// and the durable read methods.
    public func events() -> AsyncStream<FloeMacSelfSessionEvent> {
        session.channel.stream()
    }

    public func snapshot() async -> ConversationRunService.Snapshot? {
        await session.snapshot()
    }

    public func phase() async -> FloeMacSelfSessionPhase {
        await session.phaseValue()
    }

    public func summary() async -> FloeMacSelfSessionSummary {
        await session.summary()
    }

    public func resolveApproval(
        _ command: FloeMacSelfApprovalCommand
    ) async -> FloeMacSelfApprovalResolution {
        await session.resolveApproval(command)
    }

    /// Cancels this session's exact run and waits for the runtime's terminal
    /// checkpoint. The real runtime maps a user stop to `checkpointed`; inspect
    /// the receipt's outcome instead of assuming `cancelled`. A dispatch that
    /// may have begun and does not settle within the timeout returns
    /// `.dispatchUnknown` and retains the durable admission.
    public func cancelAndWait(timeout: TimeInterval = 30) async -> FloeMacSelfCancelReceipt {
        await session.cancelAndWait(timeout: timeout)
    }

    public func waitForTerminal(timeout: TimeInterval = 30) async -> FloeMacSelfTerminalReceipt? {
        await session.waitForTerminal(timeout: timeout)
    }

    public func close(allowUnconfirmed: Bool = false) async throws -> FloeMacSelfCloseReceipt {
        try await runtime.closeSession(runID: identity.runID, allowUnconfirmed: allowUnconfirmed)
    }

    public func durableRun() async throws -> RunRecord? {
        try await session.durableRun()
    }

    public func durableMessages(limit: Int = 100) async throws -> [PersistedMessage] {
        try await session.durableMessages(limit: limit)
    }

    public func durableEvents(afterSequence: Int = 0, limit: Int = 100) async throws -> [RunEventRecord] {
        try await session.durableEvents(afterSequence: afterSequence, limit: limit)
    }

    public func recoveryPoint() async throws -> AgentCheckpoint? {
        try await session.recoveryPoint()
    }
}
