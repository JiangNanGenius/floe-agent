// SPDX-License-Identifier: MPL-2.0
//
// C02 — trusted-host bindings and production adapters.
//
// Two surfaces live here:
//
// 1. `C02TargetBridge` — the reserved trusted-host channel `floe.target/19`.
//    It is host-only, bounded JSON, and mirrors C05's channel discipline. It
//    is NOT a BridgeV3 matrix command, NOT a model tool and cannot widen a
//    task/run/environment permission.
//
// 2. Real production adapters over existing authorities:
//      * C01 workspace ownership + C01ProjectRootLayout;
//      * the host-registered G073 runtime environment metadata snapshot;
//      * the existing RemoteHostStore/known_hosts credential gateway;
//      * the existing RunDomainFacade deletion/drain lifecycle and G03 job
//        owner, used here as an explicit migration fence (released with
//        `abortDeletionFence`, never committed as a deletion);
//      * the existing ShellSessionCenter environment-scoped close;
//      * the real C02 SSH adapter.
//
// Main owns the C ABI branch, RuntimeHost/Composition wiring and the
// coordinated schema registration. This file is source-only.
import Foundation
import Dispatch
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeSSH
import FloeTools
import FloeAndroidShellTools

// MARK: - Bridge

public enum BridgeV19 {
    public static let version = C02ExecutionTargetWire.version
    public static let schema = C02ExecutionTargetWire.schema
    public static let maximumRequestBytes = C02ExecutionTargetWire.maximumRequestBytes
    public static let maximumResponseBytes = C02ExecutionTargetWire.maximumResponseBytes
    public static let modelTools = false
}

public final class C02TargetBridge: @unchecked Sendable {
    private let epoch: UInt64
    private let domain: C02ExecutionTargetDomain
    private let adapter: C02SSHExecutionAdapter

    public init(epoch: UInt64, domain: C02ExecutionTargetDomain, adapter: C02SSHExecutionAdapter) {
        self.epoch = epoch
        self.domain = domain
        self.adapter = adapter
    }

    public func handle(requestData: Data, fallbackRequestID: String?) -> [String: Any] {
        var requestID = fallbackRequestID
        func failure(_ error: C02ExecutionTargetError, operation: String?) -> [String: Any] {
            var value: [String: Any] = [
                "ok": false,
                "code": error.code,
                "retryable": error.retryable,
                "message": error.message,
                "schema": C02ExecutionTargetWire.schema,
            ]
            if let operation { value["operation"] = operation }
            if let requestID { value["requestID"] = requestID }
            return value
        }
        guard requestData.count <= C02ExecutionTargetWire.maximumRequestBytes else {
            return failure(C02ExecutionTargetError.invalidTarget("requestTooLarge"), operation: nil)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any],
              let version = Self.exactInt(object["version"]), version == C02ExecutionTargetWire.version,
              let operation = Self.boundedString(object["operation"], 64) else {
            return failure(C02ExecutionTargetError.invalidTarget("request"), operation: nil)
        }
        requestID = Self.boundedString(object["requestID"], 256) ?? requestID
        let request = C02TargetRequest(object)

        switch operation {
        case "handshake", "c02.capabilities":
            var value: [String: Any] = [
                "ok": true,
                "schema": C02ExecutionTargetWire.schema,
                "channel": C02ExecutionTargetWire.version,
                "coreReady": epoch > 0,
                "epoch": epoch,
                "modelTools": false,
                "maximumRequestBytes": C02ExecutionTargetWire.maximumRequestBytes,
                "maximumResponseBytes": C02ExecutionTargetWire.maximumResponseBytes,
            ]
            if let requestID { value["requestID"] = requestID }
            return value
        case "c02.target.options", "c02.target.snapshot":
            guard let taskID = request.uuid("taskID") else {
                return failure(C02ExecutionTargetError.invalidTarget("taskID"), operation: operation)
            }
            return awaitResult(operation: operation, requestID: requestID) {
                let options = try await self.domain.options(taskID: taskID)
                var value: [String: Any] = [
                    "taskID": taskID.uuidString,
                    "remoteExecutionAllowed": options.remoteExecutionAllowed,
                    "hasUsableLocalEnvironment": options.hasUsableLocalEnvironment,
                    "canCreateInitialTarget": options.canCreateInitialTarget,
                    "localEnvironments": options.localEnvironments.map(Self.localEnvironmentWire),
                    "remoteHosts": options.remoteHosts.map(Self.remoteHostWire),
                ]
                if let current = options.current {
                    value["target"] = Self.targetWire(current)
                }
                if let migration = options.activeMigration {
                    value["migration"] = Self.migrationWire(migration)
                }
                return Self.payload(value)
            }
        case "c02.target.initialize":
            guard let taskID = request.uuid("taskID"),
                  let destination = request.destination() else {
                return failure(C02ExecutionTargetError.invalidTarget("destination"), operation: operation)
            }
            return awaitResult(operation: operation, requestID: requestID) {
                let target = try await self.domain.initialize(taskID: taskID, selection: destination)
                return Self.payload(["target": Self.targetWire(target)])
            }
        case "c02.target.checkMigration":
            guard let taskID = request.uuid("taskID"),
                  let expectedRevision = request.int64("expectedRevision"),
                  let destination = request.destination() else {
                return failure(C02ExecutionTargetError.invalidTarget("migrationRequest"), operation: operation)
            }
            return awaitResult(operation: operation, requestID: requestID) {
                let preview = try await self.domain.previewMigration(
                    taskID: taskID,
                    expectedRevision: expectedRevision,
                    destination: destination
                )
                var value: [String: Any] = [
                    "taskID": taskID.uuidString,
                    "source": Self.targetWire(preview.source),
                    "destination": Self.targetWire(preview.destination),
                    "affectedWork": Self.workWire(preview.affectedWork),
                    "requiresDrain": preview.requiresDrain,
                    "canCommit": preview.canCommit,
                    "generatedAt": Self.iso(preview.generatedAt),
                    "expiresAt": Self.iso(preview.expiresAt),
                ]
                if let challenge = preview.remoteHostKeyChallenge {
                    value["challenge"] = Self.challengeWire(challenge)
                }
                return Self.payload(value)
            }
        case "c02.target.beginMigration":
            guard let taskID = request.uuid("taskID"),
                  let expectedRevision = request.int64("expectedRevision"),
                  let destination = request.destination() else {
                return failure(C02ExecutionTargetError.invalidTarget("migrationRequest"), operation: operation)
            }
            let drainSeconds = max(1, min(request.int("drainTimeoutSeconds") ?? 30, 120))
            return awaitResult(operation: operation, requestID: requestID) {
                let commit = try await self.domain.beginMigration(
                    taskID: taskID,
                    expectedRevision: expectedRevision,
                    destination: destination,
                    drainTimeout: .seconds(drainSeconds)
                )
                let finished = try? await self.domain.completeMigration(commit.migration)
                return Self.payload([
                    "target": Self.targetWire(commit.target),
                    "migration": Self.migrationWire(finished ?? commit.migration),
                ])
            }
        case "c02.target.migration":
            guard let taskID = request.uuid("taskID") else {
                return failure(C02ExecutionTargetError.invalidTarget("taskID"), operation: operation)
            }
            return awaitResult(operation: operation, requestID: requestID) {
                var migration = try await self.domain.migrationStatus(taskID: taskID)
                if let committed = migration, committed.phase == .committed {
                    migration = (try? await self.domain.completeMigration(committed)) ?? committed
                }
                return Self.payload(["migration": migration.map(Self.migrationWire) ?? NSNull()])
            }
        case "c02.target.cancelMigration":
            guard let taskID = request.uuid("taskID"),
                  let expectedRevision = request.int64("expectedRevision") else {
                return failure(C02ExecutionTargetError.invalidTarget("migrationRequest"), operation: operation)
            }
            return awaitResult(operation: operation, requestID: requestID) {
                let migration = try await self.domain.cancelMigration(
                    taskID: taskID, expectedRevision: expectedRevision)
                return Self.payload(["migration": migration.map(Self.migrationWire) ?? NSNull()])
            }
        case "c02.target.approveHostKey":
            guard let taskID = request.uuid("taskID"),
                  let challengeID = request.uuid("challengeID"),
                  let accept = request.bool("accept") else {
                return failure(C02ExecutionTargetError.invalidTarget("hostKeyRequest"), operation: operation)
            }
            let replaceChanged = request.bool("replaceChanged") ?? false
            let expectedFingerprint = request.string("expectedFingerprint")
            return awaitResult(operation: operation, requestID: requestID) {
                let approval = try await self.domain.approveHostKey(
                    taskID: taskID,
                    challengeID: challengeID,
                    accept: accept,
                    replaceChanged: replaceChanged,
                    expectedFingerprint: expectedFingerprint
                )
                return Self.payload([
                    "trusted": approval.trusted,
                    "changed": approval.changed,
                    "challengeID": approval.challengeID.uuidString,
                    "fingerprintSHA256": approval.fingerprintSHA256 ?? NSNull(),
                ])
            }
        default:
            return failure(C02ExecutionTargetError.invalidTarget("unknownOperation"), operation: operation)
        }
    }

    fileprivate struct C02BridgePayload: @unchecked Sendable {
        let value: [String: Any]
    }

    private static func payload(_ value: [String: Any]) -> C02BridgePayload {
        C02BridgePayload(value: value)
    }

    private func awaitResult(
        operation: String,
        requestID: String?,
        _ body: @escaping @Sendable () async throws -> C02BridgePayload
    ) -> [String: Any] {
        // This bridge is synchronous at the C ABI boundary. The app must call
        // it from its trusted IO executor; a bounded semaphore waits for the
        // domain/adapter result without touching the main thread.
        let box = C02BridgeResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do {
                let value = try await body()
                box.setSuccess(value)
            } catch let error as C02ExecutionTargetError {
                box.setTargetFailure(error)
            } catch let error as C02SSHAdapterError {
                box.setSSHFailure(error)
            } catch {
                box.setUnknownFailure()
            }
            semaphore.signal()
        }
        let wait = semaphore.wait(timeout: .now() + .seconds(180))
        if case .timedOut = wait {
            task.cancel()
        }
        guard let result = box.value else {
            return [
                "ok": false,
                "code": "bridgeTimeout",
                "retryable": true,
                "message": "The execution-target operation did not complete in time.",
                "schema": C02ExecutionTargetWire.schema,
                "operation": operation,
            ].merging(requestID.map { ["requestID": $0] } ?? [:]) { $1 }
        }
        switch result {
        case .success(let value):
            var response = value.value
            response["ok"] = true
            response["schema"] = C02ExecutionTargetWire.schema
            response["operation"] = operation
            if let requestID { response["requestID"] = requestID }
            return response
        case .targetFailure(let error):
            var response: [String: Any] = [
                "ok": false, "code": error.code, "retryable": error.retryable,
                "message": error.message, "schema": C02ExecutionTargetWire.schema,
                "operation": operation,
            ]
            if let requestID { response["requestID"] = requestID }
            if case .hostKeyApprovalRequired(let challenge) = error {
                response["challenge"] = Self.challengeWire(challenge)
            }
            return response
        case .sshFailure(let error):
            var response: [String: Any] = [
                "ok": false, "code": error.code, "retryable": false,
                "message": error.message, "schema": C02ExecutionTargetWire.schema,
                "operation": operation,
            ]
            if let requestID { response["requestID"] = requestID }
            if case .hostKeyApprovalRequired(let challenge) = error {
                response["challenge"] = Self.challengeWire(challenge)
            }
            return response
        case .unknown:
            return [
                "ok": false, "code": "internalFailure", "retryable": false,
                "message": "The execution-target operation failed.",
                "schema": C02ExecutionTargetWire.schema, "operation": operation,
            ].merging(requestID.map { ["requestID": $0] } ?? [:]) { $1 }
        }
    }

    // MARK: Wire helpers

    private static func targetWire(_ target: C02ExecutionTarget) -> [String: Any] {
        var value: [String: Any] = [
            "taskID": target.taskID.uuidString,
            "revision": target.revision,
            "kind": target.kind.rawValue,
            "environmentID": target.environmentID,
            "workspaceID": target.workspaceID.uuidString,
            "rootEpoch": target.rootEpoch,
            "provenance": target.provenance.rawValue,
            "createdAt": iso(target.createdAt),
            "updatedAt": iso(target.updatedAt),
        ]
        if let projectID = target.projectID { value["projectID"] = projectID.uuidString }
        if let remote = target.remote {
            value["remoteHostID"] = remote.hostID.uuidString
            value["remoteOS"] = remote.operatingSystem
            value["remoteArchitecture"] = remote.architecture
            value["remoteGeneration"] = remote.runtimeGeneration
            if let distribution = remote.distribution { value["remoteDistribution"] = distribution }
            // The remote task root is deliberately not exposed: it is an
            // execution-authority path, not a UI concern.
        }
        return value
    }

    private static func localEnvironmentWire(_ option: C02LocalEnvironmentOption) -> [String: Any] {
        var value: [String: Any] = [
            "id": option.id, "kind": option.kind, "state": option.state,
            "requiresRebuild": option.requiresRebuild,
        ]
        if let name = option.name { value["name"] = name }
        return value
    }

    private static func remoteHostWire(_ option: C02RemoteHostOption) -> [String: Any] {
        [
            "id": option.id.uuidString,
            "displayName": option.displayName,
            "isExecutionEnvironment": option.isExecutionEnvironment,
            "sshConfigured": option.sshConfigured,
        ]
    }

    private static func workWire(_ work: C02OwnedWorkSummary) -> [String: Any] {
        [
            "liveRuns": work.liveRuns,
            "liveChildRuns": work.liveChildRuns,
            "activeJobs": work.activeJobs,
            "shellSessions": work.shellSessions,
            "managedServices": work.managedServices,
            "unknownOutcomes": work.unknownOutcomes,
            "files": work.files,
            "bytes": work.bytes,
        ]
    }

    private static func migrationWire(_ migration: C02TargetMigration) -> [String: Any] {
        var value: [String: Any] = [
            "id": migration.id.uuidString,
            "taskID": migration.taskID.uuidString,
            "phase": migration.phase.rawValue,
            "revision": migration.revision,
            "cancellationRequested": migration.cancellationRequested,
            "affectedWork": workWire(migration.affectedWork),
            "source": targetWire(migration.source),
            "destination": targetWire(migration.destination),
            "createdAt": iso(migration.createdAt),
            "updatedAt": iso(migration.updatedAt),
        ]
        if let receipt = migration.drainReceipt {
            value["drainReceipt"] = [
                "complete": receipt.complete,
                "timedOut": receipt.timedOut,
                "stoppedRuns": receipt.stoppedRuns,
                "stoppedJobs": receipt.stoppedJobs,
                "closedSessions": receipt.closedSessions,
                "closedServices": receipt.closedServices,
                "unknownOutcomes": receipt.unknownOutcomes,
            ]
        }
        if let failure = migration.failureCode { value["failureCode"] = failure }
        return value
    }

    private static func challengeWire(_ challenge: C02RemoteHostKeyChallenge) -> [String: Any] {
        [
            "id": challenge.id.uuidString,
            "taskID": challenge.taskID.uuidString,
            "hostID": challenge.hostID.uuidString,
            "address": challenge.address,
            "port": challenge.port,
            "keyType": challenge.keyType,
            "fingerprintSHA256": challenge.fingerprintSHA256,
            "expectedFingerprintSHA256": challenge.expectedFingerprintSHA256 ?? NSNull(),
            "kind": challenge.kind.rawValue,
            "createdAt": iso(challenge.createdAt),
            "expiresAt": iso(challenge.expiresAt),
        ]
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    fileprivate static func exactInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              String(cString: number.objCType) != "d" else { return nil }
        return number.intValue
    }

    fileprivate static func boundedString(_ value: Any?, _ maximum: Int) -> String? {
        guard let string = value as? String,
              !string.isEmpty, string.utf8.count <= maximum,
              !string.contains("\0") else { return nil }
        return string
    }
}

private struct C02TargetRequest {
    private let object: [String: Any]

    init(_ object: [String: Any]) { self.object = object }

    func string(_ key: String) -> String? {
        C02TargetBridge.boundedString(object[key], 4_096)
    }

    func bool(_ key: String) -> Bool? {
        if let value = object[key] as? Bool { return value }
        if let number = object[key] as? NSNumber { return number.boolValue }
        return nil
    }

    func int(_ key: String) -> Int? {
        C02TargetBridge.exactInt(object[key])
    }

    func int64(_ key: String) -> Int64? {
        guard let value = C02TargetBridge.exactInt(object[key]) else { return nil }
        return Int64(value)
    }

    func uuid(_ key: String) -> UUID? {
        guard let string = C02TargetBridge.boundedString(object[key], 64) else { return nil }
        return UUID(uuidString: string)
    }

    func destination() -> C02ExecutionTargetSelection? {
        guard let destination = object["destination"] as? [String: Any],
              let kindName = destination["kind"] as? String,
              let kind = C02ExecutionTargetKind(rawValue: kindName) else { return nil }
        let explicit = (destination["explicitUserChoice"] as? Bool)
            ?? (destination["explicitUserChoice"] as? NSNumber)?.boolValue
        guard explicit == true else { return nil }
        let environmentID = C02TargetBridge.boundedString(destination["environmentID"], 64)
        let host = C02TargetBridge.boundedString(destination["remoteHostID"], 64)
            .flatMap(UUID.init(uuidString:))
        switch kind {
        case .localLinux:
            guard let environmentID else { return nil }
            return C02ExecutionTargetSelection(
                kind: .localLinux,
                environmentID: environmentID,
                remoteHostID: nil,
                explicitUserChoice: true
            )
        case .ssh:
            guard let host else { return nil }
            return C02ExecutionTargetSelection(
                kind: .ssh,
                environmentID: nil,
                remoteHostID: host,
                explicitUserChoice: true
            )
        }
    }
}

private enum C02BridgeResult {
    case success(C02TargetBridge.C02BridgePayload)
    case targetFailure(C02ExecutionTargetError)
    case sshFailure(C02SSHAdapterError)
    case unknown
}

private final class C02BridgeResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: C02BridgeResult?

    var value: C02BridgeResult? {
        lock.lock(); defer { lock.unlock() }; return stored
    }

    func setSuccess(_ value: C02TargetBridge.C02BridgePayload) { lock.lock(); stored = .success(value); lock.unlock() }
    func setTargetFailure(_ error: C02ExecutionTargetError) { lock.lock(); stored = .targetFailure(error); lock.unlock() }
    func setSSHFailure(_ error: C02SSHAdapterError) { lock.lock(); stored = .sshFailure(error); lock.unlock() }
    func setUnknownFailure() { lock.lock(); stored = .unknown; lock.unlock() }
}

// MARK: - Production ownership

/// C01 workspace ownership + the three distinct runtime identities.
public struct C02SQLiteTargetOwnershipProvider: C02ExecutionTargetOwnershipProviding {
    private let conversationStore: SQLiteConversationStore
    private let workspaceStore: SQLiteWorkspaceStore
    private let storageRoot: URL
    private let rootEpoch: @Sendable () -> UInt64?

    public init(
        database: DatabaseManager,
        storageRoot: URL,
        rootEpoch: @escaping @Sendable () -> UInt64? = { G02NativeRootEpoch.readback() }
    ) {
        self.conversationStore = SQLiteConversationStore(database: database)
        self.workspaceStore = SQLiteWorkspaceStore(database: database)
        self.storageRoot = storageRoot.standardizedFileURL
        self.rootEpoch = rootEpoch
    }

    public func ownership(taskID: UUID) async throws -> C02TargetOwnership? {
        guard let conversation = try await conversationStore.conversation(id: taskID),
              conversation.purpose == .ordinary,
              let workspaceID = try await workspaceStore.workspaceID(conversationID: taskID),
              let workspace = try await workspaceStore.workspace(id: workspaceID) else {
            return nil
        }
        let root: URL
        let projectID: UUID?
        if C01ProjectRootLayout.isManagedProject(workspace) {
            let state = C01ProjectRootLayout.inspectProjectDirectory(
                rootPath: storageRoot.path, projectID: workspace.id)
            guard state == .available else { return nil }
            root = URL(fileURLWithPath: C01ProjectRootLayout.projectDirectory(
                rootPath: storageRoot.path, projectID: workspace.id), isDirectory: true)
            projectID = workspace.id
        } else if workspace.kind == .privateTask,
                  workspace.internalRelativePath == "PrivateTasks/\(taskID.uuidString)" {
            let candidate = storageRoot
                .appendingPathComponent("Workspace/PrivateTasks/\(taskID.uuidString)", isDirectory: true)
            guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
            root = candidate
            projectID = nil
        } else {
            return nil
        }
        let canonical = root.standardizedFileURL
        guard canonical.path.hasPrefix("/") else { return nil }
        let shellHash = FloeDigest.sha256Hex(Data(canonical.path.utf8))
        let engineProject = LinuxShellProjectMapping.projectID(
            forCanonicalCoreWorkspaceRoot: canonical)
        let engineHash = FloeDigest.sha256Hex(
            Data("linux-engine-project:v1:\(engineProject.uuidString.lowercased())".utf8))
        guard let rootEpoch = rootEpoch(), rootEpoch > 0 else {
            throw C02ExecutionTargetError.rootEpochUnavailable
        }
        return C02TargetOwnership(
            taskID: taskID,
            projectID: projectID,
            workspaceID: workspace.id,
            workspaceRoot: canonical,
            shellRootHash: shellHash,
            engineOwnerHash: engineHash,
            rootEpoch: rootEpoch
        )
    }
}

// MARK: - Production policy

public struct C02SQLiteTargetPolicyProvider: C02ExecutionTargetPolicyProviding {
    private let conversationStore: SQLiteConversationStore
    private let workspaceStore: SQLiteWorkspaceStore

    public init(database: DatabaseManager) {
        self.conversationStore = SQLiteConversationStore(database: database)
        self.workspaceStore = SQLiteWorkspaceStore(database: database)
    }

    public func policy(taskID: UUID) async throws -> C02TargetTaskPolicy {
        guard let conversation = try await conversationStore.conversation(id: taskID) else {
            throw C02ExecutionTargetError.workspaceOwnershipMismatch
        }
        let policy = try await workspaceStore.taskPolicy(conversationID: taskID)
        return C02TargetTaskPolicy(
            isTemporary: conversation.purpose == .temporary,
            isOrdinary: conversation.purpose == .ordinary,
            remoteExecutionAllowed: policy.remoteExecutionAllowed ?? false
        )
    }
}

// MARK: - Production environment host snapshot

/// Adapts the EXISTING host-registered G07.3 environment snapshot to the
/// metadata-source seam. It does not add a registry or refresh policy.
public struct C02ScheduleMetadataSource: G073EnvironmentMetadataSource {
    private let ownership: G073ScheduleEnvironmentOwnership

    public init(ownership: G073ScheduleEnvironmentOwnership) {
        self.ownership = ownership
    }

    public func environmentMetadata(id: String) async -> G073EnvironmentMetadata? {
        ownership.metadata(id: id)
    }

    public func allEnvironmentMetadata() async -> [G073EnvironmentMetadata] {
        ownership.allMetadata()
    }
}

public struct C02MetadataTargetEnvironmentProvider: C02ExecutionTargetEnvironmentProviding {
    private let metadata: any G073EnvironmentMetadataSource
    private let hosts: RemoteHostStore
    private let liveCatalog: (@Sendable (C02TargetOwnership) async throws -> [C02RuntimeEnvironmentCatalog.Row])?

    public init(metadata: any G073EnvironmentMetadataSource, hosts: RemoteHostStore,
                liveCatalog: (@Sendable (C02TargetOwnership) async throws -> [C02RuntimeEnvironmentCatalog.Row])? = nil) {
        self.metadata = metadata
        self.hosts = hosts
        self.liveCatalog = liveCatalog
    }

    public func localEnvironments(
        taskID: UUID,
        ownership: C02TargetOwnership
    ) async throws -> [C02LocalEnvironmentFacts] {
        if let liveCatalog {
            return try await liveCatalog(ownership).filter { row in
                row.kind == "project" || (row.kind == "session" &&
                    row.ownerID?.lowercased() == taskID.uuidString.lowercased())
            }.map { $0.targetFacts(projectOwner: ownership.workspaceID.uuidString) }
        }
        let rows = await metadata.allEnvironmentMetadata()
        return rows
            .filter { row in
                switch row.kind {
                case .session:
                    return row.ownerID?.lowercased() == taskID.uuidString.lowercased()
                case .project:
                    return row.ownerID?.lowercased() == ownership.workspaceID.uuidString.lowercased()
                case .template, .shared:
                    return false
                }
            }
            .map(Self.facts)
    }

    public func validateLocal(
        environmentID: String,
        taskID: UUID,
        ownership: C02TargetOwnership
    ) async throws -> C02LocalEnvironmentFacts {
        if liveCatalog != nil {
            guard let facts = try await localEnvironments(taskID: taskID, ownership: ownership)
                .first(where: { $0.id == environmentID }) else {
                throw C02ExecutionTargetError.environmentMissing(environmentID)
            }
            return facts
        }
        guard let row = await metadata.environmentMetadata(id: environmentID) else {
            throw C02ExecutionTargetError.environmentMissing(environmentID)
        }
        guard row.authorizes(
            projectOwner: ownership.workspaceID.uuidString,
            sessionOwner: taskID.uuidString
        ) else {
            throw C02ExecutionTargetError.environmentUnavailable(environmentID)
        }
        return Self.facts(row)
    }

    public func remoteHosts(taskID: UUID) async throws -> [C02RemoteHostSummary] {
        let rows = try await hosts.hosts()
        return rows.compactMap(Self.remoteSummary)
    }

    public func validateRemoteHost(hostID: UUID, taskID: UUID) async throws -> C02RemoteHostSummary {
        guard let row = try await hosts.host(id: hostID) else {
            throw C02ExecutionTargetError.remoteHostNotFound
        }
        guard let summary = Self.remoteSummary(row) else {
            throw C02ExecutionTargetError.remoteNotExecutionEnvironment
        }
        return summary
    }

    private static func facts(_ row: G073EnvironmentMetadata) -> C02LocalEnvironmentFacts {
        C02LocalEnvironmentFacts(
            id: row.id,
            name: row.name,
            kind: row.kind.rawValue,
            state: row.state,
            requiresRebuild: row.requiresRebuild,
            executionBackend: row.executionBackend,
            ownerID: row.ownerID
        )
    }

    private static func remoteSummary(_ row: RemoteHostStore.StoredHost) -> C02RemoteHostSummary? {
        guard let auth = try? JSONDecoder().decode(
            SSHAuthMethod.self, from: Data(row.authJSON.utf8)),
              auth != .none else { return nil }
        guard row.isRemoteExecutionEnvironment ?? true else { return nil }
        let profile = try? RemoteHostProfile(stored: row)
        var pinned: String?
        if let policy = profile?.hostKeyPolicy, case .pinned(let fingerprint) = policy {
            pinned = fingerprint
        }
        return C02RemoteHostSummary(
            id: row.id,
            displayName: row.displayName,
            address: row.address,
            port: row.port,
            user: row.user,
            isExecutionEnvironment: true,
            sshConfigured: true,
            hostKeyPinnedFingerprint: pinned
        )
    }
}

// MARK: - Production host trust

public struct C02RemoteHostTrustAdapter: C02RemoteHostTrusting {
    private let store: RemoteHostStore

    public init(store: RemoteHostStore) { self.store = store }

    public func trust(
        hostID: UUID,
        address: String,
        port: Int,
        keyType: String,
        fingerprintSHA256: String
    ) async throws {
        try await store.trust(KnownHostRecord(
            hostID: hostID,
            address: address,
            port: port,
            keyType: keyType,
            fingerprintSHA256: fingerprintSHA256
        ))
        // Keep an explicitly pinned profile coherent with the approved
        // replacement. A non-pinned profile is unchanged.
        do {
            if let row = try await store.host(id: hostID),
               var profile = try? RemoteHostProfile(stored: row),
               case .pinned = profile.hostKeyPolicy {
                profile.hostKeyPolicy = .pinned(
                    fingerprintSHA256: SSHHostKeyFingerprint.normalize(fingerprintSHA256))
                try await store.saveHost(profile.storedHost())
            }
        } catch {
            // The known_hosts trust write already succeeded. A profile
            // read-back failure is surfaced by the next connection as a
            // changed-key challenge; it is never silently replaced by a
            // different key.
        }
    }
}

// MARK: - Production migration drain

/// Uses the EXISTING run-domain deletion fence as a migration fence: it
/// fences new launches, drains the conversation's owned run work, closes the
/// old environment's shell sessions/jobs and then ABORTS the fence. It never
/// calls `commitDeletionFence`, so no conversation/workspace row is deleted.
public actor C02RuntimeOwnedWorkDrainAdapter: C02ExecutionTargetDraining {
    private let epoch: UInt64
    private let database: DatabaseManager
    private let lifecycle: @Sendable (UInt64) async -> (any ConversationDeletionLifecycle)?
    private let shellSessions: @Sendable () async -> ShellSessionCenter?
    private let jobOwner: @Sendable () async -> G03JobLifecycle?
    private let remoteSessions: @Sendable () async -> C02SSHExecutionAdapter?
    private var fences: [UUID: ConversationDeletionFence] = [:]

    public init(
        epoch: UInt64,
        database: DatabaseManager,
        lifecycle: @escaping @Sendable (UInt64) async -> (any ConversationDeletionLifecycle)? = { epoch in
            RunDomainFacade.current(epoch: epoch)?.1
        },
        shellSessions: @escaping @Sendable () async -> ShellSessionCenter? = {
            RuntimeFacadeLinuxBindings.shared.components?.sessions
        },
        jobOwner: @escaping @Sendable () async -> G03JobLifecycle? = {
            G03JobLifecycle.current
        },
        remoteSessions: @escaping @Sendable () async -> C02SSHExecutionAdapter? = { nil }
    ) {
        self.epoch = epoch
        self.database = database
        self.lifecycle = lifecycle
        self.shellSessions = shellSessions
        self.jobOwner = jobOwner
        self.remoteSessions = remoteSessions
    }

    public func preview(
        taskID: UUID,
        environmentID: String,
        targetRevision: Int64
    ) async throws -> C02OwnedWorkSummary {
        let runStore = SQLiteRunStore(database: database)
        let childStore = SQLiteChildRunStore(database: database)
        let jobStore = BackgroundJobStore(database: database)
        let terminal: Set<String> = ["completed", "failed", "checkpointed", "interrupted"]
        let runs = try await runStore.runs(conversationID: taskID)
            .filter { !terminal.contains($0.state) }.count
        let children = try await childStore.children(conversationID: taskID)
            .filter { !["completed", "cancelled"].contains($0.state.rawValue) }.count
        let jobs = try await jobStore.jobs(conversationID: taskID, limit: 200)
            .filter { $0.state == .queued || $0.state == .running }
        let serviceJobs = jobs.filter { $0.targetTool == "exec.localService" }.count
        let sessionCount: Int
        if let sessions = await self.shellSessions() {
            sessionCount = await sessions.activeSessionIDs(environmentID: environmentID).count
        } else {
            sessionCount = 0
        }
        let unknown = (try? await database.reader { db in
            guard try db.tableExists("task_remote_command_receipts") else { return 0 }
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM task_remote_command_receipts
                WHERE task_id = ? AND state = 'outcomeUnknown'
                """, arguments: [taskID.uuidString]) ?? 0
        }) ?? 0
        return C02OwnedWorkSummary(
            liveRuns: runs,
            liveChildRuns: children,
            activeJobs: jobs.count - serviceJobs,
            shellSessions: sessionCount,
            managedServices: serviceJobs,
            unknownOutcomes: unknown
        )
    }

    public func fence(
        taskID: UUID,
        environmentID: String,
        targetRevision: Int64,
        rootEpoch: UInt64
    ) async throws -> C02OwnedWorkFence {
        guard let lifecycle = await self.lifecycle(epoch) else {
            throw C02ExecutionTargetError.runtimeIdentityUnavailable
        }
        let token = UUID()
        let deletionFence = try await lifecycle.beginDeletionFence(
            conversationID: taskID, epoch: epoch, operationID: token)
        let fence = C02OwnedWorkFence(
            id: token,
            taskID: taskID,
            environmentID: environmentID,
            targetRevision: targetRevision,
            rootEpoch: rootEpoch,
            createdAt: Date()
        )
        fences[token] = deletionFence
        return fence
    }

    public func drain(
        _ fence: C02OwnedWorkFence,
        timeout: Duration
    ) async throws -> C02DrainReceipt {
        guard let lifecycle = await self.lifecycle(epoch),
              let deletionFence = fences[fence.id] else {
            return C02DrainReceipt(
                complete: false, timedOut: false, detailCode: "fenceUnavailable")
        }
        let report = try await Self.withTimeout(timeout: timeout) {
            try await lifecycle.drainOwnedWork(fence: deletionFence)
        }
        guard let report else {
            return C02DrainReceipt(
                complete: false, timedOut: true,
                stoppedRuns: 0, stoppedJobs: 0, closedSessions: 0,
                closedServices: 0, unknownOutcomes: 0,
                detailCode: "drainDeadline")
        }
        // Close the exact old-environment interactive shell sessions.
        if let sessions = await self.shellSessions() {
            await sessions.closeAll(environmentID: fence.environmentID)
        }
        // Request cancellation of the conversation's remaining durable jobs.
        if let owner = await self.jobOwner() {
            let jobs = (try? await BackgroundJobStore(database: database)
                .jobs(conversationID: fence.taskID, limit: 200)) ?? []
            for job in jobs where job.state == .queued || job.state == .running {
                await owner.requestCancel(jobID: job.id)
            }
        }
        // Close model-owned remote sessions for the old revision.
        if let adapter = await self.remoteSessions() {
            await adapter.closeSessions(
                taskID: fence.taskID,
                targetRevision: fence.targetRevision,
                rootEpoch: fence.rootEpoch
            )
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var latest = C02OwnedWorkSummary()
        while ContinuousClock.now < deadline {
            latest = try await preview(
                taskID: fence.taskID,
                environmentID: fence.environmentID,
                targetRevision: fence.targetRevision
            )
            if !latest.hasLiveWork {
                return C02DrainReceipt(
                    complete: true,
                    timedOut: false,
                    stoppedRuns: max(report.runServicesCancelled, latest.liveRuns),
                    stoppedJobs: max(report.ownedTasksDrained, latest.activeJobs),
                    closedSessions: latest.shellSessions,
                    closedServices: latest.managedServices,
                    unknownOutcomes: latest.unknownOutcomes
                )
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return C02DrainReceipt(
            complete: false,
            timedOut: true,
            stoppedRuns: report.runServicesCancelled,
            stoppedJobs: report.ownedTasksDrained,
            closedSessions: latest.shellSessions,
            closedServices: latest.managedServices,
            unknownOutcomes: latest.unknownOutcomes,
            detailCode: "liveWorkRemains"
        )
    }

    public func release(_ fence: C02OwnedWorkFence) async {
        guard let lifecycle = await self.lifecycle(epoch),
              let deletionFence = fences.removeValue(forKey: fence.id) else { return }
        _ = await lifecycle.abortDeletionFence(deletionFence)
    }

    public func closeRemoteSessions(taskID: UUID, targetRevision: Int64, rootEpoch: UInt64) async {
        if let adapter = await self.remoteSessions() {
            await adapter.closeSessions(
                taskID: taskID, targetRevision: targetRevision, rootEpoch: rootEpoch)
        }
    }

    private static func withTimeout<T: Sendable>(
        timeout: Duration,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() as T? }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - exec.shell routing bridge

/// Concrete bridge the Main-owned ShellTools seam calls for a context that
/// resolves to an SSH target. Returning nil keeps the existing local Linux
/// backend path unchanged.
public final class C02RemoteShellBridge: @unchecked Sendable {
    private let domain: C02ExecutionTargetDomain
    private let adapter: C02SSHExecutionAdapter

    public init(domain: C02ExecutionTargetDomain, adapter: C02SSHExecutionAdapter) {
        self.domain = domain
        self.adapter = adapter
    }

    public func execute(_ request: C02RemoteShellRequest) async -> ShellRunOutcome? {
        guard let taskID = request.context.conversationID,
              !request.context.temporaryReadOnly else {
            return nil
        }
        let target: C02ExecutionTarget?
        do {
            target = try await domain.executionTarget(taskID: taskID)
        } catch {
            return .failed(message: "transport=ssh status=targetUnavailable reason=executionTargetReadFailed")
        }
        guard let target else {
            return .failed(message: "No execution target was bound to this run. Select an environment and start a new run.")
        }
        switch target.kind {
        case .localLinux:
            // The existing LocalShellService path owns local Linux. It may run
            // only when the run is pinned to this exact target revision.
            do {
                let resolved = try await domain.resolveForRun(
                    taskID: taskID, runID: request.context.runID)
                let pin = resolved.pin
                guard resolved.target.kind == .localLinux,
                      pin.targetRevision == target.revision,
                      pin.environmentID == target.environmentID,
                      request.context.environmentID == target.environmentID else {
                    return .failed(message: "transport=ssh status=targetNotPinned\nThe run has no matching execution-target pin; nothing was executed.")
                }
                return nil
            } catch {
                return .failed(message: "transport=ssh status=targetNotPinned reason=pinReadFailed")
            }
        case .ssh:
            guard let toolCallID = request.context.toolCallID,
                  !toolCallID.isEmpty else {
                return .failed(message: "transport=ssh status=missingToolCallID\nThe remote execution requires a stable tool call identity; nothing was executed.")
            }
            let operationID = "run:\(request.context.runID.uuidString):call:\(toolCallID)"
            guard operationID.utf8.count <= 256 else {
                return .failed(message: "transport=ssh status=invalidOperationID")
            }
            do {
                let authorization = try await domain.authorizeSSHExecution(
                    taskID: taskID,
                    runID: request.context.runID
                )
                let result = try await adapter.execute(C02SSHExecutionRequest(
                    operationID: operationID,
                    authorization: authorization,
                    command: request.command,
                    cwd: request.cwd,
                    environment: request.environment,
                    stdin: request.stdin,
                    timeout: request.timeout,
                    maxOutputBytes: request.maxOutputBytes,
                    cancellation: request.context.cancellation
                ))
                switch result.state {
                case .exited(let code):
                    // Keep the remote stderr as remote evidence, not under
                    // LocalShellTool's "backend metadata" label.
                    let combined = result.stderr.isEmpty
                        ? result.stdout
                        : result.stdout + "\n--- remote stderr ---\n" + result.stderr
                    return .exited(
                        code: code,
                        stdout: combined,
                        stderr: "",
                        truncated: result.truncated,
                        stderrTruncated: false,
                        durationMs: result.durationMs
                    )
                case .timedOut, .cancelled, .outcomeUnknown:
                    // A local channel close or a transport failure is NOT
                    // proof that the remote command stopped. Surface the
                    // unknown outcome instead of a fake clean cancellation.
                    return .failed(message: result.summary)
                }
            } catch let error as C02ExecutionTargetError {
                return .failed(message: "transport=ssh status=targetRefused code=\(error.code)\n\(error.message)")
            } catch let error as C02SSHAdapterError {
                if case .hostKeyApprovalRequired(let challenge) = error {
                    await domain.recordRemoteHostKeyChallenge(challenge)
                } else if case .hostKeyChanged(let challenge) = error {
                    await domain.recordRemoteHostKeyChallenge(challenge)
                }
                return .failed(message: "transport=ssh status=sshRefused code=\(error.code)\n\(error.message)")
            } catch {
                return .failed(message: "transport=ssh status=sshFailed")
            }
        }
    }
}

public struct C02RemoteShellRequest: Sendable {
    public var command: String
    public var cwd: String
    public var environment: [String: String]
    public var stdin: String?
    public var timeout: TimeInterval
    public var maxOutputBytes: Int
    public var context: ToolContext

    public init(
        command: String,
        cwd: String,
        environment: [String: String],
        stdin: String?,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        context: ToolContext
    ) {
        self.command = command
        self.cwd = cwd
        self.environment = environment
        self.stdin = stdin
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.context = context
    }
}

// MARK: - Production composition (Main supplies concrete authorities)

public enum C02ExecutionTargetProduction {
    public struct Components: Sendable {
        public let domain: C02ExecutionTargetDomain
        public let adapter: C02SSHExecutionAdapter
        public let bridge: C02TargetBridge
        public let shellBridge: C02RemoteShellBridge

        public init(
            domain: C02ExecutionTargetDomain,
            adapter: C02SSHExecutionAdapter,
            bridge: C02TargetBridge,
            shellBridge: C02RemoteShellBridge
        ) {
            self.domain = domain
            self.adapter = adapter
            self.bridge = bridge
            self.shellBridge = shellBridge
        }
    }

    /// Constructs the real graph over the accepted generation's SAME
    /// DatabaseManager. Main calls this once during composition and registers
    /// `bridge` on `floe.target/19` and `shellBridge` in the ShellTools seam.
    public static func make(
        epoch: UInt64,
        database: DatabaseManager,
        storageRoot: URL,
        metadata: any G073EnvironmentMetadataSource,
        hosts: RemoteHostStore,
        credentialResolver: @escaping SSHCredentialResolver,
        lifecycle: @escaping @Sendable (UInt64) async -> (any ConversationDeletionLifecycle)? = { epoch in
            RunDomainFacade.current(epoch: epoch)?.1
        },
        shellSessions: @escaping @Sendable () async -> ShellSessionCenter? = {
            RuntimeFacadeLinuxBindings.shared.components?.sessions
        },
        jobOwner: @escaping @Sendable () async -> G03JobLifecycle? = {
            G03JobLifecycle.current
        }
    ) -> Components {
        let store = C02SQLiteExecutionTargetStore(database: database)
        let ownership = C02SQLiteTargetOwnershipProvider(
            database: database, storageRoot: storageRoot)
        let policy = C02SQLiteTargetPolicyProvider(database: database)
        let environments = C02MetadataTargetEnvironmentProvider(
            metadata: metadata, hosts: hosts,
            liveCatalog: { ownership in
                try await C02RuntimeEnvironmentCatalog.read(ownership: ownership)
            })
        let trust = C02RemoteHostTrustAdapter(store: hosts)
        let adapter = C02SSHExecutionAdapter(
            hostStore: hosts,
            connectorFactory: { _ in SSHConnectionService(hostStore: hosts) },
            credentialResolver: credentialResolver,
            pins: store,
            receipts: store,
            liveEpoch: { G02NativeRootEpoch.readback() }
        )
        let drain = C02RuntimeOwnedWorkDrainAdapter(
            epoch: epoch,
            database: database,
            lifecycle: lifecycle,
            shellSessions: shellSessions,
            jobOwner: jobOwner,
            remoteSessions: { adapter }
        )
        let domain = C02ExecutionTargetDomain(
            epoch: epoch,
            store: store,
            ownership: ownership,
            policy: policy,
            environments: environments,
            remoteProbe: adapter,
            remoteTrust: trust,
            drain: drain,
            liveEpoch: { G02NativeRootEpoch.readback() }
        )
        let bridge = C02TargetBridge(epoch: epoch, domain: domain, adapter: adapter)
        let shellBridge = C02RemoteShellBridge(domain: domain, adapter: adapter)
        return Components(
            domain: domain, adapter: adapter, bridge: bridge, shellBridge: shellBridge)
    }
}
