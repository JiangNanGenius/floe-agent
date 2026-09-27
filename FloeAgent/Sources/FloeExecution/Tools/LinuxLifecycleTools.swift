// FloeExecution — model-facing Linux lifecycle tools.
//
// Five explicit capabilities over one owned Linux guest:
//   environment.startLinux / .linuxStatus / .stopLinux /
//   .softRestartLinux / .hardRestartLinux
//
// They share one injected `LinuxGuestLifecycleControlling` service and render
// its truthful receipt. They never accept an image URL or script, never delete
// the environment, and surface the typed refusal as a nonzero-result failure
// instead of a thrown pipeline error. Disruptive operations carry risk labels
// and go through the existing approval/risk system.

import Foundation
import FloeCore
import FloeTools

/// Shared vcpu/memory arguments for start and both restart tools.
public struct LinuxGuestShapeArguments: Decodable, Sendable {
    public var vcpus: Int?
    public var memoryMB: Int?

    public init(vcpus: Int? = nil, memoryMB: Int? = nil) {
        self.vcpus = vcpus
        self.memoryMB = memoryMB
    }
}

enum LinuxLifecycleRendering {
    /// Renders a successful receipt: headline key=value lines plus the full
    /// JSON receipt for structured consumption.
    static func success(_ receipt: LinuxGuestLifecycleReceipt) -> String {
        var lines = [
            "phase=\(receipt.phase.rawValue)",
            "environmentID=\(receipt.environmentID)",
            "actualVCPUs=\(receipt.actualVCPUs)",
            "actualMemoryMB=\(receipt.actualMemoryMB)",
            "reused=\(receipt.reused)",
        ]
        if let requested = receipt.requestedVCPUs { lines.append("requestedVCPUs=\(requested)") }
        if let generation = receipt.launchGeneration { lines.append("launchGeneration=\(generation)") }
        if receipt.servicesStopped > 0 { lines.append("servicesStopped=\(receipt.servicesStopped)") }
        lines.append("detail=\(receipt.detail)")
        if let json = encode(receipt) { lines.append("receipt=\(json)") }
        return lines.joined(separator: "\n")
    }

    static func failure(status: String, error: Error) -> String {
        "status=\(status)\n\(error.localizedDescription)"
    }

    static func encode(_ receipt: LinuxGuestLifecycleReceipt) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(receipt) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum LinuxLifecycleToolSupport {
    /// The environment this call must act on; nil when none is in scope.
    static func environmentID(_ context: ToolContext) -> String? {
        context.environmentID ?? context.environment?.id
    }

    /// Stable exit codes for the typed lifecycle refusals.
    static func exitStatus(for error: LinuxGuestLifecycleError) -> Int32 {
        switch error {
        case .capabilityUnsupported: return 125
        case .invalidConfiguration: return 2
        case .busy, .runningShapeMismatch, .runningMemoryMismatch, .runningShapeUnknown, .activeInteractiveTerminal:
            return 126
        case .notOwned: return 127
        case .stopFailedQuarantined: return 137
        }
    }

    /// The status token paired with the exit code.
    static func statusToken(for error: LinuxGuestLifecycleError) -> String {
        switch error {
        case .capabilityUnsupported: return "unsupported"
        case .invalidConfiguration: return "invalidArgument"
        case .busy: return "busy"
        case .runningShapeMismatch, .runningMemoryMismatch, .runningShapeUnknown: return "shapeConflict"
        case .activeInteractiveTerminal: return "activeTerminal"
        case .notOwned: return "notOwned"
        case .stopFailedQuarantined: return "quarantined"
        }
    }

    /// Runs a lifecycle call and converts its typed errors into honest
    /// nonzero-result outputs, so a refusal never looks like a tool crash.
    static func run(
        call: () async throws -> LinuxGuestLifecycleReceipt
    ) async -> ToolExecutionOutput {
        do {
            let receipt = try await call()
            return ToolExecutionOutput(
                digesting: LinuxLifecycleRendering.success(receipt),
                exitStatus: 0
            )
        } catch FloeError.cancelled {
            return ToolExecutionOutput(digesting: "status=cancelled", exitStatus: 130)
        } catch let error as LinuxGuestLifecycleError {
            return ToolExecutionOutput(
                digesting: LinuxLifecycleRendering.failure(
                    status: statusToken(for: error), error: error
                ),
                exitStatus: exitStatus(for: error)
            )
        } catch {
            return ToolExecutionOutput(
                digesting: LinuxLifecycleRendering.failure(status: "failed", error: error),
                exitStatus: 1
            )
        }
    }
}

// MARK: - start

public struct StartLinuxGuestLifecycleTool: AgentTool {
    public typealias Arguments = LinuxGuestShapeArguments

    public static let name = "environment.startLinux"
    public static let toolDescription =
        "Start this environment's on-device Linux guest (TinyEMU) with an explicit shape. Omit arguments for the default single-core, 256 MiB cold start; set vcpus and memoryMB to choose a shape. An already-running guest is reused untouched and never reset to single core. A shape that contradicts the running guest is refused (stop or hard-restart it first). vcpus=2 is honored only when the installed verified image proves SMP (its kernel/firmware are the dual-hart pair); otherwise the tool returns the image's explicit refusal and never boots one core silently. Dual-core passes the S0–S4 correctness contract but the equal-work benchmark is currently slower on two cores. Reports requested vs actual vCPU/memory and whether the guest was reused."
    public static let parametersJSON = #"""
    {"type":"object","properties":{"vcpus":{"type":"integer","enum":[1,2],"description":"Requested guest cores. 2 requires a verified SMP-capable image; otherwise the call is refused with the image reason."},"memoryMB":{"type":"integer","enum":[256,512,768,1024,1536,2048],"description":"Requested guest RAM in MiB (default 256)."}},"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .executesLocalCode]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let lifecycle: any LinuxGuestLifecycleControlling

    public init(lifecycle: any LinuxGuestLifecycleControlling) {
        self.lifecycle = lifecycle
    }

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let environmentID = LinuxLifecycleToolSupport.environmentID(context) else {
            return ToolExecutionOutput(
                digesting: "status=notOwned\nno environment is in scope for this Linux lifecycle call",
                exitStatus: 127
            )
        }
        let config = LinuxGuestLifecycleConfig(vcpus: args.vcpus, memoryMB: args.memoryMB)
        return await LinuxLifecycleToolSupport.run {
            try await lifecycle.start(
                environmentID: environmentID,
                config: config,
                ownerTaskID: context.runID.uuidString,
                cancellation: context.cancellation
            )
        }
    }
}

// MARK: - status

public struct LinuxGuestStatusLifecycleTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public init() {}
    }

    public static let name = "environment.linuxStatus"
    public static let toolDescription =
        "Read the truthful status of this environment's Linux guest: running or stopped, the actual granted vCPU count and RAM, the image id and launch generation, and any last error. Read-only; it never starts, stops or reconfigures the guest."
    public static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let lifecycle: any LinuxGuestLifecycleControlling

    public init(lifecycle: any LinuxGuestLifecycleControlling) {
        self.lifecycle = lifecycle
    }

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let environmentID = LinuxLifecycleToolSupport.environmentID(context) else {
            return ToolExecutionOutput(
                digesting: "status=notOwned\nno environment is in scope for this Linux lifecycle call",
                exitStatus: 127
            )
        }
        return await LinuxLifecycleToolSupport.run {
            try await lifecycle.status(environmentID: environmentID)
        }
    }
}

// MARK: - stop

public struct StopLinuxGuestLifecycleTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public init() {}
    }

    public static let name = "environment.stopLinux"
    public static let toolDescription =
        "Stop this environment's actual Linux guest instance and verify it left, releasing its lease. The environment, its persistent disk and shares are preserved; nothing is deleted or reset. Managed services in the guest are terminated (the count is reported). Refused while an interactive terminal is open (close it first). A stop that cannot confirm the guest left reports a quarantine failure instead of reusing the disk."
    public static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.executesLocalCode]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let lifecycle: any LinuxGuestLifecycleControlling

    public init(lifecycle: any LinuxGuestLifecycleControlling) {
        self.lifecycle = lifecycle
    }

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let environmentID = LinuxLifecycleToolSupport.environmentID(context) else {
            return ToolExecutionOutput(
                digesting: "status=notOwned\nno environment is in scope for this Linux lifecycle call",
                exitStatus: 127
            )
        }
        return await LinuxLifecycleToolSupport.run {
            try await lifecycle.stop(
                environmentID: environmentID,
                cancellation: context.cancellation
            )
        }
    }
}

// MARK: - soft restart

public struct SoftRestartLinuxGuestLifecycleTool: AgentTool {
    public typealias Arguments = LinuxGuestShapeArguments

    public static let name = "environment.softRestartLinux"
    public static let toolDescription =
        "Request a safe in-guest soft restart with a durable flush, preserving running services where possible. Requires a guest agent that implements ordered flush+durable restart; the current guest image has none, so this returns an explicit unsupported capability (never a false success) — use environment.hardRestartLinux when stopping the actual VM is acceptable. An optional shape may be requested by a future qualified guest."
    public static let parametersJSON = #"""
    {"type":"object","properties":{"vcpus":{"type":"integer","enum":[1,2],"description":"Optional requested cores for a future qualified guest."},"memoryMB":{"type":"integer","enum":[256,512,768,1024,1536,2048],"description":"Optional requested guest RAM in MiB."}},"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .executesLocalCode]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let lifecycle: any LinuxGuestLifecycleControlling

    public init(lifecycle: any LinuxGuestLifecycleControlling) {
        self.lifecycle = lifecycle
    }

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let environmentID = LinuxLifecycleToolSupport.environmentID(context) else {
            return ToolExecutionOutput(
                digesting: "status=notOwned\nno environment is in scope for this Linux lifecycle call",
                exitStatus: 127
            )
        }
        let config = LinuxGuestLifecycleConfig(vcpus: args.vcpus, memoryMB: args.memoryMB)
        return await LinuxLifecycleToolSupport.run {
            try await lifecycle.softRestart(
                environmentID: environmentID,
                config: config,
                cancellation: context.cancellation
            )
        }
    }
}

// MARK: - hard restart

public struct HardRestartLinuxGuestLifecycleTool: AgentTool {
    public typealias Arguments = LinuxGuestShapeArguments

    public static let name = "environment.hardRestartLinux"
    public static let toolDescription =
        "Hard-restart this environment's Linux guest: stop the ACTUAL TinyEMU instance/threads, close its handles and verify it left and its lease was released, then reacquire a safe lease and boot a fresh instance at the requested shape (default single core). The environment is never deleted, and a command reboot inside the guest cannot do this. Open interactive terminals block it; managed services are terminated (count reported). A failed stop quarantines and no new guest boots. vcpus=2 is honored only for a verified SMP-capable image; otherwise the tool returns the image's explicit refusal and never boots one core silently."
    public static let parametersJSON = #"""
    {"type":"object","properties":{"vcpus":{"type":"integer","enum":[1,2],"description":"Requested cores for the new instance. 2 requires a verified SMP-capable image; otherwise the call is refused with the image reason."},"memoryMB":{"type":"integer","enum":[256,512,768,1024,1536,2048],"description":"Requested guest RAM in MiB (default 256)."}},"additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .executesLocalCode]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let lifecycle: any LinuxGuestLifecycleControlling

    public init(lifecycle: any LinuxGuestLifecycleControlling) {
        self.lifecycle = lifecycle
    }

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let environmentID = LinuxLifecycleToolSupport.environmentID(context) else {
            return ToolExecutionOutput(
                digesting: "status=notOwned\nno environment is in scope for this Linux lifecycle call",
                exitStatus: 127
            )
        }
        let config = LinuxGuestLifecycleConfig(vcpus: args.vcpus, memoryMB: args.memoryMB)
        return await LinuxLifecycleToolSupport.run {
            try await lifecycle.hardRestart(
                environmentID: environmentID,
                config: config,
                cancellation: context.cancellation
            )
        }
    }
}
