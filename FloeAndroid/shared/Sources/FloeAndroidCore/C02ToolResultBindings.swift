// SPDX-License-Identifier: MPL-2.0
//
// C02 — reserved trusted-host bridge `floe.results/20`.
//
// Host-only: it exposes bounded pages of a task's retained tool results to the
// app's existing tool-history/card detail entry. It is NOT a model tool, does
// not grant tool permission and never accepts a filesystem path. Model
// retrieval uses the registered `tools.readResult` runner, whose task
// identity comes from `ToolContext`, never from this ABI.
import Foundation
import Dispatch
#if canImport(CoreFoundation)
import CoreFoundation
#endif
import FloeCore
import FloeModels
import FloeTools
import FloeAndroidToolResults

public enum BridgeV20 {
    public static let version = C02ToolResultWire.version
    public static let schema = C02ToolResultWire.schema
    public static let maximumRequestBytes = C02ToolResultWire.maximumRequestBytes
    public static let maximumResponseBytes = C02ToolResultWire.maximumResponseBytes
    public static let modelTools = false
}

public enum C02ToolResultBridge {
    public static func handle(
        requestData: Data,
        fallbackRequestID: String?,
        service: C02ToolResultService,
        epoch: UInt64,
        liveEpoch: @escaping @Sendable () -> UInt64
    ) -> [String: Any] {
        var requestID = fallbackRequestID
        func failure(_ error: C02ToolResultError, operation: String?) -> [String: Any] {
            var value: [String: Any] = [
                "ok": false,
                "code": error.code,
                "retryable": error.retryable,
                "message": error.message,
                "schema": C02ToolResultWire.schema,
            ]
            if let operation { value["operation"] = operation }
            if let requestID { value["requestID"] = requestID }
            return value
        }
        guard requestData.count <= C02ToolResultWire.maximumRequestBytes else {
            return failure(.invalidRequest("requestTooLarge"), operation: nil)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any],
              let version = exactInt(object["version"]),
              version == C02ToolResultWire.version,
              let operation = boundedString(object["operation"], 64) else {
            return failure(.invalidRequest("request"), operation: nil)
        }
        requestID = boundedString(object["requestID"], 256) ?? requestID
        let responseRequestID = requestID
        let temporary = (object["temporary"] as? Bool) ?? false
        let request = C02ResultRequest(object)

        switch operation {
        case "handshake", "c02.results.capabilities":
            let live = epoch > 0 && liveEpoch() == epoch
            var value: [String: Any] = [
                "ok": true,
                "schema": C02ToolResultWire.schema,
                "channel": C02ToolResultWire.version,
                "coreReady": live,
                "epoch": epoch,
                "modelTools": BridgeV20.modelTools,
                "modelResultTool": C02ToolResultWire.modelToolName,
                "maximumRequestBytes": C02ToolResultWire.maximumRequestBytes,
                "maximumResponseBytes": C02ToolResultWire.maximumResponseBytes,
                "maximumPageBytes": C02ToolResultWire.maximumPageBytes,
                "defaultPageBytes": C02ToolResultWire.defaultPageBytes,
                "temporary": temporary,
            ]
            if let requestID { value["requestID"] = requestID }
            return value
        case "c02.results.index":
            guard !temporary else {
                return failure(.temporaryTaskRefused, operation: operation)
            }
            guard let taskID = request.uuid("taskID") else {
                return failure(.invalidRequest("taskID"), operation: operation)
            }
            let hasRunID = object["runID"] != nil
            let runID = request.uuid("runID")
            if hasRunID && runID == nil {
                return failure(.invalidRequest("runID"), operation: operation)
            }
            let limit = min(max(1, request.int("limit") ?? C02ToolResultWire.maximumIndexRows),
                            C02ToolResultWire.maximumIndexRows)
            return awaitResult(operation: operation, requestID: requestID) {
                let (rows, evicted) = try await service.index(
                    taskID: taskID, runID: runID, limit: limit)
                return payload([
                    "taskID": taskID.uuidString,
                    "evicted": evicted,
                    "rows": rows.map(rowWire),
                    "modelResultTool": C02ToolResultWire.modelToolName,
                ])
            }
        case "c02.results.page":
            guard let taskID = request.uuid("taskID") else {
                return failure(.invalidRequest("taskID"), operation: operation)
            }
            let ref = request.string("ref", 64)
            let callID = request.string("callID", 256)
            guard ref != nil || callID != nil else {
                return failure(.invalidRequest("refOrCallID"), operation: operation)
            }
            let offset = max(0, request.int("offset") ?? 0)
            let requested = request.int("length") ?? request.int("maxBytes") ?? C02ToolResultWire.defaultPageBytes
            let maximum = min(max(1, requested), C02ToolResultWire.maximumPageBytes)
            let hasExpectedDigest = object["expectedSHA256"] != nil
            let expected = request.digest("expectedSHA256")
            if hasExpectedDigest && expected == nil {
                return failure(.invalidRequest("expectedSHA256"), operation: operation)
            }
            let hasRunID = object["runID"] != nil
            let runID = request.uuid("runID")
            if hasRunID && runID == nil {
                return failure(.invalidRequest("runID"), operation: operation)
            }
            let exactRun = (object["exactRun"] as? Bool) ?? false
            return awaitResult(operation: operation, requestID: requestID) {
                let outcome = try await service.page(
                    taskID: taskID,
                    ref: ref,
                    callID: callID,
                    runID: runID,
                    offset: offset,
                    maxBytes: maximum,
                    expectedSHA256: expected,
                    temporary: temporary,
                    exactRun: exactRun
                )
                switch outcome {
                case .page(let page):
                    var value: [String: Any] = [
                        "taskID": taskID.uuidString,
                        "ref": page.ref,
                        "runID": page.runID.uuidString,
                        "callID": page.callID,
                        "toolName": page.toolName,
                        "status": page.status,
                        "offset": page.offset,
                        "endOffset": page.endOffset,
                        "totalBytes": page.totalBytes,
                        "text": page.text,
                        "sha256": page.sha256,
                        "executionReportedTruncation": page.executionReportedTruncation,
                        "retentionTruncated": page.retentionTruncated,
                        "durability": page.durability,
                        "restoredFromDisk": page.restoredFromDisk,
                        "evictedCopies": page.evictedCopies,
                        "capturedAt": iso(page.capturedAt),
                    ]
                    if let next = page.nextOffset { value["nextOffset"] = next }
                    if let original = page.originalDigest { value["originalDigest"] = original }
                    return payload(value)
                case .outOfRange(let totalBytes, let identity):
                    return failurePayload(
                        code: "offsetOutOfRange",
                        message: "The requested offset is outside the retained result.",
                        retryable: false,
                        operation: operation,
                        requestID: responseRequestID,
                        extra: ["identity": identity, "totalBytes": totalBytes]
                    )
                case .changed(let identity, let expectedDigest, let actualDigest):
                    return failurePayload(
                        code: "changed",
                        message: "The retained result changed after the first page; restart at offset 0.",
                        retryable: true,
                        operation: operation,
                        requestID: responseRequestID,
                        extra: [
                            "identity": identity,
                            "expectedSHA256": expectedDigest,
                            "actualSHA256": actualDigest,
                        ]
                    )
                case .missing(let identity, let reason):
                    return failurePayload(
                        code: "missing",
                        message: reason,
                        retryable: false,
                        operation: operation,
                        requestID: responseRequestID,
                        extra: ["identity": identity]
                    )
                }
            }
        case "c02.results.search":
            guard let taskID = request.uuid("taskID"),
                  let query = request.string("query", 360) else {
                return failure(.invalidRequest("search"), operation: operation)
            }
            let limit = min(max(1, request.int("limit") ?? C02ToolResultWire.maximumSearchHits),
                            C02ToolResultWire.maximumSearchHits)
            return awaitResult(operation: operation, requestID: requestID) {
                let result = try await service.search(
                    taskID: taskID, query: query, limit: limit, temporary: temporary)
                return payload([
                    "taskID": taskID.uuidString,
                    "hits": result.hits.map(hitWire),
                    "searchedCaptures": result.searchedCaptures,
                    "searchedBytes": result.searchedBytes,
                    "truncated": result.truncated,
                ])
            }
        case "c02.results.purge":
            guard !temporary else {
                return failure(.temporaryTaskRefused, operation: operation)
            }
            guard let taskID = request.uuid("taskID") else {
                return failure(.invalidRequest("taskID"), operation: operation)
            }
            return awaitResult(operation: operation, requestID: requestID) {
                let result = await service.purge(taskID: taskID)
                return payload([
                    "taskID": taskID.uuidString,
                    "removedDurableDirectory": result.removedDurableDirectory,
                    "failure": result.failure?.rawValue ?? NSNull(),
                    "retryScheduled": result.retryScheduled,
                ])
            }
        default:
            return failure(.unsupportedOperation, operation: operation)
        }
    }

    // MARK: - Wire helpers

    private static func rowWire(_ row: C02ToolResultIndexRow) -> [String: Any] {
        var value: [String: Any] = [
            "ref": row.ref,
            "runID": row.runID.uuidString,
            "callID": row.callID,
            "toolName": row.toolName,
            "totalBytes": row.totalBytes,
            "executionReportedTruncation": row.executionReportedTruncation,
            "retentionTruncated": row.retentionTruncated,
            "capturedAt": iso(row.capturedAt),
            "durability": row.durability,
            "sha256": row.sha256,
        ]
        if let original = row.originalDigest { value["originalDigest"] = original }
        return value
    }

    private static func hitWire(_ hit: C02ToolResultSearchHit) -> [String: Any] {
        [
            "ref": hit.ref,
            "runID": hit.runID.uuidString,
            "callID": hit.callID,
            "toolName": hit.toolName,
            "totalBytes": hit.totalBytes,
            "matchOffset": hit.matchOffset,
            "excerpt": hit.excerpt,
            "hasAdditionalMatches": hit.hasAdditionalMatches,
            "sha256": hit.sha256,
        ]
    }

    private static func payload(_ value: [String: Any]) -> [String: Any] {
        var object = value
        object["ok"] = true
        object["schema"] = C02ToolResultWire.schema
        return object
    }

    private static func failurePayload(
        code: String,
        message: String,
        retryable: Bool,
        operation: String,
        requestID: String?,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var value: [String: Any] = [
            "ok": false,
            "code": code,
            "message": message,
            "retryable": retryable,
            "schema": C02ToolResultWire.schema,
            "operation": operation,
        ]
        for (key, item) in extra { value[key] = item }
        if let requestID { value["requestID"] = requestID }
        return value
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    fileprivate static func exactInt(_ value: Any?) -> Int? {
        if let text = value as? String { return Int(text) }
        guard let number = value as? NSNumber else { return nil }
        #if canImport(CoreFoundation)
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        #endif
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double else { return nil }
        return number.intValue
    }

    fileprivate static func boundedString(_ value: Any?, _ maximum: Int) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximum,
              trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            return nil
        }
        return trimmed
    }

    private struct C02ResultRequest {
        let object: [String: Any]
        init(_ object: [String: Any]) { self.object = object }

        func string(_ key: String, _ maximum: Int) -> String? {
            C02ToolResultBridge.boundedString(object[key], maximum)
        }

        func uuid(_ key: String) -> UUID? {
            guard let value = string(key, 64) else { return nil }
            return UUID(uuidString: value)
        }

        func int(_ key: String) -> Int? {
            C02ToolResultBridge.exactInt(object[key])
        }

        func digest(_ key: String) -> String? {
            guard let value = string(key, 64) else { return nil }
            let lower = value.lowercased()
            guard lower.count == 64,
                  lower.allSatisfy({ ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }) else {
                return nil
            }
            return lower
        }
    }

    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<T, Error>?
        func set(_ result: Result<T, Error>) {
            lock.lock(); value = result; lock.unlock()
        }
        func get() -> Result<T, Error>? {
            lock.lock(); defer { lock.unlock() }; return value
        }
    }

    private static func awaitResult(
        operation: String,
        requestID: String?,
        seconds: Double = 10,
        _ work: @escaping @Sendable () async throws -> [String: Any]
    ) -> [String: Any] {
        let box = ResultBox<[String: Any]>()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do { box.set(.success(try await work())) }
            catch { box.set(.failure(error)) }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + seconds) == .timedOut {
            return failurePayload(
                code: C02ToolResultError.timedOut.code,
                message: C02ToolResultError.timedOut.message,
                retryable: true,
                operation: operation,
                requestID: requestID
            )
        }
        guard let result = box.get() else {
            return failurePayload(
                code: C02ToolResultError.notInstalled.code,
                message: C02ToolResultError.notInstalled.message,
                retryable: false,
                operation: operation,
                requestID: requestID
            )
        }
        switch result {
        case .success(let value):
            var object = value
            object["operation"] = operation
            if let requestID { object["requestID"] = requestID }
            return object
        case .failure(let error as C02ToolResultError):
            return failurePayload(
                code: error.code,
                message: error.message,
                retryable: error.retryable,
                operation: operation,
                requestID: requestID
            )
        case .failure(let error):
            return failurePayload(
                code: "internal",
                message: "The result read failed.",
                retryable: false,
                operation: operation,
                requestID: requestID
            )
        }
    }
}
