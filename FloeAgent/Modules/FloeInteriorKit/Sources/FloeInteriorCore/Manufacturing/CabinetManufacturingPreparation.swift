// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum CabinetGrain: String, Codable, Equatable, Sendable {case unknown, none, length, width}
public enum CabinetBlankSizingRule: String, Codable, Equatable, Sendable {
    case geometryIncludesBands, geometryIsSubstrate
}
public enum CabinetEdgeTreatment: Codable, Equatable, Sendable {
    case unknown
    case unbanded
    case band(materialID:String, version:String, thicknessMM:Double)
}
public struct CabinetEdgeTreatments: Codable, Equatable, Sendable {
    public var lengthStart:CabinetEdgeTreatment
    public var lengthEnd:CabinetEdgeTreatment
    public var widthStart:CabinetEdgeTreatment
    public var widthEnd:CabinetEdgeTreatment
    public init(lengthStart:CabinetEdgeTreatment, lengthEnd:CabinetEdgeTreatment,
                widthStart:CabinetEdgeTreatment, widthEnd:CabinetEdgeTreatment) {
        self.lengthStart=lengthStart;self.lengthEnd=lengthEnd;self.widthStart=widthStart;self.widthEnd=widthEnd
    }
    public static let unknown=Self(lengthStart:.unknown,lengthEnd:.unknown,widthStart:.unknown,widthEnd:.unknown)
    public static let unbanded=Self(lengthStart:.unbanded,lengthEnd:.unbanded,widthStart:.unbanded,widthEnd:.unbanded)
    var all:[CabinetEdgeTreatment]{[lengthStart,lengthEnd,widthStart,widthEnd]}
}
public struct CabinetPartDimensions: Codable, Equatable, Sendable {
    public var lengthMM:Double
    public var widthMM:Double
    public var thicknessMM:Double
    public init(lengthMM:Double,widthMM:Double,thicknessMM:Double){self.lengthMM=lengthMM;self.widthMM=widthMM;self.thicknessMM=thicknessMM}
}
public struct CabinetMachiningAllowance: Codable, Equatable, Sendable {
    /// Total additional size per axis, not a per-edge amount.
    public var totalLengthMM:Double
    public var totalWidthMM:Double
    public init(totalLengthMM:Double,totalWidthMM:Double){self.totalLengthMM=totalLengthMM;self.totalWidthMM=totalWidthMM}
}
public struct CabinetPanelProcess: Codable, Equatable, Sendable {
    public var panelID:String
    public var lengthAxis:InteriorAxis
    public var widthAxis:InteriorAxis
    public var sizingRule:CabinetBlankSizingRule?
    public var ruleReference:InteriorRuleReference?
    public var edges:CabinetEdgeTreatments
    public var allowance:CabinetMachiningAllowance?
    public var grain:CabinetGrain
    public var mayRotate90:Bool
    public init(panelID:String,lengthAxis:InteriorAxis,widthAxis:InteriorAxis,
                sizingRule:CabinetBlankSizingRule?=nil,ruleReference:InteriorRuleReference?=nil,
                edges:CabinetEdgeTreatments = .unknown,allowance:CabinetMachiningAllowance?=nil,
                grain:CabinetGrain = .unknown,mayRotate90:Bool=false) {
        self.panelID=panelID;self.lengthAxis=lengthAxis;self.widthAxis=widthAxis
        self.sizingRule=sizingRule;self.ruleReference=ruleReference;self.edges=edges;self.allowance=allowance
        self.grain=grain;self.mayRotate90=mayRotate90
    }
}
public struct CabinetStockTrim: Codable, Equatable, Sendable {
    public var lengthStartMM:Double;public var lengthEndMM:Double
    public var widthStartMM:Double;public var widthEndMM:Double
    public init(lengthStartMM:Double,lengthEndMM:Double,widthStartMM:Double,widthEndMM:Double){
        self.lengthStartMM=lengthStartMM;self.lengthEndMM=lengthEndMM;self.widthStartMM=widthStartMM;self.widthEndMM=widthEndMM
    }
    var all:[Double]{[lengthStartMM,lengthEndMM,widthStartMM,widthEndMM]}
}
public struct CabinetStockPanel: Codable, Equatable, Sendable {
    public enum Kind:String,Codable,Equatable,Sendable {case standard,offcut}
    public var id:String
    public var version:String
    public var material:InteriorPanelMaterial
    public var kind:Kind
    public var lengthMM:Double
    public var widthMM:Double
    public var quantity:Int?
    public var trim:CabinetStockTrim?
    public var grain:CabinetGrain
    public init(id:String,version:String,material:InteriorPanelMaterial,kind:Kind,
                lengthMM:Double,widthMM:Double,quantity:Int?,trim:CabinetStockTrim?,grain:CabinetGrain){
        self.id=id;self.version=version;self.material=material;self.kind=kind;self.lengthMM=lengthMM;self.widthMM=widthMM
        self.quantity=quantity;self.trim=trim;self.grain=grain
    }
}
public struct CabinetManufacturingInput: Codable, Equatable, Sendable {
    public var assembly:CabinetAssembly
    public var processes:[CabinetPanelProcess]
    public var stocks:[CabinetStockPanel]
    public var kerfMM:Double?
    public init(assembly:CabinetAssembly,processes:[CabinetPanelProcess],stocks:[CabinetStockPanel],kerfMM:Double?){
        self.assembly=assembly;self.processes=processes;self.stocks=stocks;self.kerfMM=kerfMM
    }
}
public struct CabinetPreparedPart: Codable, Equatable, Sendable, Identifiable {
    public var id:String
    public var material:InteriorPanelMaterial
    public var designSizeXYZMM:InteriorVector3
    public var designFace:CabinetPartDimensions?
    public var finished:CabinetPartDimensions?
    public var substrate:CabinetPartDimensions?
    public var cuttingBlank:CabinetPartDimensions?
    public var process:CabinetPanelProcess?
    public var issues:[String]
}
public struct CabinetPackingStock: Codable, Equatable, Sendable {
    public var source:CabinetStockPanel
    public var usableLengthMM:Double
    public var usableWidthMM:Double
}
public struct CabinetPackingPart: Codable, Equatable, Sendable {
    public var panelID:String
    public var dimensions:CabinetPartDimensions
    /// Each panel remains an individual item; identical-looking panels do not
    /// lose their geometry identity when quantities are reported.
    public var quantity:Int {1}
    /// Missing stock IDs are forbidden, not a default zero-degree placement.
    public var allowedDegreesByStockID:[String:[Int]]
}
public struct CabinetPackingGroup: Codable, Equatable, Sendable, Identifiable {
    public var id:String
    public var material:InteriorPanelMaterial
    public var grain:CabinetGrain
    public var kerfMM:Double
    public var stocks:[CabinetPackingStock]
    public var parts:[CabinetPackingPart]
}
public struct CabinetManufacturingPreparation: Codable, Equatable, Sendable {
    public var inputFingerprint:String
    public var geometryFingerprint:String
    public var parts:[CabinetPreparedPart]
    public var packingGroups:[CabinetPackingGroup]
    public var issues:[String]
    public var readyForNesting:Bool {issues.isEmpty && parts.allSatisfy{$0.issues.isEmpty} && packingGroups.reduce(0){$0+$1.parts.count}==parts.count}
    public var manufacturingVerified:Bool {false}
    public var missingProductionValidation:[String]{["optimizer-output","hardware-and-drilling-rules","joinery-and-grain-matching","motion-and-clearance","machine-postprocessor"]}
    public func isStale(for input:CabinetManufacturingInput)throws->Bool {
        inputFingerprint != (try CabinetManufacturingPlanner.prepare(input)).inputFingerprint
    }
    public func validateDerivedSnapshot(for input:CabinetManufacturingInput)throws {
        guard self == (try CabinetManufacturingPlanner.prepare(input)) else {throw InteriorDesignError.staleAssemblySnapshot}
    }
    public func dimensionsCSV()->String {
        func cell(_ value:String)->String{"\""+value.replacingOccurrences(of:"\"",with:"\"\"")+"\""}
        func numbers(_ d:CabinetPartDimensions?)->[String]{d.map{[String($0.lengthMM),String($0.widthMM),String($0.thicknessMM)]} ?? ["","",""]}
        var lines=["panel_id,material_id,material_version,rule_id,rule_version,grain,design_length_mm,design_width_mm,design_thickness_mm,finished_length_mm,finished_width_mm,finished_thickness_mm,substrate_length_mm,substrate_width_mm,substrate_thickness_mm,blank_length_mm,blank_width_mm,blank_thickness_mm,issues"]
        for part in parts {
            let fields=[part.id,part.material.id,part.material.version,part.process?.ruleReference?.id ?? "",part.process?.ruleReference?.version ?? "",part.process?.grain.rawValue ?? "unknown"]+numbers(part.designFace)+numbers(part.finished)+numbers(part.substrate)+numbers(part.cuttingBlank)+[part.issues.joined(separator:";")]
            lines.append(fields.map(cell).joined(separator:","))
        }
        return lines.joined(separator:"\r\n")+"\r\n"
    }
}

/// Rectangular part preparation only. No nesting solver, manufacturing default
/// stock, brand-hole generation, shop certification or CNC output is implied.
public enum CabinetManufacturingPlanner {
    public static let version="cabinet-preparation@1"
    public static func prepare(_ input:CabinetManufacturingInput)throws->CabinetManufacturingPreparation {
        try input.assembly.validateGeneratedSnapshot()
        guard input.assembly.panels.count<=10_000,input.processes.count<=10_000,input.stocks.count<=1024 else {throw InteriorDesignError.researchBudgetExceeded}
        guard Set(input.processes.map(\.panelID)).count==input.processes.count,
              Set(input.stocks.map(\.id)).count==input.stocks.count else {throw InteriorDesignError.duplicateIdentity}
        let knownIDs=Set(input.assembly.panels.map(\.id))
        guard input.processes.allSatisfy({knownIDs.contains($0.panelID)}) else {throw InteriorDesignError.invalidDimension("foreign process panel")}
        func identity(_ s:String)->Bool{!s.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && s.utf8.count<=1024}
        func finite(_ x:Double)->Bool{x.isFinite && x>=0 && x<=1e7}
        func axis(_ size:InteriorVector3,_ a:InteriorAxis)->Double{switch a {case .x:size.x;case .y:size.y;case .z:size.z}}
        if let kerf=input.kerfMM, !finite(kerf){throw InteriorDesignError.invalidDimension("kerf")}
        let processes=Dictionary(uniqueKeysWithValues:input.processes.map{($0.panelID,$0)})
        var global:[String]=[],stockValues:[CabinetPackingStock]=[]
        if input.kerfMM==nil{global.append("kerf-unspecified")}
        for stock in input.stocks.sorted(by:{$0.id<$1.id}) {
            guard identity(stock.id),identity(stock.version),identity(stock.material.id),identity(stock.material.version),
                  finite(stock.lengthMM),stock.lengthMM>0,finite(stock.widthMM),stock.widthMM>0,
                  finite(stock.material.thicknessMM),stock.material.thicknessMM>0,
                  stock.quantity.map({(0...100_000).contains($0)}) ?? true else {throw InteriorDesignError.invalidDimension("stock")}
            if let trim=stock.trim {
                guard trim.all.allSatisfy(finite),trim.lengthStartMM+trim.lengthEndMM<stock.lengthMM,
                      trim.widthStartMM+trim.widthEndMM<stock.widthMM else {throw InteriorDesignError.invalidDimension("stock trim")}
            }
            if stock.quantity==0{global.append("stock-unavailable:"+stock.id);continue}
            guard let trim=stock.trim,stock.quantity != nil,stock.grain != .unknown else {
                global.append("stock-conditions-unspecified:"+stock.id);continue
            }
            stockValues.append(.init(source:stock,usableLengthMM:stock.lengthMM-trim.lengthStartMM-trim.lengthEndMM,
                                     usableWidthMM:stock.widthMM-trim.widthStartMM-trim.widthEndMM))
        }
        var prepared:[CabinetPreparedPart]=[],groups:[String:CabinetPackingGroup]=[:]
        for panel in input.assembly.panels.sorted(by:{$0.id<$1.id}) {
            var row=CabinetPreparedPart(id:panel.id,material:panel.material,designSizeXYZMM:panel.sizeMM,
                designFace:nil,finished:nil,substrate:nil,cuttingBlank:nil,process:processes[panel.id],issues:[])
            guard let process=row.process else {row.issues.append("process-unspecified");prepared.append(row);continue}
            guard process.lengthAxis != process.widthAxis,process.lengthAxis != panel.thicknessAxis,process.widthAxis != panel.thicknessAxis else {
                throw InteriorDesignError.invalidDimension("local part axes")
            }
            let d=CabinetPartDimensions(lengthMM:axis(panel.sizeMM,process.lengthAxis),widthMM:axis(panel.sizeMM,process.widthAxis),thicknessMM:axis(panel.sizeMM,panel.thicknessAxis))
            row.designFace=d
            if process.sizingRule==nil || process.ruleReference==nil{row.issues.append("sizing-rule-unspecified")}
            if let ref=process.ruleReference, !identity(ref.id) || !identity(ref.version){throw InteriorDesignError.invalidDimension("rule source")}
            if process.allowance==nil{row.issues.append("allowance-unspecified")}
            if let allowance=process.allowance, !finite(allowance.totalLengthMM) || !finite(allowance.totalWidthMM){throw InteriorDesignError.invalidDimension("machining allowance")}
            if process.grain == .unknown {row.issues.append("grain-unspecified")}
            var bands:[Double]=[]
            for (index,edge) in process.edges.all.enumerated() {
                switch edge {
                case .unknown:row.issues.append("edge-treatment-unspecified:"+["length-start","length-end","width-start","width-end"][index]);bands.append(0)
                case .unbanded:bands.append(0)
                case .band(let material,let revision,let thickness):
                    guard identity(material),identity(revision),finite(thickness),thickness>0 else {throw InteriorDesignError.invalidDimension("band source or thickness")}
                    bands.append(thickness)
                }
            }
            guard row.issues.isEmpty,let rule=process.sizingRule,let allowance=process.allowance else {prepared.append(row);continue}
            let lengthBand=bands[0]+bands[1],widthBand=bands[2]+bands[3]
            let substrate=CabinetPartDimensions(lengthMM:d.lengthMM-(rule == .geometryIncludesBands ? lengthBand:0),
                widthMM:d.widthMM-(rule == .geometryIncludesBands ? widthBand:0),thicknessMM:d.thicknessMM)
            let finished=CabinetPartDimensions(lengthMM:d.lengthMM+(rule == .geometryIsSubstrate ? lengthBand:0),
                widthMM:d.widthMM+(rule == .geometryIsSubstrate ? widthBand:0),thicknessMM:d.thicknessMM)
            let blank=CabinetPartDimensions(lengthMM:substrate.lengthMM+allowance.totalLengthMM,
                widthMM:substrate.widthMM+allowance.totalWidthMM,thicknessMM:d.thicknessMM)
            guard [substrate.lengthMM,substrate.widthMM,finished.lengthMM,finished.widthMM,blank.lengthMM,blank.widthMM].allSatisfy({finite($0) && $0>0}) else {
                throw InteriorDesignError.invalidDimension("collapsed or overflowing cut size")
            }
            row.finished=finished;row.substrate=substrate;row.cuttingBlank=blank
            let matching=stockValues.filter{$0.source.material==panel.material}
            var orientations:[String:[Int]]=[:]
            for stock in matching {
                var degrees:[Int]=[]
                for turn in process.mayRotate90 ? [0,90]:[0] {
                    let alongLength=turn==0 ? process.grain == .length:process.grain == .width
                    let alongWidth=turn==0 ? process.grain == .width:process.grain == .length
                    let grainFits=process.grain == .none || (alongLength && stock.source.grain == .length) || (alongWidth && stock.source.grain == .width)
                    let length=turn==0 ? blank.lengthMM:blank.widthMM,width=turn==0 ? blank.widthMM:blank.lengthMM
                    if grainFits && length<=stock.usableLengthMM && width<=stock.usableWidthMM{degrees.append(turn)}
                }
                if !degrees.isEmpty{orientations[stock.source.id]=degrees}
            }
            if orientations.isEmpty{row.issues.append(matching.isEmpty ? "compatible-stock-unavailable":"stock-size-or-grain-incompatible")}
            if let kerf=input.kerfMM,!orientations.isEmpty {
                struct GroupKey:Encodable {var material:InteriorPanelMaterial;var grain:CabinetGrain;var rotate:Bool;var rule:InteriorRuleReference?;var sizing:CabinetBlankSizingRule}
                let key=try InteriorFingerprint.hash(GroupKey(material:panel.material,grain:process.grain,rotate:process.mayRotate90,rule:process.ruleReference,sizing:rule))
                var group=groups[key] ?? .init(id:key,material:panel.material,grain:process.grain,kerfMM:kerf,stocks:matching,parts:[])
                group.parts.append(.init(panelID:panel.id,dimensions:blank,allowedDegreesByStockID:orientations));groups[key]=group
            }
            prepared.append(row)
        }
        struct Fingerprint:Encodable {var version:String;var geometry:String;var schedule:String;var processes:[CabinetPanelProcess];var stocks:[CabinetStockPanel];var kerf:Double?}
        let hash=try InteriorFingerprint.hash(Fingerprint(version:version,geometry:input.assembly.geometryFingerprint,
            schedule:input.assembly.scheduleFingerprint,processes:input.processes.sorted{$0.panelID<$1.panelID},stocks:input.stocks.sorted{$0.id<$1.id},kerf:input.kerfMM))
        return .init(inputFingerprint:hash,geometryFingerprint:input.assembly.geometryFingerprint,parts:prepared,
                     packingGroups:groups.values.sorted{$0.id<$1.id},issues:global.sorted())
    }
}
