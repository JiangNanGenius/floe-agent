// SPDX-License-Identifier: MPL-2.0
//
// G08 generic trusted App-platform tool bridge (Full-only seam).
//
// The shared Play core never contains phone/ADB/root tool names, schemas,
// implementations or assets. Instead the trusted Full App host hands ONE
// bounded catalog of descriptors to this bridge at bind time over a typed
// C ABI. Every descriptor is validated here against the ORIGINAL
// `ToolCatalog.Descriptor` metadata types before it can become a
// `ToolRunnerRegistry` runner, and every invocation is re-derived from the
// runtime-issued `ToolContext` (never from model JSON) by the mailbox in
// `PlatformToolHostMailbox.swift`.
//
// This file owns:
//   * the exact descriptor/catalog wire contract (closed key sets, bounds);
//   * a bounded JSON-Schema subset that is actually ENFORCED on arguments
//     (unsupported keywords are rejected at bind time, never silently
//     ignored);
//   * the bounded result contract (`summary` / `exitStatus` / `evidence` /
//     optional verified `ToolArtifactReference`).
//
// There is no fallback shell/interpreter and no model-facing route here.
import Foundation
import CoreFoundation
import FloeCore
import FloeModels
import FloeTools

// MARK: - Shared bounds

public enum PlatformToolHostLimits {
    /// Whole catalog JSON from the trusted host. 24 tools x 4 KiB schema plus
    /// bounded metadata stays comfortably below this.
    public static let maximumCatalogBytes = 128 * 1024
    public static let maximumTools = 24
    /// Same-epoch discoverability publish from the Full host: a bounded JSON
    /// array of catalog names actually usable right now.
    public static let maximumAvailabilityBytes = 16 * 1024
    public static let maximumNameCharacters = 80
    public static let maximumNameSegmentCharacters = 32
    public static let maximumDescriptionBytes = 4 * 1024
    public static let maximumSchemaBytes = 4 * 1024
    public static let maximumSchemaProperties = 32
    public static let maximumSchemaNodes = 256
    public static let maximumSchemaDepth = 4
    public static let maximumEnumValues = 16
    public static let maximumSchemaTextCharacters = 256
    public static let maximumTicketDescriptorBytes = 2 * 1024
    /// Same ceiling the runtime already applies to tool arguments.
    public static let maximumArgumentsBytes = toolArgumentsMaxBytes
    public static let maximumArgumentArrayItems = 256
    public static let maximumReplyBytes = 64 * 1024
    public static let maximumFailureReplyBytes = 512
    public static let maximumLiveTickets = 8
    public static let maximumRetired = 128
    public static let maximumCodeCharacters = 64
    public static let maximumDetailCharacters = 200
    public static let maximumOwnerTokenCharacters = 128
    /// Phone actions may include one real foreground operation; the mailbox
    /// adds scheduling/settlement margin and never detaches claimed IO.
    public static let ticketBudgetMillis = 30_000
    public static let maximumSummaryCharacters = 2_048
    public static let maximumEvidenceEntries = 8
    public static let maximumEvidenceCharacters = 192
    public static let maximumArtifactPathCharacters = 256
    public static let maximumScopeBytes = 512
    /// The ONLY app-storage namespace this bridge will publish as visual
    /// evidence. `VNCArtifacts` is the EXISTING remote-screen capture
    /// namespace in `ArtifactNamespace`, and `AgentRuntime.providerImageEvidence`
    /// already carries it to vision providers. The Full adapter commits the
    /// real PNG (`image/png`, `.png`) or JPEG (`image/jpeg`, `.jpg`/`.jpeg`)
    /// bytes there; no new artifact namespace, image format or transport is
    /// introduced.
    public static let artifactPathPrefix = "VNCArtifacts/"
}

/// Additive status space for this mailbox family. Generic claim codes match
/// the reviewed artifact/network mailbox ladder; `-109` is new and means a
/// success was refused because the owning call was already cancelled.
public enum PlatformToolHostStatus {
    public static let ok: Int32 = 0
    public static let staleClaim: Int32 = -101
    public static let generationFenced: Int32 = -102
    public static let shape: Int32 = -105
    public static let bufferTooSmall: Int32 = -106
    public static let oversized: Int32 = -107
    public static let descriptorInvalid: Int32 = -108
    public static let cancelled: Int32 = -109
    public static let notClaimed: Int32 = -110
}

// MARK: - Strict JSON primitives

private enum PlatformToolJSON {
    static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBoolean(number) else { return nil }
        return number.boolValue
    }

    static func strictInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double,
              double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return number.intValue
    }

    static func strictDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        let double = number.doubleValue
        guard double.isFinite else { return nil }
        return double
    }

    static func object(_ data: Data) -> [String: Any]? {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else { return nil }
        return object
    }

    static func isValidCode(_ code: String) -> Bool {
        guard !code.isEmpty, code.count <= PlatformToolHostLimits.maximumCodeCharacters,
              let first = code.first, first.isLetter else { return false }
        return code.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)
                || scalar == "_" || scalar == "-")
        }
    }

    static func boundedToken(_ value: String?) -> String {
        guard let value else { return "" }
        let cleaned = String(value.filter { character in
            character.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
        })
        return String(cleaned.prefix(PlatformToolHostLimits.maximumOwnerTokenCharacters))
    }

    static func hasControlCharacters(_ value: String, allowingNewlines: Bool) -> Bool {
        for scalar in value.unicodeScalars {
            if scalar == "\n" || scalar == "\t" {
                if allowingNewlines { continue }
                return true
            }
            if CharacterSet.controlCharacters.contains(scalar) { return true }
        }
        return false
    }
}

// MARK: - Catalog contract

public enum PlatformToolCatalogError: Error, Equatable {
    case malformed(String)
    case duplicateName(String)
    case nameInvalid(String)
    case nameCollision(String)
    case descriptionInvalid(String)
    case schemaInvalid(String)
    case riskInvalid(String)
    case riskUnsupported(String)
    case effectInvalid(String)
    case boundaryInvalid(String)
    case concurrentInvalid(String)
    case fieldInvalid(String)

    /// Stable, bounded diagnostic token for `stats`/`readiness`. Never
    /// carries model content or host paths.
    public var code: String {
        switch self {
        case .malformed(let field): return "malformed:\(field)"
        case .duplicateName: return "duplicateName"
        case .nameInvalid(let field): return "nameInvalid:\(field)"
        case .nameCollision: return "nameCollision"
        case .descriptionInvalid(let field): return "descriptionInvalid:\(field)"
        case .schemaInvalid(let field): return "schemaInvalid:\(field)"
        case .riskInvalid(let field): return "riskInvalid:\(field)"
        case .riskUnsupported(let field): return "riskUnsupported:\(field)"
        case .effectInvalid(let field): return "effectInvalid:\(field)"
        case .boundaryInvalid(let field): return "boundaryInvalid:\(field)"
        case .concurrentInvalid(let field): return "concurrentInvalid:\(field)"
        case .fieldInvalid(let field): return "fieldInvalid:\(field)"
        }
    }

    public var boundedDetail: String? {
        switch self {
        case .duplicateName(let name), .nameInvalid(let name),
             .nameCollision(let name):
            return String(name.prefix(PlatformToolHostLimits.maximumNameCharacters))
        default:
            return nil
        }
    }
}

public struct PlatformToolCatalogEntry: Sendable, Equatable {
    public let name: String
    public let description: String
    public let schemaJSON: String
    public let riskLabels: Set<RiskLabel>
    public let effect: ToolEffect
    public let isSideEffecting: Bool
    public let requiresHostScope: Bool
    public let executionBoundary: ToolExecutionBoundary
    public let supportsConcurrentBatchDispatch: Bool

    /// The canonical descriptor registered with the original runner registry.
    /// Every field comes from the validated trusted descriptor; nothing is
    /// defaulted silently.
    public var descriptor: ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            toolDescription: description,
            parametersJSON: schemaJSON,
            riskLabels: riskLabels,
            isSideEffecting: isSideEffecting,
            effect: effect,
            requiresHostScope: requiresHostScope,
            prerequisites: [],
            executionBoundary: executionBoundary,
            supportsConcurrentBatchDispatch: supportsConcurrentBatchDispatch
        )
    }
}

public struct PlatformToolCatalog: Sendable, Equatable {
    public let entries: [PlatformToolCatalogEntry]

    public init(entries: [PlatformToolCatalogEntry]) {
        self.entries = entries
    }

    public var names: [String] { entries.map(\.name) }

    public func entry(named name: String) -> PlatformToolCatalogEntry? {
        entries.first { $0.name == name }
    }
}

public enum PlatformToolCatalogParser {
    /// Runtime-issued ownership fields may never be re-opened as model
    /// arguments, even if a Full schema accidentally declares them. The host
    /// must use the trusted ticket descriptor for these values.
    private static let reservedArgumentKeys: Set<String> = [
        "taskID", "runID", "epoch", "toolCallID", "toolIdempotencyKey",
        "idempotencyKey", "clientSessionID", "approvalGrantID", "scope",
        "conversationID",
    ]

    /// Strict trusted-descriptor parser. The host is trusted, but a buggy or
    /// compromised Full host must not be able to widen the shared tool
    /// surface: unknown keys, unknown risks/effects, non-main-run or
    /// concurrent descriptors, invalid schemas, retired names and compiled
    /// catalog collisions are all rejected.
    public static func parse(_ data: Data) throws -> PlatformToolCatalog {
        guard data.count > 0,
              data.count <= PlatformToolHostLimits.maximumCatalogBytes
        else { throw PlatformToolCatalogError.malformed("catalogBytes") }
        guard let root = PlatformToolJSON.object(data) else {
            throw PlatformToolCatalogError.malformed("json")
        }
        try requireClosed(root, allowed: ["version", "tools"], context: "catalog")
        guard PlatformToolJSON.strictInt(root["version"]) == 1 else {
            throw PlatformToolCatalogError.malformed("version")
        }
        guard let rawTools = root["tools"] as? [Any] else {
            throw PlatformToolCatalogError.malformed("tools")
        }
        guard rawTools.count > 0,
              rawTools.count <= PlatformToolHostLimits.maximumTools
        else { throw PlatformToolCatalogError.malformed("toolsCount") }

        var entries: [PlatformToolCatalogEntry] = []
        var seen = Set<String>()
        for raw in rawTools {
            guard let object = raw as? [String: Any] else {
                throw PlatformToolCatalogError.malformed("tool")
            }
            let entry = try parseEntry(object)
            guard seen.insert(entry.name).inserted else {
                throw PlatformToolCatalogError.duplicateName(entry.name)
            }
            if ToolCatalog.descriptor(named: entry.name) != nil {
                throw PlatformToolCatalogError.nameCollision(entry.name)
            }
            entries.append(entry)
        }
        return PlatformToolCatalog(entries: entries)
    }

    private static func parseEntry(_ object: [String: Any]) throws
        -> PlatformToolCatalogEntry {
        try requireClosed(object, allowed: [
            "name", "description", "schema", "riskLabels", "effect",
            "isSideEffecting", "hostScope", "executionBoundary",
            "supportsConcurrentBatchDispatch",
        ], context: "tool")

        guard let name = object["name"] as? String else {
            throw PlatformToolCatalogError.nameInvalid("missing")
        }
        try validateName(name)

        guard let description = object["description"] as? String,
              !description.isEmpty,
              description.utf8.count <= PlatformToolHostLimits.maximumDescriptionBytes,
              !PlatformToolJSON.hasControlCharacters(description, allowingNewlines: true)
        else { throw PlatformToolCatalogError.descriptionInvalid("shape") }

        guard let schemaObject = object["schema"] as? [String: Any] else {
            throw PlatformToolCatalogError.schemaInvalid("missing")
        }
        let schemaData: Data
        do {
            schemaData = try JSONSerialization.data(
                withJSONObject: schemaObject, options: [.sortedKeys])
        } catch {
            throw PlatformToolCatalogError.schemaInvalid("json")
        }
        guard schemaData.count <= PlatformToolHostLimits.maximumSchemaBytes else {
            throw PlatformToolCatalogError.schemaInvalid("bytes")
        }
        do {
            try PlatformToolSchemaValidator.validateSchema(schemaObject)
        } catch {
            throw PlatformToolCatalogError.schemaInvalid("structure")
        }
        if let properties = schemaObject["properties"] as? [String: Any] {
            for key in properties.keys where reservedArgumentKeys.contains(key) {
                throw PlatformToolCatalogError.schemaInvalid("reservedOwnership")
            }
        }
        guard let schemaJSON = String(data: schemaData, encoding: .utf8) else {
            throw PlatformToolCatalogError.schemaInvalid("encoding")
        }

        guard let rawRisks = object["riskLabels"] as? [Any],
              rawRisks.count <= RiskLabel.allCases.count
        else { throw PlatformToolCatalogError.riskInvalid("shape") }
        var risks = Set<RiskLabel>()
        for raw in rawRisks {
            guard let text = raw as? String,
                  let risk = RiskLabel(rawValue: text) else {
                throw PlatformToolCatalogError.riskInvalid("unknown")
            }
            // A generic mailbox is not a general model-code executor.
            guard risk != .executesLocalCode else {
                throw PlatformToolCatalogError.riskUnsupported("executesLocalCode")
            }
            guard risks.insert(risk).inserted else {
                throw PlatformToolCatalogError.riskInvalid("duplicate")
            }
        }

        guard let effectText = object["effect"] as? String,
              let effect = ToolEffect(rawValue: effectText) else {
            throw PlatformToolCatalogError.effectInvalid("unknown")
        }
        guard let sideEffecting = PlatformToolJSON.strictBool(
            object["isSideEffecting"]) else {
            throw PlatformToolCatalogError.fieldInvalid("isSideEffecting")
        }
        guard let hostScope = PlatformToolJSON.strictBool(
            object["hostScope"]) else {
            throw PlatformToolCatalogError.fieldInvalid("hostScope")
        }
        if effect == .readOnly, sideEffecting {
            throw PlatformToolCatalogError.effectInvalid("readOnlySideEffecting")
        }
        // `.internalState` is legitimately used both with and without an
        // approval requirement (e.g. UserQuestionTool is internalState and
        // not side-effecting). External mutation must still be side-effecting.
        if effect == .mutating, !sideEffecting {
            throw PlatformToolCatalogError.effectInvalid("mutatingNotSideEffecting")
        }

        guard let boundaryText = object["executionBoundary"] as? String,
              let boundary = ToolExecutionBoundary(rawValue: boundaryText),
              boundary == .mainRunOnly else {
            throw PlatformToolCatalogError.boundaryInvalid("mainRunOnly")
        }
        guard let concurrent = PlatformToolJSON.strictBool(
            object["supportsConcurrentBatchDispatch"]), concurrent == false else {
            throw PlatformToolCatalogError.concurrentInvalid("serialOnly")
        }

        return PlatformToolCatalogEntry(
            name: name,
            description: description,
            schemaJSON: schemaJSON,
            riskLabels: risks,
            effect: effect,
            isSideEffecting: sideEffecting,
            requiresHostScope: hostScope,
            executionBoundary: boundary,
            supportsConcurrentBatchDispatch: concurrent
        )
    }

    private static func validateName(_ name: String) throws {
        guard name.utf8.count <= PlatformToolHostLimits.maximumNameCharacters,
              name.utf8.count == name.count else {
            throw PlatformToolCatalogError.nameInvalid("characters")
        }
        let segments = name.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else {
            throw PlatformToolCatalogError.nameInvalid("segments")
        }
        for (index, segment) in segments.enumerated() {
            guard segment.count >= 1,
                  segment.count <= PlatformToolHostLimits.maximumNameSegmentCharacters
            else { throw PlatformToolCatalogError.nameInvalid("segmentLength") }
            let bytes = Array(segment.utf8)
            guard let first = bytes.first else {
                throw PlatformToolCatalogError.nameInvalid("segment")
            }
            let firstValid = index == 0
                ? (first >= 97 && first <= 122)
                : ((first >= 65 && first <= 90) || (first >= 97 && first <= 122))
            guard firstValid else {
                throw PlatformToolCatalogError.nameInvalid("segmentStart")
            }
            guard bytes.allSatisfy({ byte in
                (byte >= 97 && byte <= 122) || (byte >= 65 && byte <= 90)
                    || (byte >= 48 && byte <= 57)
            }) else { throw PlatformToolCatalogError.nameInvalid("segmentCharacters") }
        }
        // The MCP runtime source owns the `mcp.` namespace and removes its
        // tools by that prefix on disconnect. A platform tool must never be
        // able to occupy a name another runtime source can unregister.
        guard segments.first != "mcp" else {
            throw PlatformToolCatalogError.nameCollision("reservedNamespace")
        }
        guard ToolAliasTable.canonical(name) == name else {
            throw PlatformToolCatalogError.nameCollision("alias")
        }
        guard !RetiredExecutionTools.contains(name) else {
            throw PlatformToolCatalogError.nameCollision("retired")
        }
    }

    private static func requireClosed(_ object: [String: Any],
                                      allowed: Set<String>,
                                      context: String) throws {
        for key in object.keys where !allowed.contains(key) {
            throw PlatformToolCatalogError.fieldInvalid("\(context).\(key)")
        }
    }
}

// MARK: - Bounded schema enforcement

public enum PlatformToolSchemaError: Error, Equatable {
    case invalid(String)
    case argumentsInvalid(String)
}

/// The exact JSON-Schema subset this bridge promises to enforce. Anything
/// outside it is refused at bind time, so an argument can never slip past a
/// keyword the executor does not understand.
public enum PlatformToolSchemaValidator {
    private static let annotationKeys: Set<String> = ["type", "description", "title"]
    private static let valueTypes: Set<String> = [
        "object", "array", "string", "integer", "number", "boolean",
    ]
    private static let numericBoundsKeys: Set<String> = ["minimum", "maximum"]
    private static let stringBoundsKeys: Set<String> = ["minLength", "maxLength"]
    private static let arrayBoundsKeys: Set<String> = ["minItems", "maxItems"]

    public static func validateSchema(_ root: [String: Any]) throws {
        var nodes = 0
        try validateNode(root, depth: 0, isRoot: true, nodes: &nodes)
    }

    private static func validateNode(_ node: [String: Any], depth: Int,
                                     isRoot: Bool, nodes: inout Int) throws {
        nodes += 1
        guard nodes <= PlatformToolHostLimits.maximumSchemaNodes else {
            throw PlatformToolSchemaError.invalid("schemaNodes")
        }
        guard depth <= PlatformToolHostLimits.maximumSchemaDepth else {
            throw PlatformToolSchemaError.invalid("schemaDepth")
        }
        guard let type = node["type"] as? String,
              valueTypes.contains(type) else {
            throw PlatformToolSchemaError.invalid("type")
        }
        try validateAnnotations(node)
        if isRoot, type != "object" {
            throw PlatformToolSchemaError.invalid("rootObject")
        }

        switch type {
        case "object":
            try requireOnly(node, keys: annotationKeys.union([
                "properties", "required", "additionalProperties",
            ]))
            guard let properties = node["properties"] as? [String: Any] else {
                throw PlatformToolSchemaError.invalid("properties")
            }
            guard properties.count <= PlatformToolHostLimits.maximumSchemaProperties
            else { throw PlatformToolSchemaError.invalid("propertyCount") }
            guard let additional = PlatformToolJSON.strictBool(
                node["additionalProperties"]), additional == false else {
                throw PlatformToolSchemaError.invalid("additionalProperties")
            }
            if let required = node["required"] {
                guard let list = required as? [Any],
                      list.count <= properties.count,
                      list.allSatisfy({ $0 is String }) else {
                    throw PlatformToolSchemaError.invalid("required")
                }
                let names = list.compactMap { $0 as? String }
                guard Set(names).count == names.count,
                      names.allSatisfy({ properties[$0] != nil }) else {
                    throw PlatformToolSchemaError.invalid("requiredNames")
                }
            }
            for (key, value) in properties {
                guard !key.isEmpty,
                      key.utf8.count <= PlatformToolHostLimits.maximumNameSegmentCharacters
                else { throw PlatformToolSchemaError.invalid("propertyName") }
                guard let child = value as? [String: Any] else {
                    throw PlatformToolSchemaError.invalid("propertySchema")
                }
                try validateNode(child, depth: depth + 1, isRoot: false,
                                 nodes: &nodes)
            }

        case "array":
            try requireOnly(node, keys: annotationKeys.union(
                arrayBoundsKeys.union(["items"])))
            guard let items = node["items"] as? [String: Any] else {
                throw PlatformToolSchemaError.invalid("items")
            }
            try validateNode(items, depth: depth + 1, isRoot: false,
                             nodes: &nodes)
            try validateIntegerBounds(node, keys: arrayBoundsKeys,
                                      lower: 0, upper: 1_024)

        case "string":
            try requireOnly(node, keys: annotationKeys.union(
                stringBoundsKeys.union(["enum"])))
            try validateIntegerBounds(node, keys: stringBoundsKeys,
                                      lower: 0, upper: 65_536)
            if let enumValue = node["enum"] {
                guard let values = enumValue as? [Any],
                      !values.isEmpty,
                      values.count <= PlatformToolHostLimits.maximumEnumValues,
                      values.allSatisfy({ $0 is String }) else {
                    throw PlatformToolSchemaError.invalid("enum")
                }
                let strings = values.compactMap { $0 as? String }
                guard Set(strings).count == strings.count,
                      strings.allSatisfy({
                          $0.utf8.count <= 256 && !$0.isEmpty
                              && !PlatformToolJSON.hasControlCharacters(
                                  $0, allowingNewlines: false)
                      }) else {
                    throw PlatformToolSchemaError.invalid("enumValues")
                }
            }

        case "integer", "number":
            try requireOnly(node, keys: annotationKeys.union(numericBoundsKeys))
            if let minimum = node["minimum"],
               PlatformToolJSON.strictDouble(minimum) == nil {
                throw PlatformToolSchemaError.invalid("minimum")
            }
            if let maximum = node["maximum"],
               PlatformToolJSON.strictDouble(maximum) == nil {
                throw PlatformToolSchemaError.invalid("maximum")
            }
            if let minimum = node["minimum"],
               let maximum = node["maximum"],
               let low = PlatformToolJSON.strictDouble(minimum),
               let high = PlatformToolJSON.strictDouble(maximum),
               low > high {
                throw PlatformToolSchemaError.invalid("range")
            }

        case "boolean":
            try requireOnly(node, keys: annotationKeys)

        default:
            throw PlatformToolSchemaError.invalid("type")
        }
    }

    private static func validateAnnotations(_ node: [String: Any]) throws {
        for key in ["description", "title"] {
            guard let raw = node[key] else { continue }
            guard let text = raw as? String,
                  text.utf8.count <= PlatformToolHostLimits.maximumSchemaTextCharacters
            else { throw PlatformToolSchemaError.invalid(key) }
        }
    }

    private static func requireOnly(_ node: [String: Any], keys: Set<String>) throws {
        for key in node.keys where !keys.contains(key) {
            throw PlatformToolSchemaError.invalid("keyword:\(key)")
        }
    }

    private static func validateIntegerBounds(_ node: [String: Any],
                                              keys: Set<String>,
                                              lower: Int,
                                              upper: Int) throws {
        var values: [String: Int] = [:]
        for key in keys where node[key] != nil {
            guard let value = PlatformToolJSON.strictInt(node[key]),
                  value >= lower, value <= upper else {
                throw PlatformToolSchemaError.invalid(key)
            }
            values[key] = value
        }
        if let minimum = values["minLength"], let maximum = values["maxLength"],
           minimum > maximum {
            throw PlatformToolSchemaError.invalid("stringRange")
        }
        if let minimum = values["minItems"], let maximum = values["maxItems"],
           minimum > maximum {
            throw PlatformToolSchemaError.invalid("arrayRange")
        }
    }

    // MARK: Arguments

    public static func validateArguments(_ data: Data, schemaJSON: String) throws {
        guard data.count > 0,
              data.count <= PlatformToolHostLimits.maximumArgumentsBytes else {
            throw PlatformToolSchemaError.argumentsInvalid("bytes")
        }
        guard let arguments = PlatformToolJSON.object(data) else {
            throw PlatformToolSchemaError.argumentsInvalid("json")
        }
        guard let schemaData = schemaJSON.data(using: .utf8),
              let schema = PlatformToolJSON.object(schemaData) else {
            throw PlatformToolSchemaError.argumentsInvalid("schema")
        }
        try validateObject(arguments, schema: schema, depth: 0)
    }

    private static func validateObject(_ value: [String: Any],
                                       schema: [String: Any],
                                       depth: Int) throws {
        guard depth <= PlatformToolHostLimits.maximumSchemaDepth + 4 else {
            throw PlatformToolSchemaError.argumentsInvalid("depth")
        }
        guard let properties = schema["properties"] as? [String: Any],
              let additional = PlatformToolJSON.strictBool(
                schema["additionalProperties"]), additional == false else {
            throw PlatformToolSchemaError.argumentsInvalid("schemaShape")
        }
        for key in value.keys where properties[key] == nil {
            throw PlatformToolSchemaError.argumentsInvalid("unknown:\(key)")
        }
        if let required = schema["required"] as? [Any] {
            for raw in required {
                guard let key = raw as? String, value[key] != nil else {
                    throw PlatformToolSchemaError.argumentsInvalid("missing")
                }
            }
        }
        for (key, child) in properties {
            guard let childValue = value[key] else { continue }
            guard let childSchema = child as? [String: Any] else {
                throw PlatformToolSchemaError.argumentsInvalid("schemaShape")
            }
            try validateValue(childValue, schema: childSchema, depth: depth + 1)
        }
    }

    private static func validateValue(_ value: Any,
                                      schema: [String: Any],
                                      depth: Int) throws {
        guard let type = schema["type"] as? String else {
            throw PlatformToolSchemaError.argumentsInvalid("type")
        }
        switch type {
        case "object":
            guard let object = value as? [String: Any] else {
                throw PlatformToolSchemaError.argumentsInvalid("type:object")
            }
            try validateObject(object, schema: schema, depth: depth)

        case "array":
            guard let array = value as? [Any],
                  array.count <= PlatformToolHostLimits.maximumArgumentArrayItems
            else { throw PlatformToolSchemaError.argumentsInvalid("type:array") }
            if let minimum = PlatformToolJSON.strictInt(schema["minItems"]),
               array.count < minimum {
                throw PlatformToolSchemaError.argumentsInvalid("minItems")
            }
            if let maximum = PlatformToolJSON.strictInt(schema["maxItems"]),
               array.count > maximum {
                throw PlatformToolSchemaError.argumentsInvalid("maxItems")
            }
            guard let items = schema["items"] as? [String: Any] else {
                throw PlatformToolSchemaError.argumentsInvalid("items")
            }
            for element in array {
                try validateValue(element, schema: items, depth: depth + 1)
            }

        case "string":
            guard let string = value as? String else {
                throw PlatformToolSchemaError.argumentsInvalid("type:string")
            }
            let length = string.count
            if let minimum = PlatformToolJSON.strictInt(schema["minLength"]),
               length < minimum {
                throw PlatformToolSchemaError.argumentsInvalid("minLength")
            }
            if let maximum = PlatformToolJSON.strictInt(schema["maxLength"]),
               length > maximum {
                throw PlatformToolSchemaError.argumentsInvalid("maxLength")
            }
            if let enumValue = schema["enum"] as? [Any] {
                let allowed = enumValue.compactMap { $0 as? String }
                guard allowed.contains(string) else {
                    throw PlatformToolSchemaError.argumentsInvalid("enum")
                }
            }

        case "integer":
            guard PlatformToolJSON.strictInt(value) != nil else {
                throw PlatformToolSchemaError.argumentsInvalid("type:integer")
            }
            try validateNumericBounds(value, schema: schema)

        case "number":
            guard PlatformToolJSON.strictDouble(value) != nil else {
                throw PlatformToolSchemaError.argumentsInvalid("type:number")
            }
            try validateNumericBounds(value, schema: schema)

        case "boolean":
            guard PlatformToolJSON.strictBool(value) != nil else {
                throw PlatformToolSchemaError.argumentsInvalid("type:boolean")
            }

        default:
            throw PlatformToolSchemaError.argumentsInvalid("type")
        }
    }

    private static func validateNumericBounds(_ value: Any,
                                              schema: [String: Any]) throws {
        guard let number = PlatformToolJSON.strictDouble(value) else {
            throw PlatformToolSchemaError.argumentsInvalid("number")
        }
        if let minimum = PlatformToolJSON.strictDouble(schema["minimum"]),
           number < minimum {
            throw PlatformToolSchemaError.argumentsInvalid("minimum")
        }
        if let maximum = PlatformToolJSON.strictDouble(schema["maximum"]),
           number > maximum {
            throw PlatformToolSchemaError.argumentsInvalid("maximum")
        }
    }
}

// MARK: - Result contract

public struct PlatformToolResult: Sendable {
    public let summary: String
    public let exitStatus: Int32?
    public let evidence: [String]
    /// Only a byte-verified image already committed under the App storage
    /// artifact namespace. The bytes, size and SHA-256 are re-read here.
    public let artifact: ToolArtifactReference?
    /// Digest of the exact full result JSON before any summary shortening.
    public let rawJSONSHA256: String

    public init(summary: String, exitStatus: Int32?, evidence: [String],
                artifact: ToolArtifactReference?, rawJSONSHA256: String) {
        self.summary = summary
        self.exitStatus = exitStatus
        self.evidence = evidence
        self.artifact = artifact
        self.rawJSONSHA256 = rawJSONSHA256
    }

    /// Model-visible text within the bounded summary budget.
    public var modelVisibleSummary: String {
        guard !evidence.isEmpty else { return summary }
        return summary + "\n\nEvidence:\n"
            + evidence.map { "- \($0)" }.joined(separator: "\n")
    }
}

public enum PlatformToolResultError: Error, Equatable {
    case invalid(String)
}

public enum PlatformToolResultParser {
    /// `artifactRoot` is the ONE actual App-owned artifact directory bound by
    /// trusted composition (`<live owned root>/FloeAgent`) or nil while no
    /// root is bound. An artifact is refused when the root is nil; a result
    /// without an artifact remains valid so the mailbox can operate before a
    /// screenshot capability is bound. Both PNG and JPEG are accepted (the
    /// Full host's real screenshot encoder emits either), with the same
    /// strict sniffed-MIME, byte-count, SHA-256 and namespace checks.
    public static func parse(_ data: Data, artifactRoot: URL?) throws
        -> PlatformToolResult {
        guard data.count > 0,
              data.count <= PlatformToolHostLimits.maximumReplyBytes else {
            throw PlatformToolResultError.invalid("bytes")
        }
        guard let root = PlatformToolJSON.object(data),
              String(data: data, encoding: .utf8) != nil else {
            throw PlatformToolResultError.invalid("json")
        }
        try requireClosed(root, allowed: [
            "version", "summary", "exitStatus", "evidence", "artifact",
        ])
        guard PlatformToolJSON.strictInt(root["version"]) == 1 else {
            throw PlatformToolResultError.invalid("version")
        }

        guard let summary = root["summary"] as? String,
              !summary.isEmpty,
              summary.count <= PlatformToolHostLimits.maximumSummaryCharacters,
              !PlatformToolJSON.hasControlCharacters(summary, allowingNewlines: true)
        else { throw PlatformToolResultError.invalid("summary") }

        var exitStatus: Int32?
        if let rawStatus = root["exitStatus"] {
            guard let value = PlatformToolJSON.strictInt(rawStatus),
                  value >= Int(Int32.min), value <= Int(Int32.max) else {
                throw PlatformToolResultError.invalid("exitStatus")
            }
            exitStatus = Int32(value)
        }

        var evidence: [String] = []
        if let rawEvidence = root["evidence"] {
            guard let list = rawEvidence as? [Any],
                  list.count <= PlatformToolHostLimits.maximumEvidenceEntries else {
                throw PlatformToolResultError.invalid("evidence")
            }
            for raw in list {
                guard let line = raw as? String,
                      !line.isEmpty,
                      line.utf8.count <= PlatformToolHostLimits.maximumEvidenceCharacters,
                      !PlatformToolJSON.hasControlCharacters(
                        line, allowingNewlines: false) else {
                    throw PlatformToolResultError.invalid("evidenceLine")
                }
                evidence.append(line)
            }
        }

        var artifact: ToolArtifactReference?
        if let rawArtifact = root["artifact"] {
            guard let object = rawArtifact as? [String: Any] else {
                throw PlatformToolResultError.invalid("artifact")
            }
            guard let artifactRoot else {
                // Fail closed until trusted composition binds the ACTUAL
                // owned root; never fall back to Foundation/temporary.
                throw PlatformToolResultError.invalid("artifactRootUnbound")
            }
            artifact = try verifiedArtifact(object, root: artifactRoot)
        }

        return PlatformToolResult(
            summary: summary,
            exitStatus: exitStatus,
            evidence: evidence,
            artifact: artifact,
            rawJSONSHA256: FloeDigest.sha256Hex(data)
        )
    }

    private static func verifiedArtifact(_ object: [String: Any], root: URL) throws
        -> ToolArtifactReference {
        try requireClosed(object, allowed: [
            "relativePath", "mimeType", "byteCount", "sha256",
        ])
        guard let path = object["relativePath"] as? String,
              path.hasPrefix(PlatformToolHostLimits.artifactPathPrefix),
              path.utf8.count <= PlatformToolHostLimits.maximumArtifactPathCharacters,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.split(separator: "/").contains(where: {
                  $0.isEmpty || $0 == "." || $0 == ".."
              })
        else { throw PlatformToolResultError.invalid("artifactPath") }

        // The screenshot wire is closed to the two families the Full host
        // actually emits. JPEG is a first-class path (PhoneControl writes
        // real JPEG); no conversion or duplicated bitmap is required.
        guard let rawMIME = object["mimeType"] as? String,
              let mime = ProviderImageEvidencePolicy.canonicalMIMEType(rawMIME),
              mime == "image/png" || mime == "image/jpeg"
        else { throw PlatformToolResultError.invalid("artifactMIME") }

        let fileExtension = (path as NSString).pathExtension.lowercased()
        let extensionMatchesMIME = mime == "image/png"
            ? fileExtension == "png"
            : (fileExtension == "jpg" || fileExtension == "jpeg")
        guard extensionMatchesMIME else {
            throw PlatformToolResultError.invalid("artifactExtension")
        }

        guard let byteCount = PlatformToolJSON.strictInt(object["byteCount"]),
              byteCount > 0,
              byteCount <= ProviderImageEvidencePolicy.maximumImageBytes
        else { throw PlatformToolResultError.invalid("artifactBytes") }

        guard let sha = object["sha256"] as? String,
              sha.count == 64,
              sha.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57)
                      || (scalar.value >= 97 && scalar.value <= 102)
                      || (scalar.value >= 65 && scalar.value <= 70)
              })
        else { throw PlatformToolResultError.invalid("artifactSHA256") }

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(path)
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(resolvedRoot.path + "/") else {
            throw PlatformToolResultError.invalid("artifactEscape")
        }
        // No symlink may appear anywhere below the trusted bound root. A
        // resolved path that stays inside the root is still refused, so a
        // host-compromised symlink can never substitute bytes the tool did
        // not commit (the root itself is excluded: it is the validated owned
        // directory, not an artifact path).
        var component = root
        for segment in path.split(separator: "/") {
            component.appendPathComponent(String(segment))
            let values = try? component.resourceValues(
                forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else {
                throw PlatformToolResultError.invalid("artifactSymlink")
            }
        }
        guard let bytes = try? Data(contentsOf: resolved, options: [.mappedIfSafe]),
              bytes.count == byteCount,
              FloeDigest.sha256Hex(bytes) == sha.lowercased(),
              ProviderImageEvidencePolicy.sniffedMIME(bytes) == mime
        else { throw PlatformToolResultError.invalid("artifactContent") }

        return ToolArtifactReference(
            id: UUID(),
            relativePath: path,
            mimeType: mime,
            byteCount: byteCount,
            sha256: sha.lowercased()
        )
    }

    private static func requireClosed(_ object: [String: Any],
                                      allowed: Set<String>) throws {
        for key in object.keys where !allowed.contains(key) {
            throw PlatformToolResultError.invalid("field:\(key)")
        }
    }
}
