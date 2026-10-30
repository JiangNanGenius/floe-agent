// SPDX-License-Identifier: MPL-2.0
//
// G07.1 network diagnostics — the trusted tool executor + live-generation
// registration.
//
// The executor is the ONE place a model-visible `network.*` call becomes a
// mailbox ticket. It re-derives ownership from the runtime-issued
// `ToolContext` (never from model JSON), refuses temporary/public-web-only
// runs, binds the ticket to the CURRENT live native root epoch, and rechecks
// that generation after the round trip. The Kotlin host receives only the
// validated request v1 plus opaque task/run ids; it never decides authority.
import Foundation
import FloeCore
import FloeTools
import FloeAndroidNetwork

public final class G07NetworkToolExecutor: NetworkHostExecuting, @unchecked Sendable {
    private let host: any G07NetworkHostSubmitting
    private let currentEpoch: @Sendable () -> UInt64?

    public init(host: any G07NetworkHostSubmitting,
                currentEpoch: @escaping @Sendable () -> UInt64?) {
        self.host = host
        self.currentEpoch = currentEpoch
    }

    /// True only while the mailbox is bound to the ACTUAL live root epoch.
    /// Discovery consults this through `ToolRunnerRegistry.descriptor(named:)`.
    public var isAvailable: Bool {
        guard let live = currentEpoch(), live != 0 else { return false }
        return host.isBound && host.boundEpoch == live
    }

    public func execute(request: NetworkToolRequest,
                        context: ToolContext) async throws -> Data {
        try context.cancellation.throwIfCancelled()
        // Temporary chat has a public-web-only ceiling. Network diagnostics
        // are task-owned device measurements and stay outside it even when a
        // stale/dynamic catalog somehow offered the name.
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            throw FloeError.validationFailed(
                "Network diagnostics are unavailable in temporary chat; open a task to use them")
        }
        guard let conversationID = context.conversationID else {
            throw FloeError.validationFailed(
                "Network diagnostics require a task-owned run")
        }
        guard let live = currentEpoch(), live != 0 else {
            throw FloeError.invalidConfiguration(
                "Network diagnostics are unavailable until the runtime is ready")
        }
        guard host.isBound, host.boundEpoch == live else {
            throw FloeError.invalidConfiguration(
                "Network diagnostics are unavailable for this runtime generation")
        }
        let owner = G07NetworkOwner(taskID: conversationID,
                                    runID: context.runID, epoch: live)
        let data: Data
        do {
            data = try await host.submit(request: request, owner: owner,
                                         cancellation: context.cancellation)
        } catch let error as G07NetworkHostTransportError {
            if context.cancellation.isCancelled { throw FloeError.cancelled }
            throw Self.mapped(error)
        }
        try context.cancellation.throwIfCancelled()
        // Generation currentness BEFORE completion: a rebound/closed runtime
        // can never report an old-generation measurement as current.
        guard currentEpoch() == live, host.boundEpoch == live, host.isBound else {
            throw FloeError.invalidConfiguration(
                "Network diagnostics generation changed before completion")
        }
        return data
    }

    private static func mapped(_ error: G07NetworkHostTransportError) -> FloeError {
        switch error {
        case .cancelled:
            return .cancelled
        case .hostUnbound, .hostClosed, .hostFenced:
            return .invalidConfiguration(
                "Network diagnostics are unavailable for the current runtime generation")
        case .hostBudget:
            return .validationFailed("Network diagnostics timed out")
        case .saturated:
            return .validationFailed(
                "Too many network diagnostics are already running; retry shortly")
        case .oversized:
            return .validationFailed(
                "Network request or observation exceeded its bounded size")
        case .remoteFailed(let code, _):
            // The bounded code is a transport classification only. The
            // detail may contain a user target, so it never reaches the
            // model-facing error text.
            switch code {
            case "cancelled":
                return .cancelled
            case "timeout", "hopTimeout":
                return .validationFailed("Network diagnostics timed out")
            case "permissionRequired":
                return .validationFailed(
                    "Android permission is required for this network diagnostic")
            case "descriptorInvalid", "requestInvalid", "requestTooLarge",
                 "observationInvalid":
                return .validationFailed(
                    "The phone refused this network diagnostic request")
            case "serviceUnavailable":
                return .invalidConfiguration(
                    "The phone network service is unavailable")
            default:
                return .internalError("Network diagnostics failed (\(code))")
            }
        }
    }
}

// MARK: - Composition

public final class G07NetworkComposition: @unchecked Sendable {
    public static let shared = G07NetworkComposition()

    private let lock = NSLock()
    private var installedNames: [String] = []
    private let executor: G07NetworkToolExecutor

    private init() {
        executor = G07NetworkToolExecutor(
            host: G07NetworkHostMailbox.shared,
            currentEpoch: { G02NativeRootEpoch.readback() })
    }

    public var isInstalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return !installedNames.isEmpty
    }

    /// Idempotent registration. Called by the successful
    /// `floe_network_diag_bind`; the registry replaces by name, and each
    /// runner's `isAvailable` keeps riding the mailbox's exact bound state.
    public func installToolsIfNeeded() {
        lock.lock()
        guard installedNames.isEmpty else { lock.unlock(); return }
        installedNames = registerNetworkTools(executor: executor)
        lock.unlock()
    }

    /// Actual tool visibility for diagnostics: a name is listed only when
    /// the shared registry currently returns its runner (descriptor presence
    /// alone is not capability).
    public func visibleToolNames() -> [String] {
        NetworkToolNames.all.filter {
            ToolRunnerRegistry.shared.descriptor(named: $0) != nil
        }
    }

    /// `{"version":1,...}` readiness/capability report. Honest disabled /
    /// unbound states are reported, never a synthetic "ready".
    public func readinessJSON() -> String {
        let mailbox = G07NetworkHostMailbox.shared
        let visible = visibleToolNames()
        let installed = isInstalled
        let available = executor.isAvailable
        let reason: String
        if !installed {
            reason = "hostUnbound"
        } else if !mailbox.isBound {
            reason = "mailboxClosed"
        } else if !available {
            reason = "generationMismatch"
        } else {
            reason = "ready"
        }
        var object: [String: Any] = [
            "version": 1,
            "tool": "network",
            "installed": installed,
            "bound": mailbox.isBound,
            "epoch": mailbox.boundEpoch,
            "available": available,
            "reason": reason,
            "toolCount": visible.count,
            "registered": visible,
            "expected": NetworkToolNames.all,
        ]
        if let raw = try? JSONSerialization.jsonObject(
            with: Data(mailbox.statsJSON().utf8)),
           let stats = raw as? [String: Any] {
            object["mailbox"] = stats
        } else {
            object["mailbox"] = ["error": "stats"]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"readiness\"}"
        }
        return string
    }
}
