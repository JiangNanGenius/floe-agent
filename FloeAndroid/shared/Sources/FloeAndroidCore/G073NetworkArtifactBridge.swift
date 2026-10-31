// SPDX-License-Identifier: MPL-2.0
//
// G07.3B saved-artifact tool executor + composition.
//
// The executor re-derives the caller's task/run/epoch/workspace from the
// runtime-issued ToolContext (never from model JSON). Temporary chat and
// public-web-only runs are refused before any ticket. The Kotlin host decides
// whether the artifact is actually shared/owned for this caller; an opaque
// UUID is never sufficient authority.
import Foundation
import FloeCore
import FloeTools
import FloeAndroidNetwork

public final class G073NetworkArtifactToolExecutor: NetworkArtifactHostExecuting, @unchecked Sendable {
    private let host: any G073NetworkArtifactHostSubmitting
    private let currentEpoch: @Sendable () -> UInt64?

    public init(host: any G073NetworkArtifactHostSubmitting,
                currentEpoch: @escaping @Sendable () -> UInt64?) {
        self.host = host
        self.currentEpoch = currentEpoch
    }

    public var isAvailable: Bool {
        guard let live = currentEpoch(), live != 0 else { return false }
        return host.isBound && host.boundEpoch == live
    }

    public func execute(request: NetworkArtifactToolRequest,
                        context: ToolContext) async throws -> Data {
        try context.cancellation.throwIfCancelled()
        // Temporary chat is text/public-web-only. Local artifact reads are
        // outside that ceiling even if a stale catalog still offered the name.
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            throw FloeError.validationFailed(
                "Local capture and coverage artifacts are unavailable in temporary chat; open a task")
        }
        guard let conversationID = context.conversationID else {
            throw FloeError.validationFailed("Local artifacts require a task-owned run")
        }
        guard let live = currentEpoch(), live != 0 else {
            throw FloeError.invalidConfiguration(
                "Local artifacts are unavailable until the runtime is ready")
        }
        guard host.isBound, host.boundEpoch == live else {
            throw FloeError.invalidConfiguration(
                "Local artifacts are unavailable for this runtime generation")
        }
        let workspace = context.workspaceRootURL.map {
            FloeDigest.sha256Hex(Data($0.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
        }
        let owner = G073NetworkArtifactOwner(
            taskID: conversationID, runID: context.runID, epoch: live,
            workspaceFingerprint: workspace)
        let data: Data
        do {
            data = try await host.submit(request: request, owner: owner,
                                         cancellation: context.cancellation)
        } catch let error as G073NetworkArtifactTransportError {
            if context.cancellation.isCancelled { throw FloeError.cancelled }
            throw Self.mapped(error)
        }
        try context.cancellation.throwIfCancelled()
        guard currentEpoch() == live, host.boundEpoch == live, host.isBound else {
            throw FloeError.invalidConfiguration(
                "Local artifact generation changed before completion")
        }
        return data
    }

    private static func mapped(_ error: G073NetworkArtifactTransportError) -> FloeError {
        switch error {
        case .cancelled:
            return .cancelled
        case .hostUnbound, .hostClosed, .hostFenced:
            return .invalidConfiguration(
                "Local artifacts are unavailable for the current runtime generation")
        case .hostBudget:
            return .validationFailed("Local artifact read timed out")
        case .saturated:
            return .validationFailed(
                "Too many local artifact reads are already running; retry shortly")
        case .oversized:
            return .validationFailed("Local artifact request or reply exceeded its bounded size")
        case .remoteFailed(let code, _):
            switch code {
            case "cancelled":
                return .cancelled
            case "notAuthorized":
                return .validationFailed(
                    "This artifact is not shared with the current task")
            case "analysisNotFound", "sessionNotFound":
                return .notFound("The saved local artifact does not exist")
            case "requestInvalid", "requestTooLarge", "descriptorInvalid":
                return .validationFailed("The phone refused this local artifact read")
            case "analysisInvalid", "resultTooLarge", "internal":
                return .internalError("The saved local artifact could not be read")
            default:
                return .internalError("Local artifact read failed (\(code))")
            }
        }
    }
}

public final class G073NetworkArtifactComposition: @unchecked Sendable {
    public static let shared = G073NetworkArtifactComposition()

    private let lock = NSLock()
    private var installedNames: [String] = []
    private let executor: G073NetworkArtifactToolExecutor

    private init() {
        executor = G073NetworkArtifactToolExecutor(
            host: G073NetworkArtifactHostMailbox.shared,
            currentEpoch: { G02NativeRootEpoch.readback() })
    }

    public var isInstalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return !installedNames.isEmpty
    }

    public func installToolsIfNeeded() {
        lock.lock()
        guard installedNames.isEmpty else { lock.unlock(); return }
        installedNames = registerNetworkArtifactTools(executor: executor)
        lock.unlock()
    }

    public func visibleToolNames() -> [String] {
        NetworkArtifactToolNames.all.filter {
            ToolRunnerRegistry.shared.descriptor(named: $0) != nil
        }
    }

    public func readinessJSON() -> String {
        let mailbox = G073NetworkArtifactHostMailbox.shared
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
            "tool": "networkArtifact",
            "installed": installed,
            "bound": mailbox.isBound,
            "epoch": mailbox.boundEpoch,
            "available": available,
            "reason": reason,
            "toolCount": visible.count,
            "registered": visible,
            "expected": NetworkArtifactToolNames.all,
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
