import Foundation
import Darwin
import FloeNCProgram
import FloeManufacturingCore
import FloeManufacturingNC

enum R9Qualify {
    static func run(_ directory:URL,sourceFile:URL? = nil) throws {
        let started=ProcessInfo.processInfo.systemUptime
        var cases=[("smooth",try NCSamples.smooth()),("turning",try NCCodec.decode(NCSamples.turning))]
        if let sourceFile {
            guard try sourceFile.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max <= 4_000_000 else { throw NCError("Input byte budget exceeded") }
            let data=try Data(contentsOf:sourceFile)
            guard data.count <= 4_000_000,let source=String(data:data,encoding:.utf8) else { throw NCError("Expected UTF-8 input") }
            cases=[("imported",try NCCodec.decode(source))]
        }
        var records=[[String:Any]]()
        for (name,program) in cases {
            let source=NCCodec.encode(program)
            let report=try NCVerification.roundTrip(program)
            let paths=try NCGeometry.sample(program)
            try Data(source.utf8).write(to:directory.appendingPathComponent(name+".nc"),options:.atomic)
            try NCArchive.encoder.encode(program).write(to:directory.appendingPathComponent(name+"-analytic.json"),options:.atomic)
            try NCArchive.encoder.encode(paths).write(to:directory.appendingPathComponent(name+"-preview.json"),options:.atomic)
            try NCArchive.encoder.encode(report).write(to:directory.appendingPathComponent(name+"-roundtrip.json"),options:.atomic)
            let archive=directory.appendingPathComponent(name+".floenc")
            try NCArchive.save(source:source,configuration:program.configuration,to:archive)
            let reopened=try NCArchive.open(archive)
            guard reopened.source == source,try NCVerification.roundTrip(reopened.program).passed else { throw NCError("Saved source reopen mismatch") }
            records.append(["case":name,"motions":report.motions,"events":report.events,"points":report.sampledPoints,
                "canonicalSHA256":report.canonicalSHA256,"maximumSampleDeviationMM":report.maximumSampleDeviationMM,"archiveReopen":true,
                "unresolvedAxes":program.finalPosition.unresolvedAxes])
        }
        var failures=[[String:Any]]()
        if sourceFile == nil {
            for (name,study) in [("cam-block",ManufacturingStudy.featureCAM()),("cam-turning",ManufacturingStudy.cuttingSpeedExample())] {
                let artifact=try NativeManufacturingEngine().compute(study,control:.init())
                var options=ManufacturingNCOptions();options.turningDiameterProgramming=true
                let output=try ManufacturingNCPost.generate(study:study,artifact:artifact,options:options)
                try Data(output.source.utf8).write(to:directory.appendingPathComponent(name+".nc"),options:.atomic)
                try NCArchive.encoder.encode(output.receipt).write(to:directory.appendingPathComponent(name+"-post.json"),options:.atomic)
                try NCArchive.encoder.encode(try NCGeometry.sample(output.program)).write(to:directory.appendingPathComponent(name+"-preview.json"),options:.atomic)
                try NCArchive.save(source:output.source,configuration:output.program.configuration,to:directory.appendingPathComponent(name+".floenc"))
                try ManufacturingArchive.save(study:study,artifact:artifact,to:directory.appendingPathComponent(name+".floemanufacturing"))
                records.append(["case":name,"sourceInputSHA256":artifact.inputSHA256,"sourcePaths":output.receipt.sourcePaths.count,
                    "recordedAddedMoves":output.receipt.addedMoves.count,"points":output.receipt.roundTrip.sampledPoints,
                    "canonicalSHA256":output.receipt.canonicalSHA256,"roundTrip":output.receipt.roundTrip.passed,
                    "operationsUsingFallbackRPM":output.receipt.operationsUsingFallbackRPM])
            }
        }
        for (name,source) in [("ambiguous-r-circle","G21\nG0 X1 Y0\nG2 R1 F10"),("unsupported-cycle","G21\nG81 X0 Z-5 R1 F10"),("radius-mismatch","G21\nG0 X1 Y0\nG2 X2 I-1 J0 F10")] {
            do { _ = try NCCodec.decode(source);throw NCError("Expected rejection did not occur: "+name) }
            catch let error as NCError {
                guard error.line > 0 else { throw error }
                failures.append(["case":name,"source":source,"line":error.line,"reason":error.message])
            }
        }
        var usage=rusage();getrusage(RUSAGE_SELF,&usage)
        let summary:[String:Any]=["profile":NCCodec.profile,"cases":records,"expectedFailures":failures,
            "elapsedSeconds":ProcessInfo.processInfo.systemUptime-started,"processPeakBytes":usage.ru_maxrss,
            "scope":"macOS component CLI; no physical-device, machine, stock-removal or industrial acceptance"]
        let data=try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:directory.appendingPathComponent("NC_RESULTS.json"),options:.atomic)
        print(String(decoding:data,as:UTF8.self))
    }
}
