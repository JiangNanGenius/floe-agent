// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Simulated machine state at one point in the schedule. Pure value type;
/// the planner produces the start and end snapshots and a chronological
/// event list so Root's executor can replay and drive the real machines.
public struct CellMachineState: Codable, Equatable, Sendable {
    public struct SpindleState: Codable, Equatable, Sendable {
        public enum Mode: String, Codable, Sendable, CaseIterable {
            case stopped, rpm, cIndex
        }
        public var mode: Mode
        public var rpm: Double?
        public var cIndexDegrees: Double?
        /// Commanded direction about +Z; meaningful in RPM mode.
        public var direction: CellRotationDirection?
        /// Phase datum in degrees at `phaseReferenceSeconds`.
        public var phaseDatumDegrees: Double?
        /// Schedule seconds at which `phaseDatumDegrees` was captured.
        public var phaseReferenceSeconds: Double
        public var chuckOpeningDiameterMM: Double
        public var maxOpeningDiameterMM: Double
        public var clampedWorkpieceID: String?
        public var gripLengthMM: Double?
        /// Current world position of the chuck mouth (carriage position);
        /// starts at the spindle frame origin and moves with transfer
        /// approach/retract.
        public var carriagePositionMM: [Double]?
        public init(mode: Mode, rpm: Double? = nil, cIndexDegrees: Double? = nil,
                    direction: CellRotationDirection? = nil,
                    phaseDatumDegrees: Double? = nil, phaseReferenceSeconds: Double = 0,
                    chuckOpeningDiameterMM: Double, maxOpeningDiameterMM: Double,
                    clampedWorkpieceID: String? = nil, gripLengthMM: Double? = nil,
                    carriagePositionMM: [Double]? = nil) {
            self.mode = mode; self.rpm = rpm; self.cIndexDegrees = cIndexDegrees
            self.direction = direction
            self.phaseDatumDegrees = phaseDatumDegrees
            self.phaseReferenceSeconds = phaseReferenceSeconds
            self.chuckOpeningDiameterMM = chuckOpeningDiameterMM
            self.maxOpeningDiameterMM = maxOpeningDiameterMM
            self.clampedWorkpieceID = clampedWorkpieceID; self.gripLengthMM = gripLengthMM
            self.carriagePositionMM = carriagePositionMM
        }
        /// Commanded phase in degrees at an absolute schedule time. RPM mode
        /// integrates direction × rpm × 6 deg/s from the datum; C-index mode
        /// is positioning (phase = C value); stopped holds the datum. This is
        /// a commanded value, never a measured hardware proof.
        public func phase(atSeconds time: Double) -> Double? {
            guard let datum = phaseDatumDegrees else { return nil }
            let value: Double
            switch mode {
            case .stopped: value = datum
            case .cIndex: value = cIndexDegrees ?? datum
            case .rpm:
                guard let rpm, let direction else { return datum }
                value = datum + direction.sign * rpm * 6 * (time - phaseReferenceSeconds)
            }
            let wrapped = value.truncatingRemainder(dividingBy: 360)
            return wrapped < 0 ? wrapped + 360 : wrapped
        }
    }
    public struct TurretState: Codable, Equatable, Sendable {
        public var stationID: String
        public var parked: Bool
        public init(stationID: String, parked: Bool) { self.stationID = stationID; self.parked = parked }
    }
    public var spindleStates: [String: SpindleState]
    public var turretStates: [String: TurretState]
    /// workpiece id -> owner spindle id. A nil/absent entry means the part is
    /// between chucks; a resting schedule end state must own every part.
    public var workpieceOwners: [String: String?]
    public var workpieceTransforms: [String: CellRigidTransform]
    public init(spindleStates: [String: SpindleState], turretStates: [String: TurretState],
                workpieceOwners: [String: String?], workpieceTransforms: [String: CellRigidTransform]) {
        self.spindleStates = spindleStates; self.turretStates = turretStates
        self.workpieceOwners = workpieceOwners; self.workpieceTransforms = workpieceTransforms
    }
    public func owner(of workpieceID: String) -> String? { workpieceOwners[workpieceID] ?? nil }
}

/// Chronological machine event. `seconds` is schedule time; simultaneous
/// events are ordered deterministically (started before completed before
/// detailed state changes, then by step and kind).
public struct CellMachineEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case stepStarted, stepCompleted
        case spindleModeChanged
        case chuckOpened, chuckClamped, chuckReleased
        case turretIndexed, turretParked
        case synchronized
        case transferApproach, transferAcquired, transferReleased, transferRetract
        case barrierPassed
    }
    public var seconds: Double
    public var stepID: String
    public var channelID: String
    public var kind: Kind
    public var spindleID: String?
    public var workpieceID: String?
    public var detail: String?
    public init(seconds: Double, stepID: String, channelID: String, kind: Kind,
                spindleID: String? = nil, workpieceID: String? = nil, detail: String? = nil) {
        self.seconds = seconds; self.stepID = stepID; self.channelID = channelID
        self.kind = kind; self.spindleID = spindleID; self.workpieceID = workpieceID
        self.detail = detail
    }
    /// Deterministic simultaneous-event priority.
    var priority: Int {
        switch kind {
        case .stepStarted: return 0
        case .stepCompleted: return 1
        case .barrierPassed, .synchronized: return 2
        default: return 3
        }
    }
}

/// One scheduled step: exact occupancy interval, held resources and the
/// workpiece world transforms after the step. There are no implicit moves
/// between steps; gaps are explicit machine state, not hidden motion.
public struct CellScheduledStep: Codable, Equatable, Sendable, Identifiable {
    public var id: String { stepID }
    public var stepID: String
    public var channelID: String
    public var order: Int
    public var startSeconds: Double
    public var endSeconds: Double
    /// Exclusion-expanded resources held for [startSeconds, endSeconds].
    public var resources: [CellResourceID]
    /// Exact worldFromWorkpiece per affected workpiece at step end.
    public var workpieceTransforms: [String: CellRigidTransform]
    /// Stock dependency chain carried by the underlying action.
    public var stockDependencyIDs: [String]
    public init(stepID: String, channelID: String, order: Int, startSeconds: Double,
                endSeconds: Double, resources: [CellResourceID],
                workpieceTransforms: [String: CellRigidTransform], stockDependencyIDs: [String]) {
        self.stepID = stepID; self.channelID = channelID; self.order = order
        self.startSeconds = startSeconds; self.endSeconds = endSeconds
        self.resources = resources; self.workpieceTransforms = workpieceTransforms
        self.stockDependencyIDs = stockDependencyIDs
    }
}

/// Transfer handover record. The receiver acquires the part before the donor
/// releases it; the recorded times make that ordering auditable.
public struct CellTransferRecord: Codable, Equatable, Sendable {
    public var stepID: String
    public var workpieceID: String
    public var donorSpindleID: String
    public var receiverSpindleID: String
    /// Receiver chuck clamps and ownership moves (start + duration/2).
    public var acquireSeconds: Double
    /// Donor chuck opens (start + 3·duration/4); always ≥ acquireSeconds.
    public var releaseSeconds: Double
    public var worldFromWorkpieceBefore: CellRigidTransform
    public var worldFromWorkpieceAfter: CellRigidTransform
    /// Commanded phase offset contribution included in the after transform.
    public var commandedPhaseOffsetDegrees: Double
    /// Receiver chuck mouth position at acquisition (world, mm).
    public var acquisitionOriginMM: [Double]
    /// Post-release receiver carriage position (world, mm), if retracted.
    public var retractOriginMM: [Double]?
    /// Rigid translation applied to the part by the retract.
    public var carriageDisplacementMM: [Double]
    public init(stepID: String, workpieceID: String, donorSpindleID: String,
                receiverSpindleID: String, acquireSeconds: Double, releaseSeconds: Double,
                worldFromWorkpieceBefore: CellRigidTransform,
                worldFromWorkpieceAfter: CellRigidTransform,
                commandedPhaseOffsetDegrees: Double = 0,
                acquisitionOriginMM: [Double], retractOriginMM: [Double]? = nil,
                carriageDisplacementMM: [Double] = [0, 0, 0]) {
        self.stepID = stepID; self.workpieceID = workpieceID
        self.donorSpindleID = donorSpindleID; self.receiverSpindleID = receiverSpindleID
        self.acquireSeconds = acquireSeconds; self.releaseSeconds = releaseSeconds
        self.worldFromWorkpieceBefore = worldFromWorkpieceBefore
        self.worldFromWorkpieceAfter = worldFromWorkpieceAfter
        self.commandedPhaseOffsetDegrees = commandedPhaseOffsetDegrees
        self.acquisitionOriginMM = acquisitionOriginMM
        self.retractOriginMM = retractOriginMM
        self.carriageDisplacementMM = carriageDisplacementMM
    }
}

/// Deterministic ordered executor context for one `operate` step. Root runs
/// these in `jobs` order, feeding each study's stock state from the recorded
/// dependency chain (`compute(study, startingStock:)`,
/// `artifact.startingStockSHA256`).
///
/// Offset semantics (explicit contract with Root's executor):
/// - `toolOffsetMM` is a world-axis Cartesian offset. Root exports
///   `worldPaths` (material TCP) and `worldToolReferencePaths`
///   (= worldPaths + toolOffsetMM) separately; neither shifts geometry or
///   material, and stock stays part-local.
/// - `commandedWorkOffsetMM` is reserved for commanded work offsets. The
///   planner currently fails closed on nonzero values (they would shift
///   cutting geometry) until the executor defines the study transform; the
///   field documents the wire and is nil or all-zero today.
/// - Station `wearOffsetMM` and vendor parameter sets are saved metadata and
///   never appear here as active values.
public struct CellJobContext: Codable, Equatable, Sendable {
    public var stepID: String
    public var channelID: String
    public var startSeconds: Double
    public var study: ManufacturingStudy
    public var workpieceID: String
    /// worldFromWorkpiece at job start; occupancy stays workpiece-local.
    public var worldFromWorkpiece: CellRigidTransform
    /// Selected station milling/live tool identity, when the operation names a station.
    public var toolID: String?
    /// Selected station turning insert identity, when named.
    public var turningToolID: String?
    /// Commanded work offset (tool-reference frame); executor applies or fails.
    public var commandedWorkOffsetMM: [Double]?
    /// Station tool offset (commanded tool-reference); executor applies or fails.
    public var toolOffsetMM: [Double]?
    public var nominalDurationSeconds: Double
    public var stockDependencyStepIDs: [String]
    public init(stepID: String, channelID: String, startSeconds: Double, study: ManufacturingStudy,
                workpieceID: String, worldFromWorkpiece: CellRigidTransform,
                toolID: String? = nil, turningToolID: String? = nil,
                commandedWorkOffsetMM: [Double]? = nil,
                toolOffsetMM: [Double]? = nil,
                nominalDurationSeconds: Double, stockDependencyStepIDs: [String]) {
        self.stepID = stepID; self.channelID = channelID; self.startSeconds = startSeconds
        self.study = study; self.workpieceID = workpieceID
        self.worldFromWorkpiece = worldFromWorkpiece
        self.toolID = toolID; self.turningToolID = turningToolID
        self.commandedWorkOffsetMM = commandedWorkOffsetMM
        self.toolOffsetMM = toolOffsetMM
        self.nominalDurationSeconds = nominalDurationSeconds
        self.stockDependencyStepIDs = stockDependencyStepIDs
    }
}

/// Deterministic plan result. `startState`/`endState` are the simulated
/// machine states, `events` the chronological transition list, `jobs` the
/// ordered executor contexts. Total time counts only explicit event
/// durations: no acceleration, no synthesized links, no implicit moves.
public struct CellSchedule: Codable, Equatable, Sendable {
    public var formatVersion = 1
    public var cellID: UUID
    public var startState: CellMachineState
    public var endState: CellMachineState
    public var steps: [CellScheduledStep]
    public var events: [CellMachineEvent]
    public var jobs: [CellJobContext]
    public var transfers: [CellTransferRecord]
    /// Parts explicitly released to a part catcher (requires the cell's
    /// `uncommon.allowsPartEject` option; otherwise releases must hand over
    /// to another chuck).
    public var ejectedWorkpieceIDs: [String]
    public var totalSeconds: Double
    public var warnings: [String]
    public init(formatVersion: Int = 1, cellID: UUID, startState: CellMachineState,
                endState: CellMachineState, steps: [CellScheduledStep], events: [CellMachineEvent],
                jobs: [CellJobContext], transfers: [CellTransferRecord],
                ejectedWorkpieceIDs: [String] = [], totalSeconds: Double, warnings: [String]) {
        self.formatVersion = formatVersion; self.cellID = cellID
        self.startState = startState; self.endState = endState
        self.steps = steps; self.events = events; self.jobs = jobs
        self.transfers = transfers; self.ejectedWorkpieceIDs = ejectedWorkpieceIDs.sorted()
        self.totalSeconds = totalSeconds; self.warnings = warnings
    }

    /// Structural re-check of a decoded or edited schedule against the cell.
    /// A reopened archive is verified, never trusted blindly (same contract
    /// as `CuttingTimeline.validate`).
    public func validate(for cell: ManufacturingCell) throws {
        func require(_ condition: Bool, _ reason: String) throws { try CellCheck.require(condition, reason) }
        try require(formatVersion == 1, "unsupported schedule version")
        try require(cellID == cell.id, "schedule cell mismatch")
        try require(cell.steps.count == steps.count, "scheduled step count")
        try require(totalSeconds.isFinite && totalSeconds > 0 && totalSeconds <= cell.budget.maxSimulatedSeconds, "total seconds budget")
        let ordered = steps.sorted { lhs, rhs in
            (lhs.startSeconds, lhs.channelID, lhs.stepID) < (rhs.startSeconds, rhs.channelID, rhs.stepID)
        }
        try require(ordered == steps, "scheduled steps not in deterministic order")
        try require(Set(steps.map(\.stepID)) == Set(cell.steps.map(\.id)), "scheduled steps do not match the cell")
        var freeAt: [CellResourceID: Double] = [:]
        for step in steps {
            let source = cell.steps.first { $0.id == step.stepID }
            try require(source != nil, "unknown scheduled step \(step.stepID)")
            let duration: Double
            if case .indexTurret(let index) = source!.action, index.durationSeconds == nil {
                // Derived durations depend on the simulated turret state, not
                // the initial station: check the machine-constant multiple.
                let turret = cell.turret(index.turretID)!
                let derived = step.endSeconds - step.startSeconds
                try require(derived.isFinite && derived >= 0 && derived <= Double(turret.stations.count) * turret.indexDurationSeconds &&
                            abs(derived / turret.indexDurationSeconds - (derived / turret.indexDurationSeconds).rounded()) <= 1e-9,
                            "step \(step.stepID) derived index duration is not a station multiple")
                duration = derived
            } else {
                duration = try CellPlanner.duration(of: source!, in: cell)
            }
            try require(step.endSeconds > step.startSeconds || duration == 0, "step \(step.stepID) empty interval")
            try require(abs(step.endSeconds - step.startSeconds - duration) <= 1e-9 * max(1, duration), "step \(step.stepID) duration mismatch")
            try require(step.startSeconds >= 0 && step.endSeconds <= totalSeconds + 1e-9, "step \(step.stepID) outside total time")
            for resource in step.resources {
                if let busyUntil = freeAt[resource] {
                    try require(busyUntil <= step.startSeconds + 1e-9, "resource \(resource) double-booked by step \(step.stepID)")
                }
                freeAt[resource] = max(freeAt[resource] ?? 0, step.endSeconds)
            }
            for (workpieceID, transform) in step.workpieceTransforms {
                try require(cell.workpiece(workpieceID) != nil, "step \(step.stepID) unknown transform workpiece \(workpieceID)")
                try transform.validate()
            }
        }
        try require(events == events.sorted(by: Self.eventLess), "events not chronological")
        for transfer in transfers {
            let interval = steps.first { $0.stepID == transfer.stepID }
            try require(interval != nil, "transfer record without a scheduled step")
            try require(transfer.acquireSeconds >= interval!.startSeconds - 1e-9 &&
                        transfer.acquireSeconds <= interval!.endSeconds + 1e-9, "transfer acquire outside its step")
            try require(transfer.releaseSeconds >= transfer.acquireSeconds - 1e-9 &&
                        transfer.releaseSeconds <= interval!.endSeconds + 1e-9, "transfer release before acquire or outside its step")
            try transfer.worldFromWorkpieceBefore.validate()
            try transfer.worldFromWorkpieceAfter.validate()
            try require(transfer.acquisitionOriginMM.count == 3 && transfer.acquisitionOriginMM.allSatisfy { $0.isFinite && abs($0) <= 100_000 },
                        "transfer acquisition origin out of range")
            if let retract = transfer.retractOriginMM {
                try require(retract.count == 3 && retract.allSatisfy { $0.isFinite && abs($0) <= 100_000 }, "transfer retract origin out of range")
            }
            try require(transfer.carriageDisplacementMM.count == 3 && transfer.carriageDisplacementMM.allSatisfy { $0.isFinite && abs($0) <= 100_000 },
                        "transfer carriage displacement out of range")
            try require(cell.workpiece(transfer.workpieceID) != nil, "transfer unknown workpiece \(transfer.workpieceID)")
        }
        let operateIDs = cell.steps.compactMap { step -> String? in
            if case .operate = step.action { return step.id }
            return nil
        }
        try require(jobs.count == operateIDs.count, "job count")
        let operateSteps = steps.filter { operateIDs.contains($0.stepID) }
        try require(jobs.map(\.stepID) == operateSteps.map(\.stepID), "jobs not in scheduled operate order")
        for (index, job) in jobs.enumerated() {
            let source = cell.steps.first { $0.id == job.stepID }
            guard case .operate(let operation) = source?.action else { throw ManufacturingError.invalid("cell: job \(job.stepID) is not an operation") }
            try require(operation.study == job.study, "job \(job.stepID) study mismatch")
            try require(abs(job.nominalDurationSeconds - (operateSteps[index].endSeconds - operateSteps[index].startSeconds)) <= 1e-9 * max(1, job.nominalDurationSeconds), "job \(job.stepID) duration mismatch")
            try require(job.worldFromWorkpiece == operateSteps[index].workpieceTransforms[job.workpieceID] || job.worldFromWorkpiece == startState.workpieceTransforms[job.workpieceID], "job \(job.stepID) transform mismatch")
        }
        // Resting state must own every workpiece unless it was explicitly
        // ejected to a part catcher; a part left between chucks means the
        // program dropped the last grip.
        let ejectAllowed = cell.uncommon?.allowsPartEject == true
        try require(ejectedWorkpieceIDs.isEmpty || ejectAllowed, "ejected workpieces require the allowsPartEject option")
        try require(ejectedWorkpieceIDs == ejectedWorkpieceIDs.sorted() && Set(ejectedWorkpieceIDs).count == ejectedWorkpieceIDs.count,
                    "ejected workpiece ids unordered or duplicated")
        for workpieceID in ejectedWorkpieceIDs {
            try require(cell.workpiece(workpieceID) != nil, "unknown ejected workpiece \(workpieceID)")
        }
        for part in cell.workpieces {
            let owner = endState.workpieceOwners[part.id] ?? nil
            try require(owner != nil || ejectedWorkpieceIDs.contains(part.id),
                        "workpiece \(part.id) left without an owner spindle")
        }
        for (workpieceID, transform) in endState.workpieceTransforms {
            try require(cell.workpiece(workpieceID) != nil, "end state unknown workpiece \(workpieceID)")
            try transform.validate()
        }
        for spindleID in cell.spindles.map(\.id) { try require(endState.spindleStates[spindleID] != nil, "end state missing spindle \(spindleID)") }
        for turretID in cell.turrets.map(\.id) { try require(endState.turretStates[turretID] != nil, "end state missing turret \(turretID)") }
    }

    static func eventLess(_ lhs: CellMachineEvent, _ rhs: CellMachineEvent) -> Bool {
        (lhs.seconds, lhs.stepID, lhs.priority, lhs.kind.rawValue) < (rhs.seconds, rhs.stepID, rhs.priority, rhs.kind.rawValue)
    }
}

/// Deterministic multi-channel scheduler for `ManufacturingCell`.
///
/// Scheduling model: list scheduling over the explicit dependency graph.
/// A step starts when its channel predecessor, explicit edges, wait point
/// and stock dependencies have completed, at the earliest time its resources
/// (spindle / turret / workpiece, expanded by exclusion groups) are free.
/// Independent channels overlap only for distinct actual resources. Missing
/// dependencies, cycles, deadlocks, unsupported geometry and failed
/// synchronization all fail closed with `ManufacturingError.invalid`.
public struct CellPlanner: Sendable {
    public init() {}

    public func plan(_ cell: ManufacturingCell, control: ComputationControl = .init()) throws -> CellSchedule {
        try cell.validate()
        try control.check()
        var context = try PlanContext(cell: cell, control: control)
        return try context.run()
    }

    /// Resolved step duration in seconds; wait/barrier are zero, turret
    /// index/park derive from machine constants when not overridden.
    static func duration(of step: CellStep, in cell: ManufacturingCell) throws -> Double {
        func resolved(_ value: Double?) throws -> Double {
            if let value { try CellCheck.positive(value, max: 1e6, name: "step \(step.id) duration"); return value }
            throw ManufacturingError.invalid("cell plan: step \(step.id) missing duration")
        }
        switch step.action {
        case .approach(let approach): return try resolved(approach.durationSeconds)
        case .retract(let retract): return try resolved(retract.durationSeconds)
        case .dwell(let dwell): return try resolved(dwell.seconds)
        case .spindle(let command): return try resolved(command.durationSeconds)
        case .chuck(let command): return try resolved(command.durationSeconds)
        case .synchronize(let sync): return try resolved(sync.durationSeconds)
        case .transfer(let transfer): return try resolved(transfer.durationSeconds)
        case .operate(let operation): return try resolved(operation.durationSeconds)
        case .parkTurret(let park):
            if let duration = park.durationSeconds { return try resolved(duration) }
            guard let turret = cell.turret(park.turretID) else { throw ManufacturingError.invalid("cell plan: step \(step.id) unknown turret") }
            return turret.parkDurationSeconds
        case .indexTurret(let index):
            if let duration = index.durationSeconds { return try resolved(duration) }
            guard let turret = cell.turret(index.turretID) else { throw ManufacturingError.invalid("cell plan: step \(step.id) unknown turret") }
            guard let from = turret.stations.firstIndex(where: { $0.id == turret.initialStationID }),
                  let to = turret.stations.firstIndex(where: { $0.id == index.stationID }) else {
                throw ManufacturingError.invalid("cell plan: step \(step.id) unknown station")
            }
            let count = turret.stations.count
            let forward = (to - from + count) % count
            let backward = (from - to + count) % count
            return Double(min(forward, backward)) * turret.indexDurationSeconds
        case .wait, .barrier: return 0
        }
    }

    /// Base resources held by a step, before exclusion-group expansion.
    static func baseResources(of step: CellStep) throws -> [CellResourceID] {
        switch step.action {
        case .approach(let approach):
            return [.init(.turret, approach.turretID), .init(.spindle, approach.spindleID)]
                + (approach.workpieceID.map { [CellResourceID(.workpiece, $0)] } ?? [])
        case .retract(let retract):
            return [.init(.turret, retract.turretID)]
                + (retract.spindleID.map { [CellResourceID(.spindle, $0)] } ?? [])
        case .parkTurret(let park): return [.init(.turret, park.turretID)]
        case .indexTurret(let index): return [.init(.turret, index.turretID)]
        case .dwell(let dwell):
            return dwell.workpieceID.map { [CellResourceID(.workpiece, $0)] } ?? []
        case .spindle(let command): return [.init(.spindle, command.spindleID)]
        case .chuck(let command):
            return [.init(.spindle, command.spindleID)]
                + (command.workpieceID.map { [CellResourceID(.workpiece, $0)] } ?? [])
        case .synchronize(let sync): return sync.spindleIDs.map { .init(.spindle, $0) }
        case .transfer(let transfer):
            return [.init(.spindle, transfer.donorSpindleID), .init(.spindle, transfer.receiverSpindleID),
                    .init(.workpiece, transfer.workpieceID)]
        case .wait, .barrier: return []
        case .operate(let operation):
            return [.init(.spindle, operation.spindleID), .init(.workpiece, operation.workpieceID)]
                + (operation.turretID.map { [CellResourceID(.turret, $0)] } ?? [])
        }
    }
}

// MARK: - Simulation

private struct SyncRecord: Equatable {
    var referenceSpindleID: String
    var receiverSpindleID: String
    var completedAt: Double
    var mode: CellSynchronize.Mode
    var speedRatio: Double
    var phaseToleranceDegrees: Double
    var targetPhaseOffsetDegrees: Double
}

private struct PlanContext {
    let cell: ManufacturingCell
    let control: ComputationControl
    let stepsByID: [String: CellStep]
    let channelOrder: [String: [String]]
    let dependencies: [String: Set<String>]
    let dependents: [String: Set<String>]
    let stepResources: [String: [CellResourceID]]
    let stepDurations: [String: Double]

    var machine: CellMachineState
    var lastModeChange: [String: Double] = [:]
    var syncRecords: [String: SyncRecord] = [:]   // key: "a|b" with a < b
    var resourceFreeAt: [CellResourceID: Double] = [:]
    var completionTime: [String: Double] = [:]
    var scheduled: [CellScheduledStep] = []
    var completed = Set<String>()
    var applied = Set<String>()
    var events: [CellMachineEvent] = []
    var transfers: [CellTransferRecord] = []
    var jobs: [CellJobContext] = []
    var warnings: [String] = []
    var ejected = Set<String>()
    var eventCount = 0

    init(cell: ManufacturingCell, control: ComputationControl) throws {
        self.cell = cell
        self.control = control
        var byID = [String: CellStep]()
        for step in cell.steps { byID[step.id] = step }
        self.stepsByID = byID
        var order = [String: [(Int, String)]]()
        for step in cell.steps { order[step.channelID, default: []].append((step.order, step.id)) }
        self.channelOrder = order.mapValues { $0.sorted { $0.0 < $1.0 }.map(\.1) }
        self.machine = try Self.initialState(of: cell)
        var dependencies = [String: Set<String>]()
        var dependents = [String: Set<String>]()
        func addDependency(_ from: String, to: String) {
            dependencies[to, default: []].insert(from)
            dependents[from, default: []].insert(to)
        }
        // Channel order is an explicit dependency per channel.
        for steps in self.channelOrder.values {
            for index in 1..<steps.count { addDependency(steps[index-1], to: steps[index]) }
        }
        // Explicit edges.
        for edge in cell.edges { addDependency(edge.from, to: edge.to) }
        // Named waits.
        for step in cell.steps {
            if case .wait(let wait) = step.action,
               let point = cell.waitPoints.first(where: { $0.name == wait.pointName }) {
                for target in point.stepIDs { addDependency(target, to: step.id) }
            }
        }
        // Stock dependencies flow through prior steps.
        for step in cell.steps {
            if case .operate(let operation) = step.action {
                for dependency in operation.stockDependencyIDs { addDependency(dependency, to: step.id) }
            }
        }
        // Barriers: depend on every step of the participating channels that
        // does not transitively depend on the barrier itself (collective
        // arrival semantics).
        for step in cell.steps {
            guard case .barrier(let barrier) = step.action else { continue }
            let participants = barrier.channelIDs.isEmpty ? cell.channels.map(\.id) : barrier.channelIDs
            let descendants = Self.reachable(from: step.id, via: dependents)
            for other in cell.steps where other.id != step.id && participants.contains(other.channelID) && !descendants.contains(other.id) {
                addDependency(other.id, to: step.id)
            }
        }
        self.dependencies = dependencies
        self.dependents = dependents
        // Resolve durations and resources up front (validated once).
        var durations = [String: Double]()
        var resources = [String: [CellResourceID]]()
        for step in cell.steps {
            durations[step.id] = try CellPlanner.duration(of: step, in: cell)
            resources[step.id] = cell.expandedResources(try CellPlanner.baseResources(of: step))
        }
        self.stepDurations = durations
        self.stepResources = resources
    }

    static func initialState(of cell: ManufacturingCell) throws -> CellMachineState {
        var spindles = [String: CellMachineState.SpindleState]()
        for spindle in cell.spindles {
            let mode = CellMachineState.SpindleState.Mode(rawValue: spindle.initialMode.rawValue) ?? .stopped
            spindles[spindle.id] = .init(mode: mode, rpm: spindle.initialRPM,
                                         cIndexDegrees: spindle.initialCIndexDegrees,
                                         direction: spindle.initialDirection,
                                         phaseDatumDegrees: spindle.initialPhaseDegrees,
                                         chuckOpeningDiameterMM: spindle.chuck.openingDiameterMM,
                                         maxOpeningDiameterMM: spindle.chuck.maxOpeningDiameterMM,
                                         clampedWorkpieceID: spindle.chuck.clampedWorkpieceID,
                                         gripLengthMM: spindle.chuck.gripLengthMM,
                                         carriagePositionMM: spindle.frame.originMM)
        }
        var turrets = [String: CellMachineState.TurretState]()
        for turret in cell.turrets {
            turrets[turret.id] = .init(stationID: turret.initialStationID, parked: turret.parkedInitially)
        }
        var owners = [String: String?]()
        var transforms = [String: CellRigidTransform]()
        for part in cell.workpieces {
            owners[part.id] = part.ownerSpindleID
            transforms[part.id] = part.worldFromWorkpiece
            if let owner = part.ownerSpindleID, let spindle = cell.spindle(owner) {
                try validatePartGeometry(part, spindle: spindle, toleranceDegrees: cell.uncommon?.transferAxisToleranceDegrees ?? 1)
            }
        }
        return .init(spindleStates: spindles, turretStates: turrets, workpieceOwners: owners, workpieceTransforms: transforms)
    }

    /// A clamped part's origin must lie on the owner spindle axis and its
    /// local Z must align (parallel or antiparallel) with the spindle axis.
    static func validatePartGeometry(_ part: ManufacturingCell.Workpiece,
                                     spindle: ManufacturingCell.Spindle,
                                     toleranceDegrees: Double) throws {
        let transform = part.worldFromWorkpiece
        try transform.validate()
        let axis = spindle.frame.axis
        let origin = spindle.frame.originMM
        let point = transform.translationMM
        let delta = zip(point, origin).map { $0 - $1 }
        let along = zip(delta, axis).reduce(0.0) { $0 + $1.0*$1.1 }
        let radial = zip(delta, axis).map { $0 - $1*along }
        let radialError = sqrt(radial.reduce(0) { $0 + $1*$1 })
        try CellCheck.require(radialError <= 1e-3, "workpiece \(part.id) origin is \(radialError) mm off the \(spindle.id) spindle axis")
        let localZ = [transform.rotation[2], transform.rotation[5], transform.rotation[8]]
        let cosine = abs(zip(localZ, axis).reduce(0.0) { $0 + $1.0*$1.1 })
        let limit = cos(min(toleranceDegrees, 45) * Double.pi / 180)
        try CellCheck.require(cosine >= limit, "workpiece \(part.id) local axis is not aligned with spindle \(spindle.id) within \(toleranceDegrees)°")
    }

    static func reachable(from start: String, via graph: [String: Set<String>]) -> Set<String> {
        var seen = Set<String>()
        var stack = Array(graph[start] ?? [])
        while let next = stack.popLast() {
            if seen.insert(next).inserted { stack.append(contentsOf: graph[next] ?? []) }
        }
        return seen
    }

    /// Kahn's algorithm: any step left with unscheduled ancestors means the
    /// graph has a cycle; fail closed before simulating.
    func detectCycles() throws {
        var remaining = dependencies.mapValues(\.count)
        for step in cell.steps { remaining[step.id] = remaining[step.id] ?? 0 }
        var queue = cell.steps.filter { remaining[$0.id] == 0 }.map(\.id).sorted()
        var visited = 0
        while !queue.isEmpty {
            let id = queue.removeFirst()
            visited += 1
            for dependent in (dependents[id] ?? []).sorted() {
                remaining[dependent, default: 0] -= 1
                if remaining[dependent] == 0 { queue.append(dependent); queue.sort() }
            }
        }
        try CellCheck.require(visited == cell.steps.count, "dependency cycle involving \(cell.steps.filter { remaining[$0.id] != 0 }.map(\.id).sorted().prefix(4).joined(separator: ", "))")
    }

    mutating func run() throws -> CellSchedule {
        try detectCycles()
        var remaining = dependencies.mapValues(\.count)
        for step in cell.steps { remaining[step.id] = remaining[step.id] ?? 0 }
        let startState = machine
        let allIDs = cell.steps.map(\.id).sorted()
        while completed.count < allIDs.count {
            try control.check()
            eventCount += 1
            try CellCheck.require(eventCount <= cell.budget.maxEvents, "event budget exceeded")
            let candidates = allIDs.filter { remaining[$0] == 0 && !completed.contains($0) }
                .sorted { lhs, rhs in
                    let a = stepsByID[lhs]!, b = stepsByID[rhs]!
                    return (a.channelID, a.order, a.id) < (b.channelID, b.order, b.id)
                }
            try CellCheck.require(!candidates.isEmpty, "deadlock: no runnable step while \(allIDs.count - completed.count) steps remain unscheduled")
            for stepID in candidates {
                try schedule(stepID, remaining: &remaining)
            }
        }
        let total = scheduled.map(\.endSeconds).max() ?? 0
        try CellCheck.require(total.isFinite && total > 0 && total <= cell.budget.maxSimulatedSeconds, "simulated time budget exceeded")
        // Apply all remaining effects to reach the resting end state.
        let finishing = scheduled.filter { !applied.contains($0.stepID) }
            .sorted { ($0.endSeconds, $0.channelID, $0.stepID) < ($1.endSeconds, $1.channelID, $1.stepID) }
        for step in finishing { try applyEffects(of: step) }
        let endState = machine
        let orderedSteps = scheduled.sorted { ($0.startSeconds, $0.channelID, $0.stepID) < ($1.startSeconds, $1.channelID, $1.stepID) }
        let orderedEvents = events.sorted(by: CellSchedule.eventLess)
        var warnings = self.warnings
        for note in [Self.nominalTimeWarning] + offsetWarningNotes() where !warnings.contains(note) {
            warnings.append(note)
        }
        warnings.sort()
        let schedule = CellSchedule(cellID: cell.id, startState: startState, endState: endState,
                                    steps: orderedSteps, events: orderedEvents,
                                    jobs: jobs.sorted { ($0.startSeconds, $0.channelID, $0.stepID) < ($1.startSeconds, $1.channelID, $1.stepID) },
                                    transfers: transfers.sorted { $0.stepID < $1.stepID },
                                    ejectedWorkpieceIDs: ejected.sorted(),
                                    totalSeconds: total, warnings: warnings)
        try schedule.validate(for: cell)
        return schedule
    }

    func offsetWarningNotes() -> [String] {
        var notes = [String]()
        if cell.turrets.contains(where: { $0.stations.contains { $0.toolOffsetMM?.allSatisfy { $0 == 0 } == false } }) {
            notes.append("Station tool offsets are active: the executor must apply them to commanded paths or fail explicitly; material TCP is unchanged.")
        }
        if cell.steps.contains(where: { step in
            if case .operate(let o) = step.action { return o.durationProvenance == .supplied }
            return false
        }) {
            notes.append("Operation durations are nominal supplied times; patch them from a computed CuttingTimeline without regenerating geometry.")
        }
        if cell.spindles.contains(where: { $0.initialMode == .rpm && $0.initialPhaseDegrees == nil }) {
            notes.append("At least one RPM-mode spindle has no initial phase datum; synchronization uses commanded acquisition values only.")
        }
        if cell.uncommon?.allowsPartEject == true {
            notes.append("Part eject to the catcher is enabled; ejected parts are recorded in ejectedWorkpieceIDs.")
        }
        return notes
    }

    static let nominalTimeWarning = "Nominal schedule time counts explicit event durations only; acceleration, spindle transients and unlisted links are excluded. This is a program model, not physical-safety certification."

    /// Schedule one step at the earliest time its dependencies and resources
    /// allow, validating preconditions against the simulated state snapshot.
    mutating func schedule(_ stepID: String, remaining: inout [String: Int]) throws {
        let step = stepsByID[stepID]!
        var duration = stepDurations[stepID]!
        let depEnd = (dependencies[stepID] ?? []).map { endOf($0) }.max() ?? 0
        var start = depEnd
        for resource in stepResources[stepID]! {
            start = max(start, resourceFreeAt[resource] ?? 0)
        }
        try applyUpTo(start)
        try validatePreconditions(of: step, at: start)
        if case .indexTurret(let index) = step.action,index.durationSeconds == nil {
            let turret = cell.turret(index.turretID)!
            guard let current = machine.turretStates[index.turretID]?.stationID,
                  let from = turret.stations.firstIndex(where:{ $0.id == current }),
                  let to = turret.stations.firstIndex(where:{ $0.id == index.stationID }) else {
                throw ManufacturingError.invalid("cell plan: current turret station is unavailable")
            }
            let count = turret.stations.count
            duration = Double(min((to-from+count)%count,(from-to+count)%count))*turret.indexDurationSeconds
        }
        let end = start + duration
        completionTime[step.id] = end
        for resource in stepResources[stepID]! { resourceFreeAt[resource] = end }
        completed.insert(stepID)
        for dependent in (dependents[stepID] ?? []).sorted() {
            remaining[dependent, default: 0] -= 1
        }
        let snapshot = snapshotTransforms()
        emit(.init(seconds: start, stepID: step.id, channelID: step.channelID, kind: .stepStarted))
        if case .operate(let operation) = step.action {
            let station = operation.stationID.flatMap { station in cell.turret(operation.turretID ?? "")?.stations.first { $0.id == station } }
            let stationToolID = operation.toolID ?? station?.toolID
            let stationTurningToolID = operation.turningToolID ?? station?.turningToolID
            jobs.append(.init(stepID: step.id, channelID: step.channelID, startSeconds: start,
                              study: operation.study, workpieceID: operation.workpieceID,
                              worldFromWorkpiece: snapshot[operation.workpieceID]!,
                              toolID: stationToolID,
                              turningToolID: stationTurningToolID,
                              commandedWorkOffsetMM: operation.workOffsetMM,
                              toolOffsetMM: station?.toolOffsetMM,
                              nominalDurationSeconds: operation.durationSeconds,
                              stockDependencyStepIDs: operation.stockDependencyIDs))
        }
        let entry = CellScheduledStep(stepID:step.id,channelID:step.channelID,order:step.order,
            startSeconds:start,endSeconds:end,resources:stepResources[stepID]!,
            workpieceTransforms:snapshot,stockDependencyIDs:stockDependencies(of:step))
        // Barriers, waits and no-op indexing remain in the output schedule.
        scheduled.append(entry)
        if duration == 0 { try applyEffects(of:entry) }
    }

    func endOf(_ stepID: String) -> Double {
        completionTime[stepID] ?? 0
    }

    func stockDependencies(of step: CellStep) -> [String] {
        if case .operate(let operation) = step.action { return operation.stockDependencyIDs }
        return []
    }

    mutating func emit(_ event: CellMachineEvent) {
        events.append(event)
        eventCount += 1
    }

    func snapshotTransforms() -> [String: CellRigidTransform] { machine.workpieceTransforms }

    /// Apply the effects of every scheduled step that ends at or before
    /// `time`, in deterministic (end, channel, id) order, so precondition
    /// checks see the exact state at that instant.
    mutating func applyUpTo(_ time: Double) throws {
        let due = scheduled.filter { !applied.contains($0.stepID) && $0.endSeconds <= time + 1e-12 }
            .sorted { ($0.endSeconds, $0.channelID, $0.stepID) < ($1.endSeconds, $1.channelID, $1.stepID) }
        for step in due { try applyEffects(of: step) }
    }

    mutating func applyEffects(of scheduledStep: CellScheduledStep) throws {
        if applied.contains(scheduledStep.stepID) { return }
        let step = stepsByID[scheduledStep.stepID]!
        let t = scheduledStep.endSeconds
        switch step.action {
        case .spindle(let command):
            var state = machine.spindleStates[command.spindleID]!
            // Phase continues from the current commanded phase (continuous
            // datum), then the new mode takes over.
            state.phaseDatumDegrees = state.phase(atSeconds: t)
            state.phaseReferenceSeconds = t
            state.mode = CellMachineState.SpindleState.Mode(rawValue: command.mode.rawValue) ?? .stopped
            state.rpm = command.rpm
            state.cIndexDegrees = command.cIndexDegrees
            state.direction = command.direction
            machine.spindleStates[command.spindleID] = state
            lastModeChange[command.spindleID] = t
            syncRecords = syncRecords.filter { !($0.key.components(separatedBy: "|").contains(command.spindleID)) }
            emit(.init(seconds: t, stepID: step.id, channelID: step.channelID, kind: .spindleModeChanged,
                       spindleID: command.spindleID, detail: command.mode.rawValue))
        case .chuck(let command):
            var state = machine.spindleStates[command.spindleID]!
            switch command.operation {
            case .open:
                state.chuckOpeningDiameterMM = command.openDiameterMM!
                emit(.init(seconds: t, stepID: step.id, channelID: step.channelID, kind: .chuckOpened,
                           spindleID: command.spindleID, detail: "diameter \(command.openDiameterMM!)"))
            case .clamp:
                state.clampedWorkpieceID = command.workpieceID
                state.gripLengthMM = command.gripLengthMM
                machine.workpieceOwners[command.workpieceID!] = command.spindleID
                emit(.init(seconds: t, stepID: step.id, channelID: step.channelID, kind: .chuckClamped,
                           spindleID: command.spindleID, workpieceID: command.workpieceID,
                           detail: "grip \(command.gripLengthMM!) mm"))
            case .release:
                let held = state.clampedWorkpieceID
                state.clampedWorkpieceID = nil
                state.gripLengthMM = nil
                if let held {
                    let remainingHolders = machine.spindleStates.filter { $0.key != command.spindleID && $0.value.clampedWorkpieceID == held }.map(\.key).sorted()
                    if let nextOwner = remainingHolders.first {
                        machine.workpieceOwners[held] = nextOwner
                    } else if cell.uncommon?.allowsPartEject == true {
                        machine.workpieceOwners[held] = nil
                        ejected.insert(held)
                    }
                }
                emit(.init(seconds: t, stepID: step.id, channelID: step.channelID, kind: .chuckReleased,
                           spindleID: command.spindleID, workpieceID: held,
                           detail: held.flatMap { ejected.contains($0) ? "ejected to part catcher" : nil }))
            }
            machine.spindleStates[command.spindleID] = state
        case .parkTurret(let park):
            var state = machine.turretStates[park.turretID]!
            state.parked = true
            machine.turretStates[park.turretID] = state
            emit(.init(seconds: t, stepID: step.id, channelID: step.channelID, kind: .turretParked,
                       detail: park.turretID))
        case .indexTurret(let index):
            var state = machine.turretStates[index.turretID]!
            state.parked = false
            state.stationID = index.stationID
            machine.turretStates[index.turretID] = state
            emit(.init(seconds: t, stepID: step.id, channelID: step.channelID, kind: .turretIndexed,
                       detail: "\(index.turretID) -> \(index.stationID)"))
        case .synchronize(let sync):
            if sync.mode == .matchedRPM {
                let donor = machine.spindleStates[sync.spindleIDs[0]]!
                var receiver = machine.spindleStates[sync.spindleIDs[1]]!
                let a = cell.spindle(sync.spindleIDs[0])!.frame.axis
                let b = cell.spindle(sync.spindleIDs[1])!.frame.axis
                let orientation = zip(a,b).reduce(0.0) { $0 + $1.0*$1.1 } >= 0 ? 1.0 : -1.0
                // Commanded acquisition changes the receiver datum and speed.
                // It is not a hardware phase measurement or a part rotation.
                receiver.rpm = donor.rpm! * (sync.speedRatio ?? 1)
                receiver.phaseDatumDegrees = orientation * donor.phase(atSeconds:t)! + (sync.targetPhaseOffsetDegrees ?? 0)
                receiver.phaseReferenceSeconds = t
                machine.spindleStates[sync.spindleIDs[1]] = receiver
            }
            let key = sync.spindleIDs.sorted().joined(separator: "|")
            syncRecords[key] = .init(referenceSpindleID:sync.spindleIDs[0],receiverSpindleID:sync.spindleIDs[1],
                                     completedAt: t, mode: sync.mode, speedRatio: sync.speedRatio ?? 1,
                                     phaseToleranceDegrees: sync.phaseToleranceDegrees ?? 0,
                                     targetPhaseOffsetDegrees: sync.targetPhaseOffsetDegrees ?? 0)
            emit(.init(seconds: t, stepID: step.id, channelID: step.channelID, kind: .synchronized,
                       detail: sync.spindleIDs.sorted().joined(separator: "+")))
        case .transfer(let transfer):
            try applyTransferEffects(transfer, step: step, start: scheduledStep.startSeconds, end: t)
        case .barrier:
            emit(.init(seconds: t, stepID: step.id, channelID: step.channelID, kind: .barrierPassed,
                       detail: "channels arrived"))
        case .approach, .retract, .dwell, .wait, .operate:
            break
        }
        applied.insert(scheduledStep.stepID)
        if let index = scheduled.firstIndex(where:{ $0.stepID == scheduledStep.stepID }) {
            scheduled[index].workpieceTransforms = snapshotTransforms()
        }
        emit(.init(seconds: scheduledStep.endSeconds, stepID: step.id, channelID: step.channelID, kind: .stepCompleted))
    }

    mutating func applyTransferEffects(_ transfer: CellTransfer, step: CellStep, start: Double, end: Double) throws {
        let acquire = start + (end - start) / 2
        let release = start + 3 * (end - start) / 4
        let before = machine.workpieceTransforms[transfer.workpieceID]!
        let key = [transfer.donorSpindleID, transfer.receiverSpindleID].sorted().joined(separator: "|")
        let sync = syncRecords[key]
        let phaseOffset = sync?.mode == .matchedRPM ? sync!.targetPhaseOffsetDegrees : 0
        // Phase 1 (start..acquire): the receiver carriage approaches; the
        // part never moves or flips while both chucks close on it.
        emit(.init(seconds: start, stepID: step.id, channelID: step.channelID, kind: .transferApproach,
                   spindleID: transfer.receiverSpindleID, workpieceID: transfer.workpieceID,
                   detail: "receiver to [\(transfer.acquisitionOriginMM.map { String($0) }.joined(separator: ","))]"))
        // Acquire: receiver clamps, ownership moves while both chucks hold.
        var receiverState = machine.spindleStates[transfer.receiverSpindleID]!
        receiverState.clampedWorkpieceID = transfer.workpieceID
        receiverState.gripLengthMM = transfer.receiverGripLengthMM
        receiverState.carriagePositionMM = transfer.acquisitionOriginMM
        machine.spindleStates[transfer.receiverSpindleID] = receiverState
        machine.workpieceOwners[transfer.workpieceID] = transfer.receiverSpindleID
        var after = try Self.transferTransform(cell: cell, transfer: transfer, before: before)
        emit(.init(seconds: acquire, stepID: step.id, channelID: step.channelID, kind: .transferAcquired,
                   spindleID: transfer.receiverSpindleID, workpieceID: transfer.workpieceID,
                   detail: "receiver acquired before donor release"))
        // Release: donor opens; the last grip is never dropped because the
        // receiver already owns the part.
        var donorState = machine.spindleStates[transfer.donorSpindleID]!
        donorState.clampedWorkpieceID = nil
        donorState.gripLengthMM = nil
        machine.spindleStates[transfer.donorSpindleID] = donorState
        emit(.init(seconds: release, stepID: step.id, channelID: step.channelID, kind: .transferReleased,
                   spindleID: transfer.donorSpindleID, workpieceID: transfer.workpieceID))
        // Phase 2 (release..end): receiver retracts and translates the part
        // rigidly by the carriage displacement; occupancy is unchanged.
        var displacement = [0.0, 0.0, 0.0]
        if let retract = transfer.retractOriginMM {
            displacement = zip(retract, transfer.acquisitionOriginMM).map { $0 - $1 }
            after.translationMM = zip(after.translationMM, displacement).map { $0 + $1 }
            receiverState = machine.spindleStates[transfer.receiverSpindleID]!
            receiverState.carriagePositionMM = retract
            machine.spindleStates[transfer.receiverSpindleID] = receiverState
            try after.validate()
        }
        machine.workpieceTransforms[transfer.workpieceID] = after
        emit(.init(seconds: end, stepID: step.id, channelID: step.channelID, kind: .transferRetract,
                   spindleID: transfer.receiverSpindleID, workpieceID: transfer.workpieceID,
                   detail: "retracted by [\(displacement.map { String($0) }.joined(separator: ","))]"))
        transfers.append(.init(stepID: step.id, workpieceID: transfer.workpieceID,
                               donorSpindleID: transfer.donorSpindleID,
                               receiverSpindleID: transfer.receiverSpindleID,
                               acquireSeconds: acquire, releaseSeconds: release,
                               worldFromWorkpieceBefore: before, worldFromWorkpieceAfter: after,
                               commandedPhaseOffsetDegrees: phaseOffset,
                               acquisitionOriginMM: transfer.acquisitionOriginMM,
                               retractOriginMM: transfer.retractOriginMM,
                               carriageDisplacementMM: displacement))
    }

    /// Exact rigid transform of the part across the handover. The part is a
    /// rigid body: the handover itself does not move or flip it, so the
    /// world translation is unchanged and the world rotation only gains the
    /// commanded twist about the receiver axis. The receiver frame may be
    /// parallel or antiparallel; anything else is unsupported geometry and
    /// fails closed. Only an explicit post-release twist moves the part.
    /// Synchronization changes the receiving
    /// chuck datum, never the material orientation during dual grip.
    static func transferTransform(cell: ManufacturingCell, transfer: CellTransfer,
                                  before: CellRigidTransform) throws -> CellRigidTransform {
        let donor = cell.spindle(transfer.donorSpindleID)!
        let receiver = cell.spindle(transfer.receiverSpindleID)!
        let tolerance = cell.uncommon?.transferAxisToleranceDegrees ?? 1
        let cosine = zip(donor.frame.axis, receiver.frame.axis).reduce(0.0) { $0 + $1.0*$1.1 }
        let limit = cos(min(tolerance, 45) * Double.pi / 180)
        try CellCheck.require(abs(cosine) >= limit,
                              "transfer \(transfer.workpieceID): spindle axes are neither parallel nor antiparallel within \(tolerance)° (unsupported geometry)")
        // The part origin must sit on both axes (validated preconditions);
        // the receiver grip plane is already where the part is.
        let rOrigin = receiver.frame.originMM
        let rAxis = receiver.frame.axis
        let point = before.translationMM
        let delta = zip(point, rOrigin).map { $0 - $1 }
        let along = zip(delta, rAxis).reduce(0.0) { $0 + $1.0*$1.1 }
        let radial = zip(delta, rAxis).map { $0 - $1*along }
        let radialError = sqrt(radial.reduce(0) { $0 + $1*$1 })
        try CellCheck.require(radialError <= 1e-3,
                              "transfer \(transfer.workpieceID): part origin is \(radialError) mm off the \(receiver.id) receiver axis (unsupported geometry)")
        let twist = transfer.twistDegrees.truncatingRemainder(dividingBy: 360)
        var rotation = before.rotation
        if twist != 0 {
            // Rodrigues rotation of the part about the receiver axis.
            let (ux, uy, uz) = (rAxis[0], rAxis[1], rAxis[2])
            let angle = twist * Double.pi / 180
            let c = cos(angle), s = sin(angle), k = 1 - c
            let r = [
                c + ux*ux*k, ux*uy*k - uz*s, ux*uz*k + uy*s,
                uy*ux*k + uz*s, c + uy*uy*k, uy*uz*k - ux*s,
                uz*ux*k - uy*s, uz*uy*k + ux*s, c + uz*uz*k,
            ]
            var product = [Double](repeating: 0, count: 9)
            for row in 0..<3 { for column in 0..<3 {
                product[row*3+column] = (0..<3).reduce(0.0) { $0 + r[row*3+$1] * rotation[$1*3+column] }
            } }
            rotation = product
        }
        let transform = CellRigidTransform(rotation: rotation, translationMM: before.translationMM)
        try transform.validate()
        return transform
    }

    // swiftlint:disable:next function_body_length
    mutating func validatePreconditions(of step: CellStep, at time: Double) throws {
        switch step.action {
        case .chuck(let command):
            let state = machine.spindleStates[command.spindleID]!
            switch command.operation {
            case .open:
                try CellCheck.require(state.clampedWorkpieceID == nil,
                                      "step \(step.id): cannot open chuck \(command.spindleID) while it clamps a workpiece")
                try CellCheck.require(command.openDiameterMM! <= state.maxOpeningDiameterMM,
                                      "step \(step.id): open diameter exceeds chuck \(command.spindleID) maximum")
            case .clamp:
                let workpieceID = command.workpieceID!
                try CellCheck.require(state.clampedWorkpieceID == nil || state.clampedWorkpieceID == workpieceID,
                                      "step \(step.id): chuck \(command.spindleID) already clamps another workpiece")
                try CellCheck.require((machine.workpieceOwners[workpieceID] ?? nil) == command.spindleID,
                                      "step \(step.id): chuck \(command.spindleID) cannot clamp workpiece \(workpieceID) it does not own")
                if let length = cell.workpiece(workpieceID)!.lengthMM {
                    try CellCheck.require(command.gripLengthMM! <= length,
                                          "step \(step.id): clamp grip exceeds workpiece \(workpieceID) length")
                }
            case .release:
                let held = state.clampedWorkpieceID
                try CellCheck.require(held != nil, "step \(step.id): chuck \(command.spindleID) has nothing to release")
                let otherHolders = machine.spindleStates.filter { $0.key != command.spindleID && $0.value.clampedWorkpieceID == held }
                let ejectAllowed = cell.uncommon?.allowsPartEject == true
                try CellCheck.require(!otherHolders.isEmpty || ejectAllowed,
                                      "step \(step.id): release would drop the last grip of workpiece \(held!)")
            }
        case .indexTurret(let index):
            let state = machine.turretStates[index.turretID]!
            try CellCheck.require(state.stationID != index.stationID,
                                  "step \(step.id): turret \(index.turretID) already at station \(index.stationID)")
        case .synchronize(let sync):
            let first = machine.spindleStates[sync.spindleIDs[0]]!
            let second = machine.spindleStates[sync.spindleIDs[1]]!
            switch sync.mode {
            case .matchedRPM:
                try CellCheck.require(first.mode == .rpm && second.mode == .rpm,
                                      "step \(step.id): matched-RPM synchronization needs both spindles in RPM mode")
                let a = cell.spindle(sync.spindleIDs[0])!.frame.axis
                let b = cell.spindle(sync.spindleIDs[1])!.frame.axis
                let cosine = zip(a,b).reduce(0.0) { $0 + $1.0*$1.1 }
                let limit = cos(min(cell.uncommon?.transferAxisToleranceDegrees ?? 1,45)*Double.pi/180)
                try CellCheck.require(abs(cosine) >= limit && first.direction != nil && second.direction != nil,
                                      "step \(step.id): matched-RPM synchronization requires parallel axes and commanded directions")
                try CellCheck.require(cosine * first.direction!.sign * second.direction!.sign >= limit,
                                      "step \(step.id): matched-RPM synchronization needs aligned world rotation directions")
                let requestedRPM = (first.rpm ?? 0) * (sync.speedRatio ?? 1)
                try CellCheck.require(requestedRPM > 0 && requestedRPM <= cell.spindle(sync.spindleIDs[1])!.maxRPM && first.phase(atSeconds:time) != nil,
                                      "step \(step.id): synchronization exceeds receiver RPM capacity or lacks a donor phase datum")
            case .bothStopped:
                try CellCheck.require(first.mode == .stopped && second.mode == .stopped,
                                      "step \(step.id): stopped synchronization needs both spindles stopped")
            }
        case .transfer(let transfer):
            let donor = machine.spindleStates[transfer.donorSpindleID]!
            let receiver = machine.spindleStates[transfer.receiverSpindleID]!
            try CellCheck.require(donor.clampedWorkpieceID == transfer.workpieceID,
                                  "step \(step.id): donor \(transfer.donorSpindleID) does not clamp workpiece \(transfer.workpieceID)")
            try CellCheck.require((donor.gripLengthMM ?? 0) > 0,
                                  "step \(step.id): donor \(transfer.donorSpindleID) has no grip on workpiece \(transfer.workpieceID)")
            try CellCheck.require(receiver.clampedWorkpieceID == nil,
                                  "step \(step.id): receiver \(transfer.receiverSpindleID) already clamps a workpiece")
            let part = cell.workpiece(transfer.workpieceID)!
            if let radius = part.envelopeRadiusMM {
                try CellCheck.require(receiver.chuckOpeningDiameterMM >= 2*radius + transfer.clearanceMM,
                                      "step \(step.id): receiver opening \(receiver.chuckOpeningDiameterMM) mm cannot clear envelope Ø\(2*radius) mm plus \(transfer.clearanceMM) mm")
            } else {
                try CellCheck.require(receiver.chuckOpeningDiameterMM >= transfer.clearanceMM,
                                      "step \(step.id): receiver opening below transfer clearance")
                let note = "Workpiece \(transfer.workpieceID) has no envelope radius; the receiver opening was only checked against the transfer clearance."
                if !warnings.contains(note) { warnings.append(note) }
            }
            // Both spindles stopped, or an explicit synchronization covers
            // the pair and is still valid (no mode change since).
            let key = [transfer.donorSpindleID, transfer.receiverSpindleID].sorted().joined(separator: "|")
            let record = syncRecords[key]
            let synchronized = record.map {
                $0.completedAt >= (lastModeChange[transfer.donorSpindleID] ?? -1) &&
                $0.completedAt >= (lastModeChange[transfer.receiverSpindleID] ?? -1)
            } ?? false
            let bothStopped = donor.mode == .stopped && receiver.mode == .stopped
            try CellCheck.require(bothStopped || synchronized,
                                  "step \(step.id): transfer without synchronization or stopped spindles is unsafe and unsupported")
            if synchronized, let record, record.mode == .matchedRPM {
                // Commanded world rotation directions must agree at the grip:
                // for antiparallel axes the commanded directions are opposite
                // while the world rotation vectors align.
                let donorAxis = cell.spindle(transfer.donorSpindleID)!.frame.axis
                let receiverAxis = cell.spindle(transfer.receiverSpindleID)!.frame.axis
                let tolerance = cell.uncommon?.transferAxisToleranceDegrees ?? 1
                let limit = cos(min(tolerance, 45) * Double.pi / 180)
                let donorVector = donorAxis.map { $0 * (donor.direction?.sign ?? 0) }
                let receiverVector = receiverAxis.map { $0 * (receiver.direction?.sign ?? 0) }
                let worldDot = zip(donorVector, receiverVector).reduce(0.0) { $0 + $1.0*$1.1 }
                let aligned = worldDot >= limit
                try CellCheck.require(aligned,
                                      "step \(step.id): matched-RPM transfer needs aligned world rotation directions between spindles")
                try CellCheck.require(donor.direction != nil && receiver.direction != nil,
                                      "step \(step.id): matched-RPM transfer requires commanded directions on both spindles")
                try CellCheck.require(abs(record.speedRatio-1) <= 1e-9 && abs((donor.rpm ?? 0)-(receiver.rpm ?? 0)) <= 1e-6,
                                      "step \(step.id): rigid dual-grip transfer requires equal spindle RPM and a 1:1 ratio")
                let reference = machine.spindleStates[record.referenceSpindleID]!
                let follower = machine.spindleStates[record.receiverSpindleID]!
                let a = cell.spindle(record.referenceSpindleID)!.frame.axis
                let b = cell.spindle(record.receiverSpindleID)!.frame.axis
                let orientation = zip(a,b).reduce(0.0) { $0 + $1.0*$1.1 } >= 0 ? 1.0 : -1.0
                guard let referencePhase = reference.phase(atSeconds:time),let followerPhase = follower.phase(atSeconds:time) else {
                    throw ManufacturingError.invalid("cell: step \(step.id): synchronized transfer lacks commanded phase data")
                }
                var phaseError = (followerPhase-orientation*referencePhase-record.targetPhaseOffsetDegrees).truncatingRemainder(dividingBy:360)
                if phaseError > 180 { phaseError -= 360 };if phaseError < -180 { phaseError += 360 }
                try CellCheck.require(abs(phaseError) <= record.phaseToleranceDegrees,
                                      "step \(step.id): commanded synchronization phase exceeds the transfer tolerance")
            }
            try CellCheck.require((machine.workpieceOwners[transfer.workpieceID] ?? nil) == transfer.donorSpindleID,
                                  "step \(step.id): workpiece \(transfer.workpieceID) is not owned by donor \(transfer.donorSpindleID)")
            try Self.validatePartGeometry(part, spindle: cell.spindle(transfer.donorSpindleID)!,
                                          toleranceDegrees: cell.uncommon?.transferAxisToleranceDegrees ?? 1)
            // Acquisition kinematics: the receiver grip interval must
            // physically overlap the held part. A chuck positioned away from
            // the part fails closed instead of silently passing a remote
            // grip; without a known part length the check is impossible and
            // also fails closed.
            try CellCheck.require(part.lengthMM != nil,
                                  "step \(step.id): transfer requires a known workpiece length for grip overlap")
            let beforeTransform = machine.workpieceTransforms[transfer.workpieceID]!
            let axis = cell.spindle(transfer.receiverSpindleID)!.frame.axis
            let localZ = [beforeTransform.rotation[2], beforeTransform.rotation[5], beforeTransform.rotation[8]]
            func axisCoordinate(_ localZMM: Double) -> Double {
                let world = zip(beforeTransform.translationMM, localZ).map { $0 + $1 * localZMM }
                let delta = zip(world, transfer.acquisitionOriginMM).map { $0 - $1 }
                return zip(delta, axis).reduce(0.0) { $0 + $1.0*$1.1 }
            }
            let partLow = axisCoordinate(0)
            let partHigh = axisCoordinate(part.lengthMM!)
            let partInterval = (min(partLow, partHigh), max(partLow, partHigh))
            let overlap = min(transfer.receiverGripLengthMM, partInterval.1) - max(0.0, partInterval.0)
            try CellCheck.require(overlap + 1e-6 >= transfer.receiverGripLengthMM,
                                  "step \(step.id): insufficient actual axial grip on \(transfer.workpieceID); requested grip does not overlap fully: \(max(0,overlap)) mm, requested \(transfer.receiverGripLengthMM) mm")
        case .operate(let operation):
            let spindle = machine.spindleStates[operation.spindleID]!
            try CellCheck.require(spindle.clampedWorkpieceID == operation.workpieceID,
                                  "step \(step.id): spindle \(operation.spindleID) does not clamp workpiece \(operation.workpieceID)")
            try CellCheck.require((machine.workpieceOwners[operation.workpieceID] ?? nil) == operation.spindleID,
                                  "step \(step.id): workpiece \(operation.workpieceID) is not owned by spindle \(operation.spindleID)")
            let study = operation.study
            // Never simulate one speed law and schedule another: an active
            // fixed-RPM turning law must match the runtime spindle RPM
            // (capped), and CSS was already refused at validation time.
            if study.turning.enabled, let cutting = study.turningCutting {
                let capped = min(cutting.spindleRPM, cutting.maxSpindleRPM)
                try CellCheck.require(spindle.mode == .rpm && abs((spindle.rpm ?? -1) - capped) <= 1e-9,
                                      "step \(step.id): runtime spindle \(operation.spindleID) RPM does not match the study's capped fixed RPM \(capped)")
            }
            // Live-tool work (legacy slot or non-axisymmetric CAM) requires a
            // stopped/C-index work spindle; only a genuinely coaxial
            // centreline drill may run against a rotating workpiece.
            let spindleAxis = cell.spindle(operation.spindleID)!.frame.axis
            func coaxial(_ a: [Double]) -> Bool {
                let dot = abs(zip(a, spindleAxis).reduce(0.0) { $0 + $1.0*$1.1 })
                let limit = cos(min(cell.uncommon?.transferAxisToleranceDegrees ?? 1, 45) * Double.pi / 180)
                return dot >= limit
            }
            var requiresRigidSpindle = study.milling.enabled
            if !requiresRigidSpindle, let cam = study.cam {
                for camOp in cam.operations where camOp.enabled {
                    guard camOp.strategy == "drill",
                          let tool = cam.tools.first(where: { $0.id == camOp.toolID }),
                          tool.kind == "drill", coaxial(camOp.frame.axis) else {
                        requiresRigidSpindle = true
                        break
                    }
                }
            }
            if requiresRigidSpindle {
                try CellCheck.require(spindle.mode == .stopped || spindle.mode == .cIndex,
                                      "step \(step.id): live-tool operation on workpiece \(operation.workpieceID) requires a stopped or C-index work spindle")
            }
            if let stationID = operation.stationID {
                let turretID = operation.turretID!
                let turretState = machine.turretStates[turretID]!
                try CellCheck.require(turretState.stationID == stationID,
                                      "step \(step.id): turret \(turretID) is not indexed to station \(stationID)")
                let station = cell.turret(turretID)!.stations.first { $0.id == stationID }!
                if let expected = operation.toolID, let actual = station.toolID {
                    try CellCheck.require(expected == actual,
                                          "step \(step.id): station \(stationID) holds tool \(actual), not \(expected)")
                }
                if let expected = operation.turningToolID, let actual = station.turningToolID {
                    try CellCheck.require(expected == actual,
                                          "step \(step.id): station \(stationID) holds turning tool \(actual), not \(expected)")
                }
                // The record must match the study's effective setup and nose.
                if let turningID = operation.turningToolID ?? station.turningToolID,
                   let record = cell.turningTool(turningID) {
                    try record.validate(matching: operation.study)
                }
            }
            // Stock dependencies must already hold material state: they must
            // be operate or transfer steps on the same workpiece.
            for dependency in operation.stockDependencyIDs {
                guard let source = stepsByID[dependency] else { continue }
                switch source.action {
                case .operate(let prior):
                    try CellCheck.require(prior.workpieceID == operation.workpieceID,
                                          "step \(step.id): stock dependency \(dependency) is on a different workpiece")
                case .transfer(let prior):
                    try CellCheck.require(prior.workpieceID == operation.workpieceID,
                                          "step \(step.id): stock dependency \(dependency) is on a different workpiece")
                default:
                    throw ManufacturingError.invalid("cell plan: step \(step.id): stock dependency \(dependency) produces no stock state")
                }
            }
        case .approach(let approach):
            if let partID = approach.workpieceID {
                let owner = machine.workpieceOwners[partID] ?? nil
                try CellCheck.require(owner == approach.spindleID,
                                      "step \(step.id): approach targets workpiece \(partID) not owned by spindle \(approach.spindleID)")
            }
        case .barrier, .wait, .spindle, .parkTurret, .retract, .dwell:
            break
        }
        _ = time
    }
}
