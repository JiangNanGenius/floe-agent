// FloeIOSAutomation — bounded action receipt and unknown-outcome recovery.

import Foundation

public enum IOSAutomationUnknownReason: String, Sendable, Equatable, Codable {
    case requestMayHaveBeenSent
    case responseUnreadable
    case cancelledAfterDispatch
    case lifecycleFencedAfterDispatch
    case taskGenerationChangedAfterDispatch
    case serverReportedUnknown
    case serverReportedTimeout
    case serverReportedFenced
    case applicationBackgrounded
}

public enum IOSAutomationRecoveryAdvice: String, Sendable, Equatable, Codable {
    case observeScreenFirst
    case readBridgeConfiguration
    case askOwnerToCheckDevice

    /// This module never retries a mutation automatically. The caller must
    /// observe the device or ask the owner before deciding whether to act.
    public var permitsAutomaticRetry: Bool { false }
}

public struct IOSAutomationUnknownOutcome: Sendable, Equatable {
    public let operationID: String
    public let reason: IOSAutomationUnknownReason
    public let message: String
    public let recovery: IOSAutomationRecoveryAdvice

    public init(
        operationID: String,
        reason: IOSAutomationUnknownReason,
        message: String,
        recovery: IOSAutomationRecoveryAdvice
    ) {
        self.operationID = operationID
        self.reason = reason
        self.message = message
        self.recovery = recovery
    }
}

public enum IOSAutomationReceiptOutcome: Sendable, Equatable {
    case succeeded
    /// Definite failure after the operation was dispatched, but without a
    /// successful completion receipt.
    case failed(IOSBridgeError)
    /// The client refused or could not reach Bridge before dispatch.
    case notSent(IOSBridgeError)
    case cancelled
    case fenced
    /// A mutation may already have taken effect. Never retry blindly.
    case outcomeUnknown(IOSAutomationUnknownOutcome)
}

public struct IOSAutomationReceipt: Sendable, Equatable {
    public let action: IOSAutomationAction
    public let effect: IOSAutomationEffect
    public let operationID: String
    public let outcome: IOSAutomationReceiptOutcome
    public let result: IOSBridgeJSONValue?
    public let startedAt: Date
    public let completedAt: Date
    public let usedInputLease: Bool

    public init(
        action: IOSAutomationAction,
        effect: IOSAutomationEffect,
        operationID: String,
        outcome: IOSAutomationReceiptOutcome,
        result: IOSBridgeJSONValue?,
        startedAt: Date,
        completedAt: Date,
        usedInputLease: Bool
    ) {
        self.action = action
        self.effect = effect
        self.operationID = operationID
        self.outcome = outcome
        self.result = result
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.usedInputLease = usedInputLease
    }

    public var isSuccess: Bool {
        if case .succeeded = outcome { return true }
        return false
    }

    public var isOutcomeUnknown: Bool {
        if case .outcomeUnknown = outcome { return true }
        return false
    }

    public var error: IOSBridgeError? {
        switch outcome {
        case .failed(let error), .notSent(let error): return error
        default: return nil
        }
    }

    public var recovery: IOSAutomationRecoveryAdvice? {
        if case .outcomeUnknown(let unknown) = outcome { return unknown.recovery }
        return nil
    }

    public var resultObject: [String: IOSBridgeJSONValue]? {
        result?.objectValue
    }

    /// Concise, non-secret diagnostic line. Never includes arguments,
    /// screenshot bytes or pairing material.
    public var diagnosticSummary: String {
        let duration = max(0, completedAt.timeIntervalSince(startedAt))
        let outcomeText: String
        switch outcome {
        case .succeeded: outcomeText = "succeeded"
        case .failed(let error): outcomeText = "failed(\(error.canonicalCode))"
        case .notSent(let error): outcomeText = "notSent(\(error.canonicalCode))"
        case .cancelled: outcomeText = "cancelled"
        case .fenced: outcomeText = "fenced"
        case .outcomeUnknown(let unknown): outcomeText = "outcomeUnknown(\(unknown.reason.rawValue))"
        }
        return "\(action.rawValue) \(effect.rawValue) \(outcomeText) "
            + "operation=\(operationID) duration=\(String(format: "%.2f", duration))s"
    }
}
