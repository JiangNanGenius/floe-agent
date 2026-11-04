// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — trusted-host channel `floe.agentmedia/28` (BridgeV28) on the
// EXISTING `floe_bridge_exchange` C ABI.
//
// This is the App-host bridge for CONVERSATION-OWNED agent media jobs (the
// durable `media_generation_jobs` rows the model-facing image.generate /
// video.generate tools create, `MediaJobOwnerKind.conversation`). It exposes
// exactly ONE closed read/reconcile action and deliberately carries NO model
// tool, NO submit path and NO credential material:
//
//   media.jobs.refresh  {conversationID} -> bounded durable job projections
//
// Semantics: refresh ONLY restarts bounded poll workers for retained accepted
// rows and classifies lost single-shot rows unknown — the exact authorities
// of `G09R2AgentGenerationService.resumeStaleJobs` (the relaunch pump). It
// NEVER submits, never re-bills and never invents completion: the returned
// projections are the re-read durable rows, filtered by conversation ownership.
// A stopping or unavailable root fails closed/typed.
//
// Main owns the C ABI and the `Bridge.swift` dispatch branch (both additive);
// no JNI entry is added.
import Foundation
import CoreFoundation
import FloeCore

public enum BridgeV28 {
    public static let version = G09R2AgentMediaWire.version
    public static let schema = G09R2AgentMediaWire.schema
    public static let maximumRequestBytes = G09R2AgentMediaWire.maximumRequestBytes
    public static let maximumResponseBytes = G09R2AgentMediaWire.maximumResponseBytes
}

/// Closed wire constants for the conversation media refresh channel.
public enum G09R2AgentMediaWire {
    public static let version = 28
    public static let schema = "floe.agentmedia/28"
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 48 * 1_024
    /// One refresh reply carries at most this many durable job projections.
    public static let maximumJobs = 50
    /// The ONE closed action of this channel.
    public static let refreshAction = "media.jobs.refresh"
    public static var modelTools: Bool { false }
}

/// One durable job projection on the refresh wire. It is the typed
/// `G09R2AgentJobStatus` re-encoded flat for the App host; artifacts carry
/// only real store-derived relative paths, measured bytes and digests.
struct G09R2AgentMediaJobWire: Encodable {
    var jobID: String
    var state: String
    var terminated: Bool
    var ready: Bool
    var mediaKind: String
    var providerTaskID: String?
    var resultURL: String?
    var resultURLExpiresAt: String?
    var artifacts: [G09R2AgentGenerationArtifact]?
    var workspaceRelativePath: String?
    var deliveredByteCount: Int64?
    var deliveredSHA256: String?
    var nextPollAt: String?
    var lastError: String?
}

struct G09R2AgentMediaRefreshWire: Encodable {
    var schema: String
    var jobs: [G09R2AgentMediaJobWire]
    var count: Int
}

/// The single entry point wired into `AndroidBridge.exchange` (Bridge.swift).
/// Synchronous from the host thread's perspective: the async reconcile runs
/// on the shared runtime and the host thread waits on a semaphore, exactly
/// like the creative BridgeV6 handler.
public enum G09R2AgentMediaBridge {
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<[String: Any], Error>?
        func set(_ result: Result<[String: Any], Error>) {
            lock.lock(); value = result; lock.unlock()
        }
        func get() -> Result<[String: Any], Error>? {
            lock.lock(); defer { lock.unlock() }; return value
        }
    }

    private static func blocking(
        _ body: @escaping @Sendable () async throws -> [String: Any]
    ) -> Result<[String: Any], Error> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task {
            do { box.set(.success(try await body())) }
            catch { box.set(.failure(error)) }
            semaphore.signal()
        }
        semaphore.wait()
        return box.get() ?? .failure(G09CreativeError.storageUnavailable)
    }

    public static func handle(requestData: Data,
                              fallbackRequestID: String?) -> [String: Any] {
        var requestID = fallbackRequestID
        func failure(_ error: G09CreativeError) -> [String: Any] {
            var value = G09CreativeWire.failure(error)
            value["schema"] = G09R2AgentMediaWire.schema
            if let requestID { value["requestID"] = requestID }
            return value
        }
        guard requestData.count <= G09R2AgentMediaWire.maximumRequestBytes else {
            return failure(.requestTooLarge)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: requestData))
                as? [String: Any] else {
            return failure(.invalidRequest("invalidJSON"))
        }
        requestID = boundedString(object["requestID"], 256) ?? requestID
        guard exactInt(object["version"]) == G09R2AgentMediaWire.version else {
            return failure(.unsupportedVersion)
        }
        guard (object["operation"] as? String) == "command" else {
            return failure(.unsupportedOperation)
        }
        guard let epochRaw = exactInt(object["epoch"]),
              epochRaw > 0 else {
            return failure(.invalidRequest("missingEpoch"))
        }
        let epoch = UInt64(epochRaw)
        guard let action = boundedString(object["action"], 80),
              action == G09R2AgentMediaWire.refreshAction else {
            return failure(.unsupportedAction(actionOrEmpty(object["action"])))
        }
        guard let payload = object["payload"] as? [String: Any],
              let rawConversation = boundedString(
                  payload["conversationID"], 64),
              let conversationID = G09CreativeWire.uuid(rawConversation) else {
            return failure(.invalidRequest("invalidConversationID"))
        }
        let stableRequestID = requestID
        let result = blocking {
            let statuses = try await G09R2AgentGenerationService.shared
                .refreshConversationJobs(epoch: epoch, conversationID: conversationID)
            let wire = G09R2AgentMediaRefreshWire(
                schema: G09R2AgentMediaWire.schema,
                jobs: statuses.prefix(G09R2AgentMediaWire.maximumJobs)
                    .map(Self.wire(status:)),
                count: min(statuses.count, G09R2AgentMediaWire.maximumJobs))
            var object = try G09CreativeWire.object(wire)
            object["ok"] = true
            if let stableRequestID { object["requestID"] = stableRequestID }
            return object
        }
        switch result {
        case .success(let object):
            guard let encoded = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]),
                  encoded.count <= G09R2AgentMediaWire.maximumResponseBytes else {
                return failure(.responseTooLarge)
            }
            return object
        case .failure(let error):
            if let typed = error as? G09CreativeError {
                return failure(typed)
            }
            return failure(.storageUnavailable)
        }
    }

    private static func actionOrEmpty(_ value: Any?) -> String {
        (value as? String).map { G09CreativeWire.bounded($0, limit: 80) } ?? ""
    }

    /// Bool/Double/Int NSNumber coercion is rejected: only a real JSON integer
    /// is accepted (same discipline as the other trusted-host bridges).
    private static func exactInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() else {
            return nil
        }
        let double = number.doubleValue
        guard double.rounded() == double, double >= 0, double <= 9_007_199_254_740_991 else {
            return nil
        }
        return number.intValue
    }

    private static func boundedString(_ value: Any?, _ limit: Int) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return G09CreativeWire.bounded(string, limit: limit)
    }

    private static func wire(status: G09R2AgentJobStatus) -> G09R2AgentMediaJobWire {
        let iso = G09CreativeWire.encoder()
        func stamp(_ date: Date?) -> String? {
            guard let date else { return nil }
            return (try? iso.encode(date)).flatMap {
                String(data: $0, encoding: .utf8)
            }?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return G09R2AgentMediaJobWire(
            jobID: status.jobID.uuidString.lowercased(),
            state: status.state.rawValue,
            terminated: status.terminated,
            ready: status.ready,
            mediaKind: status.mediaKind,
            providerTaskID: status.providerTaskID,
            resultURL: status.resultURL?.absoluteString,
            resultURLExpiresAt: stamp(status.resultURLExpiresAt),
            artifacts: status.artifacts,
            workspaceRelativePath: status.workspaceRelativePath,
            deliveredByteCount: status.deliveredByteCount,
            deliveredSHA256: status.deliveredSHA256,
            nextPollAt: stamp(status.nextPollAt),
            lastError: status.lastError)
    }
}
