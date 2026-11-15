// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum InteriorResearchSamples {
    private static func id(_ suffix:Int)->UUID {
        UUID(uuidString:String(format:"00000000-0000-4000-8000-%012d",suffix))!
    }
    public static func cabinet(bayCount:Int=3,shelvesPerBay:Int=3,includeFronts:Bool=true) -> CabinetRecipe {
        let board=InteriorPanelMaterial(id:"synthetic-board",version:"1",thicknessMM:18)
        return .init(id:id(1),name:"Research cabinet",widthMM:2400,heightMM:2400,carcassDepthMM:600,
                     carcassMaterial:board,
                     backMaterial:.init(id:"synthetic-back",version:"1",thicknessMM:9),
                     shelfFrontSetbackMM:20,
                     constructionRule:.init(id:"between-sides-inset-back",version:"1"),
                     bays:(0..<bayCount).map { b in
                        .init(id:id(100+b),shelfIDs:(0..<shelvesPerBay).map{id(1000+b*100+$0)})
                     },fronts:includeFronts ? .init(material:board,revealMM:2,gapMM:2,distanceFromCarcassMM:2):nil)
    }
}
