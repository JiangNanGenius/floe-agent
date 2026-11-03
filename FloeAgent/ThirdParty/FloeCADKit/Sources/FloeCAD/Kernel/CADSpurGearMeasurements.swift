// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd
import OCCTShim

nonisolated struct CADSpurGearMeasurements: Equatable, Sendable {
    var width: Double
    var tipRadius: Double
    var rootRadius: Double
    var boreRadius: Double
    var teeth: Int
    var meanPitchThickness: Double
    var minPitchThickness: Double
    var maxPitchThickness: Double
    var pressureDegrees: Double
    var volume: Double
    var polynomialCapEdges: Int
    var maxNativeTolerance: Double
    var dictionary: [String:Any] {
        ["width":width,"tip_diameter":2*tipRadius,"root_diameter":2*rootRadius,"bore_diameter":2*boreRadius,
         "measured_teeth":teeth,"mean_pitch_tooth_thickness":meanPitchThickness,
         "minimum_pitch_tooth_thickness":minPitchThickness,"maximum_pitch_tooth_thickness":maxPitchThickness,
         "measured_pressure_degrees":pressureDegrees,"native_volume":volume,
         "polynomial_lower_cap_edges":polynomialCapEdges,"native_maximum_tolerance":maxNativeTolerance]
    }
}
nonisolated extension OCCTKernel {
    static func spurGearMeasurements(_ handle: BRepHandle, pitchRadius: Double) throws -> CADSpurGearMeasurements {
        let status=OCCTOpStatus()
        guard let data=OCCTBridge.spurGearMeasurements(of:handle.shape,pitchRadius:pitchRadius,status:status) else {
            throw CADMechanicalFailure.invalid("Native gear measurement refused: "+OCCTOpError(status).message)
        }
        let v=data.withUnsafeBytes { Array($0.bindMemory(to:Double.self)) }
        guard v.count==12,v.allSatisfy(\.isFinite),let teeth=Int(exactly:v[4]),let edges=Int(exactly:v[10]) else {
            throw CADMechanicalFailure.invalid("Invalid native gear measurement record.")
        }
        return .init(width:v[0],tipRadius:v[1],rootRadius:v[2],boreRadius:v[3],teeth:teeth,
            meanPitchThickness:v[5],minPitchThickness:v[6],maxPitchThickness:v[7],pressureDegrees:v[8],
            volume:v[9],polynomialCapEdges:edges,maxNativeTolerance:v[11])
    }
    static func gearBoundaryDistances(_ handle: BRepHandle, points: [SIMD3<Double>], faces: [Int]) throws -> [Double] {
        let status=OCCTOpStatus()
        let flat=points.flatMap { [$0.x,$0.y,$0.z] }
        let data=flat.withUnsafeBytes { Data($0) }
        guard let result=OCCTBridge.gearBoundaryDistances(of:handle.shape,points:data,faceIndices:packIndices(faces),status:status) else {
            throw CADMechanicalFailure.invalid("Native gear witness refused: "+OCCTOpError(status).message)
        }
        let distances=result.withUnsafeBytes { Array($0.bindMemory(to:Double.self)) }
        guard distances.count==points.count,distances.allSatisfy({ $0.isFinite && $0>=0 }) else {
            throw CADMechanicalFailure.invalid("Invalid native gear witness record.")
        }
        return distances
    }
}
