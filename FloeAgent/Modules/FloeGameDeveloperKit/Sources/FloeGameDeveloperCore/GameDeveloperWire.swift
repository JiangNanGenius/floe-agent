// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation
import FloeGameCore

/// Strict, duplicate-key and bounds aware codec for the narrow page bridge.
/// Nothing here evaluates page text: only typed JSON crosses the boundary.
public enum GameDeveloperWire {
    public static let protocolVersion = 1
    public static let bridgeVersion = "1.0.0"

    private static let reservedIdentifiers: Set<String> = [
        "__proto__", "prototype", "constructor", "toString", "valueOf",
        "hasOwnProperty", "isPrototypeOf", "propertyIsEnumerable", "__defineGetter__",
        "__defineSetter__", "__lookupGetter__", "__lookupSetter__",
    ]

    public static func validIdentifier(_ id: String, maximumBytes: Int = 128) -> Bool {
        guard !id.isEmpty, id.utf8.count <= maximumBytes,
              !reservedIdentifiers.contains(id) else { return false }
        let scalars = Array(id.unicodeScalars)
        guard let first = scalars.first,
              ("a"..."z").contains(Character(first)) else { return false }
        var previousSeparator = false
        for index in scalars.indices {
            let scalar = scalars[index]
            let character = Character(scalar)
            if ("a"..."z").contains(character) || ("A"..."Z").contains(character) ||
                ("0"..."9").contains(character) {
                previousSeparator = false
            } else if character == "." || character == "_" || character == "-" {
                guard !previousSeparator, index != scalars.count - 1 else { return false }
                previousSeparator = true
            } else {
                return false
            }
        }
        return true
    }


    public static func validOptionValue(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128,
              !reservedIdentifiers.contains(value) else { return false }
        let scalars = Array(value.unicodeScalars)
        guard let first = scalars.first,
              ("a"..."z").contains(Character(first)) ||
                ("A"..."Z").contains(Character(first)) ||
                ("0"..."9").contains(Character(first)) else { return false }
        return scalars.allSatisfy { scalar in
            let character = Character(scalar)
            return ("a"..."z").contains(character) || ("A"..."Z").contains(character) ||
                ("0"..."9").contains(character) || character == "." || character == "_" ||
                character == "-" || character == ":" || character == "@"
        }
    }

    public static func validate(text: String, limit: Int, field: String) throws {
        guard text.utf8.count <= limit,
              !text.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) &&
                  $0 != Unicode.Scalar("\n") && $0 != Unicode.Scalar("\t")
              }) else {
            throw GameDeveloperError.invalidRequest("\(field) exceeds its bound")
        }
    }

    public static func validate(value: GameDeveloperValue,
                                against field: GameDeveloperFieldDescriptor,
                                limits: GameDeveloperLimits) throws {
        switch field.kind {
        case .boolean, .readOnlyBoolean:
            guard case .boolean = value else {
                throw GameDeveloperError.invalidField("\(field.id) expects a boolean")
            }
        case .integer:
            guard let number = value.numberValue, number.isFinite,
                  number.rounded() == number,
                  abs(number) <= limits.maximumValueMagnitude else {
                throw GameDeveloperError.invalidField("\(field.id) expects an integer (got \(value.displayText))")
            }
            if let minimum = field.minimum, number < minimum {
                throw GameDeveloperError.invalidField("\(field.id) is below its minimum")
            }
            if let maximum = field.maximum, number > maximum {
                throw GameDeveloperError.invalidField("\(field.id) is above its maximum")
            }
        case .number, .readOnlyNumber:
            guard let number = value.numberValue, number.isFinite,
                  abs(number) <= limits.maximumValueMagnitude else {
                throw GameDeveloperError.invalidField("\(field.id) expects a finite number (got \(value.displayText))")
            }
            if let minimum = field.minimum, number < minimum {
                throw GameDeveloperError.invalidField("\(field.id) is below its minimum")
            }
            if let maximum = field.maximum, number > maximum {
                throw GameDeveloperError.invalidField("\(field.id) is above its maximum")
            }
        case .text, .readOnlyText:
            guard let text = value.textValue else {
                throw GameDeveloperError.invalidField("\(field.id) expects text")
            }
            try validate(text: text,
                         limit: min(field.maximumLength ?? limits.maximumStringBytes,
                                    limits.maximumStringBytes),
                         field: field.id)
        case .choice:
            guard let text = value.textValue,
                  field.options.contains(where: { $0.value == text }) else {
                throw GameDeveloperError.invalidField("\(field.id) expects a listed choice")
            }
        }
    }

    public static func validate(value: GameDeveloperValue,
                                against parameter: GameDeveloperActionParameterDescriptor,
                                limits: GameDeveloperLimits) throws {
        switch parameter.kind {
        case .boolean:
            guard case .boolean = value else {
                throw GameDeveloperError.invalidAction("\(parameter.id) expects a boolean")
            }
        case .integer:
            guard let number = value.numberValue, number.isFinite, number.rounded() == number,
                  abs(number) <= limits.maximumValueMagnitude else {
                throw GameDeveloperError.invalidAction("\(parameter.id) expects an integer")
            }
            if let minimum = parameter.minimum, number < minimum {
                throw GameDeveloperError.invalidAction("\(parameter.id) is below its minimum")
            }
            if let maximum = parameter.maximum, number > maximum {
                throw GameDeveloperError.invalidAction("\(parameter.id) is above its maximum")
            }
        case .number:
            guard let number = value.numberValue, number.isFinite,
                  abs(number) <= limits.maximumValueMagnitude else {
                throw GameDeveloperError.invalidAction("\(parameter.id) expects a number")
            }
            if let minimum = parameter.minimum, number < minimum {
                throw GameDeveloperError.invalidAction("\(parameter.id) is below its minimum")
            }
            if let maximum = parameter.maximum, number > maximum {
                throw GameDeveloperError.invalidAction("\(parameter.id) is above its maximum")
            }
        case .text:
            guard let text = value.textValue else {
                throw GameDeveloperError.invalidAction("\(parameter.id) expects text")
            }
            try validate(text: text,
                         limit: min(parameter.maximumLength ?? limits.maximumStringBytes,
                                    limits.maximumStringBytes),
                         field: parameter.id)
        case .choice:
            guard let text = value.textValue,
                  parameter.options.contains(where: { $0.value == text }) else {
                throw GameDeveloperError.invalidAction("\(parameter.id) expects a listed choice")
            }
        case .readOnlyText, .readOnlyNumber, .readOnlyBoolean:
            throw GameDeveloperError.invalidAction("\(parameter.id) is not an input")
        }
    }

    // MARK: - Decode

    public static func decodeCapabilities(_ data: Data, expectedEngine: GameEngineID,
                                          limits: GameDeveloperLimits) throws -> GameDeveloperCapabilities {
        guard data.count <= limits.maximumResponseBytes else {
            throw GameDeveloperError.payloadTooLarge("capabilities response")
        }
        let capabilities: GameDeveloperCapabilities
        do {
            capabilities = try JSONDecoder().decode(GameDeveloperCapabilities.self, from: data)
        } catch {
            throw GameDeveloperError.invalidRequest("capabilities JSON: \(error)")
        }
        guard capabilities.protocolVersion == protocolVersion else {
            throw GameDeveloperError.bridgeUnavailable("unsupported bridge protocol \(capabilities.protocolVersion)")
        }
        guard capabilities.engine == expectedEngine else {
            throw GameDeveloperError.contextMismatch("engine \(capabilities.engine.rawValue) != \(expectedEngine.rawValue)")
        }
        try validate(text: capabilities.bridgeVersion, limit: 64, field: "bridgeVersion")
        try validate(text: capabilities.runtime, limit: 256, field: "runtime")
        guard capabilities.fields.count <= limits.maximumFields,
              capabilities.actions.count <= limits.maximumActions,
              capabilities.notices.count <= limits.maximumNotices else {
            throw GameDeveloperError.payloadTooLarge("capabilities count")
        }

        var fieldIDs = Set<String>()
        for field in capabilities.fields {
            guard validIdentifier(field.id), fieldIDs.insert(field.id).inserted else {
                throw GameDeveloperError.invalidRequest("duplicate/invalid field id \(field.id)")
            }
            try validate(text: field.label, limit: limits.maximumLabelBytes, field: "field label")
            try validate(text: field.labelZhHans, limit: limits.maximumLabelBytes, field: "field label")
            try validate(text: field.group, limit: limits.maximumLabelBytes, field: "field group")
            try validate(text: field.groupZhHans, limit: limits.maximumLabelBytes, field: "field group")
            if let detail = field.detail { try validate(text: detail, limit: limits.maximumDetailBytes, field: "field detail") }
            if let detail = field.detailZhHans { try validate(text: detail, limit: limits.maximumDetailBytes, field: "field detail") }
            if field.options.count > limits.maximumChoices {
                throw GameDeveloperError.payloadTooLarge("field options \(field.id)")
            }
            var optionValues = Set<String>()
            for option in field.options {
                guard validOptionValue(option.value), optionValues.insert(option.value).inserted else {
                    throw GameDeveloperError.invalidRequest("field option \(field.id)")
                }
                try validate(text: option.label, limit: limits.maximumLabelBytes, field: "option label")
                try validate(text: option.labelZhHans, limit: limits.maximumLabelBytes, field: "option label")
            }
            if let minimum = field.minimum, !minimum.isFinite { throw GameDeveloperError.invalidRequest("field minimum") }
            if let maximum = field.maximum, !maximum.isFinite { throw GameDeveloperError.invalidRequest("field maximum") }
            if let minimum = field.minimum, let maximum = field.maximum, minimum > maximum {
                throw GameDeveloperError.invalidRequest("field range \(field.id)")
            }
            if let step = field.step, (!step.isFinite || step <= 0) {
                throw GameDeveloperError.invalidRequest("field step \(field.id)")
            }
            if let length = field.maximumLength, !(1...limits.maximumStringBytes).contains(length) {
                throw GameDeveloperError.invalidRequest("field length \(field.id)")
            }
            if field.kind.isReadOnly != field.isReadOnly {
                throw GameDeveloperError.invalidRequest("field read-only flag \(field.id)")
            }
            if field.kind == .choice && field.options.isEmpty {
                throw GameDeveloperError.invalidRequest("choice field without options \(field.id)")
            }
        }

        var actionIDs = Set<String>()
        for action in capabilities.actions {
            guard validIdentifier(action.id), actionIDs.insert(action.id).inserted else {
                throw GameDeveloperError.invalidRequest("duplicate/invalid action id \(action.id)")
            }
            try validate(text: action.label, limit: limits.maximumLabelBytes, field: "action label")
            try validate(text: action.labelZhHans, limit: limits.maximumLabelBytes, field: "action label")
            try validate(text: action.group, limit: limits.maximumLabelBytes, field: "action group")
            try validate(text: action.groupZhHans, limit: limits.maximumLabelBytes, field: "action group")
            if let detail = action.detail { try validate(text: detail, limit: limits.maximumDetailBytes, field: "action detail") }
            if let detail = action.detailZhHans { try validate(text: detail, limit: limits.maximumDetailBytes, field: "action detail") }
            guard action.parameters.count <= limits.maximumActionParameters else {
                throw GameDeveloperError.payloadTooLarge("action parameters \(action.id)")
            }
            var parameterIDs = Set<String>()
            for parameter in action.parameters {
                guard validIdentifier(parameter.id), parameterIDs.insert(parameter.id).inserted else {
                    throw GameDeveloperError.invalidRequest("duplicate parameter \(action.id)/\(parameter.id)")
                }
                try validate(text: parameter.label, limit: limits.maximumLabelBytes, field: "parameter label")
                try validate(text: parameter.labelZhHans, limit: limits.maximumLabelBytes, field: "parameter label")
                if let detail = parameter.detail { try validate(text: detail, limit: limits.maximumDetailBytes, field: "parameter detail") }
                if let detail = parameter.detailZhHans { try validate(text: detail, limit: limits.maximumDetailBytes, field: "parameter detail") }
                if parameter.options.count > limits.maximumChoices {
                    throw GameDeveloperError.payloadTooLarge("parameter options \(parameter.id)")
                }
                var optionValues = Set<String>()
                for option in parameter.options {
                    guard validOptionValue(option.value), optionValues.insert(option.value).inserted else {
                        throw GameDeveloperError.invalidRequest("parameter option \(parameter.id)")
                    }
                }
                if let minimum = parameter.minimum, !minimum.isFinite { throw GameDeveloperError.invalidRequest("parameter minimum") }
                if let maximum = parameter.maximum, !maximum.isFinite { throw GameDeveloperError.invalidRequest("parameter maximum") }
                if let minimum = parameter.minimum, let maximum = parameter.maximum, minimum > maximum {
                    throw GameDeveloperError.invalidRequest("parameter range \(parameter.id)")
                }
                if parameter.kind == .choice && parameter.options.isEmpty {
                    throw GameDeveloperError.invalidRequest("choice parameter without options")
                }
                if let defaultValue = parameter.defaultValue {
                    try validate(value: defaultValue, against: parameter, limits: limits)
                }
            }
        }

        for notice in capabilities.notices {
            guard validIdentifier(notice.code) else { throw GameDeveloperError.invalidRequest("notice code") }
            try validate(text: notice.message, limit: limits.maximumDetailBytes, field: "notice message")
            try validate(text: notice.messageZhHans, limit: limits.maximumDetailBytes, field: "notice message")
        }
        if capabilities.diagnostics.details.count > 64 {
            throw GameDeveloperError.payloadTooLarge("diagnostics details")
        }
        for (key, value) in capabilities.diagnostics.details {
            guard !key.isEmpty, key.utf8.count <= 128 else { throw GameDeveloperError.invalidRequest("diagnostics key") }
            try validate(text: value, limit: limits.maximumDetailBytes, field: "diagnostics value")
        }
        return capabilities
    }

    public static func decodeState(_ data: Data, capabilities: GameDeveloperCapabilities,
                                   limits: GameDeveloperLimits) throws -> GameDeveloperRuntimeState {
        guard data.count <= limits.maximumResponseBytes else {
            throw GameDeveloperError.payloadTooLarge("state response")
        }
        let state: GameDeveloperRuntimeState
        do { state = try JSONDecoder().decode(GameDeveloperRuntimeState.self, from: data) }
        catch { throw GameDeveloperError.invalidRequest("state JSON: \(error)") }
        guard state.revision >= 0, state.values.count <= capabilities.fields.count,
              state.fieldErrors.count <= capabilities.fields.count else {
            throw GameDeveloperError.invalidRequest("state bounds")
        }
        let fields = Dictionary(uniqueKeysWithValues: capabilities.fields.map { ($0.id, $0) })
        for (id, value) in state.values {
            guard let field = fields[id] else {
                throw GameDeveloperError.invalidRequest("state contains unknown field \(id)")
            }
            try validate(value: value, against: field, limits: limits)
        }
        for (id, message) in state.fieldErrors {
            guard fields[id] != nil else {
                throw GameDeveloperError.invalidRequest("state error contains unknown field \(id)")
            }
            try validate(text: message, limit: limits.maximumDetailBytes, field: "field error")
        }
        return state
    }

    public static func decodeOutcome(_ data: Data, expectedActionID: String,
                                     capabilities: GameDeveloperCapabilities,
                                     limits: GameDeveloperLimits) throws -> GameDeveloperActionOutcome {
        guard data.count <= limits.maximumResponseBytes else {
            throw GameDeveloperError.payloadTooLarge("action response")
        }
        let outcome: GameDeveloperActionOutcome
        do { outcome = try JSONDecoder().decode(GameDeveloperActionOutcome.self, from: data) }
        catch { throw GameDeveloperError.invalidRequest("action JSON: \(error)") }
        guard outcome.actionID == expectedActionID else {
            throw GameDeveloperError.invalidRequest("action response id mismatch")
        }
        let fieldIDs = Set(capabilities.fields.map(\.id))
        guard outcome.changedFieldIDs.count <= capabilities.fields.count,
              outcome.changedFieldIDs.allSatisfy({ fieldIDs.contains($0) }) else {
            throw GameDeveloperError.invalidRequest("action changed field list")
        }
        try validate(text: outcome.message, limit: limits.maximumDetailBytes, field: "action message")
        try validate(text: outcome.messageZhHans, limit: limits.maximumDetailBytes, field: "action message")
        if let state = outcome.state {
            _ = try decodeState(try JSONEncoder().encode(state), capabilities: capabilities, limits: limits)
        }
        return outcome
    }

    /// Snapshot envelope: `{snapshot: <object>, bytes: <int>}`. The exact nested
    /// object is preserved for engine restore; only bounded metadata is checked.
    public static func decodeSnapshot(_ data: Data, expectedEngine: GameEngineID,
                                      limits: GameDeveloperLimits) throws -> Data {
        guard data.count <= limits.maximumResponseBytes else {
            throw GameDeveloperError.payloadTooLarge("snapshot response")
        }
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) }
        catch { throw GameDeveloperError.invalidRequest("snapshot JSON") }
        guard let object = root as? [String: Any],
              let snapshot = object["snapshot"] as? [String: Any] else {
            throw GameDeveloperError.snapshotUnavailable("bridge did not return a snapshot object")
        }
        let bytes = try JSONSerialization.data(withJSONObject: snapshot,
            options: [.sortedKeys, .withoutEscapingSlashes])
        guard bytes.count <= limits.maximumSnapshotBytes else {
            throw GameDeveloperError.payloadTooLarge("snapshot \(bytes.count) bytes")
        }
        guard let format = snapshot["format"] as? String, format == "floe-developer-snapshot",
              let version = snapshot["version"] as? Int, version == protocolVersion,
              let engine = snapshot["engine"] as? String, engine == expectedEngine.rawValue else {
            throw GameDeveloperError.invalidRequest("snapshot envelope metadata")
        }
        return bytes
    }

    public static func validateSnapshot(_ data: Data, expectedEngine: GameEngineID,
                                        limits: GameDeveloperLimits) throws {
        guard data.count <= limits.maximumSnapshotBytes else {
            throw GameDeveloperError.payloadTooLarge("snapshot")
        }
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) }
        catch { throw GameDeveloperError.invalidRequest("snapshot JSON") }
        guard let object = root as? [String: Any],
              object["format"] as? String == "floe-developer-snapshot",
              object["version"] as? Int == protocolVersion,
              object["engine"] as? String == expectedEngine.rawValue,
              object["state"] != nil else {
            throw GameDeveloperError.invalidRequest("snapshot envelope")
        }
    }

    // MARK: - Encode

    private struct WireChange: Encodable { let id: String; let value: GameDeveloperValue }
    private struct WritePayload: Encodable { let changes: [WireChange] }
    private struct InvokePayload: Encodable { let id: String; let arguments: [String: GameDeveloperValue] }
    private struct ResetPayload: Encodable { let mode: String }
    private struct RestorePayload: Encodable { let snapshot: AnyEncodable }

    public static func encodeChanges(_ changes: [GameDeveloperFieldChange],
                                     limits: GameDeveloperLimits) throws -> Data {
        guard !changes.isEmpty, changes.count <= limits.maximumChangesPerRequest else {
            throw GameDeveloperError.invalidRequest("change count")
        }
        let data = try JSONEncoder().encode(WritePayload(changes: changes.map {
            WireChange(id: $0.id, value: $0.value)
        }))
        guard data.count <= limits.maximumRequestBytes else {
            throw GameDeveloperError.payloadTooLarge("write request")
        }
        return data
    }

    public static func encodeInvoke(actionID: String,
                                    arguments: [String: GameDeveloperValue],
                                    limits: GameDeveloperLimits) throws -> Data {
        guard validIdentifier(actionID), arguments.count <= limits.maximumActionParameters else {
            throw GameDeveloperError.invalidAction(actionID)
        }
        let data = try JSONEncoder().encode(InvokePayload(id: actionID, arguments: arguments))
        guard data.count <= limits.maximumRequestBytes else {
            throw GameDeveloperError.payloadTooLarge("invoke request")
        }
        return data
    }

    public static func encodeRestore(snapshot: Data, expectedEngine: GameEngineID,
                                     limits: GameDeveloperLimits) throws -> Data {
        try validateSnapshot(snapshot, expectedEngine: expectedEngine, limits: limits)
        let object = try JSONSerialization.jsonObject(with: snapshot)
        let data = try JSONEncoder().encode(RestorePayload(snapshot: AnyEncodable(object)))
        guard data.count <= limits.maximumRequestBytes else {
            throw GameDeveloperError.payloadTooLarge("restore request")
        }
        return data
    }

    public static func encodeReset(mode: String, limits: GameDeveloperLimits) throws -> Data {
        guard mode == "reload" || mode == "restart" || mode == "hook" else {
            throw GameDeveloperError.invalidRequest("reset mode")
        }
        let data = try JSONEncoder().encode(ResetPayload(mode: mode))
        guard data.count <= limits.maximumRequestBytes else {
            throw GameDeveloperError.payloadTooLarge("reset request")
        }
        return data
    }

    public static func emptyPayload() -> Data { Data("{}".utf8) }
}

/// Small type-erased Encodable wrapper for a JSONSerialization value.
public struct AnyEncodable: Encodable {
    private let value: Any
    public init(_ value: Any) { self.value = value }
    public func encode(to encoder: any Encoder) throws {
        switch value {
        case is NSNull:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let number as NSNumber:
            // NSNumber bridges to Bool for 0/1; inspect the CoreFoundation
            // type so a numeric 1 is never silently encoded as true.
            var container = encoder.singleValueContainer()
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                try container.encode(number.boolValue)
            } else {
                let double = number.doubleValue
                if double.rounded() == double, double >= Double(Int.min), double <= Double(Int.max) {
                    try container.encode(Int(double))
                } else {
                    try container.encode(double)
                }
            }
        case let value as Bool:
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let value as Int:
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let value as Double:
            var container = encoder.singleValueContainer()
            if value.rounded() == value, value >= Double(Int.min), value <= Double(Int.max) {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case let value as String:
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let value as [Any]:
            var array = encoder.unkeyedContainer()
            for element in value { try array.encode(AnyEncodable(element)) }
        case let value as [String: Any]:
            var object = encoder.container(keyedBy: DynamicCodingKey.self)
            for key in value.keys.sorted() {
                try object.encode(AnyEncodable(value[key]!), forKey: DynamicCodingKey(key))
            }
        default:
            throw EncodingError.invalidValue(value, .init(
                codingPath: encoder.codingPath,
                debugDescription: "Unsupported JSON value in snapshot"))
        }
    }
}

public struct DynamicCodingKey: CodingKey {
    public let stringValue: String
    public let intValue: Int?
    public init(_ string: String) { stringValue = string; intValue = nil }
    public init?(stringValue: String) { self.init(stringValue) }
    public init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

public extension GameDeveloperWire {
    struct RestoreResult: Decodable {
        public let restored: Bool
        public let state: GameDeveloperRuntimeState?
    }

    struct ResetResult: Decodable {
        public let status: String
        public let message: String?
        public let messageZhHans: String?
    }

    static func decodeRestore(_ data: Data, capabilities: GameDeveloperCapabilities,
                              limits: GameDeveloperLimits) throws -> GameDeveloperRuntimeState? {
        guard data.count <= limits.maximumResponseBytes else {
            throw GameDeveloperError.payloadTooLarge("restore response")
        }
        let result: RestoreResult
        do { result = try JSONDecoder().decode(RestoreResult.self, from: data) }
        catch { throw GameDeveloperError.invalidRequest("restore JSON: \(error)") }
        guard result.restored else {
            throw GameDeveloperError.snapshotUnavailable("the engine refused the restore")
        }
        if let state = result.state {
            _ = try decodeState(try JSONEncoder().encode(state),
                                capabilities: capabilities, limits: limits)
        }
        return result.state
    }

    static func decodeReset(_ data: Data, limits: GameDeveloperLimits) throws -> ResetResult {
        guard data.count <= limits.maximumResponseBytes else {
            throw GameDeveloperError.payloadTooLarge("reset response")
        }
        let result: ResetResult
        do { result = try JSONDecoder().decode(ResetResult.self, from: data) }
        catch { throw GameDeveloperError.invalidRequest("reset JSON: \(error)") }
        guard result.status == "reloading" || result.status == "applied" else {
            throw GameDeveloperError.transport("unexpected reset status \(result.status)")
        }
        if let message = result.message { try validate(text: message, limit: limits.maximumDetailBytes, field: "reset message") }
        if let message = result.messageZhHans { try validate(text: message, limit: limits.maximumDetailBytes, field: "reset message") }
        return result
    }

    static func decodeDiagnostics(_ data: Data, limits: GameDeveloperLimits) throws -> GameDeveloperDiagnostics {
        guard data.count <= limits.maximumResponseBytes else {
            throw GameDeveloperError.payloadTooLarge("diagnostics response")
        }
        let diagnostics: GameDeveloperDiagnostics
        do { diagnostics = try JSONDecoder().decode(GameDeveloperDiagnostics.self, from: data) }
        catch { throw GameDeveloperError.invalidRequest("diagnostics JSON: \(error)") }
        guard diagnostics.details.count <= 64 else {
            throw GameDeveloperError.payloadTooLarge("diagnostics details")
        }
        for (key, value) in diagnostics.details {
            guard !key.isEmpty, key.utf8.count <= 128 else { throw GameDeveloperError.invalidRequest("diagnostics key") }
            try validate(text: value, limit: limits.maximumDetailBytes, field: "diagnostics value")
        }
        return diagnostics
    }
}
