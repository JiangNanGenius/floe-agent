import Foundation
import FloeManufacturingCore
import FloeManufacturingParameters

@main struct Qualify {
    static func main() async throws {
        guard (2...4).contains(CommandLine.arguments.count), CommandLine.arguments[1].hasPrefix("/") else {
            throw ManufacturingError.invalid("usage: manufacturing-qualify /absolute/output [--r7 source-archive | --r6 [cell-archive] | --r5 | --parameters-only | --assembly-r2 | --cutting-r3 | --cam-r4 | existing-input-directory | --reopen-archives archive-directory]")
        }
        let directory = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        if CommandLine.arguments.count >= 3,CommandLine.arguments[2] == "--nc" {
            try R9Qualify.run(directory,sourceFile:CommandLine.arguments.count == 4 ? URL(fileURLWithPath:CommandLine.arguments[3]) : nil);return
        }
        if CommandLine.arguments.count == 4,CommandLine.arguments[2] == "--r7" {
            try R7Qualify.run(directory,sourceArchive:URL(fileURLWithPath:CommandLine.arguments[3]));return
        }
        if CommandLine.arguments.count >= 3,CommandLine.arguments[2] == "--r6" {
            try R6Qualify.run(directory,reusingArchive:CommandLine.arguments.count == 4 ? URL(fileURLWithPath:CommandLine.arguments[3]) : nil);return
        }
        if CommandLine.arguments.count == 3,CommandLine.arguments[2] == "--r5" { try R5Qualify.run(directory);return }
        if CommandLine.arguments.count == 3, CommandLine.arguments[2] == "--parameters-only" {
            try parameterDemo(directory); return
        }
        if CommandLine.arguments.count == 4, CommandLine.arguments[2] == "--reopen-archives" {
            var records = [[String:Any]]()
            let inputDirectory = URL(fileURLWithPath:CommandLine.arguments[3],isDirectory:true)
            let archives = try FileManager.default.contentsOfDirectory(at:inputDirectory,includingPropertiesForKeys:nil).filter { $0.pathExtension == "floemanufacturing" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !archives.isEmpty && archives.count <= 16 else { throw ManufacturingError.invalid("archive selection budget") }
            for url in archives {
                let (study,artifact) = try ManufacturingArchive.open(url)
                records.append(["file":url.lastPathComponent,"inputSHA256":artifact.inputSHA256,"assemblyAbsent":study.millingAssembly == nil,"triangles":artifact.result.triangles.count,"archiveSHA256":ManufacturingStudy.digest(try Data(contentsOf:url))])
            }
            let data = try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys])
            try data.write(to:directory.appendingPathComponent("LEGACY_REOPEN.json"),options:.atomic)
            print(String(decoding:data,as:UTF8.self)); return
        }
        guard CommandLine.arguments.count <= 3 else { throw ManufacturingError.invalid("unrecognized qualification mode") }
        let service = ManufacturingService()
        var records = [[String:Any]]()
        let assemblyMode = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--assembly-r2"
        let cuttingMode = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--cutting-r3"
        let camMode = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--cam-r4"
        var samples = [("shaft",ManufacturingStudy.shaft()),("turnmill",.shaft(milled:true)),("fiveaxis",.fiveAxis())]
        if assemblyMode {
            var short = ManufacturingStudy.shaft(milled:true)
            short.milling.toolLengthMM = 0.5; short.millingAssembly = .demonstration(cuttingLengthMM:0.5)
            var ac = ManufacturingStudy.fiveAxis(); ac.millingAssembly = .demonstration(cuttingLengthMM:ac.milling.toolLengthMM)
            samples = [("holder-interference",.holderInterference()),("short-shank",short),("ac-assembly",ac)]
        }
        if cuttingMode {
            let css = ManufacturingStudy.cuttingSpeedExample()
            var fixed = css
            fixed.turningCutting?.spindleMode = .fixedRPM
            fixed.turningCutting?.spindleRPM = 900
            var mixed = css
            mixed.milling.enabled = true
            samples = [("css",css),("fixed-rpm",fixed),("timed-turnmill",mixed)]
        }
        if camMode { samples = [("turnmill-cam",.turnMillCAM()),("feature-cam",.featureCAM()),("surface-cam",.surfaceCAM()),("selected-turning",.selectedTurning())] }
        for (name,sample) in samples {
            let study: ManufacturingStudy
            if CommandLine.arguments.count == 3 && !assemblyMode && !cuttingMode && !camMode {
                let input = URL(fileURLWithPath:CommandLine.arguments[2]).appendingPathComponent(name+"-input.json")
                study = try JSONDecoder().decode(ManufacturingStudy.self,from:Data(contentsOf:input))
            } else { study = sample }
            let artifact = try await service.calculate(study)
            let archive = directory.appendingPathComponent("\(name).floemanufacturing")
            try ManufacturingArchive.save(study:study,artifact:artifact,to:archive)
            let (_,reopened) = try ManufacturingArchive.open(archive)
            guard reopened == artifact else { throw ManufacturingError.archive("reopen mismatch") }
            try ManufacturingArchive.stl(artifact.result).write(to:directory.appendingPathComponent("\(name).stl"),options:.atomic)
            try ManufacturingArchive.toolpath(artifact.result).write(to:directory.appendingPathComponent("\(name)-toolpath.json"),options:.atomic)
            try ManufacturingStudy.encoder.encode(artifact.result).write(to:directory.appendingPathComponent("\(name)-result.json"),options:.atomic)
            try study.encoded().write(to:directory.appendingPathComponent("\(name)-input.json"),options:.atomic)
            var record: [String:Any] = ["fixture":name,"inputSHA256":artifact.inputSHA256,"initialMM3":artifact.result.initialMM3,"remainingMM3":artifact.result.remainingMM3,"removedMM3":artifact.result.removedMM3,"triangles":artifact.result.triangles.count,"paths":artifact.result.paths.count,"frames":artifact.result.frames?.count ?? 0,"elapsedSeconds":artifact.elapsedSeconds,"processPeakBytes":artifact.processPeakBytes,"backend":artifact.result.backend,"collisions":artifact.result.collisions.map { ["component":$0.component,"state":$0.state] },"assemblyQueryCount":artifact.result.assemblyQueryCount ?? 0,"nominalCuttingSeconds":artifact.result.cuttingTimeline?.totalSeconds ?? 0,"timedSegments":artifact.result.cuttingTimeline?.segments.count ?? 0,"warnings":artifact.result.warnings]
            if let reports = artifact.result.camReport {
                record["camReport"] = try JSONSerialization.jsonObject(with:ManufacturingStudy.encoder.encode(reports))
                record["sampledCamPoses"] = artifact.result.sampledCamPoses ?? 0
            }
            if let receipt = artifact.result.turningSetupReceipt {
                record["turningSetupReceipt"] = try JSONSerialization.jsonObject(with:ManufacturingStudy.encoder.encode(receipt))
            }
            if let timeline = artifact.result.cuttingTimeline {
                record["timeSamples"] = try [0.0,0.25,0.5,0.75,1.0].map { fraction -> [String:Any] in
                    let sample = try timeline.sample(atSeconds:fraction*timeline.totalSeconds)
                    return ["fraction":fraction,"pointMM":sample.pointMM,"pathIndex":sample.pathIndex,
                            "feedMMPerMinute":sample.feedMMPerMinute,"rpm":sample.rpm.map { $0 as Any } ?? NSNull()]
                }
            }
            records.append(record)
        }
        let data = try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:directory.appendingPathComponent("RESULTS.json"),options:.atomic)
        print(String(decoding:data,as:UTF8.self))
    }
    private static func parameterDemo(_ directory:URL) throws {
        let catalog = ManufacturingParameterCatalog.standard
        guard catalog.validate().isEmpty else { throw ManufacturingError.invalid("catalog consistency") }
        var parameters = ManufacturingParameterSet()
        if let rare = catalog.parameters.first(where:{ $0.rare && $0.support == .configurationOnly && $0.kind == .string }) {
            parameters.set(rare.id,.string("Prototype process note; replace with actual tool data"))
        }
        parameters.set("vendor.extension.example",.object(["preserved":.array([.integer(0),.number(0),.null,.boolean(false)])]))
        let study = try ManufacturingStudy.shaft(milled:true).applyingParameters(parameters)
        let data = try study.encoded()
        guard try JSONDecoder().decode(ManufacturingStudy.self,from:data) == study else { throw ManufacturingError.archive("parameter demo round-trip") }
        try data.write(to:directory.appendingPathComponent("process-sheet.json"),options:.atomic)
        let preset = ManufacturingParameterPreset(name:"Research settings; not machining recommendations",values:study.parameterSnapshot().values)
        try ManufacturingStudy.encoder.encode(preset).write(to:directory.appendingPathComponent("parameters.json"),options:.atomic)
        try ManufacturingStudy.encoder.encode(catalog).write(to:directory.appendingPathComponent("parameter-catalog.json"),options:.atomic)
        let report:[String:Any] = ["groups":catalog.groups.count,"parameters":catalog.parameters.count,"rare":catalog.parameters.filter(\.rare).count,"bound":catalog.parameters.filter { $0.support == .previewUsed }.count,"configurationOnly":catalog.parameters.filter { $0.support == .configurationOnly }.count,"future":catalog.parameters.filter { $0.support == .notAvailable }.count,"fixed":catalog.parameters.filter { $0.support == .fixed }.count,"roundTrip":true,"demoInputSHA256":try study.fingerprint()]
        let summary = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        try summary.write(to:directory.appendingPathComponent("PARAMETERS.json"),options:.atomic)
        print(String(decoding:summary,as:UTF8.self))
    }
}
