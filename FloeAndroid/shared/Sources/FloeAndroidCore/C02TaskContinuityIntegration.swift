// SPDX-License-Identifier: MPL-2.0
//
// C02 — production composition for durable task continuity.
//
// Every adapter below is a narrow bridge over the ORIGINAL authority:
//   * conversation/run rows and task purpose: SQLiteConversationStore /
//     SQLiteRunStore over the generation's SAME DatabaseManager;
//   * execution target pin: C02SQLiteExecutionTargetStore over the SAME
//     database (schema absent => honest empty target, never a second store);
//   * live pause: ConversationRunService.requestStoragePause() (central
//     patch; the ORIGINAL AgentRuntime checkpoint path);
//   * resume: FacadeRunDomain.retry (the ORIGINAL checkpoint/history resume
//     and interrupted-dispatch reconciliation);
//   * questions/approvals: UserQuestionHostAPI/UserQuestionStore and the run
//     event thread — read-only projections only.
//
// Main registers the `floe.continuity/21` branch and the central run gate.
// No build, Gradle, native, device, network or provider action happens here.
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime

// MARK: - Task purpose reader

public struct C02TaskContinuityTaskReader: TaskContinuityTaskReading {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func task(taskID: UUID) async throws -> TaskContinuityTaskDescriptor? {
        let store = SQLiteConversationStore(database: database)
        guard let record = try await store.conversation(id: taskID) else { return nil }
        return TaskContinuityTaskDescriptor(
            taskID: record.id, purpose: record.purpose.rawValue)
    }
}

// MARK: - Execution-target reader

public struct C02TaskContinuityTargetReader: TaskContinuityTargetReading {
    private let database: DatabaseManager
    private let store: C02SQLiteExecutionTargetStore

    public init(database: DatabaseManager) {
        self.database = database
        self.store = C02SQLiteExecutionTargetStore(database: database)
    }

    public func target(taskID: UUID, runID: UUID) async throws
        -> TaskContinuityTargetSnapshot {
        let pin: C02RunTargetPin?
        do {
            pin = try await store.runPin(runID: runID)
        } catch C02ExecutionTargetError.schemaUnavailable {
            return TaskContinuityTargetSnapshot()
        } catch C02ExecutionTargetError.storeCorrupted {
            return TaskContinuityTargetSnapshot()
        } catch {
            throw C02TaskContinuityError.storeUnavailable("targetPin")
        }
        let target: C02ExecutionTarget?
        do {
            target = try await store.target(taskID: taskID)
        } catch C02ExecutionTargetError.schemaUnavailable {
            return TaskContinuityTargetSnapshot()
        } catch {
            target = nil
        }
        return TaskContinuityTargetSnapshot(
            targetRevision: pin?.targetRevision ?? target?.revision,
            targetRootEpoch: pin?.rootEpoch ?? target?.rootEpoch,
            environmentID: pin?.environmentID ?? target?.environmentID,
            workspaceID: target?.workspaceID,
            shellRootHash: pin?.shellRootHash ?? target?.shellRootHash,
            engineOwnerHash: pin?.engineOwnerHash ?? target?.engineOwnerHash,
            unknownOutcomeCount: (try? await unknownOutcomeCount(runID: runID)) ?? 0)
    }

    private func unknownOutcomeCount(runID: UUID) async throws -> Int {
        try await database.reader { db in
            guard try db.tableExists("task_remote_command_receipts") else { return 0 }
            return try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM task_remote_command_receipts
                    WHERE run_id = ? AND state = 'outcomeUnknown'
                    """,
                arguments: [runID.uuidString]) ?? 0
        }
    }
}

// MARK: - Run coordinator

public struct C02TaskContinuityRunCoordinator: TaskContinuityRunCoordinating {
    private let epoch: UInt64
    private let database: DatabaseManager

    public init(epoch: UInt64, database: DatabaseManager) {
        self.epoch = epoch
        self.database = database
    }

    public func run(taskID: UUID, runID: UUID) async throws
        -> TaskContinuityRunDescriptor {
        guard let record = try await SQLiteRunStore(database: database).run(id: runID),
              record.conversationID == taskID else {
            throw C02TaskContinuityError.runNotFound
        }
        return TaskContinuityRunDescriptor(
            taskID: record.conversationID,
            runID: record.id,
            state: record.state,
            conversationMode: record.conversationMode,
            modelID: record.modelID,
            providerID: record.providerID)
    }

    public func latestRun(taskID: UUID) async throws
        -> TaskContinuityRunDescriptor? {
        let records = try await SQLiteRunStore(database: database)
            .recentRuns(conversationID: taskID, limit: 1)
        guard let record = records.first else { return nil }
        return TaskContinuityRunDescriptor(
            taskID: record.conversationID,
            runID: record.id,
            state: record.state,
            conversationMode: record.conversationMode,
            modelID: record.modelID,
            providerID: record.providerID)
    }

    public func requestPause(taskID: UUID, runID: UUID) async -> Bool {
        guard let domain = RunDomainFacade.current(epoch: epoch)?.0,
              let service = await domain.liveService(runID),
              service.conversationID == taskID else {
            return false
        }
        // Central patch on ConversationRunService: write the ORIGINAL
        // checkpoint and park. A failed checkpoint falls back to the original
        // terminal cancel, so no further paid provider turn starts.
        return await service.requestStoragePause()
    }

    public func resume(
        taskID: UUID,
        runID: UUID,
        expectedState: String,
        markerID: String
    ) async throws -> TaskContinuityRunResumeResult {
        guard let domain = RunDomainFacade.current(epoch: epoch)?.0 else {
            throw TaskContinuityResumeRefusal.storeUnavailable("runDomain")
        }
        let receipt = "continuity." + markerID
        let envelope = RunCommandEnvelope(object: [
            "owner": [
                "taskID": taskID.uuidString,
                "runID": runID.uuidString,
            ],
            "revision": [
                "resourceID": RunWireRevision.runResourceID(runID),
                "version": expectedState,
            ],
            "payload": ["expectedState": expectedState],
        ])
        let reply = await domain.retry(envelope: envelope, receipt: receipt)
        switch reply.outcome {
        case .mutationAccepted(let detail):
            return TaskContinuityRunResumeResult(detail: detail)
        case .rejected(let error):
            throw TaskContinuityResumeRefusal.resumeRejected(error.code.rawValue)
        case .completedPage:
            throw TaskContinuityResumeRefusal.resumeRejected("unexpectedPage")
        }
    }
}

// MARK: - Production installation

public enum C02TaskContinuityProduction {
    public struct Components: Sendable {
        public let epoch: UInt64
        public let rootFingerprint: String
        public let store: any TaskContinuityPauseStoring
        public let recovery: any TaskContinuityRecoveryMetadataStoring
        public let coordinator: TaskContinuityCoordinator
        public let bridge: C02TaskContinuityBridge
        public let installed: C02TaskContinuityRuntimeHost.Installed

        public init(
            epoch: UInt64,
            rootFingerprint: String,
            store: any TaskContinuityPauseStoring,
            recovery: any TaskContinuityRecoveryMetadataStoring,
            coordinator: TaskContinuityCoordinator,
            bridge: C02TaskContinuityBridge,
            installed: C02TaskContinuityRuntimeHost.Installed
        ) {
            self.epoch = epoch
            self.rootFingerprint = rootFingerprint
            self.store = store
            self.recovery = recovery
            self.coordinator = coordinator
            self.bridge = bridge
            self.installed = installed
        }
    }

    /// Builds the real graph over the accepted generation. `recoveryDirectory`
    /// is an app-private host directory OUTSIDE the task database (the host
    /// picks it); the sidecar stores only IDs/reason/timestamps.
    public static func make(
        epoch: UInt64,
        database: DatabaseManager,
        rootURL: URL,
        recoveryDirectory: URL,
        liveEpoch: @escaping @Sendable () -> UInt64?
    ) -> Components {
        let fingerprint = TaskContinuityRootFingerprint.make(rootPath: rootURL.path)
        let store = C02SQLiteTaskContinuityStore(database: database)
        let recovery = TaskContinuityFileRecoveryMetadata(directory: recoveryDirectory)
        let probe = TaskContinuityRootStorageProbe(
            database: database, rootURL: rootURL)
        let liveApproval: @Sendable (UUID, UUID) async -> TaskContinuityLiveApproval? = {
            taskID, runID in
            guard let domain = RunDomainFacade.current(epoch: epoch)?.0,
                  let service = await domain.liveService(runID),
                  service.conversationID == taskID else {
                return nil
            }
            let snapshot = await service.snapshot()
            guard let waiting = snapshot.pendingApproval else { return nil }
            return TaskContinuityLiveApproval(
                callID: waiting.toolCall.id,
                tool: waiting.toolCall.toolName,
                reason: waiting.reason,
                requestedAt: waiting.requestedAt)
        }
        let waitProvider = C02SQLiteTaskContinuityWaitProvider(
            database: database,
            epoch: epoch,
            rootFingerprint: fingerprint,
            liveApproval: liveApproval)
        let coordinator = TaskContinuityCoordinator(
            epoch: epoch,
            rootFingerprint: fingerprint,
            taskReader: C02TaskContinuityTaskReader(database: database),
            runCoordinator: C02TaskContinuityRunCoordinator(
                epoch: epoch, database: database),
            targetReader: C02TaskContinuityTargetReader(database: database),
            waitProvider: waitProvider,
            store: store,
            recovery: recovery,
            storage: probe)
        let bridge = C02TaskContinuityBridge(
            epoch: epoch,
            rootFingerprint: fingerprint,
            coordinator: coordinator,
            storageProbe: probe,
            liveEpoch: liveEpoch)
        let installed = C02TaskContinuityRuntimeHost.Installed(
            epoch: epoch,
            rootFingerprint: fingerprint,
            coordinator: coordinator,
            bridge: bridge)
        return Components(
            epoch: epoch,
            rootFingerprint: fingerprint,
            store: store,
            recovery: recovery,
            coordinator: coordinator,
            bridge: bridge,
            installed: installed)
    }

    /// One-line Main composition entry. Main calls this once after the store
    /// cluster is ready and retires the same epoch with the generation.
    @discardableResult
    public static func install(
        epoch: UInt64,
        database: DatabaseManager,
        rootURL: URL,
        recoveryDirectory: URL,
        liveEpoch: @escaping @Sendable () -> UInt64?
    ) -> Components {
        let components = make(
            epoch: epoch,
            database: database,
            rootURL: rootURL,
            recoveryDirectory: recoveryDirectory,
            liveEpoch: liveEpoch)
        C02TaskContinuityRuntimeHost.install(components.installed)
        return components
    }
}
