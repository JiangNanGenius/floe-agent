// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeManufacturingCore
import FloeNCProgram

public struct ManufacturingNCOptions:Codable,Equatable,Sendable {
    /// Explicit research post settings; never inferred from inactive process fields.
    public var fallbackSpindleRPM=1200.0
    public var connectionFeedMMPerMinute=80.0
    public var extraClearanceMM=0.0
    public var turningDiameterProgramming=false
    public var floodCoolant=false
    public var toolNumbers=[String:Int]()
    public init() {}
}
public struct ManufacturingNCReceipt:Codable,Sendable {
    public struct Tool:Codable,Sendable { public let sourceID:String;public let number:Int;public let name:String }
    public struct SourcePath:Codable,Sendable {
        public let index:Int
        public let kind:String
        public let pointCount:Int
        public let firstLine,lastLine:Int
    }
    public struct AddedMove:Codable,Sendable { public let line:Int;public let kind:String }
    public let sourceStudyID:UUID
    public let sourceInputSHA256:String
    public let canonicalSHA256:String
    public let options:ManufacturingNCOptions
    public let tools:[Tool]
    public let sourcePaths:[SourcePath]
    public let addedMoves:[AddedMove]
    public let operationsUsingFallbackRPM:[String]
    public let roundTrip:NCRoundTripReport
    public let limits:[String]
}
public struct ManufacturingNCOutput:Sendable {
    public let source:String
    public let program:NCProgram
    public let receipt:ManufacturingNCReceipt
}

/// Generic single-spindle post for fixed +Z three-axis milling OR X/Z turning.
/// It emits and records every added connection. It is not a machine postprocessor.
public enum ManufacturingNCPost {
    public static func generate(study:ManufacturingStudy,artifact:ManufacturingArtifact,
                                options:ManufacturingNCOptions = .init(),cancellation:NCCancellation? = nil) throws -> ManufacturingNCOutput {
        try study.validate();try cancellation?.check()
        guard artifact.studyID == study.id,artifact.inputSHA256 == (try study.fingerprint()),artifact.startingStockSHA256 == nil else { throw NCError("Stale or continued-job result; use the matching standalone study") }
        try artifact.result.validate(for:study)
        guard study.acMotion == nil else { throw NCError("A/C output requires a machine axis/offset post mapping") }
        guard options.fallbackSpindleRPM.isFinite,(1...100000).contains(options.fallbackSpindleRPM),
              options.connectionFeedMMPerMinute.isFinite,(0.000001...1000000).contains(options.connectionFeedMMPerMinute),
              options.extraClearanceMM.isFinite,(0...10000).contains(options.extraClearanceMM),
              options.toolNumbers.count <= 256,options.toolNumbers.values.allSatisfy({ (1...9999).contains($0) }),
              Set(options.toolNumbers.values).count == options.toolNumbers.count else { throw NCError("Invalid post settings/tool number mapping") }
        let paths=artifact.result.paths
        guard !paths.isEmpty,paths.count <= 12000,paths.reduce(0,{ $0+$1.points.count }) <= 50000 else { throw NCError("Path/point count budget exceeded or empty result") }
        let turning=paths.allSatisfy { $0.kind.hasPrefix("turning-") }
        guard turning || paths.allSatisfy({ $0.kind.hasPrefix("cam-") }) else { throw NCError("Mixed turn-mill, legacy live-tool, transfer or channel output needs explicit spindle/C-axis/tool-change post mapping") }
        for path in paths {
            try cancellation?.check()
            guard !path.points.isEmpty,path.points.allSatisfy({ $0.count == 3 && $0.allSatisfy { $0.isFinite && abs($0) <= 1000000 } }),
                  path.joints == nil else { throw NCError("Missing points or unmapped rotary joints") }
            if turning {
                guard path.points.allSatisfy({ abs($0[1]) < 1e-9 && $0[0] >= 0 }) else { throw NCError("Turning post requires nonnegative radial X and Y=0") }
            } else {
                guard let axes=path.toolAxes,axes.count == path.points.count,
                      axes.allSatisfy({ $0.count == 3 && abs($0[0]) < 1e-9 && abs($0[1]) < 1e-9 && abs($0[2]-1) < 1e-9 }) else { throw NCError("Only fixed +Z milling has a generic mapping; indexed/five-axis tools need a machine post") }
            }
        }
        func n(_ value:Double)->String { NCFormat.number(value) }
        func point(_ p:[Double])->NCVector { .init(p[0],p[1],p[2]) }
        func xyz(_ p:NCVector)->String { "X\(n(p.x*(turning && options.turningDiameterProgramming ? 2 : 1))) Y\(n(p.y)) Z\(n(p.z))" }
        var lines=[String](),added=[ManufacturingNCReceipt.AddedMove](),receipts=[ManufacturingNCReceipt.SourcePath]()
        func emit(_ text:String,_ kind:String? = nil) throws {
            try cancellation?.check()
            guard lines.count < 50000 else { throw NCError("Post block budget exceeded") }
            lines.append(text)
            if let kind { added.append(.init(line:lines.count,kind:kind)) }
        }
        let maxZ=paths.flatMap(\.points).map { $0[2] }.max() ?? 0
        let maxX=paths.flatMap(\.points).map { $0[0] }.max() ?? 0
        let clearance=turning ? study.configuredTurningSetup.clearanceMM : (study.cam?.enabledOperations.map(\.clearanceMM).max() ?? 0)
        let safeZ=max(maxZ,study.stock.bounds.max[2]+clearance)+options.extraClearanceMM
        let safeX=max(maxX,study.stock.radiusMM+clearance)+options.extraClearanceMM
        var current:NCVector?,currentTool:String?,tools=[ManufacturingNCReceipt.Tool](),fallback=Set<String>()
        func retract() throws {
            guard var p=current else { return }
            if turning { if p.x != safeX { p.x=safeX;try emit("G0 "+xyz(p),"radial-retract");current=p } }
            else if p.z != safeZ { p.z=safeZ;try emit("G0 "+xyz(p),"clearance-retract");current=p }
        }
        try emit("G21 G90 G91.1 G54 G40 G49 G61 G94 G\(turning ? 18 : 17) G\(turning && options.turningDiameterProgramming ? 7 : 8)")
        try emit("M5 M9")
        for (index,path) in paths.enumerated() {
            try cancellation?.check()
            let sourceID=turning ? (study.turningToolID ?? "turning-default") : path.toolID!
            let operationID=path.operationID ?? path.kind
            let operation=study.cam?.operations.first { $0.id == path.operationID }
            let rpm=turning ? study.turningCutting?.spindleRPM : operation?.cutting?.toolSpindleRPM
            if rpm == nil { fallback.insert(operationID) }
            if currentTool != sourceID {
                try retract();try emit("M5 M9")
                var number=options.toolNumbers[sourceID] ?? 1
                if options.toolNumbers[sourceID] == nil {
                    let occupied=Set(options.toolNumbers.values).union(tools.map(\.number))
                    while occupied.contains(number) { number += 1 }
                }
                let name=turning ? "Turning insert" : (study.cam?.tools.first { $0.id == sourceID }?.name ?? sourceID)
                if !tools.contains(where:{ $0.sourceID == sourceID }) { tools.append(.init(sourceID:sourceID,number:number,name:name)) }
                let mapped=tools.first { $0.sourceID == sourceID }!.number
                try emit("T\(mapped) M6");currentTool=sourceID
            }
            if turning,let cutting=study.turningCutting {
                if cutting.spindleMode == .constantSurfaceSpeed { try emit("G96 D\(n(cutting.maxSpindleRPM)) S\(n(cutting.surfaceSpeedMPerMinute)) M3") }
                else { try emit("G97 S\(n(min(cutting.spindleRPM,cutting.maxSpindleRPM))) M3") }
                try emit(cutting.feedMode == .mmPerRevolution ? "G95 F\(n(cutting.feedMMPerRevolution))" : "G94")
            } else { try emit("G94 G97 S\(n(rpm ?? options.fallbackSpindleRPM)) M3") }
            if options.floodCoolant { try emit("M8") }
            let first=point(path.points[0])
            if current == nil {
                current=turning ? NCVector(safeX,0,safeZ) : NCVector(first.x,first.y,safeZ)
                try emit("G0 "+xyz(current!),"initial-position-unknown-start")
            }
            if current != first {
                try retract()
                var approach=turning ? NCVector(safeX,0,first.z) : NCVector(first.x,first.y,safeZ)
                if current != approach { try emit("G0 "+xyz(approach),"clearance-link");current=approach }
                if approach != first {
                    // Added approach is an explicit feed motion, never a hidden rapid through stock.
                    let perRev=turning && study.turningCutting?.feedMode == .mmPerRevolution
                    let feed=perRev ? study.turningCutting!.feedMMPerRevolution : options.connectionFeedMMPerMinute
                    try emit("G1 "+xyz(first)+" F\(n(feed))","feed-approach");approach=first;current=first
                }
            }
            let firstLine=lines.count+1
            if path.moveType == "dwell" {
                guard let seconds=path.dwellSeconds,seconds > 0 else { throw NCError("Missing dwell duration") }
                try emit("G4 P\(n(seconds))")
            } else {
                guard path.points.count >= 2 else { throw NCError("Motion has fewer than two source points") }
                let rapid=["rapid","retract"].contains(path.moveType ?? "")
                let perRev=turning && study.turningCutting?.feedMode == .mmPerRevolution
                let feed=perRev ? study.turningCutting!.feedMMPerRevolution : path.feedMMPerMinute
                guard rapid || (feed?.isFinite == true && feed! > 0) else { throw NCError("Path \(index) has no active feed law") }
                for p in path.points.dropFirst() {
                    try emit((rapid ? "G0 " : "G1 ")+xyz(point(p))+(rapid ? "" : " F\(n(feed!))"));current=point(p)
                }
            }
            receipts.append(.init(index:index,kind:path.kind,pointCount:path.points.count,firstLine:firstLine,lastLine:lines.count))
        }
        try retract();try emit("M5 M9");try emit("M2")
        let text=lines.joined(separator:"\n")+"\n"
        let program=try NCCodec.decode(text,cancellation:cancellation)
        let motionByLine=Dictionary(uniqueKeysWithValues:program.motions.map { ($0.line,$0) })
        // Verify each original polyline segment after decoding; added links have separate receipts.
        for receipt in receipts {
            let original=paths[receipt.index]
            if original.moveType == "dwell" {
                guard program.events.contains(where:{ $0.line == receipt.firstLine && $0.kind == "dwell" && $0.value == original.dwellSeconds }) else { throw NCError("Post dwell readback mismatch") };continue
            }
            let readback=(receipt.firstLine...receipt.lastLine).compactMap { motionByLine[$0] }
            guard readback.count == original.points.count-1 else { throw NCError("Source segment count changed during post") }
            for (i,motion) in readback.enumerated() {
                let a=point(original.points[i]),b=point(original.points[i+1])
                guard (motion.start.displayPoint-a).length <= 1e-8,(motion.end.displayPoint-b).length <= 1e-8 else { throw NCError("Post changed source path coordinates") }
            }
        }
        let report=try NCVerification.roundTrip(program,cancellation:cancellation)
        let receipt=ManufacturingNCReceipt(sourceStudyID:study.id,sourceInputSHA256:artifact.inputSHA256,canonicalSHA256:report.canonicalSHA256,
            options:options,tools:tools,sourcePaths:receipts,addedMoves:added,operationsUsingFallbackRPM:fallback.sorted(),roundTrip:report,
            limits:["Generic work-coordinate program; controller tool offsets, turret codes, initial traverse and machine post mapping require setup.",
                    "Added clearance/approach links are visible and recorded, but have no continuous machine/fixture/tool-body collision certificate.",
                    "G0 speed belongs to the machine; source rapid speeds are not encoded as a verified machine time law.",
                    "Source polylines and true corners remain linear; no arc fitting or corner rounding is inferred.",
                    "Fallback RPM is an explicit research post option, not a machining recommendation."])
        return .init(source:NCCodec.encode(program),program:program,receipt:receipt)
    }
}
