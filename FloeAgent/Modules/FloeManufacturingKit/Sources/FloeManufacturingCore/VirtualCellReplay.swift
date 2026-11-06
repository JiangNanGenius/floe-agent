// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct VirtualSpindlePose:Codable,Equatable,Sendable,Identifiable {
    public var id:String
    public var frame:CellRigidTransform
    public var carriageOriginMM:[Double]
    public var unwrappedPhaseDegrees:Double
    public var wrappedPhaseDegrees:Double
    public var phaseKnown:Bool
    public var rpm:Double?
    public var mode:CellMachineState.SpindleState.Mode
    public var chuckOpeningDiameterMM:Double
    public var clampedWorkpieceID:String?
}
public struct VirtualWorkpiecePose:Codable,Equatable,Sendable,Identifiable {
    public var id:String
    public var worldFromWorkpiece:CellRigidTransform
    public var ownerSpindleID:String?
    public var lastCompletedJobID:String?
    public var activeJobID:String?
}
public struct VirtualToolPose:Codable,Equatable,Sendable {
    public var stepID:String
    public var spindleID:String
    public var turretID:String?
    public var toolID:String?
    public var worldTipMM:[Double]
    public var worldAxis:[Double]
    public var pathIndex:Int
}
public struct VirtualCellSnapshot:Codable,Equatable,Sendable {
    public var seconds:Double
    public var spindles:[VirtualSpindlePose]
    public var workpieces:[VirtualWorkpiecePose]
    public var tools:[VirtualToolPose]
    public var activeStepIDs:[String]
    public var warnings:[String]
}

/// Deterministic seeking in R5's nominal command schedule. RPM integrates phase;
/// mode/C-index/sync commands take effect at their recorded completion boundary.
/// Transfer carriage travel is linear over explicit approach/retract intervals.
/// It is deliberately separate from a drive/servo dynamics prediction.
public struct VirtualCellReplay:Sendable {
    public let project:ManufacturingCellProject
    public let artifact:CellSimulationArtifact
    public var durationSeconds:Double { artifact.schedule.totalSeconds }
    private struct Event:Sendable { var time:Double;var rank:Int;var id:String;var kind:Int }
    private let events:[Event]
    private let stepMap:[String:CellStep]
    private let timing:[String:CellScheduledStep]
    private struct AngleState {
        var mode:CellMachineState.SpindleState.Mode
        var rpm:Double?
        var direction:CellRotationDirection?
        var angle:Double
        var known:Bool
        var time = 0.0
        var opening:Double
        var held:String?
        mutating func advance(_ end:Double) {
            if mode == .rpm { angle += (rpm ?? 0)*(direction?.sign ?? 0)*6*(end-time) }
            time = end
        }
    }
    private struct Binding {
        var owner:String?
        var relative:CellRigidTransform
        var transferID:String?
    }
    public init(project:ManufacturingCellProject,artifact:CellSimulationArtifact,control:ComputationControl = .init()) throws {
        try control.check();try artifact.validate(for:project);try control.check()
        self.project = project;self.artifact = artifact
        stepMap = Dictionary(uniqueKeysWithValues:artifact.executedCell.steps.map { ($0.id,$0) })
        timing = Dictionary(uniqueKeysWithValues:artifact.schedule.steps.map { ($0.stepID,$0) })
        var result = [Event]()
        for entry in artifact.schedule.steps {
            guard let step = artifact.executedCell.steps.first(where:{ $0.id == entry.stepID }) else { throw ManufacturingError.invalid("virtual replay step identity") }
            switch step.action {
            case .spindle,.chuck,.synchronize:result.append(.init(time:entry.endSeconds,rank:0,id:step.id,kind:0))
            case .transfer:
                guard let record = artifact.schedule.transfers.first(where:{ $0.stepID == step.id }) else { throw ManufacturingError.invalid("virtual transfer receipt") }
                result.append(.init(time:record.acquireSeconds,rank:1,id:step.id,kind:1))
                result.append(.init(time:record.releaseSeconds,rank:2,id:step.id,kind:2))
            default:break
            }
        }
        events = result.sorted { ($0.time,$0.rank,$0.id) < ($1.time,$1.rank,$1.id) }
    }
    public func snapshot(at seconds:Double) throws -> VirtualCellSnapshot {
        guard seconds.isFinite,seconds>=0,seconds<=durationSeconds+1e-9 else { throw ManufacturingError.invalid("virtual replay time outside schedule") }
        let t = min(seconds,durationSeconds)
        var states = [String:AngleState](),bindings = [String:Binding](),warnings = [String]()
        for spindle in project.cell.spindles {
            guard let initial = artifact.schedule.startState.spindleStates[spindle.id] else { throw ManufacturingError.invalid("virtual initial spindle") }
            let phase = initial.mode == .cIndex ? initial.cIndexDegrees : initial.phaseDatumDegrees
            states[spindle.id] = .init(mode:initial.mode,rpm:initial.rpm,direction:initial.direction,angle:phase ?? 0,known:phase != nil,opening:initial.chuckOpeningDiameterMM,held:initial.clampedWorkpieceID)
            if phase == nil { warnings.append("Spindle \(spindle.id) has no commanded phase datum; its visual zero is a reference only.") }
        }
        for part in project.cell.workpieces {
            if let owner = part.ownerSpindleID,let state = states[owner] {
                let frame = spindleFrame(owner,at:0,angle:state.angle)
                bindings[part.id] = .init(owner:owner,relative:frame.inverse.composed(with:part.worldFromWorkpiece))
            } else { bindings[part.id] = .init(owner:nil,relative:part.worldFromWorkpiece) }
        }
        func placed(_ id:String,_ time:Double)->CellRigidTransform {
            guard let binding = bindings[id] else { return .identity }
            guard let owner = binding.owner,let state = states[owner] else { return binding.relative }
            let angle = state.angle+(state.mode == .rpm ? (state.rpm ?? 0)*(state.direction?.sign ?? 0)*6*(time-state.time) : 0)
            let frame = spindleFrame(owner,at:time,angle:angle)
            var relative = binding.relative
            if let id = binding.transferID,let entry = timing[id],let record = artifact.schedule.transfers.first(where:{ $0.stepID == id }),
               let step = stepMap[id],case .transfer(let command) = step.action {
                let fraction = entry.endSeconds>record.releaseSeconds ? max(0,min(1,(time-record.releaseSeconds)/(entry.endSeconds-record.releaseSeconds))) : 1
                let extra = Self.zRotation(command.twistDegrees*fraction)
                relative.rotation = extra.composed(with:.init(rotation:relative.rotation,translationMM:[0,0,0])).rotation
            }
            return frame.composed(with:relative)
        }
        for event in events where event.time<=t {
            for id in states.keys.sorted() { states[id]!.advance(event.time) }
            guard let step = stepMap[event.id] else { throw ManufacturingError.invalid("virtual event step") }
            if event.kind == 1,case .transfer(let transfer) = step.action {
                let before = placed(transfer.workpieceID,event.time)
                guard let receiver = states[transfer.receiverSpindleID] else { throw ManufacturingError.invalid("virtual receiver state") }
                let frame = spindleFrame(transfer.receiverSpindleID,at:event.time,angle:receiver.angle)
                bindings[transfer.workpieceID] = .init(owner:transfer.receiverSpindleID,relative:frame.inverse.composed(with:before),transferID:step.id)
                states[transfer.receiverSpindleID]!.held = transfer.workpieceID
            } else if event.kind == 2,case .transfer(let transfer) = step.action {
                states[transfer.donorSpindleID]!.held = nil
            } else {
                switch step.action {
                case .spindle(let command):
                    var state = states[command.spindleID]!
                    state.mode = .init(rawValue:command.mode.rawValue) ?? .stopped
                    state.rpm = command.rpm;state.direction = command.direction
                    if let index = command.cIndexDegrees { state.angle = index;state.known = true }
                    states[command.spindleID] = state
                case .synchronize(let sync):
                    if sync.mode == .matchedRPM {
                        let a = sync.spindleIDs[0],b = sync.spindleIDs[1],reference = states[a]!
                        let first = project.cell.spindles.first { $0.id == a }!,second = project.cell.spindles.first { $0.id == b }!
                        let orientation = zip(first.frame.axis,second.frame.axis).reduce(0.0) { $0+$1.0*$1.1 } >= 0 ? 1.0 : -1.0
                        var follower = states[b]!
                        let target = orientation*reference.angle+(sync.targetPhaseOffsetDegrees ?? 0)
                        follower.angle = target+360*((follower.angle-target)/360).rounded()
                        follower.rpm = (reference.rpm ?? 0)*(sync.speedRatio ?? 1);follower.known = reference.known;states[b] = follower
                    }
                case .chuck(let command):
                    switch command.operation {
                    case .open:states[command.spindleID]!.opening = command.openDiameterMM!
                    case .clamp:
                        let id = command.workpieceID!,before = placed(id,event.time),state = states[command.spindleID]!
                        let frame = spindleFrame(command.spindleID,at:event.time,angle:state.angle)
                        bindings[id] = .init(owner:command.spindleID,relative:frame.inverse.composed(with:before))
                        states[command.spindleID]!.held = id
                    case .release:
                        if let held = states[command.spindleID]!.held {
                            let before = placed(held,event.time)
                            states[command.spindleID]!.held = nil
                            let other = states.keys.sorted().first { states[$0]?.held == held }
                            if let other,let state = states[other] {
                                let frame = spindleFrame(other,at:event.time,angle:state.angle)
                                bindings[held] = .init(owner:other,relative:frame.inverse.composed(with:before))
                            } else { bindings[held] = .init(owner:nil,relative:before) }
                        }
                    }
                default:break
                }
            }
        }
        var spindlePoses = [VirtualSpindlePose]()
        for id in states.keys.sorted() {
            states[id]!.advance(t);let state = states[id]!,wrapped = Self.wrap(state.angle)
            spindlePoses.append(.init(id:id,frame:spindleFrame(id,at:t,angle:state.angle),carriageOriginMM:carriage(id,at:t),
                unwrappedPhaseDegrees:state.angle,wrappedPhaseDegrees:wrapped,phaseKnown:state.known,rpm:state.rpm,mode:state.mode,
                chuckOpeningDiameterMM:state.opening,clampedWorkpieceID:state.held))
        }
        var pieces = [VirtualWorkpiecePose](),tools = [VirtualToolPose]()
        for part in project.cell.workpieces {
            let jobs = artifact.jobs.filter { $0.workpieceID == part.id }
            let active = jobs.first { job in timing[job.stepID].map { $0.startSeconds<=t && t<$0.endSeconds } ?? false }
            let completed = jobs.filter { job in timing[job.stepID].map { $0.endSeconds<=t } ?? false }
                .max { timing[$0.stepID]!.endSeconds < timing[$1.stepID]!.endSeconds }
            let transform = placed(part.id,t);try transform.validate()
            pieces.append(.init(id:part.id,worldFromWorkpiece:transform,ownerSpindleID:bindings[part.id]?.owner,
                lastCompletedJobID:completed?.stepID,activeJobID:active?.stepID))
            guard let job = active,let entry = timing[job.stepID],let step = stepMap[job.stepID],case .operate(let operation) = step.action else { continue }
            guard let timeline = job.artifact.result.cuttingTimeline else { warnings.append("Job \(job.stepID) has no timeable toolpath; its tool pose is uncovered.");continue }
            if !timeline.excludedPathIndices.isEmpty { warnings.append("Job \(job.stepID) excludes \(timeline.excludedPathIndices.count) paths from timed replay; unlisted links are not interpolated.") }
            let local = max(0,min(timeline.totalSeconds,t-entry.startSeconds)),sample = try timeline.sample(atSeconds:local)
            let paths = job.artifact.result.paths
            guard paths.indices.contains(sample.pathIndex) else { throw ManufacturingError.invalid("virtual timed path index") }
            let path = paths[sample.pathIndex],turning = path.kind.hasPrefix("turning-")
            let placement = turning ? job.worldFromWorkpiece : transform
            var axis = [0.0,0,1]
            if let axes = path.toolAxes,axes.indices.contains(timeline.segments[sample.segmentIndex].startPointIndex) {
                let segment = timeline.segments[sample.segmentIndex],i = segment.startPointIndex
                axis = axes[i]
                if axes.indices.contains(i+1) {
                    let a = segment.startPointMM,b = segment.endPointMM,delta = zip(a,b).map { $1-$0 },v = zip(a,sample.pointMM).map { $1-$0 }
                    let dd = delta.reduce(0.0) { $0+$1*$1 },fraction = dd>1e-16 ? zip(delta,v).reduce(0.0) { $0+$1.0*$1.1 }/dd : 0
                    axis = try ToolAxisInterpolation.interpolate(axes[i],axes[i+1],fraction:max(0,min(1,fraction)))
                }
            } else if turning { axis = [1,0,0] }
            let r = placement.rotation,worldAxis = (0..<3).map { row in (0..<3).reduce(0.0) { $0+r[row*3+$1]*axis[$1] } }
            tools.append(.init(stepID:job.stepID,spindleID:operation.spindleID,turretID:operation.turretID,toolID:path.toolID,
                worldTipMM:placement.applied(to:sample.pointMM),worldAxis:worldAxis,pathIndex:sample.pathIndex))
        }
        if artifact.executedCell.steps.contains(where:{ if case .spindle(let command) = $0.action { command.mode == .cIndex } else { false } }) {
            warnings.append("C-index values are unwrapped commanded positions installed at command completion; no transition sweep or acceleration is fabricated.")
        }
        warnings += ["RPM phases use nominal command boundaries; synchronization acquisition is a commanded datum change, not a servo trajectory.",
                     "Only explicitly timed paths have tool poses. Transfer carriage travel is linear within declared intervals; approach/retract tool links without geometry remain uncovered."]
        return .init(seconds:t,spindles:spindlePoses,workpieces:pieces.sorted { $0.id<$1.id },tools:tools.sorted { $0.stepID<$1.stepID },
            activeStepIDs:artifact.schedule.steps.filter { $0.startSeconds<=t && t<$0.endSeconds }.map(\.stepID).sorted(),warnings:Array(Set(warnings)).sorted())
    }
    private func carriage(_ id:String,at t:Double)->[Double] {
        var origin = project.cell.spindles.first { $0.id == id }!.frame.originMM
        let transfers = artifact.schedule.transfers.filter { $0.receiverSpindleID == id }.sorted { timing[$0.stepID]!.startSeconds < timing[$1.stepID]!.startSeconds }
        for record in transfers {
            let start = timing[record.stepID]!.startSeconds,end = timing[record.stepID]!.endSeconds
            if t<start { break }
            if t<record.acquireSeconds { return Self.lerp(origin,record.acquisitionOriginMM,(t-start)/(record.acquireSeconds-start)) }
            if t<record.releaseSeconds { return record.acquisitionOriginMM }
            let destination = record.retractOriginMM ?? record.acquisitionOriginMM
            if t<end { return Self.lerp(record.acquisitionOriginMM,destination,(t-record.releaseSeconds)/(end-record.releaseSeconds)) }
            origin = destination
        }
        return origin
    }
    private func spindleFrame(_ id:String,at t:Double,angle:Double)->CellRigidTransform {
        var base = project.cell.spindles.first { $0.id == id }!.frame.transform;base.translationMM = carriage(id,at:t)
        return base.composed(with:Self.zRotation(angle))
    }
    private static func zRotation(_ degrees:Double)->CellRigidTransform {
        let theta = wrap(degrees)*Double.pi/180,c = cos(theta),s = sin(theta)
        return .init(rotation:[c,-s,0,s,c,0,0,0,1],translationMM:[0,0,0])
    }
    private static func wrap(_ degrees:Double)->Double { let v = degrees.truncatingRemainder(dividingBy:360);return v<0 ? v+360 : v }
    private static func lerp(_ a:[Double],_ b:[Double],_ t:Double)->[Double] { zip(a,b).map { $0+($1-$0)*max(0,min(1,t)) } }
}
