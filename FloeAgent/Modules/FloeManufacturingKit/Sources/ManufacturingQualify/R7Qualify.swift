import Foundation
import Darwin
import FloeManufacturingCore

enum R7Qualify {
    static func run(_ directory:URL,sourceArchive:URL) throws {
        let started = Date(),source:CAMPreviewSource,state:Data?
        switch sourceArchive.pathExtension.lowercased() {
        case "floecell":let (input,result) = try ManufacturingCellArchive.open(sourceArchive);source = .cell(.init(cell:input),result);state = nil
        case "floetwin":let (input,result) = try VirtualMachineArchive.open(sourceArchive);source = .cell(input,result.cellArtifact);state = nil
        case "floemanufacturing":let (input,result) = try ManufacturingArchive.open(sourceArchive);source = .study(input,result);state = nil
        case "floepreview":let value = try CAMPreviewArchive.open(sourceArchive);source = value.source;state = value.viewState
        default:throw ManufacturingError.invalid("R7 requires an existing source-bound manufacturing archive")
        }
        let program = try CAMPreviewProgram(source:source),file = directory.appendingPathComponent("machining-preview.floepreview")
        try CAMPreviewArchive.save(source:source,viewState:state,to:file)
        let reopened = try CAMPreviewArchive.open(file),copy = try CAMPreviewProgram(source:reopened.source)
        guard program.sourceKey == copy.sourceKey,reopened.viewState == state else { throw ManufacturingError.archive("R7 preview reopen") }
        var rows = [[String:Any]](),csv = "position,metric,tool,X_mm,Y_mm,Z_mm,axis_X,axis_Y,axis_Z,feed_mm_min,rpm,A_degrees,C_degrees\n"
        var machineCSV = "position,machine,tool,X_mm,Y_mm,Z_mm,axis_X,axis_Y,axis_Z,A_degrees,C_degrees\n"
        func csvLine(_ fields:[String])->String { fields.map { "\""+$0.replacingOccurrences(of:"\"",with:"\"\"")+"\"" }.joined(separator:",")+"\n" }
        for i in 0...120 {
            let frame = try program.frame(at:program.extent*Double(i)/120)
            let check = try copy.frame(at:frame.position)
            guard frame.tools.map(\.tipMM) == check.tools.map(\.tipMM),frame.tools.map(\.axis) == check.tools.map(\.axis) else { throw ManufacturingError.archive("R7 pose reopen") }
            var row:[String:Any] = ["position":frame.position,"activeChapters":frame.activeChapterIDs,"bodies":frame.scene.bodies.count,
                "tools":frame.tools.map { ["id":$0.id,"tipMM":$0.tipMM,"axis":$0.axis,"pathID":$0.pathID,"rpm":$0.rpm as Any? ?? NSNull(),"joints":$0.joints as Any? ?? NSNull()] as [String:Any] }]
            if let machine = frame.machine {
                row["machine"] = ["kind":machine.kind.rawValue,"workpieceRotation":machine.worldFromWorkpiece.rotation,
                    "machineToolTipMM":machine.machineToolTipMM as Any? ?? NSNull(),"machineToolAxis":machine.machineToolAxis as Any? ?? NSNull(),"joints":machine.joints as Any? ?? NSNull()] as [String:Any]
            }
            rows.append(row)
            for tool in frame.tools {
                var values = [String(format:"%.17g",frame.position),program.metric.rawValue,tool.id]
                values += (tool.tipMM+tool.axis).map { String(format:"%.17g",$0) }
                values += [tool.feedMMPerMinute,tool.rpm,tool.joints.flatMap { $0.count == 5 ? $0[3] : nil },tool.joints.flatMap { $0.count == 5 ? $0[4] : nil }].map { $0.map { String(format:"%.17g",$0) } ?? "" }
                csv += csvLine(values)
                let machine = frame.machine,tip = machine?.machineToolTipMM ?? tool.tipMM,axis = machine?.machineToolAxis ?? tool.axis
                var physical = [String(format:"%.17g",frame.position),machine?.kind.rawValue ?? "cell",tool.id]
                physical += (tip+axis).map { String(format:"%.17g",$0) }
                physical += [machine?.joints.flatMap { $0.count==5 ? $0[3]:nil },machine?.joints.flatMap { $0.count==5 ? $0[4]:nil }].map { $0.map { String(format:"%.17g",$0) } ?? "" }
                machineCSV += csvLine(physical)
            }
        }
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("pose-samples.json"),options:.atomic)
        try Data(csv.utf8).write(to:directory.appendingPathComponent("tcp-replay.csv"),options:.atomic)
        try Data(machineCSV.utf8).write(to:directory.appendingPathComponent("machine-replay.csv"),options:.atomic)
        let chapters = program.chapters.map { ["id":$0.id,"name":$0.name,"start":$0.start as Any? ?? NSNull(),"end":$0.end as Any? ?? NSNull(),"pathCount":$0.pathIDs.count] as [String:Any] }
        try JSONSerialization.data(withJSONObject:chapters,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("operations.json"),options:.atomic)
        var usage = rusage();getrusage(RUSAGE_SELF,&usage)
        let report:[String:Any] = ["revision":"R7","name":program.name,"sourceKey":program.sourceKey,"sourceArchiveSHA256":ManufacturingStudy.digest(try Data(contentsOf:sourceArchive)),
            "reusedExistingCAM":true,"metric":program.metric.rawValue,"extent":program.extent,"chapters":program.chapters.count,"paths":program.paths.count,"samples":rows.count,
            "saveReopen":true,"viewStatePreserved":reopened.viewState == state,"elapsedSeconds":Date().timeIntervalSince(started),"processPeakBytes":UInt64(max(0,usage.ru_maxrss)),
            "warnings":program.warnings,"scope":"actual supplied TCP paths and commanded virtual spindle/tool poses; head outline schematic; retained-stage stock; no new CAM recompute or continuous machine-safety proof",
            "fullE38CodeClosed":false,"fullE38Accepted":false]
        let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);try data.write(to:directory.appendingPathComponent("RESULTS.json"),options:.atomic)
        print(String(decoding:data,as:UTF8.self))
    }
}
