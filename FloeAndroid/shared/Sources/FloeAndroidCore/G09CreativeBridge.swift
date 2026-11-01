// SPDX-License-Identifier: MPL-2.0
//
// G09-R1 — Bridge protocol v5 (`floe.creative/5`).
//
// Additive to the frozen v1-v4 handlers and dispatched from the SAME
// `floe_bridge_exchange` C ABI. Host-only: no model tool registration, no
// new JNI function, no task/run/provider authority. A missing v5 handler in
// an older installed core therefore returns the ordinary v1
// `unsupportedVersion` response; the Android host maps that to a typed
// `needsCoreUpdate` state and never invents a local project store.
import Foundation
import FloeCore
import FloeAndroidWorkbench

public enum BridgeV5 {
    public static let version = 5
    public static let schema = "floe.creative/5"
    public static let maximumRequestBytes = G09CreativeLimits.requestBytes
    public static let maximumResponseBytes = G09CreativeLimits.responseBytes

    static let service = G09CreativeDomainService()

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Data, Error>?
        func set(_ result: Result<Data, Error>) { lock.lock(); value = result; lock.unlock() }
        func get() -> Result<Data, Error>? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func blocking(_ body: @escaping @Sendable () async throws -> Data)
        -> Result<Data, Error> {
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

    public static func handle(requestData: Data, fallbackRequestID: String?) -> [String: Any] {
        handle(requestData: requestData, fallbackRequestID: fallbackRequestID, service: service)
    }

    /// Test/host-injection seam: the same closed handler with an isolated
    /// service instance. Production always uses the process-wide service.
    static func handle(requestData: Data, fallbackRequestID: String?,
                       service: G09CreativeDomainService) -> [String: Any] {
        guard requestData.count <= maximumRequestBytes else {
            return failure(.requestTooLarge)
        }
        let request: G09CreativeRequest
        do {
            request = try G09CreativeWire.decoder().decode(
                G09CreativeRequest.self, from: requestData)
        } catch {
            return failure(.invalidRequest("invalidJSON"))
        }
        guard request.version == version else {
            return failure(.unsupportedVersion)
        }
        switch request.operation {
        case "handshake":
            return handshake()
        case "status":
            return status(requestID: request.requestID, service: service)
        case "bind":
            guard let epoch = request.epoch, epoch > 0 else {
                return failure(.invalidRequest("missingEpoch"))
            }
            return bind(epoch: epoch, service: service)
        case "command":
            guard let epoch = request.epoch, epoch > 0 else {
                return failure(.invalidRequest("missingEpoch"))
            }
            guard let action = request.action, !action.isEmpty else {
                return failure(.invalidRequest("missingAction"))
            }
            guard G09CreativeActions.isCommand(action) else {
                return failure(.unsupportedAction(G09CreativeWire.bounded(action, limit: 80)))
            }
            let correlation = request.requestID ?? fallbackRequestID
            guard let correlation, !correlation.isEmpty,
                  correlation.utf8.count <= G09CreativeLimits.requestIDBytes else {
                return failure(.invalidRequest("missingRequestID"))
            }
            let result = blocking {
                try await service.perform(
                    epoch: epoch, requestID: correlation,
                    action: action, payload: request.payload)
            }
            return decode(result)
        default:
            return failure(.unsupportedOperation)
        }
    }

    public static func handshake() -> [String: Any] {
        [
            "ok": true,
            "version": version,
            "schema": schema,
            "engine": "FloeCreative",
            "actions": G09CreativeActions.all,
            "requestMaxBytes": maximumRequestBytes,
            "responseMaxBytes": maximumResponseBytes,
            "canvasProjectMaxBytes": G09CreativeLimits.canvasProjectBytes,
            "mediaProjectMaxBytes": G09CreativeLimits.mediaProjectBytes,
            "assetMaxBytes": G09CreativeLimits.assetBytes,
            "canvasSchemaVersion": CanvasProject.currentSchemaVersion,
            "mediaSchemaVersion": MediaProject.currentSchemaVersion,
            "persistence": "canvas-file-cas+media-json-cas+creative-asset-store",
            "videoPlayback": false,
            "modelTools": false,
        ]
    }

    private static func status(requestID: String?,
                               service: G09CreativeDomainService) -> [String: Any] {
        _ = requestID
        let result = blocking {
            let status = await service.status()
            return try objectData(status)
        }
        return decode(result)
    }

    private static func bind(epoch: UInt64,
                             service: G09CreativeDomainService) -> [String: Any] {
        let result = blocking {
            guard let cluster = await AndroidRuntimeBootstrap.creativeCluster(epoch: epoch) else {
                throw G09CreativeError.acceptedRootNotLive
            }
            let storage = G09CreativeStorageContext(
                root: cluster.identity.root,
                database: cluster.database,
                workspaceStore: cluster.workspaceStore,
                conversationStore: cluster.conversationStore)
            let status = try await service.bind(epoch: epoch, storage: storage)
            return try objectData(status)
        }
        return decode(result)
    }

    private static func objectData<T: Encodable>(_ value: T) throws -> Data {
        var object = try G09CreativeWire.object(value)
        object["ok"] = true
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]) else {
            throw G09CreativeError.storageUnavailable
        }
        return data
    }

    private static func decode(_ result: Result<Data, Error>) -> [String: Any] {
        switch result {
        case .success(let data):
            guard data.count <= maximumResponseBytes else {
                return failure(.responseTooLarge)
            }
            guard let object = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any] else {
                return failure(.storageUnavailable)
            }
            return object
        case .failure(let error):
            return failure(G09CreativeError.map(error))
        }
    }

    private static func failure(_ error: G09CreativeError) -> [String: Any] {
        G09CreativeWire.failure(error)
    }
}
