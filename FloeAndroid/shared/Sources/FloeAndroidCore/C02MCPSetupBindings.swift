// SPDX-License-Identifier: MPL-2.0
//
// C02 — reserved trusted-host bridge `floe.mcpsetup/23`.
//
// Host-only: this surface lets the Settings → Skills/MCP guided setup read
// explicit projects/environments, validate a draft with the ORIGINAL rules,
// stage the verified App-owned template, drive bounded `exec.shell` dependency
// phases, start/stop a C01-owned Linux service lane, run the ORIGINAL MCP
// client verification, and commit through the existing MCP domain save path.
//
// It is not a model tool: no tool key is registered, no permission is
// granted, and no credential bytes cross this ABI. Template chunks are
// public reviewed source bytes, not a secret. Absolute paths, raw job output
// and remote tool schemas never leave the native side; only digests, bounded
// labels, relative workspace paths and typed codes are returned.
import Foundation
import Dispatch
#if canImport(CoreFoundation)
import CoreFoundation
#endif
import FloeCore
import FloeTools

public enum C02MCPSetupWire {
    public static let version = 23
    public static let schema = "floe.mcpsetup/23"
    public static let maximumRequestBytes = C02MCPSetupLimits.maximumRequestBytes
    public static let maximumResponseBytes = C02MCPSetupLimits.maximumResponseBytes
    public static let templateChunkBytes = 44_000
    public static let modelTools = false
    public static let operations: Set<String> = [
        "handshake", "floe.mcpsetup.capabilities", "mcp.setup.capabilities",
        "mcp.setup.projects", "mcp.setup.environments", "mcp.setup.validate",
        "mcp.setup.records.create", "mcp.setup.template.chunk",
        "mcp.setup.prepare", "mcp.setup.build.start", "mcp.setup.build.poll",
        "mcp.setup.build.cancel", "mcp.setup.service.start", "mcp.setup.verify",
        "mcp.setup.commit", "mcp.setup.stop", "mcp.setup.discard",
        "mcp.setup.records.list", "mcp.setup.records.status",
        "mcp.setup.stdio.capabilities",
    ]
}

public enum BridgeV23 {
    public static let version = C02MCPSetupWire.version
    public static let schema = C02MCPSetupWire.schema
    public static let maximumRequestBytes = C02MCPSetupWire.maximumRequestBytes
    public static let maximumResponseBytes = C02MCPSetupWire.maximumResponseBytes
    public static let modelTools = false
}

public final class C02MCPSetupBridgeRuntime: @unchecked Sendable {
    public let epoch: UInt64
    public let center: C02MCPSetupCenter
    public let templateAssetAvailable: Bool
    public let stdioLaneAvailable: Bool
    private let liveEpoch: @Sendable () -> UInt64

    public init(epoch: UInt64, center: C02MCPSetupCenter,
                templateAssetAvailable: Bool, stdioLaneAvailable: Bool,
                liveEpoch: @escaping @Sendable () -> UInt64) {
        self.epoch = epoch
        self.center = center
        self.templateAssetAvailable = templateAssetAvailable
        self.stdioLaneAvailable = stdioLaneAvailable
        self.liveEpoch = liveEpoch
    }

    public func isLive() -> Bool { epoch > 0 && liveEpoch() == epoch }
}

public enum C02MCPSetupBridge {
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        func set(_ value: T) { lock.lock(); self.value = value; lock.unlock() }
        func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
    }

    public static func handle(requestData: Data,
                              fallbackRequestID: String?,
                              runtime: C02MCPSetupBridgeRuntime?) -> [String: Any] {
        var requestID = fallbackRequestID
        func failure(_ code: String, _ message: String, retryable: Bool,
                     operation: String?) -> [String: Any] {
            var value: [String: Any] = [
                "ok": false,
                "schema": C02MCPSetupWire.schema,
                "code": code,
                "message": String(message.prefix(512)),
                "retryable": retryable,
            ]
            if let operation { value["operation"] = operation }
            if let requestID { value["requestID"] = requestID }
            return value
        }
        guard requestData.count <= C02MCPSetupWire.maximumRequestBytes else {
            return failure("requestTooLarge", "The MCP setup request exceeded the supported bound.", retryable: false, operation: nil)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any],
              let version = exactInt(object["version"]),
              version == C02MCPSetupWire.version,
              let operation = boundedString(object["operation"], 64),
              C02MCPSetupWire.operations.contains(operation) else {
            return failure("invalidRequest", "The MCP setup request is not valid.", retryable: false, operation: nil)
        }
        requestID = boundedString(object["requestID"], 256) ?? requestID
        let responseID = requestID
        let success: @Sendable ([String: Any]) -> [String: Any] = { fields in
            var value = fields
            value["ok"] = true
            value["schema"] = C02MCPSetupWire.schema
            value["operation"] = operation
            if let responseID { value["requestID"] = responseID }
            return value
        }
        guard let runtime else {
            return failure(C02MCPSetupFailure.Code.serviceLaneUnavailable.rawValue,
                           "The MCP setup domain is not installed for this runtime generation.",
                           retryable: true, operation: operation)
        }
        guard runtime.isLive() else {
            return failure(C02MCPSetupFailure.Code.liveEpochChanged.rawValue,
                           "The native runtime generation changed.",
                           retryable: true, operation: operation)
        }

        switch operation {
        case "handshake", "floe.mcpsetup.capabilities", "mcp.setup.capabilities":
            return awaitResult(operation: operation, requestID: requestID, seconds: 15) {
                let options = try await runtime.center.options()
                return success([
                    "channel": C02MCPSetupWire.version,
                    "epoch": runtime.epoch,
                    "templateBundled": runtime.templateAssetAvailable,
                    "templateID": C02MCPSetupTemplateIdentity.templateID,
                    "templateVersion": C02MCPSetupTemplateIdentity.templateVersion,
                    "serviceLaneAvailable": options.serviceLaneAvailable,
                    "generationAvailable": options.generationAvailable,
                    "stdioLaneAvailable": runtime.stdioLaneAvailable,
                    "clientCompatibilityVersion": C02MCPSetupLimits.clientCompatibilityVersion,
                    "clientPlatform": C02MCPSetupLimits.clientPlatform,
                    "transports": transportInventory(stdioAvailable: runtime.stdioLaneAvailable),
                    "modelTools": C02MCPSetupWire.modelTools,
                    "maximumRequestBytes": C02MCPSetupWire.maximumRequestBytes,
                    "maximumResponseBytes": C02MCPSetupWire.maximumResponseBytes,
                    "templateChunkBytes": C02MCPSetupWire.templateChunkBytes,
                ])
            }
        case "mcp.setup.projects":
            return awaitResult(operation: operation, requestID: requestID, seconds: 20) {
                let options = try await runtime.center.options()
                return success(["projects": options.projects.map(projectJSON)])
            }
        case "mcp.setup.environments":
            guard let raw = boundedString(object["projectID"], 64),
                  let projectID = UUID(uuidString: raw) else {
                return failure("invalidRequest", "A project identity is required.", retryable: false, operation: operation)
            }
            return awaitResult(operation: operation, requestID: requestID, seconds: 20) {
                let options = try await runtime.center.options(projectID: projectID)
                return success(["environments": options.environments.map(environmentJSON)])
            }
        case "mcp.setup.validate":
            guard let draftObject = object["draft"] as? [String: Any],
                  let draft = draft(from: draftObject) else {
                return failure("invalidRequest", "The MCP setup draft is not valid.", retryable: false, operation: operation)
            }
            return success(["preflight": preflightJSON(
                C02MCPSetupPreflightLogic.evaluate(draft))])
        case "mcp.setup.records.create":
            guard let draftObject = object["draft"] as? [String: Any],
                  let draft = draft(from: draftObject) else {
                return failure("invalidRequest", "The MCP setup draft is not valid.", retryable: false, operation: operation)
            }
            return awaitResult(operation: operation, requestID: requestID, seconds: 20) {
                let record = try await runtime.center.create(draft)
                return success(["record": recordJSON(record)])
            }
        case "mcp.setup.template.chunk":
            guard let raw = boundedString(object["recordID"], 64),
                  let recordID = UUID(uuidString: raw),
                  let offset = exactInt(object["offset"]), offset >= 0,
                  let base64 = boundedString(object["data"], 64_000),
                  let data = Data(base64Encoded: base64),
                  data.count <= C02MCPSetupWire.templateChunkBytes,
                  let final = object["final"] as? Bool else {
                return failure("invalidRequest", "The template chunk is not valid.", retryable: false, operation: operation)
            }
            return awaitResult(operation: operation, requestID: requestID, seconds: 20) {
                let complete = try await runtime.center.stageTemplateChunk(
                    recordID: recordID, chunk: data, offset: offset, final: final)
                return success(["complete": complete])
            }
        case "mcp.setup.prepare":
            return awaitRecord(operation: operation, requestID: requestID,
                               object: object, runtime: runtime,
                               action: { try await $0.prepare(recordID: $1, expectedRevision: $2) })
        case "mcp.setup.build.start":
            return awaitRecord(operation: operation, requestID: requestID,
                               object: object, runtime: runtime,
                               action: { try await $0.startBuild(recordID: $1, expectedRevision: $2) })
        case "mcp.setup.build.poll":
            return awaitRecord(operation: operation, requestID: requestID,
                               object: object, runtime: runtime,
                               action: { try await $0.pollBuild(recordID: $1, expectedRevision: $2) })
        case "mcp.setup.build.cancel":
            return awaitRecord(operation: operation, requestID: requestID,
                               object: object, runtime: runtime,
                               action: { try await $0.cancelBuild(recordID: $1, expectedRevision: $2) })
        case "mcp.setup.service.start":
            return awaitRecord(operation: operation, requestID: requestID,
                               object: object, runtime: runtime,
                               action: { try await $0.startService(recordID: $1, expectedRevision: $2) })
        case "mcp.setup.verify":
            return awaitRecord(operation: operation, requestID: requestID,
                               object: object, runtime: runtime,
                               action: { try await $0.verify(recordID: $1, expectedRevision: $2) },
                               seconds: 50)
        case "mcp.setup.commit":
            return awaitRecord(operation: operation, requestID: requestID,
                               object: object, runtime: runtime,
                               action: { try await $0.commit(recordID: $1, expectedRevision: $2) },
                               seconds: 50)
        case "mcp.setup.stop", "mcp.setup.discard":
            guard let recordID = recordID(from: object),
                  let revision = exactInt(object["revision"]), revision >= 0 else {
                return failure("invalidRequest", "A record identity and revision are required.", retryable: false, operation: operation)
            }
            let discard = operation == "mcp.setup.discard"
            return awaitResult(operation: operation, requestID: requestID, seconds: 50) {
                let record = try await runtime.center.stop(
                    recordID: recordID,
                    expectedRevision: UInt64(revision),
                    discard: discard)
                var fields: [String: Any] = ["discarded": record == nil]
                if let record { fields["record"] = recordJSON(record) }
                return success(fields)
            }
        case "mcp.setup.records.list":
            return awaitResult(operation: operation, requestID: requestID, seconds: 15) {
                let records = try await runtime.center.list()
                return success(["records": records.map(recordJSON)])
            }
        case "mcp.setup.records.status":
            guard let recordID = recordID(from: object) else {
                return failure("invalidRequest", "A record identity is required.", retryable: false, operation: operation)
            }
            return awaitResult(operation: operation, requestID: requestID, seconds: 15) {
                let record = try await runtime.center.record(id: recordID)
                return success(["record": recordJSON(record)])
            }
        case "mcp.setup.stdio.capabilities":
            return success([
                "available": runtime.stdioLaneAvailable,
                "protocolRevisions": C02MCPStdioClient.supportedProtocolRevisions.sorted(),
                "pipeRequired": true,
                "ptyEchoAccepted": false,
                "originalMCPClientFactory": "OriginalMCPClientFactory(stdio: C02MCPSetupStdioClientFactory)",
                "transport": "stdioSeparatedPipe",
                "credentials": "notAccepted",
                "note": runtime.stdioLaneAvailable
                    ? "The original MCP factory has a separated stdio adapter and the C01 pipe is available."
                    : "The original MCP factory has a separated stdio adapter; the C01 pipe provider is not installed in this build.",
            ])
        default:
            return failure("unsupportedOperation", "The MCP setup operation is not supported.", retryable: false, operation: operation)
        }
    }

    // MARK: - Record operations

    private static func awaitRecord(
        operation: String,
        requestID: String?,
        object: [String: Any],
        runtime: C02MCPSetupBridgeRuntime,
        action: @escaping @Sendable (C02MCPSetupCenter, UUID, UInt64) async throws -> C02MCPSetupRecord,
        seconds: Double = 20
    ) -> [String: Any] {
        guard let recordID = recordID(from: object),
              let revision = exactInt(object["revision"]), revision >= 0 else {
            var value: [String: Any] = [
                "ok": false, "schema": C02MCPSetupWire.schema,
                "operation": operation, "code": "invalidRequest",
                "message": "A record identity and revision are required.",
                "retryable": false,
            ]
            if let requestID { value["requestID"] = requestID }
            return value
        }
        return awaitResult(operation: operation, requestID: requestID, seconds: seconds) {
            let record = try await action(runtime.center, recordID, UInt64(revision))
            return [
                "ok": true, "schema": C02MCPSetupWire.schema,
                "operation": operation, "record": recordJSON(record),
            ]
        }
    }

    // MARK: - Async bridge

    private static func awaitResult(
        operation: String,
        requestID: String?,
        seconds: Double = 15,
        _ work: @escaping @Sendable () async throws -> [String: Any]
    ) -> [String: Any] {
        let box = Box<[String: Any]>()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do { box.set(try await work()) }
            catch let failure as C02MCPSetupFailure {
                var value: [String: Any] = [
                    "ok": false,
                    "schema": C02MCPSetupWire.schema,
                    "operation": operation,
                    "code": failure.code.rawValue,
                    "message": failure.message,
                    "retryable": failure.retryable,
                ]
                if let requestID { value["requestID"] = requestID }
                box.set(value)
            } catch {
                var value: [String: Any] = [
                    "ok": false,
                    "schema": C02MCPSetupWire.schema,
                    "operation": operation,
                    "code": "internalError",
                    "message": "The MCP setup operation failed.",
                    "retryable": true,
                ]
                if let requestID { value["requestID"] = requestID }
                box.set(value)
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + seconds) == .timedOut {
            var value: [String: Any] = [
                "ok": false,
                "schema": C02MCPSetupWire.schema,
                "operation": operation,
                "code": "operationTimedOut",
                "message": "The MCP setup operation did not finish in time.",
                "retryable": true,
            ]
            if let requestID { value["requestID"] = requestID }
            return value
        }
        return box.get() ?? [
            "ok": false, "schema": C02MCPSetupWire.schema,
            "operation": operation, "code": "internalError",
            "message": "The MCP setup operation produced no result.",
            "retryable": true,
        ]
    }

    // MARK: - Bound decoding

    private static func recordID(from object: [String: Any]) -> UUID? {
        guard let raw = boundedString(object["recordID"], 64) else { return nil }
        return UUID(uuidString: raw)
    }

    private static func draft(from object: [String: Any]) -> C02MCPSetupDraft? {
        let mode = (object["mode"] as? String).flatMap(C02MCPSetupMode.init(rawValue:)) ?? .remoteHTTP
        let authentication = (object["authentication"] as? String)
            .flatMap(C02MCPSetupAuthentication.init(rawValue:)) ?? .none
        let displayName = boundedString(object["displayName"], 1_024) ?? ""
        let endpointText = boundedString(object["endpointText"], 4_096) ?? ""
        let header = boundedString(object["credentialHeaderName"], 256) ?? "Authorization"
        let projectID = (object["projectID"] as? String).flatMap(UUID.init(uuidString:))
        let environmentID = boundedString(object["environmentID"], 256)
        let portText = boundedString(object["portText"], 16) ?? "8080"
        let details = boundedString(object["details"], C02MCPSetupLimits.maximumDetailsBytes * 2) ?? ""
        guard displayName.utf8.count <= C02MCPSetupLimits.maximumDisplayNameBytes,
              endpointText.utf8.count <= C02MCPSetupLimits.maximumEndpointBytes,
              details.utf8.count <= C02MCPSetupLimits.maximumDetailsBytes else {
            return nil
        }
        let timeout = (object["timeoutSeconds"] as? NSNumber)?.doubleValue ?? 30
        return C02MCPSetupDraft(
            mode: mode,
            displayName: displayName,
            endpointText: endpointText,
            authentication: authentication,
            credentialHeaderName: header,
            allowInsecureHTTP: (object["allowInsecureHTTP"] as? Bool) ?? false,
            allowInCanvas: (object["allowInCanvas"] as? Bool) ?? false,
            timeoutSeconds: timeout,
            projectID: projectID,
            environmentID: environmentID,
            portText: portText,
            details: details)
    }

    private static func projectJSON(_ project: C02MCPSetupProject) -> [String: Any] {
        [
            "id": project.id.uuidString,
            "name": String(project.name.prefix(256)),
            "revision": String(project.revision.prefix(256)),
        ]
    }

    private static func environmentJSON(_ environment: C02MCPSetupEnvironmentOption) -> [String: Any] {
        [
            "id": String(environment.id.prefix(256)),
            "label": String(environment.label.prefix(256)),
            "backend": String(environment.backend.prefix(64)),
            "containerID": String(environment.containerID.prefix(128)),
            "baseRevision": String(environment.baseRevision.prefix(256)),
            "layerFormat": environment.layerFormat,
        ]
    }

    private static func preflightJSON(_ preflight: C02MCPSetupPreflight) -> [String: Any] {
        var value: [String: Any] = [
            "valid": preflight.isValid,
            "mode": preflight.mode.rawValue,
            "displayName": String(preflight.displayName.prefix(256)),
            "authentication": preflight.authentication.rawValue,
            "allowInsecureHTTP": preflight.allowInsecureHTTP,
            "allowInCanvas": preflight.allowInCanvas,
            "timeoutSeconds": preflight.timeoutSeconds,
            "findings": preflight.findings.map(\.rawValue),
        ]
        if let endpoint = preflight.endpoint { value["endpoint"] = String(endpoint.absoluteString.prefix(2_048)) }
        if let projectID = preflight.projectID { value["projectID"] = projectID.uuidString }
        if let environmentID = preflight.environmentID { value["environmentID"] = String(environmentID.prefix(256)) }
        if let port = preflight.port { value["port"] = port }
        return value
    }

    private static func recordJSON(_ record: C02MCPSetupRecord) -> [String: Any] {
        var value: [String: Any] = [
            "id": record.id.uuidString,
            "revision": record.revision,
            "phase": record.phase.rawValue,
            "busy": record.phase.isBusy,
            "displayName": String(record.draft.displayName.prefix(256)),
            "projectID": record.projectID.uuidString,
            "projectName": String(record.projectName.prefix(256)),
            "environmentID": String(record.environmentID.prefix(256)),
            "environmentLabel": String(record.environmentLabel.prefix(256)),
            "containerID": String(record.containerID.prefix(128)),
            "baseRevision": String(record.baseRevision.prefix(256)),
            "allowInCanvas": record.draft.allowInCanvas,
            "port": Int(record.draft.portText) ?? 0,
            "createdAt": iso(record.createdAt),
            "updatedAt": iso(record.updatedAt),
            "steps": record.steps.map { step -> [String: Any] in
                var row: [String: Any] = [
                    "name": step.name.rawValue,
                    "state": step.state.rawValue,
                    "callID": String(step.callID.prefix(128)),
                ]
                if let jobID = step.jobID { row["jobID"] = jobID.uuidString }
                if let exit = step.exitCode { row["exitCode"] = exit }
                if let digest = step.outputDigest { row["outputDigest"] = String(digest.prefix(64)) }
                if let bytes = step.outputBytes { row["outputBytes"] = bytes }
                if let code = step.errorCode { row["errorCode"] = String(code.prefix(128)) }
                return row
            },
        ]
        if let workspace = record.workspaceRelativePath {
            value["workspaceRelativePath"] = String(workspace.prefix(C02MCPSetupLimits.maximumWorkspaceRelativePathBytes))
        }
        if let endpoint = record.serviceEndpoint {
            value["serviceEndpoint"] = String(endpoint.prefix(2_048))
        }
        if let code = record.errorCode { value["errorCode"] = String(code.prefix(128)) }
        if let message = record.errorMessage { value["errorMessage"] = String(message.prefix(512)) }
        if let receipt = record.receipt {
            var row: [String: Any] = [
                "recordID": receipt.recordID.uuidString,
                "projectID": receipt.projectID.uuidString,
                "environmentID": String(receipt.environmentID.prefix(256)),
                "containerID": String(receipt.containerID.prefix(128)),
                "baseRevision": String(receipt.baseRevision.prefix(256)),
                "rootIdentity": String(receipt.rootIdentity.prefix(64)),
                "endpoint": String(receipt.endpoint.prefix(2_048)),
                "smokeDigest": String(receipt.smokeDigest.prefix(64)),
                "verifiedTools": receipt.verifiedTools.map { String($0.prefix(128)) },
                "verifiedAt": iso(receipt.verifiedAt),
            ]
            if let serverID = receipt.serverID { row["serverID"] = serverID.uuidString }
            if let revision = receipt.newRevision { row["newRevision"] = String(revision.prefix(256)) }
            value["receipt"] = row
        }
        return value
    }

    private static func transportInventory(stdioAvailable: Bool) -> [[String: Any]] {
        [
            ["kind": "streamableHTTP", "available": true, "note": "Original remote client (current stateless and previous session revisions)."],
            ["kind": "httpSSE", "available": true, "note": "Bounded SSE response parsing inside the original Streamable HTTP client."],
            ["kind": "linuxStdio", "available": stdioAvailable, "note": stdioAvailable
                ? "Linux-owned separated pipe; the original MCP factory selects the C02 adapter."
                : "The original MCP factory has the adapter; the C01 pipe provider is not installed in this build."],
        ]
    }

    private static func exactInt(_ value: Any?) -> Int? {
        switch value {
        case let int as Int: return int
        case let number as NSNumber:
            let double = number.doubleValue
            guard double.isFinite, double.rounded() == double,
                  double >= Double(Int.min), double <= Double(Int.max) else { return nil }
            return Int(double)
        default: return nil
        }
    }

    private static func boundedString(_ value: Any?, _ maximum: Int) -> String? {
        guard let string = value as? String, !string.isEmpty,
              string.utf8.count <= maximum else { return nil }
        return string
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
