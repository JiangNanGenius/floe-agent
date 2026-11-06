import Foundation
import FloeManufacturingCore
import FloeManufacturingParameters
import FloeEngineeringCore

enum R5Qualify {
    static func run(_ directory:URL) throws {
        var records = [[String:Any]]()
        let project = ManufacturingCellProject.demonstration()
        let artifact = try CellManufacturingEngine().compute(project)
        let archive = directory.appendingPathComponent("dual-spindle.floecell")
        try ManufacturingCellArchive.save(project:project,artifact:artifact,to:archive)
        let (reopenedInput,reopenedResult) = try ManufacturingCellArchive.open(archive)
        guard try ResearchArchive.digest(reopenedInput) == ResearchArchive.digest(project),
              try ResearchArchive.digest(reopenedResult) == ResearchArchive.digest(artifact) else { throw ManufacturingError.archive("cell reopen mismatch") }
        try ResearchArchive.saveInput(project,to:directory.appendingPathComponent("dual-spindle-input.json"))
        try ResearchArchive.saveInput(artifact,to:directory.appendingPathComponent("dual-spindle-result.json"))
        try ManufacturingCellArchive.neutralExport(artifact).write(to:directory.appendingPathComponent("cell-neutral.json"),options:.atomic)
        var partRows = [[String:Any]]()
        for (i,key) in artifact.finalStock.keys.sorted().enumerated() {
            guard let job = artifact.jobs.last(where:{ $0.workpieceID == key }) else { throw ManufacturingError.native("missing final workpiece job") }
            let file = String(format:"workpiece-%03d-local.stl",i+1)
            try ManufacturingArchive.stl(job.artifact.result).write(to:directory.appendingPathComponent(file),options:.atomic)
            partRows.append(["workpieceID":key,"stl":file,"coordinateFrame":"immutable-workpiece-local","remainingMM3":artifact.finalStock[key]!.remainingMM3])
        }
        records.append(["fixture":"dual-spindle","inputSHA256":artifact.inputSHA256,"jobs":artifact.jobs.count,
            "spindles":project.cell.spindles.count,"turrets":project.cell.turrets.count,"channels":project.cell.channels.count,
            "transfers":artifact.schedule.transfers.count,"nominalSeconds":artifact.schedule.totalSeconds,
            "elapsedSeconds":artifact.elapsedSeconds,"processPeakBytes":artifact.processPeakBytes,"workpieces":partRows,"saveReopen":true])

        let machineInput = MachineQueryRequest.midpointCollision(synchronized:true)
        let machine = try NativeManufacturingEngine().machineQuery(machineInput)
        guard machine.hasInterference else { throw ManufacturingError.native("midpoint interference was missed") }
        try ResearchArchive.saveInput(machineInput,to:directory.appendingPathComponent("machine-motion-input.json"))
        try ResearchArchive.saveInput(machine,to:directory.appendingPathComponent("machine-motion-result.json"))
        records.append(["fixture":"synchronized-machine-midpoint","samples":machine.poses.count,"parryCalls":machine.parryCalls,"interferenceFound":machine.hasInterference,"scope":machine.scope])

        for thermal in [false,true] {
            let input = EngineeringAnalysisProject.demonstration(thermal:thermal)
            let output = try EngineeringAnalysisEngine().compute(input)
            let name = thermal ? "steady-thermal" : "linear-static"
            let url = directory.appendingPathComponent(name+".floeanalysis")
            try EngineeringAnalysisArchive.save(project:input,artifact:output,to:url)
            let (savedInput,savedOutput) = try EngineeringAnalysisArchive.open(url)
            guard try ResearchArchive.digest(savedInput) == ResearchArchive.digest(input),
                  try ResearchArchive.digest(savedOutput) == ResearchArchive.digest(output) else { throw ManufacturingError.archive("engineering reopen mismatch") }
            try ResearchArchive.saveInput(input,to:directory.appendingPathComponent(name+"-input.json"))
            try ResearchArchive.saveInput(output,to:directory.appendingPathComponent(name+"-result.json"))
            var row:[String:Any] = ["fixture":name,"inputSHA256":output.inputSHA256,"elapsedSeconds":output.elapsedSeconds,"processPeakBytes":output.processPeakBytes,"saveReopen":true]
            switch output.result {
            case .structural(let result):row["maximumDisplacementMM"] = result.nodalDisplacementMM.map(\.magnitude).max();row["maximumVonMisesMPa"] = result.maxVonMisesMPa;row["relativeResidual"] = result.relativeResidual
            case .thermal(let result):row["minimumCelsius"] = result.minTemperatureCelsius;row["maximumCelsius"] = result.maxTemperatureCelsius;row["energyBalanceResidualW"] = result.energyBalanceResidualW;row["relativeResidual"] = result.relativeResidual
            }
            records.append(row)
        }
        var process = ManufacturingStudy.cuttingSpeedExample()
        process.processRequirements = .init(availableInputPowerKW:5,availableTorqueNM:20,maximumIdealCuspUM:3)
        let processResult = try NativeManufacturingEngine().compute(process,control:.init())
        try ResearchArchive.saveInput(process,to:directory.appendingPathComponent("process-assessment-input.json"))
        try ResearchArchive.saveInput(processResult,to:directory.appendingPathComponent("process-assessment-result.json"))
        let catalog = ManufacturingParameterCatalog.standard
        guard catalog.validate().isEmpty else { throw ManufacturingError.invalid("parameter catalog") }
        try ResearchArchive.saveInput(catalog,to:directory.appendingPathComponent("parameter-catalog.json"))
        records.append(["fixture":"parameters","groups":catalog.groups.count,"parameters":catalog.parameters.count,
            "rare":catalog.parameters.filter(\.rare).count,"runtimeBindings":catalog.parameters.filter { $0.support == .previewUsed }.count,
            "savedOnly":catalog.parameters.filter { $0.support == .configurationOnly }.count,"fixed":catalog.parameters.filter { $0.support == .fixed }.count,
            "unavailable":catalog.parameters.filter { $0.support == .notAvailable }.count])
        let report = try JSONSerialization.data(withJSONObject:["revision":"R5","checks":"bounded component demos; full functional verification waived","fullE38Accepted":false,"records":records],options:[.prettyPrinted,.sortedKeys])
        try report.write(to:directory.appendingPathComponent("RESULTS.json"),options:.atomic)
        print(String(decoding:report,as:UTF8.self))
    }
}
