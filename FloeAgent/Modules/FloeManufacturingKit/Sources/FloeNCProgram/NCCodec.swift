// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A bounded, numeric RS274-style profile. Unsupported semantics fail with source line.
/// No controller execution, offsets, macros or compensation are inferred.
public enum NCCodec {
    public static let profile = "Floe NC 1 / numeric RS274 + documented XY spline extensions"
    public static func decode(_ source: String, configuration: NCConfiguration = .init(),
                              cancellation: NCCancellation? = nil) throws -> NCProgram {
        try configuration.validate(); try cancellation?.check()
        guard source.utf8.count <= configuration.maximumBytes else { throw NCError("G-code byte budget exceeded") }
        let blocks = try tokenize(source,configuration:configuration,cancellation:cancellation)
        var parser = Parser(configuration:configuration,cancellation:cancellation)
        for block in blocks { try parser.execute(block) }
        guard parser.nurbs == nil else { throw NCError("Unclosed G5.2 block; expected G5.3") }
        guard parser.percentCount == 0 || parser.percentCount == 2 else { throw NCError("Unpaired % program delimiter") }
        guard !parser.motions.isEmpty else { throw NCError("Program contains no motion") }
        let program = NCProgram(profile:profile,blocks:blocks,motions:parser.motions,events:parser.events,
            finalPosition:parser.position,finalProcess:parser.process,configuration:configuration,
            notes:["Coordinates are in the selected local work frame; machine/tool offsets and stock are not supplied.",
                   "Unknown initial axes remain unknown; an unlocated first traverse is not drawn.",
                   "Subdivision changes display only. G5.2/G5.3 is an experimental documented extension, not a controller certification."])
        // Fail closed before handing a partial or over-budget preview to the caller.
        _ = try NCGeometry.sample(program,cancellation:cancellation)
        return program
    }
    /// Serialize validated words, rather than echoing the input text or linearizing curves.
    public static func encode(_ program: NCProgram) -> String {
        program.blocks.map { block in
            if block.words.first?.letter == "%" { return "%" }
            return block.words.map { $0.letter+NCFormat.number($0.value) }.joined(separator:" ")
        }.joined(separator:"\n")+"\n"
    }
    private static func tokenize(_ source: String,configuration:NCConfiguration,cancellation:NCCancellation?) throws -> [NCBlock] {
        var blocks = [NCBlock]()
        let input=source.hasPrefix("\u{FEFF}") ? String(source.dropFirst()) : source
        for (index,raw) in input.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n").split(separator:"\n",omittingEmptySubsequences:false).enumerated() {
            try cancellation?.check()
            var clean = "", comment = false
            for character in raw {
                if character == ";" && !comment { break }
                if character == "(" {
                    guard !comment else { throw NCError("Nested comments unsupported",line:index+1) }; comment = true
                } else if character == ")" {
                    guard comment else { throw NCError("Unmatched comment terminator",line:index+1) }; comment = false
                } else if !comment { clean.append(character) }
            }
            guard !comment else { throw NCError("Unclosed comment",line:index+1) }
            clean = clean.trimmingCharacters(in:.whitespaces)
            if clean.isEmpty { continue }
            guard blocks.count < configuration.maximumBlocks else { throw NCError("Block budget exceeded",line:index+1) }
            if clean == "%" { blocks.append(.init(line:index+1,words:[.init("%",0)])); continue }
            let bytes = Array(clean.uppercased().utf8)
            var cursor = 0, words = [NCWord]()
            while cursor < bytes.count {
                if bytes[cursor] == 32 || bytes[cursor] == 9 { cursor += 1; continue }
                let letter = bytes[cursor]
                guard (65...90).contains(letter) || letter == 36 else { throw NCError("Expected a numeric word; macros, expressions and block-delete require an explicit adapter",line:index+1) }
                cursor += 1
                while cursor < bytes.count && (bytes[cursor] == 32 || bytes[cursor] == 9) { cursor += 1 }
                let begin = cursor
                if cursor < bytes.count && (bytes[cursor] == 43 || bytes[cursor] == 45) { cursor += 1 }
                var decimal = false, digits = 0
                while cursor < bytes.count {
                    let c = bytes[cursor]
                    if (48...57).contains(c) { digits += 1; cursor += 1 }
                    else if c == 46 && !decimal { decimal = true; cursor += 1 }
                    else { break }
                }
                guard digits > 0, let value = Double(String(decoding:bytes[begin..<cursor],as:UTF8.self)), value.isFinite, abs(value) <= 1e9 else { throw NCError("Invalid or out-of-range numeric word",line:index+1) }
                words.append(.init(String(UnicodeScalar(letter)),value))
                guard words.count <= 40 else { throw NCError("Words-per-block budget exceeded",line:index+1) }
            }
            blocks.append(.init(line:index+1,words:words))
        }
        return blocks
    }
}

private struct NURBSBlock {
    let line: Int
    let start: NCPosition
    let process: NCProcessState
    let order: Int
    var controls: [NCVector]
    var weights: [Double]
}
private struct Parser {
    let configuration: NCConfiguration
    let cancellation: NCCancellation?
    var position: NCPosition
    var units: NCUnits?
    var plane = NCPlane.xy
    var absolute = true, absoluteCenter = false, diameter = false
    var mode: Double?
    var process = NCProcessState()
    var motions = [NCMotion](), events = [NCEvent]()
    var ended = false, percentCount = 0, processedBlocks = 0
    var tangent: NCVector?
    var nurbs: NURBSBlock?
    init(configuration: NCConfiguration,cancellation: NCCancellation?) {
        self.configuration=configuration; self.cancellation=cancellation
        position=configuration.initialPosition; units=configuration.defaultUnits
    }
    mutating func execute(_ block: NCBlock) throws {
        try cancellation?.check()
        defer { processedBlocks += 1 }
        let line = block.line
        func fail(_ message:String) -> NCError { NCError(message,line:line) }
        if block.words.first?.letter == "%" {
            guard nurbs == nil, percentCount < 2, percentCount > 0 || processedBlocks == 0 else { throw fail("Misplaced % delimiter") }
            percentCount += 1; if percentCount == 2 { ended = true }; return
        }
        guard !ended else { throw fail("Content after program end is not interpreted") }
        var values = [String:Double](), gs = [Double](), ms = [Int]()
        for word in block.words {
            if word.letter == "G" { gs.append(word.value) }
            else if word.letter == "M" {
                guard word.value.rounded() == word.value else { throw fail("M code must be an integer") }; ms.append(Int(word.value))
            } else {
                guard values[word.letter] == nil else { throw fail("Duplicate \(word.letter) word") }
                values[word.letter] = word.value
            }
        }
        if let n = values["N"], n < 0 || n.rounded() != n { throw fail("Invalid sequence number") }
        values.removeValue(forKey:"N")
        if nurbs != nil {
            guard ms.isEmpty else { throw fail("M code inside NURBS control block") }
            if gs == [5.3] {
                guard values.isEmpty, let curve = nurbs, curve.controls.count >= curve.order else { throw fail("G5.3 requires enough control points and no extra words") }
                position.x = curve.controls.last!.x; position.y = curve.controls.last!.y
                motions.append(.init(line:curve.line,start:curve.start,end:position,
                    curve:.nurbs(controls:curve.controls,weights:curve.weights,knots:NCGeometry.uniformKnots(controlCount:curve.controls.count,order:curve.order),order:curve.order),rapid:false,process:curve.process))
                nurbs=nil; mode=nil; tangent=nil; return
            }
            guard gs.isEmpty || gs == [5.2],Set(values.keys).isSubset(of:["X","Y","P"]),
                  let x=values["X"],let y=values["Y"],let weight=values["P"],weight >= 1e-9,weight <= 1e9,
                  nurbs!.controls.count < configuration.maximumControlPoints else { throw fail("NURBS rows require absolute X Y and positive P weight within the control-point budget") }
            let scale = units!.scale
            nurbs!.controls.append(.init(x*scale,y*scale,position.z ?? 0)); nurbs!.weights.append(weight); return
        }
        let groups: [Double:Int] = [0:1,1:1,2:1,3:1,5:1,5.1:1,5.2:1,80:1,17:2,18:2,19:2,20:3,21:3,90:4,91:4,90.1:5,91.1:5,7:6,8:6,93:7,94:7,95:7,96:8,97:8,4:9,40:10,49:11,54:12,61:13,61.1:13]
        var seenGroups = Set<Int>()
        for g in gs {
            guard let group = groups[g] else { throw fail("Unsupported G\(NCFormat.number(g)); no partial interpretation") }
            guard seenGroups.insert(group).inserted else { throw fail("Conflicting G codes in one modal group") }
        }
        let mGroups: [Int:Int] = [0:1,1:1,2:1,30:1,3:2,4:2,5:2,6:3,7:4,8:5,9:6]
        var seenM = Set<Int>()
        for m in ms {
            guard let group = mGroups[m] else { throw fail("Unsupported M\(m); machine-specific action needs an adapter") }
            guard seenM.insert(group).inserted else { throw fail("Conflicting M codes") }
        }
        if ms.contains(9) && (ms.contains(7) || ms.contains(8)) { throw fail("Conflicting coolant commands") }
        let oldProcess = process
        let spindleValue = values["$"] ?? 0
        guard spindleValue.rounded() == spindleValue, (-1...7).contains(spindleValue) else { throw fail("Spindle selector must be an integer -1...7") }
        let spindleID = Int(spindleValue)
        let spindleCommands = values["S"] != nil || gs.contains(96) || gs.contains(97) || ms.contains(where:{ (3...5).contains($0) })
        if values["$"] != nil && !spindleCommands { throw fail("Spindle selector has no spindle command in this profile") }
        if spindleID < 0 && (values["S"] != nil || gs.contains(96) || gs.contains(97)) { throw fail("$-1 is only supported for M3/M4/M5") }
        for g in gs {
            switch g {
            case 17: plane = .xy
            case 18: plane = .zx
            case 19: plane = .yz
            case 20: units = .inches
            case 21: units = .millimetres
            case 90: absolute = true
            case 91: absolute = false
            case 90.1: absoluteCenter = true
            case 91.1: absoluteCenter = false
            case 7: diameter = true
            case 8: diameter = false
            case 93,94,95:
                let next:NCFeedMode = g == 93 ? .inverseTime : g == 94 ? .perMinute : .perRevolution
                if process.feedMode != next { process.feed = nil }; process.feedMode = next
            case 0,1,2,3,5,5.1,5.2: mode = g;if g != 5 { tangent=nil }
            case 80: mode = nil
            default: break
            }
        }
        let lengthWords = Set(values.keys).intersection(["X","Y","Z","I","J","K","R","F","S"])
        guard units != nil || lengthWords.isEmpty else { throw fail("Declare G20/G21 or supply explicit default units") }
        let scale = units?.scale ?? 1
        var allowed:Set<String> = ["X","Y","Z","A","B","C","F","S","T","$"]
        if gs.contains(96) || gs.contains(97) {
            var spindle = process.spindles[spindleID] ?? .init()
            let next:NCSpindleMode = gs.contains(96) ? .constantSurfaceSpeed : .rpm
            if spindle.mode != next && values["S"] == nil { throw fail("S required when changing spindle speed mode") }
            spindle.mode = next
            if gs.contains(96) { allowed.insert("D"); if let d = values["D"] { guard d > 0 else { throw fail("D RPM cap must be positive") }; spindle.maximumRPM=d } }
            process.spindles[spindleID]=spindle
        }
        if let feed=values["F"] { guard feed > 0 else { throw fail("F must be positive") }; process.feed = feed*(process.feedMode == .inverseTime ? 1 : scale) }
        if let speed=values["S"] {
            guard speed >= 0 else { throw fail("S cannot be negative") }
            var spindle = process.spindles[spindleID] ?? .init()
            spindle.speed = speed*(spindle.mode == .constantSurfaceSpeed && units == .inches ? 0.3048 : 1)
            process.spindles[spindleID]=spindle
        }
        if let tool=values["T"] { guard tool >= 0,tool.rounded() == tool else { throw fail("T must be a nonnegative tool identity") }; process.selectedTool=Int(tool) }
        for m in ms.filter({ (3...5).contains($0) }) {
            let ids = spindleID == -1 ? process.spindles.keys.sorted() : [spindleID]
            for id in ids {
                var spindle = process.spindles[id] ?? .init()
                spindle.direction = m == 3 ? .clockwise : m == 4 ? .counterclockwise : .stopped
                process.spindles[id]=spindle
            }
        }
        if ms.contains(6) {
            guard !spindleCommands else { throw fail("Use separate blocks for tool change and spindle commands in this profile") }
            guard let selected = process.selectedTool else { throw fail("M6 needs a selected T identity") }
            guard Set(values.keys).intersection(["X","Y","Z","A","B","C"]).isEmpty else { throw fail("Tool change and axis motion must use separate blocks in this profile") }
            process.loadedTool=selected; process.spindles[0,default:.init()].direction = .stopped
            events.append(.init(line:line,kind:"tool-change",value:Double(selected),process:process))
        }
        if ms.contains(7) { process.mist=true }; if ms.contains(8) { process.flood=true }
        if ms.contains(9) { process.mist=false; process.flood=false }
        if process != oldProcess { events.append(.init(line:line,kind:"process",value:nil,process:process)) }
        let axisNames = Array("XYZABC").map(String.init)
        let hasAxis = axisNames.contains(where:{ values[$0] != nil })
        if gs.contains(4) {
            allowed.insert("P")
            guard !hasAxis,let seconds=values["P"],seconds >= 0 else { throw fail("G4 needs nonnegative P seconds and no axis words") }
            events.append(.init(line:line,kind:"dwell",value:seconds,process:process))
        } else if mode == 5.2 && gs.contains(5.2) {
            allowed.formUnion(["P","L"])
            guard plane == .xy,absolute,!diameter,position.x != nil,position.y != nil,
                  Set(values.keys).intersection(["Z","A","B","C"]).isEmpty,
                  let feed=process.feed,feed > 0,process.feedMode != .inverseTime else { throw fail("G5.2 needs G17/G90/G8, known XY, fixed Z, and G94/G95 feed") }
            let orderValue = values["L"] ?? 3
            guard orderValue.rounded() == orderValue,(3...6).contains(orderValue) else { throw fail("NURBS L order must be 3...6") }
            var controls=[position.displayPoint],weights=[1.0]
            if hasAxis {
                guard let x=values["X"],let y=values["Y"],let p=values["P"],p >= 1e-9,p <= 1e9 else { throw fail("First appended NURBS control requires X Y P") }
                controls.append(.init(x*scale,y*scale,position.z ?? 0)); weights.append(p)
            } else { let p=values["P"] ?? 1; guard p >= 1e-9,p <= 1e9 else { throw fail("NURBS weight must be positive") }; weights[0]=p }
            nurbs = .init(line:line,start:position,process:process,order:Int(orderValue),controls:controls,weights:weights)
            tangent=nil
        } else if hasAxis || ((mode == 2 || mode == 3) && !Set(values.keys).intersection(["I","J","K","R"]).isEmpty) || (gs.contains(5) || gs.contains(5.1)) {
            guard let mode else { throw fail("Axis words require an explicit motion mode") }
            if mode != 0 { guard process.feed != nil, process.feedMode != .inverseTime || values["F"] != nil else { throw fail("Cutting motion requires feed; G93 requires F on every motion block") } }
            var end = position
            for axis in 0..<6 {
                guard let value=values[axisNames[axis]] else { continue }
                let physical = value*(axis < 3 ? scale : 1)*(axis == 0 && diameter ? 0.5 : 1)
                if absolute { end[axis]=physical }
                else { guard let start=position[axis] else { throw fail("Incremental \(axisNames[axis]) has unknown initial coordinate") }; end[axis]=start+physical }
                if mode != 0 && position[axis] == nil { throw fail("Cutting motion has unknown starting \(axisNames[axis])") }
                guard end[axis]!.isFinite,abs(end[axis]!) <= 1e9 else { throw fail("Resolved axis exceeds coordinate budget") }
            }
            let curve:NCCurve
            if mode == 0 || mode == 1 {
                let unknownStart = (0..<6).contains { values[axisNames[$0]] != nil && position[$0] == nil }
                curve = unknownStart ? .unlocated : .line; tangent=nil
            } else if mode == 2 || mode == 3 {
                allowed.formUnion(["I","J","K","R","P"])
                curve = try arc(start:position,end:end,words:values,clockwise:mode == 2,scale:scale,line:line); tangent=nil
            } else if mode == 5 || mode == 5.1 {
                allowed.formUnion(mode == 5 ? ["I","J","P","Q"] : ["I","J"])
                guard plane == .xy,!diameter,position.x != nil,position.y != nil,
                      Set(values.keys).intersection(["Z","A","B","C"]).isEmpty else { throw fail("XY splines require G17/G8 and fixed ZABC") }
                let a=position.displayPoint,b=end.displayPoint,control:NCVector
                if mode == 5 {
                    guard let p=values["P"],let q=values["Q"] else { throw fail("G5 requires both P and Q end-control offsets") }
                    if let i=values["I"],let j=values["J"] { control=a+NCVector(i*scale,j*scale,0) }
                    else { guard values["I"] == nil,values["J"] == nil,let tangent else { throw fail("First G5 requires both I and J; subsequent omission needs a preceding cubic") }; control=a+tangent }
                    let offset=NCVector(p*scale,q*scale,0)
                    curve = .bezier(controls:[a,control,b+offset,b]); tangent=offset * -1
                } else {
                    let i=values["I"] ?? 0,j=values["J"] ?? 0
                    guard i != 0 || j != 0 else { throw fail("G5.1 requires a nonzero I or J control offset") }
                    curve = .bezier(controls:[a,a+NCVector(i*scale,j*scale,0),b]); tangent=nil
                }
            } else { throw fail("Unsupported motion") }
            motions.append(.init(line:line,start:position,end:end,curve:curve,rapid:mode == 0,process:process)); position=end
        }
        guard Set(values.keys).isSubset(of:allowed) else { throw fail("Unused/unsupported word(s): \(Set(values.keys).subtracting(allowed).sorted().joined(separator:", "))") }
        if ms.contains(0) || ms.contains(1) { events.append(.init(line:line,kind:ms.contains(0) ? "pause" : "optional-pause",value:nil,process:process)) }
        if ms.contains(2) || ms.contains(30) {
            for id in process.spindles.keys { process.spindles[id]!.direction = .stopped }
            process.mist=false;process.flood=false;process.feedMode = .perMinute
            plane = .xy;absolute=true;mode=1
            events.append(.init(line:line,kind:ms.contains(2) ? "end-M2" : "end-M30",value:nil,process:process)); ended=true
        }
    }

    private func arc(start:NCPosition,end:NCPosition,words:[String:Double],clockwise:Bool,scale:Double,line:Int) throws -> NCCurve {
        func fail(_ message:String) -> NCError { .init(message,line:line) }
        let axes=plane.axes,u=axes[0],v=axes[1],w=axes[2],names=["I","J","K"]
        guard let su=start[u],let sv=start[v],let eu=end[u],let ev=end[v] else { throw fail("Arc plane has unknown start/end axes") }
        let turns=words["P"] ?? 1
        guard turns.rounded() == turns,(1...10000).contains(turns) else { throw fail("Arc P must be a positive integer turn count within budget") }
        func sweep(_ center:NCVector) -> Double {
            if su == eu && sv == ev { return clockwise ? -2 * .pi : 2 * .pi }
            var angle=atan2(ev-center[v],eu-center[u])-atan2(sv-center[v],su-center[u])
            if clockwise { while angle >= 0 { angle -= 2 * .pi } } else { while angle <= 0 { angle += 2 * .pi } }
            return angle
        }
        var center=start.displayPoint
        if let signedR=words["R"] {
            guard Set(words.keys).intersection(["I","J","K"]).isEmpty else { throw fail("Mixed R and IJK arc formats") }
            let radius=abs(signedR*scale),du=eu-su,dv=ev-sv,d=hypot(du,dv)
            guard d > 1e-12,radius > 0,d <= 2*radius else { throw fail("Ambiguous full-circle R arc or radius smaller than chord") }
            let h=sqrt(max(0,radius*radius-d*d/4))
            center[u]=(su+eu)/2-dv/d*h; center[v]=(sv+ev)/2+du/d*h
            if (abs(sweep(center)) > .pi+1e-12) != (signedR < 0) {
                center[u]=(su+eu)/2+dv/d*h; center[v]=(sv+ev)/2-du/d*h
            }
        } else {
            guard words[names[w]] == nil,words[names[u]] != nil || words[names[v]] != nil else { throw fail("Arc needs in-plane IJK center offsets or R") }
            if absoluteCenter {
                guard let cu=words[names[u]],let cv=words[names[v]] else { throw fail("G90.1 requires both in-plane absolute center coordinates") }
                center[u]=cu*scale;center[v]=cv*scale
            } else { center[u]=su+(words[names[u]] ?? 0)*scale;center[v]=sv+(words[names[v]] ?? 0)*scale }
        }
        let r0=hypot(su-center[u],sv-center[v]),r1=hypot(eu-center[u],ev-center[v])
        guard r0 > 1e-12,abs(r0-r1) <= configuration.arcRadiusToleranceMM else { throw fail("Arc start/end radius mismatch exceeds \(configuration.arcRadiusToleranceMM) mm") }
        return .arc(center:center,sweepRadians:sweep(center)+(clockwise ? -1 : 1)*2 * .pi*(turns-1),plane:plane)
    }
}
