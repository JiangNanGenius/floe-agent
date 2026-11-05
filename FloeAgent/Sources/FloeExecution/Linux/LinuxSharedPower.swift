import Foundation
import FloeCore
import FloeTools

/// Physical shared-machine state. Project leases are reported separately;
/// an empty lease list alone does not prove that the machine powered off.
public enum LinuxSharedMachinePhase: String, Sendable, Codable {
    case poweredOff, starting, running, stopping, failed
}

public enum LinuxSharedPowerAction: String, Sendable, Codable {
    case shutdown, restart
}

public struct LinuxSharedRuntimeOwner: Sendable, Codable {
    public var runID: UUID
    public var environmentID: String
    public var title: String?
    public init(runID: UUID, environmentID: String, title: String? = nil) {
        self.runID = runID; self.environmentID = environmentID; self.title = title
    }
}

public struct LinuxSharedPowerSnapshot: Sendable, Codable {
    public var phase: LinuxSharedMachinePhase
    public var vcpus: Int?
    public var memoryMB: Int?
    public var activities: [LinuxGuestActivityDetail]
    public var activeRuns: [LinuxSharedRuntimeOwner]
}

public struct LinuxSharedPowerReceipt: Sendable, Codable {
    public var action: LinuxSharedPowerAction
    public var before: LinuxSharedPowerSnapshot
    public var after: LinuxSharedPowerSnapshot
    public var stoppedEnvironmentIDs: [String]
    public var restartedEnvironmentID: String?
    public var cancelledAfterShutdown: Bool
}

/// Reuses the registry's actual shared machine and the existing project
/// start lifecycle. It never chooses a project, replays commands or resets
/// files/dependencies. Only a native-checked occupancy snapshot may authorize
/// stopping other projects; model arguments cannot mint that snapshot.
public actor LinuxSharedPowerService {
    private let controller: any LinuxGuestControlling
    private let lifecycle: any LinuxGuestLifecycleControlling
    private let onStopped: @Sendable ([String]) async -> Void
    private let activeRuns: @Sendable (Set<String>) async -> [LinuxSharedRuntimeOwner]
    private var busy = false

    public init(controller: any LinuxGuestControlling,
                lifecycle: any LinuxGuestLifecycleControlling,
                onStopped: @escaping @Sendable ([String]) async -> Void = { _ in },
                activeRuns: @escaping @Sendable (Set<String>) async -> [LinuxSharedRuntimeOwner] = { _ in [] }) {
        self.controller = controller
        self.lifecycle = lifecycle
        self.onStopped = onStopped
        self.activeRuns = activeRuns
    }

    public func inspect() async throws -> LinuxSharedPowerSnapshot {
        guard let phase = await controller.sharedMachinePhase() else {
            throw LinuxGuestError.invalidConfiguration("This backend does not expose shared-machine power control")
        }
        let resources = await controller.sharedGuestConfiguration()
        let activities = await controller.guestActivityDetails()
        return LinuxSharedPowerSnapshot(phase: phase, vcpus: resources?.vcpus,
            memoryMB: resources?.memoryMB, activities: activities,
            activeRuns: await activeRuns(Set(activities.map(\.environmentID))))
    }

    public func perform(_ action: LinuxSharedPowerAction, environmentID: String,
                        ownerRunID: UUID, allowingActiveEnvironmentIDs: Set<String>,
                        allowingActiveRunIDs: Set<UUID>,
                        observedActivities: [LinuxGuestActivityDetail]? = nil,
                        cancellation: CancellationToken) async throws -> LinuxSharedPowerReceipt {
        guard !busy else { throw LinuxGuestError.guestBusy(environmentID: "shared") }
        busy = true
        defer { busy = false }
        try cancellation.throwIfCancelled()
        let before = try await inspect()
        guard Set(before.activeRuns.map(\.runID)).isSubset(of: allowingActiveRunIDs) else {
            throw LinuxGuestError.invalidConfiguration("The active tasks changed; inspect and coordinate with their current owners again")
        }
        let target = await controller.guestStatus(environmentID: environmentID)
        guard target.imageID != nil else { throw LinuxGuestError.notOwned(environmentID: environmentID) }
        // The registry rechecks this set while holding the physical-machine
        // start fence. A new owner after inspection/approval causes refusal.
        let activities = observedActivities ?? before.activities
        guard Set(activities.map(\.environmentID)).isSubset(of: allowingActiveEnvironmentIDs) else {
            throw LinuxGuestError.guestBusy(environmentID: "shared")
        }
        let stopped = try await controller.stopSharedGuest(allowing: activities)
        await onStopped(stopped)
        if action == .restart, !cancellation.isCancelled, !Task.isCancelled {
            _ = try await lifecycle.start(environmentID: environmentID, config: .init(),
                ownerTaskID: ownerRunID.uuidString, cancellation: cancellation)
        }
        let after = try await inspect()
        if action == .shutdown, after.phase != .poweredOff {
            throw LinuxGuestError.stopFailed(environmentID: "shared", detail: "The physical machine did not confirm power off")
        }
        return LinuxSharedPowerReceipt(action: action, before: before, after: after,
            stoppedEnvironmentIDs: stopped,
            restartedEnvironmentID: action == .restart && after.phase == .running ? environmentID : nil,
            cancelledAfterShutdown: cancellation.isCancelled || Task.isCancelled)
    }
}
