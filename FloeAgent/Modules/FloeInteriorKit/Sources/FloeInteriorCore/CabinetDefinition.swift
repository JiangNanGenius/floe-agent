// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum InteriorDesignError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidDimension(String)
    case duplicateIdentity
    case invalidBayConfiguration
    case insufficientInternalSpace
    case researchBudgetExceeded
    case staleAssemblySnapshot
}

/// Component coordinates: X width, Y depth from front to back, Z height; mm.
public struct InteriorVector3: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x=x; self.y=y; self.z=z }
    public var values: [Double] { [x,y,z] }
}

public struct InteriorRuleReference: Codable, Equatable, Sendable {
    public var id: String
    public var version: String
    public init(id: String, version: String) { self.id=id; self.version=version }
}

public struct InteriorPanelMaterial: Codable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var thicknessMM: Double
    public init(id: String, version: String, thicknessMM: Double) {
        self.id=id; self.version=version; self.thicknessMM=thicknessMM
    }
}

public struct CabinetBay: Codable, Equatable, Sendable {
    public var id: UUID
    /// Stable IDs are retained when a shelf is moved or the cabinet is resized.
    public var shelfIDs: [UUID]
    public init(id: UUID, shelfIDs: [UUID]) { self.id=id; self.shelfIDs=shelfIDs }
}

public struct CabinetFronts: Codable, Equatable, Sendable {
    public var material: InteriorPanelMaterial
    public var revealMM: Double
    public var gapMM: Double
    public var distanceFromCarcassMM: Double
    public init(material: InteriorPanelMaterial, revealMM: Double,
                gapMM: Double, distanceFromCarcassMM: Double) {
        self.material=material; self.revealMM=revealMM
        self.gapMM=gapMM; self.distanceFromCarcassMM=distanceFromCarcassMM
    }
}

/// First research recipe: between-side top/bottom, inset back between rails,
/// fixed shelves and optional slab fronts. This is not a manufacturing solver.
public struct CabinetRecipe: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var widthMM: Double
    public var heightMM: Double
    /// Front thickness and stand-off are outside this explicit carcass depth.
    public var carcassDepthMM: Double
    public var carcassMaterial: InteriorPanelMaterial
    public var backMaterial: InteriorPanelMaterial
    public var shelfFrontSetbackMM: Double
    public var constructionRule: InteriorRuleReference
    public var bays: [CabinetBay]
    public var fronts: CabinetFronts?

    public init(id: UUID, name: String, widthMM: Double, heightMM: Double,
                carcassDepthMM: Double, carcassMaterial: InteriorPanelMaterial,
                backMaterial: InteriorPanelMaterial, shelfFrontSetbackMM: Double,
                constructionRule: InteriorRuleReference, bays: [CabinetBay],
                fronts: CabinetFronts? = nil, schemaVersion: Int = 1) {
        self.schemaVersion=schemaVersion; self.id=id; self.name=name
        self.widthMM=widthMM; self.heightMM=heightMM; self.carcassDepthMM=carcassDepthMM
        self.carcassMaterial=carcassMaterial; self.backMaterial=backMaterial
        self.shelfFrontSetbackMM=shelfFrontSetbackMM; self.constructionRule=constructionRule
        self.bays=bays; self.fronts=fronts
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw InteriorDesignError.unsupportedVersion(schemaVersion) }
        for (name,value) in [("width",widthMM),("height",heightMM),("carcassDepth",carcassDepthMM),
                             ("boardThickness",carcassMaterial.thicknessMM),("backThickness",backMaterial.thicknessMM)] {
            guard value.isFinite, value>0 else { throw InteriorDesignError.invalidDimension(name) }
            guard value<=20_000 else { throw InteriorDesignError.researchBudgetExceeded }
        }
        guard shelfFrontSetbackMM.isFinite, shelfFrontSetbackMM>=0 else {
            throw InteriorDesignError.invalidDimension("shelfSetback")
        }
        guard !name.isEmpty, !constructionRule.id.isEmpty, !constructionRule.version.isEmpty,
              !carcassMaterial.id.isEmpty, !carcassMaterial.version.isEmpty,
              !backMaterial.id.isEmpty, !backMaterial.version.isEmpty else {
            throw InteriorDesignError.invalidBayConfiguration
        }
        guard constructionRule.id == "between-sides-inset-back", constructionRule.version == "1" else {
            throw InteriorDesignError.invalidBayConfiguration
        }
        guard !bays.isEmpty, bays.count<=16, bays.allSatisfy({ $0.shelfIDs.count<=32 }) else {
            throw InteriorDesignError.invalidBayConfiguration
        }
        let identities = bays.map(\.id) + bays.flatMap(\.shelfIDs)
        guard Set(identities).count==identities.count else { throw InteriorDesignError.duplicateIdentity }
        let thickness=carcassMaterial.thicknessMM
        let clearWidth=(widthMM-2*thickness-Double(bays.count-1)*thickness)/Double(bays.count)
        guard clearWidth>0, heightMM>2*thickness,
              carcassDepthMM>backMaterial.thicknessMM+shelfFrontSetbackMM,
              bays.allSatisfy({ heightMM-2*thickness-Double($0.shelfIDs.count)*thickness>0 }) else {
            throw InteriorDesignError.insufficientInternalSpace
        }
        if let fronts {
            for (name,value) in [("frontThickness",fronts.material.thicknessMM),
                                 ("frontReveal",fronts.revealMM),("frontGap",fronts.gapMM),
                                 ("frontStandOff",fronts.distanceFromCarcassMM)] {
                guard value.isFinite, value>=0, (name != "frontThickness" || value>0), value<=20_000 else {
                    throw InteriorDesignError.invalidDimension(name)
                }
            }
            guard !fronts.material.id.isEmpty, !fronts.material.version.isEmpty,
                  widthMM-2*fronts.revealMM-Double(bays.count-1)*fronts.gapMM>0,
                  heightMM-2*fronts.revealMM>0 else { throw InteriorDesignError.insufficientInternalSpace }
        }
        let count=5+max(0,bays.count-1)+bays.reduce(0){$0+$1.shelfIDs.count}+(fronts == nil ? 0:bays.count)
        guard count<=512 else { throw InteriorDesignError.researchBudgetExceeded }
    }
}
