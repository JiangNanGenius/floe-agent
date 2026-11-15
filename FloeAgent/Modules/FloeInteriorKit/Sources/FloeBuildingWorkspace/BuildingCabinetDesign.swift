// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeInteriorCore

/// Shared persisted cabinet inputs. The UI and CAD adapter decode the same
/// contract; neither reads a second private copy of another editor's schema.
public struct BuildingCabinetDesign:Codable,Equatable,Sendable {
    public var recipe:CabinetRecipe
    public var manualNotes:[CabinetManualSheetNote]
    public var dimensionPresentation:[CabinetDimensionPresentation]
    public init(recipe:CabinetRecipe = InteriorResearchSamples.cabinet(),
                manualNotes:[CabinetManualSheetNote]=[],dimensionPresentation:[CabinetDimensionPresentation]=[]) {
        self.recipe=recipe;self.manualNotes=manualNotes;self.dimensionPresentation=dimensionPresentation
    }
    private enum CodingKeys:String,CodingKey {case recipe,manualNotes,dimensionPresentation,sheet}
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        recipe=try c.decode(CabinetRecipe.self,forKey:.recipe)
        let legacy=try c.decodeIfPresent(CabinetCombinationSheet.self,forKey:.sheet)
        manualNotes=try c.decodeIfPresent([CabinetManualSheetNote].self,forKey:.manualNotes) ?? legacy?.manualNotes ?? []
        dimensionPresentation=try c.decodeIfPresent([CabinetDimensionPresentation].self,forKey:.dimensionPresentation) ?? legacy?.dimensionPresentation ?? []
    }
    public func encode(to encoder:Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(recipe,forKey:.recipe);try c.encode(manualNotes,forKey:.manualNotes)
        try c.encode(dimensionPresentation,forKey:.dimensionPresentation)
    }
}
