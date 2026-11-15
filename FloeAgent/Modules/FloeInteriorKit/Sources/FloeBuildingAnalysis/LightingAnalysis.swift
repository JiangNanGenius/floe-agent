// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct LightingLuminaire: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var positionM: AnalysisVector3
    public var aim: AnalysisVector3
    public var c0Direction: AnalysisVector3
    public var outputScale: Double
    public var photometry: IESPhotometry
    public init(id:String,positionM:AnalysisVector3,aim:AnalysisVector3 = .init(0,0,-1),
                c0Direction:AnalysisVector3 = .init(1,0,0),outputScale:Double=1,photometry:IESPhotometry) {
        self.id=id;self.positionM=positionM;self.aim=aim;self.c0Direction=c0Direction
        self.outputScale=outputScale;self.photometry=photometry
    }
}

public struct LightingOccluder: Codable, Equatable, Sendable {
    public var id: String
    public var minimumM: AnalysisVector3
    public var maximumM: AnalysisVector3
    public init(id:String,minimumM:AnalysisVector3,maximumM:AnalysisVector3) {
        self.id=id;self.minimumM=minimumM;self.maximumM=maximumM
    }
    func validate() throws {
        guard !id.isEmpty,minimumM.isFinite,maximumM.isFinite,
              maximumM.x>minimumM.x,maximumM.y>minimumM.y,maximumM.z>minimumM.z else {
            throw BuildingAnalysisError.invalidInput("opaque occluder")
        }
    }
    func blocks(from start:AnalysisVector3,to end:AnalysisVector3)->Bool {
        let direction=end-start
        var low=1e-7,high=1-1e-7
        for (origin,delta,minimum,maximum) in [(start.x,direction.x,minimumM.x,maximumM.x),
            (start.y,direction.y,minimumM.y,maximumM.y),(start.z,direction.z,minimumM.z,maximumM.z)] {
            if abs(delta)<1e-12 {
                if origin<minimum || origin>maximum { return false }
            } else {
                let a=(minimum-origin)/delta,b=(maximum-origin)/delta
                low=max(low,min(a,b));high=min(high,max(a,b))
                if high<low { return false }
            }
        }
        return high>=low
    }
}

public struct LightingWorkplane: Codable, Equatable, Sendable {
    public var originM: AnalysisVector3
    public var right: AnalysisVector3
    public var up: AnalysisVector3
    public var widthM: Double
    public var heightM: Double
    public var columns: Int
    public var rows: Int
    public init(originM:AnalysisVector3,right:AnalysisVector3 = .init(1,0,0),
                up:AnalysisVector3 = .init(0,1,0),widthM:Double,heightM:Double,columns:Int,rows:Int) {
        self.originM=originM;self.right=right;self.up=up;self.widthM=widthM
        self.heightM=heightM;self.columns=columns;self.rows=rows
    }
    func basis() throws -> (AnalysisVector3,AnalysisVector3,AnalysisVector3) {
        guard originM.isFinite,widthM.isFinite,heightM.isFinite,widthM>0,heightM>0,
              widthM<=1000,heightM<=1000,columns>=2,rows>=2,columns<=40_000,rows<=40_000 else {
            throw BuildingAnalysisError.invalidInput("workplane")
        }
        let r=try right.normalized(),u=try up.normalized()
        guard abs(r.dot(u))<1e-8 else { throw BuildingAnalysisError.invalidInput("workplane axes") }
        return (r,u,try r.cross(u).normalized())
    }
}

public struct LightingAnalysisRequest: Codable, Equatable, Sendable {
    public var projectRevision: Int
    public var luminaires: [LightingLuminaire]
    public var opaqueBoxes: [LightingOccluder]
    public var workplane: LightingWorkplane
    public init(projectRevision:Int,luminaires:[LightingLuminaire],opaqueBoxes:[LightingOccluder]=[],workplane:LightingWorkplane) {
        self.projectRevision=projectRevision;self.luminaires=luminaires
        self.opaqueBoxes=opaqueBoxes;self.workplane=workplane
    }
    public func fingerprint() throws -> String { try BuildingAnalysisFingerprint.hash(self) }
}

public struct IlluminanceSample: Codable, Equatable, Sendable {
    public var positionM: AnalysisVector3
    public var lux: Double
}

public struct LightingAnalysisResult: Codable, Equatable, Sendable {
    public var inputFingerprint: String
    public var engine: String
    public var columns: Int
    public var rows: Int
    public var samples: [IlluminanceSample]
    public var minimumLux: Double
    public var maximumLux: Double
    public var averageLux: Double
    public var minimumToAverage: Double
    public var scope: String
    public var limitations: [String]
    public func isStale(for request:LightingAnalysisRequest) throws -> Bool {
        inputFingerprint != (try request.fingerprint())
    }
    public func csv() -> String {
        let locale=Locale(identifier:"en_US_POSIX")
        return "x_m,y_m,z_m,illuminance_lux\r\n"+samples.map {
            [ $0.positionM.x,$0.positionM.y,$0.positionM.z,$0.lux ].map { String(format:"%.6f",locale:locale,$0) }.joined(separator:",")
        }.joined(separator:"\r\n")+"\r\n"
    }
}

/// Direct point-by-point Type-C illuminance, with opaque AABB shadow checks.
/// Does not approximate interreflection/daylight by relabeling direct light.
public enum DirectLightingSolver {
    private struct Prepared {
        var source: LightingLuminaire
        var forward: AnalysisVector3
        var right: AnalysisVector3
        var up: AnalysisVector3
    }
    public static func solve(_ request:LightingAnalysisRequest,maximumCells:Int=40_000,
                             maximumRayChecks:Int=5_000_000,
                             cancelled:()->Bool = {false}) throws -> LightingAnalysisResult {
        let plane=try request.workplane.basis()
        let grid=request.workplane
        guard request.projectRevision>=0,!request.luminaires.isEmpty,request.luminaires.count<=256,
              Set(request.luminaires.map(\.id)).count==request.luminaires.count,
              request.opaqueBoxes.count<=4096,maximumCells>0,maximumRayChecks>0 else {
            throw BuildingAnalysisError.invalidInput("lighting request")
        }
        guard grid.columns<=maximumCells/grid.rows else { throw BuildingAnalysisError.budgetExceeded(grid.columns*grid.rows) }
        let count=grid.columns*grid.rows
        let perSample=request.luminaires.count*max(1,request.opaqueBoxes.count)
        guard count<=maximumRayChecks/perSample else { throw BuildingAnalysisError.budgetExceeded(count) }
        try request.opaqueBoxes.forEach{try $0.validate()}
        let lights=try request.luminaires.map { light -> Prepared in
            try light.photometry.validate()
            guard !light.id.isEmpty,light.positionM.isFinite,light.outputScale.isFinite,
                  (0...1).contains(light.outputScale) else { throw BuildingAnalysisError.invalidInput("luminaire") }
            let forward=try light.aim.normalized()
            let right=try (light.c0Direction-forward*light.c0Direction.dot(forward)).normalized()
            return .init(source:light,forward:forward,right:right,up:try right.cross(forward).normalized())
        }
        var samples:[IlluminanceSample]=[];samples.reserveCapacity(count)
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                if cancelled() { throw BuildingAnalysisError.cancelled }
                let point = grid.originM + plane.0 * (grid.widthM * Double(column) / Double(grid.columns-1))
                    + plane.1 * (grid.heightM * Double(row) / Double(grid.rows-1))
                var lux=0.0
                for light in lights {
                    let delta=point-light.source.positionM
                    guard delta.squaredLength.isFinite,delta.squaredLength>1e-12 else {
                        throw BuildingAnalysisError.invalidInput("workplane intersects light source")
                    }
                    let ray=try delta.normalized(),incidence=max(0,plane.2.dot(ray * -1))
                    if incidence==0 || light.source.outputScale==0 { continue }
                    if request.opaqueBoxes.contains(where:{$0.blocks(from:light.source.positionM,to:point)}) { continue }
                    let vertical=acos(min(1,max(-1,ray.dot(light.forward))))*180 / .pi
                    let horizontal=atan2(ray.dot(light.up),ray.dot(light.right))*180 / .pi
                    let cd=light.source.photometry.sample(verticalDegrees:vertical,horizontalDegrees:horizontal)
                    lux+=cd*incidence*light.source.outputScale/delta.squaredLength
                }
                guard lux.isFinite else { throw BuildingAnalysisError.invalidInput("nonfinite illuminance") }
                samples.append(.init(positionM:point,lux:lux))
            }
        }
        let sum=samples.reduce(0){$0+$1.lux},average=sum/Double(count)
        guard sum.isFinite,average.isFinite else { throw BuildingAnalysisError.invalidInput("illuminance sum") }
        let minimum=samples.map(\.lux).min() ?? 0,maximum=samples.map(\.lux).max() ?? 0
        return .init(inputFingerprint:try request.fingerprint(),engine:"native-direct-type-C-v1",
            columns:grid.columns,rows:grid.rows,samples:samples,minimumLux:minimum,maximumLux:maximum,
            averageLux:average,minimumToAverage:average>0 ? minimum/average:0,
            scope:"preliminary-direct-illuminance",limitations:["no interreflection","no daylight","opaque axis-aligned boxes only","Type-C TILT=NONE only","no regulatory pass/fail assertion"])
    }
}
