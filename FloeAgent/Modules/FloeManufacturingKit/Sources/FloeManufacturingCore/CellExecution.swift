// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

public struct ManufacturingCellProject:Codable,Equatable,Sendable,Identifiable {
    public struct MotionCheck:Codable,Equatable,Sendable,Identifiable {
        public var id:String
        public var stepID:String
        public var request:MachineQueryRequest
        public init(id:String,stepID:String,request:MachineQueryRequest) { self.id = id; self.stepID = stepID; self.request = request }
    }
    public var formatVersion = 1
    public var cell:ManufacturingCell
    public var machineChecks:[MotionCheck]
    public var maxRetainedBytes = 64_000_000
    public var id:UUID { cell.id }
    public init(cell:ManufacturingCell,machineChecks:[MotionCheck] = []) { self.cell = cell; self.machineChecks = machineChecks }
    public static func demonstration()->Self { .init(cell:.opposingSpindleTwoTurret()) }
    public func validate() throws {
        try cell.validate()
        guard formatVersion == 1,cell.steps.count <= 512,machineChecks.count <= 128,
              (1...64_000_000).contains(maxRetainedBytes),
              Set(machineChecks.map(\.id)).count == machineChecks.count else { throw ManufacturingError.invalid("cell project retention/event budget") }
        let steps = Set(cell.steps.map(\.id))
        for check in machineChecks {
            guard !check.id.isEmpty,steps.contains(check.stepID) else { throw ManufacturingError.invalid("machine check step identity") }
            try check.request.validate()
        }
        let operations = cell.steps.compactMap { if case .operate(let op) = $0.action { op } else { nil } }
        guard !operations.isEmpty,operations.count <= 32 else { throw ManufacturingError.invalid("cell requires 1...32 machining jobs") }
        for operation in operations { try operation.study.validate() }
    }
}

public struct CellSimulationArtifact:Codable,Sendable {
    public struct Job:Codable,Sendable {
        public var stepID:String
        public var workpieceID:String
        public var spindleID:String
        public var worldFromWorkpiece:CellRigidTransform
        public var artifact:ManufacturingArtifact
        /// Neutral world paths; the embedded artifact and stock remain part-local.
        public var worldPaths:[ManufacturingResult.Path]
        /// World-axis Cartesian reference offset. TCP/material stay unchanged.
        public var toolOffsetMM:[Double]?
        public var worldToolReferencePaths:[ManufacturingResult.Path]
    }
    public struct MotionFeedback:Codable,Sendable {
        public var checkID:String
        public var stepID:String
        public var result:MachineQueryResult
    }
    public var formatVersion = 1
    public var projectID:UUID
    public var inputSHA256:String
    public var executedCell:ManufacturingCell
    public var schedule:CellSchedule
    public var jobs:[Job]
    public var machineFeedback:[MotionFeedback]
    public var finalStock:[String:ManufacturingStockState]
    public var derivedStockEdges:[CellEdge]
    public var warnings:[String]
    public var capabilities:[String]
    public var sources:[String]
    public var elapsedSeconds:Double
    public var processPeakBytes:UInt64

    public func validate(for project:ManufacturingCellProject) throws {
        try project.validate()
        guard formatVersion == 1,projectID == project.id,inputSHA256 == (try ResearchArchive.digest(project)),
              elapsedSeconds.isFinite && elapsedSeconds >= 0,
              capabilities == CellManufacturingEngine.capabilities(hasMotionChecks:!machineFeedback.isEmpty),
              sources == ["Floe R5 CellPlanner / CellExecution (MPL-2.0)"] + Array(Set(jobs.map { $0.artifact.result.backend })).sorted() else { throw ManufacturingError.stale }
        var expected = project.cell
        let operations = project.cell.steps.filter { if case .operate = $0.action { true } else { false } }
        guard jobs.count == operations.count,Set(jobs.map(\.stepID)).count == jobs.count,
              Set(jobs.map(\.stepID)) == Set(operations.map(\.id)) else { throw ManufacturingError.archive("cell job coverage") }
        var stocks = [String:ManufacturingStockState](), predecessors = [String:String](), edges = [CellEdge]()
        for job in jobs {
            guard let index = expected.steps.firstIndex(where:{ $0.id == job.stepID }),case .operate(let operation) = expected.steps[index].action,
                  job.workpieceID == operation.workpieceID,job.spindleID == operation.spindleID,
                  job.artifact.studyID == operation.study.id,job.artifact.inputSHA256 == (try operation.study.fingerprint()),
                  job.artifact.startingStockSHA256 == (try stocks[job.workpieceID]?.fingerprint()) else { throw ManufacturingError.archive("cell material/source chain") }
            try job.worldFromWorkpiece.validate(); try job.artifact.result.validate(for:operation.study)
            guard let end = job.artifact.result.stockState else { throw ManufacturingError.archive("cell job lacks material checkpoint") }
            if let previous = stocks[job.workpieceID] { try end.validateContinuation(from:previous) }
            stocks[job.workpieceID] = end
            if let previous = predecessors[job.workpieceID] {
                let edge = CellEdge(from:previous,to:job.stepID)
                if !expected.edges.contains(edge) { expected.edges.append(edge); edges.append(edge) }
            }
            predecessors[job.workpieceID] = job.stepID
            if let timeline = job.artifact.result.cuttingTimeline { expected.steps[index].action = .operate(try operation.patchingDuration(from:timeline)) }
            guard job.worldPaths == CellManufacturingEngine.worldPaths(job.artifact.result.paths,transform:job.worldFromWorkpiece) else {
                throw ManufacturingError.archive("cell world path transform mismatch")
            }
            guard job.worldToolReferencePaths == CellManufacturingEngine.referencePaths(job.worldPaths,offset:job.toolOffsetMM) else {
                throw ManufacturingError.archive("cell tool-reference path offset mismatch")
            }
        }
        guard stocks == finalStock,edges == derivedStockEdges,expected == executedCell else { throw ManufacturingError.archive("cell executed program mismatch") }
        let planned = try CellPlanner().plan(executedCell)
        guard try ResearchArchive.digest(planned) == ResearchArchive.digest(schedule) else { throw ManufacturingError.archive("cell schedule mismatch") }
        for job in jobs {
            guard let step = schedule.steps.first(where:{ $0.stepID == job.stepID }),
                  step.workpieceTransforms[job.workpieceID] == job.worldFromWorkpiece,
                  let context = schedule.jobs.first(where:{ $0.stepID == job.stepID }),context.toolOffsetMM == job.toolOffsetMM else { throw ManufacturingError.archive("cell job frame/offset mismatch") }
        }
        guard machineFeedback.count == project.machineChecks.count,Set(machineFeedback.map(\.checkID)).count == machineFeedback.count else { throw ManufacturingError.archive("cell machine feedback coverage") }
        for feedback in machineFeedback {
            guard let check = project.machineChecks.first(where:{ $0.id == feedback.checkID }),feedback.stepID == check.stepID else { throw ManufacturingError.archive("cell machine feedback identity") }
            try feedback.result.validate(for:check.request)
        }
    }
}

public struct CellManufacturingEngine:Sendable {
    public init() {}
    static func capabilities(hasMotionChecks:Bool)->[String] {
        ["commanded-multi-spindle-grip-transfer-state","identified-turret-stations-and-channel-resource-schedule",
         "named-waits-and-collective-barriers","shared-workpiece-occupancy-continuation","neutral-world-toolpaths","source-bound-atomic-cell-archives"] +
        (hasMotionChecks ? ["explicit-sampled-machine-body-feedback"] : [])
    }
    public func compute(_ project:ManufacturingCellProject,control:ComputationControl = .init()) throws -> CellSimulationArtifact {
        try control.check();try project.validate();try control.check()
        let inputData = try ManufacturingStudy.encoder.encode(project)
        guard inputData.count <= ResearchArchive.byteLimit else { throw ManufacturingError.invalid("cell input byte budget") }
        let inputSHA256 = ManufacturingStudy.digest(inputData)
        let started = Date()
        let operationCount = project.cell.steps.filter { if case .operate = $0.action { true } else { false } }.count
        let total = operationCount+project.machineChecks.count+2
        func stageControl(_ index:Int)->ComputationControl {
            .init(parent:control,progress:{ fraction,phase in _ = control.report((Double(index)+fraction)/Double(total),phase) })
        }
        let plan = try CellPlanner().plan(project.cell,control:stageControl(0))
        var executed = project.cell,jobs = [CellSimulationArtifact.Job](),stocks = [String:ManufacturingStockState]()
        var previousJobs = [String:String](),edges = [CellEdge](),retainedBytes = 0
        let engine = NativeManufacturingEngine()
        for scheduled in plan.steps {
            try control.check()
            guard let index = executed.steps.firstIndex(where:{ $0.id == scheduled.stepID }),case .operate(let operation) = executed.steps[index].action else { continue }
            guard let transform = scheduled.workpieceTransforms[operation.workpieceID] else { throw ManufacturingError.native("cell planner omitted workpiece frame") }
            let value = try engine.compute(operation.study,startingStock:stocks[operation.workpieceID],control:stageControl(jobs.count+1))
            guard let state = value.result.stockState else { throw ManufacturingError.native("cell requires the R5 material checkpoint component") }
            stocks[operation.workpieceID] = state
            let offset = plan.jobs.first(where:{ $0.stepID == scheduled.stepID })?.toolOffsetMM
            let world = Self.worldPaths(value.result.paths,transform:transform)
            let job = CellSimulationArtifact.Job(stepID:scheduled.stepID,workpieceID:operation.workpieceID,spindleID:operation.spindleID,
                worldFromWorkpiece:transform,artifact:value,worldPaths:world,toolOffsetMM:offset,
                worldToolReferencePaths:Self.referencePaths(world,offset:offset))
            retainedBytes += try ManufacturingStudy.encoder.encode(job).count
            guard retainedBytes <= project.maxRetainedBytes else { throw ManufacturingError.native("cell retained result byte budget") }
            jobs.append(job)
            if let predecessor = previousJobs[operation.workpieceID] {
                let edge = CellEdge(from:predecessor,to:scheduled.stepID)
                if !executed.edges.contains(edge) { executed.edges.append(edge); edges.append(edge) }
            }
            previousJobs[operation.workpieceID] = scheduled.stepID
            if let timeline = value.result.cuttingTimeline { executed.steps[index].action = .operate(try operation.patchingDuration(from:timeline)) }
        }
        // Freeze material order before updating durations, so independent-channel
        // timing changes cannot reorder operations on the same piece.
        let schedule = try CellPlanner().plan(executed,control:stageControl(operationCount+1))
        // Replanning may change commanded spindle phases at handoff. Geometry
        // remains in the immutable part frame; rebuild world paths from the
        // final schedule, rather than retaining an earlier nominal placement.
        for i in jobs.indices {
            guard let placement = schedule.steps.first(where:{ $0.stepID == jobs[i].stepID })?.workpieceTransforms[jobs[i].workpieceID] else {
                throw ManufacturingError.native("final schedule omitted machining placement")
            }
            jobs[i].worldFromWorkpiece = placement
            jobs[i].worldPaths = Self.worldPaths(jobs[i].artifact.result.paths,transform:placement)
            jobs[i].worldToolReferencePaths = Self.referencePaths(jobs[i].worldPaths,offset:jobs[i].toolOffsetMM)
        }
        var feedback = [CellSimulationArtifact.MotionFeedback]()
        for check in project.machineChecks {
            try control.check()
            let result = try engine.machineQuery(check.request,control:stageControl(operationCount+2+feedback.count))
            retainedBytes += try ManufacturingStudy.encoder.encode(result).count
            guard retainedBytes <= project.maxRetainedBytes else { throw ManufacturingError.native("cell motion feedback byte budget") }
            feedback.append(.init(checkID:check.id,stepID:check.stepID,result:result))
        }
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        let artifact = CellSimulationArtifact(projectID:project.id,inputSHA256:inputSHA256,executedCell:executed,
            schedule:schedule,jobs:jobs,machineFeedback:feedback,finalStock:stocks,derivedStockEdges:edges,
            warnings:["CPU jobs are evaluated serially; the schedule describes nominal machine concurrency.",
                      "Only explicit machine motion checks are evaluated. Machining paths without joint/body queries have no whole-machine collision verdict.",
                      "Station tool offsets are world-axis Cartesian offsets on neutral tool-reference paths; material TCP paths are retained separately. Wear offsets remain saved metadata.",
                      "World paths use declared setup frames. Spindle RPM/C-index states are retained separately; these paths are not automatic complete machine-joint trajectories.",
                      "No implicit links, automatic general IK, controller commands or physical spindle/chuck confirmation are generated."],
            capabilities:Self.capabilities(hasMotionChecks:!feedback.isEmpty),
            sources:["Floe R5 CellPlanner / CellExecution (MPL-2.0)"] + Array(Set(jobs.map { $0.artifact.result.backend })).sorted(),
            elapsedSeconds:Date().timeIntervalSince(started),processPeakBytes:UInt64(max(0,usage.ru_maxrss)))
        try control.check(); try artifact.validate(for:project)
        guard try ManufacturingStudy.encoder.encode(artifact).count <= project.maxRetainedBytes else {
            throw ManufacturingError.native("complete cell artifact byte budget")
        }
        _ = control.report(1,"cell-complete");try control.check()
        return artifact
    }
    static func worldPaths(_ paths:[ManufacturingResult.Path],transform:CellRigidTransform)->[ManufacturingResult.Path] {
        paths.map { source in
            var path = source
            path.points = path.points.map { transform.applied(to:$0) }
            path.toolAxes = path.toolAxes?.map { axis in
                let p = transform.applied(to:axis)
                return zip(p,transform.translationMM).map(-)
            }
            return path
        }
    }
    static func referencePaths(_ paths:[ManufacturingResult.Path],offset:[Double]?)->[ManufacturingResult.Path] {
        guard let offset else { return paths }
        return paths.map { source in
            var path = source;path.points = source.points.map { zip($0,offset).map(+) };return path
        }
    }
}

public enum ManufacturingCellArchive {
    public static func save(project:ManufacturingCellProject,artifact:CellSimulationArtifact,to url:URL) throws {
        try ResearchArchive.save(input:project,output:artifact,family:.manufacturingCell,to:url) { try $1.validate(for:$0) }
    }
    public static func open(_ url:URL) throws -> (ManufacturingCellProject,CellSimulationArtifact) {
        try ResearchArchive.open(url,input:ManufacturingCellProject.self,output:CellSimulationArtifact.self,family:.manufacturingCell) { try $1.validate(for:$0) }
    }
    public static func neutralExport(_ artifact:CellSimulationArtifact) throws -> Data {
        struct Export:Encodable {
            var formatVersion = 1
            var units = "mm, degrees, rpm, seconds"
            var schedule:CellSchedule
            var jobs:[CellSimulationArtifact.Job]
            var motionFeedback:[CellSimulationArtifact.MotionFeedback]
            var warnings:[String]
            var capabilities:[String]
            var sources:[String]
        }
        return try ManufacturingStudy.encoder.encode(Export(schedule:artifact.schedule,jobs:artifact.jobs,motionFeedback:artifact.machineFeedback,warnings:artifact.warnings,capabilities:artifact.capabilities,sources:artifact.sources))
    }
}

public actor CellManufacturingService {
    private var controls:[UUID:ComputationControl] = [:]
    public init() {}
    public func calculate(_ project:ManufacturingCellProject,progress:@escaping @Sendable(Double,String)->Void = { _,_ in }) async throws -> CellSimulationArtifact {
        let id = UUID(),control = ComputationControl(progress:progress)
        controls[id] = control; defer { controls.removeValue(forKey:id) }
        return try await withTaskCancellationHandler {
            let value = try await Task.detached(priority:.userInitiated) { try CellManufacturingEngine().compute(project,control:control) }.value
            try control.check(); try Task.checkCancellation()
            guard value.inputSHA256 == (try ResearchArchive.digest(project)) else { throw ManufacturingError.stale }
            return value
        } onCancel: { control.cancel() }
    }
}
