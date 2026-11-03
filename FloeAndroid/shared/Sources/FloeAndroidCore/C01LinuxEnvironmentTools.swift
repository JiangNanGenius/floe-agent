// SPDX-License-Identifier: MPL-2.0
//
// C01LinuxEnvironmentTools — truthful model-facing environment lifecycle for
// the on-device PRoot Linux engine.
//
// This is NOT the iOS TinyEMU lifecycle. The Android engine has no per-start
// VM shape (vcpus/memoryMB), no VM soft/hard restart and no guest-image repair:
// it is an installed Debian rootfs executed by the separate runtime UID,
// installed and started through the EXISTING Kotlin `LocalRuntimeSetupHost`
// (`status` / `install.start` / `install.status` / `install.cancel`) and the
// runtime service `status` operation. Registering a pretend VM shape or a
// no-op restart would lie to the model; those names are deliberately absent.
//
// The tools are registered ONLY after Main installs a real host port
// (`C01LinuxEnvironmentHosting`). The production implementation is the bounded
// mailbox operation `host.environmentControl`, answered by the app's
// `C01LinuxEnvironmentOwner`; when that owner is not attached the domain
// answers `hostNotWired` and no tool is registered. There is no host-mode
// fallback and no fabricated `ready`.
//
// Typed outcomes: `ready`, `installRequired`, `pending`, `refused`, `failed`,
// `stopping`, `stopped`, `unknown`. A missing rootfs/download/user permission
// returns `installRequired` with actionable host-flow guidance; it never
// returns `ready`.
import Foundation
import FloeCore
import FloeTools

// MARK: - Typed host snapshot

public struct C01LinuxEnvironmentSnapshot: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case unknown
        case componentRequired
        case setupRequired
        case installRequired
        case installing
        case installed
        case ready
        case pending
        case stopping
        case stopped
        case refused
        case failed
    }

    public var phase: Phase
    /// The exact environment the host resolved, when one was in scope.
    public var environmentID: String?
    /// True only when the runtime service reports owned activity.
    public var runtimeActive: Bool
    /// True while the existing stop/drain gate is running.
    public var runtimeStopping: Bool
    /// The runtime's own published workload contract, when readable.
    public var contractVersion: String?
    /// Real component/package match from the existing setup authority.
    public var componentMatches: Bool
    /// Core's own live qualification at the same generation.
    public var readinessQualified: Bool
    public var installed: Bool
    /// True only for a phase the model can act on through the host flow.
    public var installRequired: Bool
    public var retryable: Bool
    /// Bounded actionable detail (never a raw path, command or credential).
    public var detail: String

    public init(phase: Phase,
                environmentID: String? = nil,
                runtimeActive: Bool = false,
                runtimeStopping: Bool = false,
                contractVersion: String? = nil,
                componentMatches: Bool = false,
                readinessQualified: Bool = false,
                installed: Bool = false,
                installRequired: Bool = false,
                retryable: Bool = false,
                detail: String = "") {
        self.phase = phase
        self.environmentID = environmentID
        self.runtimeActive = runtimeActive
        self.runtimeStopping = runtimeStopping
        self.contractVersion = contractVersion
        self.componentMatches = componentMatches
        self.readinessQualified = readinessQualified
        self.installed = installed
        self.installRequired = installRequired
        self.retryable = retryable
        self.detail = String(detail.prefix(512))
    }

    /// The only phases that mean "the engine can accept ordinary work".
    public var isUsable: Bool { phase == .ready || phase == .installed }
}

// MARK: - Host port (installed by Main)

/// Trusted app-side environment control. Every implementation must use the
/// REAL existing setup/runtime-service operations; a stub returning ready is
/// forbidden. `status` is read-only; `start` may trigger the existing hosted
/// install flow but must return `installRequired` rather than pretending;
/// `stop` must go through the existing root stop/drain gate.
public protocol C01LinuxEnvironmentHosting: Sendable {
    func status(environmentID: String?) async -> C01LinuxEnvironmentSnapshot
    func start(environmentID: String?, cancellation: CancellationToken) async -> C01LinuxEnvironmentSnapshot
    func stop(environmentID: String?, cancellation: CancellationToken) async -> C01LinuxEnvironmentSnapshot
}

/// Bounded mailbox adapter. This is the production transport; the Kotlin
/// `C01LinuxEnvironmentOwner` answers the operation from the REAL setup host
/// and runtime service. It is fail-closed when the mailbox is unbound.
public struct C01LinuxEnvironmentMailboxHost: C01LinuxEnvironmentHosting {
    public static let operation = "host.environmentControl"
    public static let maximumReplyBytes = 16 * 1024

    private let epoch: @Sendable () -> UInt64

    public init(epoch: @escaping @Sendable () -> UInt64) {
        self.epoch = epoch
    }

    public func status(environmentID: String?) async -> C01LinuxEnvironmentSnapshot {
        await submit(action: "status", environmentID: environmentID)
    }

    public func start(environmentID: String?, cancellation: CancellationToken) async -> C01LinuxEnvironmentSnapshot {
        if cancellation.isCancelled {
            return C01LinuxEnvironmentSnapshot(phase: .refused, environmentID: environmentID,
                                               detail: "The lifecycle request was cancelled before admission.")
        }
        return await submit(action: "start", environmentID: environmentID)
    }

    public func stop(environmentID: String?, cancellation: CancellationToken) async -> C01LinuxEnvironmentSnapshot {
        if cancellation.isCancelled {
            return C01LinuxEnvironmentSnapshot(phase: .refused, environmentID: environmentID,
                                               detail: "The stop request was cancelled before admission; nothing was changed.")
        }
        // The Android engine is app-global: a stop is never scoped to one
        // task while another task's run/job/session/service is still live.
        // Check the REAL owned-work surfaces first; the host repeats the
        // check under its own gate.
        let jobsLive = await RuntimeFacadeJobBindings.shared.hasLiveJobWork()
        let drained = await RuntimeFacadeLinuxBindings.shared.isDrained()
        if jobsLive || !drained {
            return C01LinuxEnvironmentSnapshot(
                phase: .refused, environmentID: environmentID, retryable: true,
                detail: "Another task's run, job, terminal or managed service still owns work in this environment; stop it explicitly first.")
        }
        return await submit(action: "stop", environmentID: environmentID)
    }

    private func submit(action: String, environmentID: String?) async -> C01LinuxEnvironmentSnapshot {
        let currentEpoch = epoch()
        guard currentEpoch > 0 else {
            return C01LinuxEnvironmentSnapshot(
                phase: .refused, environmentID: environmentID,
                detail: "The Linux runtime generation is not bound; nothing was changed.")
        }
        var payload: [String: Any] = ["action": action, "epoch": currentEpoch]
        if let environmentID, !environmentID.isEmpty {
            payload["environmentID"] = String(environmentID.prefix(128))
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return C01LinuxEnvironmentSnapshot(phase: .failed, environmentID: environmentID,
                                               detail: "The lifecycle request could not be encoded.")
        }
        do {
            let reply = try await LinuxShellMailbox.shared.submit(
                operation: Self.operation, payload: data, timeoutMillis: 30_000)
            guard reply.count <= Self.maximumReplyBytes,
                  let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
                  let rawPhase = object["phase"] as? String,
                  let phase = C01LinuxEnvironmentSnapshot.Phase(rawValue: rawPhase) else {
                return C01LinuxEnvironmentSnapshot(phase: .failed, environmentID: environmentID,
                                                   detail: "The host returned an unreadable lifecycle receipt.")
            }
            // Core is the only authority for live qualification; the host
            // reports the setup/install truth and must not self-declare ready.
            let qualified = RuntimeFacadeLinuxBindings.shared.isCapabilityQualified
            var resolvedPhase: C01LinuxEnvironmentSnapshot.Phase =
                (phase == .installed && qualified) ? .ready : phase
            var resolvedDetail = object["detail"] as? String ?? ""
            if !qualified, resolvedPhase == .ready {
                resolvedPhase = action == "start" ? .pending : .installed
                resolvedDetail = "The runtime is active but Core has not qualified shell work in this generation; complete setup/ingress and retry."
            } else if action == "start", !qualified, resolvedPhase == .installed {
                // Installed is not yet usable: the real ingress facts are
                // still missing. Report pending rather than a start success.
                resolvedPhase = .pending
                resolvedDetail = "The runtime is installed but not yet qualified for shell work; complete setup and wait for readiness."
            }
            return C01LinuxEnvironmentSnapshot(
                phase: resolvedPhase,
                environmentID: object["environmentID"] as? String ?? environmentID,
                runtimeActive: object["runtimeActive"] as? Bool ?? false,
                runtimeStopping: object["runtimeStopping"] as? Bool ?? false,
                contractVersion: (object["contractVersion"] as? String).map { String($0.prefix(64)) },
                componentMatches: object["componentMatches"] as? Bool ?? false,
                readinessQualified: qualified,
                installed: object["installed"] as? Bool ?? (resolvedPhase == .installed || resolvedPhase == .ready),
                installRequired: object["installRequired"] as? Bool ?? (resolvedPhase == .installRequired),
                retryable: object["retryable"] as? Bool ?? false,
                detail: resolvedDetail)
        } catch {
            return C01LinuxEnvironmentSnapshot(
                phase: .refused, environmentID: environmentID,
                detail: "The environment host is not reachable in this generation; nothing was changed.")
        }
    }
}

// MARK: - Domain registry

/// One installed host per process generation. Installation is a trusted Main
/// composition step; the model can never install or replace it.
public final class C01LinuxEnvironmentDomain: @unchecked Sendable {
    public static let shared = C01LinuxEnvironmentDomain()

    private let lock = NSLock()
    private var hostStorage: (any C01LinuxEnvironmentHosting)?
    private var epochStorage: UInt64 = 0

    private init() {}

    /// Install/replace the exact-generation host. A zero epoch or nil host
    /// clears the slot (fail closed).
    public func install(_ host: (any C01LinuxEnvironmentHosting)?, epoch: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if epoch == 0 || host == nil {
            hostStorage = nil
            epochStorage = 0
            return
        }
        hostStorage = host
        epochStorage = epoch
    }

    @discardableResult
    public func retire(epoch: UInt64, registry: ToolRunnerRegistry = .shared) -> Bool {
        lock.lock()
        let matches = epochStorage == epoch
        if matches {
            hostStorage = nil
            epochStorage = 0
        }
        lock.unlock()
        guard matches else { return false }
        unregister(registry: registry)
        return true
    }

    public var installedEpoch: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return epochStorage
    }

    var host: (any C01LinuxEnvironmentHosting)? {
        lock.lock(); defer { lock.unlock() }
        return hostStorage
    }

    /// Register the three truthful lifecycle names. Returns false when no
    /// host was installed (never a fake host-mode fallback). Idempotent. The
    /// runners resolve the CURRENT installed host on every call, so a
    /// retirement/failed rebind makes them fail closed instead of retaining
    /// an old generation's controls.
    @discardableResult
    public func register(registry: ToolRunnerRegistry = .shared) -> Bool {
        guard host != nil else { return false }
        ToolCatalog.register(C01LinuxEnvironmentStatusTool.self)
        ToolCatalog.register(C01LinuxEnvironmentStartTool.self)
        ToolCatalog.register(C01LinuxEnvironmentStopTool.self)
        registry.register(C01LinuxEnvironmentStatusTool())
        registry.register(C01LinuxEnvironmentStartTool())
        registry.register(C01LinuxEnvironmentStopTool())
        return true
    }

    public func unregister(registry: ToolRunnerRegistry = .shared) {
        let names = Set(C01LinuxEnvironmentToolNames.all)
        registry.unregister { names.contains(ToolAliasTable.canonical($0)) }
    }
}

public enum C01LinuxEnvironmentToolNames {
    public static let status = "environment.linuxStatus"
    public static let start = "environment.startLinux"
    public static let stop = "environment.stopLinux"
    public static let all: [String] = [status, start, stop]
}

// MARK: - Rendering

enum C01LinuxEnvironmentRendering {
    static func text(_ snapshot: C01LinuxEnvironmentSnapshot) -> String {
        var lines = [
            "phase=\(snapshot.phase.rawValue)",
            "installed=\(snapshot.installed)",
            "runtimeActive=\(snapshot.runtimeActive)",
            "runtimeStopping=\(snapshot.runtimeStopping)",
            "componentMatches=\(snapshot.componentMatches)",
            "qualified=\(snapshot.readinessQualified)",
            "installRequired=\(snapshot.installRequired)",
            "retryable=\(snapshot.retryable)",
        ]
        if let environmentID = snapshot.environmentID, !environmentID.isEmpty {
            lines.append("environmentID=\(environmentID)")
        }
        if let contract = snapshot.contractVersion, !contract.isEmpty {
            lines.append("contractVersion=\(contract)")
        }
        if !snapshot.detail.isEmpty { lines.append("detail=\(snapshot.detail)") }
        return lines.joined(separator: "\n")
    }

    static func exitStatus(_ snapshot: C01LinuxEnvironmentSnapshot) -> Int32 {
        switch snapshot.phase {
        case .ready, .installed, .pending, .installing, .stopping, .stopped:
            return 0
        case .installRequired, .componentRequired, .setupRequired:
            return 75 // not started; the caller has an actionable host step
        case .refused:
            return 126
        case .failed, .unknown:
            return 125
        }
    }
}

// MARK: - Tools

public struct C01LinuxEnvironmentStatusTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public init() {}
    }

    public static let name = C01LinuxEnvironmentToolNames.status
    public static let toolDescription =
        "Read the truthful status of this environment's on-device Linux engine: installed phase, whether the runtime is active or stopping, the published workload contract, component match, and whether the engine is qualified for shell work. Read-only; it never installs, starts, stops or changes the environment."
    public static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    public init() {}

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let host = C01LinuxEnvironmentDomain.shared.host else {
            return ToolExecutionOutput(
                digesting: "phase=refused\ndetail=The environment host is not installed in this generation; nothing was changed.",
                exitStatus: 126)
        }
        let snapshot = await host.status(environmentID: context.environmentID ?? context.environment?.id)
        return ToolExecutionOutput(
            digesting: C01LinuxEnvironmentRendering.text(snapshot),
            exitStatus: C01LinuxEnvironmentRendering.exitStatus(snapshot))
    }
}

public struct C01LinuxEnvironmentStartTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public init() {}
    }

    public static let name = C01LinuxEnvironmentToolNames.start
    public static let toolDescription =
        "Prepare this environment's real on-device Linux engine. The Android engine is an installed PRoot Debian userland, not a VM: there are no vcpus or memoryMB shape parameters. If the rootfs/component is not installed, this returns installRequired with the exact user-facing setup action instead of pretending to start; if installation is already running it returns pending. Ready is reported only from the host's real install/runtime status."
    public static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .executesLocalCode]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    public init() {}

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let host = C01LinuxEnvironmentDomain.shared.host else {
            return ToolExecutionOutput(
                digesting: "phase=refused\ndetail=The environment host is not installed in this generation; nothing was started.",
                exitStatus: 126)
        }
        let snapshot = await host.start(
            environmentID: context.environmentID ?? context.environment?.id,
            cancellation: context.cancellation)
        return ToolExecutionOutput(
            digesting: C01LinuxEnvironmentRendering.text(snapshot),
            exitStatus: C01LinuxEnvironmentRendering.exitStatus(snapshot))
    }
}

public struct C01LinuxEnvironmentStopTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public init() {}
    }

    public static let name = C01LinuxEnvironmentToolNames.stop
    public static let toolDescription =
        "Stop this environment's Linux engine through the existing root stop/drain gate after all owned work in it is drained and released. Refused while another task's run, job, terminal or managed service still owns work; the environment's files are preserved. Reports stopping until the host proves the stop, never a fake stopped state."
    public static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.executesLocalCode]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    public init() {}

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let host = C01LinuxEnvironmentDomain.shared.host else {
            return ToolExecutionOutput(
                digesting: "phase=refused\ndetail=The environment host is not installed in this generation; nothing was stopped.",
                exitStatus: 126)
        }
        let snapshot = await host.stop(
            environmentID: context.environmentID ?? context.environment?.id,
            cancellation: context.cancellation)
        return ToolExecutionOutput(
            digesting: C01LinuxEnvironmentRendering.text(snapshot),
            exitStatus: C01LinuxEnvironmentRendering.exitStatus(snapshot))
    }
}
