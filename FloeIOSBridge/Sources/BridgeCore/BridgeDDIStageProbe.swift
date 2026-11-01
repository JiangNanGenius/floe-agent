import Foundation

/// Pure gate for the prototype-only, read-only DDI stage probe.
///
/// The probe must never overlap a mount/removal worker, a startup, an
/// initialized one-shot engine or an enabled Auto-recover. It also refuses a
/// latched terminal fault and requires both an imported pairing record and the
/// cached DDI files, because it is allowed to read them but never download or
/// import anything.
public enum BridgeDDIStageProbeGuardDecision: Equatable, Sendable {
    case allowed
    case refused(code: String)

    public var isAllowed: Bool { self == .allowed }

    public var refusalCode: String? {
        if case .refused(let code) = self { return code }
        return nil
    }
}

public struct BridgeDDIStageProbeGuardInput: Equatable, Sendable {
    public var terminalFault: Bool
    public var oneShotDispatched: Bool
    public var engineEntryObserved: Bool
    public var ddiWorkerBusy: Bool
    public var engineRunning: Bool
    public var serviceRunning: Bool
    public var phaseActive: Bool
    public var autoStartEnabled: Bool
    public var pairingImported: Bool
    public var assetsComplete: Bool

    public init(
        terminalFault: Bool = false,
        oneShotDispatched: Bool = false,
        engineEntryObserved: Bool = false,
        ddiWorkerBusy: Bool = false,
        engineRunning: Bool = false,
        serviceRunning: Bool = false,
        phaseActive: Bool = false,
        autoStartEnabled: Bool = false,
        pairingImported: Bool = false,
        assetsComplete: Bool = false
    ) {
        self.terminalFault = terminalFault
        self.oneShotDispatched = oneShotDispatched
        self.engineEntryObserved = engineEntryObserved
        self.ddiWorkerBusy = ddiWorkerBusy
        self.engineRunning = engineRunning
        self.serviceRunning = serviceRunning
        self.phaseActive = phaseActive
        self.autoStartEnabled = autoStartEnabled
        self.pairingImported = pairingImported
        self.assetsComplete = assetsComplete
    }
}

/// Exhaustive, ordered refusal policy. The ordering is part of the contract:
/// a latched fault can never be downgraded to an ordinary refusal, and an
/// initialized engine is refused before the worker check because the latter is
/// an ordinary transient state.
public enum BridgeDDIStageProbeGuard {
    public static let terminalFaultCode = "terminal-fault"
    public static let oneShotCode = "one-shot-dispatched"
    public static let workerBusyCode = "ddi-worker-busy"
    public static let engineActiveCode = "engine-active"
    public static let autoStartCode = "auto-start-enabled"
    public static let pairingCode = "pairing-required"
    public static let assetsCode = "ddi-assets-missing"

    public static func decide(_ input: BridgeDDIStageProbeGuardInput) -> BridgeDDIStageProbeGuardDecision {
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
        if !input.assetsComplete { return .refused(code: assetsCode) }
        return .allowed
    }
}

/// Ownership facts persisted with a diagnostic report. A reader compares these
/// against the current process and generation instead of trusting a stale
/// file's own "running" stage.
public struct BridgeDiagnosticReportOwner: Equatable, Sendable {
    public var hostPid: Int32
    public var generation: UInt64

    public init(hostPid: Int32, generation: UInt64) {
        self.hostPid = hostPid
        self.generation = generation
    }

    public func isCurrentProcess(_ processIdentifier: Int32) -> Bool {
        hostPid == processIdentifier
    }

    public func matchesGeneration(_ currentGeneration: UInt64) -> Bool {
        generation == currentGeneration
    }
}

/// Every call the probe can make, in the order the coordinator and worker
/// record it. Only stages this build can actually observe are listed. The
/// opaque install path is deliberately absent: the probe never installs.
public enum BridgeDDIProbeStage: String, Codable, Sendable, CaseIterable {
    case tssReachability = "tss-reachability"
    case tunnelStart = "tunnel-start"
    case tunnelProbe = "tunnel-probe"
    case pairingStage = "pairing-stage"
    case rsdSession = "rsd-session"
    case cachedAssetsLoad = "cached-assets-load"
    case assetsNonceDomain = "assets-nonce-domain"
    case personalizationIdentifiers = "read-personalization-identifiers"
    case cryptexNonce = "cryptex-nonce"
    case tunnelStop = "tunnel-stop"
}

public enum BridgeDDIStageSampleState: String, Codable, Sendable {
    case running
    case completed
    case failed
    case cancelled
}

public enum BridgeDDIStageProbeOutcome: String, Codable, Sendable {
    case running
    case completed
    case notApplicable = "not-applicable"
    case cancelled
    case failed
}

public enum BridgeDDIStageProbeLimits {
    public static let maximumStages = 16
    public static let maximumNotes = 16
    public static let maximumNoteCharacters = 200
    public static let maximumDetailCharacters = 160
    public static let maximumErrorCharacters = 240
    public static let maximumReportBytes = 32 * 1024
    public static let maximumIdentifierCharacters = 48
}

/// One observed stage. `startedAt` is recorded immediately before the call and
/// `durationMilliseconds` only after it returns. `detail` is restricted to
/// non-secret facts such as byte counts or a boolean presence flag.
public struct BridgeDDIStageSample: Codable, Equatable, Sendable {
    public var stage: String
    public var state: BridgeDDIStageSampleState
    public var startedAt: String
    public var finishedAt: String?
    public var durationMilliseconds: Int?
    public var detail: String?
    public var errorCode: String?

    public init(
        stage: String,
        state: BridgeDDIStageSampleState,
        startedAt: String,
        finishedAt: String? = nil,
        durationMilliseconds: Int? = nil,
        detail: String? = nil,
        errorCode: String? = nil
    ) {
        self.stage = stage
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationMilliseconds = durationMilliseconds
        self.detail = detail
        self.errorCode = errorCode
    }
}

/// Bounded, non-secret stage evidence. It never contains a pairing record,
/// personalization dictionary, ECID/UDID, raw nonce, TSS request/response or
/// credential. `hostPid` and `generation` let a later reader reject a stale
/// file instead of presenting it as current.
public struct BridgeDDIStageProbeReport: Codable, Equatable, Sendable {
    public var schema: Int
    public var outcome: BridgeDDIStageProbeOutcome
    public var hostPid: Int32
    public var generation: UInt64
    public var installMethod: String
    public var cryptexProbeApplicable: Bool
    public var startedAt: String
    public var updatedAt: String
    public var finishedAt: String?
    public var elapsedMilliseconds: Int
    public var tunnel: String
    public var currentStage: String?
    public var stages: [BridgeDDIStageSample]
    public var tss: BridgeTSSReachabilityReport?
    public var notes: [String]
    public var errorCode: String?
    public var errorMessage: String?

    public init(
        schema: Int = 1,
        outcome: BridgeDDIStageProbeOutcome,
        hostPid: Int32,
        generation: UInt64,
        installMethod: String,
        cryptexProbeApplicable: Bool,
        startedAt: String,
        updatedAt: String,
        finishedAt: String? = nil,
        elapsedMilliseconds: Int,
        tunnel: String,
        currentStage: String? = nil,
        stages: [BridgeDDIStageSample] = [],
        tss: BridgeTSSReachabilityReport? = nil,
        notes: [String] = [],
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        self.schema = schema
        self.outcome = outcome
        self.hostPid = hostPid
        self.generation = generation
        self.installMethod = installMethod
        self.cryptexProbeApplicable = cryptexProbeApplicable
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
        self.elapsedMilliseconds = elapsedMilliseconds
        self.tunnel = tunnel
        self.currentStage = currentStage
        self.stages = stages
        self.tss = tss
        self.notes = notes
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

/// Thread-safe recorder shared by the owning Swift task, the heartbeat and the
/// blocking worker. `begin` is called immediately before a call and
/// `complete`/`fail` immediately after it returns; a stage that never returns
/// stays `running` with no duration, which is the truthful evidence a hung
/// read call leaves behind.
public final class BridgeDDIStageProbeRecorder: @unchecked Sendable {
    private struct OpenStage {
        var stage: BridgeDDIProbeStage
        var state: BridgeDDIStageSampleState
        var started: Date
        var finished: Date?
        var detail: String?
        var errorCode: String?
    }

    private let lock = NSLock()
    private let hostPid: Int32
    private let generation: UInt64
    private let installMethod: BridgeDDIInstallMethod
    private let started: Date
    private var outcome: BridgeDDIStageProbeOutcome
    private var cryptexProbeApplicable: Bool
    private var stages: [OpenStage] = []
    private var tunnel = "not-started"
    private var tss: BridgeTSSReachabilityReport?
    private var notes: [String] = []
    private var errorCode: String?
    private var errorMessage: String?
    private var updated: Date
    private var finished: Date?

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
        self.updated = startedAt
        self.outcome = .running
        self.cryptexProbeApplicable = installMethod == .cryptex
    }

    @discardableResult
    public func begin(_ stage: BridgeDDIProbeStage, at date: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == .running else { return false }
        guard stages.count < BridgeDDIStageProbeLimits.maximumStages else { return false }
        guard !stages.contains(where: { $0.state == .running }) else { return false }
        guard !stages.contains(where: { $0.stage == stage }) else { return false }
        stages.append(OpenStage(stage: stage, state: .running, started: date))
        updated = date
        return true
    }

    @discardableResult
    public func complete(
        _ stage: BridgeDDIProbeStage,
        at date: Date = Date(),
        detail: String? = nil
    ) -> Bool {
        finishStage(stage, state: .completed, at: date, detail: detail, errorCode: nil)
    }

    @discardableResult
    public func fail(
        _ stage: BridgeDDIProbeStage,
        at date: Date = Date(),
        code: String,
        detail: String? = nil
    ) -> Bool {
        finishStage(stage, state: .failed, at: date, detail: detail, errorCode: code)
    }

    @discardableResult
    public func cancel(_ stage: BridgeDDIProbeStage, at date: Date = Date()) -> Bool {
        finishStage(stage, state: .cancelled, at: date, detail: nil, errorCode: "cancelled")
    }

    public func setTSS(_ report: BridgeTSSReachabilityReport) {
        lock.lock()
        tss = report
        updated = Date()
        lock.unlock()
    }

    public func setTunnel(_ value: String) {
        lock.lock()
        tunnel = Self.bounded(value, maximum: BridgeDDIStageProbeLimits.maximumIdentifierCharacters)
        updated = Date()
        lock.unlock()
    }

    public func setCryptexProbeApplicable(_ value: Bool) {
        lock.lock()
        cryptexProbeApplicable = value
        updated = Date()
        lock.unlock()
    }

    public func note(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        let bounded = Self.bounded(value, maximum: BridgeDDIStageProbeLimits.maximumNoteCharacters)
        guard !bounded.isEmpty else { return }
        notes.append(bounded)
        if notes.count > BridgeDDIStageProbeLimits.maximumNotes {
            notes.removeFirst(notes.count - BridgeDDIStageProbeLimits.maximumNotes)
        }
        updated = Date()
    }

    /// A service-owned heartbeat only refreshes elapsed/updated timestamps. It
    /// never changes the stage, outcome or error and never frees an FFI input.
    @discardableResult
    public func heartbeat(at date: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == .running else { return false }
        updated = date
        return true
    }

    @discardableResult
    public func finish(
        _ newOutcome: BridgeDDIStageProbeOutcome,
        at date: Date = Date(),
        errorCode code: String? = nil,
        errorMessage message: String? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == .running else { return false }
        guard newOutcome != .running else { return false }
        outcome = newOutcome
        finished = date
        updated = date
        if let code { errorCode = Self.bounded(code, maximum: 64) }
        if let message {
            errorMessage = Self.bounded(
                message,
                maximum: BridgeDDIStageProbeLimits.maximumErrorCharacters
            )
        }
        return true
    }

    public var currentStage: String? {
        lock.lock()
        defer { lock.unlock() }
        return stages.last(where: { $0.state == .running })?.stage.rawValue
    }

    public func snapshot(at date: Date = Date()) -> BridgeDDIStageProbeReport {
        lock.lock()
        defer { lock.unlock() }
        let end = finished ?? date
        let samples = stages.map { entry -> BridgeDDIStageSample in
            BridgeDDIStageSample(
                stage: entry.stage.rawValue,
                state: entry.state,
                startedAt: BridgeClock.timestamp(entry.started),
                finishedAt: entry.finished.map { BridgeClock.timestamp($0) },
                durationMilliseconds: entry.finished.map {
                    Self.milliseconds(from: entry.started, to: $0)
                },
                detail: entry.detail,
                errorCode: entry.errorCode
            )
        }
        return BridgeDDIStageProbeReport(
            outcome: outcome,
            hostPid: hostPid,
            generation: generation,
            installMethod: installMethod.rawValue,
            cryptexProbeApplicable: cryptexProbeApplicable,
            startedAt: BridgeClock.timestamp(started),
            updatedAt: BridgeClock.timestamp(updated),
            finishedAt: finished.map { BridgeClock.timestamp($0) },
            elapsedMilliseconds: Self.milliseconds(from: started, to: end),
            tunnel: tunnel,
            currentStage: stages.last(where: { $0.state == .running })?.stage.rawValue,
            stages: samples,
            tss: tss,
            notes: notes,
            errorCode: errorCode,
            errorMessage: errorMessage
        )
    }

    /// Atomic, bounded write. A late writer can only replace the file with a
    /// coherent snapshot; it cannot produce a partial JSON document.
    @discardableResult
    public func write(to url: URL, at date: Date = Date()) -> Bool {
        let report = snapshot(at: date)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report),
              data.count <= BridgeDDIStageProbeLimits.maximumReportBytes else {
            BridgeLog.shared.append("ddi_stage_probe_write_refused reason=bounds")
            return false
        }
        do {
            try BridgeAtomicFile.write(data, to: url)
            return true
        } catch {
            BridgeLog.shared.append(
                "ddi_stage_probe_write_failed error=\(error.localizedDescription)"
            )
            return false
        }
    }

    private func finishStage(
        _ stage: BridgeDDIProbeStage,
        state: BridgeDDIStageSampleState,
        at date: Date,
        detail: String?,
        errorCode code: String?
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == .running else { return false }
        guard let index = stages.lastIndex(where: { $0.stage == stage && $0.state == .running }) else {
            return false
        }
        stages[index].state = state
        stages[index].finished = date
        if let detail {
            stages[index].detail = Self.bounded(
                detail,
                maximum: BridgeDDIStageProbeLimits.maximumDetailCharacters
            )
        }
        if let code {
            stages[index].errorCode = Self.bounded(code, maximum: 64)
        }
        updated = date
        return true
    }

    private static func bounded(_ value: String, maximum: Int) -> String {
        String(value.prefix(maximum)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func milliseconds(from start: Date, to end: Date) -> Int {
        let seconds = end.timeIntervalSince(start)
        guard seconds.isFinite else { return 0 }
        return Int(min(max(seconds, 0), 86_400) * 1000)
    }
}
