// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

public enum InteriorAxis: String, Codable, Sendable { case x,y,z }
public enum CabinetPanelRole: String, Codable, Sendable {
    case leftSide,rightSide,top,bottom,back,partition,shelf,front
}

public struct CabinetPanel: Codable, Equatable, Sendable {
    public var id: String
    public var role: CabinetPanelRole
    public var originMM: InteriorVector3
    public var sizeMM: InteriorVector3
    public var thicknessAxis: InteriorAxis
    public var material: InteriorPanelMaterial
    public var bayID: UUID?
    public var grain: String { "unspecified" }
    public var faceDimensionsMM: [Double] {
        switch thicknessAxis {
        case .x: [sizeMM.y,sizeMM.z]
        case .y: [sizeMM.x,sizeMM.z]
        case .z: [sizeMM.x,sizeMM.y]
        }
    }
    public var faceAreaM2: Double { faceDimensionsMM[0]*faceDimensionsMM[1]/1_000_000 }
    public var volumeM3: Double { sizeMM.x*sizeMM.y*sizeMM.z/1_000_000_000 }
}

public struct CabinetAssembly: Codable, Equatable, Sendable {
    public var recipe: CabinetRecipe
    public var panels: [CabinetPanel]
    public var geometryFingerprint: String
    public var scheduleFingerprint: String
    public var manufacturingVerified: Bool { false }
    public var missingManufacturingInputs: [String] {
        ["cut-size-and-allowance-rules","edge-and-grain-rules","joinery-rules","hardware-and-drilling-rules"]
    }
    public var designFaceAreaM2: Double { panels.reduce(0){$0+$1.faceAreaM2} }
    public func validateGeneratedSnapshot() throws {
        guard self == (try CabinetBuilder.build(recipe)) else { throw InteriorDesignError.staleAssemblySnapshot }
    }
}

public enum InteriorFingerprint {
    public static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        return try encoder.encode(value)
    }
    public static func hash<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data:try data(value)).map { String(format:"%02x",$0) }.joined()
    }
}

public enum CabinetBuilder {
    public static func build(_ recipe: CabinetRecipe) throws -> CabinetAssembly {
        try recipe.validate()
        let w=recipe.widthMM,h=recipe.heightMM,d=recipe.carcassDepthMM
        let t=recipe.carcassMaterial.thicknessMM,b=recipe.backMaterial.thicknessMM
        let innerW=w-2*t,innerH=h-2*t
        let bayWidth=(innerW-Double(recipe.bays.count-1)*t)/Double(recipe.bays.count)
        let prefix=recipe.id.uuidString.lowercased()
        var panels:[CabinetPanel]=[]
        func append(_ key:String,_ role:CabinetPanelRole,_ origin:InteriorVector3,
                    _ size:InteriorVector3,_ axis:InteriorAxis,_ material:InteriorPanelMaterial,
                    bayID:UUID?=nil) {
            panels.append(.init(id:prefix+"/"+key,role:role,originMM:origin,sizeMM:size,
                                thicknessAxis:axis,material:material,bayID:bayID))
        }
        append("left",.leftSide,.init(0,0,0),.init(t,d,h),.x,recipe.carcassMaterial)
        append("right",.rightSide,.init(w-t,0,0),.init(t,d,h),.x,recipe.carcassMaterial)
        append("bottom",.bottom,.init(t,0,0),.init(innerW,d,t),.z,recipe.carcassMaterial)
        append("top",.top,.init(t,0,h-t),.init(innerW,d,t),.z,recipe.carcassMaterial)
        append("back",.back,.init(t,d-b,t),.init(innerW,b,innerH),.y,recipe.backMaterial)
        for (index,bay) in recipe.bays.enumerated() {
            let bayX=t+Double(index)*(bayWidth+t)
            if index<recipe.bays.count-1 {
                let key="between/"+bay.id.uuidString.lowercased()+"/"+recipe.bays[index+1].id.uuidString.lowercased()
                append(key,.partition,.init(bayX+bayWidth,0,t),.init(t,d-b,innerH),.x,recipe.carcassMaterial)
            }
            let gap=(innerH-Double(bay.shelfIDs.count)*t)/Double(bay.shelfIDs.count+1)
            for (shelfIndex,id) in bay.shelfIDs.enumerated() {
                let z=t+Double(shelfIndex+1)*gap+Double(shelfIndex)*t
                append("shelf/"+id.uuidString.lowercased(),.shelf,
                       .init(bayX,recipe.shelfFrontSetbackMM,z),
                       .init(bayWidth,d-b-recipe.shelfFrontSetbackMM,t),.z,recipe.carcassMaterial,bayID:bay.id)
            }
            if let fronts=recipe.fronts {
                let frontW=(w-2*fronts.revealMM-Double(recipe.bays.count-1)*fronts.gapMM)/Double(recipe.bays.count)
                append("front/"+bay.id.uuidString.lowercased(),.front,
                       .init(fronts.revealMM+Double(index)*(frontW+fronts.gapMM),
                             -fronts.material.thicknessMM-fronts.distanceFromCarcassMM,fronts.revealMM),
                       .init(frontW,fronts.material.thicknessMM,h-2*fronts.revealMM),.y,fronts.material,bayID:bay.id)
            }
        }
        struct Geometry: Encodable { var id:String; var origin:InteriorVector3; var size:InteriorVector3 }
        let geometry=panels.map { Geometry(id:$0.id,origin:$0.originMM,size:$0.sizeMM) }
        return CabinetAssembly(recipe:recipe,panels:panels,
                               geometryFingerprint:try InteriorFingerprint.hash(geometry),
                               scheduleFingerprint:try InteriorFingerprint.hash(panels))
    }
}
