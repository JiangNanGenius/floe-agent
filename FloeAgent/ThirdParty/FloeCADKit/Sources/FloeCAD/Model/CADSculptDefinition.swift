// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd

/// Authored mesh multiresolution data. Each level adds local-space vector
/// detail to the existing Catmull-Clark refinement of its edited parent.
/// Switching down/up retains higher detail; it never substitutes a BRep.
nonisolated struct CADSculptDefinition:Codable,Equatable,Sendable {
    static let supportedVersion=1
    static let maxLevels=4
    static let maxFaces=32_768
    static let maxVertices=32_768
    nonisolated struct Offset:Codable,Equatable,Sendable { var vertex:UUID;var vector:SIMD3<Double> }
    nonisolated struct Weight:Codable,Equatable,Sendable { var vertex:UUID;var value:Double }
    nonisolated struct Level:Codable,Equatable,Sendable,Identifiable {
        var id=UUID()
        var offsets:[Offset]=[]
        /// Explicit weights override inherited masks, including zero (unmask).
        var mask:[Weight]=[]
    }
    var version=1
    var sourceDigest:String
    var base:CADPolygonCage
    var levels:[Level]=[Level()]
    var activeLevel=0
    func validate() throws {
        guard version==Self.supportedVersion,sourceDigest.count==64,
              (1...Self.maxLevels).contains(levels.count),levels.indices.contains(activeLevel),
              Set(levels.map(\.id)).count==levels.count,base.faces.count<=2048,base.vertices.count<=4096,
              levels.reduce(0,{ $0+$1.offsets.count+$1.mask.count })<=65_536 else { throw CADPolygonFailure.invalid("The sculpt hierarchy exceeds its bounds or has an unsupported version.") }
        try base.validate(limit:Self.maxFaces,planarConvex:false)
        for level in levels {
            guard level.offsets.count<=Self.maxVertices,level.mask.count<=Self.maxVertices,
                  Set(level.offsets.map(\.vertex)).count==level.offsets.count,Set(level.mask.map(\.vertex)).count==level.mask.count,
                  level.offsets.allSatisfy({ [$0.vector.x,$0.vector.y,$0.vector.z].allSatisfy { $0.isFinite && abs($0)<=1e6 } }),
                  level.mask.allSatisfy({ $0.value.isFinite && (0...1).contains($0.value) }) else { throw CADPolygonFailure.invalid("A sculpt level contains invalid vertex detail or mask weights.") }
        }
    }
}
nonisolated struct CADSculptBrush:Codable,Equatable,Sendable {
    nonisolated enum Mode:String,Codable,CaseIterable,Sendable { case inflate,smooth,mask,unmask }
    var mode:Mode = .inflate
    /// Local mesh millimetres; transform scale is applied by the viewport.
    var radius:Double=2
    var strength:Double=0.5
    var inverted:Bool=false
    func validate() throws {
        guard radius.isFinite,(1e-4...10000).contains(radius),strength.isFinite,(0...1).contains(strength) else { throw CADPolygonFailure.invalid("Use a finite brush radius and strength from zero to one.") }
    }
}
nonisolated struct CADSculptSample:Codable,Equatable,Sendable {
    /// Render triangle identity belongs to the pinned cageDigest/generation.
    var triangle:Int
    var barycentric:SIMD3<Double>
    var pressure:Double
    func validate() throws {
        let p=barycentric
        guard triangle>=0,pressure.isFinite,(0...1).contains(pressure),[p.x,p.y,p.z].allSatisfy({ $0.isFinite && $0>=0 && $0<=1 }),abs(p.x+p.y+p.z-1)<=1e-8 else { throw CADPolygonFailure.invalid("A sculpt sample needs a current triangle, barycentric weights and pressure from zero to one.") }
    }
}
nonisolated struct CADSculptStroke:Codable,Equatable,Sendable {
    var brush:CADSculptBrush
    var samples:[CADSculptSample]
    func validate() throws {
        try brush.validate()
        guard (1...256).contains(samples.count) else { throw CADPolygonFailure.invalid("A sculpt stroke supports one to 256 bounded samples.") }
        for sample in samples { try sample.validate() }
    }
}
nonisolated enum CADSculptEdit:Sendable {
    case begin,stroke(CADSculptStroke),subdivide,level(Int),clearMask
}
