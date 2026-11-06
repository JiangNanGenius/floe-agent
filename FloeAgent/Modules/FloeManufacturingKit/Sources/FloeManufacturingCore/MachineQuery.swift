// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeMachiningNative

public struct MachineFrame:Codable,Equatable,Sendable {
    public var originMM:[Double]
    public var xDirection:[Double]
    public var zDirection:[Double]
    public var yDirection:[Double]?
    public init(originMM:[Double] = [0,0,0],xDirection:[Double] = [1,0,0],zDirection:[Double] = [0,0,1]) {
        self.originMM = originMM; self.xDirection = xDirection; self.zDirection = zDirection
    }
    public func validate() throws {
        func vector(_ v:[Double])->Bool { v.count == 3 && v.allSatisfy { $0.isFinite && abs($0) <= 1e6 } }
        guard vector(originMM),vector(xDirection),vector(zDirection) else { throw ManufacturingError.invalid("machine frame vectors") }
        func dot(_ a:[Double],_ b:[Double])->Double { zip(a,b).reduce(0) { $0+$1.0*$1.1 } }
        guard abs(dot(xDirection,xDirection)-1)<1e-6,abs(dot(zDirection,zDirection)-1)<1e-6,
              abs(dot(xDirection,zDirection))<1e-6 else { throw ManufacturingError.invalid("machine frame must be orthonormal") }
        if let yDirection {
            let x = xDirection,z = zDirection
            let y = [z[1]*x[2]-z[2]*x[1],z[2]*x[0]-z[0]*x[2],z[0]*x[1]-z[1]*x[0]]
            guard vector(yDirection),zip(y,yDirection).allSatisfy({ abs($0-$1)<1e-6 }) else { throw ManufacturingError.invalid("machine frame handedness") }
        }
    }
}

public struct MachineAxis:Codable,Equatable,Sendable,Identifiable {
    public enum Kind:String,Codable,Sendable { case linear,revolute }
    public var id:String
    public var kind:Kind
    public var parent:String?
    public var originMM:[Double]
    public var axis:[Double]
    public var limitsMM:[Double]?
    public var limitsDeg:[Double]?
    public init(id:String,kind:Kind,parent:String? = nil,originMM:[Double] = [0,0,0],axis:[Double],limits:[Double]) {
        self.id = id; self.kind = kind; self.parent = parent; self.originMM = originMM; self.axis = axis
        limitsMM = kind == .linear ? limits : nil; limitsDeg = kind == .revolute ? limits : nil
    }
}

public struct MachineBody:Codable,Equatable,Sendable,Identifiable {
    public struct Shape:Codable,Equatable,Sendable {
        public enum Kind:String,Codable,Sendable { case box,cylinder,capsule,mesh }
        public var type:Kind
        public var halfExtentsMM:[Double]?
        public var radiusMM:Double?
        public var lengthMM:Double?
        public var vertices:[[Double]]?
        public var triangles:[[Int]]?
        public init(type:Kind,halfExtentsMM:[Double]? = nil,radiusMM:Double? = nil,lengthMM:Double? = nil,
                    vertices:[[Double]]? = nil,triangles:[[Int]]? = nil) {
            self.type = type; self.halfExtentsMM = halfExtentsMM; self.radiusMM = radiusMM; self.lengthMM = lengthMM
            self.vertices = vertices; self.triangles = triangles
        }
    }
    public struct Attachment:Codable,Equatable,Sendable {
        public var axis:String
        public var frame:MachineFrame?
        public init(axis:String,frame:MachineFrame? = nil) { self.axis = axis; self.frame = frame }
    }
    public var id:String
    public var resourceID:String?
    public var attach:Attachment?
    public var frame:MachineFrame?
    public var shape:Shape
    public init(id:String,resourceID:String? = nil,attach:Attachment? = nil,frame:MachineFrame? = nil,shape:Shape) {
        self.id = id; self.resourceID = resourceID; self.attach = attach; self.frame = frame; self.shape = shape
    }
}

public struct MachineMotion:Codable,Equatable,Sendable {
    public var joint:String
    public var fromMM:Double?
    public var toMM:Double?
    public var fromDeg:Double?
    public var toDeg:Double?
    public static func linear(_ id:String,from:Double,to:Double)->Self { .init(joint:id,fromMM:from,toMM:to) }
    public static func rotary(_ id:String,from:Double,to:Double)->Self { .init(joint:id,fromDeg:from,toDeg:to) }
    public init(joint:String,fromMM:Double? = nil,toMM:Double? = nil,fromDeg:Double? = nil,toDeg:Double? = nil) {
        self.joint = joint; self.fromMM = fromMM; self.toMM = toMM; self.fromDeg = fromDeg; self.toDeg = toDeg
    }
}

public struct MachineQueryRequest:Codable,Equatable,Sendable {
    public struct Chain:Codable,Equatable,Sendable {
        public var formatVersion = 1
        public var baseFrame:MachineFrame?
        public var axes:[MachineAxis]
        public init(baseFrame:MachineFrame? = nil,axes:[MachineAxis]) { self.baseFrame = baseFrame; self.axes = axes }
    }
    public struct Budget:Codable,Equatable,Sendable {
        public var maxSamples = 512
        public var maxCollisionQueries = 50_000
        public var clearanceMM = 0.0
        public var sampleSpacingMM = 1.0
        public var maxRotationDegPerSample = 15.0
        public init() {}
    }
    public var formatVersion = 1
    public var chain:Chain
    public var bodies:[MachineBody]
    public var fixtures:[MachineBody]
    public var motion:MachineMotion?
    public var motions:[MachineMotion]?
    public var jointPositions:[String:Double]?
    /// Intentional contacts excluded from checks, always retained in the request.
    public var allowedContactPairs:[[String]]?
    /// Optional explicit subset; any verdict then covers only these pairs.
    public var queryPairs:[[String]]?
    public var budget = Budget()
    public init(chain:Chain,bodies:[MachineBody],fixtures:[MachineBody] = [],motion:MachineMotion? = nil,motions:[MachineMotion]? = nil,
                jointPositions:[String:Double]? = nil,allowedContactPairs:[[String]]? = nil,queryPairs:[[String]]? = nil) {
        self.chain = chain; self.bodies = bodies; self.fixtures = fixtures; self.motion = motion; self.motions = motions
        self.jointPositions = jointPositions; self.allowedContactPairs = allowedContactPairs; self.queryPairs = queryPairs
    }
    public func validate() throws {
        guard formatVersion == 1,chain.formatVersion == 1,(1...32).contains(chain.axes.count),
              bodies.count+fixtures.count <= 128,!bodies.isEmpty,
              (motion != nil) != (motions != nil), motions == nil || !(motions?.isEmpty ?? true),
              (1...4096).contains(budget.maxSamples),(1...500_000).contains(budget.maxCollisionQueries),
              budget.clearanceMM.isFinite && (0...100).contains(budget.clearanceMM),
              budget.sampleSpacingMM.isFinite && (0.01...100).contains(budget.sampleSpacingMM),
              budget.maxRotationDegPerSample.isFinite && (0.05...180).contains(budget.maxRotationDegPerSample) else {
            throw ManufacturingError.invalid("machine query version, motion or budget")
        }
        try chain.baseFrame?.validate()
        for b in bodies+fixtures { try b.frame?.validate(); try b.attach?.frame?.validate() }
        // Detailed topology, travel and shape checks are authoritative in Rust.
        // Input JSON is bounded before crossing the native ABI.
        if let queryPairs,queryPairs.isEmpty { throw ManufacturingError.invalid("empty machine pair selection") }
    }
}

public struct MachineQueryResult:Codable,Equatable,Sendable {
    public struct ExcludedPair:Codable,Equatable,Sendable {
        public var a:String
        public var b:String
        public var reason:String
    }
    public struct PlacedBody:Codable,Equatable,Sendable {
        public var id:String
        public var resourceID:String?
        public var frame:MachineFrame
    }
    public struct Pose:Codable,Equatable,Sendable {
        public var t:Double
        public var jointValueMM:Double?
        public var jointValueDeg:Double?
        public var jointValues:[String:Double]?
        public var axes:[PlacedBody]
        public var bodies:[PlacedBody]
    }
    public struct Pair:Codable,Equatable,Sendable {
        public var a:String
        public var b:String
        public var state:String
        public var scope:String
        public var samplesPlanned:Int
        public var samplesEvaluated:Int
        public var firstSample:Int?
        public var firstTime:Double?
        public var firstJointValueMM:Double?
        public var firstJointValueDeg:Double?
        public var firstJointValues:[String:Double]?
        public var penetrationDepthMM:Double?
        public var minimumGapMM:Double?
        public var transformA:MachineFrame?
        public var transformB:MachineFrame?
    }
    public var ok:Bool
    public var backend:String
    public var scope:String
    public var samplesPlanned:Int
    public var samplesEvaluated:Int
    public var parryCalls:UInt64
    public var poses:[Pose]
    public var fixtures:[PlacedBody]
    public var pairs:[Pair]
    public var warnings:[String]
    public var motions:[MachineMotion]?
    public var jointPositions:[String:Double]?
    public var excludedPairs:[ExcludedPair]?
    public var hasCollisionCoverage:Bool { !pairs.isEmpty }
    public var hasInterference:Bool { pairs.contains { ["intersecting","clearance"].contains($0.state) } }
    public var hasUnresolvedQueries:Bool { pairs.contains { ["incomplete","uncertain"].contains($0.state) } }
    public func validate(for request:MachineQueryRequest) throws {
        guard ok,!backend.isEmpty,!scope.isEmpty,samplesPlanned >= 1,samplesPlanned <= request.budget.maxSamples,
              samplesEvaluated == samplesPlanned,poses.count == samplesPlanned+1,!poses.isEmpty,
              parryCalls <= UInt64(request.budget.maxCollisionQueries) else { throw ManufacturingError.native("invalid machine query result budget") }
        let allBodies = request.bodies+request.fixtures
        let dynamicIDs = Set(allBodies.filter { $0.attach != nil }.map(\.id))
        let staticIDs = Set(allBodies.filter { $0.attach == nil }.map(\.id))
        guard poses.first?.t == 0,poses.last?.t == 1,Set(fixtures.map(\.id)) == staticIDs,fixtures.count == staticIDs.count,
              motions == (request.motions ?? request.motion.map { [$0] }),
              jointPositions == (request.jointPositions ?? [:]) else { throw ManufacturingError.native("machine pose endpoint/input/fixture coverage") }
        for fixture in fixtures { try fixture.frame.validate() }
        var previousTime = -1.0
        for pose in poses {
            guard pose.t.isFinite,(0...1).contains(pose.t),
                  pose.t > previousTime,
                  Set(pose.axes.map(\.id)) == Set(request.chain.axes.map(\.id)),pose.axes.count == request.chain.axes.count,
                  Set(pose.bodies.map(\.id)) == dynamicIDs,pose.bodies.count == dynamicIDs.count,
                  Set(pose.jointValues?.keys.map { $0 } ?? []) == Set(request.chain.axes.map(\.id)),
                  (pose.jointValues?.values.allSatisfy(\.isFinite) ?? false) else { throw ManufacturingError.native("invalid machine pose") }
            previousTime = pose.t
            for item in pose.axes+pose.bodies { try item.frame.validate() }
        }
        let ids = Set((request.bodies+request.fixtures).map(\.id))
        func key(_ a:String,_ b:String)->String { [a,b].sorted().map { "\($0.utf8.count):\($0)" }.joined() }
        let allowed = Set((request.allowedContactPairs ?? []).filter { $0.count == 2 }.map { key($0[0],$0[1]) })
        guard let excludedPairs,excludedPairs.allSatisfy({ $0.reason == "allowed-contact" }),
              Set(excludedPairs.map { key($0.a,$0.b) }) == allowed,excludedPairs.count == allowed.count else { throw ManufacturingError.native("machine allowed contact receipt") }
        let sorted = ids.sorted()
        var expectedPairs = Set<String>()
        if let selected = request.queryPairs {
            expectedPairs = Set(selected.filter { $0.count == 2 }.map { key($0[0],$0[1]) })
        } else {
            for i in sorted.indices { for j in sorted.indices where j > i { expectedPairs.insert(key(sorted[i],sorted[j])) } }
        }
        expectedPairs.subtract(allowed)
        let actualPairs = pairs.map { key($0.a,$0.b) }
        guard Set(actualPairs).count == pairs.count,Set(actualPairs) == expectedPairs else { throw ManufacturingError.native("missing or duplicate machine collision pairs") }
        for pair in pairs {
            guard ids.contains(pair.a),ids.contains(pair.b),pair.a != pair.b,
                  ["clear","intersecting","clearance","incomplete","uncertain"].contains(pair.state),!pair.scope.isEmpty,
                  pair.samplesPlanned > 0,pair.samplesPlanned <= poses.count,
                  pair.samplesEvaluated >= 0,pair.samplesEvaluated <= pair.samplesPlanned,
                  (!["clear","clearance"].contains(pair.state) || pair.samplesEvaluated == pair.samplesPlanned),
                  (pair.penetrationDepthMM.map { $0.isFinite && $0 >= 0 } ?? true),
                  (pair.minimumGapMM.map { $0.isFinite && $0 >= 0 } ?? true),
                  (pair.firstTime.map { $0.isFinite && (0...1).contains($0) } ?? true) else { throw ManufacturingError.native("invalid machine collision pair") }
            if pair.state == "intersecting" {
                guard let sample = pair.firstSample,poses.indices.contains(sample),let time = pair.firstTime,
                      abs(poses[sample].t-time)<1e-12,pair.transformA != nil,pair.transformB != nil,
                      pair.firstJointValues == poses[sample].jointValues else { throw ManufacturingError.native("machine collision first-hit receipt") }
            }
            try pair.transformA?.validate(); try pair.transformB?.validate()
        }
    }
}

public extension NativeManufacturingEngine {
    func machineQuery(_ request:MachineQueryRequest,control:ComputationControl = .init()) throws -> MachineQueryResult {
        try request.validate(); try control.check()
        let data = try ManufacturingStudy.encoder.encode(request)
        guard data.count <= 32_000_000 else { throw ManufacturingError.invalid("machine geometry input byte budget") }
        let context = Unmanaged.passUnretained(control).toOpaque()
        let output = try String(decoding:data,as:UTF8.self).withCString { json -> Data in
            guard let pointer = fm_machine_query(json,nativeProgress,context) else { throw ManufacturingError.native("empty machine query response") }
            defer { fm_core_free(pointer) }
            return try checkedReply(pointer)
        }
        try control.check()
        var result = try JSONDecoder().decode(MachineQueryResult.self,from:output)
        result.warnings.append("Body queries use pinned Parry Float32 geometry at discrete poses; numerical geometry precision and motion between samples are not physical clearance certification.")
        try result.validate(for:request); return result
    }
}
