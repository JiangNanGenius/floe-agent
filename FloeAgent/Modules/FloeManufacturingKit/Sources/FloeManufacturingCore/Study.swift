// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import FloeManufacturingParameters

public enum ManufacturingError: Error, LocalizedError, Sendable {
    case invalid(String), native(String), cancelled, stale, archive(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "Invalid manufacturing input: \(reason)"
        case .native(let reason): return "Calculation failed: \(reason)"
        case .cancelled: return "Calculation cancelled"
        case .stale: return "The workpiece has changed. Calculate again before saving."
        case .archive(let reason): return "Unable to open manufacturing file: \(reason)"
        }
    }
}

public enum TurningApproach:String,Codable,Equatable,Sendable,CaseIterable { case positiveZ,negativeZ }

public struct ProfilePoint: Codable, Equatable, Sendable {
    public var radiusMM: Double
    public var zMM: Double
    public init(_ radiusMM: Double, _ zMM: Double) { self.radiusMM = radiusMM; self.zMM = zMM }
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        radiusMM = try c.decode(Double.self); zMM = try c.decode(Double.self)
        guard c.isAtEnd else { throw ManufacturingError.invalid("profile point requires radius and Z") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer(); try c.encode(radiusMM); try c.encode(zMM)
    }
}

public struct ManufacturingStudy: Codable, Equatable, Sendable, Identifiable {
    public struct Source: Codable, Equatable, Sendable {
        public var documentID: String
        public var revision: Int
        public var contentSHA256: String
        public init(documentID:String,revision:Int,contentSHA256:String) { self.documentID = documentID; self.revision = revision; self.contentSHA256 = contentSHA256 }
    }
    public struct Stock: Codable, Equatable, Sendable {
        public var radiusMM = 12.0
        public var zMinMM = 0.0
        public var zMaxMM = 40.0
        public var resolutionMM = 1.0
        public var shape: String?
        public var minMM: [Double]?
        public var maxMM: [Double]?
        public var isBox: Bool { shape == "box" }
        public var bounds: (min:[Double],max:[Double]) {
            if isBox, let minMM, let maxMM, minMM.count == 3, maxMM.count == 3 { return (minMM,maxMM) }
            return ([-radiusMM,-radiusMM,zMinMM],[radiusMM,radiusMM,zMaxMM])
        }
    }
    public struct Turning: Codable, Equatable, Sendable {
        public var enabled = true
        public var stepOverMM = 1.0
        public var allowanceMM = 0.2
        public var finishPasses = 1
        public var toolNoseRadiusMM = 0.4
        public var feedMMPerMinute = 120.0
    }
    public struct Milling: Codable, Equatable, Sendable {
        public var enabled = false
        public var angleDegrees = 0.0
        public var widthMM = 4.0
        public var depthMM = 2.0
        public var startZMM = 18.0
        public var endZMM = 26.0
        public var toolRadiusMM = 2.0
        public var toolLengthMM = 15.0
        public var feedMMPerMinute = 250.0
    }
    public struct Fixture: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var minMM: [Double]
        public var maxMM: [Double]
        public init(id: String, minMM: [Double], maxMM: [Double]) { self.id = id; self.minMM = minMM; self.maxMM = maxMM }
    }
    public struct Budget: Codable, Equatable, Sendable {
        public var maxCells = 131_072
        public var maxPoses = 12_000
        public var maxTriangles = 180_000
        public var maxCollisionQueries: Int?
        public var maxFrames: Int?
        public var maxRetainedMeshBytes: Int?
        public var frameLimit: Int { maxFrames ?? 8 }
        public var retainedMeshByteLimit: Int { maxRetainedMeshBytes ?? 128_000_000 }
        public var collisionQueryLimit: Int { maxCollisionQueries ?? 500_000 }
    }
    public struct ACMotion: Codable, Equatable, Sendable {
        public var formatVersion = 1
        public var start: [Double]
        public var end: [Double]
        public var toolLengthMM: Double
        public var steps: Int
        public init(start: [Double], end: [Double], toolLengthMM: Double, steps: Int) {
            self.start = start; self.end = end; self.toolLengthMM = toolLengthMM; self.steps = steps
        }
    }
    public var formatVersion = 1
    public var id = UUID()
    public var name: String
    public var source: Source
    public var stock = Stock()
    public var profile: [ProfilePoint]
    public var turning = Turning()
    public var milling = Milling()
    public var fixtures: [Fixture] = [.init(id: "chuck", minMM: [-15,-15,-8], maxMM: [15,15,-2])]
    public var budget = Budget()
    public var acMotion: ACMotion?
    public var millingAssembly: MillingToolAssembly?
    /// Optional single-spindle speed/feed schedule. Absence preserves legacy archives.
    public var turningCutting: TurningCuttingParameters?
    public var turningSetup: TurningSetup?
    /// Local machining +Z may face either end of the immutable part frame.
    public var turningApproach: TurningApproach?
    public var turningToolID: String?
    public var millingToolID: String?
    public var cam: ManufacturingCAM?
    public var processRequirements: TurningProcessRequirements?
    public var processAssessmentEnabled: Bool?
    public var isProcessAssessmentEnabled: Bool { processRequirements != nil && processAssessmentEnabled != false }
    /// Extra configuration; typed study fields own the active native values.
    /// The editor projects those fields into a complete parameter snapshot.
    public var parameters: ManufacturingParameterSet?

    public init(id:UUID = UUID(),name:String,source:Source,profile:[ProfilePoint]) {
        self.id = id; self.name = name; self.source = source; self.profile = profile
    }

    public static func shaft(milled: Bool = false) -> Self {
        let profile = [ProfilePoint(10,0), .init(10,15), .init(7,15), .init(7,28), .init(5,28), .init(5,38)]
        var study = Self(name: milled ? "车铣件" : "阶梯轴", source: .init(documentID: "fixture:shaft-v1", revision: 1, contentSHA256: digest(Data("shaft-r10-7-5-z0-15-28-38".utf8))), profile: profile)
        study.milling.enabled = milled
        return study
    }
    public static func fiveAxis() -> Self {
        var study = shaft()
        study.name = "A/C 五轴轨迹"
        study.turning.enabled = false
        study.stock.radiusMM = 16; study.stock.zMinMM = -2; study.stock.zMaxMM = 8
        study.profile = [.init(16,-2),.init(16,8)]
        study.source = .init(documentID: "fixture:physical-trunnion-stage7-joints", revision: 1, contentSHA256:"4c5771216374b4d7b3257e407bf47b222dd5f43bb8523be25cf869d0f85d1f93")
        study.milling.toolLengthMM = 6
        study.milling.startZMM = -1; study.milling.endZMM = 7
        study.acMotion = .init(start: [10,0,40,20,-170], end: [10,0,40,40,170], toolLengthMM: 40, steps: 160)
        study.fixtures = [.init(id:"trunnion-fixture",minMM:[-18,-18,-6],maxMM:[18,18,-2])]
        return study
    }
    public static func holderInterference() -> Self {
        var study = shaft(milled:true)
        study.name = "刀柄干涉例"
        study.milling.startZMM = 2; study.milling.endZMM = 36
        study.millingAssembly = .demonstration(cuttingLengthMM:study.milling.toolLengthMM)
        study.fixtures = [.init(id:"holder-only",minMM:[35.5,-0.3,21.7],maxMM:[36.5,0.3,22.3])]
        return study
    }
    public func validate(requireOperations:Bool = true) throws {
        func require(_ condition: Bool, _ reason: String) throws { if !condition { throw ManufacturingError.invalid(reason) } }
        func finite(_ xs: [Double]) -> Bool { xs.allSatisfy { $0.isFinite && abs($0) <= 100_000 } }
        try require(formatVersion == 1, "unsupported version; keep original file")
        try require(!name.isEmpty && name.utf8.count <= 512, "name")
        try require(!source.documentID.isEmpty && source.revision >= 0 && source.contentSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, "source identity")
        try require(finite([stock.radiusMM,stock.zMinMM,stock.zMaxMM,stock.resolutionMM]) && stock.radiusMM > 0 && stock.zMaxMM > stock.zMinMM && (0.1...4).contains(stock.resolutionMM), "stock dimensions or resolution")
        try require((1...131_072).contains(budget.maxCells) && (2...12_000).contains(budget.maxPoses) && (12...180_000).contains(budget.maxTriangles), "budget")
        try require((1...500_000).contains(budget.collisionQueryLimit), "collision query budget")
        if let millingAssembly { try millingAssembly.validate(cuttingLengthMM:milling.toolLengthMM) }
        if let turningCutting { try turningCutting.validate() }
        if let turningSetup { try turningSetup.validate(requireOperations:turning.enabled) }
        try cam?.validate()
        for toolID in [turningToolID,millingToolID].compactMap({ $0 }) {
            try require(!toolID.isEmpty && toolID.utf8.count <= 256,"legacy tool identity")
        }
        try processRequirements?.validate()
        if isProcessAssessmentEnabled, let processRequirements { _ = try TurningProcessAssessment.evaluate(study:self,requirements:processRequirements) }
        try require(stock.shape == nil || ["cylinder","box"].contains(stock.shape!), "stock shape")
        if stock.isBox {
            try require(!turning.enabled && !milling.enabled, "box stock requires feature CAM; cylindrical turning/slot is unavailable")
            guard let lo = stock.minMM, let hi = stock.maxMM else { throw ManufacturingError.invalid("box stock bounds") }
            try require(lo.count == 3 && hi.count == 3 && finite(lo+hi) && zip(lo,hi).allSatisfy { $0.0 < $0.1 }, "box stock bounds")
            try require(abs(lo[2]-stock.zMinMM) <= 1e-9 && abs(hi[2]-stock.zMaxMM) <= 1e-9, "box stock Z bounds")
        } else { try require(stock.minMM == nil && stock.maxMM == nil,"cylinder stock cannot contain box bounds") }
        try require((1...16).contains(budget.frameLimit) && (1...256_000_000).contains(budget.retainedMeshByteLimit),"retained frame budget")
        let bounds = stock.bounds
        let dimensions = zip(bounds.min,bounds.max).map { ceil(($1-$0)/stock.resolutionMM)+1 }
        try require(dimensions.reduce(1,*) <= Double(budget.maxCells), "stock exceeds cell budget")
        try require((2...256).contains(profile.count), "profile count")
        for (index,p) in profile.enumerated() {
            try require(finite([p.radiusMM,p.zMM]) && p.radiusMM >= 0 && ((!turning.enabled && !milling.enabled) || (p.radiusMM <= stock.radiusMM && (stock.zMinMM...stock.zMaxMM).contains(p.zMM))), "profile radius/Z")
            if index > 0 { try require(p.zMM >= profile[index-1].zMM && p != profile[index-1], "profile order/duplicate point") }
        }
        try require(profile.last!.zMM > profile.first!.zMM, "profile extent")
        if turning.enabled {
            try require(finite([turning.stepOverMM,turning.allowanceMM,turning.toolNoseRadiusMM,turning.feedMMPerMinute]) && turning.stepOverMM >= 0.05 && turning.stepOverMM <= stock.radiusMM && turning.allowanceMM >= 0 && turning.allowanceMM < stock.radiusMM && abs(turning.toolNoseRadiusMM-0.4) < 1e-9 && turning.feedMMPerMinute > 0 && (1...5).contains(turning.finishPasses), "turning settings; nominal nose remains 0.4 mm without compensation")
        }
        if milling.enabled {
            let widthMessage = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "当前单趟铣槽需要槽宽等于刀具直径。请同时调整槽宽与刀具半径。" : "This single-pass slot requires its width to equal the tool diameter. Adjust slot width and tool radius together."
            try require(abs(milling.widthMM-2*milling.toolRadiusMM) < 1e-9,widthMessage)
            try require(finite([milling.angleDegrees,milling.widthMM,milling.depthMM,milling.startZMM,milling.endZMM,milling.toolRadiusMM,milling.toolLengthMM,milling.feedMMPerMinute]) && abs(milling.widthMM-2*milling.toolRadiusMM) < 1e-9 && milling.toolRadiusMM > 0 && milling.toolLengthMM > 0 && milling.depthMM > 0 && milling.depthMM < stock.radiusMM && milling.startZMM < milling.endZMM && milling.startZMM >= stock.zMinMM && milling.endZMM <= stock.zMaxMM && milling.feedMMPerMinute > 0, "milling settings; single-pass slot width must equal tool diameter")
        }
        try require(fixtures.count <= 16, "fixture count")
        for f in fixtures {
            try require(!f.id.isEmpty && f.minMM.count == 3 && f.maxMM.count == 3 && finite(f.minMM+f.maxMM) && zip(f.minMM,f.maxMM).allSatisfy { $0.0 < $0.1 }, "fixture bounds")
        }
        if let acMotion {
            try require(finite([milling.toolRadiusMM,milling.toolLengthMM]) && milling.toolRadiusMM > 0 && milling.toolLengthMM > 0,"A/C cutting radius and length")
            try require(acMotion.formatVersion == 1 && acMotion.start.count == 5 && acMotion.end.count == 5 && finite(acMotion.start+acMotion.end) && acMotion.toolLengthMM.isFinite && acMotion.toolLengthMM > 0 && (1...4096).contains(acMotion.steps) && acMotion.steps < budget.maxPoses, "AC motion")
        }
        if requireOperations { try require(turning.enabled || milling.enabled || acMotion != nil || !(cam?.enabledOperations.isEmpty ?? true), "no operations") }
        try validateParameterStorage()
    }
    public func encoded() throws -> Data { try Self.encoder.encode(self) }
    public func fingerprint() throws -> String { Self.digest(try encoded()) }
    public static var encoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public struct ManufacturingResult: Codable, Sendable, Equatable {
    public struct Path: Codable, Sendable, Equatable {
        public var kind: String
        public var points: [[Double]]
        public var feedMMPerMinute: Double?
        public var operationID: String?
        public var toolID: String?
        public var moveType: String?
        public var toolAxes: [[Double]]?
        public var joints: [[Double]]?
        public var dwellSeconds: Double?
        public init(kind:String,points:[[Double]],feedMMPerMinute:Double? = nil,
                    operationID:String? = nil,toolID:String? = nil,moveType:String? = nil,
                    toolAxes:[[Double]]? = nil,joints:[[Double]]? = nil,dwellSeconds:Double? = nil) {
            self.kind = kind; self.points = points; self.feedMMPerMinute = feedMMPerMinute
            self.operationID = operationID; self.toolID = toolID; self.moveType = moveType
            self.toolAxes = toolAxes; self.joints = joints; self.dwellSeconds = dwellSeconds
        }
    }
    public struct Stage: Codable, Sendable, Equatable {
        public var name: String
        public var remainingMM3: Double
        public var removedMM3: Double
    }
    public struct Collision: Codable, Sendable, Equatable {
        public var component: String
        public var state: String
        public var message: String
        public var toolPart: String?
        public var targetKind: String?
        public var operation: String?
        public var firstPoseIndex: Int?
        public var minimumGapLowerBoundMM: Double?
        public var geometryErrorMM: Double?
    }
    public struct Pose: Codable, Sendable, Equatable {
        public var tipMM: [Double]
        public var axis: [Double]
        public var joints: [Double]
    }
    public struct Frame: Codable, Sendable, Equatable {
        public var name: String
        public var vertices: [[Double]]
        public var triangles: [[Int]]
    }
    public var ok: Bool
    public var backend: String
    public var initialMM3: Double
    public var analyticInitialMM3: Double?
    public var remainingMM3: Double
    public var removedMM3: Double
    public var vertices: [[Double]]
    public var triangles: [[Int]]
    public var paths: [Path]
    public var stages: [Stage]
    public var collisions: [Collision]
    public var warnings: [String]
    public var capabilities: [String]
    public var acPoses: [Pose]?
    public var frames: [Frame]?
    public var assemblyQueryCount: UInt64?
    public var cuttingTimeline: CuttingTimeline?
    public var turningSetupReceipt: TurningSetup.Receipt?
    public var camReport: [CAMReport]?
    public var sampledCamPoses: Int?
    /// Exact sampled material checkpoint, in immutable workpiece coordinates.
    /// Absent in older native results and archives.
    public var stockState: ManufacturingStockState?
    public var processAssessment: TurningProcessAssessment?
    public struct CAMReport: Codable, Sendable, Equatable {
        public var operationID: String
        public var strategy: String
        public var toolID: String
        public var generatedPoints: Int
        public var cutPoses: Int
        public var remainingMM3: Double
        public var removedMM3: Double
        public var sources: [String]
        public var limits: [String]
    }

    public func validate(for study: ManufacturingStudy) throws {
        if study.turning.enabled,study.turningApproach == .negativeZ,
           !capabilities.contains("negative-z-turning-envelope") { throw ManufacturingError.native("native component lacks negative-Z turning support") }
        for path in paths {
            if path.kind.hasPrefix("turning-") && path.toolID != study.turningToolID { throw ManufacturingError.native("turning path tool identity") }
            if path.kind == "milling-slot" && path.toolID != study.millingToolID { throw ManufacturingError.native("live-tool path identity") }
        }
        let expectedAssessment = try (study.isProcessAssessmentEnabled ? study.processRequirements : nil).map { try TurningProcessAssessment.evaluate(study:study,requirements:$0) }
        guard processAssessment == expectedAssessment else { throw ManufacturingError.native("missing or inconsistent process assessment") }
        try validateCAM(for:study)
        if (study.turningCutting != nil && study.turning.enabled) || !(study.cam?.enabledOperations.isEmpty ?? true) {
            let expected = try CuttingTimeline.plan(paths:paths,study:study)
            guard cuttingTimeline == expected else { throw ManufacturingError.native("missing or inconsistent motion timeline") }
        } else if cuttingTimeline != nil { throw ManufacturingError.native("unexpected motion timeline") }
        guard ok, initialMM3.isFinite, remainingMM3.isFinite, removedMM3.isFinite,
              initialMM3 >= 0, remainingMM3 >= 0, removedMM3 >= 0,
              abs(initialMM3-remainingMM3-removedMM3) < max(0.01,initialMM3*1e-8),
              (remainingMM3 == 0 || (!vertices.isEmpty && !triangles.isEmpty)), triangles.count <= study.budget.maxTriangles,
              vertices.count <= study.budget.maxTriangles*3 else { throw ManufacturingError.native("invalid output quantities/mesh budget") }
        if let stockState {
            try stockState.validate(for:study)
            guard abs(stockState.remainingMM3-remainingMM3) < max(0.01,remainingMM3*1e-8) else {
                throw ManufacturingError.native("remaining material checkpoint volume mismatch")
            }
        } else if initialMM3 == 0 { throw ManufacturingError.native("empty material requires a checkpoint") }
        func point(_ p: [Double]) -> Bool { p.count == 3 && p.allSatisfy { $0.isFinite && abs($0) <= 100_000 } }
        guard vertices.allSatisfy(point), triangles.allSatisfy({ $0.count == 3 && $0.allSatisfy { vertices.indices.contains($0) } && Set($0).count == 3 }),
              paths.allSatisfy({ $0.points.allSatisfy(point) }),
              collisions.allSatisfy({ collision in ["clear","intersecting","uncertain","clearance"].contains(collision.state) &&
                  (collision.toolPart == nil || ["cutter","shank","holder","turningNose"].contains(collision.toolPart!)) &&
                  (collision.targetKind == nil || ["fixture","stock"].contains(collision.targetKind!)) &&
                  (collision.operation == nil || ["milling","ac","turning"].contains(collision.operation!) || study.cam?.enabledOperations.contains(where: { op in collision.operation == op.id || collision.operation == "cam:"+op.id }) == true) &&
                  (collision.firstPoseIndex == nil || collision.firstPoseIndex! >= 0) &&
                  (collision.minimumGapLowerBoundMM == nil || collision.minimumGapLowerBoundMM!.isFinite) &&
                  (collision.geometryErrorMM == nil || (collision.geometryErrorMM!.isFinite && collision.geometryErrorMM! >= 0)) }),
              stages.allSatisfy({ $0.remainingMM3.isFinite && $0.removedMM3.isFinite && $0.remainingMM3 >= 0 && $0.removedMM3 >= 0 }) else { throw ManufacturingError.native("invalid mesh, paths or collision status") }
        if let acPoses { guard acPoses.allSatisfy({ point($0.tipMM) && point($0.axis) && abs($0.axis.reduce(0) { $0+$1*$1 }-1) < 1e-3 && $0.joints.count == 5 && $0.joints.allSatisfy(\.isFinite) }) else { throw ManufacturingError.native("invalid AC poses") } }
        guard (1...500_000).contains(study.budget.collisionQueryLimit) else { throw ManufacturingError.native("invalid collision query budget") }
        if let assemblyQueryCount, assemblyQueryCount > UInt64(study.budget.collisionQueryLimit) { throw ManufacturingError.native("collision query budget exceeded") }
        if let assembly = study.millingAssembly {
            try assembly.validate(cuttingLengthMM:study.milling.toolLengthMM)
            let operations = (study.milling.enabled ? ["milling"] : []) + (study.acMotion != nil ? ["ac"] : [])
            if !operations.isEmpty {
                guard assemblyQueryCount != nil else { throw ManufacturingError.native("native component did not report requested tool-assembly checks") }
                let bodyParts = (assembly.holderProfile.first!.axialMM-study.milling.toolLengthMM > 1e-9 ? ["shank"] : []) + ["holder"]
                for operation in operations {
                    func has(_ part:String,_ target:String,_ component:String) -> Bool {
                        collisions.contains { $0.operation == operation && $0.toolPart == part && $0.targetKind == target && $0.component == component }
                    }
                    for part in bodyParts {
                        guard has(part,"stock","remaining-stock") else { throw ManufacturingError.native("missing \(operation) \(part) stock check") }
                    }
                    for fixture in study.fixtures {
                        for part in ["cutter"]+bodyParts {
                            guard has(part,"fixture",fixture.id) else { throw ManufacturingError.native("missing \(operation) \(part) fixture check") }
                        }
                    }
                }
            }
        }
        if let frames {
            guard frames.count <= study.budget.frameLimit,
                  frames.reduce(0,{ $0+$1.vertices.count*24+$1.triangles.count*12 }) <= study.budget.retainedMeshByteLimit, frames.allSatisfy({ f in
                f.triangles.count <= study.budget.maxTriangles && f.vertices.count <= study.budget.maxTriangles*3 && f.vertices.allSatisfy(point) && f.triangles.allSatisfy { t in t.count == 3 && t.allSatisfy { f.vertices.indices.contains($0) } && Set(t).count == 3 }
            }) else { throw ManufacturingError.native("invalid replay frames") }
        }
    }
}

public struct ManufacturingArtifact: Codable, Sendable, Equatable {
    public var studyID: UUID
    public var inputSHA256: String
    public var result: ManufacturingResult
    public var elapsedSeconds: Double
    public var processPeakBytes: UInt64
    public var startingStockSHA256: String? = nil
}
