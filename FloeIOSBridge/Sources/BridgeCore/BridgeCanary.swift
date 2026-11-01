import CoreFoundation
import Foundation

/// A small, explicitly user-triggered on-device check. It reuses the ordinary
/// start flow and the existing authenticated file-command parser; it does not
/// add a second dispatcher, endpoint or readiness path.
public enum BridgeCanaryPolicy {
    public static let schema = 1
    /// Backstop for the whole start preparation. The start flow owns its
    /// tighter 180-second post-dispatch entry timeout; this larger bound only
    /// prevents an unattended check from polling forever.
    public static let entryTimeoutSeconds: TimeInterval = 600
    public static let resultPollMilliseconds = 200
    public static let maximumReportBytes = 65_536
    public static let maximumResultFileBytes = 1_048_576
    public static let maximumErrorCharacters = 240
    public static let stepTimeouts: [String: TimeInterval] = [
        "status": 20,
        "screenshot": 30,
        "open_settings": 60,
        "tap_general": 60,
        "home": 30,
    ]
    public static let note = "Diagnostic wait limits only. A timeout does not kill an entered UIKit/XCTest call, and an unobserved command is never replayed."

    public static func timeout(for action: String) -> TimeInterval {
        stepTimeouts[action] ?? 30
    }
}

public enum BridgeCanarySequence {
    /// Every run uses this fixed order. The screenshots bracket the cross-app
    /// part so a reviewer can see the state before and after the tap.
    public static let actions: [String] = [
        "status",
        "screenshot",
        "open_settings",
        "tap_general",
        "screenshot",
        "home",
        "status",
    ]
}

public enum BridgeCanaryState: String, Codable, Sendable {
    case idle
    case pending
    case running
    case completed
    case partial
    case failed
    case cancelled

    public var isLive: Bool { self == .pending || self == .running }
    public var isTerminal: Bool { !isLive }
}

public enum BridgeCanaryStepState: String, Codable, Sendable {
    case pending
    case issuing
    case awaitingResult = "awaiting-result"
    case passed
    case failed
    case unobserved
    case cancelled
    case skipped
}

public struct BridgeCanaryStep: Codable, Equatable, Sendable {
    public var index: Int
    public var action: String
    public var commandID: String
    public var state: BridgeCanaryStepState
    public var issuedAt: String?
    public var finishedAt: String?
    public var resultStatus: String?
    public var resultBytes: Int?
    public var resultProcessIdentifier: Int32?
    public var resultGeneration: UInt64?
    public var screenshotFile: String?
    public var screenshotBytes: Int?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var destinationLabel: String?
    public var error: String?
    public var note: String?

    public init(index: Int, action: String, commandID: String) {
        self.index = index
        self.action = action
        self.commandID = commandID
        self.state = .pending
    }

    public func dictionary() -> [String: Any] {
        var value: [String: Any] = [
            "index": index,
            "action": action,
            "commandID": commandID,
            "state": state.rawValue,
        ]
        if let issuedAt { value["issuedAt"] = issuedAt }
        if let finishedAt { value["finishedAt"] = finishedAt }
        if let resultStatus { value["resultStatus"] = resultStatus }
        if let resultBytes { value["resultBytes"] = resultBytes }
        if let resultProcessIdentifier { value["resultProcessIdentifier"] = resultProcessIdentifier }
        if let resultGeneration { value["resultGeneration"] = resultGeneration }
        if let screenshotFile { value["screenshotFile"] = screenshotFile }
        if let screenshotBytes { value["screenshotBytes"] = screenshotBytes }
        if let pixelWidth { value["pixelWidth"] = pixelWidth }
        if let pixelHeight { value["pixelHeight"] = pixelHeight }
        if let destinationLabel { value["destinationLabel"] = destinationLabel }
        if let error { value["error"] = error }
        if let note { value["note"] = note }
        return value
    }
}

public struct BridgeCanaryReport: Codable, Equatable, Sendable {
    public var schema: Int
    public var runID: String
    public var state: BridgeCanaryState
    public var ownerProcessIdentifier: Int32
    public var ownerGeneration: UInt64
    public var startedAt: String
    public var finishedAt: String?
    public var currentStepIndex: Int?
    public var steps: [BridgeCanaryStep]
    public var failureCode: String?
    public var message: String?
    public var note: String

    public init(
        schema: Int = BridgeCanaryPolicy.schema,
        runID: String,
        state: BridgeCanaryState,
        ownerProcessIdentifier: Int32,
        ownerGeneration: UInt64,
        startedAt: String,
        finishedAt: String? = nil,
        currentStepIndex: Int? = nil,
        steps: [BridgeCanaryStep],
        failureCode: String? = nil,
        message: String? = nil,
        note: String = BridgeCanaryPolicy.note
    ) {
        self.schema = schema
        self.runID = runID
        self.state = state
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.ownerGeneration = ownerGeneration
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.currentStepIndex = currentStepIndex
        self.steps = steps
        self.failureCode = failureCode
        self.message = message
        self.note = note
    }

    public var passedCount: Int { steps.filter { $0.state == .passed }.count }

    public func dictionary() -> [String: Any] {
        var value: [String: Any] = [
            "schema": schema,
            "runID": runID,
            "state": state.rawValue,
            "ownerProcessIdentifier": ownerProcessIdentifier,
            "ownerGeneration": ownerGeneration,
            "startedAt": startedAt,
            "steps": steps.map { $0.dictionary() },
            "note": note,
        ]
        if let finishedAt { value["finishedAt"] = finishedAt }
        if let currentStepIndex { value["currentStepIndex"] = currentStepIndex }
        if let failureCode { value["failureCode"] = failureCode }
        if let message { value["message"] = message }
        return value
    }

    public var isWellFormed: Bool {
        guard schema == BridgeCanaryPolicy.schema,
              !runID.isEmpty,
              ownerProcessIdentifier > 0,
              !startedAt.isEmpty,
              steps.count == BridgeCanarySequence.actions.count else {
            return false
        }
        for (index, step) in steps.enumerated() {
            guard step.index == index,
                  step.action == BridgeCanarySequence.actions[index],
                  !step.commandID.isEmpty else {
                return false
            }
        }
        return true
    }
}

public struct BridgeCanaryStepEvaluation: Equatable, Sendable {
    public var passed: Bool
    public var error: String?
    public var screenshotFile: String?
    public var screenshotBytes: Int?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var destinationLabel: String?

    public init(
        passed: Bool,
        error: String? = nil,
        screenshotFile: String? = nil,
        screenshotBytes: Int? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        destinationLabel: String? = nil
    ) {
        self.passed = passed
        self.error = error
        self.screenshotFile = screenshotFile
        self.screenshotBytes = screenshotBytes
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.destinationLabel = destinationLabel
    }
}

public enum BridgeCanaryStepEvaluator {
    public static func evaluate(action: String, result: BridgeCommandResult) -> BridgeCanaryStepEvaluation {
        guard result.status == "ok", result.error == nil else {
            return BridgeCanaryStepEvaluation(
                passed: false,
                error: bounded(result.error ?? "Result status was \(result.status), not ok.")
            )
        }
        let details = result.details
        switch action {
        case "status":
            return BridgeCanaryStepEvaluation(passed: true)
        case "screenshot":
            let rawFile = details["screenshotFile"] ?? ""
            let file = (rawFile as NSString).lastPathComponent
            let bytes = int(details["screenshotBytes"])
            let width = int(details["pixelWidth"])
            let height = int(details["pixelHeight"])
            let passed = !file.isEmpty && (bytes ?? 0) > 0 && (width ?? 0) > 0 && (height ?? 0) > 0
            return BridgeCanaryStepEvaluation(
                passed: passed,
                error: passed ? nil : "Screenshot result lacked a filename, byte count or pixel dimensions.",
                screenshotFile: file.isEmpty ? nil : file,
                screenshotBytes: bytes,
                pixelWidth: width,
                pixelHeight: height
            )
        case "open_settings":
            let passed = bool(details["foreground"])
            return BridgeCanaryStepEvaluation(
                passed: passed,
                error: passed ? nil : "Settings did not report runningForeground."
            )
        case "tap_general":
            let verified = bool(details["destinationVerified"])
            let tapped = bool(details["tapPerformed"])
            let label = details["destinationLabel"] ?? ""
            let knownDestination = BridgeSettingsCanaryPolicy.destinationLabels.contains(label)
            let passed = verified && tapped && knownDestination
            return BridgeCanaryStepEvaluation(
                passed: passed,
                error: passed ? nil : "General was not verified as an About/Software Update destination after a real tap.",
                destinationLabel: label.isEmpty ? nil : label
            )
        case "home":
            let verified = bool(details["destinationVerified"])
            return BridgeCanaryStepEvaluation(
                passed: verified,
                error: verified ? nil : "Home did not report an observed state change."
            )
        default:
            return BridgeCanaryStepEvaluation(passed: false, error: "Unsupported canary action.")
        }
    }

    private static func bool(_ raw: String?) -> Bool {
        raw == "true" || raw == "1"
    }

    private static func int(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw), value >= 0 else { return nil }
        return value
    }

    private static func bounded(_ message: String) -> String {
        String(message.prefix(BridgeCanaryPolicy.maximumErrorCharacters))
    }
}

public enum BridgeCanaryResultDisposition: Equatable, Sendable {
    case passed
    case failed
    case ownershipMismatch
    case ignored
}

/// Pure canary state machine. Every accepted transition is written by the
/// caller before the next action, so the persisted report always describes
/// what was observed, not what was intended.
public struct BridgeCanaryRun: Sendable {
    public private(set) var report: BridgeCanaryReport

    public init(
        runID: String,
        ownerProcessIdentifier: Int32,
        ownerGeneration: UInt64,
        startedAt: String = BridgeClock.timestamp()
    ) {
        var steps: [BridgeCanaryStep] = []
        for (index, action) in BridgeCanarySequence.actions.enumerated() {
            steps.append(BridgeCanaryStep(
                index: index,
                action: action,
                commandID: "canary-\(runID)-\(index + 1)-\(action)"
            ))
        }
        report = BridgeCanaryReport(
            runID: runID,
            state: .pending,
            ownerProcessIdentifier: ownerProcessIdentifier,
            ownerGeneration: ownerGeneration,
            startedAt: startedAt,
            steps: steps
        )
    }

    public init?(report: BridgeCanaryReport) {
        guard report.isWellFormed else { return nil }
        self.report = report
    }

    public var isLive: Bool { report.state.isLive }
    public var isTerminal: Bool { report.state.isTerminal }
    public var passedCount: Int { report.passedCount }
    public var totalCount: Int { report.steps.count }

    public var currentStep: BridgeCanaryStep? {
        guard let index = report.currentStepIndex,
              report.steps.indices.contains(index) else { return nil }
        return report.steps[index]
    }

    public var nextPendingIndex: Int? {
        report.steps.first(where: { $0.state == .pending })?.index
    }

    public static func makeRunID(
        ownerProcessIdentifier: Int32,
        ownerGeneration: UInt64,
        at: Date = Date()
    ) -> String {
        let milliseconds = UInt64(max(0, at.timeIntervalSince1970) * 1000)
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        return "c-\(ownerProcessIdentifier)-\(ownerGeneration)-\(milliseconds)-\(suffix)"
    }

    @discardableResult
    public mutating func markRunning(at: String = BridgeClock.timestamp()) -> Bool {
        guard report.state == .pending,
              let first = nextPendingIndex else { return false }
        report.state = .running
        report.currentStepIndex = first
        return true
    }

    @discardableResult
    public mutating func beginIssue(index: Int, at: String = BridgeClock.timestamp()) -> Bool {
        guard isLive,
              report.currentStepIndex == nil || report.currentStepIndex == index,
              report.steps.indices.contains(index),
              report.steps[index].state == .pending else { return false }
        report.state = .running
        report.currentStepIndex = index
        report.steps[index].state = .issuing
        report.steps[index].issuedAt = at
        return true
    }

    @discardableResult
    public mutating func markAwaitingResult(index: Int) -> Bool {
        guard isLive,
              report.currentStepIndex == index,
              report.steps.indices.contains(index),
              report.steps[index].state == .issuing else { return false }
        report.steps[index].state = .awaitingResult
        return true
    }

    @discardableResult
    public mutating func recordResult(
        index: Int,
        result: BridgeCommandResult,
        resultBytes: Int,
        at: String = BridgeClock.timestamp()
    ) -> BridgeCanaryResultDisposition {
        guard isLive,
              report.currentStepIndex == index,
              report.steps.indices.contains(index) else { return .ignored }
        var step = report.steps[index]
        guard step.state == .issuing || step.state == .awaitingResult else { return .ignored }

        step.resultStatus = result.status
        step.resultBytes = resultBytes
        step.resultProcessIdentifier = result.processIdentifier
        step.resultGeneration = result.generation
        // Command ID alone is not enough: a result with the right command
        // envelope but a different action must never be evaluated as the
        // expected step (for example an ok screenshot result mislabeled under
        // a status command). PID and generation complete the ownership check.
        if result.id != step.commandID ||
            result.action != step.action ||
            result.processIdentifier != report.ownerProcessIdentifier ||
            result.generation != report.ownerGeneration {
            step.state = .unobserved
            step.finishedAt = at
            step.error = "Result identity did not match this run (command, action, PID or generation); the result was not accepted."
            report.steps[index] = step
            finishAfterFailure(code: "ownership-mismatch", message: step.error, at: at)
            return .ownershipMismatch
        }

        let evaluation = BridgeCanaryStepEvaluator.evaluate(action: step.action, result: result)
        step.screenshotFile = evaluation.screenshotFile
        step.screenshotBytes = evaluation.screenshotBytes
        step.pixelWidth = evaluation.pixelWidth
        step.pixelHeight = evaluation.pixelHeight
        step.destinationLabel = evaluation.destinationLabel
        step.finishedAt = at
        if evaluation.passed {
            step.state = .passed
            step.error = nil
            report.steps[index] = step
            report.currentStepIndex = report.steps.first(where: { $0.state == .pending })?.index
            return .passed
        }

        step.state = .failed
        step.error = evaluation.error
        report.steps[index] = step
        finishAfterFailure(code: "step-failed", message: evaluation.error, at: at)
        return .failed
    }

    @discardableResult
    public mutating func recordUnobserved(
        index: Int,
        code: String,
        message: String,
        at: String = BridgeClock.timestamp()
    ) -> Bool {
        guard isLive,
              report.steps.indices.contains(index),
              report.steps[index].state == .issuing || report.steps[index].state == .awaitingResult else {
            return false
        }
        report.steps[index].state = .unobserved
        report.steps[index].finishedAt = at
        report.steps[index].error = bounded(message)
        finishAfterFailure(code: code, message: message, at: at)
        return true
    }

    @discardableResult
    public mutating func failBeforeIssue(
        index: Int,
        code: String,
        message: String,
        at: String = BridgeClock.timestamp()
    ) -> Bool {
        guard isLive,
              report.steps.indices.contains(index),
              report.steps[index].state == .pending || report.steps[index].state == .issuing else {
            return false
        }
        report.steps[index].state = .failed
        report.steps[index].finishedAt = at
        report.steps[index].error = bounded(message)
        finishAfterFailure(code: code, message: message, at: at)
        return true
    }

    @discardableResult
    public mutating func complete(at: String = BridgeClock.timestamp()) -> Bool {
        guard isLive else { return false }
        guard report.steps.allSatisfy({ $0.state == .passed }) else { return false }
        report.state = .completed
        report.finishedAt = at
        report.currentStepIndex = nil
        return true
    }

    /// A start/readiness failure that occurred before any step was issued.
    /// Pending steps become skipped; no step is marked failed.
    @discardableResult
    public mutating func failRun(
        code: String,
        message: String,
        at: String = BridgeClock.timestamp()
    ) -> Bool {
        guard isLive else { return false }
        for index in report.steps.indices where report.steps[index].state == .pending {
            report.steps[index].state = .skipped
        }
        report.state = report.passedCount > 0 ? .partial : .failed
        report.finishedAt = at
        report.currentStepIndex = nil
        report.failureCode = code
        report.message = bounded(message)
        return true
    }

    @discardableResult
    public mutating func cancel(
        code: String,
        message: String,
        at: String = BridgeClock.timestamp()
    ) -> Bool {
        guard isLive else { return false }
        for index in report.steps.indices {
            switch report.steps[index].state {
            case .issuing:
                report.steps[index].state = .unobserved
                report.steps[index].finishedAt = at
                report.steps[index].note = "Cancelled after issue began; a command may exist and its result was not observed."
            case .awaitingResult:
                report.steps[index].state = .unobserved
                report.steps[index].finishedAt = at
                report.steps[index].note = "Cancelled while waiting; the result was not observed and the command was not replayed."
            case .pending:
                report.steps[index].state = .skipped
            case .passed, .failed, .unobserved, .cancelled, .skipped:
                break
            }
        }
        report.state = .cancelled
        report.finishedAt = at
        report.currentStepIndex = nil
        report.failureCode = code
        report.message = bounded(message)
        return true
    }

    private mutating func finishAfterFailure(code: String, message: String?, at: String) {
        for index in report.steps.indices where report.steps[index].state == .pending {
            report.steps[index].state = .skipped
        }
        report.state = report.passedCount > 0 ? .partial : .failed
        report.finishedAt = at
        report.currentStepIndex = nil
        report.failureCode = code
        report.message = message.map(bounded)
    }

    private func bounded(_ message: String) -> String {
        String(message.prefix(BridgeCanaryPolicy.maximumErrorCharacters))
    }
}

public enum BridgeCanaryReportStore {
    @discardableResult
    public static func write(
        _ report: BridgeCanaryReport,
        to url: URL = BridgePaths.canaryReportFile
    ) -> Bool {
        guard report.isWellFormed else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report),
              data.count <= BridgeCanaryPolicy.maximumReportBytes else {
            return false
        }
        do {
            try BridgeAtomicFile.write(data, to: url)
            return true
        } catch {
            return false
        }
    }

    public static func read(from url: URL = BridgePaths.canaryReportFile) -> BridgeCanaryReport? {
        guard let data = try? Data(contentsOf: url),
              data.count <= BridgeCanaryPolicy.maximumReportBytes,
              let report = try? JSONDecoder().decode(BridgeCanaryReport.self, from: data),
              report.isWellFormed else {
            return nil
        }
        return report
    }
}

public enum BridgeCanaryReadinessDecision: Equatable, Sendable {
    case ready
    case waiting(reason: String)
    case fenced
    case failed(code: String, message: String)
}

/// The canary may proceed only when the real test entry for this PID is live
/// and the readiness marker describes the same dispatch. A stale marker, a
/// different PID or a fenced generation never counts as ready.
public enum BridgeCanaryReadiness {
    public static func evaluate(
        snapshot: BridgeSnapshot,
        readyMarker: [String: Any]?,
        expectedGeneration: UInt64,
        expectedProcessIdentifier: Int32
    ) -> BridgeCanaryReadinessDecision {
        if snapshot.terminalFault {
            return .failed(
                code: snapshot.terminalFaultCode ?? "terminal-fault",
                message: snapshot.terminalFaultMessage ?? "The engine latched a terminal fault."
            )
        }
        if snapshot.phase == .failed {
            return .failed(
                code: snapshot.errorCode ?? "failed",
                message: snapshot.lastError ?? "The start flow failed before the check could run."
            )
        }
        guard snapshot.generation == expectedGeneration else { return .fenced }
        guard snapshot.serviceRunning else { return .fenced }
        guard snapshot.phase == .ready else {
            return .waiting(reason: "phase-\(snapshot.phase.rawValue)")
        }
        guard snapshot.engineEntryObserved,
              snapshot.engineRunning,
              snapshot.enginePid == expectedProcessIdentifier else {
            return .waiting(reason: "engine-entry-not-live")
        }
        guard let readyMarker else { return .waiting(reason: "ready-marker-missing") }
        guard (readyMarker["ready"] as? Bool) == true else {
            return .waiting(reason: "ready-marker-not-ready")
        }
        guard int32(readyMarker["processIdentifier"]) == expectedProcessIdentifier else {
            return .waiting(reason: "ready-marker-pid")
        }
        guard let testBundle = readyMarker["testBundleIdentifier"] as? String,
              testBundle == BridgeBuild.hostBundleIdentifier else {
            return .waiting(reason: "ready-marker-test-bundle")
        }
        guard let markerGeneration = uint64(readyMarker["dispatchedGeneration"]),
              let dispatchedGeneration = snapshot.dispatchedGeneration,
              markerGeneration == dispatchedGeneration else {
            return .waiting(reason: "ready-marker-dispatch")
        }
        return .ready
    }

    private static func int32(_ value: Any?) -> Int32? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.int32Value
        }
        if let string = value as? String { return Int32(string) }
        return nil
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.uint64Value
        }
        if let string = value as? String { return UInt64(string) }
        return nil
    }
}
