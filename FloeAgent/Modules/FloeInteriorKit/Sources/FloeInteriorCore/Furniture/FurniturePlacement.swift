// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum FurniturePlacementError: Error, Equatable, Sendable {
    case invalid(String)
    case disproportionateCatalogFit
    case stalePlan
}

/// Bounds supplied by a geometry reader, never inferred from a catalog label.
public struct FurnitureSourceBounds: Codable, Equatable, Sendable {
    public var minimum: InteriorVector3
    public var maximum: InteriorVector3
    public init(minimum: InteriorVector3, maximum: InteriorVector3) {
        self.minimum=minimum; self.maximum=maximum
    }
    public var extent: InteriorVector3 {
        .init(maximum.x-minimum.x,maximum.y-minimum.y,maximum.z-minimum.z)
    }
    var corners: [InteriorVector3] {
        [minimum.x,maximum.x].flatMap { x in
            [minimum.y,maximum.y].flatMap { y in
                [minimum.z,maximum.z].map { z in InteriorVector3(x,y,z) }
            }
        }
    }
}

public struct FurnitureDimensions: Codable, Equatable, Sendable {
    public var widthMM: Double
    public var depthMM: Double
    public var heightMM: Double
    public init(widthMM: Double, depthMM: Double, heightMM: Double) {
        self.widthMM=widthMM; self.depthMM=depthMM; self.heightMM=heightMM
    }
}

public enum FurnitureSizing: Codable, Equatable, Sendable {
    /// Preserve source proportions. The caller must know the unit conversion.
    case sourceUnits(millimetresPerUnit: Double)
    /// Fit author-declared dimensions. These are not measured source units.
    /// Distortion is explicit, because a catalog can describe a resized model.
    case catalogDimensions(FurnitureDimensions, allowNonUniformScaling: Bool)
}

public enum FurnitureSourceOrientation: Codable, Equatable, Sendable {
    /// +X right, +Y up, +Z front; the same axes as native CAD world geometry.
    case cadYUp
    /// A proper orthonormal rotation from source axes to native CAD axes.
    /// Nine values, column-major. This does not permit shear or scale.
    case rotation3x3([Double])
}

public enum FurnitureAnchor: String, Codable, Equatable, Sendable {
    case bottomCenter
    /// Minimum X / minimum Y / maximum Z in the oriented model's bounds.
    case bottomFrontLeft
    case geometricCenter
}

public struct FurniturePose: Codable, Equatable, Sendable {
    public var planXMM: Double
    public var planYMM: Double
    public var floorElevationMM: Double
    public var elevationAboveFloorMM: Double
    public var yawDegrees: Double
    public var anchor: FurnitureAnchor
    public init(planXMM: Double, planYMM: Double, floorElevationMM: Double,
                elevationAboveFloorMM: Double, yawDegrees: Double, anchor: FurnitureAnchor) {
        self.planXMM=planXMM; self.planYMM=planYMM; self.floorElevationMM=floorElevationMM
        self.elevationAboveFloorMM=elevationAboveFloorMM; self.yawDegrees=yawDegrees; self.anchor=anchor
    }
}

public struct FurniturePlacementInput: Codable, Equatable, Sendable {
    public var instanceID: UUID
    public var roomID: UUID?
    public var assetID: String
    public var assetVersion: String
    public var sourceSHA256: String
    public var dependencySHA256: [String:String]
    public var sourceBounds: FurnitureSourceBounds
    public var orientation: FurnitureSourceOrientation
    public var sizing: FurnitureSizing
    public var pose: FurniturePose
    public init(instanceID: UUID, roomID: UUID?, assetID: String, assetVersion: String,
                sourceSHA256: String, dependencySHA256: [String:String],
                sourceBounds: FurnitureSourceBounds, orientation: FurnitureSourceOrientation,
                sizing: FurnitureSizing, pose: FurniturePose) {
        self.instanceID=instanceID; self.roomID=roomID; self.assetID=assetID; self.assetVersion=assetVersion
        self.sourceSHA256=sourceSHA256; self.dependencySHA256=dependencySHA256
        self.sourceBounds=sourceBounds; self.orientation=orientation; self.sizing=sizing; self.pose=pose
    }
}

/// A value-only adapter plan. It neither imports geometry nor verifies native
/// rendering, collision clearance or manufacturing suitability.
public struct FurniturePlacementPlan: Codable, Equatable, Sendable {
    public let adapterVersion: String
    public let instanceID: UUID
    public let assetID: String
    public let assetVersion: String
    public let inputFingerprint: String
    public let sizeBasis: String
    public let sourceMillimetresPerUnit: Double?
    public let scaleAlongOrientedAxes: InteriorVector3
    public let dimensionsMM: FurnitureDimensions
    public let anchorInBuildingMM: InteriorVector3
    /// Native +Y up; building (x,y,z) maps to native (x,z,-y).
    public let nativeMatrixColumnMajor: [Double]
    /// A transformed bounding envelope, not the furniture's exact footprint.
    public let envelopeInNativeMM: FurnitureSourceBounds
    public var nativeGeometryVerified: Bool { false }
    public var manufacturingVerified: Bool { false }

    public func nativePointMM(fromSource point: InteriorVector3) throws -> InteriorVector3 {
        guard nativeMatrixColumnMajor.count==16,
              nativeMatrixColumnMajor.allSatisfy(\.isFinite),point.values.allSatisfy(\.isFinite),
              [3,7,11].allSatisfy({nativeMatrixColumnMajor[$0]==0}),nativeMatrixColumnMajor[15]==1 else {
            throw FurniturePlacementError.invalid("affine matrix or source point")
        }
        let m=nativeMatrixColumnMajor
        let value=InteriorVector3(m[0]*point.x+m[4]*point.y+m[8]*point.z+m[12],
                                  m[1]*point.x+m[5]*point.y+m[9]*point.z+m[13],
                                  m[2]*point.x+m[6]*point.y+m[10]*point.z+m[14])
        guard value.values.allSatisfy({$0.isFinite && abs($0)<=1e9}) else {
            throw FurniturePlacementError.invalid("transformed coordinate budget")
        }
        return value
    }
    public func isStale(for input: FurniturePlacementInput) throws -> Bool {
        inputFingerprint != (try FurniturePlacementPlanner.make(input)).inputFingerprint
    }
    public func validateDerivedSnapshot(for input: FurniturePlacementInput) throws {
        guard self == (try FurniturePlacementPlanner.make(input)) else {throw FurniturePlacementError.stalePlan}
    }
}

public enum FurniturePlacementPlanner {
    public static let adapterVersion="furniture-placement@1"

    public static func make(_ input: FurniturePlacementInput) throws -> FurniturePlacementPlan {
        func validHash(_ value:String)->Bool {
            value.utf8.count==64 && value.utf8.allSatisfy{(48...57).contains($0) || (97...102).contains($0)}
        }
        guard !input.assetID.isEmpty,input.assetID.utf8.count<=512,
              !input.assetVersion.isEmpty,input.assetVersion.utf8.count<=256,
              validHash(input.sourceSHA256),input.dependencySHA256.count<=2048,
              input.dependencySHA256.allSatisfy({!$0.key.isEmpty && $0.key.utf8.count<=4096 && validHash($0.value)}) else {
            throw FurniturePlacementError.invalid("asset identity or source versions")
        }
        let bounds=input.sourceBounds,extent=bounds.extent,p=input.pose
        let numeric=bounds.minimum.values+bounds.maximum.values+[p.planXMM,p.planYMM,p.floorElevationMM,p.elevationAboveFloorMM,p.yawDegrees]
        guard numeric.allSatisfy({$0.isFinite && abs($0)<=1e9}),
              extent.values.allSatisfy({$0>0}) else {throw FurniturePlacementError.invalid("bounds or placement")}
        let rotation:[Double]
        switch input.orientation {
        case .cadYUp: rotation=[1,0,0,0,1,0,0,0,1]
        case .rotation3x3(let matrix):rotation=matrix
        }
        guard rotation.count==9,rotation.allSatisfy(\.isFinite) else {throw FurniturePlacementError.invalid("source orientation")}
        func dot(_ a:Int,_ b:Int)->Double {(0..<3).reduce(0){$0+rotation[a*3+$1]*rotation[b*3+$1]}}
        let det=rotation[0]*(rotation[4]*rotation[8]-rotation[7]*rotation[5]) - rotation[3]*(rotation[1]*rotation[8]-rotation[7]*rotation[2]) + rotation[6]*(rotation[1]*rotation[5]-rotation[4]*rotation[2])
        guard (0..<3).allSatisfy({abs(dot($0,$0)-1)<1e-8}),
              abs(dot(0,1))<1e-8,abs(dot(0,2))<1e-8,abs(dot(1,2))<1e-8,abs(det-1)<1e-8 else {
            throw FurniturePlacementError.invalid("orientation must be a proper rotation")
        }
        func orient(_ v:InteriorVector3)->InteriorVector3 {
            .init(rotation[0]*v.x+rotation[3]*v.y+rotation[6]*v.z,
                  rotation[1]*v.x+rotation[4]*v.y+rotation[7]*v.z,
                  rotation[2]*v.x+rotation[5]*v.y+rotation[8]*v.z)
        }
        func envelope(_ points:[InteriorVector3])->FurnitureSourceBounds {
            .init(minimum:.init(points.map(\.x).min()!,points.map(\.y).min()!,points.map(\.z).min()!),
                  maximum:.init(points.map(\.x).max()!,points.map(\.y).max()!,points.map(\.z).max()!))
        }
        let oriented=envelope(bounds.corners.map(orient)),e=oriented.extent
        guard e.values.allSatisfy({$0.isFinite && $0>0}) else {throw FurniturePlacementError.invalid("oriented bounds")}
        let scales:InteriorVector3,basis:String,unitScale:Double?
        switch input.sizing {
        case .sourceUnits(let unit):
            guard unit.isFinite,unit>0,unit<=1e9 else {throw FurniturePlacementError.invalid("explicit source unit")}
            scales = .init(unit,unit,unit);basis="explicit-source-units";unitScale=unit
        case .catalogDimensions(let d,let allowNonUniform):
            guard [d.widthMM,d.depthMM,d.heightMM].allSatisfy({$0.isFinite && $0>0 && $0<=1e9}) else {
                throw FurniturePlacementError.invalid("declared catalog dimensions")
            }
            let fits=[d.widthMM/e.x,d.heightMM/e.y,d.depthMM/e.z]
            guard fits.allSatisfy({$0.isFinite && $0>0}) else {throw FurniturePlacementError.invalid("catalog scale")}
            if !allowNonUniform {
                let largest=fits.max()!,smallest=fits.min()!
                guard (largest-smallest)/largest<=1e-8 else {throw FurniturePlacementError.disproportionateCatalogFit}
            }
            scales = .init(fits[0],fits[1],fits[2]);basis="catalog-declared-size";unitScale=nil
        }
        let dimensions=FurnitureDimensions(widthMM:e.x*scales.x,depthMM:e.z*scales.z,heightMM:e.y*scales.y)
        guard [dimensions.widthMM,dimensions.depthMM,dimensions.heightMM].allSatisfy({$0.isFinite && $0>0 && $0<=1e9}) else {
            throw FurniturePlacementError.invalid("normalized dimensions")
        }
        let center=InteriorVector3((oriented.minimum.x+oriented.maximum.x)/2,
                                   (oriented.minimum.y+oriented.maximum.y)/2,
                                   (oriented.minimum.z+oriented.maximum.z)/2)
        let anchor:InteriorVector3
        switch p.anchor {
        case .bottomCenter:anchor = .init(center.x,oriented.minimum.y,center.z)
        case .bottomFrontLeft:anchor = .init(oriented.minimum.x,oriented.minimum.y,oriented.maximum.z)
        case .geometricCenter:anchor=center
        }
        let yaw=p.yawDegrees.truncatingRemainder(dividingBy:360)*Double.pi/180,c=cos(yaw),s=sin(yaw)
        var matrix=Array(repeating:0.0,count:16)
        for col in 0..<3 {
            let x=scales.x*rotation[col*3],y=scales.y*rotation[col*3+1],z=scales.z*rotation[col*3+2]
            matrix[col*4]=c*x+s*z;matrix[col*4+1]=y;matrix[col*4+2] = -s*x+c*z
        }
        let world=InteriorVector3(p.planXMM,p.planYMM,p.floorElevationMM+p.elevationAboveFloorMM)
        matrix[12]=world.x-(c*scales.x*anchor.x+s*scales.z*anchor.z)
        matrix[13]=world.z-scales.y*anchor.y
        matrix[14] = -world.y-(-s*scales.x*anchor.x+c*scales.z*anchor.z);matrix[15]=1
        guard matrix.allSatisfy(\.isFinite) else {throw FurniturePlacementError.invalid("matrix overflow")}
        struct Fingerprint:Encodable {var adapter:String;var input:FurniturePlacementInput}
        let fingerprint=try InteriorFingerprint.hash(Fingerprint(adapter:adapterVersion,input:input))
        // Reuse exactly the public point transform for the derived envelope.
        let provisional=FurniturePlacementPlan(adapterVersion:adapterVersion,instanceID:input.instanceID,
            assetID:input.assetID,assetVersion:input.assetVersion,inputFingerprint:fingerprint,
            sizeBasis:basis,sourceMillimetresPerUnit:unitScale,scaleAlongOrientedAxes:scales,
            dimensionsMM:dimensions,anchorInBuildingMM:world,nativeMatrixColumnMajor:matrix,
            envelopeInNativeMM:bounds)
        let nativeBounds=envelope(try bounds.corners.map{try provisional.nativePointMM(fromSource:$0)})
        return .init(adapterVersion:adapterVersion,instanceID:input.instanceID,assetID:input.assetID,
            assetVersion:input.assetVersion,inputFingerprint:fingerprint,sizeBasis:basis,
            sourceMillimetresPerUnit:unitScale,scaleAlongOrientedAxes:scales,dimensionsMM:dimensions,
            anchorInBuildingMM:world,nativeMatrixColumnMajor:matrix,envelopeInNativeMM:nativeBounds)
    }
}
