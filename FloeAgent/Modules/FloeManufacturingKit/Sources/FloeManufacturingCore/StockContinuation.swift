// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Sampled occupancy, not a mesh or an analytic solid. Grid cells retain their
/// identities when the part moves between spindles. All coordinates are mm.
public struct ManufacturingStockState: Codable, Equatable, Sendable {
    public var formatVersion = 1
    public var dimensions: [Int]
    public var originMM: [Double]
    public var resolutionMM: Double
    public var shape: String
    public var radiusMM: Double?
    public var declaredMaxMM: [Double]? = nil
    public var occupiedIndices: [Int]
    public var removedCount: UInt64
    public init(dimensions:[Int],originMM:[Double],resolutionMM:Double,shape:String,radiusMM:Double? = nil,occupiedIndices:[Int],removedCount:UInt64 = 0,declaredMaxMM:[Double]? = nil) {
        self.dimensions = dimensions; self.originMM = originMM; self.resolutionMM = resolutionMM
        self.shape = shape; self.radiusMM = radiusMM; self.occupiedIndices = occupiedIndices; self.removedCount = removedCount
        self.declaredMaxMM = declaredMaxMM
    }
    public var remainingMM3: Double { Double(occupiedIndices.count)*resolutionMM*resolutionMM*resolutionMM }
    public func fingerprint() throws -> String { ManufacturingStudy.digest(try ManufacturingStudy.encoder.encode(self)) }

    public func validate(for study:ManufacturingStudy) throws {
        func require(_ condition:Bool,_ message:String) throws {
            if !condition { throw ManufacturingError.invalid("material checkpoint: "+message) }
        }
        let bounds = study.stock.bounds, h = study.stock.resolutionMM
        try require(h.isFinite && h > 0 && bounds.min.count == 3 && bounds.max.count == 3 &&
                    zip(bounds.min,bounds.max).allSatisfy { $0.isFinite && $1.isFinite && $0 < $1 && ($1-$0)/h < 1_000_000 },"study envelope")
        try require(formatVersion == 1 && dimensions.count == 3 && originMM.count == 3,"version/grid")
        try require(resolutionMM.isFinite && resolutionMM > 0 && abs(resolutionMM-h) < 1e-12,"resolution")
        try require(zip(originMM,bounds.min).allSatisfy { $0.isFinite && abs($0-$1) < 1e-9 },"origin")
        if let declaredMaxMM {
            try require(declaredMaxMM.count == 3 && zip(declaredMaxMM,bounds.max).allSatisfy { $0.isFinite && abs($0-$1) < 1e-9 },"declared end planes")
        }
        let expected = zip(bounds.min,bounds.max).map { Int(ceil(($1-$0)/h)) }
        try require(dimensions == expected && dimensions.allSatisfy { $0 > 0 && $0 <= study.budget.maxCells },"dimensions")
        let product = dimensions.reduce(1.0) { $0*Double($1) }
        try require(product <= Double(study.budget.maxCells) && occupiedIndices.count <= study.budget.maxCells,"cell budget")
        try require(shape == (study.stock.isBox ? "box" : "cylinder"),"shape")
        if shape == "cylinder" {
            try require(radiusMM?.isFinite == true && abs((radiusMM ?? 0)-study.stock.radiusMM) < 1e-9,"radius")
        } else { try require(radiusMM == nil,"box radius") }
        let nx = dimensions[0], ny = dimensions[1], count = Int(product)
        func inside(_ index:Int) -> Bool {
            if shape == "box" { return true }
            let x = originMM[0]+(Double(index%nx)+0.5)*h
            let y = originMM[1]+(Double((index/nx)%ny)+0.5)*h
            return x*x+y*y <= study.stock.radiusMM*study.stock.radiusMM
        }
        var last = -1
        for index in occupiedIndices {
            try require(index > last && index < count && inside(index),"duplicate, unordered or outside-envelope cell")
            last = index
        }
        let originalCount = (0..<count).reduce(0) { $0+(inside($1) ? 1 : 0) }
        try require(removedCount <= UInt64(originalCount) && UInt64(occupiedIndices.count)+removedCount == UInt64(originalCount),"occupancy conservation")
    }

    public func validateContinuation(from previous:Self) throws {
        guard formatVersion == previous.formatVersion, dimensions == previous.dimensions,
              originMM == previous.originMM, resolutionMM == previous.resolutionMM,
              shape == previous.shape, radiusMM == previous.radiusMM,
              occupiedIndices.count <= previous.occupiedIndices.count,
              removedCount >= previous.removedCount,
              removedCount-previous.removedCount == UInt64(previous.occupiedIndices.count-occupiedIndices.count) else {
            throw ManufacturingError.native("material changed grids or broke cumulative conservation")
        }
        if let maximum=previous.declaredMaxMM {
            guard declaredMaxMM == maximum else { throw ManufacturingError.native("material changed its declared stock end planes") }
        } else if let maximum=declaredMaxMM {
            guard maximum.count == 3,originMM.count == 3,dimensions.count == 3,
                  (0..<3).allSatisfy({ maximum[$0].isFinite && abs(maximum[$0]-(originMM[$0]+Double(dimensions[$0])*resolutionMM)) < 1e-9 }) else {
                throw ManufacturingError.native("legacy material has ambiguous non-grid-aligned end planes; regenerate before continuation")
            }
        }
        var cursor = 0
        for index in occupiedIndices {
            while cursor < previous.occupiedIndices.count && previous.occupiedIndices[cursor] < index { cursor += 1 }
            guard cursor < previous.occupiedIndices.count, previous.occupiedIndices[cursor] == index else {
                throw ManufacturingError.native("removed material was restored by a later job")
            }
            cursor += 1
        }
    }

    /// Fresh continuation must know the physical envelope. Archive-only validation
    /// above stays compatible with historical saved meshes/checkpoints.
    public func validateFreshContinuation(for study:ManufacturingStudy) throws {
        try validate(for:study)
        if declaredMaxMM == nil {
            let maximum=study.stock.bounds.max
            guard (0..<3).allSatisfy({ abs(originMM[$0]+Double(dimensions[$0])*resolutionMM-maximum[$0]) < 1e-9 }) else {
                throw ManufacturingError.invalid("material checkpoint needs regeneration to retain its declared stock end planes")
            }
        }
    }
}
