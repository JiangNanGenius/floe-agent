// FloeExecution — model-facing Linux lifecycle tools.
//
// Six explicit capabilities over one owned Linux guest:
//   environment.startLinux / .linuxStatus / .stopLinux /
//   .softRestartLinux / .hardRestartLinux / .repairLinux
//
// They share one injected `LinuxGuestLifecycleControlling` service and render
// its truthful receipt. They never accept an image URL or script, never delete
// the environment, and surface the typed refusal as a nonzero-result failure
// instead of a thrown pipeline error. Disruptive operations carry risk labels
// and go through the existing approval/risk system. `repairLinux` resolves a
// repairRequired environment through the verified Runtime v2 restore only.

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
        case .busy, .runningShapeMismatch, .runningMemoryMismatch, .runningShapeUnknown,
             .activeInteractiveTerminal, .guestNotRunning:
            return 126
        case .notOwned: return 127
        case .stopFailedQuarantined, .softRestartOutcomeUnknown: return 137
        case .softRestartStageFailed, .softRestartIdempotencyConflict,
             .softRestartPersistenceFailed: return 1
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
        case .guestNotRunning: return "notRunning"
        case .softRestartStageFailed: return "softRestartFailed"
        case .softRestartOutcomeUnknown: return "softRestartUnknown"
        case .softRestartIdempotencyConflict: return "idempotencyConflict"
        case .softRestartPersistenceFailed: return "persistenceFailed"
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
        "Start or reuse this task's project in the shared on-device ARM64 Linux runtime. Omit vcpus and memoryMB to preserve the shared configuration (initially 2 CPUs and 512 MiB). Supports 1–4 online CPUs; changing CPUs uses kernel hotplug without restarting Linux, losing shell state or disrupting other projects. All projects share the CPU setting. RAM changes require stopping active projects first and are never applied by an implicit restart. Reports requested and actual resources and whether the task's project was reused."
    public static let parametersJSON = #"""
    {"type":"object","properties":{"vcpus":{"type":"integer","enum":[1,2,3,4],"description":"Online CPUs for the shared runtime. Omit to preserve the current setting. CPU-only changes do not restart Linux."},"memoryMB":{"type":"integer","enum":[256,512,768,1024],"description":"Shared RAM in MiB. Omit to preserve the current setting. A running runtime refuses a different memory size without restarting it."}},"additionalProperties":false}
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
        public var scope: String?
        public init(scope: String? = nil) { self.scope = scope }
    }

    public static let name = "environment.linuxStatus"
    public static let toolDescription =
        "Read Linux power and resources without changing them. Default scope=task reports this environment's project session, actual CPUs/RAM, image, generation, last error and recorded disk-recovery requirement; stopped does not mean damaged. scope=shared reports the physical ARM64 machine, actual project leases, live owner runIDs, commands, terminals, services and forwards. Use those runIDs with conversation.message to coordinate before environment.powerLinux; verify real ownership again after any acknowledgement."
    public static let parametersJSON = #"{"type":"object","properties":{"scope":{"type":"string","enum":["task","shared"],"description":"Default task. shared inspects physical power and all current project/task owners; never starts Linux."}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let lifecycle: any LinuxGuestLifecycleControlling
    private let sharedPower: LinuxSharedPowerService?

    public init(lifecycle: any LinuxGuestLifecycleControlling, sharedPower: LinuxSharedPowerService? = nil) {
        self.lifecycle = lifecycle
        self.sharedPower = sharedPower
    }

    public func validate(_ args: Arguments) throws {
        guard args.scope == nil || args.scope == "task" || args.scope == "shared" else {
            throw FloeError.validationFailed("Unknown Linux status scope")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        if args.scope == "shared" {
            guard let sharedPower else {
                return ToolExecutionOutput(digesting: "status=unsupported\nShared-machine inspection is unavailable", exitStatus: 125)
            }
            try context.cancellation.throwIfCancelled()
            let snapshot = try await sharedPower.inspect()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return ToolExecutionOutput(digesting: String(decoding: try encoder.encode(snapshot), as: UTF8.self), exitStatus: 0)
        }
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
        "Soft-restart this environment's Linux guest: the running guest executes an ordered filesystem flush, records the operation receipt and powers ITSELF off; the exited disk is captured and a fresh instance reconnects at the preserved (or explicitly requested) shape. The reboot is verified by the actual guest exit, a rotated launch generation and the pre-reboot receipt read back from the persistent disk — never by an echo or a lost channel. Requires a running guest image with the ordered flush+poweroff capability (an explicit unsupported error otherwise). Open interactive terminals block it; managed services are terminated (count reported). An interrupted operation stays reconcilable: a retry converges against current state instead of blindly repeating. Use environment.hardRestartLinux when an unproven stop of the actual VM is acceptable."
    public static let parametersJSON = #"""
    {"type":"object","properties":{"vcpus":{"type":"integer","enum":[1,2,3,4],"description":"Optional cores for the replacement. Omitted dimensions preserve the running guest's granted shape; The installed image must support that core count."},"memoryMB":{"type":"integer","enum":[256,512,768,1024,1536,2048],"description":"Optional replacement RAM in MiB. Omitted dimensions preserve the running guest's granted tier."}},"additionalProperties":false}
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
        // Trusted identity for the durable operation record: the run and the
        // durable tool-call idempotency key are host-minted, never model-
        // authored.
        let operationKey = context.toolIdempotencyKey.isEmpty
            ? context.toolCallID
            : context.toolIdempotencyKey
        return await LinuxLifecycleToolSupport.run {
            try await lifecycle.softRestart(
                environmentID: environmentID,
                config: config,
                ownerTaskID: context.runID.uuidString,
                operationKey: operationKey,
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
        "Restart the resolved project's Linux session, preserving its files and dependencies. On the shared ARM64 backend this closes and reopens that project's runner; it is not a physical-machine reboot and does not replay commands. Omitted resource values preserve saved shared settings. A running CPU count supports online updates through environment.startLinux; no restart is needed just to change CPUs. For physical shared-machine shutdown/restart use environment.powerLinux after inspecting and coordinating actual owners. Open interactive terminals block project restart; managed services are terminated and reported. A failed stop retains the quarantine and refuses a replacement."
    public static let parametersJSON = #"""
    {"type":"object","properties":{"vcpus":{"type":"integer","enum":[1,2,3,4],"description":"Requested cores for the new instance. The installed image must support that core count; otherwise the call is refused with the image reason."},"memoryMB":{"type":"integer","enum":[256,512,768,1024,1536,2048],"description":"Requested guest RAM in MiB. Omit to preserve the running or last successful value; a new shared runtime uses 512."}},"additionalProperties":false}
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

// MARK: - verified disk repair

public struct RepairLinuxGuestLifecycleTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public init() {}
    }

    public static let name = "environment.repairLinux"
    public static let toolDescription =
        "Inspect this task environment's recorded Linux disk-recovery state. If no recovery is required, return resolution=notRequired without stopping, restarting or changing any files; a powered-off runtime is not evidence of damage. Only a confirmed recovery exclusion permits restoring preserved disk bytes after provenance and content verification. Recovery refuses an active guest or lifecycle operation and retains the preserved bytes on failure. This tool does not reset the shared ARM64 machine, reinstall dependencies or claim a complete operating-system health check. Use environment.linuxStatus to inspect power/resources, environment.startLinux to power on or change online CPUs, and the explicit restart/stop tools for those actions."
    public static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
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
        do {
            let receipt = try await lifecycle.repair(
                environmentID: environmentID,
                cancellation: context.cancellation
            )
            var lines = [
                "resolution=\(receipt.resolution)",
                "environmentID=\(receipt.environmentID)",
            ]
            if let path = receipt.preservedPath { lines.append("preservedPath=\(path)") }
            if let generation = receipt.restoredGeneration {
                lines.append("restoredGeneration=\(generation)")
            }
            if let digest = receipt.diskDigestSHA512 { lines.append("diskSHA512=\(digest)") }
            lines.append("detail=\(receipt.detail)")
            return ToolExecutionOutput(digesting: lines.joined(separator: "\n"), exitStatus: 0)
        } catch FloeError.cancelled {
            return ToolExecutionOutput(digesting: "status=cancelled", exitStatus: 130)
        } catch let error as LinuxGuestLifecycleError {
            return ToolExecutionOutput(
                digesting: LinuxLifecycleRendering.failure(status: "repairRefused", error: error),
                exitStatus: 125
            )
        } catch {
            return ToolExecutionOutput(
                digesting: LinuxLifecycleRendering.failure(status: "failed", error: error),
                exitStatus: 1
            )
        }
    }
}
