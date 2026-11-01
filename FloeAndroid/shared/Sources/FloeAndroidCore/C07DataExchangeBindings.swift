// SPDX-License-Identifier: MPL-2.0
//
// C07 additive bridge `floe.data/16` (channel 16 reserved by Main).
//
// Same frozen `floe_bridge_exchange` C ABI, request frame 65,536 B, metadata
// reply <= 48 KiB. No full archive is ever JSON/base64-encoded in one call:
// backups and note exports are read in <=24 KiB chunks; restore uploads stream
// in the same bounded chunks. This is a trusted App-host channel, not a model
// tool, V3 command, approval bypass or SAF/network grant.
import Foundation
import Dispatch
import FloePersistence
import FloeAndroidDataExchange

public enum BridgeV16 {
    public static let version = C07DataExchangeWire.version
    public static let schema = C07DataExchangeWire.schema
    public static let maximumRequestBytes = C07DataExchangeWire.maximumRequestBytes
    public static let maximumResponseBytes = C07DataExchangeWire.maximumResponseBytes
    public static let modelTools = false
}

public enum C07DataExchangeBridge {
    private static let operations: Set<String> = [
        "handshake", "c07.capabilities",
        "c07.backup.begin",
        "c07.job.status", "c07.job.read", "c07.job.close", "c07.job.cancel",
        "c07.restore.stageBegin", "c07.restore.stageAppend",
        "c07.restore.stageCommit", "c07.restore.stageAbort",
        "c07.restore.inspect", "c07.restore.commit", "c07.restore.abort",
        "c07.restore.pending", "c07.restore.recover",
        "c07.document.exportNote", "c07.document.exportCanvas",
        "c07.document.canvases",
    ]

    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<T, Error>?
        func set(_ result: Result<T, Error>) {
            lock.lock(); value = result; lock.unlock()
        }
        func get() -> Result<T, Error>? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    private static func block<T: Sendable>(
        seconds: Double,
        _ body: @escaping @Sendable () async throws -> T
    ) -> Result<T, Error> {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task {
            do { box.set(.success(try await body())) }
            catch { box.set(.failure(error)) }
            semaphore.signal()
        }
        let timeout = DispatchTime.now() + .milliseconds(Int(max(0.05, seconds) * 1_000))
        if semaphore.wait(timeout: timeout) == .timedOut {
            task.cancel()
            return .failure(C07DataExchangeError.storageUnavailable("timedOut"))
        }
        return box.get() ?? .failure(C07DataExchangeError.storageUnavailable("missingResult"))
    }

    public static func handle(requestData: Data, fallbackRequestID: String?) -> [String: Any] {
        var requestID = fallbackRequestID
        func failure(_ error: C07DataExchangeError, operation: String?) -> [String: Any] {
            var value: [String: Any] = [
                "ok": false,
                "code": error.code,
                "reason": c07SafeText(error.errorDescription ?? error.code, max: 240),
                "retryable": error == .restoreBusy,
                "schema": BridgeV16.schema,
            ]
            if let operation { value["operation"] = operation }
            if let requestID { value["requestID"] = requestID }
            return value
        }
        func internalFailure(_ operation: String?, _ code: String = "internal") -> [String: Any] {
            failure(C07DataExchangeError.storageUnavailable(code), operation: operation)
        }

        guard requestData.count <= BridgeV16.maximumRequestBytes else {
            return failure(C07DataExchangeError.invalidScope("requestTooLarge"), operation: nil)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any],
              let version = c07Int(object["version"]), version == BridgeV16.version,
              c07String(object["schema"], maxBytes: 64) == BridgeV16.schema,
              let operation = c07String(object["operation"], maxBytes: 64),
              operations.contains(operation) else {
            return failure(C07DataExchangeError.invalidScope("invalidRequest"), operation: nil)
        }
        requestID = c07String(object["requestID"], maxBytes: 256) ?? requestID

        func reply(_ body: [String: Any]) -> [String: Any] {
            var value = body
            value["ok"] = value["ok"] ?? true
            value["schema"] = BridgeV16.schema
            value["operation"] = operation
            if let requestID { value["requestID"] = requestID }
            guard JSONSerialization.isValidJSONObject(value),
                  let encoded = try? JSONSerialization.data(
                    withJSONObject: value, options: [.sortedKeys]),
                  encoded.count <= BridgeV16.maximumResponseBytes - 256 else {
                return failure(C07DataExchangeError.invalidScope("responseTooLarge"),
                               operation: operation)
            }
            return value
        }

        do {
            if operation == "handshake" {
                return reply(capabilitiesJSON())
            }
            let owner = try C07ExchangeOwner.parse(object["owner"])
            let domain = C07DataExchangeDomain.shared

            switch operation {
            case "c07.capabilities":
                return reply(capabilitiesJSON())

            case "c07.backup.begin":
                let context = try block(seconds: 10) {
                    try await domain.makeContext(owner: owner)
                }.get()
                let includeRetained = c07Bool(object["includeRetainedProjects"]) ?? true
                let job = block(seconds: 10) {
                    await domain.startBackup(
                        context: context, includeRetainedProjects: includeRetained)
                }
                return reply(["jobID": try job.get().uuidString])

            case "c07.job.status":
                let jobID = try c07UUID(object["jobID"])
                let status = try block(seconds: 10) {
                    try await domain.status(jobID: jobID)
                }.get()
                return reply(statusJSON(status))

            case "c07.job.read":
                let jobID = try c07UUID(object["jobID"])
                let offset = try c07Int64(object["offset"])
                let maxBytes = c07Int(object["maxBytes"]) ?? C07DataExchangeWire.maximumChunkBytes
                let read = try block(seconds: 15) {
                    try await domain.read(jobID: jobID, offset: offset, maxBytes: maxBytes)
                }.get()
                return reply([
                    "jobID": jobID.uuidString,
                    "offset": offset,
                    "nextOffset": read.nextOffset,
                    "totalBytes": read.totalBytes,
                    "eof": read.eof,
                    "dataBase64": read.data.base64EncodedString(),
                ])

            case "c07.job.close":
                let jobID = try c07UUID(object["jobID"])
                _ = try block(seconds: 10) {
                    await domain.closeJob(jobID: jobID)
                }.get()
                return reply(["jobID": jobID.uuidString, "closed": true])

            case "c07.job.cancel":
                let jobID = try c07UUID(object["jobID"])
                _ = try block(seconds: 10) {
                    await domain.cancel(jobID: jobID)
                }.get()
                return reply(["jobID": jobID.uuidString, "cancelled": true])

            case "c07.restore.stageBegin":
                let context = try block(seconds: 10) {
                    try await domain.makeContext(owner: owner)
                }.get()
                let byteCount = try c07Int64(object["byteCount"])
                let stageID = try block(seconds: 10) {
                    try await domain.stageBegin(context: context, byteCount: byteCount)
                }.get()
                return reply([
                    "stageID": stageID.uuidString,
                    "chunkBytes": C07DataExchangeWire.maximumChunkBytes,
                    "totalBytes": byteCount,
                ])

            case "c07.restore.stageAppend":
                let stageID = try c07UUID(object["stageID"])
                guard let encoded = c07String(object["dataBase64"], maxBytes: 40_000),
                      let data = Data(base64Encoded: encoded),
                      data.count <= C07DataExchangeWire.maximumChunkBytes else {
                    throw C07DataExchangeError.invalidScope("stageChunk")
                }
                let result = try block(seconds: 20) {
                    try await domain.stageAppend(stageID: stageID, data: data)
                }.get()
                return reply([
                    "stageID": stageID.uuidString,
                    "receivedBytes": result.receivedBytes,
                    "totalBytes": result.totalBytes,
                ])

            case "c07.restore.stageCommit":
                let stageID = try c07UUID(object["stageID"])
                _ = try block(seconds: 20) {
                    try await domain.stageCommit(stageID: stageID)
                }.get()
                return reply(["stageID": stageID.uuidString, "committed": true])

            case "c07.restore.stageAbort":
                let stageID = try c07UUID(object["stageID"])
                _ = try block(seconds: 10) {
                    await domain.stageAbort(stageID: stageID)
                }.get()
                return reply(["stageID": stageID.uuidString, "aborted": true])

            case "c07.restore.inspect":
                let context = try block(seconds: 10) {
                    try await domain.makeContext(owner: owner)
                }.get()
                let stageID = try c07UUID(object["stageID"])
                let kind = c07String(object["kind"], maxBytes: 16) ?? "backup"
                let displayName = c07String(object["displayName"], maxBytes: 256)
                let jobID = try block(seconds: 10) {
                    switch kind {
                    case "note":
                        return try await domain.startNoteImportInspect(
                            context: context, stageID: stageID)
                    case "canvas":
                        return try await domain.startCanvasImportInspect(
                            context: context, stageID: stageID)
                    case "document":
                        return try await domain.startDocumentImportInspect(
                            context: context, stageID: stageID,
                            displayName: displayName ?? "document.docx")
                    default:
                        return try await domain.startRestoreInspect(
                            context: context, stageID: stageID,
                            currentAppSchemaVersion: DatabaseManager.currentSchemaVersion)
                    }
                }.get()
                return reply(["jobID": jobID.uuidString])

            case "c07.restore.commit":
                let context = try block(seconds: 10) {
                    try await domain.makeContext(owner: owner)
                }.get()
                let jobID = try c07UUID(object["jobID"])
                let started = try block(seconds: 10) {
                    try await domain.startRestoreCommit(context: context, jobID: jobID)
                }.get()
                return reply(["jobID": started.uuidString])

            case "c07.restore.abort":
                let jobID = try c07UUID(object["jobID"])
                _ = try block(seconds: 10) {
                    await domain.closeJob(jobID: jobID)
                }.get()
                return reply(["jobID": jobID.uuidString, "aborted": true])

            case "c07.restore.pending":
                let context = try block(seconds: 10) {
                    try await domain.makeContext(owner: owner)
                }.get()
                let pending = try block(seconds: 10) {
                    await domain.recoveryPending(context: context)
                }.get()
                return reply(["pendingRecoveries": pending])

            case "c07.restore.recover":
                let context = try block(seconds: 10) {
                    try await domain.makeContext(owner: owner)
                }.get()
                let report = try block(seconds: 180) {
                    await domain.recover(context: context)
                }.get()
                return reply([
                    "recovered": report.recoveredJournals,
                    "failed": report.failedJournals,
                    "details": Array(report.details.prefix(16)),
                ])

            case "c07.document.exportCanvas":
                let context = try block(seconds: 10) {
                    try await domain.makeContext(owner: owner)
                }.get()
                let canvasID = try c07UUID(object["canvasID"])
                let job = block(seconds: 10) {
                    await domain.startCanvasExport(
                        context: context, canvasID: canvasID)
                }
                return reply(["jobID": try job.get().uuidString])

            case "c07.document.canvases":
                let context = try block(seconds: 10) {
                    try await domain.makeContext(owner: owner)
                }.get()
                let canvases = c07ListCanvases(context: context)
                return reply(["canvases": canvases])

            case "c07.document.exportNote":
                let context = try block(seconds: 10) {
                    try await domain.makeContext(owner: owner)
                }.get()
                let documentID = try c07UUID(object["documentID"])
                let revision = c07Int(object["expectedRevision"]) ?? 0
                guard revision > 0 else {
                    throw C07DataExchangeError.invalidScope("expectedRevision")
                }
                let job = block(seconds: 10) {
                    await domain.startNoteExport(
                        context: context, documentID: documentID,
                        expectedRevision: revision)
                }
                return reply(["jobID": try job.get().uuidString])

            default:
                return failure(C07DataExchangeError.invalidScope("unsupportedOperation"),
                               operation: operation)
            }
        } catch let error as C07DataExchangeError {
            return failure(error, operation: operation)
        } catch {
            return internalFailure(operation)
        }
    }

    // MARK: - JSON projections

    private static func c07ListCanvases(context: C07DataExchangeContext)
        -> [[String: Any]]
    {
        let directory = context.artifactRoot.appendingPathComponent(
            "Canvases", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                          .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var result: [[String: Any]] = []
        for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension.lowercased() == "json" {
            guard result.count < 500,
                  let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                              .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0,
                  size <= 32 * 1_024 * 1_024,
                  let data = try? Data(contentsOf: url) else { continue }
            guard let object = (try? JSONSerialization.jsonObject(
                with: data)) as? [String: Any],
                  let idText = object["id"] as? String,
                  let id = UUID(uuidString: idText) else { continue }
            result.append([
                "canvasID": id.uuidString,
                "name": c07SafeText((object["name"] as? String) ?? "Canvas", max: 200),
                "updatedAt": (object["updatedAt"] as? String) ?? "",
            ])
        }
        return result
    }

    private static func capabilitiesJSON() -> [String: Any] {
        [
            "formatVersion": C07DataExchangeWire.formatVersion,
            "backupExtension": C07DataExchangeWire.backupExtension,
            "notesExtension": C07DataExchangeWire.notesExtension,
            "canvasExtension": C07DocumentPackageLimits.canvasExtension,
            "documentExtensions": ["docx", "pdf"],
            "databaseCopied": false,
            "credentialsExcluded": true,
            "modelTools": false,
            "modelToolNames": [],
            "requestBytes": C07DataExchangeWire.maximumRequestBytes,
            "responseBytes": C07DataExchangeWire.maximumResponseBytes,
            "chunkBytes": C07DataExchangeWire.maximumChunkBytes,
            "included": C07BackupScope.includedIDs,
            "excluded": C07ScopePolicy.excluded.map {
                ["id": $0.id, "reason": $0.reason]
            },
            "operations": [
                "c07.backup.begin", "c07.job.status", "c07.job.read",
                "c07.job.close", "c07.job.cancel",
                "c07.restore.stageBegin", "c07.restore.stageAppend",
                "c07.restore.stageCommit", "c07.restore.stageAbort",
                "c07.restore.inspect", "c07.restore.commit", "c07.restore.abort",
                "c07.restore.pending", "c07.restore.recover",
                "c07.document.exportNote", "c07.document.exportCanvas",
                "c07.document.canvases",
            ],
            "limits": [
                "maximumManifestBytes": C07DataExchangeLimits.maximumManifestBytes,
                "maximumEntries": C07DataExchangeLimits.maximumEntries,
                "maximumEntryBytes": C07DataExchangeLimits.maximumEntryBytes,
                "maximumTotalBytes": C07DataExchangeLimits.maximumTotalBytes,
                "maximumNoteArchiveBytes": C07DataExchangeLimits.maximumNoteArchiveBytes,
                "maximumNoteResourceBytes": C07DataExchangeLimits.maximumNoteResourceBytes,
            ],
        ]
    }

    private static func statusJSON(_ status: C07JobStatus) -> [String: Any] {
        var value: [String: Any] = [
            "jobID": status.jobID.uuidString,
            "kind": status.kind,
            "phase": status.phase,
            "doneBytes": status.doneBytes,
            "totalBytes": status.totalBytes,
            "warnings": Array(status.warnings.prefix(32).map {
                c07SafeText($0, max: 200)
            }),
            "canCommit": status.canCommit,
        ]
        if let code = status.errorCode { value["error"] = code }
        if let bytes = status.fileByteCount { value["fileByteCount"] = bytes }
        if let sha = status.fileSHA256 { value["fileSHA256"] = sha }
        var plan: [String: Any] = [:]
        if let count = status.projectCount { plan["projects"] = count }
        if let count = status.projectFileCount { plan["projectFiles"] = count }
        if let count = status.noteDocumentCount { plan["noteDocuments"] = count }
        if let count = status.noteResourceCount { plan["noteResources"] = count }
        if let count = status.notebookCount { plan["notebooks"] = count }
        if let count = status.settingsKeyCount { plan["settingsKeys"] = count }
        if let count = status.providerAdvisoryCount { plan["providerAdvisories"] = count }
        if let count = status.trashedNotesExcluded { plan["trashedNotesExcluded"] = count }
        if let count = status.skippedProjects { plan["skippedProjects"] = count }
        if let count = status.conversationCount { plan["conversations"] = count }
        if let count = status.messageCount { plan["messages"] = count }
        if let count = status.runCount { plan["runs"] = count }
        if let count = status.toolCallCount { plan["toolCalls"] = count }
        if let count = status.workspaceCount { plan["workspaces"] = count }
        if let count = status.canvasProjectCount { plan["canvasProjects"] = count }
        if let count = status.mediaProjectCount { plan["mediaProjects"] = count }
        if let count = status.mediaAssetCount { plan["mediaAssets"] = count }
        if let count = status.scheduleCount { plan["schedules"] = count }
        if let count = status.actionReceiptCount { plan["actionReceipts"] = count }
        if let count = status.mailReceiptCount { plan["mailReceipts"] = count }
        if let count = status.providerConfigCount { plan["providerConfigs"] = count }
        if let count = status.executionEvidenceCount {
            plan["executionEvidence"] = count
        }
        if let count = status.todoCount { plan["todos"] = count }
        if let count = status.toolResultCount { plan["toolResults"] = count }
        if let count = status.appArtifactCount { plan["appArtifacts"] = count }
        if let count = status.captureFileCount { plan["captureFiles"] = count }
        if let count = status.configSectionCount { plan["configSections"] = count }
        if let partial = status.partial { plan["partial"] = partial }
        if let count = status.omissionCount { plan["omissions"] = count }
        if !plan.isEmpty { value["plan"] = plan }
        var receipt: [String: Any] = [:]
        if let count = status.restoredProjects { receipt["projects"] = count }
        if let count = status.restoredNotes { receipt["noteDocuments"] = count }
        if let count = status.restoredNotebooks { receipt["notebooks"] = count }
        if let count = status.restoredSettings { receipt["settings"] = count }
        if let count = status.skippedProjects { receipt["projectsSkipped"] = count }
        if let count = status.restoredConversations { receipt["conversations"] = count }
        if let count = status.restoredMessages { receipt["messages"] = count }
        if let count = status.restoredRuns { receipt["runs"] = count }
        if let count = status.restoredToolCalls { receipt["toolCalls"] = count }
        if let count = status.restoredWorkspaces { receipt["workspaces"] = count }
        if let count = status.restoredSchedules { receipt["schedules"] = count }
        if let count = status.restoredProviders { receipt["providers"] = count }
        if let count = status.restoredCanvasProjects {
            receipt["canvasProjects"] = count
        }
        if let count = status.restoredMediaProjects {
            receipt["mediaProjects"] = count
        }
        if let count = status.restoredEvidenceRows {
            receipt["evidenceRows"] = count
        }
        if let count = status.restoredTodos { receipt["todos"] = count }
        if let count = status.restoredToolResults {
            receipt["toolResults"] = count
        }
        if let count = status.restoredAppArtifacts {
            receipt["appArtifacts"] = count
        }
        if let count = status.restoredCaptureFiles {
            receipt["captureFiles"] = count
        }
        if let count = status.restoredCADPreserved {
            receipt["cadPreserved"] = count
        }
        if let count = status.restoredConfigSections {
            receipt["configSections"] = count
        }
        if let partial = status.partial { receipt["partial"] = partial }
        if !receipt.isEmpty { value["receipt"] = receipt }
        return value
    }
}

// MARK: - Small parsers

private func c07SafeText(_ raw: String, max: Int) -> String {
    let filtered = raw.filter { character in
        character.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && $0.value != 0x7F
        }
    }
    return String(filtered.prefix(max))
}

private func c07String(_ value: Any?, maxBytes: Int) -> String? {
    guard let text = value as? String, !text.isEmpty,
          text.utf8.count <= maxBytes else { return nil }
    return text
}

private func c07Int(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double.rounded(.towardZero) == double,
          double >= Double(Int32.min), double <= Double(Int32.max) else { return nil }
    return number.intValue
}

private func c07Int64(_ value: Any?) throws -> Int64 {
    guard let number = value as? NSNumber else {
        throw C07DataExchangeError.invalidScope("integer")
    }
    let double = number.doubleValue
    guard double.isFinite, double.rounded(.towardZero) == double,
          double >= Double(Int64.min), double <= Double(Int64.max) else {
        throw C07DataExchangeError.invalidScope("integer")
    }
    return number.int64Value
}

private func c07Bool(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber else { return nil }
    return number.boolValue
}

private func c07UUID(_ value: Any?) throws -> UUID {
    guard let text = c07String(value, maxBytes: 64),
          let id = UUID(uuidString: text) else {
        throw C07DataExchangeError.invalidScope("uuid")
    }
    return id
}
