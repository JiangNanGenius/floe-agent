// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum CabinetTechnicalView: String, Codable, Sendable, CaseIterable {
    case front,side,top,section,isometric,internalElevation
}
public struct CabinetPaperPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x:Double,_ y:Double) { self.x=x;self.y=y }
}
public struct CabinetSheetViewSpec: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: CabinetTechnicalView
    public var panelIDs: [String]
    public var horizontalInBuilding: InteriorVector3
    public var verticalInBuilding: InteriorVector3
    public var centreOnPaperMM: CabinetPaperPoint
    public var scaleDenominator: Double
    public var projectedWidthMM: Double
    public var projectedHeightMM: Double
    public var adapterIssues: [String]
}
public struct CabinetAssociativeDimension: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var role: String
    public var sourceObjectIDs: [String]
    public var firstInBuildingMM: InteriorVector3
    public var secondInBuildingMM: InteriorVector3
    public var valueMM: Double
    public var viewKinds: [CabinetTechnicalView]
}
public struct CabinetDimensionPresentation: Codable, Equatable, Sendable {
    public var dimensionID: String
    public var paperOffsetMM: CabinetPaperPoint
    public var additionalText: String
    public var visible: Bool
    public init(dimensionID:String,paperOffsetMM:CabinetPaperPoint = .init(0,0),additionalText:String="",visible:Bool=true) {
        self.dimensionID=dimensionID;self.paperOffsetMM=paperOffsetMM;self.additionalText=additionalText;self.visible=visible
    }
}
public struct CabinetManualSheetNote: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var positionMM: CabinetPaperPoint
    public init(id:UUID=UUID(),text:String,positionMM:CabinetPaperPoint) { self.id=id;self.text=text;self.positionMM=positionMM }
}
public struct CabinetCombinationSheet: Codable, Equatable, Sendable {
    public var id: String
    public var cabinetID: UUID
    public var geometryFingerprint: String
    public var sheetFingerprint: String
    public var paperWidthMM: Double
    public var paperHeightMM: Double
    public var views: [CabinetSheetViewSpec]
    public var dimensions: [CabinetAssociativeDimension]
    public var dimensionPresentation: [CabinetDimensionPresentation]
    public var orphanedPresentation: [CabinetDimensionPresentation]
    public var manualNotes: [CabinetManualSheetNote]
    public var status: String
    public func isStale(for assembly:CabinetAssembly)->Bool {
        geometryFingerprint != assembly.geometryFingerprint || cabinetID != assembly.recipe.id
    }
}

/// Defines native CAD views/dimension anchors and sheet layout. This does not
/// replace CAD projection, hidden-line, dimension rendering or page persistence.
public enum CabinetSheetPlanner {
    public static func make(_ assembly:CabinetAssembly,previous:CabinetCombinationSheet?=nil,
                            paperWidthMM:Double=420,paperHeightMM:Double=297,
                            maximumNativeSources:Int=12) throws -> CabinetCombinationSheet {
        try assembly.validateGeneratedSnapshot()
        guard paperWidthMM.isFinite,paperHeightMM.isFinite,(210...1189).contains(paperWidthMM),
              (210...1189).contains(paperHeightMM),maximumNativeSources>0 else {
            throw InteriorDesignError.invalidDimension("paper or native source budget")
        }
        let recipe=assembly.recipe,prefix=recipe.id.uuidString.lowercased()
        if let previous,previous.cabinetID != recipe.id { throw InteriorDesignError.staleAssemblySnapshot }
        let minY=assembly.panels.map(\.originMM.y).min() ?? 0
        let maxY=assembly.panels.map{$0.originMM.y+$0.sizeMM.y}.max() ?? recipe.carcassDepthMM
        let w=recipe.widthMM,h=recipe.heightMM
        let corners=[0.0,w].flatMap { x in [minY,maxY].flatMap { y in [0.0,h].map { z in InteriorVector3(x,y,z) } } }
        let cellW=(paperWidthMM-30-16)/3,cellH=(paperHeightMM-30-25-8)/2
        let usableW=cellW-16,usableH=cellH-16
        guard usableW>0,usableH>0 else { throw InteriorDesignError.invalidDimension("view area") }
        let scales=[5.0,10,20,25,50,100,200]
        func dot(_ a:InteriorVector3,_ b:InteriorVector3)->Double { a.x*b.x+a.y*b.y+a.z*b.z }
        var views:[CabinetSheetViewSpec]=[]
        for (index,kind) in CabinetTechnicalView.allCases.enumerated() {
            let axes:(InteriorVector3,InteriorVector3)
            switch kind {
            case .front,.internalElevation: axes=(.init(1,0,0),.init(0,0,1))
            case .side,.section: axes=(.init(0,1,0),.init(0,0,1))
            case .top: axes=(.init(1,0,0),.init(0,1,0))
            case .isometric: axes=(.init(1/sqrt(2),-1/sqrt(2),0),.init(-1/sqrt(6),-1/sqrt(6),sqrt(2.0/3)))
            }
            let xs=corners.map{dot($0,axes.0)},ys=corners.map{dot($0,axes.1)}
            let width=(xs.max() ?? 0)-(xs.min() ?? 0),height=(ys.max() ?? 0)-(ys.min() ?? 0)
            guard let scale=scales.first(where:{width/$0<=usableW && height/$0<=usableH}) else {
                throw InteriorDesignError.invalidDimension("cabinet does not fit the selected sheet")
            }
            let panels=kind == .internalElevation ? assembly.panels.filter{$0.role != .front}:assembly.panels
            let issues=panels.count>maximumNativeSources ? ["native-drawing-source-budget-exceeded"]:[]
            views.append(.init(id:prefix+"/view/"+kind.rawValue,kind:kind,panelIDs:panels.map(\.id),
                horizontalInBuilding:axes.0,verticalInBuilding:axes.1,
                centreOnPaperMM:.init(15+Double(index%3)*(cellW+8)+cellW/2,
                                      15+Double(index/3)*(cellH+8)+cellH/2),
                scaleDenominator:scale,projectedWidthMM:width,projectedHeightMM:height,adapterIssues:issues))
        }
        var dimensions:[CabinetAssociativeDimension]=[]
        func dimension(_ key:String,_ role:String,_ a:InteriorVector3,_ b:InteriorVector3,
                       _ sourceIDs:[String],_ viewKinds:[CabinetTechnicalView]) {
            let dx=b.x-a.x,dy=b.y-a.y,dz=b.z-a.z
            dimensions.append(.init(id:prefix+"/dimension/"+key,role:role,sourceObjectIDs:sourceIDs,
                firstInBuildingMM:a,secondInBuildingMM:b,valueMM:sqrt(dx*dx+dy*dy+dz*dz),viewKinds:viewKinds))
        }
        dimension("overall-width","overall-width",.init(0,minY,0),.init(w,minY,0),[prefix],[.front,.top])
        dimension("overall-height","overall-height",.init(0,minY,0),.init(0,minY,h),[prefix],[.front,.side])
        dimension("carcass-depth","carcass-depth",.init(0,0,0),.init(0,recipe.carcassDepthMM,0),[prefix],[.side,.section,.top])
        dimension("overall-depth","overall-depth",.init(0,minY,0),.init(0,maxY,0),[prefix],[.side,.top])
        let t=recipe.carcassMaterial.thicknessMM
        let bayWidth=(w-2*t-Double(recipe.bays.count-1)*t)/Double(recipe.bays.count)
        for (index,bay) in recipe.bays.enumerated() {
            let bayKey=bay.id.uuidString.lowercased(),x=t+Double(index)*(bayWidth+t)
            dimension("bay/"+bayKey+"/clear-width","bay-clear-width",.init(x,0,t),.init(x+bayWidth,0,t),[bayKey],[.internalElevation])
            dimension("bay/"+bayKey+"/clear-height","bay-clear-height",.init(x,0,t),.init(x,0,h-t),[bayKey],[.internalElevation])
            let shelves=assembly.panels.filter{$0.bayID==bay.id && $0.role == .shelf}.sorted{$0.originMM.z<$1.originMM.z}
            for opening in 0...shelves.count {
                let lower=opening==0 ? t:shelves[opening-1].originMM.z+shelves[opening-1].sizeMM.z
                let upper=opening==shelves.count ? h-t:shelves[opening].originMM.z
                let lowerID=opening==0 ? prefix+"/bottom":shelves[opening-1].id
                let upperID=opening==shelves.count ? prefix+"/top":shelves[opening].id
                dimension("opening/"+bayKey+"/"+lowerID+"/"+upperID,"opening-clear-height",.init(x,0,lower),.init(x,0,upper),[lowerID,upperID],[.internalElevation])
            }
        }
        for panel in assembly.panels {
            let a=panel.originMM
            var b=a
            switch panel.thicknessAxis {
            case .x: b.x+=panel.sizeMM.x
            case .y: b.y+=panel.sizeMM.y
            case .z: b.z+=panel.sizeMM.z
            }
            dimension("panel/"+panel.id+"/thickness","panel-thickness",a,b,[panel.id],[.section,.internalElevation])
        }
        let identities=Set(dimensions.map(\.id))
        let prior=(previous?.dimensionPresentation ?? [])+(previous?.orphanedPresentation ?? [])
        guard Set(prior.map(\.dimensionID)).count==prior.count,
              prior.allSatisfy({$0.paperOffsetMM.x.isFinite && $0.paperOffsetMM.y.isFinite && $0.additionalText.utf8.count<=8192}),
              (previous?.manualNotes ?? []).allSatisfy({$0.positionMM.x.isFinite && $0.positionMM.y.isFinite && $0.text.utf8.count<=8192}) else {
            throw InteriorDesignError.invalidDimension("manual sheet content")
        }
        struct Source:Encodable { var geometry:String;var views:[CabinetSheetViewSpec];var dimensions:[CabinetAssociativeDimension] }
        return .init(id:prefix+"/sheet/combination",cabinetID:recipe.id,geometryFingerprint:assembly.geometryFingerprint,
            sheetFingerprint:try InteriorFingerprint.hash(Source(geometry:assembly.geometryFingerprint,views:views,dimensions:dimensions)),
            paperWidthMM:paperWidthMM,paperHeightMM:paperHeightMM,views:views,dimensions:dimensions,
            dimensionPresentation:prior.filter{identities.contains($0.dimensionID)},
            orphanedPresentation:prior.filter{!identities.contains($0.dimensionID)},manualNotes:previous?.manualNotes ?? [],
            status:views.contains(where:{!$0.adapterIssues.isEmpty}) ? "native-adapter-budget-pending":"native-render-and-save-pending")
    }
}
