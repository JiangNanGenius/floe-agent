// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

public struct VirtualSpindleDriveCase:Codable,Equatable,Sendable,Identifiable {
    public var id:String
    public var spindleID:String
    public var request:SpindleDriveRequest
    public init(id:String,spindleID:String,request:SpindleDriveRequest) { self.id = id;self.spindleID = spindleID;self.request = request }
}
public struct VirtualMachineProject:Codable,Equatable,Sendable,Identifiable {
    public var formatVersion = 1
    public var id = UUID()
    public var cell:ManufacturingCellProject
    public var scene:VirtualMachineSceneConfiguration
    public var drives:[VirtualSpindleDriveCase] = []
    public var traceSamples = 121
    public var collisionFractions:[Double] = [0,0.5,1]
    public var maxRetainedBytes = 64_000_000
    public init(cell:ManufacturingCellProject) { self.cell = cell;scene = .demonstration(for:cell.cell) }
    public static func demonstration()->Self {
        var value = Self(cell:.demonstration())
        value.drives = [.init(id:"main-drive-example",spindleID:"main",request:.demonstration())]
        return value
    }
    public func validate() throws {
        try cell.validate();try scene.validate(for:cell.cell)
        guard formatVersion == 1,(2...2001).contains(traceSamples),collisionFractions.count <= 16,
              Set(collisionFractions).count == collisionFractions.count,collisionFractions.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              drives.count <= 16,Set(drives.map(\.id)).count == drives.count,
              (1...ResearchArchive.byteLimit).contains(maxRetainedBytes) else { throw ManufacturingError.invalid("virtual machine retention/sample budget") }
        for drive in drives {
            guard !drive.id.isEmpty,let spindle = cell.cell.spindles.first(where:{ $0.id == drive.spindleID }),
                  drive.request.configuration.maxRPM <= spindle.maxRPM else { throw ManufacturingError.invalid("virtual drive/spindle speed identity") }
            try drive.request.validate()
        }
    }
}
public struct VirtualPoseCollision:Codable,Equatable,Sendable {
    public enum Verdict:String,Codable,Sendable { case clear,interference,unresolved,uncovered }
    public var fraction:Double
    public var seconds:Double
    public var requestSHA256:String
    public var result:MachineQueryResult
    public var verdict:Verdict
    public init(fraction:Double,seconds:Double,requestSHA256:String,result:MachineQueryResult,verdict:Verdict) {
        self.fraction = fraction;self.seconds = seconds;self.requestSHA256 = requestSHA256;self.result = result;self.verdict = verdict
    }
}
public struct VirtualDriveArtifact:Codable,Equatable,Sendable,Identifiable {
    public var id:String
    public var spindleID:String
    public var result:SpindleDriveResult
}
public struct VirtualMachineArtifact:Codable,Sendable {
    public var formatVersion = 1
    public var projectID:UUID
    public var inputSHA256:String
    public var cellArtifact:CellSimulationArtifact
    public var trace:[VirtualCellSnapshot]
    public var collisions:[VirtualPoseCollision]
    public var drives:[VirtualDriveArtifact]
    public var elapsedSeconds:Double
    public var processPeakBytes:UInt64
    public var warnings:[String]
    public func validate(for project:VirtualMachineProject) throws {
        try project.validate()
        guard formatVersion == 1,projectID == project.id,inputSHA256 == (try ResearchArchive.digest(project)),
              elapsedSeconds.isFinite && elapsedSeconds>=0,trace.count == project.traceSamples,
              collisions.count == project.collisionFractions.count,drives.count == project.drives.count else { throw ManufacturingError.stale }
        let replay = try VirtualCellReplay(project:project.cell,artifact:cellArtifact)
        for (i,snapshot) in trace.enumerated() {
            let t = replay.durationSeconds*Double(i)/Double(project.traceSamples-1)
            guard snapshot.seconds == t,snapshot == (try replay.snapshot(at:t)) else { throw ManufacturingError.archive("virtual trace/source mismatch") }
        }
        for (index,feedback) in collisions.enumerated() {
            let fraction = project.collisionFractions.sorted()[index],t = replay.durationSeconds*fraction
            let snapshot = try replay.snapshot(at:t),scene = try VirtualMachineSceneBuilder.build(configuration:project.scene,project:project.cell,artifact:cellArtifact,snapshot:snapshot)
            let request = try scene.queryRequest(clearanceMM:project.scene.clearanceMM)
            try feedback.result.validate(for:request)
            guard feedback.fraction == fraction,feedback.seconds == t,feedback.requestSHA256 == (try ResearchArchive.digest(request)),
                  feedback.verdict == VirtualMachineEngine.verdict(feedback.result,scene:scene,snapshot:snapshot) else { throw ManufacturingError.archive("virtual collision/source mismatch") }
        }
        for (index,drive) in drives.enumerated() {
            let input = project.drives[index]
            guard drive.id == input.id,drive.spindleID == input.spindleID else { throw ManufacturingError.archive("virtual drive identity") }
            try drive.result.validate(for:input.request)
        }
    }
}
public struct VirtualMachineEngine:Sendable {
    public init() {}
    public func compute(_ project:VirtualMachineProject,reusing cellArtifact:CellSimulationArtifact? = nil,
                        control:ComputationControl = .init()) throws -> VirtualMachineArtifact {
        try control.check();try project.validate();let start = Date()
        let inputSHA = try ResearchArchive.digest(project)
        let cell = try cellArtifact ?? CellManufacturingEngine().compute(project.cell,control:.init(parent:control,progress:{ fraction,phase in _ = control.report(fraction*0.6,phase) }))
        let replay = try VirtualCellReplay(project:project.cell,artifact:cell,control:control)
        var trace = [VirtualCellSnapshot]()
        for i in 0..<project.traceSamples {
            try control.check();trace.append(try replay.snapshot(at:replay.durationSeconds*Double(i)/Double(project.traceSamples-1)))
        }
        var collisions = [VirtualPoseCollision]()
        for fraction in project.collisionFractions.sorted() {
            try control.check();let seconds = replay.durationSeconds*fraction,snapshot = try replay.snapshot(at:seconds)
            let scene = try VirtualMachineSceneBuilder.build(configuration:project.scene,project:project.cell,artifact:cell,snapshot:snapshot)
            let request = try scene.queryRequest(clearanceMM:project.scene.clearanceMM)
            let result = try NativeManufacturingEngine().machineQuery(request,control:.init(parent:control))
            collisions.append(.init(fraction:fraction,seconds:seconds,requestSHA256:try ResearchArchive.digest(request),result:result,
                verdict:Self.verdict(result,scene:scene,snapshot:snapshot)))
        }
        _ = control.report(0.85,"virtual-scene")
        var drives = [VirtualDriveArtifact]()
        for item in project.drives {
            try control.check();drives.append(.init(id:item.id,spindleID:item.spindleID,result:try SpindleDriveSolver.solve(item.request,control:control)))
        }
        var usage = rusage();getrusage(RUSAGE_SELF,&usage)
        let output = VirtualMachineArtifact(projectID:project.id,inputSHA256:inputSHA,cellArtifact:cell,trace:trace,collisions:collisions,drives:drives,
            elapsedSeconds:Date().timeIntervalSince(start),processPeakBytes:UInt64(max(0,usage.ru_maxrss)),
            warnings:["Virtual commanded replay and lumped spindle-drive dynamics are separate calculations.",
                      "Collision checks cover only the configured bodies at the stored snapshot times; continuous sweep and omitted machine components remain uncovered.",
                      "Stock uses raw retained stage meshes; display smoothing never changes collision, archives or export.",
                      "No automatic general machine IK, servo feedback, bearing/thermal prediction or machine-specific controller output is generated."])
        try control.check();try output.validate(for:project)
        guard try ManufacturingStudy.encoder.encode(output).count<=project.maxRetainedBytes else { throw ManufacturingError.native("virtual machine result byte budget") }
        _ = control.report(1,"complete");return output
    }
    public static func verdict(_ result:MachineQueryResult,scene:VirtualScene,snapshot:VirtualCellSnapshot)->VirtualPoseCollision.Verdict {
        guard !result.pairs.isEmpty else { return .uncovered }
        var unresolved = snapshot.spindles.contains { !$0.phaseKnown }
        for pair in result.pairs {
            let envelope = scene.bodies.contains { ($0.id == pair.a || $0.id == pair.b) && $0.geometryClass == .outerEnvelope }
            if pair.state == "intersecting" {
                if envelope { unresolved = true } else if !snapshot.spindles.contains(where:{ !$0.phaseKnown }) { return .interference }
            }
            if !["clear","intersecting"].contains(pair.state) { unresolved = true }
        }
        return unresolved ? .unresolved : .clear
    }
}
public actor VirtualMachineService {
    public init() {}
    public func calculate(_ project:VirtualMachineProject,reusing cellArtifact:CellSimulationArtifact? = nil,
                          progress:@escaping @Sendable(Double,String)->Void = { _,_ in }) async throws -> VirtualMachineArtifact {
        let control = ComputationControl(progress:progress)
        return try await withTaskCancellationHandler {
            let value = try await Task.detached(priority:.userInitiated) { try VirtualMachineEngine().compute(project,reusing:cellArtifact,control:control) }.value
            try control.check();try Task.checkCancellation();return value
        } onCancel:{ control.cancel() }
    }
}
public enum VirtualMachineArchive {
    public static func save(project:VirtualMachineProject,artifact:VirtualMachineArtifact,to url:URL) throws {
        try ResearchArchive.save(input:project,output:artifact,family:.virtualMachine,to:url) { try $1.validate(for:$0) }
    }
    public static func open(_ url:URL) throws -> (VirtualMachineProject,VirtualMachineArtifact) {
        try ResearchArchive.open(url,input:VirtualMachineProject.self,output:VirtualMachineArtifact.self,family:.virtualMachine) { try $1.validate(for:$0) }
    }
}
