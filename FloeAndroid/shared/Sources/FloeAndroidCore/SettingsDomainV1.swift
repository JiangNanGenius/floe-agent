// SPDX-License-Identifier: MPL-2.0
import Crypto
import Foundation

/// Settings-domain P0 wire vocabulary for the accepted rev3 contract
/// (2026-10-19).
///
/// This file is deliberately **vocabulary and validation only**:
/// * no command handler is registered;
/// * no SQLite/database access, no store, no model call and no mutation;
/// * no capability becomes "available" because a type exists;
/// * Swift remains the single structural authority; the Kotlin projection is
///   a typed mirror for callers and tests.
///
/// The five labels are additive to `BridgeV3.configurationScopes`. The closed
/// matrix in `BridgeEnvelopeV3.swift` remains the authority for which
/// command/label tuple exists. This file supplies the *closed payload*
/// grammar, typed request/result vocabulary, the canonical digest encoder and
/// the actual-UTF-8 page-budget chunker used by the later P1..P8 adapters.
public enum SettingsDomainV1 {
    // MARK: - Constants

    /// Normal serialized page budget. Counts actual UTF-8 bytes after JSON
    /// escaping; never `String.count`.
    public static let pageBudgetBytes = 48 * 1024

    /// Hard request/output frame bound, unchanged from v1/v2/v3.
    public static let maximumFrameBytes = BridgeV3.maximumBytes

    /// Original store-level clamps. User-edited oversize content is rejected
    /// with `payloadTooLarge` BEFORE mutation; it is never silently truncated.
    public static let maximumMemoryContentCharacters = 4_096
    public static let maximumPersonalizationContentCharacters = 24_000

    public static let maximumMemoryPage = 500
    public static let maximumCandidatePage = 100
    public static let maximumOrganizeProposalPage = 100
    public static let maximumUsagePage = 100
    public static let maximumBulkEntries = 500
    public static let maximumChunkBytes = 32_768
    public static let maximumSearchItems = 20
    public static let maximumSearchQueryCharacters = 8_000
    public static let maximumHandleCharacters = 256
    public static let maximumReceiptCharacters = 256
    public static let maximumFactIdentityCharacters = 160
    public static let maximumMemorySearchHandleCharacters = 256

    // MARK: - Labels and ownership

    public enum Label: String, Sendable, CaseIterable {
        case settingsDefaults = "settings.defaults"
        case memory
        case personalization
        case usage
        case privacy
    }

    /// The five additive labels, in declaration order. `BridgeV3` appends the
    /// same strings to its closed 19-label vocabulary.
    public static let labels: [String] = Label.allCases.map(\.rawValue)

    /// Command -> label for every additive tuple except the third
    /// `content.read` entry, which is label-aware.
    private static let commandOwner: [String: String] = [
        "config.defaults.get": "settings.defaults",
        "config.defaults.save": "settings.defaults",
        "memory.list": "memory",
        "memory.get": "memory",
        "memory.add": "memory",
        "memory.update": "memory",
        "memory.delete": "memory",
        "memory.delete.bulk": "memory",
        "memory.search": "memory",
        "memory.candidates.list": "memory",
        "memory.candidate.resolve": "memory",
        "memory.organize.start": "memory",
        "memory.organize.proposal.read": "memory",
        "memory.organize.apply": "memory",
        "memory.organize.cancel": "memory",
        "personalization.get": "personalization",
        "personalization.revision.read": "personalization",
        "personalization.save": "personalization",
        "personalization.rollback": "personalization",
        "personalization.automatic.set": "personalization",
        "personalization.generate": "personalization",
        "personalization.generate.cancel": "personalization",
        "usage.statistics.get": "usage",
        "privacy.summary.get": "privacy",
        "privacy.history.clear": "privacy",
        "privacy.modelConfiguration.clear": "privacy",
    ]

    /// Whether this command/label pair belongs to the additive settings
    /// vocabulary. `content.read` is special: the personalization label is
    /// owned here, while the existing conversations and conversationLifecycle
    /// entries stay on their frozen paths.
    public static func owns(command: String, label: String) -> Bool {
        guard labels.contains(label) else { return false }
        if command == "content.read" { return label == Label.personalization.rawValue }
        return commandOwner[command] == label
    }

    // MARK: - Intent policy

    /// Per-command envelope intent policy. This is stricter than the generic
    /// `allowsCreateIntent` bit: the five create-only commands below MUST
    /// carry `createIntent=true`, even though the generic matrix only says a
    /// create intent would be allowed.
    public enum IntentPolicy: String, Sendable {
        case readOnly
        case revisionRequired
        case createOnly
    }

    public static let intentPolicy: [String: IntentPolicy] = [
        "config.defaults.get": .readOnly,
        "config.defaults.save": .revisionRequired,
        "memory.list": .readOnly,
        "memory.get": .readOnly,
        "memory.add": .createOnly,
        "memory.update": .revisionRequired,
        "memory.delete": .revisionRequired,
        "memory.delete.bulk": .createOnly,
        "memory.search": .readOnly,
        "memory.candidates.list": .readOnly,
        "memory.candidate.resolve": .revisionRequired,
        "memory.organize.start": .createOnly,
        "memory.organize.proposal.read": .readOnly,
        "memory.organize.apply": .createOnly,
        "memory.organize.cancel": .readOnly,
        "personalization.get": .readOnly,
        "personalization.revision.read": .readOnly,
        "personalization.save": .revisionRequired,
        "personalization.rollback": .revisionRequired,
        "personalization.automatic.set": .revisionRequired,
        "personalization.generate": .createOnly,
        "personalization.generate.cancel": .readOnly,
        "content.read": .readOnly,
        "usage.statistics.get": .readOnly,
        "privacy.summary.get": .readOnly,
        "privacy.history.clear": .revisionRequired,
        "privacy.modelConfiguration.clear": .revisionRequired,
    ]

    /// Exact create-only commands. Exposed for the matrix checker and tests.
    public static let createOnlyCommands: Set<String> = Set(
        intentPolicy.filter { $0.value == .createOnly }.keys
    )

    // MARK: - Strict JSON value

    /// Typed JSON union used by the validator. `boolean` is never a number,
    /// integer is never fractional, and `null` is never absence.
    public enum JSONValue: Sendable, Equatable, Decodable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case integer(Int64)
        case fractional(Double)
        case boolean(Bool)
        case null

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .boolean(value)
            } else if let value = try? container.decode(Int64.self) {
                self = .integer(value)
            } else if let value = try? container.decode(Double.self) {
                self = .fractional(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else if let value = try? container.decode([String: JSONValue].self) {
                self = .object(value)
            } else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unsupported JSON value"
                ))
            }
        }

        public static func decode(_ data: Data) -> JSONValue? {
            try? JSONDecoder().decode(JSONValue.self, from: data)
        }
    }

    // MARK: - Validation failure

    public struct ValidationFailure: Error, Sendable, Equatable {
        public let code: String
        public let reason: String

        public init(code: String, reason: String) {
            self.code = code
            self.reason = reason
        }

        public static func invalid(_ reason: String) -> ValidationFailure {
            ValidationFailure(code: "invalidEnvelope", reason: reason)
        }

        public static func payloadTooLarge(maxChars: Int) -> ValidationFailure {
            ValidationFailure(code: "payloadTooLarge", reason: "maxChars:\(maxChars)")
        }
    }

    /// Validates the closed payload for a settings-domain command and enforces
    /// the exact createIntent policy. Returns `nil` when the payload is valid.
    /// This function never performs I/O and never mutates state.
    public static func validate(payload: JSONValue?,
                                command: String,
                                label: String,
                                createIntent: Bool,
                                revisionPresent: Bool) -> ValidationFailure? {
        guard owns(command: command, label: label) else {
            return .invalid("unknownCommand")
        }
        guard let policy = intentPolicy[command] else {
            return .invalid("unknownCommand")
        }
        switch policy {
        case .createOnly:
            guard createIntent else { return .invalid("createIntentRequired") }
            guard !revisionPresent else { return .invalid("revisionForNewIdentity") }
        case .readOnly, .revisionRequired:
            guard !createIntent else { return .invalid("createIntentNotAllowed") }
        }

        do {
            switch command {
            case "config.defaults.get", "privacy.summary.get":
                try validateEmpty(payload: payload)

            case "config.defaults.save":
                try validateDefaultsSave(payload)
            case "memory.list":
                try validateMemoryList(payload)
            case "memory.get":
                try validateMemoryGet(payload)
            case "memory.add":
                try validateMemoryAdd(payload)
            case "memory.update":
                try validateMemoryUpdate(payload)
            case "memory.delete":
                try validateMemoryDelete(payload)
            case "memory.delete.bulk":
                try validateMemoryDeleteBulk(payload)
            case "memory.search":
                try validateMemorySearch(payload)
            case "memory.candidates.list":
                try validateCandidatesList(payload)
            case "memory.candidate.resolve":
                try validateCandidateResolve(payload)
            case "memory.organize.start":
                try validateOrganizeStart(payload)
            case "memory.organize.proposal.read":
                try validateOrganizeProposalRead(payload)
            case "memory.organize.apply":
                try validateOrganizeApply(payload)
            case "memory.organize.cancel":
                try validateCancel(payload)
            case "personalization.get":
                try validatePersonalizationGet(payload)
            case "personalization.revision.read":
                try validatePersonalizationRevisionRead(payload)
            case "personalization.save":
                try validatePersonalizationSave(payload)
            case "personalization.rollback":
                try validatePersonalizationRollback(payload)
            case "personalization.automatic.set":
                try validatePersonalizationAutomaticSet(payload)
            case "personalization.generate":
                try validatePersonalizationGenerate(payload)
            case "personalization.generate.cancel":
                try validateCancel(payload, unknownReason: "unknownPersonalizationField")
            case "content.read":
                try validateContentRead(payload)
            case "usage.statistics.get":
                try validateUsageStatistics(payload)
            case "privacy.history.clear", "privacy.modelConfiguration.clear":
                try validatePrivacyClear(payload)
            default:
                return .invalid("unknownCommand")
            }
            return nil
        } catch let failure as ValidationFailure {
            return failure
        } catch {
            return .invalid("invalidPayload")
        }
    }

    // MARK: - Payload reader

    private struct Reader {
        let object: [String: JSONValue]
        var used: Set<String> = []

        mutating func take(_ key: String) -> JSONValue? {
            used.insert(key)
            return object[key]
        }

        mutating func finish(unknownReason: String) throws {
            for key in object.keys where !used.contains(key) {
                throw ValidationFailure.invalid(unknownReason)
            }
        }
    }

    private static func reader(_ payload: JSONValue?,
                               required: Set<String> = [],
                               unknownReason: String) throws -> Reader {
        guard let payload else { throw ValidationFailure.invalid("missingPayload") }
        guard case .object(let object) = payload else {
            throw ValidationFailure.invalid("invalidPayload")
        }
        for key in required where object[key] == nil {
            throw ValidationFailure.invalid("missingPayloadField:\(key)")
        }
        return Reader(object: object)
    }

    private static func validateEmpty(payload: JSONValue?) throws {
        guard let payload else { return }
        guard case .object(let object) = payload, object.isEmpty else {
            throw ValidationFailure.invalid("invalidPayload")
        }
    }

    // MARK: - Primitive readers

    private static func stringValue(_ value: JSONValue, _ field: String,
                                    maxCharacters: Int? = nil,
                                    allowControlCharacters: Bool = false) throws -> String {
        guard case .string(let string) = value else {
            throw ValidationFailure.invalid("invalidPayloadField:\(field)")
        }
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationFailure.invalid("emptyPayloadField:\(field)")
        }
        if let maxCharacters, string.count > maxCharacters {
            throw ValidationFailure.invalid("payloadFieldTooLong:\(field)")
        }
        if !allowControlCharacters,
           string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw ValidationFailure.invalid("controlCharacterInField:\(field)")
        }
        return string
    }

    private static func optionalStringValue(_ value: JSONValue?, _ field: String,
                                            maxCharacters: Int? = nil,
                                            allowControlCharacters: Bool = false) throws -> String? {
        guard let value else { return nil }
        return try stringValue(value, field, maxCharacters: maxCharacters,
                               allowControlCharacters: allowControlCharacters)
    }

    private static func booleanValue(_ value: JSONValue, _ field: String) throws -> Bool {
        guard case .boolean(let boolean) = value else {
            throw ValidationFailure.invalid("invalidPayloadField:\(field)")
        }
        return boolean
    }

    private static func optionalBooleanValue(_ value: JSONValue?, _ field: String) throws -> Bool? {
        guard let value else { return nil }
        return try booleanValue(value, field)
    }

    private static func int64Value(_ value: JSONValue, _ field: String) throws -> Int64 {
        guard case .integer(let integer) = value else {
            throw ValidationFailure.invalid("invalidPayloadField:\(field)")
        }
        return integer
    }

    private static func optionalIntValue(_ value: JSONValue?, _ field: String,
                                         range: ClosedRange<Int>) throws -> Int? {
        guard let value else { return nil }
        let raw = try int64Value(value, field)
        guard raw >= Int64(range.lowerBound), raw <= Int64(range.upperBound) else {
            throw ValidationFailure.invalid("payloadFieldOutOfRange:\(field)")
        }
        return Int(raw)
    }

    private static func numberValue(_ value: JSONValue, _ field: String,
                                    range: ClosedRange<Double>) throws -> Double {
        let number: Double
        switch value {
        case .integer(let integer):
            number = Double(integer)
        case .fractional(let double):
            number = double
        default:
            throw ValidationFailure.invalid("invalidPayloadField:\(field)")
        }
        guard number.isFinite, range.contains(number) else {
            throw ValidationFailure.invalid("payloadFieldOutOfRange:\(field)")
        }
        return number
    }

    private static func uuidValue(_ value: JSONValue, _ field: String) throws -> UUID {
        guard case .string(let raw) = value,
              let uuid = UUID(uuidString: raw),
              uuid != BridgeV3.nilUUID else {
            throw ValidationFailure.invalid("invalidPayloadField:\(field)")
        }
        return uuid
    }

    private static func optionalUUIDValue(_ value: JSONValue?, _ field: String) throws -> UUID? {
        guard let value else { return nil }
        return try uuidValue(value, field)
    }

    private static func objectValue(_ value: JSONValue, _ field: String) throws -> [String: JSONValue] {
        guard case .object(let object) = value else {
            throw ValidationFailure.invalid("invalidPayloadField:\(field)")
        }
        return object
    }

    private static func arrayValue(_ value: JSONValue, _ field: String) throws -> [JSONValue] {
        guard case .array(let array) = value else {
            throw ValidationFailure.invalid("invalidPayloadField:\(field)")
        }
        return array
    }

    private static func enumValue<T: RawRepresentable>(_ value: JSONValue,
                                                       _ field: String,
                                                       _ type: T.Type) throws -> T
        where T.RawValue == String {
        guard case .string(let raw) = value, let typed = T(rawValue: raw) else {
            throw ValidationFailure.invalid("invalidPayloadField:\(field)")
        }
        return typed
    }

    private static func optionalEnumValue<T: RawRepresentable>(_ value: JSONValue?,
                                                              _ field: String,
                                                              _ type: T.Type) throws -> T?
        where T.RawValue == String {
        guard let value else { return nil }
        return try enumValue(value, field, type)
    }

    private static func cursorValue(_ value: JSONValue?, _ field: String = "cursor") throws -> Int? {
        guard let value else { return nil }
        guard case .string(let raw) = value,
              !raw.isEmpty, raw.count <= 18,
              raw.allSatisfy({ $0.isNumber }),
              let offset = Int(raw), offset >= 0 else {
            throw ValidationFailure.invalid("invalidCursor")
        }
        return offset
    }

    private static func digestValue(_ value: JSONValue, _ field: String) throws -> String {
        guard case .string(let raw) = value,
              raw.hasPrefix("sha256:"),
              raw.count == 71,
              raw.dropFirst(7).allSatisfy({ $0.isHexDigit }) else {
            throw ValidationFailure.invalid("invalidPayloadField:\(field)")
        }
        return raw
    }

    private static func optionalDigestValue(_ value: JSONValue?, _ field: String) throws -> String? {
        guard let value else { return nil }
        return try digestValue(value, field)
    }

    private static func iso8601Value(_ value: JSONValue, _ field: String) throws -> String {
        guard case .string(let raw) = value, raw.count >= 20, raw.count <= 64 else {
            throw ValidationFailure.invalid("invalidPayloadField:\(field)")
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard fractional.date(from: raw) != nil || plain.date(from: raw) != nil else {
            throw ValidationFailure.invalid("invalidPayloadField:\(field)")
        }
        return raw
    }

    private static func receiptValue(_ value: JSONValue, _ field: String) throws -> String {
        try stringValue(value, field, maxCharacters: maximumReceiptCharacters,
                        allowControlCharacters: false)
    }

    private static func handleValue(_ value: JSONValue, _ field: String) throws -> String {
        try stringValue(value, field, maxCharacters: maximumHandleCharacters,
                        allowControlCharacters: false)
    }

    private static func factIdentityValue(_ value: JSONValue) throws -> FactIdentity {
        let object = try objectValue(value, "factIdentity")
        for key in object.keys where key != "subjectKey" && key != "attributeKey" {
            throw ValidationFailure.invalid("unknownMemoryField")
        }
        guard let subject = object["subjectKey"],
              let attribute = object["attributeKey"] else {
            throw ValidationFailure.invalid("missingPayloadField:factIdentity")
        }
        let subjectKey = try stringValue(subject, "subjectKey",
                                         maxCharacters: maximumFactIdentityCharacters)
        let attributeKey = try stringValue(attribute, "attributeKey",
                                           maxCharacters: maximumFactIdentityCharacters)
        return FactIdentity(subjectKey: subjectKey, attributeKey: attributeKey)
    }

    private static func memoryScopeValue(_ value: JSONValue) throws -> MemoryScope {
        let object = try objectValue(value, "scope")
        for key in object.keys where !["kind", "workspaceID", "conversationID"].contains(key) {
            throw ValidationFailure.invalid("unknownMemoryField")
        }
        guard let rawKind = object["kind"] else {
            throw ValidationFailure.invalid("missingPayloadField:scope.kind")
        }
        let kind = try enumValue(rawKind, "scope.kind", MemoryScopeKind.self)
        let workspaceID = try optionalUUIDValue(object["workspaceID"], "workspaceID")
        let conversationID = try optionalUUIDValue(object["conversationID"], "conversationID")
        do {
            return try MemoryScope(kind: kind, workspaceID: workspaceID,
                                   conversationID: conversationID)
        } catch {
            throw ValidationFailure.invalid("invalidPayloadField:scope")
        }
    }

    private static func optionalMemoryScopeValue(_ value: JSONValue?) throws -> MemoryScope? {
        guard let value else { return nil }
        return try memoryScopeValue(value)
    }

    private static func containsSecretLikeMarker(_ content: String) -> Bool {
        let lower = content.lowercased()
        return [
            "api_key=", "apikey=", "authorization: bearer", "-----begin private key",
            "password:", "password=", "access_token", "refresh_token",
        ].contains { lower.contains($0) }
    }

    private static func memoryContentValue(_ value: JSONValue) throws -> String {
        guard case .string(let content) = value else {
            throw ValidationFailure.invalid("invalidPayloadField:content")
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationFailure.invalid("memoryRejected:empty")
        }
        guard content.count <= maximumMemoryContentCharacters else {
            throw ValidationFailure.payloadTooLarge(maxChars: maximumMemoryContentCharacters)
        }
        guard !containsSecretLikeMarker(content) else {
            throw ValidationFailure.invalid("memoryRejected:secretLike")
        }
        return content
    }

    private static func personalizationContentValue(_ value: JSONValue) throws -> String {
        guard case .string(let content) = value else {
            throw ValidationFailure.invalid("invalidPayloadField:content")
        }
        guard !content.contains("\u{0}") else {
            throw ValidationFailure.invalid("invalidPayloadField:content")
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationFailure.invalid("documentEmpty")
        }
        guard content.count <= maximumPersonalizationContentCharacters else {
            throw ValidationFailure.payloadTooLarge(
                maxChars: maximumPersonalizationContentCharacters
            )
        }
        return content
    }

    // MARK: - Command payloads

    private static func validateDefaultsSave(_ payload: JSONValue?) throws {
        var reader = try reader(payload, required: ["values"],
                                unknownReason: "unknownDefaultsField")
        guard let valuesValue = reader.take("values") else {
            throw ValidationFailure.invalid("missingPayloadField:values")
        }
        let values = try objectValue(valuesValue, "values")
        guard !values.isEmpty else {
            throw ValidationFailure.invalid("invalidPayloadField:values")
        }
        for key in values.keys where !["defaultAgentMode", "runningInputMode",
                                       "verifyFinalAnswer"].contains(key) {
            throw ValidationFailure.invalid("unknownDefaultsField")
        }
        if let mode = values["defaultAgentMode"] {
            do { _ = try enumValue(mode, "defaultAgentMode", DefaultAgentMode.self) }
            catch { throw ValidationFailure.invalid("invalidDefaultsValue:defaultAgentMode") }
        }
        if let input = values["runningInputMode"] {
            do { _ = try enumValue(input, "runningInputMode", RunningInputMode.self) }
            catch { throw ValidationFailure.invalid("invalidDefaultsValue:runningInputMode") }
        }
        if let verify = values["verifyFinalAnswer"] {
            do { _ = try booleanValue(verify, "verifyFinalAnswer") }
            catch { throw ValidationFailure.invalid("invalidDefaultsValue:verifyFinalAnswer") }
        }
        try reader.finish(unknownReason: "unknownDefaultsField")
    }

    private static func validateMemoryList(_ payload: JSONValue?) throws {
        var reader = try reader(payload, unknownReason: "unknownMemoryField")
        _ = try optionalMemoryScopeValue(reader.take("scope"))
        _ = try optionalEnumValue(reader.take("status"), "status", MemoryEntryStatus.self)
        _ = try optionalUUIDValue(reader.take("originConversationID"), "originConversationID")
        _ = try optionalUUIDValue(reader.take("originWorkspaceID"), "originWorkspaceID")
        if let identity = reader.take("factIdentity") {
            _ = try factIdentityValue(identity)
        }
        _ = try optionalBooleanValue(reader.take("isPinned"), "isPinned")
        _ = try cursorValue(reader.take("cursor"))
        _ = try optionalIntValue(reader.take("limit"), "limit", range: 1...maximumMemoryPage)
        try reader.finish(unknownReason: "unknownMemoryField")
    }

    private static func validateMemoryGet(_ payload: JSONValue?) throws {
        var reader = try reader(payload, required: ["id"], unknownReason: "unknownMemoryField")
        _ = try uuidValue(reader.take("id") ?? .null, "id")
        try reader.finish(unknownReason: "unknownMemoryField")
    }

    private static func validateMemoryAdd(_ payload: JSONValue?) throws {
        var reader = try reader(payload, required: ["content", "scope"],
                                unknownReason: "unknownMemoryField")
        _ = try memoryContentValue(reader.take("content") ?? .null)
        _ = try memoryScopeValue(reader.take("scope") ?? .null)
        _ = try optionalUUIDValue(reader.take("originConversationID"), "originConversationID")
        _ = try optionalUUIDValue(reader.take("originWorkspaceID"), "originWorkspaceID")
        try reader.finish(unknownReason: "unknownMemoryField")
    }

    private static func validateMemoryUpdate(_ payload: JSONValue?) throws {
        var reader = try reader(payload, required: ["id", "changes"],
                                unknownReason: "unknownMemoryField")
        _ = try uuidValue(reader.take("id") ?? .null, "id")
        guard let changesValue = reader.take("changes") else {
            throw ValidationFailure.invalid("missingPayloadField:changes")
        }
        let changes = try objectValue(changesValue, "changes")
        guard !changes.isEmpty else {
            throw ValidationFailure.invalid("invalidPayloadField:changes")
        }
        for key in changes.keys where !["content", "importance", "isPinned", "status",
                                        "expiresAt", "factIdentity"].contains(key) {
            throw ValidationFailure.invalid("unknownMemoryField")
        }
        if let content = changes["content"] {
            _ = try memoryContentValue(content)
        }
        if let importance = changes["importance"] {
            _ = try numberValue(importance, "importance", range: 0...1)
        }
        if let pinned = changes["isPinned"] {
            _ = try booleanValue(pinned, "isPinned")
        }
        if let status = changes["status"] {
            let typed = try enumValue(status, "status", MemoryUpdateStatus.self)
            _ = typed
        }
        if let expires = changes["expiresAt"] {
            if case .null = expires {
                // Explicit null clears the expiry; valid.
            } else {
                _ = try iso8601Value(expires, "expiresAt")
            }
        }
        if let identity = changes["factIdentity"], !isNull(identity) {
            _ = try factIdentityValue(identity)
        }
        try reader.finish(unknownReason: "unknownMemoryField")
    }

    private static func validateMemoryDelete(_ payload: JSONValue?) throws {
        var reader = try reader(payload, required: ["id"], unknownReason: "unknownMemoryField")
        _ = try uuidValue(reader.take("id") ?? .null, "id")
        try reader.finish(unknownReason: "unknownMemoryField")
    }

    private static func validateMemoryDeleteBulk(_ payload: JSONValue?) throws {
        var reader = try reader(payload, required: ["batchID", "entries", "syncRevision"],
                                unknownReason: "unknownMemoryField")
        _ = try uuidValue(reader.take("batchID") ?? .null, "batchID")
        _ = try int64Value(reader.take("syncRevision") ?? .null, "syncRevision")
        guard let entriesValue = reader.take("entries") else {
            throw ValidationFailure.invalid("missingPayloadField:entries")
        }
        let entries = try arrayValue(entriesValue, "entries")
        guard !entries.isEmpty else {
            throw ValidationFailure.invalid("invalidPayloadField:entries")
        }
        guard entries.count <= maximumBulkEntries else {
            throw ValidationFailure.invalid("bulkLimitExceeded")
        }
        var seen: Set<UUID> = []
        for entry in entries {
            let object = try objectValue(entry, "entries")
            for key in object.keys where key != "id" && key != "expectedDigest" {
                throw ValidationFailure.invalid("unknownMemoryField")
            }
            guard let idValue = object["id"],
                  let expectedDigest = object["expectedDigest"] else {
                throw ValidationFailure.invalid("invalidPayloadField:entries")
            }
            let id = try uuidValue(idValue, "entries.id")
            guard seen.insert(id).inserted else {
                throw ValidationFailure.invalid("duplicateBatchEntry")
            }
            _ = try digestValue(expectedDigest, "entries.expectedDigest")
        }
        try reader.finish(unknownReason: "unknownMemoryField")
    }

    private static func validateMemorySearch(_ payload: JSONValue?) throws {
        var reader = try reader(payload, required: ["query"],
                                unknownReason: "unknownMemoryField")
        _ = try stringValue(reader.take("query") ?? .null, "query",
                            maxCharacters: maximumSearchQueryCharacters,
                            allowControlCharacters: true)
        _ = try optionalUUIDValue(reader.take("workspaceID"), "workspaceID")
        _ = try optionalUUIDValue(reader.take("conversationID"), "conversationID")
        _ = try optionalIntValue(reader.take("limit"), "limit", range: 1...maximumSearchItems)
        let handle = try optionalStringValue(reader.take("handle"), "handle",
                                             maxCharacters: maximumMemorySearchHandleCharacters)
        let cursor = try cursorValue(reader.take("cursor"))
        if cursor != nil && handle == nil {
            throw ValidationFailure.invalid("invalidCursor")
        }
        try reader.finish(unknownReason: "unknownMemoryField")
    }

    private static func validateCandidatesList(_ payload: JSONValue?) throws {
        var reader = try reader(payload, unknownReason: "unknownMemoryField")
        _ = try optionalEnumValue(reader.take("status"), "status", CandidateStatus.self)
        _ = try cursorValue(reader.take("cursor"))
        _ = try optionalIntValue(reader.take("limit"), "limit",
                                 range: 1...maximumCandidatePage)
        try reader.finish(unknownReason: "unknownMemoryField")
    }

    private static func validateCandidateResolve(_ payload: JSONValue?) throws {
        var reader = try reader(payload, required: ["id", "activate"],
                                unknownReason: "unknownMemoryField")
        _ = try uuidValue(reader.take("id") ?? .null, "id")
        _ = try booleanValue(reader.take("activate") ?? .null, "activate")
        try reader.finish(unknownReason: "unknownMemoryField")
    }

    private static func validateOrganizeStart(_ payload: JSONValue?) throws {
        var reader = try reader(payload, required: ["mode", "includeSemantic"],
                                unknownReason: "unknownMemoryField")
        _ = try enumValue(reader.take("mode") ?? .null, "mode", OrganizeMode.self)
        _ = try booleanValue(reader.take("includeSemantic") ?? .null, "includeSemantic")
        try reader.finish(unknownReason: "unknownMemoryField")
    }

    private static func validateOrganizeProposalRead(_ payload: JSONValue?) throws {
        var reader = try reader(payload, required: ["handle"],
                                unknownReason: "unknownMemoryField")
        _ = try handleValue(reader.take("handle") ?? .null, "handle")
        _ = try cursorValue(reader.take("cursor"))
        _ = try optionalIntValue(reader.take("limit"), "limit",
                                 range: 1...maximumOrganizeProposalPage)
        try reader.finish(unknownReason: "unknownMemoryField")
    }

    private static func validateOrganizeApply(_ payload: JSONValue?) throws {
        var reader = try reader(payload,
                                required: ["handle", "suggestionID", "batchID", "syncRevision"],
                                unknownReason: "unknownMemoryField")
        _ = try handleValue(reader.take("handle") ?? .null, "handle")
        _ = try uuidValue(reader.take("suggestionID") ?? .null, "suggestionID")
        _ = try uuidValue(reader.take("batchID") ?? .null, "batchID")
        _ = try int64Value(reader.take("syncRevision") ?? .null, "syncRevision")
        try reader.finish(unknownReason: "unknownMemoryField")
    }

    private static func validateCancel(_ payload: JSONValue?,
                                       unknownReason: String = "unknownMemoryField") throws {
        var reader = try reader(payload, required: ["operationReceiptID"],
                                unknownReason: unknownReason)
        _ = try receiptValue(reader.take("operationReceiptID") ?? .null,
                             "operationReceiptID")
        try reader.finish(unknownReason: "unknownMemoryField")
    }

    private static func validatePersonalizationGet(_ payload: JSONValue?) throws {
        var reader = try reader(payload, required: ["kind"],
                                unknownReason: "unknownPersonalizationField")
        _ = try enumValue(reader.take("kind") ?? .null, "kind", PersonalizationKind.self)
        _ = try optionalUUIDValue(reader.take("workspaceID"), "workspaceID")
        _ = try cursorValue(reader.take("revisionsCursor"), "revisionsCursor")
        _ = try optionalIntValue(reader.take("revisionsLimit"), "revisionsLimit",
                                 range: 1...maximumUsagePage)
        try reader.finish(unknownReason: "unknownPersonalizationField")
    }

    private static func validatePersonalizationRevisionRead(_ payload: JSONValue?) throws {
        var reader = try reader(payload, required: ["kind", "revision"],
                                unknownReason: "unknownPersonalizationField")
        _ = try enumValue(reader.take("kind") ?? .null, "kind", PersonalizationKind.self)
        _ = try optionalUUIDValue(reader.take("workspaceID"), "workspaceID")
        let revision = try int64Value(reader.take("revision") ?? .null, "revision")
        guard revision >= 1 else {
            throw ValidationFailure.invalid("invalidPayloadField:revision")
        }
        try reader.finish(unknownReason: "unknownPersonalizationField")
    }

    private static func validatePersonalizationSave(_ payload: JSONValue?) throws {
        var reader = try reader(payload, required: ["kind", "content"],
                                unknownReason: "unknownPersonalizationField")
        _ = try enumValue(reader.take("kind") ?? .null, "kind", PersonalizationKind.self)
        _ = try optionalUUIDValue(reader.take("workspaceID"), "workspaceID")
        _ = try personalizationContentValue(reader.take("content") ?? .null)
        try reader.finish(unknownReason: "unknownPersonalizationField")
    }

    private static func validatePersonalizationRollback(_ payload: JSONValue?) throws {
        var reader = try reader(payload, required: ["kind", "targetRevision"],
                                unknownReason: "unknownPersonalizationField")
        _ = try enumValue(reader.take("kind") ?? .null, "kind", PersonalizationKind.self)
        _ = try optionalUUIDValue(reader.take("workspaceID"), "workspaceID")
        let revision = try int64Value(reader.take("targetRevision") ?? .null,
                                      "targetRevision")
        guard revision >= 1 else {
            throw ValidationFailure.invalid("invalidPayloadField:targetRevision")
        }
        try reader.finish(unknownReason: "unknownPersonalizationField")
    }

    private static func validatePersonalizationAutomaticSet(_ payload: JSONValue?) throws {
        var reader = try reader(payload, required: ["kind", "enabled"],
                                unknownReason: "unknownPersonalizationField")
        _ = try enumValue(reader.take("kind") ?? .null, "kind", PersonalizationKind.self)
        _ = try optionalUUIDValue(reader.take("workspaceID"), "workspaceID")
        _ = try booleanValue(reader.take("enabled") ?? .null, "enabled")
        try reader.finish(unknownReason: "unknownPersonalizationField")
    }

    private static func validatePersonalizationGenerate(_ payload: JSONValue?) throws {
        var reader = try reader(payload, required: ["kind"],
                                unknownReason: "unknownPersonalizationField")
        _ = try enumValue(reader.take("kind") ?? .null, "kind", PersonalizationKind.self)
        _ = try optionalUUIDValue(reader.take("workspaceID"), "workspaceID")
        try reader.finish(unknownReason: "unknownPersonalizationField")
    }

    private static func validateContentRead(_ payload: JSONValue?) throws {
        var reader = try reader(payload,
                                required: ["handle", "offsetBytes", "maxBytes"],
                                unknownReason: "unknownContentField")
        _ = try handleValue(reader.take("handle") ?? .null, "handle")
        let offset = try int64Value(reader.take("offsetBytes") ?? .null, "offsetBytes")
        let maxBytes = try int64Value(reader.take("maxBytes") ?? .null, "maxBytes")
        guard offset >= 0,
              maxBytes >= 1,
              maxBytes <= Int64(maximumChunkBytes),
              offset <= Int64.max - maxBytes else {
            throw ValidationFailure.invalid("invalidChunkRange")
        }
        try reader.finish(unknownReason: "unknownContentField")
    }

    private static func validateUsageStatistics(_ payload: JSONValue?) throws {
        var reader = try reader(payload, unknownReason: "unknownUsageField")
        // The frozen usage contract names an invalid *present* dimension
        // explicitly (`invalidEnvelope reason=unknownDimension`) for bad
        // strings, wrong types and null; an omitted dimension defaults to
        // `total`. Other domains keep the generic enum-field taxonomy.
        if let rawDimension = reader.take("dimension") {
            guard case .string(let value) = rawDimension,
                  UsageDimension(rawValue: value) != nil else {
                throw ValidationFailure.invalid("unknownDimension")
            }
        }
        _ = try cursorValue(reader.take("cursor"))
        _ = try optionalIntValue(reader.take("limit"), "limit",
                                 range: 1...maximumUsagePage)
        try reader.finish(unknownReason: "unknownUsageField")
    }

    private static func validatePrivacyClear(_ payload: JSONValue?) throws {
        var reader = try reader(payload, required: ["confirmToken"],
                                unknownReason: "unknownPrivacyField")
        _ = try digestValue(reader.take("confirmToken") ?? .null, "confirmToken")
        try reader.finish(unknownReason: "unknownPrivacyField")
    }

    private static func isNull(_ value: JSONValue) -> Bool {
        if case .null = value { return true }
        return false
    }

    // MARK: - Canonical digest (floe.canonical-digest.v1)

    /// Type-tagged, length-prefixed SQL storage-class encoding. This is a pure
    /// encoder; the P1..P8 adapters read GRDB `DatabaseValue` storage classes
    /// inside their own transactions and pass the exact cases here. No CAST,
    /// COALESCE, delimiter join, date formatting or number formatting occurs.
    public enum CanonicalDigest {
        public enum Field: Sendable, Equatable {
            case null
            case integer(Int64)
            case real(Double)
            case text(String)
            case blob(Data)
        }

        public static let domainSettingsDefaults = "floe.settings-defaults.v2"
        public static let domainMemoryEntry = "floe.memory-entry.v3"
        public static let domainMemoryCandidate = "floe.memory-candidate.v1"
        public static let domainPersonalizationCursor = "floe.personalization-cursor.v1"
        public static let domainPersonalizationSource = "floe.personalization-source.v1"
        public static let domainPrivacyHistory = "floe.privacy-history.v3"
        public static let domainPrivacyModelConfiguration = "floe.privacy-modelconfig.v3"

        public static func fieldBytes(_ field: Field) -> Data {
            var data = Data()
            switch field {
            case .null:
                data.append(0x00)
            case .integer(let value):
                data.append(0x01)
                data.append(contentsOf: bigEndian(UInt64(bitPattern: value)))
            case .real(let value):
                data.append(0x02)
                data.append(contentsOf: bigEndian(value.bitPattern))
            case .text(let value):
                data.append(0x03)
                let bytes = Data(value.utf8)
                data.append(contentsOf: bigEndian(UInt32(bytes.count)))
                data.append(bytes)
            case .blob(let value):
                data.append(0x04)
                data.append(contentsOf: bigEndian(UInt32(value.count)))
                data.append(value)
            }
            return data
        }

        public static func record(_ fields: [Field]) -> Data {
            var data = Data()
            data.append(contentsOf: bigEndian(UInt32(fields.count)))
            for field in fields { data.append(fieldBytes(field)) }
            return data
        }

        /// `UTF-8(domain) || 0x00 || record* || UInt32BE(0)`.
        public static func stream(domain: String, records: [[Field]]) -> Data {
            var data = Data(domain.utf8)
            data.append(0x00)
            for record in records { data.append(self.record(record)) }
            data.append(contentsOf: bigEndian(UInt32(0)))
            return data
        }

        /// Returns `sha256:<64 lowercase hex>`.
        public static func token(domain: String, records: [[Field]]) -> String {
            let digest = SHA256.hash(data: stream(domain: domain, records: records))
            return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
        }

        /// Fixed-order single-row digest (one record + terminator).
        public static func rowToken(domain: String, fields: [Field]) -> String {
            token(domain: domain, records: [fields])
        }

        private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
            withUnsafeBytes(of: value.bigEndian) { Array($0) }
        }
    }

    // MARK: - Actual serialized page budget and content chunking

    public struct ContentHandle: Sendable, Equatable, Codable {
        public let handle: String
        public let bytes: Int

        public init(handle: String, bytes: Int) {
            self.handle = handle
            self.bytes = bytes
        }
    }

    public struct ContentChunk: Sendable, Equatable, Codable {
        public let chunk: String
        public let nextOffset: Int?
        public let totalBytes: Int
        public let done: Bool

        public init(chunk: String, nextOffset: Int?, totalBytes: Int, done: Bool) {
            self.chunk = chunk
            self.nextOffset = nextOffset
            self.totalBytes = totalBytes
            self.done = done
        }
    }

    public enum ContentBudget {
        /// Returns the actual serialized UTF-8 byte count of a chunk response.
        /// JSON escaping is included because the decoded `chunk` string is
        /// re-encoded with the same escaped wire rules.
        public static func encodedChunkResponseBytes(_ chunk: ContentChunk) -> Int {
            var object: [String: Any] = [
                "chunk": chunk.chunk,
                "totalBytes": chunk.totalBytes,
                "done": chunk.done,
            ]
            object["nextOffset"] = chunk.nextOffset ?? NSNull()
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object,
                                                         options: [.sortedKeys]) else {
                // Fail closed. A serializer failure must never look like a
                // zero-byte response that fits every page budget.
                return Int.max
            }
            return data.count
        }

        /// True when the complete encoded response fits the page budget.
        public static func fitsPageBudget(_ chunk: ContentChunk,
                                          pageBudget: Int = pageBudgetBytes) -> Bool {
            encodedChunkResponseBytes(chunk) <= pageBudget
        }

        /// Chunks UTF-8 content on scalar boundaries and caps the complete
        /// encoded response at the actual page budget (escape-aware). The
        /// requested `maxBytes` is an upper bound; the page budget wins.
        ///
        /// Work is bounded: the complete scalar boundaries inside the request
        /// window are discovered in one forward pass, then the largest prefix
        /// that fits the actual encoded budget is found with logarithmic
        /// probes through the real wire encoder. No prefix is re-serialized
        /// once per removed scalar.
        public static func chunk(_ content: String,
                                 offsetBytes: Int,
                                 maxBytes: Int,
                                 pageBudget: Int = pageBudgetBytes)
            -> Result<ContentChunk, ValidationFailure> {
            let bytes = Array(content.utf8)
            let total = bytes.count
            guard offsetBytes >= 0, offsetBytes <= total else {
                return .failure(.invalid("invalidChunkRange"))
            }
            guard maxBytes >= 1, maxBytes <= maximumChunkBytes else {
                return .failure(.invalid("invalidChunkRange"))
            }
            if offsetBytes == total {
                let response = ContentChunk(chunk: "", nextOffset: nil,
                                            totalBytes: total, done: true)
                // The terminal empty page is a page too: a budget smaller than
                // its encoded response must fail typed, not return oversize.
                guard fitsPageBudget(response, pageBudget: pageBudget) else {
                    return .failure(.invalid("invalidChunkRange"))
                }
                return .success(response)
            }
            // An offset inside a multi-byte scalar cannot name a valid chunk.
            if (bytes[offsetBytes] & 0xC0) == 0x80 {
                return .failure(.invalid("invalidChunkRange"))
            }
            // Never overflow when the offset already sits near Int.max.
            let limit = offsetBytes > total - maxBytes
                ? total
                : offsetBytes + maxBytes
            // Complete scalar boundaries inside the request window, built in
            // one forward pass. A partial trailing scalar is never a candidate
            // because `maxBytes` is an upper bound, not a promise.
            var boundaries: [Int] = []
            boundaries.reserveCapacity(min(maxBytes, total - offsetBytes))
            var cursor = offsetBytes
            while cursor < limit {
                var next = cursor + 1
                while next < total && (bytes[next] & 0xC0) == 0x80 {
                    next += 1
                }
                if next > limit { break }
                boundaries.append(next)
                cursor = next
            }
            guard !boundaries.isEmpty else {
                return .failure(.invalid("invalidChunkRange"))
            }
            func response(endingAt end: Int) -> ContentChunk {
                ContentChunk(
                    chunk: String(decoding: bytes[offsetBytes..<end], as: UTF8.self),
                    nextOffset: end < total ? end : nil,
                    totalBytes: total,
                    done: end == total
                )
            }
            // MAIN_TERMINAL_METADATA_BUDGET_FOLLOWUP_20261019 (RB1 integration):
            // a prefix that ends exactly at the content EOF is TERMINAL
            // (nextOffset null + done true), so its metadata can be SHORTER
            // than the penultimate non-terminal prefix — encoded size is not
            // strictly monotone at that final boundary. Probe the largest
            // available terminal candidate directly first; if it fits, it is
            // the answer. Otherwise the binary search runs over the strictly
            // monotone NON-TERMINAL prefix range only. This never exceeds the
            // budget and never loses data; it only stops the search from
            // leaving a fitting terminal page unselected.
            let last = boundaries.count - 1
            let lastIsTerminal = boundaries[last] == total
            if lastIsTerminal,
               fitsPageBudget(response(endingAt: boundaries[last]),
                              pageBudget: pageBudget) {
                return .success(response(endingAt: boundaries[last]))
            }
            // Every remaining candidate keeps `done:false` and a numeric
            // nextOffset, so longer prefixes strictly grow the encoded
            // response and the binary search is exact over this range.
            var low = 0
            var high = lastIsTerminal ? last - 1 : last
            while low <= high {
                let mid = low + (high - low) / 2
                if fitsPageBudget(response(endingAt: boundaries[mid]),
                                  pageBudget: pageBudget) {
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            guard high >= 0 else {
                return .failure(.invalid("invalidChunkRange"))
            }
            return .success(response(endingAt: boundaries[high]))
        }

        /// Byte length of `value` as a JSON string value, including the two
        /// surrounding quotes and all JSON escaping (quotes, backslashes,
        /// control characters and U+0000). Unicode is measured as its actual
        /// UTF-8 bytes. This is the same encoder used by the wire.
        public static func encodedJSONStringBytes(_ value: String) -> Int {
            (try? JSONSerialization.data(withJSONObject: value,
                                         options: [.fragmentsAllowed]))?.count ?? Int.max
        }

        /// Exact complete-response size when `metadataEncodedBytesWithEmptyContent`
        /// is the actual encoded response with the content string set to the
        /// empty string (`""`). Replacing that 2-byte empty string with the
        /// encoded value adds exactly `encodedJSONStringBytes(content) - 2`.
        /// No arbitrary constant or extra 16KiB inline cap is applied.
        public static func encodedInlineResponseBytes(
            metadataEncodedBytesWithEmptyContent: Int,
            content: String
        ) -> Int {
            guard metadataEncodedBytesWithEmptyContent >= 2 else { return Int.max }
            let encoded = encodedJSONStringBytes(content)
            guard encoded != Int.max else { return Int.max }
            let (sum, overflow) = (metadataEncodedBytesWithEmptyContent - 2)
                .addingReportingOverflow(encoded)
            return overflow ? Int.max : sum
        }

        /// Decides inline vs owned handle using the complete encoded response.
        public static func shouldInline(
            content: String,
            metadataEncodedBytesWithEmptyContent: Int,
            pageBudget: Int = pageBudgetBytes
        ) -> Bool {
            encodedInlineResponseBytes(
                metadataEncodedBytesWithEmptyContent: metadataEncodedBytesWithEmptyContent,
                content: content) <= pageBudget
        }
    }

    // MARK: - Closed enums

    public enum DefaultAgentMode: String, Sendable, Codable, CaseIterable {
        case human
        case approvalModel
        case fullControl
    }

    public enum RunningInputMode: String, Sendable, Codable, CaseIterable {
        case queue
        case steer
    }

    public enum MemoryScopeKind: String, Sendable, Codable, CaseIterable {
        case user
        case agent
        case workspace
        case task
    }

    public enum MemoryEntryStatus: String, Sendable, Codable, CaseIterable {
        case pending
        case active
        case rejected
        case superseded
    }

    public enum MemoryUpdateStatus: String, Sendable, Codable, CaseIterable {
        case active
        case superseded
    }

    public enum MemorySourceKind: String, Sendable, Codable, CaseIterable {
        case explicitUserRequest
        case automaticTurnReview
        case goalStepReview
        case planReview
    }

    public enum MemorySensitivity: String, Sendable, Codable, CaseIterable {
        case none
        case personal
        case authenticationSecret
    }

    public enum MemorySuggestionKind: String, Sendable, Codable, CaseIterable {
        case exactDuplicate
        case sameFactReplacement
        case possibleDuplicate
        case expired
        case missingOwnership
    }

    public enum CandidateStatus: String, Sendable, Codable, CaseIterable {
        case pending
        case activated
        case rejected
    }

    public enum CandidateOrigin: String, Sendable, Codable, CaseIterable {
        case explicitUserRequest
        case automaticTurnReview
        case goalStepReview
        case planReview
    }

    public enum OrganizeMode: String, Sendable, Codable, CaseIterable {
        case reviewFirst
        case modelManaged
    }

    public enum PersonalizationKind: String, Sendable, Codable, CaseIterable {
        case soul
        case userProfile
    }

    public enum PersonalizationSource: String, Sendable, Codable, CaseIterable {
        case automatic
        case oneClick
        case manual
        case rollback
    }

    public enum GenerateDraftReason: String, Sendable, Codable, CaseIterable {
        case activeSlotChanged
        case sourceChanged
        case both
    }

    public enum UsageDimension: String, Sendable, Codable, CaseIterable {
        case total
        case conversation
        case model
        case provider
    }

    public enum PrivacyCredentialAvailability: String, Sendable, Codable, CaseIterable {
        case available = "AVAILABLE"
        case needsConfiguration = "NEEDS_CONFIGURATION"
    }

    // MARK: - Closed scope / identity value types

    public struct FactIdentity: Sendable, Equatable, Codable {
        public let subjectKey: String
        public let attributeKey: String

        public init(subjectKey: String, attributeKey: String) {
            self.subjectKey = subjectKey
            self.attributeKey = attributeKey
        }
    }

    public struct MemoryScope: Sendable, Equatable, Codable {
        public let kind: MemoryScopeKind
        public let workspaceID: UUID?
        public let conversationID: UUID?

        public init(kind: MemoryScopeKind,
                    workspaceID: UUID? = nil,
                    conversationID: UUID? = nil) throws {
            switch kind {
            case .user, .agent:
                guard workspaceID == nil, conversationID == nil else {
                    throw ValidationFailure.invalid("invalidPayloadField:scope")
                }
            case .workspace:
                guard workspaceID != nil, conversationID == nil else {
                    throw ValidationFailure.invalid("invalidPayloadField:scope")
                }
            case .task:
                guard conversationID != nil, workspaceID == nil else {
                    throw ValidationFailure.invalid("invalidPayloadField:scope")
                }
            }
            self.kind = kind
            self.workspaceID = workspaceID
            self.conversationID = conversationID
        }

        private enum CodingKeys: String, CodingKey {
            case kind, workspaceID, conversationID
        }

        /// Decoding also enforces the closed ownership shape; a kind/identity
        /// combination that could not be constructed cannot enter via JSON.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(MemoryScopeKind.self, forKey: .kind)
            let workspaceID = try container.decodeIfPresent(
                UUID.self, forKey: .workspaceID)
            let conversationID = try container.decodeIfPresent(
                UUID.self, forKey: .conversationID)
            do {
                try self.init(kind: kind, workspaceID: workspaceID,
                              conversationID: conversationID)
            } catch {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: container,
                    debugDescription: "invalid memory scope shape")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(workspaceID, forKey: .workspaceID)
            try container.encode(conversationID, forKey: .conversationID)
        }
    }

    public struct Revision: Sendable, Equatable, Codable {
        public let resourceID: String
        public let version: String

        public init(resourceID: String, version: String) {
            self.resourceID = resourceID
            self.version = version
        }
    }

    /// Real V21 detach/lifecycle state, surfaced as the contract's nested
    /// `ownership` object rather than flattened fields.
    public struct Ownership: Sendable, Equatable, Codable {
        public let ownerDeletedAt: String?
        public let retainedUntil: String?
        public let originOwnerLabel: String?
        public let lastRecalledAt: String?
        public let recallCount: Int

        public init(ownerDeletedAt: String?, retainedUntil: String?,
                    originOwnerLabel: String?, lastRecalledAt: String?,
                    recallCount: Int) {
            self.ownerDeletedAt = ownerDeletedAt
            self.retainedUntil = retainedUntil
            self.originOwnerLabel = originOwnerLabel
            self.lastRecalledAt = lastRecalledAt
            self.recallCount = recallCount
        }
    }

    /// Persisted candidate evidence reference. `excerpt` is the stored
    /// redacted `sha256:<hex>` form, never a raw conversation excerpt.
    public struct MemoryEvidenceReference: Sendable, Equatable, Codable {
        public let id: UUID
        public let messageID: UUID
        public let excerpt: String

        public init(id: UUID, messageID: UUID, excerpt: String) {
            self.id = id
            self.messageID = messageID
            self.excerpt = excerpt
        }
    }

    public struct MemoryEntry: Sendable, Equatable, Codable {
        public let id: UUID
        public let scope: MemoryScope
        public let status: MemoryEntryStatus
        public let content: String
        public let confidence: Double
        public let importance: Double
        public let isPinned: Bool
        public let sourceKind: MemorySourceKind
        public let originConversationID: UUID?
        public let originWorkspaceID: UUID?
        public let factIdentity: FactIdentity?
        public let ownership: Ownership
        public let expiresAt: String?
        public let createdAt: String
        public let updatedAt: String
        public let revision: String

        public init(id: UUID, scope: MemoryScope, status: MemoryEntryStatus,
                    content: String, confidence: Double, importance: Double,
                    isPinned: Bool, sourceKind: MemorySourceKind,
                    originConversationID: UUID?, originWorkspaceID: UUID?,
                    factIdentity: FactIdentity?, ownership: Ownership,
                    expiresAt: String?, createdAt: String, updatedAt: String,
                    revision: String) {
            self.id = id
            self.scope = scope
            self.status = status
            self.content = content
            self.confidence = confidence
            self.importance = importance
            self.isPinned = isPinned
            self.sourceKind = sourceKind
            self.originConversationID = originConversationID
            self.originWorkspaceID = originWorkspaceID
            self.factIdentity = factIdentity
            self.ownership = ownership
            self.expiresAt = expiresAt
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.revision = revision
        }
    }

    public struct DefaultsValues: Sendable, Equatable, Codable {
        public let defaultAgentMode: DefaultAgentMode
        public let runningInputMode: RunningInputMode
        public let verifyFinalAnswer: Bool

        public init(defaultAgentMode: DefaultAgentMode = .human,
                    runningInputMode: RunningInputMode = .queue,
                    verifyFinalAnswer: Bool = false) {
            self.defaultAgentMode = defaultAgentMode
            self.runningInputMode = runningInputMode
            self.verifyFinalAnswer = verifyFinalAnswer
        }
    }

    public struct DefaultsExplicitness: Sendable, Equatable, Codable {
        public let defaultAgentMode: Bool
        public let runningInputMode: Bool
        public let verifyFinalAnswer: Bool

        public init(defaultAgentMode: Bool, runningInputMode: Bool,
                    verifyFinalAnswer: Bool) {
            self.defaultAgentMode = defaultAgentMode
            self.runningInputMode = runningInputMode
            self.verifyFinalAnswer = verifyFinalAnswer
        }
    }

    public struct DefaultsReply: Sendable, Equatable, Codable {
        public let values: DefaultsValues
        public let explicit: DefaultsExplicitness
        public let revision: String

        public init(values: DefaultsValues, explicit: DefaultsExplicitness,
                    revision: String) {
            self.values = values
            self.explicit = explicit
            self.revision = revision
        }
    }

    public struct MemoryListReply: Sendable, Equatable, Codable {
        public let entries: [MemoryEntry]
        public let nextCursor: String?

        public init(entries: [MemoryEntry], nextCursor: String?) {
            self.entries = entries
            self.nextCursor = nextCursor
        }
    }

    public struct MemoryMutationReply: Sendable, Equatable, Codable {
        public enum Status: String, Sendable, Codable {
            case added
            case duplicate
        }
        public let status: Status
        public let entry: MemoryEntry?
        public let existingID: UUID?

        public init(status: Status, entry: MemoryEntry?, existingID: UUID?) {
            self.status = status
            self.entry = entry
            self.existingID = existingID
        }
    }

    public struct MemoryUpdateReply: Sendable, Equatable, Codable {
        public let entry: MemoryEntry

        public init(entry: MemoryEntry) {
            self.entry = entry
        }
    }

    public struct MemoryDeleteReply: Sendable, Equatable, Codable {
        public let deleted: Bool
        public let tombstoned: Bool

        public init(deleted: Bool, tombstoned: Bool) {
            self.deleted = deleted
            self.tombstoned = tombstoned
        }
    }

    public struct MemoryBulkDeleteReply: Sendable, Equatable, Codable {
        public enum Result: String, Sendable, Codable {
            case applied
            case alreadyApplied
        }
        public let batchID: UUID
        public let result: Result
        public let deletedCount: Int
        public let replacedCount: Int
        public let appliedCount: Int

        public init(batchID: UUID, result: Result, deletedCount: Int,
                    replacedCount: Int, appliedCount: Int) {
            self.batchID = batchID
            self.result = result
            self.deletedCount = deletedCount
            self.replacedCount = replacedCount
            self.appliedCount = appliedCount
        }
    }

    public struct MemorySearchItem: Sendable, Equatable, Codable {
        public let id: UUID
        public let relevance: Double
        public let lexicalRank: Int?
        public let semanticRank: Int?
        public let semanticSimilarity: Double?
        public let current: MemoryEntry?
        public let deleted: Bool

        public init(id: UUID, relevance: Double, lexicalRank: Int?,
                    semanticRank: Int?, semanticSimilarity: Double?,
                    current: MemoryEntry?, deleted: Bool) {
            self.id = id
            self.relevance = relevance
            self.lexicalRank = lexicalRank
            self.semanticRank = semanticRank
            self.semanticSimilarity = semanticSimilarity
            self.current = current
            self.deleted = deleted
        }

        private enum CodingKeys: String, CodingKey {
            case id, relevance, lexicalRank, semanticRank, semanticSimilarity,
                 current, deleted
        }

        /// `current` is always present as an object or explicit null, because
        /// the contract distinguishes "current row" from "deleted between
        /// recall and the fresh read".
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(relevance, forKey: .relevance)
            try container.encode(lexicalRank, forKey: .lexicalRank)
            try container.encode(semanticRank, forKey: .semanticRank)
            try container.encode(semanticSimilarity, forKey: .semanticSimilarity)
            try container.encode(current, forKey: .current)
            try container.encode(deleted, forKey: .deleted)
        }
    }

    public struct MemorySearchSideEffects: Sendable, Equatable, Codable {
        public let lifecycleMaintained: Bool
        public let reinforcementPathExecuted: Bool
        public let reinforcedCount: Int?
        public let digestsRefreshed: Bool
        public let explanation: String

        public init(lifecycleMaintained: Bool = true,
                    reinforcementPathExecuted: Bool = true,
                    reinforcedCount: Int? = nil,
                    digestsRefreshed: Bool = true,
                    explanation: String = "the original API returns no per-item changesCount; an exact reinforced-row count is NOT reported or fabricated") {
            self.lifecycleMaintained = lifecycleMaintained
            self.reinforcementPathExecuted = reinforcementPathExecuted
            self.reinforcedCount = reinforcedCount
            self.digestsRefreshed = digestsRefreshed
            self.explanation = explanation
        }

        private enum CodingKeys: String, CodingKey {
            case lifecycleMaintained, reinforcementPathExecuted,
                 reinforcedCount, digestsRefreshed, explanation
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(lifecycleMaintained, forKey: .lifecycleMaintained)
            try container.encode(reinforcementPathExecuted,
                                 forKey: .reinforcementPathExecuted)
            try container.encode(reinforcedCount, forKey: .reinforcedCount)
            try container.encode(digestsRefreshed, forKey: .digestsRefreshed)
            try container.encode(explanation, forKey: .explanation)
        }
    }

    public struct MemorySearchReply: Sendable, Equatable, Codable {
        public let items: [MemorySearchItem]
        public let semantic: Bool
        public let sideEffects: MemorySearchSideEffects
        public let searchHandle: String?
        public let nextCursor: String?
        public let hasMore: Bool

        public init(items: [MemorySearchItem], semantic: Bool = false,
                    sideEffects: MemorySearchSideEffects = MemorySearchSideEffects(),
                    searchHandle: String?, nextCursor: String?, hasMore: Bool) {
            self.items = items
            self.semantic = semantic
            self.sideEffects = sideEffects
            self.searchHandle = searchHandle
            self.nextCursor = nextCursor
            self.hasMore = hasMore
        }
    }

    public struct MemoryCandidate: Sendable, Equatable, Codable {
        public let id: UUID
        public let scope: MemoryScope
        public let content: String
        public let confidence: Double
        public let stability: Double
        public let importance: Double
        public let sensitivity: MemorySensitivity
        public let origin: CandidateOrigin
        public let evidence: [MemoryEvidenceReference]
        public let conflictsWithEntryIDs: [UUID]
        public let reviewReason: String?
        public let sourceAttachmentID: UUID?
        public let sourceMIMEType: String?
        public let status: CandidateStatus
        public let expiresAt: String?
        public let createdAt: String
        public let updatedAt: String
        public let revision: String

        public init(id: UUID, scope: MemoryScope, content: String,
                    confidence: Double, stability: Double, importance: Double,
                    sensitivity: MemorySensitivity, origin: CandidateOrigin,
                    evidence: [MemoryEvidenceReference],
                    conflictsWithEntryIDs: [UUID],
                    reviewReason: String?, sourceAttachmentID: UUID?,
                    sourceMIMEType: String?, status: CandidateStatus,
                    expiresAt: String?, createdAt: String, updatedAt: String,
                    revision: String) {
            self.id = id
            self.scope = scope
            self.content = content
            self.confidence = confidence
            self.stability = stability
            self.importance = importance
            self.sensitivity = sensitivity
            self.origin = origin
            self.evidence = evidence
            self.conflictsWithEntryIDs = conflictsWithEntryIDs
            self.reviewReason = reviewReason
            self.sourceAttachmentID = sourceAttachmentID
            self.sourceMIMEType = sourceMIMEType
            self.status = status
            self.expiresAt = expiresAt
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.revision = revision
        }
    }

    public struct MemoryCandidatesReply: Sendable, Equatable, Codable {
        public let candidates: [MemoryCandidate]
        public let nextCursor: String?
        public let expiredSweepApplied: Bool

        public init(candidates: [MemoryCandidate], nextCursor: String?,
                    expiredSweepApplied: Bool) {
            self.candidates = candidates
            self.nextCursor = nextCursor
            self.expiredSweepApplied = expiredSweepApplied
        }
    }

    public struct MemoryCandidateResolveReply: Sendable, Equatable, Codable {
        public enum Status: String, Sendable, Codable {
            case activated
            case rejected
        }
        public let status: Status
        public let entry: MemoryEntry?

        public init(status: Status, entry: MemoryEntry?) {
            self.status = status
            self.entry = entry
        }
    }

    public struct MemoryOrganizeSuggestion: Sendable, Equatable, Codable {
        public let id: UUID
        public let kind: MemorySuggestionKind
        public let memoryIDs: [UUID]
        public let preferredMemoryID: UUID?
        public let reason: String
        public let canApplyAutomatically: Bool

        public init(id: UUID, kind: MemorySuggestionKind, memoryIDs: [UUID],
                    preferredMemoryID: UUID?, reason: String,
                    canApplyAutomatically: Bool) {
            self.id = id
            self.kind = kind
            self.memoryIDs = memoryIDs
            self.preferredMemoryID = preferredMemoryID
            self.reason = reason
            self.canApplyAutomatically = canApplyAutomatically
        }
    }

    public struct MemoryOrganizeEntrySummary: Sendable, Equatable, Codable {
        public let id: UUID
        public let scope: MemoryScope
        public let status: MemoryEntryStatus
        public let content: String
        public let factIdentity: FactIdentity?
        public let originConversationID: UUID?
        public let originWorkspaceID: UUID?
        public let updatedAt: String

        public init(id: UUID, scope: MemoryScope, status: MemoryEntryStatus,
                    content: String, factIdentity: FactIdentity?,
                    originConversationID: UUID?, originWorkspaceID: UUID?,
                    updatedAt: String) {
            self.id = id
            self.scope = scope
            self.status = status
            self.content = content
            self.factIdentity = factIdentity
            self.originConversationID = originConversationID
            self.originWorkspaceID = originWorkspaceID
            self.updatedAt = updatedAt
        }
    }

    public struct MemoryOrganizeAutoDelete: Sendable, Equatable, Codable {
        public enum Status: String, Sendable, Codable {
            case applied
            case none
            case staleRejected
        }
        public let status: Status
        public let batchID: UUID?

        public init(status: Status, batchID: UUID?) {
            self.status = status
            self.batchID = batchID
        }
    }

    /// Start-effect variant: the automatic-delete result also carries the
    /// exact stale ids so the caller can surface which rows changed.
    public struct MemoryOrganizeStartAutoDelete: Sendable, Equatable, Codable {
        public let status: MemoryOrganizeAutoDelete.Status
        public let batchID: UUID?
        public let staleIDs: [UUID]

        public init(status: MemoryOrganizeAutoDelete.Status, batchID: UUID?,
                    staleIDs: [UUID]) {
            self.status = status
            self.batchID = batchID
            self.staleIDs = staleIDs
        }
    }

    public struct MemoryOrganizeProposalReply: Sendable, Equatable, Codable {
        public let proposalID: UUID
        public let generatedAt: String
        public let scannedCount: Int
        public let suggestions: [MemoryOrganizeSuggestion]
        public let entries: [MemoryOrganizeEntrySummary]
        public let nextCursor: String?
        public let stale: Bool
        public let staleIDs: [UUID]
        public let autoDelete: MemoryOrganizeAutoDelete

        public init(proposalID: UUID, generatedAt: String, scannedCount: Int,
                    suggestions: [MemoryOrganizeSuggestion],
                    entries: [MemoryOrganizeEntrySummary], nextCursor: String?,
                    stale: Bool, staleIDs: [UUID],
                    autoDelete: MemoryOrganizeAutoDelete) {
            self.proposalID = proposalID
            self.generatedAt = generatedAt
            self.scannedCount = scannedCount
            self.suggestions = suggestions
            self.entries = entries
            self.nextCursor = nextCursor
            self.stale = stale
            self.staleIDs = staleIDs
            self.autoDelete = autoDelete
        }
    }

    public enum MemoryOrganizeSemanticUnavailableReason: String, Sendable,
        Codable, CaseIterable {
        case needsConfiguration
        case credentialUnavailable
        case transportUnavailable
        case modelError
        case invalidModelJSON
    }

    public struct MemoryOrganizeStartEffect: Sendable, Equatable, Codable {
        public enum Status: String, Sendable, Codable {
            case completed
        }

        public enum Semantic: Sendable, Equatable, Codable {
            case applied
            case skipped
            case unavailable(reason: MemoryOrganizeSemanticUnavailableReason)

            private enum CodingKeys: String, CodingKey {
                case applied, skipped, unavailable, reason
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if container.contains(.applied) { self = .applied; return }
                if container.contains(.skipped) { self = .skipped; return }
                if container.contains(.unavailable) {
                    let nested = try container.nestedContainer(
                        keyedBy: CodingKeys.self, forKey: .unavailable)
                    self = .unavailable(reason: try nested.decode(
                        MemoryOrganizeSemanticUnavailableReason.self,
                        forKey: .reason))
                    return
                }
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown semantic outcome"
                ))
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .applied:
                    try container.encode(true, forKey: .applied)
                case .skipped:
                    try container.encode(true, forKey: .skipped)
                case .unavailable(let reason):
                    var nested = container.nestedContainer(
                        keyedBy: CodingKeys.self, forKey: .unavailable)
                    try nested.encode(reason, forKey: .reason)
                }
            }
        }

        public let status: Status
        public let scannedCount: Int
        public let autoDeletedCount: Int
        public let pendingReviewCount: Int
        public let autoDelete: MemoryOrganizeStartAutoDelete
        public let proposalStale: Bool
        public let semantic: Semantic
        public let proposalHandle: String

        public init(scannedCount: Int, autoDeletedCount: Int,
                    pendingReviewCount: Int,
                    autoDelete: MemoryOrganizeStartAutoDelete,
                    proposalStale: Bool, semantic: Semantic,
                    proposalHandle: String) {
            self.status = .completed
            self.scannedCount = scannedCount
            self.autoDeletedCount = autoDeletedCount
            self.pendingReviewCount = pendingReviewCount
            self.autoDelete = autoDelete
            self.proposalStale = proposalStale
            self.semantic = semantic
            self.proposalHandle = proposalHandle
        }
    }

    public struct MemoryOrganizeApplyReply: Sendable, Equatable, Codable {
        public enum Result: String, Sendable, Codable {
            case applied
            case alreadyApplied
        }
        public let batchID: UUID
        public let result: Result
        public let deletedCount: Int

        public init(batchID: UUID, result: Result, deletedCount: Int) {
            self.batchID = batchID
            self.result = result
            self.deletedCount = deletedCount
        }
    }

    /// Closed union of the phases named by the two cancel commands. The
    /// per-command contract still decides which subset is legal.
    public enum OperationCancelPhase: String, Sendable, Codable, CaseIterable {
        case queued
        case scan
        case semantic
        case apply
        case resolving
        case streaming
        case committing
        case committed
    }

    public struct OperationCancelReply: Sendable, Equatable, Codable {
        public enum Status: String, Sendable, Codable {
            case canceled
            case completed
        }
        public let status: Status
        public let phase: OperationCancelPhase?

        public init(status: Status, phase: OperationCancelPhase?) {
            self.status = status
            self.phase = phase
        }
    }

    public struct PersonalizationRevisionMeta: Sendable, Equatable, Codable {
        public let id: UUID
        public let revision: Int
        public let source: PersonalizationSource
        public let isActive: Bool
        public let createdAt: String
        public let contentBytes: Int
        public let contentDigest: String

        public init(id: UUID, revision: Int, source: PersonalizationSource,
                    isActive: Bool, createdAt: String, contentBytes: Int,
                    contentDigest: String) {
            self.id = id
            self.revision = revision
            self.source = source
            self.isActive = isActive
            self.createdAt = createdAt
            self.contentBytes = contentBytes
            self.contentDigest = contentDigest
        }
    }

    public struct PersonalizationDocument: Sendable, Equatable, Codable {
        public let id: UUID
        public let kind: PersonalizationKind
        public let workspaceID: UUID?
        public let revision: Int
        public let source: PersonalizationSource
        public let evidenceDigest: String
        public let isActive: Bool
        public let createdAt: String
        public let contentBytes: Int
        public let contentDigest: String
        public let content: String?
        public let contentHandle: ContentHandle?

        public init(id: UUID, kind: PersonalizationKind, workspaceID: UUID?,
                    revision: Int, source: PersonalizationSource,
                    evidenceDigest: String, isActive: Bool, createdAt: String,
                    contentBytes: Int, contentDigest: String,
                    content: String?, contentHandle: ContentHandle?) throws {
            guard (content == nil) != (contentHandle == nil) else {
                throw ValidationFailure.invalid("contentProjection")
            }
            self.id = id
            self.kind = kind
            self.workspaceID = workspaceID
            self.revision = revision
            self.source = source
            self.evidenceDigest = evidenceDigest
            self.isActive = isActive
            self.createdAt = createdAt
            self.contentBytes = contentBytes
            self.contentDigest = contentDigest
            self.content = content
            self.contentHandle = contentHandle
        }

        private enum CodingKeys: String, CodingKey {
            case id, kind, workspaceID, revision, source, evidenceDigest,
                 isActive, createdAt, contentBytes, contentDigest, content,
                 contentHandle
        }

        /// Both projections are present; exactly one is null, so a consumer
        /// can tell inline content from an owned handle without inferring
        /// from absence.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(kind, forKey: .kind)
            try container.encode(workspaceID, forKey: .workspaceID)
            try container.encode(revision, forKey: .revision)
            try container.encode(source, forKey: .source)
            try container.encode(evidenceDigest, forKey: .evidenceDigest)
            try container.encode(isActive, forKey: .isActive)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encode(contentBytes, forKey: .contentBytes)
            try container.encode(contentDigest, forKey: .contentDigest)
            try container.encode(content, forKey: .content)
            try container.encode(contentHandle, forKey: .contentHandle)
        }

        /// Enforces the contract's "inline XOR owned handle" rule on decode
        /// as well as construction.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let id = try container.decode(UUID.self, forKey: .id)
            let kind = try container.decode(PersonalizationKind.self,
                                            forKey: .kind)
            let workspaceID = try container.decodeIfPresent(
                UUID.self, forKey: .workspaceID)
            let revision = try container.decode(Int.self, forKey: .revision)
            let source = try container.decode(PersonalizationSource.self,
                                              forKey: .source)
            let evidenceDigest = try container.decode(
                String.self, forKey: .evidenceDigest)
            let isActive = try container.decode(Bool.self, forKey: .isActive)
            let createdAt = try container.decode(String.self,
                                                 forKey: .createdAt)
            let contentBytes = try container.decode(Int.self,
                                                    forKey: .contentBytes)
            let contentDigest = try container.decode(String.self,
                                                     forKey: .contentDigest)
            let content = try container.decodeIfPresent(String.self,
                                                        forKey: .content)
            let contentHandle = try container.decodeIfPresent(
                ContentHandle.self, forKey: .contentHandle)
            do {
                try self.init(
                    id: id, kind: kind, workspaceID: workspaceID,
                    revision: revision, source: source,
                    evidenceDigest: evidenceDigest, isActive: isActive,
                    createdAt: createdAt, contentBytes: contentBytes,
                    contentDigest: contentDigest, content: content,
                    contentHandle: contentHandle)
            } catch {
                throw DecodingError.dataCorruptedError(
                    forKey: .content, in: container,
                    debugDescription: "content must be inline xor handle")
            }
        }
    }

    public struct PersonalizationCursor: Sendable, Equatable, Codable {
        public let automaticUpdatesEnabled: Bool
        public let lastGeneratedAt: String?
        public let completedRunsSinceUpdate: Int
        public let userMessagesSinceUpdate: Int
        public let updatedAt: String
        public let revision: String

        public init(automaticUpdatesEnabled: Bool, lastGeneratedAt: String?,
                    completedRunsSinceUpdate: Int,
                    userMessagesSinceUpdate: Int, updatedAt: String,
                    revision: String) {
            self.automaticUpdatesEnabled = automaticUpdatesEnabled
            self.lastGeneratedAt = lastGeneratedAt
            self.completedRunsSinceUpdate = completedRunsSinceUpdate
            self.userMessagesSinceUpdate = userMessagesSinceUpdate
            self.updatedAt = updatedAt
            self.revision = revision
        }
    }

    public struct PersonalizationGetReply: Sendable, Equatable, Codable {
        public let active: PersonalizationDocument?
        public let latestRevision: Int
        public let revisionsMeta: [PersonalizationRevisionMeta]
        public let cursor: PersonalizationCursor
        public let revisionToken: String
        public let revisionsNextCursor: String?

        public init(active: PersonalizationDocument?, latestRevision: Int,
                    revisionsMeta: [PersonalizationRevisionMeta],
                    cursor: PersonalizationCursor, revisionToken: String,
                    revisionsNextCursor: String?) {
            self.active = active
            self.latestRevision = latestRevision
            self.revisionsMeta = revisionsMeta
            self.cursor = cursor
            self.revisionToken = revisionToken
            self.revisionsNextCursor = revisionsNextCursor
        }

        private enum CodingKeys: String, CodingKey {
            case active, latestRevision, revisionsMeta, cursor, revisionToken,
                 revisionsNextCursor
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(active, forKey: .active)
            try container.encode(latestRevision, forKey: .latestRevision)
            try container.encode(revisionsMeta, forKey: .revisionsMeta)
            try container.encode(cursor, forKey: .cursor)
            try container.encode(revisionToken, forKey: .revisionToken)
            try container.encode(revisionsNextCursor,
                                 forKey: .revisionsNextCursor)
        }
    }

    public struct PersonalizationRevisionReply: Sendable, Equatable, Codable {
        public let document: PersonalizationDocument
    }

    public struct PersonalizationSaveReply: Sendable, Equatable, Codable {
        public let document: PersonalizationDocument
        public let revisionToken: String
        public let latestRevision: Int
    }

    public struct PersonalizationRollbackReply: Sendable, Equatable, Codable {
        public let document: PersonalizationDocument
        public let revisionToken: String
    }

    public struct PersonalizationAutomaticReply: Sendable, Equatable, Codable {
        public let cursor: PersonalizationCursor
    }

    public struct GeneratedPersonalizationDocument: Sendable, Equatable, Codable {
        public let id: UUID
        public let revision: Int
        public let source: PersonalizationSource
        public let isActive: Bool
        public let contentBytes: Int
        public let contentDigest: String
        public let createdAt: String

        public init(id: UUID, revision: Int, source: PersonalizationSource = .oneClick,
                    isActive: Bool, contentBytes: Int, contentDigest: String,
                    createdAt: String) {
            self.id = id
            self.revision = revision
            self.source = source
            self.isActive = isActive
            self.contentBytes = contentBytes
            self.contentDigest = contentDigest
            self.createdAt = createdAt
        }
    }

    /// `outcome` is explicit: UI must never render an inactive draft as the
    /// active document.
    public enum PersonalizationGenerateOutcome: Sendable, Equatable, Codable {
        case active
        case storedAsDraft(reason: GenerateDraftReason)

        private enum CodingKeys: String, CodingKey {
            case active, storedAsDraft, reason
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.active) {
                self = .active
                return
            }
            if container.contains(.storedAsDraft) {
                let nested = try container.nestedContainer(
                    keyedBy: CodingKeys.self, forKey: .storedAsDraft)
                self = .storedAsDraft(reason: try nested.decode(
                    GenerateDraftReason.self, forKey: .reason))
                return
            }
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "unknown generate outcome"
            ))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .active:
                try container.encode(true, forKey: .active)
            case .storedAsDraft(let reason):
                var nested = container.nestedContainer(
                    keyedBy: CodingKeys.self, forKey: .storedAsDraft)
                try nested.encode(reason, forKey: .reason)
            }
        }
    }

    public struct PersonalizationGenerateRoute: Sendable, Equatable, Codable {
        public let providerID: UUID
        public let modelID: UUID

        public init(providerID: UUID, modelID: UUID) {
            self.providerID = providerID
            self.modelID = modelID
        }
    }

    public struct PersonalizationSourceSnapshot: Sendable, Equatable, Codable {
        public let memoryCount: Int
        public let digest: String

        public init(memoryCount: Int, digest: String) {
            self.memoryCount = memoryCount
            self.digest = digest
        }
    }

    public struct PersonalizationGenerateCursor: Sendable, Equatable, Codable {
        public let revision: String
        public let countersPreserved: Bool

        public init(revision: String, countersPreserved: Bool) {
            self.revision = revision
            self.countersPreserved = countersPreserved
        }
    }

    public struct PersonalizationGenerateEffect: Sendable, Equatable, Codable {
        public enum Status: String, Sendable, Codable {
            case completed
        }

        public let status: Status
        public let outcome: PersonalizationGenerateOutcome
        public let document: GeneratedPersonalizationDocument
        public let revisionToken: String
        public let draftRevision: Int?
        public let route: PersonalizationGenerateRoute
        public let evidenceDigest: String
        public let sourceSnapshot: PersonalizationSourceSnapshot
        public let cursor: PersonalizationGenerateCursor

        public init(outcome: PersonalizationGenerateOutcome,
                    document: GeneratedPersonalizationDocument,
                    revisionToken: String, draftRevision: Int?,
                    route: PersonalizationGenerateRoute,
                    evidenceDigest: String,
                    sourceSnapshot: PersonalizationSourceSnapshot,
                    cursor: PersonalizationGenerateCursor) {
            self.status = .completed
            self.outcome = outcome
            self.document = document
            self.revisionToken = revisionToken
            self.draftRevision = draftRevision
            self.route = route
            self.evidenceDigest = evidenceDigest
            self.sourceSnapshot = sourceSnapshot
            self.cursor = cursor
        }
    }

    public struct UsageMetrics: Sendable, Equatable, Codable {
        public let inputTokens: Int
        public let outputTokens: Int
        public let totalTokens: Int
        public let runs: Int
        public let cacheReadTokens: Int?
        public let cacheWriteTokens: Int?
        public let reasoningTokens: Int?
        public let averageTokensPerSecond: Double?
        public let averageTimeToFirstTokenMs: Double?
        public let averageDurationMs: Double?

        public init(inputTokens: Int, outputTokens: Int, totalTokens: Int,
                    runs: Int, cacheReadTokens: Int? = nil,
                    cacheWriteTokens: Int? = nil, reasoningTokens: Int? = nil,
                    averageTokensPerSecond: Double? = nil,
                    averageTimeToFirstTokenMs: Double? = nil,
                    averageDurationMs: Double? = nil) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.totalTokens = totalTokens
            self.runs = runs
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.reasoningTokens = reasoningTokens
            self.averageTokensPerSecond = averageTokensPerSecond
            self.averageTimeToFirstTokenMs = averageTimeToFirstTokenMs
            self.averageDurationMs = averageDurationMs
        }

        private enum CodingKeys: String, CodingKey {
            case inputTokens, outputTokens, totalTokens, runs, cacheReadTokens,
                 cacheWriteTokens, reasoningTokens, averageTokensPerSecond,
                 averageTimeToFirstTokenMs, averageDurationMs
        }

        /// Nullable metrics encode explicit null ("not reported"), never 0
        /// and never an omitted key.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(inputTokens, forKey: .inputTokens)
            try container.encode(outputTokens, forKey: .outputTokens)
            try container.encode(totalTokens, forKey: .totalTokens)
            try container.encode(runs, forKey: .runs)
            try container.encode(cacheReadTokens, forKey: .cacheReadTokens)
            try container.encode(cacheWriteTokens, forKey: .cacheWriteTokens)
            try container.encode(reasoningTokens, forKey: .reasoningTokens)
            try container.encode(averageTokensPerSecond,
                                 forKey: .averageTokensPerSecond)
            try container.encode(averageTimeToFirstTokenMs,
                                 forKey: .averageTimeToFirstTokenMs)
            try container.encode(averageDurationMs, forKey: .averageDurationMs)
        }
    }

    public struct UsageDay: Sendable, Equatable, Codable {
        public let date: String
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheReadTokens: Int?
        public let cacheWriteTokens: Int?
        public let runs: Int
        public let totalTokens: Int

        public init(date: String, inputTokens: Int, outputTokens: Int,
                    cacheReadTokens: Int?, cacheWriteTokens: Int?, runs: Int,
                    totalTokens: Int) {
            self.date = date
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.runs = runs
            self.totalTokens = totalTokens
        }

        private enum CodingKeys: String, CodingKey {
            case date, inputTokens, outputTokens, cacheReadTokens,
                 cacheWriteTokens, runs, totalTokens
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(date, forKey: .date)
            try container.encode(inputTokens, forKey: .inputTokens)
            try container.encode(outputTokens, forKey: .outputTokens)
            try container.encode(cacheReadTokens, forKey: .cacheReadTokens)
            try container.encode(cacheWriteTokens, forKey: .cacheWriteTokens)
            try container.encode(runs, forKey: .runs)
            try container.encode(totalTokens, forKey: .totalTokens)
        }
    }

    /// Flattened per contract (`UsageBreakdownDTO`), not a nested metrics
    /// object.
    public struct UsageBreakdown: Sendable, Equatable, Codable {
        public let id: String
        public let label: String
        public let inputTokens: Int
        public let outputTokens: Int
        public let runs: Int
        public let cacheReadTokens: Int?
        public let cacheWriteTokens: Int?
        public let reasoningTokens: Int?
        public let averageTokensPerSecond: Double?
        public let averageTimeToFirstTokenMs: Double?
        public let averageDurationMs: Double?
        public let totalTokens: Int

        public init(id: String, label: String, inputTokens: Int,
                    outputTokens: Int, runs: Int, cacheReadTokens: Int?,
                    cacheWriteTokens: Int?, reasoningTokens: Int?,
                    averageTokensPerSecond: Double?,
                    averageTimeToFirstTokenMs: Double?,
                    averageDurationMs: Double?, totalTokens: Int) {
            self.id = id
            self.label = label
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.runs = runs
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.reasoningTokens = reasoningTokens
            self.averageTokensPerSecond = averageTokensPerSecond
            self.averageTimeToFirstTokenMs = averageTimeToFirstTokenMs
            self.averageDurationMs = averageDurationMs
            self.totalTokens = totalTokens
        }

        private enum CodingKeys: String, CodingKey {
            case id, label, inputTokens, outputTokens, runs, cacheReadTokens,
                 cacheWriteTokens, reasoningTokens, averageTokensPerSecond,
                 averageTimeToFirstTokenMs, averageDurationMs, totalTokens
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(label, forKey: .label)
            try container.encode(inputTokens, forKey: .inputTokens)
            try container.encode(outputTokens, forKey: .outputTokens)
            try container.encode(runs, forKey: .runs)
            try container.encode(cacheReadTokens, forKey: .cacheReadTokens)
            try container.encode(cacheWriteTokens, forKey: .cacheWriteTokens)
            try container.encode(reasoningTokens, forKey: .reasoningTokens)
            try container.encode(averageTokensPerSecond,
                                 forKey: .averageTokensPerSecond)
            try container.encode(averageTimeToFirstTokenMs,
                                 forKey: .averageTimeToFirstTokenMs)
            try container.encode(averageDurationMs, forKey: .averageDurationMs)
            try container.encode(totalTokens, forKey: .totalTokens)
        }
    }

    public struct UsageStatisticsReply: Sendable, Equatable, Codable {
        public let totals: UsageMetrics
        public let byDay: [UsageDay]?
        public let rows: [UsageBreakdown]?
        public let nextCursor: String?

        public init(totals: UsageMetrics, byDay: [UsageDay]?,
                    rows: [UsageBreakdown]?, nextCursor: String?) {
            self.totals = totals
            self.byDay = byDay
            self.rows = rows
            self.nextCursor = nextCursor
        }
    }

    public struct PrivacyHistorySummary: Sendable, Equatable, Codable {
        public let conversationCount: Int
        public let runCount: Int
        public let persistedGrantCount: Int
        public let inMemoryGrantCount: Int
        public let revision: String

        public init(conversationCount: Int, runCount: Int,
                    persistedGrantCount: Int, inMemoryGrantCount: Int,
                    revision: String) {
            self.conversationCount = conversationCount
            self.runCount = runCount
            self.persistedGrantCount = persistedGrantCount
            self.inMemoryGrantCount = inMemoryGrantCount
            self.revision = revision
        }
    }

    public struct PrivacyModelConfigurationSummary: Sendable, Equatable, Codable {
        public let providerCount: Int
        public let modelCount: Int
        public let secretReferenceCount: Int
        public let preferencesSyncRevision: Int
        public let revision: String

        public init(providerCount: Int, modelCount: Int,
                    secretReferenceCount: Int, preferencesSyncRevision: Int,
                    revision: String) {
            self.providerCount = providerCount
            self.modelCount = modelCount
            self.secretReferenceCount = secretReferenceCount
            self.preferencesSyncRevision = preferencesSyncRevision
            self.revision = revision
        }
    }

    public struct PrivacySnapshotFacts: Sendable, Equatable, Codable {
        public let dbSnapshotTransaction: Bool
        public let inMemoryGrantBracket: String
        public let retriesBounded: Int

        public init(dbSnapshotTransaction: Bool = true,
                    inMemoryGrantBracket: String = "g1==g2",
                    retriesBounded: Int = 3) {
            self.dbSnapshotTransaction = dbSnapshotTransaction
            self.inMemoryGrantBracket = inMemoryGrantBracket
            self.retriesBounded = retriesBounded
        }
    }

    public struct PrivacySummaryReply: Sendable, Equatable, Codable {
        public let history: PrivacyHistorySummary
        public let modelConfiguration: PrivacyModelConfigurationSummary
        public let credentialAvailability: PrivacyCredentialAvailability
        public let snapshot: PrivacySnapshotFacts

        public init(history: PrivacyHistorySummary,
                    modelConfiguration: PrivacyModelConfigurationSummary,
                    credentialAvailability: PrivacyCredentialAvailability,
                    snapshot: PrivacySnapshotFacts = PrivacySnapshotFacts()) {
            self.history = history
            self.modelConfiguration = modelConfiguration
            self.credentialAvailability = credentialAvailability
            self.snapshot = snapshot
        }
    }

    public enum PrivacyHistoryFailurePhase: String, Sendable, Codable,
        CaseIterable {
        case quiesce
        case deleteConversation
        case grantRevoke
        case drain
    }

    public struct PrivacyFailure: Sendable, Equatable, Codable {
        public let itemID: UUID?
        public let phase: PrivacyHistoryFailurePhase
        public let reason: String

        public init(itemID: UUID?, phase: PrivacyHistoryFailurePhase,
                    reason: String) {
            self.itemID = itemID
            self.phase = phase
            self.reason = reason
        }
    }

    public struct PrivacyRemaining: Sendable, Equatable, Codable {
        public let conversationCount: Int
        public let runCount: Int
        public let persistedGrantCount: Int
        public let inMemoryGrantCount: Int

        public init(conversationCount: Int, runCount: Int,
                    persistedGrantCount: Int, inMemoryGrantCount: Int) {
            self.conversationCount = conversationCount
            self.runCount = runCount
            self.persistedGrantCount = persistedGrantCount
            self.inMemoryGrantCount = inMemoryGrantCount
        }
    }

    public struct PrivacyHistoryEnumerated: Sendable, Equatable, Codable {
        public let conversations: Int
        public let runs: Int
        public let persistedGrants: Int
        public let inMemoryGrants: Int

        public init(conversations: Int, runs: Int, persistedGrants: Int,
                    inMemoryGrants: Int) {
            self.conversations = conversations
            self.runs = runs
            self.persistedGrants = persistedGrants
            self.inMemoryGrants = inMemoryGrants
        }
    }

    public struct PrivacyGrantDeletionCounts: Sendable, Equatable, Codable {
        public let persisted: Int
        public let inMemory: Int

        public init(persisted: Int, inMemory: Int) {
            self.persisted = persisted
            self.inMemory = inMemory
        }
    }

    public struct PrivacyHistoryDeleted: Sendable, Equatable, Codable {
        public let conversations: Int
        public let runs: Int
        public let grants: PrivacyGrantDeletionCounts

        public init(conversations: Int, runs: Int,
                    grants: PrivacyGrantDeletionCounts) {
            self.conversations = conversations
            self.runs = runs
            self.grants = grants
        }
    }

    public struct PrivacyHistoryClearReport: Sendable, Equatable, Codable {
        public let enumerated: PrivacyHistoryEnumerated
        public let deleted: PrivacyHistoryDeleted
        public let failures: [PrivacyFailure]
        public let partial: Bool
        public let remaining: PrivacyRemaining

        public init(enumerated: PrivacyHistoryEnumerated,
                    deleted: PrivacyHistoryDeleted,
                    failures: [PrivacyFailure], partial: Bool,
                    remaining: PrivacyRemaining) {
            self.enumerated = enumerated
            self.deleted = deleted
            self.failures = failures
            self.partial = partial
            self.remaining = remaining
        }
    }

    public enum PrivacyModelConfigFailurePhase: String, Sendable, Codable,
        CaseIterable {
        case secretReferenceChanged
        case enqueue
        case gatewayDelete
        case complete
        case record
    }

    public struct PrivacyProviderDeletionFailure: Sendable, Equatable,
        Codable {
        public let providerID: UUID
        public let phase: PrivacyModelConfigFailurePhase
        public let reason: String

        public init(providerID: UUID, phase: PrivacyModelConfigFailurePhase,
                    reason: String) {
            self.providerID = providerID
            self.phase = phase
            self.reason = reason
        }
    }

    public struct PrivacyModelConfigEnumerated: Sendable, Equatable, Codable {
        public let providers: Int
        public let models: Int
        public let secretReferences: Int

        public init(providers: Int, models: Int, secretReferences: Int) {
            self.providers = providers
            self.models = models
            self.secretReferences = secretReferences
        }
    }

    public struct PrivacyModelConfigDeleted: Sendable, Equatable, Codable {
        public let providers: Int
        public let models: Int
        public let secrets: Int

        public init(providers: Int, models: Int, secrets: Int) {
            self.providers = providers
            self.models = models
            self.secrets = secrets
        }
    }

    public struct PrivacyModelConfigRemaining: Sendable, Equatable, Codable {
        public let providerCount: Int
        public let modelCount: Int
        public let secretReferenceCount: Int

        public init(providerCount: Int, modelCount: Int,
                    secretReferenceCount: Int) {
            self.providerCount = providerCount
            self.modelCount = modelCount
            self.secretReferenceCount = secretReferenceCount
        }
    }

    public struct PrivacyModelConfigClearReport: Sendable, Equatable,
        Codable {
        public let enumerated: PrivacyModelConfigEnumerated
        public let deleted: PrivacyModelConfigDeleted
        public let deletionFailures: [PrivacyProviderDeletionFailure]
        public let preferencesReset: Bool
        public let preferencesSyncRevision: Int
        public let remaining: PrivacyModelConfigRemaining
        public let partial: Bool

        public init(enumerated: PrivacyModelConfigEnumerated,
                    deleted: PrivacyModelConfigDeleted,
                    deletionFailures: [PrivacyProviderDeletionFailure],
                    preferencesReset: Bool, preferencesSyncRevision: Int,
                    remaining: PrivacyModelConfigRemaining, partial: Bool) {
            self.enumerated = enumerated
            self.deleted = deleted
            self.deletionFailures = deletionFailures
            self.preferencesReset = preferencesReset
            self.preferencesSyncRevision = preferencesSyncRevision
            self.remaining = remaining
            self.partial = partial
        }
    }
}
