import Foundation

/// One cryptex entry reported by the device. `cryptexd_installed_ddi` filters
/// the identifier itself; this type keeps the identifier explicit so the
/// removal planner can refuse anything except the DDI identifier even if a
/// future call site reports a broader list.
public struct BridgeDDICryptexEntry: Equatable, Sendable {
    public var identifier: String
    public var version: String?

    public init(identifier: String, version: String? = nil) {
        self.identifier = identifier
        self.version = version
    }
}

/// Trustworthy result of the cryptexd DDI query. A Bool cannot represent the
/// difference between "the device says absent" and "the query failed"; a
/// failed query must never become an absence claim.
public enum BridgeDDICryptexQuery: Equatable, Sendable {
    case absent
    case installed(BridgeDDICryptexEntry)
    /// The service is known not to be exposed by this OS. Callers may treat
    /// this as absence only on an install path that does not use cryptexd.
    case notApplicable(reason: String)
    case unknown(reason: String)

    public var installedEntry: BridgeDDICryptexEntry? {
        if case .installed(let entry) = self { return entry }
        return nil
    }

    public var summary: String {
        switch self {
        case .absent:
            return "absent"
        case .installed(let entry):
            return "installed:\(entry.identifier)"
        case .notApplicable(let reason):
            return "not-applicable:\(reason)"
        case .unknown(let reason):
            return "unknown:\(reason)"
        }
    }
}

/// One raw entry from the image mounter's `CopyDevices` before policy
/// normalization. `invalidEntry` is used for a null pointer or a node that is
/// not a dictionary; `image` with a nil type is used for a missing or
/// non-string `DiskImageType`.
public enum BridgeDDIImageObservation: Equatable, Sendable {
    case invalidEntry
    case image(diskImageType: String?, isMounted: Bool)
}

/// One normalized image type vocabulary for parsing, detection and planning.
/// Only a small known set is accepted; an unknown string is malformed service
/// output, not evidence that the entry is unrelated.
public enum BridgeDDIImagePolicy {
    /// Modest bound applied before iterating the service-owned array.
    public static let maximumDeviceEntries = 256
    public static let maximumTypeBytes = 64

    /// Developer images that this prototype may unmount.
    public static let developerTypes: Set<String> = ["developer", "personalized"]
    /// Known image types. `Cryptex` is a known unrelated type for this gate and
    /// is retained without ever being unmounted.
    public static let knownTypes: Set<String> = ["developer", "personalized", "cryptex"]

    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func canonical(_ normalized: String) -> String {
        switch normalized {
        case "developer":
            return "Developer"
        case "personalized":
            return "Personalized"
        case "cryptex":
            return "Cryptex"
        default:
            return normalized
        }
    }
}

/// Validates the raw `CopyDevices` entries and converts them into a definitive
/// query. A malformed array shape, entry, missing/empty type or unknown type is
/// unknown (fail closed), never a definitive empty list. This parser is used by
/// the host FFI adapter, so the same rules are exercised by the core checks.
public enum BridgeDDIImageQueryParser {
    public static var maximumDeviceEntries: Int {
        BridgeDDIImagePolicy.maximumDeviceEntries
    }

    public static func parse(_ observations: [BridgeDDIImageObservation]) -> BridgeDDIImageQuery {
        guard observations.count <= maximumDeviceEntries else {
            return .unknown(
                reason: "image-mounter returned more than \(maximumDeviceEntries) entries"
            )
        }
        var images: [BridgeDDIDeviceImage] = []
        images.reserveCapacity(observations.count)
        for (index, observation) in observations.enumerated() {
            switch observation {
            case .invalidEntry:
                return .unknown(reason: "image-mounter entry \(index) is not a usable dictionary")
            case .image(let rawType, let isMounted):
                guard let rawType,
                      rawType.utf8.count <= BridgeDDIImagePolicy.maximumTypeBytes,
                      let normalized = BridgeDDIImagePolicy.normalize(rawType) else {
                    return .unknown(
                        reason: "image-mounter entry \(index) has a missing, empty or oversized DiskImageType"
                    )
                }
                guard BridgeDDIImagePolicy.knownTypes.contains(normalized) else {
                    return .unknown(
                        reason: "image-mounter entry \(index) has an unrecognized DiskImageType"
                    )
                }
                images.append(
                    BridgeDDIDeviceImage(
                        diskImageType: BridgeDDIImagePolicy.canonical(normalized),
                        isMounted: isMounted
                    )
                )
            }
        }
        return .devices(images)
    }
}

/// One entry returned by the image mounter's `CopyDevices`. Type is the
/// authoritative field for deciding whether the entry is a developer image;
/// the mount path is not reported by this service.
public struct BridgeDDIDeviceImage: Equatable, Sendable {
    public var diskImageType: String
    public var isMounted: Bool

    public init(diskImageType: String, isMounted: Bool) {
        self.diskImageType = diskImageType
        self.isMounted = isMounted
    }

    public var normalizedDiskImageType: String {
        BridgeDDIImagePolicy.normalize(diskImageType) ?? ""
    }

    public var isDeveloperDiskImage: Bool {
        BridgeDDIImagePolicy.developerTypes.contains(normalizedDiskImageType)
    }
}

/// Trustworthy result of the image-mounter query. `devices([])` is a
/// definitive empty list; an unavailable or failed service is unknown.
public enum BridgeDDIImageQuery: Equatable, Sendable {
    case devices([BridgeDDIDeviceImage])
    case notApplicable(reason: String)
    case unknown(reason: String)

    public var deviceList: [BridgeDDIDeviceImage]? {
        if case .devices(let devices) = self { return devices }
        return nil
    }

    public var developerImages: [BridgeDDIDeviceImage] {
        deviceList?.filter(\.isDeveloperDiskImage) ?? []
    }

    public var hasDeveloperDiskImage: Bool {
        !developerImages.isEmpty
    }

    public var isDefinitive: Bool {
        if case .devices = self { return true }
        return false
    }

    public var summary: String {
        switch self {
        case .devices(let devices):
            if devices.isEmpty { return "devices:empty" }
            let entries = devices.prefix(16).map { "\($0.diskImageType):\($0.isMounted)" }
            return "devices:" + entries.joined(separator: ",")
        case .notApplicable(let reason):
            return "not-applicable:\(reason)"
        case .unknown(let reason):
            return "unknown:\(reason)"
        }
    }
}

public enum BridgeDDIPreStateDecision: Equatable, Sendable {
    case absent
    case alreadyMounted(reason: String)
    case unknown(reason: String)
}

public enum BridgeDDIRemovalPlan: Equatable, Sendable {
    case uninstallCryptex(identifier: String, version: String?)
    case unmountDeveloperImage(path: String, diskImageType: String)
    case alreadyAbsent
    case failClosed(reason: String)
}

/// Pure decision policy for the prototype-only DDI removal action and for the
/// hardened mount pre-state.
///
/// Both service views are required before an install may count as this app's
/// own mount. The only typed exception is a cryptexd service known not to be
/// exposed on a personalized-image OS (iOS versions before 26.4), where that
/// service is not part of the install path.
public enum BridgeDDIRemovalPolicy {
    public static let ddiCryptexIdentifier = "com.apple.MobileAsset.DDI"
    public static let personalizedMountPath = "/System/Developer"
    public static let legacyMountPath = "/Developer"

    /// `IdeviceError::ServiceNotFound` in the pinned v0.1.68 FFI.
    public static let serviceNotFoundCode: Int32 = 21

    /// Classifies a cryptexd connection/query error. A missing service is a
    /// typed not-applicable result only when the OS install path does not use
    /// cryptexd; every other error stays unknown.
    public static func cryptexQueryAfterServiceError(
        code: Int32,
        installMethod: BridgeDDIInstallMethod
    ) -> BridgeDDICryptexQuery {
        if code == serviceNotFoundCode && installMethod == .personalized {
            return .notApplicable(reason: "cryptexd is not exposed by this OS")
        }
        return .unknown(reason: "cryptexd query failed (code \(code))")
    }

    /// Decides whether an install may proceed and whether a successful mount
    /// can be attributed to this app. A pre-existing mount, an unknown query
    /// and an unexplained local readability all block an install claim.
    public static func classifyPreState(
        cryptex: BridgeDDICryptexQuery,
        image: BridgeDDIImageQuery,
        probeMounted: Bool,
        installMethod: BridgeDDIInstallMethod
    ) -> BridgeDDIPreStateDecision {
        if case .installed(let entry) = cryptex {
            return .alreadyMounted(reason: "cryptex \(entry.identifier) is already installed")
        }
        if image.hasDeveloperDiskImage {
            return .alreadyMounted(reason: "the image mounter already reports a developer image")
        }
        guard cryptexAbsenceIsTrustworthy(cryptex, installMethod: installMethod) else {
            return .unknown(reason: "the cryptex state could not be verified")
        }
        guard image.isDefinitive else {
            return .unknown(reason: "the image-mounter state could not be verified")
        }
        guard !probeMounted else {
            return .unknown(reason: "XCTest is readable but neither service reports a DDI")
        }
        return .absent
    }

    /// Plans the single scoped mutation. The cryptex identifier is the only
    /// cryptex this prototype may touch, with a nil version meaning all of its
    /// versions. An image removal is limited to the developer-image mount paths
    /// and only when the reported type is Developer or Personalized. Unknown
    /// or inconsistent state always fails closed before any call.
    public static func removalPlan(
        cryptex: BridgeDDICryptexQuery,
        image: BridgeDDIImageQuery,
        probeMounted: Bool,
        installMethod: BridgeDDIInstallMethod
    ) -> BridgeDDIRemovalPlan {
        guard image.isDefinitive else {
            return .failClosed(reason: "the image-mounter state is not trustworthy")
        }
        switch cryptex {
        case .unknown(let reason):
            return .failClosed(reason: "cryptex state unknown: \(reason)")
        case .notApplicable(let reason) where installMethod == .cryptex:
            return .failClosed(reason: "cryptexd is required on this OS but unavailable: \(reason)")
        case .installed(let entry):
            guard entry.identifier == ddiCryptexIdentifier else {
                return .failClosed(reason: "unexpected cryptex identifier \(entry.identifier)")
            }
            return .uninstallCryptex(identifier: ddiCryptexIdentifier, version: nil)
        case .absent, .notApplicable:
            break
        }

        if let personalized = image.developerImages.first(where: {
            $0.normalizedDiskImageType == "personalized"
        }) {
            return .unmountDeveloperImage(
                path: personalizedMountPath,
                diskImageType: personalized.diskImageType
            )
        }
        if let developer = image.developerImages.first(where: {
            $0.normalizedDiskImageType == "developer"
        }) {
            return .unmountDeveloperImage(
                path: legacyMountPath,
                diskImageType: developer.diskImageType
            )
        }
        guard !probeMounted else {
            return .failClosed(reason: "XCTest is readable but neither service reports a DDI")
        }
        return .alreadyAbsent
    }

    public static func cryptexAbsenceIsTrustworthy(
        _ query: BridgeDDICryptexQuery,
        installMethod: BridgeDDIInstallMethod
    ) -> Bool {
        switch query {
        case .absent:
            return true
        case .notApplicable:
            return installMethod == .personalized
        case .installed, .unknown:
            return false
        }
    }
}

/// Result of the one-shot atomic decision that lets a blocking worker enter a
/// device mutation.
public enum BridgeDDIMutationEntry: Equatable, Sendable {
    case entered
    case cancelledBeforeEntry
    case alreadyEntered
}

/// Small thread-safe cancellation/mutation gate shared by the owning Swift
/// Task and the blocking FFI worker thread. `cancel()` never waits for FFI and
/// the worker never holds the lock across a blocking call.
///
/// Ordering is explicit: the first `beginMutation()` wins, and a cancellation
/// recorded before that call prevents the mutation. A cancellation after entry
/// is reported to the worker but cannot abort the FFI call; the caller must
/// keep the worker inputs alive until it returns and must not claim success.
public final class BridgeDDIMutationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var entered = false

    public init() {}

    /// Records logical cancellation. Returns true when no mutation had entered
    /// yet, so the next `beginMutation()` must fail.
    @discardableResult
    public func cancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let cancelledBeforeEntry = !entered
        cancelled = true
        return cancelledBeforeEntry
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public var didEnterMutation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    /// One-shot decision. Exactly one caller can enter, and only when no
    /// cancellation was recorded first.
    public func beginMutation() -> BridgeDDIMutationEntry {
        lock.lock()
        defer { lock.unlock() }
        if entered { return .alreadyEntered }
        if cancelled { return .cancelledBeforeEntry }
        entered = true
        return .entered
    }
}

/// Lifetime of the single blocking DDI worker that owns the reflector, staged
/// pairing record and service connections. A rejected concurrent call must not
/// end or otherwise modify the live worker's lifetime.
public final class BridgeDDIWorkerLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    public init() {}

    @discardableResult
    public func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !active else { return false }
        active = true
        return true
    }

    public func end() {
        lock.lock()
        defer { lock.unlock() }
        active = false
    }

    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }
}

/// Shared cancellation result for a removal report. Logical cancellation always
/// wins over an outcome that would look like a completed operation; the
/// pre/post facts already stored remain as evidence.
public enum BridgeDDIRemovalCancellation {
    @discardableResult
    public static func apply(
        to report: inout BridgeDDIRemovalReport,
        gate: BridgeDDIMutationGate
    ) -> Bool {
        guard gate.isCancelled else { return false }
        report.outcome = .cancelled
        report.errorCode = "cancelled"
        report.errorMessage = report.mutationAttempted == true
            ? "Cancelled while the removal mutation was in flight; pre/post evidence is retained but no success is claimed."
            : "Cancelled before the removal mutation was entered; pre-state evidence is retained and no mutation was attempted."
        return true
    }
}

public enum BridgeDDIRemovalOutcome: String, Codable, Sendable, Equatable {
    case removed
    case alreadyAbsent = "already-absent"
    case preStateUnknown = "pre-state-unknown"
    case verificationFailed = "verification-failed"
    case failed
    case cancelled
}

/// Bounded, non-secret removal evidence. It records service state summaries and
/// timestamps only: no pairing record, token, raw device plist or credential
/// may be added to this type.
public struct BridgeDDIRemovalReport: Codable, Equatable, Sendable {
    public var schema: Int
    public var outcome: BridgeDDIRemovalOutcome
    public var startedAt: String
    public var finishedAt: String?
    public var durationSeconds: Double?
    public var generation: UInt64
    public var installMethod: String
    public var action: String
    /// Whether the blocking mutation FFI was entered. A cancellation after
    /// entry retains this flag and the pre/post evidence.
    public var mutationAttempted: Bool?
    public var cryptexIdentifier: String?
    public var cryptexVersion: String?
    public var preCryptex: String
    public var preImageState: String
    public var preImages: [String]
    public var preProbeMounted: Bool?
    public var postCryptex: String?
    public var postImageState: String?
    public var postImages: [String]?
    public var postProbeMounted: Bool?
    public var postXCTestReadable: Bool?
    public var remoteAbsent: Bool?
    public var localProbeAbsent: Bool?
    /// Who owns the reflector for this operation: not-started, reused,
    /// started-and-stopped, started-stop-pending.
    public var tunnel: String
    public var errorCode: String?
    public var errorMessage: String?
    public var notes: [String]

    public init(
        schema: Int = 1,
        outcome: BridgeDDIRemovalOutcome = .failed,
        startedAt: String = BridgeClock.timestamp(),
        finishedAt: String? = nil,
        durationSeconds: Double? = nil,
        generation: UInt64 = 0,
        installMethod: BridgeDDIInstallMethod,
        action: String = "none",
        mutationAttempted: Bool? = nil,
        cryptexIdentifier: String? = nil,
        cryptexVersion: String? = nil,
        preCryptex: String = "unknown",
        preImageState: String = "unknown",
        preImages: [String] = [],
        preProbeMounted: Bool? = nil,
        postCryptex: String? = nil,
        postImageState: String? = nil,
        postImages: [String]? = nil,
        postProbeMounted: Bool? = nil,
        postXCTestReadable: Bool? = nil,
        remoteAbsent: Bool? = nil,
        localProbeAbsent: Bool? = nil,
        tunnel: String = "not-started",
        errorCode: String? = nil,
        errorMessage: String? = nil,
        notes: [String] = []
    ) {
        self.schema = schema
        self.outcome = outcome
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationSeconds = durationSeconds
        self.generation = generation
        self.installMethod = installMethod.rawValue
        self.action = action
        self.mutationAttempted = mutationAttempted
        self.cryptexIdentifier = cryptexIdentifier
        self.cryptexVersion = cryptexVersion
        self.preCryptex = preCryptex
        self.preImageState = preImageState
        self.preImages = preImages
        self.preProbeMounted = preProbeMounted
        self.postCryptex = postCryptex
        self.postImageState = postImageState
        self.postImages = postImages
        self.postProbeMounted = postProbeMounted
        self.postXCTestReadable = postXCTestReadable
        self.remoteAbsent = remoteAbsent
        self.localProbeAbsent = localProbeAbsent
        self.tunnel = tunnel
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.notes = notes
    }

    /// A rejected concurrent removal call. It deliberately does not touch any
    /// live manager phase or report; the existing worker owns those inputs.
    public static func busy(
        generation: UInt64,
        installMethod: BridgeDDIInstallMethod
    ) -> BridgeDDIRemovalReport {
        BridgeDDIRemovalReport(
            outcome: .failed,
            finishedAt: BridgeClock.timestamp(),
            durationSeconds: 0,
            generation: generation,
            installMethod: installMethod,
            action: "busy",
            mutationAttempted: false,
            errorCode: "busy",
            errorMessage: "Another DDI operation is already running.",
            notes: ["concurrent call rejected; live worker state was not modified"]
        )
    }

    /// Writes one atomically replaced report. The size is bounded by the fixed
    /// fields above; callers must not append raw device output to `notes`.
    @discardableResult
    public static func write(_ report: BridgeDDIRemovalReport, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report) else { return false }
        do {
            try BridgeAtomicFile.write(data, to: url)
            return true
        } catch {
            BridgeLog.shared.append("ddi_removal_report_write_failed error=\(error.localizedDescription)")
            return false
        }
    }
}

public struct BridgeDDIRemovalGuardInput: Equatable, Sendable {
    public var autoStartEnabled: Bool
    public var engineRunning: Bool
    public var serviceRunning: Bool
    public var phaseActive: Bool
    public var oneShotDispatched: Bool
    public var engineEntryObserved: Bool
    public var terminalFault: Bool
    public var ddiWorkerBusy: Bool
    public var pairingImported: Bool

    public init(
        autoStartEnabled: Bool = false,
        engineRunning: Bool = false,
        serviceRunning: Bool = false,
        phaseActive: Bool = false,
        oneShotDispatched: Bool = false,
        engineEntryObserved: Bool = false,
        terminalFault: Bool = false,
        ddiWorkerBusy: Bool = false,
        pairingImported: Bool = false
    ) {
        self.autoStartEnabled = autoStartEnabled
        self.engineRunning = engineRunning
        self.serviceRunning = serviceRunning
        self.phaseActive = phaseActive
        self.oneShotDispatched = oneShotDispatched
        self.engineEntryObserved = engineEntryObserved
        self.terminalFault = terminalFault
        self.ddiWorkerBusy = ddiWorkerBusy
        self.pairingImported = pairingImported
    }
}

public enum BridgeDDIRemovalGuardDecision: Equatable, Sendable {
    case allowed
    case refused(code: String)

    public var isAllowed: Bool {
        self == .allowed
    }

    public var refusalCode: String? {
        if case .refused(let code) = self { return code }
        return nil
    }
}

/// Pure guard for the prototype removal action. It never mutates anything and
/// is exercised directly by the host checks.
public enum BridgeDDIRemovalGuard {
    public static let terminalFaultCode = "terminal-fault"
    public static let oneShotCode = "one-shot-dispatched"
    public static let workerBusyCode = "ddi-worker-busy"
    public static let engineActiveCode = "engine-active"
    public static let autoStartCode = "auto-start-enabled"
    public static let pairingCode = "pairing-required"

    public static func decide(_ input: BridgeDDIRemovalGuardInput) -> BridgeDDIRemovalGuardDecision {
        if input.terminalFault { return .refused(code: terminalFaultCode) }
        if input.oneShotDispatched || input.engineEntryObserved {
            return .refused(code: oneShotCode)
        }
        if input.ddiWorkerBusy { return .refused(code: workerBusyCode) }
        if input.engineRunning || input.serviceRunning || input.phaseActive {
            return .refused(code: engineActiveCode)
        }
        if input.autoStartEnabled { return .refused(code: autoStartCode) }
        if !input.pairingImported { return .refused(code: pairingCode) }
        return .allowed
    }
}
