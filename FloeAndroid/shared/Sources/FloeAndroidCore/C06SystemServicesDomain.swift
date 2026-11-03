// SPDX-License-Identifier: MPL-2.0
//
// C06 — Android system services: one-shot location, read-only contacts,
// foreground NDEF reading and bounded Health Connect reads.
//
// The App host owns EVERY real platform call: LocationManager, the
// ContactsContract provider, the NFC adapter/reader-mode lifecycle and the
// Health Connect client. This Swift domain owns the closed wire vocabulary,
// permission/availability separation, task-owned stable paging cursors,
// bounded output shaping and the exact model-facing tool behaviour. It never
// invents a location, contact, tag or health record, and it never turns a
// missing permission, disabled radio or absent provider into an empty success.
//
// The platform port is executed by the trusted App host over the additive
// `floe.system/15` mailbox. Model tools use the ORIGINAL ToolCatalog /
// ToolRunnerRegistry lifecycle and the ordinary task approval path.
import Foundation
import FloeCore
import FloeTools

// MARK: - Wire bounds

public enum C06SystemWire {
    public static let version = 15
    public static let schema = "floe.system/15"
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 49_152
    public static let maximumOwnerBytes = 128
    public static let maximumCursorBytes = 512
    public static let cursorLifetime: TimeInterval = 600
    public static let maximumSnapshots = 4
    public static let maximumSnapshotBytes = 524_288
    public static let maximumPageCharacters = 3_800
    public static let pageHeaderReserve = 320

    public static let maximumContactScan = 500
    public static let defaultContactLimit = 50
    public static let maximumContactLimit = 50
    public static let maximumContactQueryCharacters = 120
    public static let maximumContactQueryBytes = 480
    public static let maximumContactLineCharacters = 700
    public static let maximumContactPhones = 3
    public static let maximumContactEmails = 3

    public static let maximumHealthDays = 366
    public static let maximumHealthRangeMillis: Int64 =
        Int64(maximumHealthDays) * 24 * 60 * 60 * 1_000
    public static let defaultHealthLimit = 50
    public static let maximumHealthLimit = 200
    public static let maximumHealthScanRows = 1_000
    public static let maximumHealthLineCharacters = 600

    public static let defaultNFCTimeoutSeconds = 20
    public static let minimumNFCTimeoutSeconds = 5
    public static let maximumNFCTimeoutSeconds = 55
    public static let maximumNFCRecords = 32
    public static let maximumNFCBytes = 32_768

    public static let locationTimeoutSeconds: TimeInterval = 15

    public static let modelTools = true
    public static let modelToolNames: [String] = [
        "location.current",
        "contacts.list",
        "nfc.readNDEF",
        "health.read",
    ]
}

// MARK: - Errors

public enum C06SystemErrorCode: String, Codable, Sendable, Equatable {
    case coreUnavailable
    case runtimeNotInstalled
    case staleEpoch
    case invalidRequest
    case unsupportedOperation
    case responseTooLarge
    case invalidOwner
    case temporaryOwnerCannotUseSystemServices
    case permissionNotDetermined
    case permissionDenied
    case permissionRestricted
    case foregroundRequired
    case locationServicesDisabled
    case locationUnavailable
    case locationTimedOut
    case contactsProviderAbsent
    case contactsUnavailable
    case contactsQueryFailed
    case nfcHardwareUnavailable
    case nfcDisabled
    case nfcBusy
    case nfcTagLost
    case nfcUnsupportedTag
    case nfcMalformedTag
    case nfcPayloadTooLarge
    case healthProviderAbsent
    case healthProviderUpdateRequired
    case healthPermissionDenied
    case healthUnsupportedMetric
    case healthQueryFailed
    case invalidCursor
    case cursorExpired
    case cursorMismatch
    case invalidQuery
    case invalidField
    case invalidLimit
    case invalidTimeout
    case invalidMetric
    case invalidMode
    case invalidAggregation
    case invalidRange
    case invalidDate
    case busy
    case timedOut
    case cancelled
    case hostUnavailable
    case invalidHostReply
    case internalFailure
}

public struct C06SystemError: Error, Sendable, Equatable {
    public let code: C06SystemErrorCode
    public let reason: String
    public let retryable: Bool
    public let detail: String?
    public let stage: String?

    public init(
        _ code: C06SystemErrorCode,
        _ reason: String? = nil,
        retryable: Bool = false,
        detail: String? = nil,
        stage: String? = nil
    ) {
        self.code = code
        self.reason = reason ?? code.rawValue
        self.retryable = retryable
        self.detail = detail.map { String($0.prefix(240)) }
        self.stage = stage.map { String($0.prefix(64)) }
    }

    public var exitStatus: Int32 {
        switch code {
        case .permissionNotDetermined, .permissionDenied, .permissionRestricted,
             .foregroundRequired, .temporaryOwnerCannotUseSystemServices, .locationServicesDisabled,
             .nfcDisabled:
            return 75
        case .nfcHardwareUnavailable, .healthProviderAbsent, .contactsProviderAbsent:
            return 77
        case .cancelled:
            return 130
        case .busy, .timedOut, .locationTimedOut:
            return 75
        default:
            return 1
        }
    }

    /// A compact model-facing line. Detail is bounded by the initializer and
    /// never contains raw contact/health payloads.
    public var modelLine: String {
        var value = "status=error code=\(code.rawValue) reason=\(reason)"
        if let detail, !detail.isEmpty { value += " detail=\(detail)" }
        if retryable { value += " retryable=true" }
        if let stage { value += " stage=\(stage)" }
        return value
    }
}

// MARK: - Platform availability

public enum C06SystemPermission: String, Sendable, Equatable, Codable {
    case notDetermined
    case granted
    case denied
    case restricted
    case unavailable

    public var canRead: Bool { self == .granted }
}

public struct C06LocationAvailability: Sendable, Equatable {
    public var hardwareAvailable: Bool
    public var servicesEnabled: Bool
    public var permission: C06SystemPermission
    public var precise: Bool

    public init(
        hardwareAvailable: Bool = false,
        servicesEnabled: Bool = false,
        permission: C06SystemPermission = .unavailable,
        precise: Bool = false
    ) {
        self.hardwareAvailable = hardwareAvailable
        self.servicesEnabled = servicesEnabled
        self.permission = permission
        self.precise = precise
    }

    public var available: Bool {
        hardwareAvailable && servicesEnabled && permission == .granted
    }

    public var precisionLabel: String {
        guard permission == .granted else { return "unknown" }
        return precise ? "precise" : "approximate"
    }
}

public struct C06ContactsAvailability: Sendable, Equatable {
    public var providerAvailable: Bool
    public var permission: C06SystemPermission

    public init(
        providerAvailable: Bool = false,
        permission: C06SystemPermission = .unavailable
    ) {
        self.providerAvailable = providerAvailable
        self.permission = permission
    }

    public var available: Bool { providerAvailable && permission == .granted }
}

public struct C06NFCAvailability: Sendable, Equatable {
    public var hardwareAvailable: Bool
    public var enabled: Bool

    public init(hardwareAvailable: Bool = false, enabled: Bool = false) {
        self.hardwareAvailable = hardwareAvailable
        self.enabled = enabled
    }

    public var available: Bool { hardwareAvailable }
    public var canRead: Bool { hardwareAvailable && enabled }
}

public enum C06HealthProviderStatus: String, Sendable, Equatable, Codable {
    case available
    case updateRequired
    case unavailable
}

public struct C06HealthAvailability: Sendable, Equatable {
    public var providerStatus: C06HealthProviderStatus
    /// Granular Health Connect READ grants per Android record type, keyed by
    /// the tool metric name. A metric missing from the set is not granted.
    public var grantedMetrics: Set<String>

    public init(
        providerStatus: C06HealthProviderStatus = .unavailable,
        grantedMetrics: Set<String> = []
    ) {
        self.providerStatus = providerStatus
        self.grantedMetrics = grantedMetrics
    }

    public var available: Bool { providerStatus == .available }
}

public struct C06SystemAvailabilitySnapshot: Sendable, Equatable {
    public var coreReady: Bool
    public var foreground: Bool
    public var revision: Int64
    public var epoch: UInt64?
    public var location: C06LocationAvailability
    public var contacts: C06ContactsAvailability
    public var nfc: C06NFCAvailability
    public var health: C06HealthAvailability

    public init(
        coreReady: Bool = false,
        foreground: Bool = false,
        revision: Int64 = 0,
        epoch: UInt64? = nil,
        location: C06LocationAvailability = C06LocationAvailability(),
        contacts: C06ContactsAvailability = C06ContactsAvailability(),
        nfc: C06NFCAvailability = C06NFCAvailability(),
        health: C06HealthAvailability = C06HealthAvailability()
    ) {
        self.coreReady = coreReady
        self.foreground = foreground
        self.revision = revision
        self.epoch = epoch
        self.location = location
        self.contacts = contacts
        self.nfc = nfc
        self.health = health
    }

    public var locationAvailable: Bool { coreReady && foreground && location.available }
    public var contactsAvailable: Bool { coreReady && foreground && contacts.available }
    public var nfcAvailable: Bool { coreReady && foreground && nfc.canRead }
    public var healthAvailable: Bool {
        coreReady && foreground && health.available && !health.grantedMetrics.isEmpty
    }
}

public final class C06SystemAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var value = C06SystemAvailabilitySnapshot()

    public init() {}

    public var snapshot: C06SystemAvailabilitySnapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    @discardableResult
    public func update(_ next: C06SystemAvailabilitySnapshot, epoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // A genuinely newer host projection wins. An equal revision for the
        // same epoch is idempotent; an older revision never regresses a live
        // permission or foreground transition.
        if let current = value.epoch, current == epoch, next.revision < value.revision {
            return false
        }
        if value.epoch != epoch {
            value = next
            value.epoch = epoch
            return true
        }
        if next.revision == value.revision {
            return true
        }
        value = next
        value.epoch = epoch
        return true
    }

    public func reset() {
        lock.lock(); value = C06SystemAvailabilitySnapshot(); lock.unlock()
    }
}

// MARK: - Owner

public struct C06SystemOwner: Sendable, Equatable {
    public let token: String
    public let nativeEpoch: UInt64
    public let taskID: UUID?
    public let conversationID: UUID?
    public let environmentID: String?
    public let temporary: Bool

    public init(
        token: String,
        nativeEpoch: UInt64,
        taskID: UUID? = nil,
        conversationID: UUID? = nil,
        environmentID: String? = nil,
        temporary: Bool = false
    ) throws {
        guard (8...C06SystemWire.maximumOwnerBytes).contains(token.utf8.count),
              token.unicodeScalars.allSatisfy({
                  $0.value < 128
                      && !$0.properties.isWhitespace
                      && !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw C06SystemError(.invalidOwner, "invalidOwnerToken")
        }
        guard nativeEpoch > 0 else {
            throw C06SystemError(.invalidOwner, "invalidNativeEpoch")
        }
        if temporary {
            throw C06SystemError(
                .temporaryOwnerCannotUseSystemServices,
                "temporaryOwnerCannotUseSystemServices"
            )
        }
        self.token = token
        self.nativeEpoch = nativeEpoch
        self.taskID = taskID
        self.conversationID = conversationID
        self.environmentID = environmentID
        self.temporary = temporary
    }

    public static func parse(_ value: Any?) throws -> C06SystemOwner {
        guard let object = value as? [String: Any],
              let token = c06SystemText(object["token"], limit: C06SystemWire.maximumOwnerBytes),
              let epoch = c06SystemUInt64(object["nativeEpoch"]) else {
            throw C06SystemError(.invalidOwner, "invalidOwner")
        }
        let taskID = (object["taskID"] as? String).flatMap(UUID.init(uuidString:))
        let conversationID = (object["conversationID"] as? String).flatMap(UUID.init(uuidString:))
        let environmentID = c06SystemText(object["environmentID"], limit: 128)
        let temporary = c06SystemBool(object["temporary"]) ?? false
        return try C06SystemOwner(
            token: token,
            nativeEpoch: epoch,
            taskID: taskID,
            conversationID: conversationID,
            environmentID: environmentID,
            temporary: temporary
        )
    }

    public func toJSON() -> [String: Any] {
        var value: [String: Any] = [
            "token": token,
            "nativeEpoch": nativeEpoch,
            "temporary": temporary,
        ]
        if let taskID { value["taskID"] = taskID.uuidString }
        if let conversationID { value["conversationID"] = conversationID.uuidString }
        if let environmentID { value["environmentID"] = environmentID }
        return value
    }
}

// MARK: - Contacts / health vocabulary

public enum C06ContactField: String, CaseIterable, Sendable, Equatable {
    case any
    case name
    case organization
    case phone
    case email

    public static func parse(_ raw: String?) throws -> C06ContactField {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .any
        }
        guard let value = C06ContactField(rawValue: raw) else {
            throw C06SystemError(.invalidField, "invalidContactField")
        }
        return value
    }
}

public enum C06HealthMetric: String, CaseIterable, Sendable, Equatable {
    case steps
    case activeEnergy
    case heartRate
    case restingHeartRate
    case sleep
    case workouts
    case activitySummary
    case bodyMass
    case oxygenSaturation
    case heartRateVariability

    public static func parse(_ raw: String?) throws -> C06HealthMetric {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = C06HealthMetric(rawValue: raw) else {
            throw C06SystemError(.invalidMetric, "invalidHealthMetric")
        }
        return value
    }

    /// Android Health Connect has no Activity Summary ring equivalent. The
    /// metric name is preserved so callers get an honest unsupported result
    /// instead of invented totals.
    public var supportedOnAndroid: Bool { self != .activitySummary }

    public var isQuantity: Bool {
        switch self {
        case .steps, .activeEnergy, .heartRate, .restingHeartRate, .bodyMass,
             .oxygenSaturation, .heartRateVariability:
            return true
        case .sleep, .workouts, .activitySummary:
            return false
        }
    }

    public var allowsSum: Bool { self == .steps || self == .activeEnergy }

    public var unit: String {
        switch self {
        case .steps: return "count"
        case .activeEnergy: return "kcal"
        case .heartRate, .restingHeartRate: return "count/min"
        case .sleep, .workouts: return "minutes"
        case .activitySummary: return "none"
        case .bodyMass: return "kg"
        case .oxygenSaturation: return "fraction"
        case .heartRateVariability: return "ms"
        }
    }
}

public enum C06HealthMode: String, Sendable, Equatable {
    case samples
    case aggregate

    public static func parse(_ raw: String?) throws -> C06HealthMode {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .samples
        }
        guard let value = C06HealthMode(rawValue: raw) else {
            throw C06SystemError(.invalidMode, "invalidHealthMode")
        }
        return value
    }
}

public enum C06HealthAggregation: String, CaseIterable, Sendable, Equatable {
    case sum
    case average
    case minimum
    case maximum
    case mostRecent

    public static func parse(_ raw: String?) throws -> C06HealthAggregation? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        guard let value = C06HealthAggregation(rawValue: raw) else {
            throw C06SystemError(.invalidAggregation, "invalidHealthAggregation")
        }
        return value
    }
}

// MARK: - Platform rows

public struct C06LocationFix: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let accuracyMeters: Double
    public let timestamp: Date
    public let precise: Bool
    public let provider: String

    public init(
        latitude: Double,
        longitude: Double,
        accuracyMeters: Double,
        timestamp: Date,
        precise: Bool,
        provider: String
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
        self.timestamp = timestamp
        self.precise = precise
        self.provider = provider
    }
}

public struct C06ContactRecord: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let organization: String
    public let phones: [String]
    public let emails: [String]

    public init(
        id: String,
        displayName: String,
        organization: String,
        phones: [String],
        emails: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.organization = organization
        self.phones = phones
        self.emails = emails
    }
}

public struct C06ContactScanPage: Sendable, Equatable {
    public let scanToken: String
    public let rows: [C06ContactRecord]
    public let totalCount: Int
    public let truncated: Bool
    public let nextOffset: Int?

    public init(
        scanToken: String,
        rows: [C06ContactRecord],
        totalCount: Int,
        truncated: Bool,
        nextOffset: Int?
    ) {
        self.scanToken = scanToken
        self.rows = rows
        self.totalCount = totalCount
        self.truncated = truncated
        self.nextOffset = nextOffset
    }
}

public struct C06NFCRecord: Sendable, Equatable {
    public let index: Int
    public let tnf: Int
    public let typeText: String
    public let identifier: String
    public let kind: String
    public let value: String?
    public let payloadBytes: Int
    public let payloadSHA256Prefix: String
    public let truncated: Bool

    public init(
        index: Int,
        tnf: Int,
        typeText: String,
        identifier: String,
        kind: String,
        value: String?,
        payloadBytes: Int,
        payloadSHA256Prefix: String,
        truncated: Bool
    ) {
        self.index = index
        self.tnf = tnf
        self.typeText = typeText
        self.identifier = identifier
        self.kind = kind
        self.value = value
        self.payloadBytes = payloadBytes
        self.payloadSHA256Prefix = payloadSHA256Prefix
        self.truncated = truncated
    }
}

public struct C06NFCReadResult: Sendable, Equatable {
    public let records: [C06NFCRecord]
    public let rawBytes: Int
    public let writable: Bool
    public let techList: [String]
    public let truncated: Bool
    public let elapsedMilliseconds: Int

    public init(
        records: [C06NFCRecord],
        rawBytes: Int,
        writable: Bool,
        techList: [String],
        truncated: Bool,
        elapsedMilliseconds: Int
    ) {
        self.records = records
        self.rawBytes = rawBytes
        self.writable = writable
        self.techList = techList
        self.truncated = truncated
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public struct C06HealthSampleRow: Sendable, Equatable {
    public let metric: String
    public let start: Date
    public let end: Date
    public let value: Double?
    public let unit: String
    /// Bounded structured detail for multi-sample records (for example
    /// `samples=42 bpmMin=58 bpmMax=131`, sleep stage counts, workout type).
    public let detail: String?

    public init(
        metric: String,
        start: Date,
        end: Date,
        value: Double?,
        unit: String,
        detail: String?
    ) {
        self.metric = metric
        self.start = start
        self.end = end
        self.value = value
        self.unit = unit
        self.detail = detail
    }
}

public struct C06HealthPage: Sendable, Equatable {
    public let rows: [C06HealthSampleRow]
    public let nextPageToken: String?
    public let totalScanned: Int
    public let truncated: Bool

    public init(
        rows: [C06HealthSampleRow],
        nextPageToken: String?,
        totalScanned: Int,
        truncated: Bool
    ) {
        self.rows = rows
        self.nextPageToken = nextPageToken
        self.totalScanned = totalScanned
        self.truncated = truncated
    }
}

public struct C06HealthAggregateResult: Sendable, Equatable {
    public let metric: String
    public let aggregation: String
    public let value: Double?
    public let unit: String
    public let recordCount: Int
    public let start: Date
    public let end: Date
    public let detail: String?

    public init(
        metric: String,
        aggregation: String,
        value: Double?,
        unit: String,
        recordCount: Int,
        start: Date,
        end: Date,
        detail: String?
    ) {
        self.metric = metric
        self.aggregation = aggregation
        self.value = value
        self.unit = unit
        self.recordCount = recordCount
        self.start = start
        self.end = end
        self.detail = detail
    }
}

// MARK: - Platform port

/// The trusted App lane executes these calls. Every method is bounded and
/// must throw the exact C06SystemError code rather than returning fake data.
public protocol C06SystemPlatformPort: Sendable {
    func locationFix(owner: C06SystemOwner, timeout: TimeInterval) async throws -> C06LocationFix
    func contactsScan(
        owner: C06SystemOwner,
        query: String?,
        field: C06ContactField,
        scanToken: String?,
        offset: Int,
        limit: Int
    ) async throws -> C06ContactScanPage
    func nfcRead(owner: C06SystemOwner, timeout: TimeInterval) async throws -> C06NFCReadResult
    func healthSamples(
        owner: C06SystemOwner,
        metric: C06HealthMetric,
        start: Date,
        end: Date,
        limit: Int,
        pageToken: String?
    ) async throws -> C06HealthPage
    func healthAggregate(
        owner: C06SystemOwner,
        metric: C06HealthMetric,
        aggregation: C06HealthAggregation,
        start: Date,
        end: Date
    ) async throws -> C06HealthAggregateResult
}

// MARK: - Text helpers

public enum C06SystemText {
    public static func quoted(_ raw: String, limit: Int) -> String {
        let scalars = raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.value != 0x7F
        }
        var view = String.UnicodeScalarView()
        for scalar in scalars.prefix(limit) { view.append(scalar) }
        let cleaned = String(view)
        let escaped = cleaned
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    public static func quotedList(_ values: [String], itemLimit: Int, totalLimit: Int) -> String {
        var rendered: [String] = []
        var characters = 0
        for value in values {
            let item = quoted(value, limit: itemLimit)
            if characters + item.count + 1 > totalLimit { break }
            rendered.append(item)
            characters += item.count + 1
        }
        return "[" + rendered.joined(separator: ",") + "]"
    }

    public static func boundedRow(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(max(0, limit - 3))) + "..."
    }

    public static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    public static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    public static func parseISO8601(_ raw: String) throws -> Date {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64 else {
            throw C06SystemError(.invalidDate, "invalidDate")
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return date }
        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        if let date = regular.date(from: trimmed) { return date }
        throw C06SystemError(.invalidDate, "invalidDate")
    }

    public static func format(_ value: Double) -> String {
        guard value.isFinite else { return "unavailable" }
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private func c06SystemText(_ value: Any?, limit: Int) -> String? {
    guard let string = value as? String, !string.isEmpty, string.utf8.count <= limit else {
        return nil
    }
    return string
}

private func c06SystemBool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    return nil
}

private func c06SystemInt(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
}

private func c06SystemInt64(_ value: Any?) -> Int64? {
    if let value = value as? Int64 { return value }
    if let value = value as? NSNumber { return value.int64Value }
    if let value = value as? String { return Int64(value) }
    return nil
}

private func c06SystemUInt64(_ value: Any?) -> UInt64? {
    if let value = value as? UInt64 { return value }
    if let value = value as? NSNumber { return value.uint64Value }
    if let value = value as? String { return UInt64(value) }
    return nil
}

// MARK: - Cursor

struct C06SystemCursorPayload: Sendable, Equatable {
    let kind: String
    let snapshotID: String
    let offset: Int
    let filterDigest: String
    let issuedAt: Int64
    let metric: String
    let mode: String
    let aggregation: String
}

enum C06SystemCursor {
    static func encode(
        kind: String,
        snapshotID: String,
        offset: Int,
        filterDigest: String,
        metric: String = "",
        mode: String = "",
        aggregation: String = "",
        issuedAt: Date = Date()
    ) throws -> String {
        let seconds = Int64(issuedAt.timeIntervalSince1970.rounded(.down))
        let signature = digest(
            kind: kind,
            snapshotID: snapshotID,
            offset: offset,
            filterDigest: filterDigest,
            metric: metric,
            mode: mode,
            aggregation: aggregation,
            issuedAt: seconds
        )
        let payload: [String: Any] = [
            "v": 1,
            "k": kind,
            "s": snapshotID,
            "o": offset,
            "f": filterDigest,
            "i": seconds,
            "m": metric,
            "md": mode,
            "ag": aggregation,
            "d": signature,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            throw C06SystemError(.internalFailure, "cursorEncodingFailed")
        }
        let token = "cs1." + base64URL(data)
        guard token.utf8.count <= C06SystemWire.maximumCursorBytes else {
            throw C06SystemError(.invalidRequest, "cursorTooLong")
        }
        return token
    }

    static func decode(_ raw: String) throws -> C06SystemCursorPayload {
        guard raw.utf8.count <= C06SystemWire.maximumCursorBytes else {
            throw C06SystemError(.invalidCursor, "cursorTooLong")
        }
        guard raw.hasPrefix("cs1.") else {
            throw C06SystemError(.invalidCursor, "invalidCursorPrefix")
        }
        guard let data = base64URLDecode(String(raw.dropFirst(4))),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              c06SystemInt(object["v"]) == 1,
              let kind = c06SystemText(object["k"], limit: 32),
              let snapshotID = c06SystemText(object["s"], limit: 64),
              let offset = c06SystemInt(object["o"]), offset >= 0,
              let filterDigest = c06SystemText(object["f"], limit: 64),
              let issuedAt = c06SystemInt64(object["i"]),
              let metric = object["m"] as? String,
              let mode = object["md"] as? String,
              let aggregation = object["ag"] as? String,
              let signature = c06SystemText(object["d"], limit: 64) else {
            throw C06SystemError(.invalidCursor, "invalidCursor")
        }
        let expected = digest(
            kind: kind,
            snapshotID: snapshotID,
            offset: offset,
            filterDigest: filterDigest,
            metric: metric,
            mode: mode,
            aggregation: aggregation,
            issuedAt: issuedAt
        )
        guard constantTimeEquals(expected, signature) else {
            throw C06SystemError(.invalidCursor, "cursorSignatureMismatch")
        }
        return C06SystemCursorPayload(
            kind: kind,
            snapshotID: snapshotID,
            offset: offset,
            filterDigest: filterDigest,
            issuedAt: issuedAt,
            metric: metric,
            mode: mode,
            aggregation: aggregation
        )
    }

    private static func digest(
        kind: String,
        snapshotID: String,
        offset: Int,
        filterDigest: String,
        metric: String,
        mode: String,
        aggregation: String,
        issuedAt: Int64
    ) -> String {
        let value = "\(kind)|\(snapshotID)|\(offset)|\(filterDigest)|\(metric)|\(mode)|\(aggregation)|\(issuedAt)"
        return String(FloeDigest.sha256Hex(Data(value.utf8)).prefix(32))
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base.append("=") }
        return Data(base64Encoded: base)
    }
}

// MARK: - Snapshot store

private struct C06SystemSnapshot {
    let id: String
    let ownerToken: String
    let nativeEpoch: UInt64
    let kind: String
    let filterDigest: String
    let lines: [String]
    let totalCount: Int
    let truncated: Bool
    let createdAt: Date

    var characters: Int { lines.reduce(0) { $0 + $1.count + 1 } }
}

private actor C06SystemSnapshotStore {
    private var snapshots: [String: C06SystemSnapshot] = [:]
    private var order: [String] = []

    func begin(
        owner: C06SystemOwner,
        kind: String,
        filterDigest: String,
        lines: [String],
        totalCount: Int,
        truncated: Bool
    ) throws -> String {
        prune()
        if snapshots.count >= C06SystemWire.maximumSnapshots {
            if let oldest = order.first {
                snapshots.removeValue(forKey: oldest)
                order.removeAll { $0 == oldest }
            }
        }
        let id = UUID().uuidString
        var kept: [String] = []
        var characters = 0
        for line in lines {
            if characters + line.count + 1 > C06SystemWire.maximumSnapshotBytes { break }
            kept.append(line)
            characters += line.count + 1
        }
        snapshots[id] = C06SystemSnapshot(
            id: id,
            ownerToken: owner.token,
            nativeEpoch: owner.nativeEpoch,
            kind: kind,
            filterDigest: filterDigest,
            lines: kept,
            totalCount: totalCount,
            truncated: truncated || kept.count < lines.count,
            createdAt: Date()
        )
        order.append(id)
        return id
    }

    func page(
        snapshotID: String,
        owner: C06SystemOwner,
        kind: String,
        filterDigest: String,
        offset: Int,
        limit: Int
    ) throws -> (lines: [String], nextOffset: Int?, totalCount: Int, truncated: Bool, snapshotTime: Date) {
        prune()
        guard let snapshot = snapshots[snapshotID] else {
            throw C06SystemError(.cursorExpired, "cursorSnapshotExpired")
        }
        guard snapshot.ownerToken == owner.token,
              snapshot.nativeEpoch == owner.nativeEpoch,
              snapshot.kind == kind else {
            throw C06SystemError(.cursorMismatch, "cursorOwnerMismatch")
        }
        guard snapshot.filterDigest == filterDigest else {
            throw C06SystemError(.cursorMismatch, "cursorFilterMismatch")
        }
        guard offset >= 0, offset < max(1, snapshot.lines.count) || (offset == 0 && snapshot.lines.isEmpty) else {
            throw C06SystemError(.invalidCursor, "cursorOffsetOutOfRange")
        }
        var lines: [String] = []
        var characters = 0
        var index = offset
        while index < snapshot.lines.count {
            let line = snapshot.lines[index]
            if !lines.isEmpty && characters + line.count + 1 > C06SystemWire.maximumPageCharacters {
                break
            }
            if lines.count >= limit { break }
            lines.append(line)
            characters += line.count + 1
            index += 1
        }
        let nextOffset = index < snapshot.lines.count ? index : nil
        return (
            lines,
            nextOffset,
            snapshot.totalCount,
            snapshot.truncated,
            snapshot.createdAt
        )
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-C06SystemWire.cursorLifetime)
        let expired = snapshots.values.filter { $0.createdAt < cutoff }.map(\.id)
        for id in expired {
            snapshots.removeValue(forKey: id)
            order.removeAll { $0 == id }
        }
    }
}

// MARK: - Domain

public actor C06SystemServicesDomain {
    public static let shared = C06SystemServicesDomain(
        portProvider: { _ in C06SystemHostMailboxPort() }
    )
    public static let availability = C06SystemAvailability()

    private let portProvider: @Sendable (UInt64) async throws -> any C06SystemPlatformPort
    private let snapshots = C06SystemSnapshotStore()

    public init(
        portProvider: @escaping @Sendable (UInt64) async throws -> any C06SystemPlatformPort
    ) {
        self.portProvider = portProvider
    }

    private func port(for owner: C06SystemOwner) async throws -> any C06SystemPlatformPort {
        let snapshot = C06SystemServicesDomain.availability.snapshot
        guard snapshot.coreReady, let epoch = snapshot.epoch else {
            throw C06SystemError(.runtimeNotInstalled, "runtimeNotInstalled", retryable: true)
        }
        guard epoch == owner.nativeEpoch else {
            throw C06SystemError(.staleEpoch, "staleNativeEpoch")
        }
        return try await portProvider(epoch)
    }

    public func applyHostAvailability(_ snapshot: C06SystemAvailabilitySnapshot, epoch: UInt64) {
        C06SystemServicesDomain.availability.update(snapshot, epoch: epoch)
    }

    public func refreshAvailability(epoch: UInt64) async {
        let current = C06SystemServicesDomain.availability.snapshot
        guard current.coreReady, current.epoch == epoch else {
            C06SystemServicesDomain.availability.reset()
            return
        }
    }

    private static func requireForeground() throws {
        guard C06SystemServicesDomain.availability.snapshot.foreground else {
            throw C06SystemError(.foregroundRequired, "foregroundRequired")
        }
    }

    private static func requireContacts() throws {
        let snapshot = C06SystemServicesDomain.availability.snapshot
        guard snapshot.contacts.providerAvailable else {
            throw C06SystemError(.contactsProviderAbsent, "contactsProviderAbsent")
        }
        switch snapshot.contacts.permission {
        case .granted: return
        case .notDetermined: throw C06SystemError(.permissionNotDetermined, "contactsPermissionNotDetermined")
        case .denied: throw C06SystemError(.permissionDenied, "contactsPermissionDenied")
        case .restricted: throw C06SystemError(.permissionRestricted, "contactsPermissionRestricted")
        case .unavailable: throw C06SystemError(.contactsUnavailable, "contactsUnavailable")
        }
    }

    private static func requireLocation() throws {
        let snapshot = C06SystemServicesDomain.availability.snapshot
        guard snapshot.location.hardwareAvailable else {
            throw C06SystemError(.locationUnavailable, "locationHardwareUnavailable")
        }
        guard snapshot.location.servicesEnabled else {
            throw C06SystemError(.locationServicesDisabled, "locationServicesDisabled")
        }
        switch snapshot.location.permission {
        case .granted: return
        case .notDetermined: throw C06SystemError(.permissionNotDetermined, "locationPermissionNotDetermined")
        case .denied: throw C06SystemError(.permissionDenied, "locationPermissionDenied")
        case .restricted: throw C06SystemError(.permissionRestricted, "locationPermissionRestricted")
        case .unavailable: throw C06SystemError(.locationUnavailable, "locationUnavailable")
        }
    }

    private static func requireNFC() throws {
        let snapshot = C06SystemServicesDomain.availability.snapshot
        guard snapshot.nfc.hardwareAvailable else {
            throw C06SystemError(.nfcHardwareUnavailable, "nfcHardwareUnavailable")
        }
        guard snapshot.nfc.enabled else {
            throw C06SystemError(.nfcDisabled, "nfcDisabled")
        }
    }

    private static func requireHealth(_ metric: C06HealthMetric) throws {
        let snapshot = C06SystemServicesDomain.availability.snapshot
        switch snapshot.health.providerStatus {
        case .available: break
        case .updateRequired: throw C06SystemError(.healthProviderUpdateRequired, "healthProviderUpdateRequired")
        case .unavailable: throw C06SystemError(.healthProviderAbsent, "healthProviderAbsent")
        }
        guard metric.supportedOnAndroid else {
            throw C06SystemError(
                .healthUnsupportedMetric,
                "healthMetricUnsupportedOnAndroid",
                detail: "Android Health Connect has no activity summary ring record"
            )
        }
        guard snapshot.health.grantedMetrics.contains(metric.rawValue) else {
            throw C06SystemError(
                .healthPermissionDenied,
                "healthPermissionDenied",
                detail: "metric=\(metric.rawValue)"
            )
        }
    }

    // MARK: Location

    public func locate(owner: C06SystemOwner) async throws -> C06LocationFix {
        try Self.requireForeground()
        try Self.requireLocation()
        let fix = try await port(for: owner).locationFix(
            owner: owner,
            timeout: C06SystemWire.locationTimeoutSeconds
        )
        guard fix.latitude.isFinite, fix.latitude >= -90, fix.latitude <= 90,
              fix.longitude.isFinite, fix.longitude >= -180, fix.longitude <= 180,
              fix.accuracyMeters >= 0 else {
            throw C06SystemError(.locationUnavailable, "invalidLocationFix")
        }
        return fix
    }

    // MARK: Contacts

    public struct ContactListResult: Sendable, Equatable {
        public let lines: [String]
        public let totalCount: Int
        public let returnedCount: Int
        public let hasMore: Bool
        public let nextCursor: String?
        public let pageCount: Int
        public let snapshotTime: Date
        public let scanned: Int?
        public let scanTruncated: Bool?
        public let truncatedRows: Int
        public let authorization: String
    }

    public func contactsList(
        owner: C06SystemOwner,
        query rawQuery: String?,
        field rawField: String?,
        limit rawLimit: Int?,
        cursor rawCursor: String?
    ) async throws -> ContactListResult {
        try Self.requireForeground()
        try Self.requireContacts()
        let plan = try Self.contactsPlan(query: rawQuery, field: rawField, limit: rawLimit, cursor: rawCursor)
        let filter = "q=\(plan.query ?? "")|field=\(plan.field.rawValue)|scan=\(C06SystemWire.maximumContactScan)"
        let filterDigest = String(FloeDigest.sha256Hex(Data(filter.utf8)).prefix(32))

        if let cursor = plan.cursor {
            let decoded = try C06SystemCursor.decode(cursor)
            guard decoded.kind == "contacts", decoded.filterDigest == filterDigest else {
                throw C06SystemError(.cursorMismatch, "cursorFilterMismatch")
            }
            guard Date().timeIntervalSince1970 - Double(decoded.issuedAt) <= C06SystemWire.cursorLifetime else {
                throw C06SystemError(.cursorExpired, "cursorExpired")
            }
            let page = try await snapshots.page(
                snapshotID: decoded.snapshotID,
                owner: owner,
                kind: "contacts",
                filterDigest: filterDigest,
                offset: decoded.offset,
                limit: plan.limit
            )
            let nextCursor: String? = page.nextOffset.flatMap {
                try? C06SystemCursor.encode(
                    kind: "contacts",
                    snapshotID: decoded.snapshotID,
                    offset: $0,
                    filterDigest: filterDigest
                )
            }
            return ContactListResult(
                lines: page.lines,
                totalCount: page.totalCount,
                returnedCount: page.lines.count,
                hasMore: page.nextOffset != nil,
                nextCursor: nextCursor,
                pageCount: max(1, decoded.offset / plan.limit + 1),
                snapshotTime: page.snapshotTime,
                scanned: nil,
                scanTruncated: nil,
                truncatedRows: page.lines.count < plan.limit && page.nextOffset != nil ? plan.limit - page.lines.count : 0,
                authorization: "granted"
            )
        }

        let platformPort = try await port(for: owner)
        var records: [C06ContactRecord] = []
        var scanToken: String?
        var offset = 0
        var total = 0
        var scanTruncated = false
        while records.count < C06SystemWire.maximumContactScan {
            let page = try await platformPort.contactsScan(
                owner: owner,
                query: plan.query,
                field: plan.field,
                scanToken: scanToken,
                offset: offset,
                limit: 50
            )
            scanToken = page.scanToken
            total = page.totalCount
            scanTruncated = page.truncated
            records.append(contentsOf: page.rows)
            guard let next = page.nextOffset, !page.rows.isEmpty else { break }
            offset = next
        }
        if records.count > C06SystemWire.maximumContactScan {
            records = Array(records.prefix(C06SystemWire.maximumContactScan))
            scanTruncated = true
        }
        let sorted = records.sorted(by: Self.contactOrder)
        let lines = sorted.map(Self.contactLine)
        let snapshotID = try await snapshots.begin(
            owner: owner,
            kind: "contacts",
            filterDigest: filterDigest,
            lines: lines,
            totalCount: total,
            truncated: scanTruncated
        )
        let page = try await snapshots.page(
            snapshotID: snapshotID,
            owner: owner,
            kind: "contacts",
            filterDigest: filterDigest,
            offset: 0,
            limit: plan.limit
        )
        let nextCursor: String? = page.nextOffset.flatMap {
            try? C06SystemCursor.encode(
                kind: "contacts",
                snapshotID: snapshotID,
                offset: $0,
                filterDigest: filterDigest
            )
        }
        return ContactListResult(
            lines: page.lines,
            totalCount: total,
            returnedCount: page.lines.count,
            hasMore: page.nextOffset != nil,
            nextCursor: nextCursor,
            pageCount: 1,
            snapshotTime: page.snapshotTime,
            scanned: records.count,
            scanTruncated: scanTruncated,
            truncatedRows: 0,
            authorization: "granted"
        )
    }

    private static func contactsPlan(
        query: String?,
        field: String?,
        limit: Int?,
        cursor: String?
    ) throws -> (query: String?, field: C06ContactField, limit: Int, cursor: String?) {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let literal = (trimmed?.isEmpty == true) ? nil : trimmed
        if let literal {
            guard literal.count <= C06SystemWire.maximumContactQueryCharacters,
                  literal.utf8.count <= C06SystemWire.maximumContactQueryBytes else {
                throw C06SystemError(.invalidQuery, "contactQueryTooLong")
            }
            guard !literal.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }) else {
                throw C06SystemError(.invalidQuery, "contactQueryControlCharacter")
            }
        }
        let parsedField = try C06ContactField.parse(field)
        let rowLimit = limit ?? C06SystemWire.defaultContactLimit
        guard (1...C06SystemWire.maximumContactLimit).contains(rowLimit) else {
            throw C06SystemError(.invalidLimit, "invalidContactLimit")
        }
        let trimmedCursor = cursor?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedCursor = (trimmedCursor?.isEmpty == true) ? nil : trimmedCursor
        if let parsedCursor {
            guard literal == nil, parsedField == .any else {
                throw C06SystemError(.invalidCursor, "cursorCannotBeCombinedWithQuery")
            }
            guard parsedCursor.utf8.count <= C06SystemWire.maximumCursorBytes else {
                throw C06SystemError(.invalidCursor, "cursorTooLong")
            }
        } else if literal == nil, parsedField != .any {
            throw C06SystemError(.invalidField, "contactFieldRequiresQuery")
        }
        return (literal, parsedField, rowLimit, parsedCursor)
    }

    private static func contactOrder(_ lhs: C06ContactRecord, _ rhs: C06ContactRecord) -> Bool {
        let left = C06SystemText.normalized(lhs.displayName)
        let right = C06SystemText.normalized(rhs.displayName)
        if left != right { return left < right }
        return lhs.id < rhs.id
    }

    private static func contactLine(_ record: C06ContactRecord) -> String {
        let line = [
            "id=\(C06SystemText.quoted(record.id, limit: 80))",
            "name=\(C06SystemText.quoted(record.displayName, limit: 120))",
            "organization=\(C06SystemText.quoted(record.organization, limit: 120))",
            "phones=\(C06SystemText.quotedList(record.phones, itemLimit: 40, totalLimit: 320))",
            "emails=\(C06SystemText.quotedList(record.emails, itemLimit: 120, totalLimit: 320))",
        ].joined(separator: " ")
        return C06SystemText.boundedRow(line, limit: C06SystemWire.maximumContactLineCharacters)
    }

    // MARK: NFC

    public func readNFC(owner: C06SystemOwner, timeoutSeconds: Int?) async throws -> C06NFCReadResult {
        try Self.requireForeground()
        try Self.requireNFC()
        let timeout = timeoutSeconds ?? C06SystemWire.defaultNFCTimeoutSeconds
        guard (C06SystemWire.minimumNFCTimeoutSeconds...C06SystemWire.maximumNFCTimeoutSeconds)
            .contains(timeout) else {
            throw C06SystemError(.invalidTimeout, "nfcTimeoutOutOfRange")
        }
        let result = try await port(for: owner).nfcRead(
            owner: owner,
            timeout: TimeInterval(timeout)
        )
        guard result.rawBytes >= 0, result.rawBytes <= C06SystemWire.maximumNFCBytes,
              result.records.count <= C06SystemWire.maximumNFCRecords else {
            throw C06SystemError(.nfcPayloadTooLarge, "nfcResultExceedsLimits")
        }
        return result
    }

    // MARK: Health

    public enum HealthReadResult: Sendable, Equatable {
        case samples(HealthSamplePageResult)
        case aggregate(C06HealthAggregateResult)
    }

    public struct HealthSamplePageResult: Sendable, Equatable {
        public let lines: [String]
        public let totalCount: Int
        public let returnedCount: Int
        public let hasMore: Bool
        public let nextCursor: String?
        public let pageCount: Int
        public let snapshotTime: Date
        public let truncatedRows: Int
        public let truncated: Bool
    }

    public func healthRead(
        owner: C06SystemOwner,
        metric rawMetric: String?,
        mode rawMode: String?,
        aggregation rawAggregation: String?,
        start rawStart: String?,
        end rawEnd: String?,
        limit rawLimit: Int?,
        cursor rawCursor: String?
    ) async throws -> HealthReadResult {
        try Self.requireForeground()
        let metric = try C06HealthMetric.parse(rawMetric)
        try Self.requireHealth(metric)
        let mode = try C06HealthMode.parse(rawMode)
        let aggregation = try C06HealthAggregation.parse(rawAggregation)
        let limit = rawLimit ?? C06SystemWire.defaultHealthLimit
        guard (1...C06SystemWire.maximumHealthLimit).contains(limit) else {
            throw C06SystemError(.invalidLimit, "invalidHealthLimit")
        }

        if let cursor = rawCursor?.trimmingCharacters(in: .whitespacesAndNewlines), !cursor.isEmpty {
            guard rawStart == nil, rawEnd == nil, mode == .samples else {
                throw C06SystemError(.invalidCursor, "cursorCannotBeCombinedWithRangeOrAggregate")
            }
            guard cursor.utf8.count <= C06SystemWire.maximumCursorBytes else {
                throw C06SystemError(.invalidCursor, "cursorTooLong")
            }
            let decoded = try C06SystemCursor.decode(cursor)
            guard decoded.kind == "health",
                  decoded.metric == metric.rawValue,
                  decoded.mode == mode.rawValue,
                  decoded.aggregation == (aggregation?.rawValue ?? "") else {
                throw C06SystemError(.cursorMismatch, "cursorMetricMismatch")
            }
            guard Date().timeIntervalSince1970 - Double(decoded.issuedAt) <= C06SystemWire.cursorLifetime else {
                throw C06SystemError(.cursorExpired, "cursorExpired")
            }
            let page = try await snapshots.page(
                snapshotID: decoded.snapshotID,
                owner: owner,
                kind: "health",
                filterDigest: decoded.filterDigest,
                offset: decoded.offset,
                limit: limit
            )
            let nextCursor: String? = page.nextOffset.flatMap {
                try? C06SystemCursor.encode(
                    kind: "health",
                    snapshotID: decoded.snapshotID,
                    offset: $0,
                    filterDigest: decoded.filterDigest,
                    metric: metric.rawValue,
                    mode: mode.rawValue,
                    aggregation: aggregation?.rawValue ?? ""
                )
            }
            return .samples(HealthSamplePageResult(
                lines: page.lines,
                totalCount: page.totalCount,
                returnedCount: page.lines.count,
                hasMore: page.nextOffset != nil,
                nextCursor: nextCursor,
                pageCount: max(1, decoded.offset / limit + 1),
                snapshotTime: page.snapshotTime,
                truncatedRows: 0,
                truncated: page.truncated
            ))
        }

        guard let rawStart, let rawEnd, !rawStart.isEmpty, !rawEnd.isEmpty else {
            throw C06SystemError(.invalidRange, "healthRangeRequired")
        }
        let start = try C06SystemText.parseISO8601(rawStart)
        let end = try C06SystemText.parseISO8601(rawEnd)
        guard end > start else {
            throw C06SystemError(.invalidRange, "healthRangeMustBePositive")
        }
        let rangeMillis = Int64((end.timeIntervalSince(start) * 1_000).rounded())
        guard rangeMillis > 0, rangeMillis <= C06SystemWire.maximumHealthRangeMillis else {
            throw C06SystemError(.invalidRange, "healthRangeTooLong")
        }

        if mode == .aggregate {
            guard let aggregation else {
                throw C06SystemError(.invalidAggregation, "healthAggregationRequired")
            }
            guard metric.isQuantity else {
                throw C06SystemError(
                    .unsupportedOperation,
                    "healthAggregateRequiresQuantityMetric",
                    detail: "metric=\(metric.rawValue)"
                )
            }
            guard aggregation != .sum || metric.allowsSum else {
                throw C06SystemError(
                    .invalidAggregation,
                    "healthSumLimitedToStepsAndActiveEnergy",
                    detail: "metric=\(metric.rawValue)"
                )
            }
            let result = try await port(for: owner).healthAggregate(
                owner: owner,
                metric: metric,
                aggregation: aggregation,
                start: start,
                end: end
            )
            if let value = result.value, !value.isFinite {
                throw C06SystemError(.healthQueryFailed, "invalidHealthAggregate")
            }
            return .aggregate(result)
        }

        let filterDigest = Self.healthFilterDigest(
            metric: metric,
            mode: mode,
            aggregation: aggregation,
            start: start,
            end: end
        )
        let platformPort = try await port(for: owner)
        var rows: [C06HealthSampleRow] = []
        var pageToken: String?
        var truncated = false
        var totalScanned = 0
        while rows.count < C06SystemWire.maximumHealthScanRows {
            let page = try await platformPort.healthSamples(
                owner: owner,
                metric: metric,
                start: start,
                end: end,
                limit: 50,
                pageToken: pageToken
            )
            rows.append(contentsOf: page.rows)
            totalScanned = page.totalScanned
            truncated = truncated || page.truncated
            guard let next = page.nextPageToken, !page.rows.isEmpty else { break }
            pageToken = next
        }
        if rows.count > C06SystemWire.maximumHealthScanRows {
            rows = Array(rows.prefix(C06SystemWire.maximumHealthScanRows))
            truncated = true
        }
        let lines = rows.map(Self.healthLine)
        let totalCount = max(rows.count, totalScanned)
        let snapshotID = try await snapshots.begin(
            owner: owner,
            kind: "health",
            filterDigest: filterDigest,
            lines: lines,
            totalCount: totalCount,
            truncated: truncated
        )
        let page = try await snapshots.page(
            snapshotID: snapshotID,
            owner: owner,
            kind: "health",
            filterDigest: filterDigest,
            offset: 0,
            limit: limit
        )
        let nextCursor: String? = page.nextOffset.flatMap {
            try? C06SystemCursor.encode(
                kind: "health",
                snapshotID: snapshotID,
                offset: $0,
                filterDigest: filterDigest,
                metric: metric.rawValue,
                mode: mode.rawValue,
                aggregation: aggregation?.rawValue ?? ""
            )
        }
        return .samples(HealthSamplePageResult(
            lines: page.lines,
            totalCount: totalCount,
            returnedCount: page.lines.count,
            hasMore: page.nextOffset != nil,
            nextCursor: nextCursor,
            pageCount: 1,
            snapshotTime: page.snapshotTime,
            truncatedRows: truncated ? max(0, totalScanned - rows.count) : 0,
            truncated: truncated || page.truncated
        ))
    }

    private static func healthFilterDigest(
        metric: C06HealthMetric,
        mode: C06HealthMode,
        aggregation: C06HealthAggregation?,
        start: Date?,
        end: Date?
    ) -> String {
        var filter = "metric=\(metric.rawValue)|mode=\(mode.rawValue)"
            + "|agg=\(aggregation?.rawValue ?? "none")"
        if let start { filter += "|start=\(C06SystemText.iso8601(start))" }
        if let end { filter += "|end=\(C06SystemText.iso8601(end))" }
        return String(FloeDigest.sha256Hex(Data(filter.utf8)).prefix(32))
    }

    private static func healthLine(_ row: C06HealthSampleRow) -> String {
        var line = "start=\(C06SystemText.iso8601(row.start))"
            + " end=\(C06SystemText.iso8601(row.end))"
            + " metric=\(row.metric)"
        if let value = row.value {
            line += " value=\(C06SystemText.format(value)) unit=\(row.unit)"
        } else {
            line += " unit=\(row.unit)"
        }
        if let detail = row.detail, !detail.isEmpty {
            line += " " + String(detail.prefix(320))
        }
        return C06SystemText.boundedRow(line, limit: C06SystemWire.maximumHealthLineCharacters)
    }
}

// MARK: - Tool owner / output helpers

func c06SystemToolOwner(_ context: ToolContext) throws -> C06SystemOwner {
    guard !context.temporaryReadOnly, !context.publicWebOnly else {
        throw C06SystemError(
            .temporaryOwnerCannotUseSystemServices,
            "temporaryOwnerCannotUseSystemServices"
        )
    }
    let snapshot = C06SystemServicesDomain.availability.snapshot
    guard snapshot.coreReady, let epoch = snapshot.epoch else {
        throw C06SystemError(.runtimeNotInstalled, "runtimeNotInstalled", retryable: true)
    }
    guard snapshot.foreground else {
        throw C06SystemError(.foregroundRequired, "foregroundRequired")
    }
    return try C06SystemOwner(
        token: "tool." + context.runID.uuidString,
        nativeEpoch: epoch,
        taskID: context.conversationID,
        conversationID: context.conversationID,
        environmentID: context.environmentID
    )
}

private func c06SystemFailure(_ error: C06SystemError) -> ToolExecutionOutput {
    ToolExecutionOutput(digesting: error.modelLine, exitStatus: error.exitStatus)
}

private func c06SystemFailure(_ error: FloeError) -> ToolExecutionOutput {
    ToolExecutionOutput(
        digesting: "status=error code=invalidRequest reason=\(error.localizedDescription)",
        exitStatus: 1
    )
}

// MARK: - location.current

public struct C06LocationCurrentTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public init() {}
    }

    public static let name = "location.current"
    public static let toolDescription = """
    Request ONE current Android location fix through the system location \
    provider after the user granted location access. Returns latitude, \
    longitude, reported horizontal accuracy, timestamp and whether the fix is \
    precise or approximate. The app must be in the foreground; access is \
    requested by the System Services screen, never by this tool. There is no \
    continuous, background or historical tracking, and a denied permission, \
    disabled location service or unavailable provider is a distinct honest \
    error. A reported accuracy is evidence, not a promise of precision.
    """
    public static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let domain: C06SystemServicesDomain
    public init(domain: C06SystemServicesDomain = .shared) {
        self.domain = domain
    }

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        do {
            try context.cancellation.throwIfCancelled()
            let owner = try c06SystemToolOwner(context)
            let fix = try await domain.locate(owner: owner)
            try context.cancellation.throwIfCancelled()
            let value = "status=ok capability=location"
                + " latitude=\(C06SystemText.format(fix.latitude))"
                + " longitude=\(C06SystemText.format(fix.longitude))"
                + " accuracyMeters=\(C06SystemText.format(fix.accuracyMeters))"
                + " timestamp=\(C06SystemText.iso8601(fix.timestamp))"
                + " precision=\(fix.precise ? "precise" : "approximate")"
                + " provider=\(C06SystemText.quoted(fix.provider, limit: 40))"
                + " backgroundTracking=false"
            return ToolExecutionOutput(digesting: value)
        } catch let error as C06SystemError {
            return c06SystemFailure(error)
        } catch let error as FloeError {
            return c06SystemFailure(error)
        }
    }
}

// MARK: - contacts.list

public struct C06ContactsListTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var query: String?
        public var field: String?
        public var limit: Int?
        public var cursor: String?

        public init(
            query: String? = nil,
            field: String? = nil,
            limit: Int? = nil,
            cursor: String? = nil
        ) {
            self.query = query
            self.field = field
            self.limit = limit
            self.cursor = cursor
        }
    }

    public static let name = "contacts.list"
    public static let toolDescription = """
    Search or list the user's Android contacts after Contacts read access was \
    granted. Returns only contact identifier, display name, organization and up \
    to three phone numbers/e-mail addresses per row. Search is literal text \
    across name, organization, phone or e-mail; there is no query language or \
    predicate injection, and field requires a query. The first call scans at \
    most 500 contacts; scanTruncated reports contacts beyond that bound. Pages \
    are task-owned stable snapshots: limit defaults to 50 (maximum 50); pass \
    nextCursor back as cursor to continue the same snapshot (cursor calls omit \
    query and field). This tool is READ-ONLY: it never creates, edits, deletes, \
    exports, calls, messages or opens a URL. An empty authorized result is not \
    proof of denial, and a missing permission/provider is never reported as an \
    empty contact list.
    """
    public static let parametersJSON = #"""
    {"type":"object","properties":{"query":{"type":"string","maxLength":120,"description":"Literal search text. Omit to list contacts."},"field":{"type":"string","enum":["any","name","organization","phone","email"],"description":"Field to match; defaults to any."},"limit":{"type":"integer","minimum":1,"maximum":50,"description":"Rows per page; defaults to 50."},"cursor":{"type":"string","maxLength":512,"description":"Opaque nextCursor from a previous page of the same task."}},"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let domain: C06SystemServicesDomain
    public init(domain: C06SystemServicesDomain = .shared) {
        self.domain = domain
    }

    public func validate(_ args: Arguments) throws {
        let query = args.query?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let query, !query.isEmpty {
            guard query.count <= C06SystemWire.maximumContactQueryCharacters,
                  query.utf8.count <= C06SystemWire.maximumContactQueryBytes else {
                throw FloeError.validationFailed("query must be at most 120 characters")
            }
            guard !query.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }) else {
                throw FloeError.validationFailed("query must not contain control characters")
            }
        }
        if let field = args.field, !field.isEmpty {
            guard C06ContactField(rawValue: field) != nil else {
                throw FloeError.validationFailed("field must be one of: any, name, organization, phone, email")
            }
        }
        let limit = args.limit ?? C06SystemWire.defaultContactLimit
        guard (1...C06SystemWire.maximumContactLimit).contains(limit) else {
            throw FloeError.validationFailed("limit must be 1...50")
        }
        if let cursor = args.cursor, !cursor.isEmpty, cursor.utf8.count > C06SystemWire.maximumCursorBytes {
            throw FloeError.validationFailed("cursor is too long")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        do {
            try context.cancellation.throwIfCancelled()
            let owner = try c06SystemToolOwner(context)
            let page = try await domain.contactsList(
                owner: owner,
                query: args.query,
                field: args.field,
                limit: args.limit,
                cursor: args.cursor
            )
            try context.cancellation.throwIfCancelled()
            var header = "status=ok capability=contacts kind=contacts.list"
                + " count=\(page.returnedCount) totalCount=\(page.totalCount)"
                + " hasMore=\(page.hasMore) nextCursor=\(page.nextCursor ?? "none")"
                + " pageCount=\(page.pageCount)"
                + " snapshotTime=\(C06SystemText.iso8601(page.snapshotTime))"
                + " authorization=\(page.authorization) readOnly=true writeRequested=false"
                + " fields=name,organization,phone,email"
            if let scanned = page.scanned {
                header += " scanned=\(scanned) scanTruncated=\(page.scanTruncated ?? false)"
            }
            if page.totalCount == 0 { header += " emptyResult=true" }
            if page.truncatedRows > 0 { header += " truncatedRows=\(page.truncatedRows)" }
            let body = page.lines.isEmpty ? header : header + "\n" + page.lines.joined(separator: "\n")
            return ToolExecutionOutput(digesting: body)
        } catch let error as C06SystemError {
            return c06SystemFailure(error)
        } catch let error as FloeError {
            return c06SystemFailure(error)
        }
    }
}

// MARK: - nfc.readNDEF

public struct C06NFCReadTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var timeoutSeconds: Int?

        public init(timeoutSeconds: Int? = nil) {
            self.timeoutSeconds = timeoutSeconds
        }
    }

    public static let name = "nfc.readNDEF"
    public static let toolDescription = """
    Scan ONE NFC tag in the foreground and return its bounded NDEF records \
    (text, URI, MIME and preserved raw metadata). This is READ-ONLY: it never \
    writes or locks a tag, sends raw APDUs, emulates payment or opens/forwards \
    a URL. Requires NFC hardware that is enabled and the Floe app in the \
    foreground. A concurrent scan returns busy instead of stealing another \
    task's reader. Limits: one tag, at most 32 records / 32768 payload bytes \
    and a 5...55 second Floe session timeout (default 20). Tag removal, \
    unsupported technologies, malformed records and oversized payloads are \
    reported honestly; malformed records include only bounded prefixes and hashes.
    """
    public static let parametersJSON = #"{"type":"object","properties":{"timeoutSeconds":{"type":"integer","minimum":5,"maximum":55,"description":"Floe scan deadline in seconds; defaults to 20."}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.persistsPersonalData, .sendsDataToProvider]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let domain: C06SystemServicesDomain
    public init(domain: C06SystemServicesDomain = .shared) {
        self.domain = domain
    }

    public func validate(_ args: Arguments) throws {
        let timeout = args.timeoutSeconds ?? C06SystemWire.defaultNFCTimeoutSeconds
        guard (C06SystemWire.minimumNFCTimeoutSeconds...C06SystemWire.maximumNFCTimeoutSeconds)
            .contains(timeout) else {
            throw FloeError.validationFailed("timeoutSeconds must be 5...55")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        do {
            try context.cancellation.throwIfCancelled()
            let owner = try c06SystemToolOwner(context)
            let result = try await domain.readNFC(owner: owner, timeoutSeconds: args.timeoutSeconds)
            try context.cancellation.throwIfCancelled()
            var header = "status=ok capability=nfc kind=nfc.readNDEF"
                + " records=\(result.records.count) rawBytes=\(result.rawBytes)"
                + " writable=\(result.writable) truncated=\(result.truncated)"
                + " elapsedMs=\(result.elapsedMilliseconds)"
                + " tech=\(result.techList.prefix(8).joined(separator: ","))"
                + " readOnly=true writeRequested=false"
            if result.records.isEmpty && !result.truncated { header += " emptyTag=true" }
            let lines = result.records.map { record in
                var line = "index=\(record.index) tnf=\(record.tnf)"
                    + " type=\(C06SystemText.quoted(record.typeText, limit: 80))"
                    + " id=\(C06SystemText.quoted(record.identifier, limit: 80))"
                    + " kind=\(record.kind) payloadBytes=\(record.payloadBytes)"
                    + " payloadSHA256=\(record.payloadSHA256Prefix)"
                    + " truncated=\(record.truncated)"
                if let value = record.value {
                    line += " value=\(C06SystemText.quoted(value, limit: 320))"
                }
                return line
            }
            let body = lines.isEmpty ? header : header + "\n" + lines.joined(separator: "\n")
            return ToolExecutionOutput(digesting: body)
        } catch let error as C06SystemError {
            return c06SystemFailure(error)
        } catch let error as FloeError {
            return c06SystemFailure(error)
        }
    }
}

// MARK: - health.read

public struct C06HealthReadTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var metric: String?
        public var mode: String?
        public var aggregation: String?
        public var start: String?
        public var end: String?
        public var limit: Int?
        public var cursor: String?

        public init(
            metric: String? = nil,
            mode: String? = nil,
            aggregation: String? = nil,
            start: String? = nil,
            end: String? = nil,
            limit: Int? = nil,
            cursor: String? = nil
        ) {
            self.metric = metric
            self.mode = mode
            self.aggregation = aggregation
            self.start = start
            self.end = end
            self.limit = limit
            self.cursor = cursor
        }
    }

    public static let name = "health.read"
    public static let toolDescription = """
    Read a bounded, READ-ONLY slice of the user's Android Health Connect data \
    for ONE approved metric after granular system authorization. Approved \
    metrics: steps, activeEnergy, heartRate, restingHeartRate, sleep, workouts, \
    activitySummary, bodyMass, oxygenSaturation, heartRateVariability. \
    activitySummary has no Android Health Connect equivalent and returns an \
    explicit unsupported error rather than invented ring totals. Times are ISO \
    8601 UTC; start/end are required on the first call (maximum 366 days) and \
    each sample query includes records overlapping the requested interval. Use \
    mode=samples (default) for bounded rows with a task-owned stable cursor, or \
    mode=aggregate for one statistic on quantity metrics only. sum is limited to \
    steps and activeEnergy. Cursor continues the same snapshot and omits \
    start/end. Units are stated per row: count, kcal, count/min, minutes, kg, \
    oxygenSaturation fraction (0...1, converted from Health Connect percent) \
    and milliseconds. Health Connect does not turn a missing grant into fake \
    data: the specific metric permission, provider-update state and absent \
    provider are distinct errors. Sleep is sample-only.
    """
    public static let parametersJSON = #"""
    {"type":"object","properties":{"metric":{"type":"string","enum":["steps","activeEnergy","heartRate","restingHeartRate","sleep","workouts","activitySummary","bodyMass","oxygenSaturation","heartRateVariability"],"description":"One approved Health Connect metric."},"mode":{"type":"string","enum":["samples","aggregate"],"description":"samples returns bounded rows; aggregate returns one statistic for quantity metrics."},"aggregation":{"type":"string","enum":["sum","average","minimum","maximum","mostRecent"],"description":"Required only for mode=aggregate; sum is limited to steps and activeEnergy."},"start":{"type":"string","description":"ISO 8601 inclusive start. Required unless cursor is supplied."},"end":{"type":"string","description":"ISO 8601 exclusive end. Required unless cursor is supplied."},"limit":{"type":"integer","minimum":1,"maximum":200,"description":"Rows per page; defaults to 50."},"cursor":{"type":"string","maxLength":2048,"description":"Opaque nextCursor from a previous page of the same metric."}},"required":["metric"],"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.persistsPersonalData, .sendsDataToProvider]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let domain: C06SystemServicesDomain
    public init(domain: C06SystemServicesDomain = .shared) {
        self.domain = domain
    }

    public func validate(_ args: Arguments) throws {
        _ = try C06HealthMetric.parse(args.metric)
        _ = try C06HealthMode.parse(args.mode)
        _ = try C06HealthAggregation.parse(args.aggregation)
        let limit = args.limit ?? C06SystemWire.defaultHealthLimit
        guard (1...C06SystemWire.maximumHealthLimit).contains(limit) else {
            throw FloeError.validationFailed("limit must be 1...200")
        }
        if let start = args.start, !start.isEmpty {
            _ = try C06SystemText.parseISO8601(start)
        }
        if let end = args.end, !end.isEmpty {
            _ = try C06SystemText.parseISO8601(end)
        }
        if let cursor = args.cursor, !cursor.isEmpty,
           cursor.utf8.count > C06SystemWire.maximumCursorBytes {
            throw FloeError.validationFailed("cursor is too long")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        do {
            try context.cancellation.throwIfCancelled()
            let owner = try c06SystemToolOwner(context)
            let result = try await domain.healthRead(
                owner: owner,
                metric: args.metric,
                mode: args.mode,
                aggregation: args.aggregation,
                start: args.start,
                end: args.end,
                limit: args.limit,
                cursor: args.cursor
            )
            try context.cancellation.throwIfCancelled()
            switch result {
            case .aggregate(let aggregate):
                var value = "status=ok capability=health kind=health.read mode=aggregate"
                    + " metric=\(aggregate.metric) aggregation=\(aggregate.aggregation)"
                if let number = aggregate.value {
                    value += " value=\(C06SystemText.format(number))"
                } else {
                    value += " value=unavailable"
                }
                value += " unit=\(aggregate.unit)"
                value += aggregate.recordCount >= 0
                    ? " records=\(aggregate.recordCount)"
                    : " records=unavailable"
                value += " start=\(C06SystemText.iso8601(aggregate.start))"
                    + " end=\(C06SystemText.iso8601(aggregate.end))"
                if let detail = aggregate.detail, !detail.isEmpty {
                    value += " " + String(detail.prefix(320))
                }
                return ToolExecutionOutput(digesting: value)
            case .samples(let page):
                var header = "status=ok capability=health kind=health.read mode=samples"
                    + " count=\(page.returnedCount) totalCount=\(page.totalCount)"
                    + " hasMore=\(page.hasMore) nextCursor=\(page.nextCursor ?? "none")"
                    + " pageCount=\(page.pageCount)"
                    + " snapshotTime=\(C06SystemText.iso8601(page.snapshotTime))"
                    + " readOnly=true writeRequested=false"
                if page.totalCount == 0 { header += " emptyResult=true" }
                if page.truncated { header += " scanTruncated=true" }
                if page.truncatedRows > 0 { header += " truncatedRows=\(page.truncatedRows)" }
                let body = page.lines.isEmpty ? header : header + "\n" + page.lines.joined(separator: "\n")
                return ToolExecutionOutput(digesting: body)
            }
        } catch let error as C06SystemError {
            return c06SystemFailure(error)
        } catch let error as FloeError {
            return c06SystemFailure(error)
        }
    }
}
