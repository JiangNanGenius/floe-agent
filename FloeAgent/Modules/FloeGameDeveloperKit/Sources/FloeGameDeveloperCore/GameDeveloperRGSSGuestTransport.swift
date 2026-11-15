// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation
import FloeGameCore

/// Host side of the bounded RGSS file RPC. It uses the host's existing guest
/// file service only; it never starts a shell, Ruby interpreter or VM.
@MainActor
public final class GameDeveloperRGSSGuestTransport: GameDeveloperTransport {
    public let binding: GameDeveloperSessionBinding
    public let directory: GameDeveloperGuestDirectory
    public let port: any GameDeveloperGuestFilePort

    private var probe: GameDeveloperRGSSProbe?
    private var logCache: [String] = []
    private var requestSequence: UInt64 = 0

    public init(binding: GameDeveloperSessionBinding,
                directory: GameDeveloperGuestDirectory,
                port: any GameDeveloperGuestFilePort) throws {
        guard [.rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce].contains(binding.engine) else {
            throw GameDeveloperError.unsupported("RGSS guest transport is not available for \(binding.engine.rawValue)")
        }
        self.binding = binding
        self.directory = directory
        self.port = port
    }

    public func attach() async throws -> GameDeveloperAttachReceipt {
        var lastError: Error?
        var decoded: GameDeveloperRGSSProbe?
        for _ in 0..<12 {
            do {
                let records = try await rpc(.probe, records: [], timeout: .milliseconds(900))
                decoded = try GameDeveloperRGSSProbe.decode(
                    records: records, expectedEngine: binding.engine)
                break
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        guard let decoded else {
            throw GameDeveloperError.bridgeUnavailable(
                "The RGSS overlay did not answer in \(directory.absolutePath): \(String(describing: lastError))")
        }
        guard decoded.overlayVersion.hasPrefix("1.") else {
            throw GameDeveloperError.bridgeUnavailable("unsupported RGSS overlay \(decoded.overlayVersion)")
        }
        probe = decoded
        return GameDeveloperAttachReceipt(
            binding: binding, bridgeToken: UUID(),
            protocolVersion: 1, runtime: decoded.runtime)
    }

    public func exchange(_ request: GameDeveloperTransportRequest) async throws -> GameDeveloperTransportResponse {
        let value: Data
        switch request.operation {
        case .probe:
            let probe = try await loadProbe()
            value = try JSONEncoder().encode(capabilities(probe))
        case .read:
            let probe = try await loadProbe()
            value = try encodeState(try await readState(probe: probe))
        case .write:
            value = try await write(request.payload)
        case .invoke:
            value = try await invoke(request.payload)
        case .snapshot:
            value = try await snapshot()
        case .restore:
            value = try await restore(request.payload)
        case .reset:
            value = try await reset(request.payload)
        case .diagnostics:
            value = try await diagnostics()
        case .detach:
            _ = try? await rpc(.detach, records: [], timeout: .milliseconds(300))
            value = Data("{}".utf8)
        }
        guard value.count <= 4 * 1_024 * 1_024 else {
            throw GameDeveloperError.payloadTooLarge("guest response")
        }
        return GameDeveloperTransportResponse(
            sessionID: request.sessionID, requestID: request.requestID,
            engine: binding.engine, value: value)
    }

    public func captureScreenshot() async throws -> Data {
        throw GameDeveloperError.unsupported(
            "RGSS guest screenshots are owned by the host display service, not this file bridge")
    }

    public func logs() -> [String] { logCache }

    public func detach() {
        probe = nil
        logCache.removeAll()
        Task { @MainActor [weak self] in
            _ = try? await self?.rpc(.detach, records: [], timeout: .milliseconds(200))
        }
    }

    // MARK: - Operations

    private func loadProbe() async throws -> GameDeveloperRGSSProbe {
        if let probe { return probe }
        let records = try await rpc(.probe, records: [], timeout: .seconds(2))
        let decoded = try GameDeveloperRGSSProbe.decode(records: records, expectedEngine: binding.engine)
        probe = decoded
        return decoded
    }

    private func capabilities(_ probe: GameDeveloperRGSSProbe) throws -> GameDeveloperCapabilities {
        .init(
            protocolVersion: 1,
            bridgeVersion: "rgss-file-\(probe.overlayVersion)",
            engine: binding.engine,
            runtime: probe.runtime,
            supports: GameDeveloperRGSSSchema.supports(probe: probe),
            fields: GameDeveloperRGSSSchema.fields(engine: binding.engine, probe: probe),
            actions: GameDeveloperRGSSSchema.actions(engine: binding.engine, probe: probe),
            notices: GameDeveloperRGSSSchema.notices(),
            diagnostics: .init(
                webAssembly: false,
                details: ["transport": "rgss-file-rpc", "overlay": probe.overlayVersion]))
    }

    private func readState(probe: GameDeveloperRGSSProbe) async throws -> GameDeveloperRuntimeState {
        let records = try await rpc(.read, records: [], timeout: .seconds(2))
        appendLog(records)
        let values = GameDeveloperRGSSCodec.dictionary(records)
        var stateValues: [String: GameDeveloperValue] = [:]
        var errors: [String: String] = [:]
        for field in GameDeveloperRGSSSchema.fields(engine: binding.engine, probe: probe) {
            guard let record = values["field.\(field.id)"] else { continue }
            if let value = developerValue(record) {
                do {
                    try GameDeveloperWire.validate(value: value, against: field, limits: .default)
                    stateValues[field.id] = value
                } catch {
                    errors[field.id] = "The RGSS overlay returned a value outside the field bounds."
                }
            }
        }
        return .init(revision: max(values["@revision"]?.integerValue ?? 0, 0),
                     capturedAt: Date(), values: stateValues, fieldErrors: errors)
    }

    private func write(_ payload: Data) async throws -> Data {
        let object = try jsonObject(payload)
        guard let changes = object["changes"] as? [[String: Any]], !changes.isEmpty,
              changes.count <= 32 else {
            throw GameDeveloperError.invalidRequest("guest write changes")
        }
        var records: [GameDeveloperRGSSRecord] = [.init("changeCount", .integer(changes.count))]
        for (index, change) in changes.enumerated() {
            guard let id = change["id"] as? String,
                  let value = decodeValue(change["value"]) else {
                throw GameDeveloperError.invalidRequest("guest write change")
            }
            records.append(.init("change.\(index).id", .string(id)))
            records.append(contentsOf: encodeValue(value, key: "change.\(index).value"))
        }
        let response = try await rpc(.write, records: records, timeout: .seconds(2))
        appendLog(response)
        let probe = try await loadProbe()
        return try outcomeData(response, actionID: "fields.write", probe: probe)
    }

    private func invoke(_ payload: Data) async throws -> Data {
        let object = try jsonObject(payload)
        guard let actionID = object["id"] as? String,
              let arguments = object["arguments"] as? [String: Any] else {
            throw GameDeveloperError.invalidRequest("guest action")
        }
        var records: [GameDeveloperRGSSRecord] = [
            .init("actionID", .string(actionID)),
            .init("argCount", .integer(arguments.count))
        ]
        for (index, key) in arguments.keys.sorted().enumerated() {
            guard let value = decodeValue(arguments[key]) else {
                throw GameDeveloperError.invalidAction("guest action argument")
            }
            records.append(.init("arg.\(index).id", .string(key)))
            records.append(contentsOf: encodeValue(value, key: "arg.\(index).value"))
        }
        let response = try await rpc(.invoke, records: records, timeout: .seconds(3))
        appendLog(response)
        let probe = try await loadProbe()
        return try outcomeData(response, actionID: actionID, probe: probe)
    }

    private func outcomeData(_ records: [GameDeveloperRGSSRecord],
                             actionID: String,
                             probe: GameDeveloperRGSSProbe) throws -> Data {
        let values = GameDeveloperRGSSCodec.dictionary(records)
        guard let statusCode = values["@status"]?.integerValue else {
            throw GameDeveloperError.transport("RGSS overlay returned no status")
        }
        if let echoed = values["@actionID"]?.stringValue, echoed != actionID {
            throw GameDeveloperError.invalidRequest("RGSS action response id mismatch")
        }
        let status: GameDeveloperActionStatus
        switch statusCode {
        case 0: status = .applied
        case 1: status = .rejected
        case 2: status = .unsupported
        case 3: status = .reloading
        default: throw GameDeveloperError.transport("RGSS overlay returned status \(statusCode)")
        }
        let changed = records.compactMap { record -> String? in
            guard record.key.hasPrefix("changed."), let value = record.value.stringValue else { return nil }
            return value
        }
        let state = try stateFromRecords(records, probe: probe)
        let outcome = GameDeveloperActionOutcome(
            actionID: actionID, status: status,
            message: values["@message"]?.stringValue ?? "RGSS action completed.",
            messageZhHans: values["@messageZh"]?.stringValue,
            changedFieldIDs: changed, state: state)
        return try JSONEncoder().encode(outcome)
    }

    private func stateFromRecords(_ records: [GameDeveloperRGSSRecord],
                                  probe: GameDeveloperRGSSProbe) throws -> GameDeveloperRuntimeState {
        let values = GameDeveloperRGSSCodec.dictionary(records)
        var stateValues: [String: GameDeveloperValue] = [:]
        for field in GameDeveloperRGSSSchema.fields(engine: binding.engine, probe: probe) {
            guard let record = values["field.\(field.id)"],
                  let value = developerValue(record) else { continue }
            if (try? GameDeveloperWire.validate(value: value, against: field, limits: .default)) != nil {
                stateValues[field.id] = value
            }
        }
        return .init(revision: max(values["@revision"]?.integerValue ?? 0, 0),
                     capturedAt: Date(), values: stateValues)
    }

    private func snapshot() async throws -> Data {
        let records = try await rpc(.snapshot, records: [], timeout: .seconds(3))
        appendLog(records)
        guard let binary = GameDeveloperRGSSCodec.dictionary(records)["@snapshot"]?.binaryValue,
              !binary.isEmpty else {
            throw GameDeveloperError.snapshotUnavailable("RGSS overlay returned no snapshot")
        }
        guard binary.count <= 4 * 1_024 * 1_024 else {
            throw GameDeveloperError.payloadTooLarge("RGSS snapshot")
        }
        let envelope: [String: Any] = [
            "snapshot": [
                "format": "floe-developer-snapshot",
                "version": 1,
                "engine": binding.engine.rawValue,
                "capturedAt": Int(Date().timeIntervalSince1970 * 1_000),
                "state": ["data": binary.base64EncodedString()]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    private func restore(_ payload: Data) async throws -> Data {
        let object = try jsonObject(payload)
        guard let snapshot = object["snapshot"] as? [String: Any],
              let state = snapshot["state"] as? [String: Any],
              let encoded = state["data"] as? String,
              let binary = Data(base64Encoded: encoded),
              !binary.isEmpty, binary.count <= 4 * 1_024 * 1_024 else {
            throw GameDeveloperError.invalidRequest("RGSS snapshot payload")
        }
        let records = try await rpc(.restore,
            records: [.init("snapshot", .binary(binary))], timeout: .seconds(3))
        appendLog(records)
        let values = GameDeveloperRGSSCodec.dictionary(records)
        guard values["@status"]?.integerValue == 0 else {
            throw GameDeveloperError.snapshotUnavailable(
                values["@message"]?.stringValue ?? "RGSS overlay refused the restore")
        }
        let probe = try await loadProbe()
        let stateValue = try stateFromRecords(records, probe: probe)
        let encodedState = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(stateValue))
        let result: [String: Any] = ["restored": true, "state": encodedState]
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }

    private func reset(_ payload: Data) async throws -> Data {
        let object = try jsonObject(payload)
        let mode = (object["mode"] as? String) ?? "hook"
        let records = try await rpc(.reset, records: [.init("mode", .string(mode))],
                                    timeout: .seconds(3))
        appendLog(records)
        let values = GameDeveloperRGSSCodec.dictionary(records)
        guard values["@status"]?.integerValue == 0 else {
            throw GameDeveloperError.unsupported(
                values["@message"]?.stringValue ?? "RGSS reset is not available for this project")
        }
        let result: [String: Any] = [
            "status": "applied",
            "message": values["@message"]?.stringValue ?? "The RGSS game reset to its title scene.",
            "messageZhHans": values["@messageZh"]?.stringValue ?? "RGSS 游戏已返回标题场景。"
        ]
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }

    private func diagnostics() async throws -> Data {
        let records = try await rpc(.diagnostics, records: [], timeout: .seconds(1))
        appendLog(records)
        let values = GameDeveloperRGSSCodec.dictionary(records)
        let diagnostics = GameDeveloperDiagnostics(
            fps: values["@fps"]?.numberValue,
            frames: values["@frames"]?.integerValue,
            canvases: 1,
            webAssembly: false,
            details: [
                "map": values["@mapID"]?.stringValue ?? String(values["@mapID"]?.integerValue ?? 0),
                "playtime": values["@playtime"]?.stringValue ?? "",
                "transport": "rgss-file-rpc"
            ])
        return try JSONEncoder().encode(diagnostics)
    }

    private func rpc(_ operation: GameDeveloperRGSSOperation,
                     records: [GameDeveloperRGSSRecord],
                     timeout: Duration) async throws -> [GameDeveloperRGSSRecord] {
        requestSequence &+= 1
        let requestID = UUID()
        let requestData: Data
        do {
            requestData = try GameDeveloperRGSSCodec.encodeRequest(
                operation: operation, requestID: requestID, records: records)
        } catch let error as GameDeveloperError {
            throw error
        } catch {
            throw GameDeveloperError.invalidRequest("guest request encoding")
        }
        let requestPath = "\(directory.requestsRelativeDirectory)/\(requestID.uuidString.lowercased()).req"
        let responsePath = "\(directory.responsesRelativeDirectory)/\(requestID.uuidString.lowercased()).res"
        do {
            try await port.writeFile(requestData, relativePath: requestPath, directory: directory)
        } catch {
            throw GameDeveloperError.transport("guest request write: \(String(describing: error))")
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            do {
                if let response = try await port.readFile(
                    relativePath: responsePath, directory: directory,
                    maximumBytes: 4 * 1_024 * 1_024) {
                    _ = try? await port.removeFile(relativePath: responsePath, directory: directory)
                    _ = try? await port.removeFile(relativePath: requestPath, directory: directory)
                    return try GameDeveloperRGSSCodec.decodeResponse(response, expectedRequestID: requestID)
                }
            } catch let error as GameDeveloperError {
                throw error
            } catch {
                throw GameDeveloperError.transport("guest response read: \(String(describing: error))")
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        _ = try? await port.removeFile(relativePath: requestPath, directory: directory)
        throw GameDeveloperError.transport("RGSS overlay did not answer \(operation)")
    }

    // MARK: - Values

    private func developerValue(_ value: GameDeveloperRGSSRecordValue) -> GameDeveloperValue? {
        switch value {
        case .string(let text): return .text(text)
        case .integer(let number): return .integer(number)
        case .number(let number): return .number(number)
        case .boolean(let flag): return .boolean(flag)
        case .null, .binary: return nil
        }
    }

    private func decodeValue(_ any: Any?) -> GameDeveloperValue? {
        if let text = any as? String { return .text(text) }
        if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            let double = number.doubleValue
            if double.rounded() == double, double >= Double(Int.min), double <= Double(Int.max) {
                return .integer(Int(double))
            }
            return .number(double)
        }
        return nil
    }

    private func encodeValue(_ value: GameDeveloperValue,
                             key: String) -> [GameDeveloperRGSSRecord] {
        switch value {
        case .boolean(let flag): return [.init(key, .boolean(flag))]
        case .integer(let number): return [.init(key, .integer(number))]
        case .number(let number): return [.init(key, .number(number))]
        case .text(let text): return [.init(key, .string(text))]
        }
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GameDeveloperError.invalidRequest("JSON object")
        }
        return object
    }

    private func encodeState(_ state: GameDeveloperRuntimeState) throws -> Data {
        try JSONEncoder().encode(state)
    }

    private func appendLog(_ records: [GameDeveloperRGSSRecord]) {
        guard let log = GameDeveloperRGSSCodec.dictionary(records)["@log"]?.stringValue,
              !log.isEmpty else { return }
        logCache.append(String(log.prefix(2_048)))
        if logCache.count > 200 { logCache.removeFirst(logCache.count - 200) }
    }
}
