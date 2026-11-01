import Foundation

/// Observed outer markers and typed native phases. Legacy opaque markers remain
/// decodable for prior evidence; native stages never infer percentages.
public enum BridgeDDIInstallStage: String, Codable, Sendable {
    case preparing
    case assetsLoading = "assets-loading"
    case assetsLoaded = "assets-loaded"
    case opaqueInstallEntered = "opaque-install-entered"
    case opaqueInstallReturned = "opaque-install-returned"
    case connecting = "native-connecting"
    case queryingServices = "native-querying-services"
    case loadingAssets = "native-loading-assets"
    case personalization = "native-personalization"
    case nonce = "native-nonce"
    case signing = "native-signing"
    case openingInstaller = "native-opening-installer"
    case sendingRequest = "native-sending-request"
    case sendingImage = "native-sending-image"
    case sendingTrustCache = "native-sending-trust-cache"
    case sendingTicket = "native-sending-ticket"
    case sendingInfo = "native-sending-info"
    case sendingRootHash = "native-sending-root-hash"
    case awaitingInstallReply = "native-awaiting-install-reply"
    case verifyingRemoteInstall = "native-verifying-remote-install"
    case personalizedInstall = "native-personalized-install"
}

public enum BridgeDDIInstallOutcome: String, Codable, Sendable {
    case running
    case returned
    case failed
    case cancelled
    case timedOut = "timed-out"
    /// The worker returned without entering an install (for example, the DDI
    /// was already mounted or stopped before the mutation).
    case notRun = "not-run"
}

public enum BridgeDDIInstallTraceLimits {
    public static let maximumNotes = 12
    public static let maximumNoteCharacters = 160
    public static let maximumProgressBytes = 16 * 1024
}

/// Byte counts of the cached DDI components. Sizes only; no file contents.
public struct BridgeDDIAssetByteCounts: Codable, Equatable, Sendable {
    public var buildManifest: Int64
    public var image: Int64
    public var trustCache: Int64
    public var cryptexInfo: Int64
    public var rootHash: Int64

    public init(
        buildManifest: Int64 = 0,
        image: Int64 = 0,
        trustCache: Int64 = 0,
        cryptexInfo: Int64 = 0,
        rootHash: Int64 = 0
    ) {
        self.buildManifest = buildManifest
        self.image = image
        self.trustCache = trustCache
        self.cryptexInfo = cryptexInfo
        self.rootHash = rootHash
    }

    public var total: Int64 {
        buildManifest + image + trustCache + cryptexInfo + rootHash
    }

    /// Stable non-secret summary for the log and the bounded progress detail.
    public var summary: String {
        "imageBytes=\(image) trustCacheBytes=\(trustCache) cryptexInfoBytes=\(cryptexInfo) " +
            "rootHashBytes=\(rootHash) buildManifestBytes=\(buildManifest) totalBytes=\(total)"
    }

    /// Reads only file sizes from the cached set. Missing files are reported as
    /// zero; completeness is decided elsewhere and this helper performs no
    /// writes.
    public static func measure(
        directory: URL,
        method: BridgeDDIInstallMethod,
        fileManager: FileManager = .default
    ) -> BridgeDDIAssetByteCounts {
        func size(_ component: BridgeDDIComponent) -> Int64 {
            let path = directory.appendingPathComponent(component.rawValue).path
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let number = attributes[.size] as? NSNumber else {
                return 0
            }
            return number.int64Value
        }
        return BridgeDDIAssetByteCounts(
            buildManifest: method.components.contains(.buildManifest) ? size(.buildManifest) : 0,
            image: method.components.contains(.image) ? size(.image) : 0,
            trustCache: method.components.contains(.trustCache) ? size(.trustCache) : 0,
            cryptexInfo: method.components.contains(.cryptexInfo) ? size(.cryptexInfo) : 0,
            rootHash: method.components.contains(.rootHash) ? size(.rootHash) : 0
        )
    }
}

/// Bounded, non-secret progress record for the current blocking worker. The
/// owning PID and generation are mandatory so a file left by an old process
/// can be recognized instead of being interpreted as a live state.
public struct BridgeDDIInstallProgress: Codable, Equatable, Sendable {
    public var schema: Int
    public var hostPid: Int32
    public var generation: UInt64
    public var installMethod: String
    public var stage: BridgeDDIInstallStage
    public var outcome: BridgeDDIInstallOutcome
    public var stageEnteredAt: String
    public var startedAt: String
    public var updatedAt: String
    public var finishedAt: String?
    public var elapsedMilliseconds: Int
    public var heartbeats: Int
    public var assets: BridgeDDIAssetByteCounts?
    public var errorCode: String?
    public var notes: [String]

    public init(
        schema: Int = 1,
        hostPid: Int32,
        generation: UInt64,
        installMethod: BridgeDDIInstallMethod,
        stage: BridgeDDIInstallStage,
        outcome: BridgeDDIInstallOutcome,
        stageEnteredAt: String,
        startedAt: String,
        updatedAt: String,
        finishedAt: String? = nil,
        elapsedMilliseconds: Int,
        heartbeats: Int = 0,
        assets: BridgeDDIAssetByteCounts? = nil,
        errorCode: String? = nil,
        notes: [String] = []
    ) {
        self.schema = schema
        self.hostPid = hostPid
        self.generation = generation
        self.installMethod = installMethod.rawValue
        self.stage = stage
        self.outcome = outcome
        self.stageEnteredAt = stageEnteredAt
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
        self.elapsedMilliseconds = elapsedMilliseconds
        self.heartbeats = heartbeats
        self.assets = assets
        self.errorCode = errorCode
        self.notes = notes
    }
}

/// Thread-safe stage trace for one blocking mount worker. The coordinator
/// creates it before the worker, the worker records the asset/install markers,
/// and the coordinator's heartbeat refreshes elapsed time. No method frees an
/// FFI input or changes the worker's lifetime.
public final class BridgeDDIInstallTrace: @unchecked Sendable {
    private let lock = NSLock()
    private let hostPid: Int32
    private let generation: UInt64
    private let installMethod: BridgeDDIInstallMethod
    private let started: Date
    private var stage: BridgeDDIInstallStage
    private var stageEntered: Date
    private var updated: Date
    private var finished: Date?
    private var outcome: BridgeDDIInstallOutcome
    private var heartbeats = 0
    private var assets: BridgeDDIAssetByteCounts?
    private var errorCode: String?
    private var notes: [String] = []

    public init(
        hostPid: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        generation: UInt64,
        installMethod: BridgeDDIInstallMethod,
        startedAt: Date = Date()
    ) {
        self.hostPid = hostPid
        self.generation = generation
        self.installMethod = installMethod
        self.started = startedAt
        self.stage = .preparing
        self.stageEntered = startedAt
        self.updated = startedAt
        self.outcome = .running
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return outcome == .running
    }

    public var currentStage: BridgeDDIInstallStage {
        lock.lock()
        defer { lock.unlock() }
        return stage
    }

    /// Invoked synchronously by the native ABI while its input context is alive.
    /// Unknown codes are rejected; no strings cross the boundary.
    @discardableResult
    public func nativeStage(_ code: UInt32, at date: Date = Date()) -> Bool {
        guard let native = BridgeDDINativeStage(rawValue: code) else { return false }
        let next: BridgeDDIInstallStage
        switch native {
        case .connecting: next = .connecting
        case .queryingServices: next = .queryingServices
        case .loadingAssets: next = .loadingAssets
        case .personalization: next = .personalization
        case .nonce: next = .nonce
        case .signing: next = .signing
        case .openingInstaller: next = .openingInstaller
        case .sendingRequest: next = .sendingRequest
        case .sendingImage: next = .sendingImage
        case .sendingTrustCache: next = .sendingTrustCache
        case .sendingTicket: next = .sendingTicket
        case .sendingInfo: next = .sendingInfo
        case .sendingRootHash: next = .sendingRootHash
        case .awaitingInstallReply: next = .awaitingInstallReply
        case .verifyingRemoteInstall: next = .verifyingRemoteInstall
        case .personalizedInstall: next = .personalizedInstall
        }
        lock.lock()
        defer { lock.unlock() }
        guard outcome == .running else { return false }
        stage = next
        stageEntered = date
        updated = date
        return true
    }

    @discardableResult
    public func assetsBegan(_ counts: BridgeDDIAssetByteCounts, at date: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == .running,
              (stage == .preparing || stage == .connecting || stage == .queryingServices),
              installMethod == .cryptex,
              assets == nil else { return false }
        stage = .assetsLoading
        stageEntered = date
        updated = date
        assets = counts
        return true
    }

    @discardableResult
    public func assetsLoaded(at date: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == .running, stage == .assetsLoading || stage == .loadingAssets else { return false }
        stage = .assetsLoaded
        stageEntered = date
        updated = date
        return true
    }

    @discardableResult
    public func installEntered(at date: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == .running else { return false }
        let allowed = stage == .assetsLoaded ||
            (installMethod == .personalized && (stage == .preparing || stage == .queryingServices || stage == .connecting))
        guard allowed else { return false }
        stage = .opaqueInstallEntered
        stageEntered = date
        updated = date
        return true
    }

    /// The opaque call returned. No later stage or progress value is invented;
    /// the coordinator still owns post-return verification.
    @discardableResult
    public func installReturned(at date: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == .running, isInstallStage(stage) else { return false }
        stage = .opaqueInstallReturned
        stageEntered = date
        updated = date
        outcome = .returned
        finished = date
        return true
    }

    /// Failure preserves the latest observed native stage. Only its numeric
    /// FFI code is retained; native payload/error strings are excluded.
    @discardableResult
    public func installFailed(code: Int32, at date: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == .running, isInstallStage(stage) else { return false }
        updated = date
        outcome = .failed
        finished = date
        errorCode = "ffi-\(code)"
        return true
    }

    @discardableResult
    public func finish(
        _ newOutcome: BridgeDDIInstallOutcome,
        at date: Date = Date(),
        errorCode code: String? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == .running, newOutcome != .running else { return false }
        outcome = newOutcome
        finished = date
        updated = date
        if let code { errorCode = String(code.prefix(64)) }
        return true
    }

    public func note(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        let bounded = String(
            value.prefix(BridgeDDIInstallTraceLimits.maximumNoteCharacters)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bounded.isEmpty else { return }
        notes.append(bounded)
        if notes.count > BridgeDDIInstallTraceLimits.maximumNotes {
            notes.removeFirst(notes.count - BridgeDDIInstallTraceLimits.maximumNotes)
        }
        updated = Date()
    }

    /// A pending heartbeat only refreshes elapsed time and its own count. It
    /// never changes the observed stage and never asserts an abort.
    @discardableResult
    public func heartbeat(at date: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == .running else { return false }
        heartbeats &+= 1
        updated = date
        return true
    }

    public func snapshot(at date: Date = Date()) -> BridgeDDIInstallProgress {
        lock.lock()
        defer { lock.unlock() }
        let end = finished ?? date
        return BridgeDDIInstallProgress(
            hostPid: hostPid,
            generation: generation,
            installMethod: installMethod,
            stage: stage,
            outcome: outcome,
            stageEnteredAt: BridgeClock.timestamp(stageEntered),
            startedAt: BridgeClock.timestamp(started),
            updatedAt: BridgeClock.timestamp(updated),
            finishedAt: finished.map { BridgeClock.timestamp($0) },
            elapsedMilliseconds: elapsed(from: started, to: end),
            heartbeats: heartbeats,
            assets: assets,
            errorCode: errorCode,
            notes: notes
        )
    }

    @discardableResult
    public func write(to url: URL, at date: Date = Date()) -> Bool {
        let progress = snapshot(at: date)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(progress),
              data.count <= BridgeDDIInstallTraceLimits.maximumProgressBytes else {
            BridgeLog.shared.append("ddi_install_progress_write_refused reason=bounds")
            return false
        }
        do {
            try BridgeAtomicFile.write(data, to: url)
            return true
        } catch {
            BridgeLog.shared.append(
                "ddi_install_progress_write_failed error=\(error.localizedDescription)"
            )
            return false
        }
    }

    private func isInstallStage(_ stage: BridgeDDIInstallStage) -> Bool {
        switch stage {
        case .opaqueInstallEntered, .personalization, .nonce, .signing,
             .openingInstaller, .sendingRequest, .sendingImage, .sendingTrustCache,
             .sendingTicket, .sendingInfo, .sendingRootHash, .awaitingInstallReply,
             .verifyingRemoteInstall, .personalizedInstall:
            return true
        default:
            return false
        }
    }

    private func transition(
        from expected: BridgeDDIInstallStage,
        to next: BridgeDDIInstallStage,
        at date: Date
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == .running, stage == expected else { return false }
        stage = next
        stageEntered = date
        updated = date
        return true
    }

    private func elapsed(from start: Date, to end: Date) -> Int {
        let seconds = end.timeIntervalSince(start)
        guard seconds.isFinite else { return 0 }
        return Int(min(max(seconds, 0), 86_400) * 1000)
    }
}
