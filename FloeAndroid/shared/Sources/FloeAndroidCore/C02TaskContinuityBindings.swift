// SPDX-License-Identifier: MPL-2.0
//
// C02 — trusted-host bindings for durable task continuity.
//
// `BridgeV21` is the reserved host-only channel `floe.continuity/21`. It is
// NOT a BridgeV3 matrix command, NOT a model tool and cannot widen a task,
// run, environment or execution-target permission. Main owns the C ABI /
// `Bridge.swift` branch and the central run gate; this file only provides the
// closed JSON surface over the typed coordinator.
//
// Commands:
//   continuity.capabilities     -> generation + storage readiness + bounds
//   continuity.snapshot         -> pause marker + canonical question/approval waits
//   continuity.storage.check    -> probe; records a pause only for a proven condition
//   continuity.pause            -> record a pause and park the live run (user/system)
//   continuity.resume           -> explicit, validated, exactly-once resume
//
// Answering a question or an approval is deliberately NOT exposed here: the
// original `question.answer` and `run.approval.resolve` commands remain the
// only answer paths. This channel can only observe the canonical wait
// identity and require a resume when the live owner is gone.
import Foundation
import Dispatch
import FloeCore
import FloeModels

public enum BridgeV21 {
    public static let version = C02TaskContinuityWire.version
    public static let schema = C02TaskContinuityWire.schema
    public static let maximumRequestBytes = C02TaskContinuityWire.maximumRequestBytes
    public static let maximumResponseBytes = C02TaskContinuityWire.maximumResponseBytes
    public static let modelTools = false
}

public final class C02TaskContinuityBridge: @unchecked Sendable {
    private let epoch: UInt64
    private let rootFingerprint: String
    private let coordinator: TaskContinuityCoordinator
    private let storageProbe: any TaskContinuityStorageProbing
    private let liveEpoch: @Sendable () -> UInt64?

    public init(
        epoch: UInt64,
        rootFingerprint: String,
        coordinator: TaskContinuityCoordinator,
        storageProbe: any TaskContinuityStorageProbing,
        liveEpoch: @escaping @Sendable () -> UInt64?
    ) {
        self.epoch = epoch
        self.rootFingerprint = rootFingerprint
        self.coordinator = coordinator
        self.storageProbe = storageProbe
        self.liveEpoch = liveEpoch
    }

    public func isLive() -> Bool {
        epoch > 0 && liveEpoch() == epoch
    }

    public func handle(requestData: Data, fallbackRequestID: String?) -> [String: Any] {
        var requestID = fallbackRequestID
        func failure(_ error: C02TaskContinuityError) -> [String: Any] {
            var value: [String: Any] = [
                "ok": false,
                "schema": C02TaskContinuityWire.schema,
                "code": error.code,
                "message": error.message,
                "retryable": error.retryable,
            ]
            if let requestID { value["requestID"] = requestID }
            return value
        }
        guard requestData.count <= C02TaskContinuityWire.maximumRequestBytes else {
            return failure(.invalidRequest("requestTooLarge"))
        }
        guard let object = (try? JSONSerialization.jsonObject(with: requestData))
                as? [String: Any],
              let version = Self.exactInt(object["version"]),
              version == C02TaskContinuityWire.version,
              let operation = Self.boundedString(object["operation"], 64) else {
            return failure(.invalidRequest("request"))
        }
        requestID = Self.boundedString(object["requestID"], 256) ?? requestID
        if let schema = object["schema"] as? String,
           schema != C02TaskContinuityWire.schema {
            return failure(.invalidRequest("schema"))
        }
        guard self.isLive() else {
            return failure(.rootEpochUnavailable)
        }
        let request = C02TaskContinuityRequest(object)

        switch operation {
        case "handshake", "continuity.capabilities":
            return awaitResult(requestID: requestID) {
                let storage = await self.storageStatus()
                return Self.payload([
                    "coreReady": self.epoch > 0,
                    "epoch": Int64(self.epoch),
                    "rootFingerprint": self.rootFingerprint,
                    "modelTools": false,
                    "maximumRequestBytes": C02TaskContinuityWire.maximumRequestBytes,
                    "maximumResponseBytes": C02TaskContinuityWire.maximumResponseBytes,
                    "maximumWaits": C02TaskContinuityWire.maximumWaits,
                    "storage": Self.storageJSON(storage),
                ])
            }

        case "continuity.snapshot":
            guard request.allowedKeys(["taskID", "runID"]),
                  let taskID = request.uuid("taskID") else {
                return failure(.invalidRequest("snapshotRequest"))
            }
            let runID = request.uuid("runID")
            return awaitResult(requestID: requestID) {
                let snapshot = try await self.coordinator.snapshot(
                    taskID: taskID, runID: runID)
                return Self.snapshotJSON(snapshot)
            }

        case "continuity.storage.check":
            guard request.allowedKeys(["taskID", "runID"]),
                  let taskID = request.uuid("taskID"),
                  let runID = request.uuid("runID") else {
                return failure(.invalidRequest("storageCheckRequest"))
            }
            return awaitResult(requestID: requestID) {
                if let receipt = try await self.coordinator.checkStorage(
                    taskID: taskID, runID: runID) {
                    let snapshot = try await self.coordinator.snapshot(
                        taskID: taskID, runID: runID)
                    var value = Self.snapshotJSON(snapshot)
                    value["pauseRecorded"] = true
                    value["runCheckpointed"] = receipt.runCheckpointed
                    return value
                }
                let snapshot = try await self.coordinator.snapshot(
                    taskID: taskID, runID: runID)
                var value = Self.snapshotJSON(snapshot)
                value["pauseRecorded"] = false
                return value
            }

        case "continuity.pause":
            guard request.allowedKeys(["taskID", "runID", "reason", "detailCode"]),
                  let taskID = request.uuid("taskID"),
                  let runID = request.uuid("runID") else {
                return failure(.invalidRequest("pauseRequest"))
            }
            let reasonRaw = request.string("reason", maxBytes: 40)
            let reason: TaskContinuityPauseReason?
            if let reasonRaw {
                guard let parsed = TaskContinuityPauseReason(rawValue: reasonRaw) else {
                    return failure(.invalidRequest("pauseReason"))
                }
                reason = parsed
            } else {
                reason = nil
            }
            let detailCode = request.string("detailCode", maxBytes: 64)
            return awaitResult(requestID: requestID) {
                let receipt: TaskContinuityPauseReceipt
                if let reason {
                    receipt = try await self.coordinator.pause(
                        taskID: taskID, runID: runID,
                        reason: reason, detailCode: detailCode)
                } else if let probed = try await self.coordinator.checkStorage(
                    taskID: taskID, runID: runID) {
                    receipt = probed
                } else {
                    throw C02TaskContinuityError.invalidRequest("storageReady")
                }
                var value: [String: Any] = [
                    "ok": true,
                    "pause": Self.pauseJSON(receipt.marker),
                ]
                value["schema"] = C02TaskContinuityWire.schema
                value["runCheckpointed"] = receipt.runCheckpointed
                value["storage"] = Self.storageJSON(receipt.storage)
                return value
            }

        case "continuity.resume":
            guard request.allowedKeys([
                "taskID", "runID", "markerID", "expectedRootEpoch",
                "expectedTargetRevision", "explicitUserAction",
            ]),
                let taskID = request.uuid("taskID"),
                let runID = request.uuid("runID"),
                let markerID = request.string(
                    "markerID", maxBytes: C02TaskContinuityWire.maximumIdentifierBytes),
                let expectedRootEpoch = request.uint64("expectedRootEpoch"),
                expectedRootEpoch > 0 else {
                return failure(.invalidRequest("resumeRequest"))
            }
            guard request.bool("explicitUserAction") == true else {
                return Self.refusalJSON(.explicitActionRequired)
            }
            let expectedTargetRevision = request.int64("expectedTargetRevision")
            if let expectedTargetRevision, expectedTargetRevision <= 0 {
                return failure(.invalidRequest("expectedTargetRevision"))
            }
            let resume = TaskContinuityResumeRequest(
                taskID: taskID,
                runID: runID,
                markerID: markerID,
                expectedRootEpoch: expectedRootEpoch,
                expectedTargetRevision: expectedTargetRevision,
                explicitUserAction: true)
            return awaitResult(requestID: requestID) {
                let outcome = try await self.coordinator.resume(resume)
                switch outcome {
                case .accepted(let result, let marker):
                    var value: [String: Any] = [
                        "ok": true,
                        "schema": C02TaskContinuityWire.schema,
                        "accepted": true,
                        "resumed": true,
                        "requiresReconciliation": (Int(result.detail["unknownOutcomes"] ?? "") ?? 0) > 0,
                        "detail": result.detail,
                        "epoch": Int64(self.epoch),
                    ]
                    if let marker {
                        value["marker"] = Self.pauseJSON(marker)
                    }
                    return value
                case .refused(let refusal):
                    return Self.refusalPayload(refusal)
                }
            }

        default:
            return failure(.unsupportedOperation)
        }
    }

    // MARK: - Internal helpers

    private func storageStatus() async -> TaskContinuityStorageStatus {
        // The probe itself is read-only and never creates a pause marker.
        await storageProbe.probe()
    }

    private static func snapshotJSON(_ snapshot: TaskContinuitySnapshot) -> [String: Any] {
        var value: [String: Any] = [
            "ok": true,
            "schema": C02TaskContinuityWire.schema,
            "taskID": snapshot.taskID.uuidString,
            "rootEpoch": Int64(snapshot.rootEpoch),
            "rootFingerprint": snapshot.rootFingerprint,
            "storage": storageJSON(snapshot.storage),
            "waits": snapshot.waits.map(waitJSON),
            "waitsTruncated": snapshot.waitsTruncated,
            "waitsUnavailable": snapshot.waitsUnavailable,
            "unknownOutcomeCount": snapshot.unknownOutcomeCount,
            "generatedAt": ConversationWireDate.encode(snapshot.generatedAt),
            "modelTools": false,
        ]
        if let runID = snapshot.runID {
            value["runID"] = runID.uuidString
        } else {
            value["runID"] = NSNull()
        }
        if let pause = snapshot.pause {
            value["pause"] = pauseJSON(pause)
        } else {
            value["pause"] = NSNull()
        }
        return value
    }

    private static func waitJSON(_ wait: TaskContinuityWait) -> [String: Any] {
        var value: [String: Any] = [
            "waitID": wait.identity.waitID,
            "kind": wait.identity.kind.rawValue,
            "rootEpoch": Int64(wait.identity.rootEpoch),
            "rootFingerprint": wait.identity.rootFingerprint,
            "taskID": wait.identity.taskID.uuidString,
            "runID": wait.identity.runID.uuidString,
            "toolCallID": wait.identity.toolCallID,
            "requestID": wait.identity.requestID,
            "itemID": wait.identity.itemID,
            "revision": wait.identity.revision,
            "prompt": wait.prompt,
            "promptTruncated": wait.promptTruncated,
            "waitPolicy": wait.waitPolicy,
            "answerableNow": wait.answerableNow,
            "requiresResume": wait.requiresResume,
            "createdAt": ConversationWireDate.encode(wait.createdAt),
            "updatedAt": ConversationWireDate.encode(wait.updatedAt),
            "runState": wait.runState,
        ]
        if let deadline = wait.deadlineAt {
            value["deadlineAt"] = ConversationWireDate.encode(deadline)
        } else {
            value["deadlineAt"] = NSNull()
        }
        value["requestDigest"] = wait.requestDigest as Any? ?? NSNull()
        value["answerNonce"] = wait.answerNonce as Any? ?? NSNull()
        value["approvalVersion"] = wait.approvalVersion as Any? ?? NSNull()
        return value
    }

    private static func pauseJSON(_ marker: TaskContinuityPauseMarker) -> [String: Any] {
        var value: [String: Any] = [
            "markerID": marker.markerID,
            "taskID": marker.taskID.uuidString,
            "runID": marker.runID.uuidString,
            "rootEpoch": Int64(marker.rootEpoch),
            "rootFingerprint": marker.rootFingerprint,
            "reason": marker.reason.rawValue,
            "state": marker.state.rawValue,
            "durability": marker.durability.rawValue,
            "detectedAt": ConversationWireDate.encode(marker.detectedAt),
            "updatedAt": ConversationWireDate.encode(marker.updatedAt),
            "resumeAttempt": marker.resumeAttempt,
            "runCheckpointed": marker.runCheckpointed,
            "unknownOutcomeCount": marker.unknownOutcomeCount,
            "explicitResumeOnly": marker.explicitResumeOnly,
        ]
        value["targetRevision"] = marker.targetRevision.map { Int64($0) } as Any? ?? NSNull()
        value["targetRootEpoch"] = marker.targetRootEpoch.map { Int64($0) } as Any? ?? NSNull()
        value["environmentID"] = marker.environmentID as Any? ?? NSNull()
        value["workspaceID"] = marker.workspaceID?.uuidString as Any? ?? NSNull()
        value["detailCode"] = marker.detailCode as Any? ?? NSNull()
        return value
    }

    private static func storageJSON(_ status: TaskContinuityStorageStatus) -> [String: Any] {
        var value: [String: Any] = [
            "condition": status.condition.rawValue,
            "isReady": status.isReady,
            "checkedAt": ConversationWireDate.encode(status.checkedAt),
        ]
        value["availableBytes"] = status.availableBytes.map { Int64($0) } as Any? ?? NSNull()
        value["detailCode"] = status.detailCode as Any? ?? NSNull()
        return value
    }

    private static func refusalJSON(_ refusal: TaskContinuityResumeRefusal) -> [String: Any] {
        refusalPayload(refusal)
    }

    private static func refusalPayload(_ refusal: TaskContinuityResumeRefusal) -> [String: Any] {
        [
            "ok": false,
            "schema": C02TaskContinuityWire.schema,
            "accepted": false,
            "code": refusal.code,
            "message": refusal.message,
            "retryable": refusal.code == "resumeInProgress"
                || refusal.code.hasPrefix("storageStillUnavailable")
                || refusal.code == "rootEpochChanged",
        ]
    }

    private static func payload(_ value: [String: Any]) -> [String: Any] {
        var object = value
        object["ok"] = true
        object["schema"] = C02TaskContinuityWire.schema
        return object
    }

    private static func awaitResult(
        requestID: String?,
        _ body: @escaping @Sendable () async throws -> [String: Any]
    ) -> [String: Any] {
        let box = C02ContinuityResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let value = try await body()
                box.set(.success(value))
            } catch let error as C02TaskContinuityError {
                box.set(.failure(error))
            } catch let refusal as TaskContinuityResumeRefusal {
                box.set(.refused(refusal))
            } catch {
                box.set(.failure(.storeUnavailable("continuity")))
            }
            semaphore.signal()
        }
        // The bridge runs on the trusted host's serialized dispatch lane. A
        // bounded wait preserves that contract without inheriting a
        // model/provider timeout; the work is local store/actor IO.
        _ = semaphore.wait(timeout: .now() + 120)
        switch box.value {
        case .success(var value):
            if let requestID { value["requestID"] = requestID }
            return value
        case .failure(let error):
            var value: [String: Any] = [
                "ok": false,
                "schema": C02TaskContinuityWire.schema,
                "code": error.code,
                "message": error.message,
                "retryable": error.retryable,
            ]
            if let requestID { value["requestID"] = requestID }
            return value
        case .refused(let refusal):
            var value = refusalPayload(refusal)
            if let requestID { value["requestID"] = requestID }
            return value
        case .none:
            var value: [String: Any] = [
                "ok": false,
                "schema": C02TaskContinuityWire.schema,
                "code": "timedOut",
                "message": "The continuity operation did not settle.",
                "retryable": true,
            ]
            if let requestID { value["requestID"] = requestID }
            return value
        }
    }

    fileprivate static func exactInt(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Int64:
            guard value >= Int64(Int.min), value <= Int64(Int.max) else { return nil }
            return Int(value)
        case let value as NSNumber:
            let integer = value.int64Value
            guard integer >= Int64(Int.min), integer <= Int64(Int.max) else { return nil }
            return Int(integer)
        default:
            return nil
        }
    }

    fileprivate static func boundedString(_ value: Any?, _ limit: Int) -> String? {
        guard let string = value as? String, !string.isEmpty,
              string.utf8.count <= limit else { return nil }
        return string
    }
}

private final class C02ContinuityResultBox: @unchecked Sendable {
    enum Value {
        case success([String: Any])
        case failure(C02TaskContinuityError)
        case refused(TaskContinuityResumeRefusal)
    }
    private let lock = NSLock()
    private var stored: Value?
    func set(_ value: Value) { lock.lock(); stored = value; lock.unlock() }
    var value: Value? { lock.lock(); defer { lock.unlock() }; return stored }
}

private struct C02TaskContinuityRequest {
    private let object: [String: Any]

    init(_ object: [String: Any]) { self.object = object }

    func allowedKeys(_ keys: Set<String>) -> Bool {
        object.keys.allSatisfy { $0 == "version" || $0 == "schema" || $0 == "operation"
            || $0 == "requestID" || keys.contains($0) }
    }

    func string(_ key: String, maxBytes: Int) -> String? {
        C02TaskContinuityBridge.boundedString(object[key], maxBytes)
    }

    func uuid(_ key: String) -> UUID? {
        guard let value = string(key, maxBytes: 64) else { return nil }
        return UUID(uuidString: value)
    }

    func int64(_ key: String) -> Int64? {
        let raw = object[key]
        if raw is Bool { return nil }
        switch raw {
        case let value as Int64: return value
        case let value as Int:
            return Int64(value)
        case let value as NSNumber: return value.int64Value
        default: return nil
        }
    }

    func uint64(_ key: String) -> UInt64? {
        guard let value = int64(key), value > 0 else { return nil }
        return UInt64(value)
    }

    func bool(_ key: String) -> Bool? {
        object[key] as? Bool
    }
}

// MARK: - Process-wide installation

/// One installed coordinator/bridge per accepted generation. Main calls
/// `install` from G02 composition and `retire` with the rest of the
/// generation. Central run admission uses `admissionDecision`; Bridge.swift
/// uses the static `handle` entry (so it needs no instance wiring).
public enum C02TaskContinuityRuntimeHost {
    public struct Installed: @unchecked Sendable {
        public let epoch: UInt64
        public let rootFingerprint: String
        public let coordinator: TaskContinuityCoordinator
        public let bridge: C02TaskContinuityBridge

        public init(
            epoch: UInt64,
            rootFingerprint: String,
            coordinator: TaskContinuityCoordinator,
            bridge: C02TaskContinuityBridge
        ) {
            self.epoch = epoch
            self.rootFingerprint = rootFingerprint
            self.coordinator = coordinator
            self.bridge = bridge
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: Installed?

    @discardableResult
    public static func install(_ value: Installed) -> Installed {
        lock.lock()
        installed = value
        lock.unlock()
        return value
    }

    public static func current(epoch: UInt64) -> Installed? {
        lock.lock()
        defer { lock.unlock() }
        guard let installed, installed.epoch == epoch else { return nil }
        return installed
    }

    public static func retire(epoch: UInt64) {
        lock.lock()
        if installed?.epoch == epoch { installed = nil }
        lock.unlock()
    }

    /// Bridge.swift dispatch entry. When no generation is installed, a
    /// version-21 request fails closed instead of silently falling into the
    /// frozen v1/v3 grammar.
    public static func handle(
        requestData: Data,
        fallbackRequestID: String?
    ) -> [String: Any] {
        lock.lock()
        let value = installed
        lock.unlock()
        guard let value else {
            var response: [String: Any] = [
                "ok": false,
                "schema": C02TaskContinuityWire.schema,
                "code": C02TaskContinuityError.notInstalled.code,
                "message": C02TaskContinuityError.notInstalled.message,
                "retryable": false,
                "modelTools": false,
            ]
            if let fallbackRequestID { response["requestID"] = fallbackRequestID }
            return response
        }
        return value.bridge.handle(
            requestData: requestData, fallbackRequestID: fallbackRequestID)
    }

    /// Central `FacadeRunDomain` admission gate. `nil` preserves the original
    /// path byte-for-byte when no coordinator is installed or no pause is
    /// active.
    public static func admissionDecision(
        taskID: UUID,
        runID: UUID?,
        operation: TaskContinuityAdmissionOperation
    ) async -> TaskContinuityAdmission? {
        lock.lock()
        let value = installed
        lock.unlock()
        guard let value else { return nil }
        return await value.coordinator.admissionDecision(
            taskID: taskID, runID: runID, operation: operation)
    }

    /// Called by central persistence catch sites when a storage-class error
    /// is already classified. Never throws into the original path.
    @discardableResult
    public static func noteStorageFailure(
        taskID: UUID?,
        runID: UUID,
        error: Error
    ) async -> TaskContinuityPauseReceipt? {
        guard let taskID else { return nil }
        lock.lock()
        let value = installed
        lock.unlock()
        guard let value else { return nil }
        return try? await value.coordinator.noteStorageFailure(
            taskID: taskID, runID: runID, error: error)
    }

    /// A `RunDomainError.persistenceUnavailable` already proves the original
    /// store refused. Record the honest database-unavailable pause without
    /// inventing a second error classification.
    @discardableResult
    public static func notePersistenceUnavailable(
        taskID: UUID?,
        runID: UUID
    ) async -> TaskContinuityPauseReceipt? {
        guard let taskID else { return nil }
        lock.lock()
        let value = installed
        lock.unlock()
        guard let value else { return nil }
        return try? await value.coordinator.pause(
            taskID: taskID,
            runID: runID,
            reason: .databaseUnavailable,
            detailCode: "persistenceUnavailable")
    }
}
