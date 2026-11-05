import Foundation
import FloeCore
import FloeTools

public struct LinuxSharedPowerTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var action: LinuxSharedPowerAction
        public var force: Bool?
        public init(action: LinuxSharedPowerAction, force: Bool? = nil) {
            self.action = action; self.force = force
        }
    }
    public static let name = "environment.powerLinux"
    public static let toolDescription = "Power off or restart the entire shared ARM64 Linux machine, preserving project files, installed software, dependencies and Skill records. This differs from stopping/restarting one project session. Inspect environment.linuxStatus scope=shared for physical power, actual project leases and live runIDs. When other tasks still own work, the default returns coordinationRequired without changing anything: use conversation.message to coordinate release, inspect again, then retry. A message acknowledgement alone is not release evidence. force=true interrupts other work only with the existing human approval, and ownership is rechecked before stopping. restart boots only the requesting task's resolved Linux project; it never replays commands or chooses another project. Cancellation after power-off leaves the machine off instead of reviving it."
    public static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["shutdown","restart"]},"force":{"type":"boolean","description":"Default false. A forced interruption of other tasks requires the existing human approval; this argument is not authorization."}},"required":["action"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.executesLocalCode]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    private let service: LinuxSharedPowerService
    public init(service: LinuxSharedPowerService) { self.service = service }
    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let environmentID = context.environmentID ?? context.environment?.id else {
            return ToolExecutionOutput(digesting: "status=notOwned\nNo task execution environment is in scope", exitStatus: 127)
        }
        do {
            try context.cancellation.throwIfCancelled()
            let state = try await service.inspect()
            let otherRuns = state.activeRuns.filter { $0.runID != context.runID }
            let busy = state.activities.filter { activity in
                if otherRuns.contains(where: { $0.environmentID == activity.environmentID }) { return true }
                if activity.environmentID == environmentID, activity.ownerRunID == context.runID.uuidString {
                    return activity.activeTerminalCount > 0
                }
                return activity.starting || activity.quarantined || activity.activeCommandCount > 0
                    || activity.activeTerminalCount > 0 || activity.activeServiceCount > 0
                    || activity.requestedForwardCount > 0
            }
            if !otherRuns.isEmpty || !busy.isEmpty {
                if args.force != true {
                    return try Self.output([
                        "status": "coordinationRequired",
                        "coordinationTool": "conversation.message",
                        "note": "No power action ran. Coordinate with the observed owners, then recheck actual runtime ownership.",
                        "runtime": Self.jsonValue(state)
                    ], exit: 75)
                }
                if context.approvalOrigin != .humanCard {
                    guard let approval = context.nestedApproval else {
                        return ToolExecutionOutput(digesting: "status=approvalRequired\nOther work still owns the runtime; no power action ran", exitStatus: 77)
                    }
                    let format = FloeL10n.l("execution.power.confirm_other")
                    let reason = String(format: format == "execution.power.confirm_other"
                        ? "This will stop work in %ld other runtime projects. Files and installed software are kept. Continue?" : format,
                        max(busy.count, Set(otherRuns.map(\.environmentID)).count))
                    guard await approval.request(reason: reason) == .allowed else {
                        return ToolExecutionOutput(digesting: "status=notApproved\nNo power action ran", exitStatus: 77)
                    }
                }
            }
            try context.cancellation.throwIfCancelled()
            let receipt = try await service.perform(args.action, environmentID: environmentID,
                ownerRunID: context.runID,
                allowingActiveEnvironmentIDs: Set(state.activities.map(\.environmentID)),
                allowingActiveRunIDs: Set(state.activeRuns.map(\.runID)),
                observedActivities: state.activities, cancellation: context.cancellation)
            return try Self.output(Self.jsonValue(receipt), exit: 0)
        } catch is CancellationError {
            return ToolExecutionOutput(digesting: "status=cancelled\nInspect current power before retrying", exitStatus: 130)
        } catch FloeError.cancelled {
            return ToolExecutionOutput(digesting: "status=cancelled\nInspect current power before retrying", exitStatus: 130)
        } catch {
            return ToolExecutionOutput(digesting: "status=powerFailed\n\(error.localizedDescription)", exitStatus: 1)
        }
    }

    private static func jsonValue<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    private static func output(_ value: Any, exit: Int32) throws -> ToolExecutionOutput {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return ToolExecutionOutput(digesting: String(decoding: data, as: UTF8.self), exitStatus: exit)
    }
}
