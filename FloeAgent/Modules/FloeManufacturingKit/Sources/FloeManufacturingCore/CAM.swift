// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeManufacturingParameters

/// Tool and operation ownership is explicit. All geometry is in millimetres.
public struct ManufacturingCAM: Codable, Equatable, Sendable {
    public var formatVersion = 1
    public var tools: [Tool]
    public var operations: [Operation]
    public var partMesh: Mesh?
    public init(tools:[Tool],operations:[Operation],partMesh:Mesh? = nil) {
        self.tools = tools; self.operations = operations; self.partMesh = partMesh
    }
    private enum CodingKeys:String,CodingKey { case formatVersion,tools,operations,partMesh }
    public init(from decoder:Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        formatVersion = try c.defaulted(Int.self,forKey:.formatVersion,to:1)
        tools = try c.decode([Tool].self,forKey:.tools); operations = try c.decode([Operation].self,forKey:.operations)
        partMesh = try c.decodeIfPresent(Mesh.self,forKey:.partMesh)
    }
    public struct Frame: Codable, Equatable, Sendable {
        public var originMM: [Double]
        public var axis: [Double]
        public var xDirection: [Double]
        public init(originMM:[Double] = [0,0,0],axis:[Double] = [0,0,1],xDirection:[Double] = [1,0,0]) {
            self.originMM = originMM; self.axis = axis; self.xDirection = xDirection
        }
        public func validate() throws {
            try CAMCheck.require(CAMCheck.point(originMM) && CAMCheck.point(axis) && CAMCheck.point(xDirection),"frame coordinates")
            let dot = zip(axis,xDirection).reduce(0) { $0+$1.0*$1.1 }
            try CAMCheck.require(abs(CAMCheck.norm(axis)-1) <= 1e-9 && abs(CAMCheck.norm(xDirection)-1) <= 1e-9 && abs(dot) <= 1e-9,"frame axes must be unit and perpendicular")
        }
    }
    public struct Mesh: Codable, Equatable, Sendable {
        public var vertices: [[Double]]
        public var triangles: [[Int]]
        public init(vertices:[[Double]],triangles:[[Int]]) { self.vertices = vertices; self.triangles = triangles }
        public func validate() throws {
            try CAMCheck.require((3...120_000).contains(vertices.count) && (1...180_000).contains(triangles.count),"reference mesh budget")
            try CAMCheck.require(vertices.allSatisfy(CAMCheck.point),"reference mesh coordinates")
            for t in triangles {
                try CAMCheck.require(t.count == 3 && Set(t).count == 3 && t.allSatisfy(vertices.indices.contains),"reference mesh triangle indices")
                let a = vertices[t[0]], b = vertices[t[1]], c = vertices[t[2]]
                let u = zip(a,b).map { $1-$0 }, v = zip(a,c).map { $1-$0 }
                let cross = [u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0]]
                try CAMCheck.require(CAMCheck.norm(cross) > 1e-12,"degenerate reference triangle")
            }
        }
    }
    public struct Tool: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var kind: String
        public var diameterMM: Double
        public var cuttingLengthMM: Double
        public var tipAngleDegrees: Double?
        public var gaugeLengthMM: Double?
        public var assembly: MillingToolAssembly?
        public var flutes: Int?
        public var parameters: ManufacturingParameterSet?
        public init(id:String = UUID().uuidString.lowercased(),name:String,kind:String = "flatEndMill",diameterMM:Double,cuttingLengthMM:Double) {
            self.id = id; self.name = name; self.kind = kind; self.diameterMM = diameterMM; self.cuttingLengthMM = cuttingLengthMM
        }
        private enum CodingKeys:String,CodingKey { case id,name,kind,diameterMM,cuttingLengthMM,tipAngleDegrees,gaugeLengthMM,assembly,flutes,parameters }
        public init(from decoder:Decoder) throws {
            let c = try decoder.container(keyedBy:CodingKeys.self)
            self.init(id:try c.decode(String.self,forKey:.id),name:try c.decode(String.self,forKey:.name),kind:try c.decode(String.self,forKey:.kind),diameterMM:try c.decode(Double.self,forKey:.diameterMM),cuttingLengthMM:try c.decode(Double.self,forKey:.cuttingLengthMM))
            tipAngleDegrees = try c.decodeIfPresent(Double.self,forKey:.tipAngleDegrees)
            gaugeLengthMM = try c.decodeIfPresent(Double.self,forKey:.gaugeLengthMM)
            assembly = try c.decodeIfPresent(MillingToolAssembly.self,forKey:.assembly)
            flutes = try c.decodeIfPresent(Int.self,forKey:.flutes)
            parameters = try c.decodeIfPresent(ManufacturingParameterSet.self,forKey:.parameters)
        }
        public func validate() throws {
            try CAMCheck.require(CAMCheck.id(id) && !name.isEmpty && name.utf8.count <= 512,"tool identity")
            try CAMCheck.require(["flatEndMill","ballNose","drill"].contains(kind),"unsupported cutter kind")
            try CAMCheck.positive(diameterMM,max:1000,name:"cutter diameter")
            try CAMCheck.positive(cuttingLengthMM,max:1000,name:"cutting length")
            if let gaugeLengthMM { try CAMCheck.positive(gaugeLengthMM,max:1000,name:"tool gauge length") }
            if let flutes { try CAMCheck.require((1...100).contains(flutes),"flute count") }
            if kind == "ballNose" { try CAMCheck.require(cuttingLengthMM >= diameterMM/2,"ball radius exceeds cutting length") }
            if kind == "drill" {
                guard let tipAngleDegrees else { throw ManufacturingError.invalid("CAM: drill requires a tip angle") }
                try CAMCheck.require(tipAngleDegrees.isFinite && (10...170).contains(tipAngleDegrees),"drill tip angle")
                try CAMCheck.require(diameterMM/2/tan(tipAngleDegrees * .pi/360) <= cuttingLengthMM,"drill tip exceeds cutting length")
            }
            if let assembly { try assembly.validate(cuttingLengthMM:cuttingLengthMM) }
        }
    }
    public struct Cutting: Codable, Equatable, Sendable {
        public var mode: String
        public var toolSpindleRPM: Double
        public var feedPerToothMM: Double
        public var feedPerRevolutionMM: Double
        public init(mode:String,toolSpindleRPM:Double,feedPerToothMM:Double,feedPerRevolutionMM:Double) {
            self.mode = mode; self.toolSpindleRPM = toolSpindleRPM; self.feedPerToothMM = feedPerToothMM; self.feedPerRevolutionMM = feedPerRevolutionMM
        }
        public func resolvedFeed(tool:Tool,perMinute:Double) throws -> Double {
            try CAMCheck.require(["perMinute","perTooth","perRevolution"].contains(mode),"feed mode")
            try CAMCheck.positive(toolSpindleRPM,max:100_000,name:"live-tool spindle RPM")
            try CAMCheck.positive(feedPerToothMM,max:100,name:"feed per tooth")
            try CAMCheck.positive(feedPerRevolutionMM,max:100,name:"feed per revolution")
            let feed: Double
            switch mode {
            case "perTooth":
                guard let flutes = tool.flutes else { throw ManufacturingError.invalid("CAM: feed per tooth requires flute count") }
                feed = toolSpindleRPM * Double(flutes) * feedPerToothMM
            case "perRevolution": feed = toolSpindleRPM * feedPerRevolutionMM
            default: feed = perMinute
            }
            try CAMCheck.positive(feed,max:1_000_000,name:"resolved feed")
            return feed
        }
    }
    public struct Operation: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var enabled = true
        public var toolID: String
        public var strategy: String
        public var frame = Frame()
        public var minUVMM = [-5.0,-5]
        public var maxUVMM = [5.0,5]
        public var centerUVMM = [0.0,0]
        public var radiusMM = 5.0
        public var contourUVMM = [[Double]]()
        public var holesUVMM = [[Double]]()
        public var depthMM = 1.0
        public var stepDownMM = 1.0
        public var stepOverMM = 1.0
        public var wallStockMM = 0.0
        public var floorStockMM = 0.0
        public var breakThroughMM = 0.0
        public var clearanceMM = 3.0
        public var feedMMPerMinute = 200.0
        public var plungeFeedMMPerMinute = 80.0
        public var rapidMMPerMinute = 1000.0
        public var dwellSeconds = 0.0
        public var cycle = "drill"
        public var peckDepthMM = 1.0
        public var chipBreakRetractMM = 0.5
        public var climb = true
        public var springPasses = 0
        public var acSeed: [Double]?
        public var cutting: Cutting?
        public var parameters: ManufacturingParameterSet?
        public init(id:String = UUID().uuidString.lowercased(),name:String,strategy:String,toolID:String) {
            self.id = id; self.name = name; self.strategy = strategy; self.toolID = toolID
        }
        private enum CodingKeys:String,CodingKey { case id,name,toolID,strategy,enabled,frame,minUVMM,maxUVMM,centerUVMM,radiusMM,contourUVMM,holesUVMM,depthMM,stepDownMM,stepOverMM,wallStockMM,floorStockMM,breakThroughMM,clearanceMM,feedMMPerMinute,plungeFeedMMPerMinute,rapidMMPerMinute,dwellSeconds,cycle,peckDepthMM,chipBreakRetractMM,climb,springPasses,acSeed,cutting,parameters }
        public init(from decoder:Decoder) throws {
            let c = try decoder.container(keyedBy:CodingKeys.self)
            self.init(id:try c.decode(String.self,forKey:.id),name:try c.decode(String.self,forKey:.name),strategy:try c.decode(String.self,forKey:.strategy),toolID:try c.decode(String.self,forKey:.toolID))
            enabled = try c.defaulted(Bool.self,forKey:.enabled,to:true)
            frame = try c.defaulted(Frame.self,forKey:.frame,to:Frame())
            minUVMM = try c.defaulted([Double].self,forKey:.minUVMM,to:[-5,-5])
            maxUVMM = try c.defaulted([Double].self,forKey:.maxUVMM,to:[5,5])
            centerUVMM = try c.defaulted([Double].self,forKey:.centerUVMM,to:[0,0])
            radiusMM = try c.defaulted(Double.self,forKey:.radiusMM,to:5)
            contourUVMM = try c.defaulted([[Double]].self,forKey:.contourUVMM,to:[])
            holesUVMM = try c.defaulted([[Double]].self,forKey:.holesUVMM,to:[])
            depthMM = try c.defaulted(Double.self,forKey:.depthMM,to:1)
            stepDownMM = try c.defaulted(Double.self,forKey:.stepDownMM,to:1)
            stepOverMM = try c.defaulted(Double.self,forKey:.stepOverMM,to:1)
            wallStockMM = try c.defaulted(Double.self,forKey:.wallStockMM,to:0)
            floorStockMM = try c.defaulted(Double.self,forKey:.floorStockMM,to:0)
            breakThroughMM = try c.defaulted(Double.self,forKey:.breakThroughMM,to:0)
            clearanceMM = try c.defaulted(Double.self,forKey:.clearanceMM,to:3)
            feedMMPerMinute = try c.defaulted(Double.self,forKey:.feedMMPerMinute,to:200)
            plungeFeedMMPerMinute = try c.defaulted(Double.self,forKey:.plungeFeedMMPerMinute,to:80)
            rapidMMPerMinute = try c.defaulted(Double.self,forKey:.rapidMMPerMinute,to:1000)
            dwellSeconds = try c.defaulted(Double.self,forKey:.dwellSeconds,to:0)
            cycle = try c.defaulted(String.self,forKey:.cycle,to:"drill")
            peckDepthMM = try c.defaulted(Double.self,forKey:.peckDepthMM,to:1)
            chipBreakRetractMM = try c.defaulted(Double.self,forKey:.chipBreakRetractMM,to:0.5)
            climb = try c.defaulted(Bool.self,forKey:.climb,to:true)
            springPasses = try c.defaulted(Int.self,forKey:.springPasses,to:0)
            acSeed = try c.decodeIfPresent([Double].self,forKey:.acSeed)
            cutting = try c.decodeIfPresent(Cutting.self,forKey:.cutting)
            parameters = try c.decodeIfPresent(ManufacturingParameterSet.self,forKey:.parameters)
        }
        public func effectiveFeed(tool:Tool) throws -> Double { try cutting?.resolvedFeed(tool:tool,perMinute:feedMMPerMinute) ?? feedMMPerMinute }
        public func validate(tool:Tool,hasMesh:Bool) throws {
            try CAMCheck.require(CAMCheck.id(id) && !name.isEmpty && name.utf8.count <= 512,"operation identity")
            try CAMCheck.require(["face","pocket","contour","drill","surfaceRaster","swarf"].contains(strategy),"unsupported CAM strategy")
            try frame.validate()
            for (value,label) in [(depthMM,"depth"),(stepDownMM,"step down"),(stepOverMM,"step over"),(clearanceMM,"clearance"),(feedMMPerMinute,"feed"),(plungeFeedMMPerMinute,"plunge feed"),(rapidMMPerMinute,"rapid speed")] {
                try CAMCheck.positive(value,max:label.contains("feed") || label.contains("speed") ? 1_000_000 : 100_000,name:label)
            }
            try CAMCheck.require([wallStockMM,floorStockMM,breakThroughMM,peckDepthMM,chipBreakRetractMM,dwellSeconds].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 100_000 },"nonnegative process dimensions")
            try CAMCheck.require((0...10).contains(springPasses),"spring pass budget")
            if ["face","surfaceRaster"].contains(strategy) {
                try CAMCheck.require(CAMCheck.pair(minUVMM) && CAMCheck.pair(maxUVMM) && zip(minUVMM,maxUVMM).allSatisfy { $0 < $1 },"planar bounds")
            }
            if ["pocket","contour"].contains(strategy) {
                try CAMCheck.require(CAMCheck.pair(centerUVMM),"feature center")
                try CAMCheck.positive(radiusMM,max:100_000,name:"feature radius")
            }
            if strategy == "drill" {
                try CAMCheck.require(!holesUVMM.isEmpty && holesUVMM.count <= 256 && holesUVMM.allSatisfy(CAMCheck.pair),"hole positions")
                try CAMCheck.require(["drill","counterBore","peck","chipBreak","bore"].contains(cycle),"unsupported hole cycle")
                if ["peck","chipBreak"].contains(cycle) { try CAMCheck.positive(peckDepthMM,max:100_000,name:"peck depth") }
            }
            if ["surfaceRaster","swarf"].contains(strategy) { try CAMCheck.require(hasMesh,"strategy requires reference mesh") }
            if let acSeed {
                try CAMCheck.require(acSeed.count == 5 && acSeed.allSatisfy { $0.isFinite && abs($0) <= 100_000 } && tool.gaugeLengthMM != nil,"A/C seed and tool gauge length")
            }
            _ = try effectiveFeed(tool:tool)
        }
    }
    public func validate() throws {
        try CAMCheck.require(formatVersion == 1,"unsupported CAM version")
        // A newly prepared CAD job owns its reference mesh before the user
        // selects a cutter or adds an operation. Only that empty draft may
        // omit tools; each enabled operation still requires its actual tool.
        let emptyDraft = tools.isEmpty && operations.isEmpty
        try CAMCheck.require((emptyDraft || (1...8).contains(tools.count)) && (0...12).contains(operations.count),"tool/operation budget")
        try CAMCheck.require(Set(tools.map(\.id)).count == tools.count && Set(operations.map(\.id)).count == operations.count,"duplicate tool/operation identity")
        try partMesh?.validate()
        for tool in tools {
            try tool.validate()
            try validateOwnedParameters(tool.parameters,prefix:"camTool.",owner:tool)
        }
        for op in operations {
            if op.enabled {
                guard let tool = tools.first(where:{ $0.id == op.toolID }) else { throw ManufacturingError.invalid("CAM: missing referenced tool") }
                try op.validate(tool:tool,hasMesh:partMesh != nil)
            } else {
                try CAMCheck.require(CAMCheck.id(op.id) && !op.name.isEmpty && op.name.utf8.count <= 512 && op.toolID.utf8.count <= 96,"disabled operation identity")
                try CAMCheck.require(["face","pocket","contour","drill","surfaceRaster","swarf"].contains(op.strategy),"unsupported disabled strategy")
                // Parked operations may await a mesh or a tool assignment. Keep
                // their finite inputs; execution validation runs when enabled.
                let numbers = [op.radiusMM,op.depthMM,op.stepDownMM,op.stepOverMM,op.wallStockMM,op.floorStockMM,op.breakThroughMM,op.clearanceMM,op.feedMMPerMinute,op.plungeFeedMMPerMinute,op.rapidMMPerMinute,op.dwellSeconds,op.peckDepthMM,op.chipBreakRetractMM]
                try CAMCheck.require(numbers.allSatisfy { $0.isFinite && abs($0) <= 1_000_000 } &&
                    op.contourUVMM.count <= 256 && op.holesUVMM.count <= 256 &&
                    (op.contourUVMM+op.holesUVMM).allSatisfy(CAMCheck.pair) &&
                    [op.minUVMM,op.maxUVMM,op.centerUVMM].allSatisfy(CAMCheck.pair) &&
                    [op.frame.originMM,op.frame.axis,op.frame.xDirection].allSatisfy(CAMCheck.point) &&
                    (op.acSeed == nil || (op.acSeed!.count == 5 && op.acSeed!.allSatisfy { $0.isFinite && abs($0) <= 100_000 })),"disabled operation storage budget")
            }
            try validateOwnedParameters(op.parameters,prefix:"camOperation.",owner:op)
        }
    }
    private func validateOwnedParameters<T:Encodable>(_ set:ManufacturingParameterSet?,prefix:String,owner:T) throws {
        guard let set else { return }
        try ManufacturingStudy.checkParameterSet(set,catalog:.standard)
        for descriptor in ManufacturingParameterCatalog.standard.parameters {
            if let binding = descriptor.binding, binding.hasPrefix(prefix), let stored = set.value(descriptor.id),
               let actual = ParameterProjection.get(owner,path:String(binding.dropFirst(prefix.count))),
               !ManufacturingStudy.sameParameterValue(stored,actual) {
                throw ManufacturingError.invalid("conflicting owned field and parameter: "+descriptor.id)
            }
        }
    }
    public var enabledOperations: [Operation] { operations.filter(\.enabled) }
    /// Resolve user feed units exactly once, at the native adapter boundary.
    public func nativeInput() throws -> Self {
        try validate()
        var value = self
        for index in value.operations.indices {
            if value.operations[index].enabled {
                guard let tool = value.tools.first(where:{ $0.id == value.operations[index].toolID }) else { throw ManufacturingError.invalid("CAM: missing referenced tool") }
                value.operations[index].feedMMPerMinute = try value.operations[index].effectiveFeed(tool:tool)
            }
            value.operations[index].parameters = nil
        }
        for index in value.tools.indices { value.tools[index].parameters = nil }
        return value
    }
}

enum CAMCheck {
    static func require(_ condition:Bool,_ message:String) throws { if !condition { throw ManufacturingError.invalid("CAM: "+message) } }
    static func positive(_ value:Double,max:Double,name:String) throws { try require(value.isFinite && value > 0 && value <= max,name) }
    static func point(_ a:[Double]) -> Bool { a.count == 3 && a.allSatisfy { $0.isFinite && abs($0) <= 100_000 } }
    static func pair(_ a:[Double]) -> Bool { a.count == 2 && a.allSatisfy { $0.isFinite && abs($0) <= 100_000 } }
    static func norm(_ a:[Double]) -> Double { sqrt(a.reduce(0) { $0+$1*$1 }) }
    static func id(_ s:String) -> Bool { !s.isEmpty && s.utf8.count <= 96 && s.range(of:"^[A-Za-z0-9._-]+$",options:.regularExpression) != nil }
}

extension KeyedDecodingContainer {
    /// Absence alone selects a default. An explicit null or wrong type never
    /// silently replaces an active process parameter with a research example.
    func defaulted<T:Decodable>(_ type:T.Type,forKey key:Key,to fallback:T) throws -> T {
        contains(key) ? try decode(type,forKey:key) : fallback
    }
}
