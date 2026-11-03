// SPDX-License-Identifier: MPL-2.0
//
// C03 additive bridge protocol `floe.voice/7`.
//
// This is a dedicated host-only channel dispatched from the SAME frozen
// `floe_bridge_exchange` C ABI. It carries only closed, non-secret operations:
// capabilities, cloud ASR lifecycle, timed subtitle write-back and cloud TTS
// lifecycle. No binary audio, credential, provider response body or filesystem
// path enters a request. One response may return a temporary native audio path
// for the App-owned player; release deletes it.
//
// The bridge does not widen BridgeV3's command matrix and does not register a
// model tool. An installed core without v7 keeps the ordinary v1
// `unsupportedVersion`; the host maps that to a typed needs-core-update state.
import Foundation
import Dispatch
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum BridgeV7 {
    public static let version = 7
    public static let schema = "floe.voice/7"
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 512 * 1_024
    public static let modelTools = false
}

public enum C03VoiceBridge {
    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<T, C03VoiceError>?
        func set(_ result: Result<T, C03VoiceError>) {
            lock.lock(); value = result; lock.unlock()
        }
        func get() -> Result<T, C03VoiceError>? {
            lock.lock(); defer { lock.unlock() }; return value
        }
    }

    public static func handle(
        requestData: Data,
        fallbackRequestID: String?
    ) -> [String: Any] {
        guard requestData.count <= BridgeV7.maximumRequestBytes else {
            return failure(C03VoiceError(.invalidSelection, "requestTooLarge"), operation: nil)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: requestData))
                as? [String: Any],
              (object["version"] as? Int) == BridgeV7.version,
              let operation = object["operation"] as? String,
              !operation.isEmpty else {
            return failure(C03VoiceError(.invalidSelection, "invalidRequest"), operation: nil)
        }
        switch operation {
        case "handshake":
            return [
                "ok": true,
                "version": BridgeV7.version,
                "schema": BridgeV7.schema,
            ]
        case "c03.capabilities":
            return block(seconds: 15, operation: operation) {
                try await C03VoiceDomain.shared.capabilities()
            }.map { capabilities in
                [
                    "ok": true,
                    "cloudReady": capabilities.cloudReady,
                    "transportReady": capabilities.transportReady,
                    "asrModels": capabilities.asrModels.map { modelJSON($0) },
                    "ttsModels": capabilities.ttsModels.map { modelJSON($0) },
                    "maxAudioBytes": capabilities.maxAudioBytes,
                    "maxChunkBytes": capabilities.maxChunkBytes,
                    "maxSourceDurationSeconds": capabilities.maxSourceDurationSeconds,
                    "maxTextCharacters": capabilities.maxTextCharacters,
                    "maxSegments": capabilities.maxSegments,
                    "ttsSampleRate": capabilities.ttsSampleRate,
                ]
            }
        case "c03.settings.load":
            return loadSettings(object, operation: operation)
        case "c03.settings.save":
            return saveSettings(object, operation: operation)
        case "c03.asr.plan":
            return planTranscription(object, operation: operation)
        case "c03.asr.chunk":
            return applyChunk(object, operation: operation)
        case "c03.asr.finish":
            return finishChunks(object, operation: operation)
        case "c03.asr.text":
            return asrText(object, operation: operation)
        case "c03.asr.utterance.start":
            return startUtterance(object, operation: operation)
        case "c03.utterance.begin":
            return beginUtterance(object, operation: operation)
        case "c03.asr.start":
            return startTranscription(object, operation: operation)
        case "c03.asr.status":
            return asrStatus(object, operation: operation)
        case "c03.asr.page":
            return asrPage(object, operation: operation)
        case "c03.asr.cancel":
            return cancelASR(object, operation: operation)
        case "c03.subtitle.write":
            return writeSubtitles(object, operation: operation)
        case "c03.tts.start":
            return startSynthesis(object, operation: operation)
        case "c03.tts.status":
            return ttsStatus(object, operation: operation)
        case "c03.tts.cancel":
            return cancelTTS(object, operation: operation)
        case "c03.tts.release":
            return releaseTTS(object, operation: operation)
        case "c03.cancelAll":
            return blockValue(seconds: 45, operation: operation) {
                await C03VoiceDomain.shared.cancelAll()
                return true
            }.map { _ in ["ok": true] }
        default:
            return failure(
                C03VoiceError(.invalidSelection, "unsupportedOperation"),
                operation: operation)
        }
    }

    // MARK: - Operations
    // MARK: - Canonical non-secret settings

    private static func loadSettings(
        _ object: [String: Any], operation: String
    ) -> [String: Any] {
        do {
            let epoch = try requireEpoch(object)
            return block(seconds: 10, operation: operation) {
                try await C03VoiceSettingsService.shared.load(epoch: epoch)
            }.map { snapshot in
                var value: [String: Any] = [
                    "ok": true,
                    "found": snapshot.found,
                    "unreadable": snapshot.unreadable,
                    "revision": snapshot.revision,
                ]
                if let settings = snapshot.settings {
                    value["settings"] = settings.jsonObject
                }
                return value
            }
        } catch let error as C03VoiceError {
            return failure(error, operation: operation)
        } catch {
            return failure(
                C03VoiceError(.invalidSelection, "invalidSettingsRequest"),
                operation: operation)
        }
    }

    private static func saveSettings(
        _ object: [String: Any], operation: String
    ) -> [String: Any] {
        do {
            let epoch = try requireEpoch(object)
            guard let expectedRevision = exactInt64(object["expectedRevision"]),
                  let settings = object["settings"] as? [String: Any],
                  JSONSerialization.isValidJSONObject(settings),
                  let data = try? JSONSerialization.data(withJSONObject: settings) else {
                throw C03VoiceError(.invalidSelection, "invalidSettings")
            }
            return block(seconds: 20, operation: operation) {
                try await C03VoiceSettingsService.shared.save(
                    settingsJSON: data,
                    expectedRevision: expectedRevision,
                    epoch: epoch)
            }.map { outcome in
                [
                    "ok": true,
                    "revision": outcome.revision,
                    "settings": outcome.settings.jsonObject,
                ]
            }
        } catch let error as C03VoiceError {
            return failure(error, operation: operation)
        } catch {
            return failure(
                C03VoiceError(.invalidSelection, "invalidSettingsRequest"),
                operation: operation)
        }
    }

    // MARK: - Bounded long-media transcription

    private static func planTranscription(
        _ object: [String: Any], operation: String
    ) -> [String: Any] {
        do {
            let epoch = try requireEpoch(object)
            let media = try parseMedia(object["media"])
            let selection = try parseSelection(object["selection"])
            let language = boundedString(object["language"], 64)
            let owner = parseOwner(object["owner"])
            return block(seconds: 45, operation: operation) {
                try await C03VoiceDomain.shared.planTranscription(
                    context: media,
                    selection: selection,
                    language: language,
                    owner: owner,
                    epoch: epoch)
            }.map { plan in
                [
                    "ok": true,
                    "operationID": plan.operationID,
                    "sourcePath": plan.sourcePath,
                    "stagingPath": plan.stagingPath,
                    "sourceBytes": plan.sourceBytes,
                    "durationSeconds": plan.durationSeconds,
                    "chunkLimitBytes": plan.chunkLimitBytes,
                    "estimatedChunks": plan.estimatedChunks,
                ]
            }
        } catch let error as C03VoiceError {
            return failure(error, operation: operation)
        } catch {
            return failure(
                C03VoiceError(.invalidSelection, "invalidTranscriptionPlan"),
                operation: operation)
        }
    }

    private static func applyChunk(
        _ object: [String: Any], operation: String
    ) -> [String: Any] {
        guard let id = boundedString(object["operationID"], 128),
              let chunkIndex = integer(object["chunkIndex"]),
              let sourceStart = double(object["sourceStart"]),
              let sourceDuration = double(object["sourceDuration"]),
              let sampleRate = integer(object["sampleRate"]),
              let channels = integer(object["channels"]) else {
            return failure(
                C03VoiceError(.invalidSelection, "invalidChunkRequest"),
                operation: operation)
        }
        return block(seconds: 300, operation: operation) {
            try await C03VoiceDomain.shared.applyChunk(
                operationID: id,
                chunkIndex: chunkIndex,
                sourceStart: sourceStart,
                sourceDuration: sourceDuration,
                sampleRate: sampleRate,
                channels: channels)
        }.map { count in
            ["ok": true, "segmentCount": count]
        }
    }

    private static func finishChunks(
        _ object: [String: Any], operation: String
    ) -> [String: Any] {
        guard let id = boundedString(object["operationID"], 128),
              let totalChunks = integer(object["totalChunks"]),
              let sourceDuration = double(object["sourceDuration"]) else {
            return failure(
                C03VoiceError(.invalidSelection, "invalidChunkFinishRequest"),
                operation: operation)
        }
        return block(seconds: 20, operation: operation) {
            try await C03VoiceDomain.shared.finishChunks(
                operationID: id,
                totalChunks: totalChunks,
                sourceDuration: sourceDuration)
        }.map { count in
            ["ok": true, "segmentCount": count]
        }
    }

    private static func asrText(
        _ object: [String: Any], operation: String
    ) -> [String: Any] {
        guard let id = boundedString(object["operationID"], 128) else {
            return failure(C03VoiceError(.invalidSelection, "missingOperationID"),
                           operation: operation)
        }
        return block(seconds: 5, operation: operation) {
            try await C03VoiceDomain.shared.asrText(id)
        }.map { text in
            ["ok": true, "text": String(text.prefix(200_000))]
        }
    }

    // MARK: - Finite cloud microphone

    private static func beginUtterance(
        _ object: [String: Any], operation: String
    ) -> [String: Any] {
        do {
            let epoch = try requireEpoch(object)
            let owner = parseOwner(object["owner"])
            return block(seconds: 10, operation: operation) {
                try await C03VoiceDomain.shared.beginUtterance(
                    owner: owner, epoch: epoch)
            }.map { staging in
                [
                    "ok": true,
                    "pathToken": staging.pathToken,
                    "path": staging.path,
                    "maxDurationSeconds": staging.maxDurationSeconds,
                ]
            }
        } catch let error as C03VoiceError {
            return failure(error, operation: operation)
        } catch {
            return failure(
                C03VoiceError(.invalidSelection, "invalidUtteranceRequest"),
                operation: operation)
        }
    }

    private static func startUtterance(
        _ object: [String: Any], operation: String
    ) -> [String: Any] {
        do {
            let epoch = try requireEpoch(object)
            guard let token = boundedString(object["pathToken"], 128),
                  let path = boundedString(object["path"], 4_096) else {
                throw C03VoiceError(.invalidSelection, "invalidUtteranceStaging")
            }
            let selection = try parseSelection(object["selection"])
            let language = boundedString(object["language"], 64)
            let owner = parseOwner(object["owner"])
            return block(seconds: 60, operation: operation) {
                try await C03VoiceDomain.shared.startUtterance(
                    pathToken: token,
                    path: path,
                    selection: selection,
                    language: language,
                    owner: owner,
                    epoch: epoch)
            }.map { id in ["ok": true, "operationID": id] }
        } catch let error as C03VoiceError {
            return failure(error, operation: operation)
        } catch {
            return failure(
                C03VoiceError(.invalidSelection, "invalidUtteranceRequest"),
                operation: operation)
        }
    }


    private static func startTranscription(
        _ object: [String: Any], operation: String
    ) -> [String: Any] {
        do {
            let media = try parseMedia(object["media"])
            let selection = try parseSelection(object["selection"])
            let language = boundedString(object["language"], 64)
            let owner = parseOwner(object["owner"])
            return block(seconds: 45, operation: operation) {
                try await C03VoiceDomain.shared.startTranscription(
                    context: media,
                    selection: selection,
                    language: language,
                    owner: owner)
            }.map { id in ["ok": true, "operationID": id] }
        } catch let error as C03VoiceError {
            return failure(error, operation: operation)
        } catch {
            return failure(
                C03VoiceError(.invalidSelection, "invalidTranscriptionRequest"),
                operation: operation)
        }
    }

    private static func asrStatus(
        _ object: [String: Any], operation: String
    ) -> [String: Any] {
        guard let id = boundedString(object["operationID"], 128) else {
            return failure(C03VoiceError(.invalidSelection, "missingOperationID"),
                           operation: operation)
        }
        return block(seconds: 5, operation: operation) {
            try await C03VoiceDomain.shared.asrStatus(id)
        }.map { status in
            var value: [String: Any] = [
                "ok": true,
                "state": status.state.rawValue,
                "progress": status.progress,
                "segmentCount": status.segmentCount,
            ]
            if let failure = status.failure { value["failure"] = failureJSON(failure) }
            return value
        }
    }

    private static func asrPage(
        _ object: [String: Any], operation: String
    ) -> [String: Any] {
        guard let id = boundedString(object["operationID"], 128) else {
            return failure(C03VoiceError(.invalidSelection, "missingOperationID"),
                           operation: operation)
        }
        let offset = max(0, integer(object["offset"]) ?? 0)
        let limit = min(max(1, integer(object["limit"]) ?? 100), 200)
        return block(seconds: 5, operation: operation) {
            try await C03VoiceDomain.shared.asrPage(id, offset: offset, limit: limit)
        }.map { page in
            [
                "ok": true,
                "segments": page.segments.map { segment in
                    ["start": segment.start, "end": segment.end, "text": segment.text]
                },
                "nextOffset": page.nextOffset,
                "total": page.total,
            ]
        }
    }

    private static func cancelASR(
        _ object: [String: Any], operation: String
    ) -> [String: Any] {
        guard let id = boundedString(object["operationID"], 128) else {
            return failure(C03VoiceError(.invalidSelection, "missingOperationID"),
                           operation: operation)
        }
        return blockValue(seconds: 30, operation: operation) {
            await C03VoiceDomain.shared.cancelTranscription(id)
            return true
        }.map { _ in ["ok": true] }
    }

    private static func writeSubtitles(
        _ object: [String: Any], operation: String
    ) -> [String: Any] {
        guard let id = boundedString(object["operationID"], 128),
              let expectedRevision = exactInt64(object["expectedRevision"]),
              let opID = boundedString(object["opID"], 100) else {
            return failure(C03VoiceError(.invalidSelection, "invalidSubtitleRequest"),
                           operation: operation)
        }
        let mode = (object["mode"] as? String) ?? "replaceTranscription"
        guard mode == "replaceTranscription" || mode == "append" else {
            return failure(C03VoiceError(.invalidSelection, "invalidSubtitleMode"),
                           operation: operation)
        }
        return block(seconds: 90, operation: operation) {
            try await C03VoiceDomain.shared.writeSubtitles(
                operationID: id,
                expectedRevision: expectedRevision,
                replaceTranscribed: mode == "replaceTranscription",
                opID: opID)
        }.map { receipt in
            [
                "ok": true,
                "receipt": [
                    "projectID": receipt.projectID.uuidString.lowercased(),
                    "revision": receipt.revision,
                    "canUndo": receipt.canUndo,
                    "canRedo": receipt.canRedo,
                    "opID": receipt.opID,
                    "idempotent": receipt.idempotent,
                ],
            ]
        }
    }

    private static func startSynthesis(
        _ object: [String: Any], operation: String
    ) -> [String: Any] {
        do {
            let selection = try parseSelection(object["selection"])
            guard let text = object["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= C03VoiceDomain.maxTextCharacters else {
                throw C03VoiceError(.invalidSelection, "invalidText")
            }
            let owner = parseOwner(object["owner"])
            return block(seconds: 30, operation: operation) {
                try await C03VoiceDomain.shared.startSynthesis(
                    text: text, selection: selection, owner: owner)
            }.map { id in ["ok": true, "operationID": id] }
        } catch let error as C03VoiceError {
            return failure(error, operation: operation)
        } catch {
            return failure(C03VoiceError(.invalidSelection, "invalidSynthesisRequest"),
                           operation: operation)
        }
    }

    private static func ttsStatus(
        _ object: [String: Any], operation: String
    ) -> [String: Any] {
        guard let id = boundedString(object["operationID"], 128) else {
            return failure(C03VoiceError(.invalidSelection, "missingOperationID"),
                           operation: operation)
        }
        return block(seconds: 5, operation: operation) {
            try await C03VoiceDomain.shared.ttsStatus(id)
        }.map { status in
            var value: [String: Any] = [
                "ok": true,
                "state": status.state.rawValue,
                "progress": status.progress,
                "sampleRate": status.sampleRate,
            ]
            if let path = status.audioPath { value["audioPath"] = path }
            if let duration = status.durationSeconds { value["durationSeconds"] = duration }
            if let failure = status.failure { value["failure"] = failureJSON(failure) }
            return value
        }
    }

    private static func cancelTTS(
        _ object: [String: Any], operation: String
    ) -> [String: Any] {
        guard let id = boundedString(object["operationID"], 128) else {
            return failure(C03VoiceError(.invalidSelection, "missingOperationID"),
                           operation: operation)
        }
        return blockValue(seconds: 20, operation: operation) {
            await C03VoiceDomain.shared.cancelSynthesis(id)
            return true
        }.map { _ in ["ok": true] }
    }

    private static func releaseTTS(
        _ object: [String: Any], operation: String
    ) -> [String: Any] {
        guard let id = boundedString(object["operationID"], 128) else {
            return failure(C03VoiceError(.invalidSelection, "missingOperationID"),
                           operation: operation)
        }
        return blockValue(seconds: 20, operation: operation) {
            await C03VoiceDomain.shared.releaseSynthesis(id)
            return true
        }.map { _ in ["ok": true] }
    }

    // MARK: - Request parsing

    private static func parseMedia(_ value: Any?) throws -> C03MediaContext {
        guard let object = value as? [String: Any],
              let projectID = UUID(uuidString: (object["projectID"] as? String) ?? ""),
              let sessionToken = boundedString(object["sessionToken"], 128),
              let storageObject = object["storage"] as? [String: Any],
              let kind = storageObject["kind"] as? String,
              let expectedRevision = exactInt64(object["expectedRevision"]),
              let assetID = UUID(uuidString: (object["assetID"] as? String) ?? "") else {
            throw C03VoiceError(.invalidSelection, "invalidMediaContext")
        }
        let storage: G09StorageLayerDTO
        switch kind {
        case "appOwned":
            guard storageObject["workspaceID"] == nil else {
                throw C03VoiceError(.invalidSelection, "appOwnedMustNotNameWorkspace")
            }
            storage = G09StorageLayerDTO(kind: .appOwned)
        case "workspace":
            guard let raw = storageObject["workspaceID"] as? String,
                  let workspaceID = UUID(uuidString: raw) else {
                throw C03VoiceError(.invalidSelection, "workspaceIDRequired")
            }
            storage = G09StorageLayerDTO(kind: .workspace, workspaceID: workspaceID)
        default:
            throw C03VoiceError(.invalidSelection, "invalidStorageLayer")
        }
        var origin: G09CreativeOriginDTO?
        if let originObject = object["origin"] as? [String: Any] {
            guard let rawKind = originObject["kind"] as? String,
                  let originKind = G09CreativeOriginDTO.Kind(rawValue: rawKind) else {
                throw C03VoiceError(.invalidSelection, "invalidOrigin")
            }
            origin = G09CreativeOriginDTO(
                kind: originKind,
                ownerID: (originObject["ownerID"] as? String).flatMap(UUID.init(uuidString:)),
                environmentID: boundedString(originObject["environmentID"], 128))
        }
        return C03MediaContext(
            projectID: projectID,
            sessionToken: sessionToken,
            storage: storage,
            origin: origin,
            expectedRevision: expectedRevision,
            assetID: assetID)
    }

    private static func parseSelection(_ value: Any?) throws -> C03VoiceSelection {
        guard let object = value as? [String: Any] else {
            throw C03VoiceError(.invalidSelection, "invalidSelection")
        }
        let engine = (object["engine"] as? String) ?? "cloud"
        guard engine == "cloud" else {
            throw C03VoiceError(.invalidSelection, "cloudSelectionRequired")
        }
        guard let providerRaw = object["providerID"] as? String,
              let modelRaw = object["modelID"] as? String,
              let providerID = UUID(uuidString: providerRaw),
              let modelID = UUID(uuidString: modelRaw) else {
            throw C03VoiceError(.invalidSelection, "providerAndModelRequired")
        }
        return C03VoiceSelection(
            engine: engine,
            providerID: providerID,
            modelID: modelID,
            voiceID: boundedString(object["voiceID"], 200),
            language: boundedString(object["language"], 64),
            rate: double(object["rate"]) ?? 1.0)
    }

    private static func parseOwner(_ value: Any?) -> C03VoiceOwner {
        guard let object = value as? [String: Any] else { return C03VoiceOwner() }
        return C03VoiceOwner(
            conversationID: (object["conversationID"] as? String)
                .flatMap { UUID(uuidString: $0) },
            taskID: (object["taskID"] as? String)
                .flatMap { UUID(uuidString: $0) },
            environmentID: boundedString(object["environmentID"], 128),
            projectID: (object["projectID"] as? String)
                .flatMap { UUID(uuidString: $0) },
            temporary: (object["temporary"] as? NSNumber)?.boolValue == true)
    }

    // MARK: - Encoding

    private static func modelJSON(_ model: C03SpeechModelChoice) -> [String: Any] {
        [
            "providerID": model.providerID.uuidString.lowercased(),
            "providerName": model.providerName,
            "modelID": model.modelID.uuidString.lowercased(),
            "remoteModelID": model.remoteModelID,
            "displayName": model.displayName,
            "likelyASR": model.likelyASR,
            "likelyTTS": model.likelyTTS,
            "credentialConfigured": model.credentialConfigured,
        ]
    }

    private static func failureJSON(_ failure: C03VoiceError) -> [String: Any] {
        var value: [String: Any] = [
            "code": failure.code.rawValue,
            "retryable": failure.retryable,
        ]
        if let reason = failure.reason { value["reason"] = reason }
        return value
    }

    private static func failure(_ error: C03VoiceError,
                               operation: String?) -> [String: Any] {
        var value: [String: Any] = [
            "ok": false,
            "error": error.code.rawValue,
            "retryable": error.retryable,
        ]
        if let operation { value["operation"] = operation }
        if let reason = error.reason { value["reason"] = reason }
        return value
    }

    // MARK: - Helpers

    private static func boundedString(_ value: Any?, _ limit: Int) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= limit else { return nil }
        return trimmed
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? Int { return value }
        return nil
    }

    /// Exact non-negative integer for revision fields. JSON booleans,
    /// fractional values and values outside `Int64` are refused; `NSNumber`
    /// bridging alone would silently coerce `true`/`1.5` to `1`.
    private static func exactInt64(_ value: Any?) -> Int64? {
        guard let value, !(value is NSNull),
              let number = value as? NSNumber else { return nil }
        let type = String(cString: number.objCType)
        guard type != "c", type != "B", type != "d", type != "f" else {
            return nil
        }
        guard let parsed = Int64(number.stringValue), parsed >= 0 else {
            return nil
        }
        return parsed
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let value = value as? Double { return value }
        return nil
    }

    private static func requireEpoch(_ object: [String: Any]) throws -> UInt64 {
        guard let number = object["epoch"] as? NSNumber,
              number.uint64Value > 0 else {
            throw C03VoiceError(.invalidSelection, "rootEpochRequired")
        }
        return number.uint64Value
    }

    private struct BlockResult<T: Sendable> {
        let operation: String
        let result: Result<T, C03VoiceError>

        func map(_ transform: (T) -> [String: Any]) -> [String: Any] {
            switch result {
            case .success(let value):
                return transform(value)
            case .failure(let error):
                return C03VoiceBridge.failure(error, operation: operation)
            }
        }
    }

    private static func block<T: Sendable>(
        seconds: Double,
        operation: String,
        _ body: @escaping @Sendable () async throws -> T
    ) -> BlockResult<T> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        let task = Task {
            do {
                box.set(.success(try await body()))
            } catch let error as C03VoiceError {
                box.set(.failure(error))
            } catch is CancellationError {
                box.set(.failure(C03VoiceError(.cancelled, "cancelled")))
            } catch {
                box.set(.failure(C03VoiceError(.internalFailure, "voiceOperationFailed")))
            }
            semaphore.signal()
        }
        let timeout = DispatchTime.now() + .milliseconds(Int(seconds * 1_000))
        if semaphore.wait(timeout: timeout) == .timedOut {
            task.cancel()
            return BlockResult(
                operation: operation,
                result: .failure(C03VoiceError(
                    .timeout, "outcomeMayBeUnknown", retryable: false)))
        }
        guard let result = box.get() else {
            return BlockResult(
                operation: operation,
                result: .failure(C03VoiceError(
                    .internalFailure, "missingOperationResult")))
        }
        return BlockResult(operation: operation, result: result)
    }

    private static func blockValue<T: Sendable>(
        seconds: Double,
        operation: String,
        _ body: @escaping @Sendable () async -> T
    ) -> BlockResult<T> {
        block(seconds: seconds, operation: operation) { () async throws -> T in
            await body()
        }
    }
}
