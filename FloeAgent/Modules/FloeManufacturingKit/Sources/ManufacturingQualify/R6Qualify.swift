import Foundation
import FloeManufacturingCore

enum R6Qualify {
    static func run(_ directory:URL,reusingArchive:URL?) throws {
        let project:VirtualMachineProject,reused:CellSimulationArtifact?
        if let reusingArchive {
            let (input,output) = try ManufacturingCellArchive.open(reusingArchive)
            var value = VirtualMachineProject(cell:input)
            if let spindle = input.cell.spindles.first {
                var drive = SpindleDriveRequest.demonstration();drive.configuration.maxRPM = spindle.maxRPM;drive.targetRPM = min(1500,spindle.maxRPM)
                value.drives = [.init(id:"drive-example",spindleID:spindle.id,request:drive)]
            }
            project = value;reused = output
        } else { project = .demonstration();reused = nil }
        let artifact = try VirtualMachineEngine().compute(project,reusing:reused)
        let archive = directory.appendingPathComponent("virtual-spindles.floetwin")
        try VirtualMachineArchive.save(project:project,artifact:artifact,to:archive)
        let (input,output) = try VirtualMachineArchive.open(archive)
        guard try ResearchArchive.digest(input) == ResearchArchive.digest(project),
              try ResearchArchive.digest(output) == ResearchArchive.digest(artifact) else { throw ManufacturingError.archive("virtual machine reopen") }
        try ResearchArchive.saveInput(project,to:directory.appendingPathComponent("virtual-machine-input.json"))
        try ResearchArchive.saveInput(artifact,to:directory.appendingPathComponent("virtual-machine-result.json"))
        let replay = try VirtualCellReplay(project:project.cell,artifact:artifact.cellArtifact)
        var samples = [VirtualCellSnapshot]()
        for transfer in artifact.cellArtifact.schedule.transfers {
            for t in [transfer.acquireSeconds-1e-6,transfer.acquireSeconds,transfer.releaseSeconds-1e-6,transfer.releaseSeconds,
                      artifact.cellArtifact.schedule.steps.first(where:{ $0.stepID == transfer.stepID })!.endSeconds] {
                samples.append(try replay.snapshot(at:max(0,t)))
            }
        }
        try ResearchArchive.saveInput(samples,to:directory.appendingPathComponent("handoff-pose-samples.json"))
        let final = try replay.snapshot(at:replay.durationSeconds)
        let scene = try VirtualMachineSceneBuilder.build(configuration:project.scene,project:project.cell,artifact:artifact.cellArtifact,snapshot:final)
        try ResearchArchive.saveInput(scene,to:directory.appendingPathComponent("final-virtual-scene.json"))
        for (i,drive) in artifact.drives.enumerated() {
            var csv = "seconds,rpm,unwrapped_phase_degrees,drive_torque_Nm,mechanical_power_kW\n"
            for point in drive.result.samples { csv += [point.seconds,point.rpm,point.unwrappedPhaseDegrees,point.driveTorqueNM,point.mechanicalPowerKW].map { String(format:"%.17g",$0) }.joined(separator:",")+"\n" }
            try Data(csv.utf8).write(to:directory.appendingPathComponent("drive-\(i+1).csv"),options:.atomic)
        }
        let report:[String:Any] = ["revision":"R6","inputSHA256":artifact.inputSHA256,"reusedCellArtifact":reused != nil,
            "cellInputSHA256":artifact.cellArtifact.inputSHA256,"nominalSeconds":replay.durationSeconds,
            "traceSamples":artifact.trace.count,"finalVirtualBodies":scene.bodies.count,"saveReopen":true,
            "snapshotQueries":artifact.collisions.map { ["seconds":$0.seconds,"verdict":$0.verdict.rawValue,"pairs":$0.result.pairs.count,"parryCalls":$0.result.parryCalls] as [String:Any] },
            "drives":artifact.drives.map { ["id":$0.id,"spindleID":$0.spindleID,"termination":$0.result.termination.rawValue,
                "elapsedSeconds":$0.result.elapsedSeconds,"finalRPM":$0.result.finalRPM,"unwrappedPhaseDegrees":$0.result.finalPhaseDegrees,
                "energyBalanceResidualJ":$0.result.energyBalanceResidualJ,"electricalInputJ":$0.result.electricalInputJ] as [String:Any] },
            "elapsedSeconds":artifact.elapsedSeconds,"processPeakBytes":artifact.processPeakBytes,
            "scope":"configured virtual geometry + nominal commanded replay; separate approximate lumped drive; static pose collisions only",
            "fullE38CodeClosed":false,"fullE38Accepted":false]
        let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:directory.appendingPathComponent("RESULTS.json"),options:.atomic);print(String(decoding:data,as:UTF8.self))
    }
}
