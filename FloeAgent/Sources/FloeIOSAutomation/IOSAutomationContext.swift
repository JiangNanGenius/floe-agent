// FloeIOSAutomation — task-owned cancellation, execution window, authority
// callback and local protection policy.
//
// This is not a second approval framework. The callback only consumes the
// authority the canonical runtime already granted for this task/call. All
// human approval surfaces remain owned by the App, Bridge and the system.

import Foundation

public protocol IOSBridgeClock: Sendable {
    func now() -> Date
}

public struct SystemIOSBridgeClock: IOSBridgeClock {
    public init() {}
    public func now() -> Date { Date() }
}

public protocol IOSBridgeRandomness: Sendable {
    func bytes(_ count: Int) throws -> Data
}

public struct SystemIOSBridgeRandomness: IOSBridgeRandomness {
    public init() {}
    public func bytes(_ count: Int) throws -> Data {
        guard let data = IOSBridgeEnvelope.randomBytes(count) else {
            throw IOSBridgeError.unexpected("The system random source refused the request.")
        }
        return data
    }
}

// MARK: - Cancellation

public final class IOSAutomationCancellationRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var remover: (@Sendable () -> Void)?

    init(remover: @escaping @Sendable () -> Void) {
        self.remover = remover
    }

    public func remove() {
        lock.lock()
        let remover = self.remover
        self.remover = nil
        lock.unlock()
        remover?()
    }
}

/// Task-owned cancellation. Handlers are used only to stop an in-flight
/// transport request; they do not authorize or approve anything.
public final class IOSAutomationCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        let pending: [@Sendable () -> Void]
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        pending = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        for handler in pending { handler() }
    }

    public func register(
        _ handler: @escaping @Sendable () -> Void
    ) -> IOSAutomationCancellationRegistration {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return IOSAutomationCancellationRegistration(remover: {})
        }
        let id = UUID()
        handlers[id] = handler
        lock.unlock()
        return IOSAutomationCancellationRegistration { [weak self] in
            self?.removeHandler(id)
        }
    }

    private func removeHandler(_ id: UUID) {
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }
}

// MARK: - Execution window

/// Bounded run window supplied by the App. A background run must pass the
/// existing BackgroundRunCoordinator's real deadline here; this type never
/// promises indefinite background execution.
public struct IOSAutomationExecutionWindow: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case foreground
        case backgroundRun
        case userInitiated
    }

    public let startedAt: Date
    public let deadline: Date?
    public let source: Source

    public init(startedAt: Date, deadline: Date?, source: Source) {
        self.startedAt = startedAt
        self.deadline = deadline
        self.source = source
    }

    public static func foreground(at date: Date = Date()) -> IOSAutomationExecutionWindow {
        IOSAutomationExecutionWindow(startedAt: date, deadline: nil, source: .foreground)
    }

    public static func backgroundRun(
        startedAt: Date,
        deadline: Date
    ) -> IOSAutomationExecutionWindow {
        IOSAutomationExecutionWindow(startedAt: startedAt, deadline: deadline, source: .backgroundRun)
    }

    public static func userInitiated(
        at date: Date = Date(),
        timeout: TimeInterval
    ) -> IOSAutomationExecutionWindow {
        IOSAutomationExecutionWindow(
            startedAt: date,
            deadline: date.addingTimeInterval(max(0, timeout)),
            source: .userInitiated
        )
    }

    public func isExpired(at date: Date) -> Bool {
        guard let deadline else { return false }
        return date >= deadline
    }

    public func remaining(at date: Date) -> TimeInterval? {
        guard let deadline else { return nil }
        return max(0, deadline.timeIntervalSince(date))
    }
}

// MARK: - Call context and target

/// Non-secret view of persistent task-level device-input ownership.
public struct IOSAutomationDeviceInputOwner: Sendable, Equatable {
    public let taskID: UUID
    public let taskGeneration: UInt64
    public let acquiredAt: Date
    public let expiresAt: Date?

    public init(taskID: UUID, taskGeneration: UInt64, acquiredAt: Date, expiresAt: Date?) {
        self.taskID = taskID
        self.taskGeneration = taskGeneration
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
    }
}

public struct IOSAutomationTarget: Sendable, Equatable {
    public var bundleIdentifier: String?
    public var url: URL?

    public init(bundleIdentifier: String? = nil, url: URL? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.url = url
    }
}

public struct IOSAutomationCallContext: Sendable {
    public var taskID: UUID
    public var taskGeneration: UInt64
    public var clientSessionID: String?
    public var toolCallID: String?
    public var toolIdempotencyKey: String?
    /// Canonical operation id. Mutating callers should pass the durable tool
    /// call id so a repeated request is the same Bridge operation, never a
    /// second device action. If nil, the client generates one and returns it
    /// in the receipt.
    public var operationID: String?
    public var cancellation: IOSAutomationCancellationToken
    public var executionWindow: IOSAutomationExecutionWindow
    /// Per-call authority supplied by the App tool wrapper. This is how the
    /// canonical ToolContext/runtime authority is checked without making the
    /// long-lived client capture one task's context. Nil uses the client-wide
    /// fail-closed default.
    public var authorityOverride: (any IOSAutomationTaskAuthority)?

    public init(
        taskID: UUID,
        taskGeneration: UInt64,
        clientSessionID: String? = nil,
        toolCallID: String? = nil,
        toolIdempotencyKey: String? = nil,
        operationID: String? = nil,
        cancellation: IOSAutomationCancellationToken = IOSAutomationCancellationToken(),
        executionWindow: IOSAutomationExecutionWindow = .foreground(),
        authorityOverride: (any IOSAutomationTaskAuthority)? = nil
    ) {
        self.taskID = taskID
        self.taskGeneration = taskGeneration
        self.clientSessionID = clientSessionID
        self.toolCallID = toolCallID
        self.toolIdempotencyKey = toolIdempotencyKey
        self.operationID = operationID
        self.cancellation = cancellation
        self.executionWindow = executionWindow
        self.authorityOverride = authorityOverride
    }
}

// MARK: - Existing task authority callback

public struct IOSAutomationAuthorizationRequest: Sendable {
    public let action: IOSAutomationAction
    public let effect: IOSAutomationEffect
    public let declaredTarget: IOSAutomationTarget
    public let foregroundBundleIdentifier: String?
    public let context: IOSAutomationCallContext

    public init(
        action: IOSAutomationAction,
        effect: IOSAutomationEffect,
        declaredTarget: IOSAutomationTarget,
        foregroundBundleIdentifier: String?,
        context: IOSAutomationCallContext
    ) {
        self.action = action
        self.effect = effect
        self.declaredTarget = declaredTarget
        self.foregroundBundleIdentifier = foregroundBundleIdentifier
        self.context = context
    }
}

public enum IOSAutomationAuthorizationDecision: Sendable, Equatable {
    case allowed
    case denied(reason: String)
}

/// The App implements this with its existing RuntimeTaskAuthority/ToolContext
/// check. The module deliberately has no parallel approval store.
public protocol IOSAutomationTaskAuthority: Sendable {
    func authorize(_ request: IOSAutomationAuthorizationRequest) async
        -> IOSAutomationAuthorizationDecision
}

/// Fail-closed default: reads remain usable, mutations require the App to wire
/// the canonical task authority.
public struct ReadOnlyIOSAutomationAuthority: IOSAutomationTaskAuthority {
    public init() {}

    public func authorize(_ request: IOSAutomationAuthorizationRequest) async
        -> IOSAutomationAuthorizationDecision {
        if request.effect == .readOnly { return .allowed }
        return .denied(reason: "No native task authority is wired for device mutation.")
    }
}

// MARK: - Protected surfaces

public struct IOSAutomationProtectionPolicy: Sendable, Equatable {
    /// Bundle ids that automation may never mutate.
    public var protectedMutationBundleIdentifiers: Set<String>
    /// Bundle ids whose screen/tree may not be read through automation. Bridge
    /// is included by default because its UI can show client/setup details.
    public var deniedReadBundleIdentifiers: Set<String>
    /// URL schemes that may never be opened by automation.
    public var protectedURLSchemes: Set<String>
    /// Additional schemes that are never opened (local content/scripting).
    public var deniedURLSchemes: Set<String>
    /// Require the live foreground app to be resolved before generic input or
    /// coordinate control. If the foreground cannot be established, input is
    /// refused.
    public var requiresForegroundVerification: Bool

    public init(
        protectedMutationBundleIdentifiers: Set<String> = [
            "org.floeagent.ios",
            "org.floeagent.iosbridge",
        ],
        deniedReadBundleIdentifiers: Set<String> = [
            "org.floeagent.iosbridge",
        ],
        protectedURLSchemes: Set<String> = [
            "floe",
            "floe-ios-bridge",
        ],
        deniedURLSchemes: Set<String> = [
            "file",
            "javascript",
            "data",
        ],
        requiresForegroundVerification: Bool = true
    ) {
        self.protectedMutationBundleIdentifiers = Set(
            protectedMutationBundleIdentifiers.map { $0.lowercased() }
        )
        self.deniedReadBundleIdentifiers = Set(
            deniedReadBundleIdentifiers.map { $0.lowercased() }
        )
        self.protectedURLSchemes = Set(protectedURLSchemes.map { $0.lowercased() })
        self.deniedURLSchemes = Set(deniedURLSchemes.map { $0.lowercased() })
        self.requiresForegroundVerification = requiresForegroundVerification
    }

    public static let `default` = IOSAutomationProtectionPolicy()

    public func mutationDenialReason(bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        let normalized = bundleIdentifier.lowercased()
        return protectedMutationBundleIdentifiers.contains(normalized)
            ? "Automation cannot mutate the Floe or Bridge authorization surface."
            : nil
    }

    public func readDenialReason(bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        let normalized = bundleIdentifier.lowercased()
        return deniedReadBundleIdentifiers.contains(normalized)
            ? "Automation cannot read the Bridge management screen."
            : nil
    }

    public func urlDenialReason(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if protectedURLSchemes.contains(scheme) {
            return "Automation cannot open the Floe or Bridge authorization surface."
        }
        if deniedURLSchemes.contains(scheme) {
            return "Automation cannot open that URL scheme."
        }
        return nil
    }
}

// MARK: - Cooperative cancellation bridge

public extension IOSAutomationCancellationToken {
    /// Bridges an existing cooperative predicate (for example
    /// `ToolContext.cancellation.isCancelled`) into this token. The App tool
    /// wrapper owns the returned watcher and cancels it when the call ends.
    /// Polling is bounded and never authorizes anything.
    @discardableResult
    func bridge(
        from predicate: @escaping @Sendable () -> Bool,
        pollInterval: Duration = .milliseconds(50)
    ) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                if self?.isCancelled == true { return }
                if predicate() {
                    self?.cancel()
                    return
                }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }
}

// MARK: - Companion presence

public enum IOSBridgeCompanionPresence: Sendable, Equatable {
    case installed
    case missing
    case unknown
}

/// The App can implement this with a declared Bridge URL scheme or an
/// installation receipt. Unknown is honest: the client then reports service
/// unavailable rather than guessing that the companion is missing.
public protocol IOSBridgeCompanionProbe: Sendable {
    func presence() async -> IOSBridgeCompanionPresence
}
