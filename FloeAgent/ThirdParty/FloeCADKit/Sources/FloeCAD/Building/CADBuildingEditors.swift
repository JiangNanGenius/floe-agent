// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

private func bt(_ key:String,_ fallback:String)->String { FloeCADStrings.text("cad.building."+key,fallback) }

struct CADBuildingElementEditor:View {
    let model:CADBuildingDocument
    let save:(CADBuildingElement,Int)throws->Void
    let remove:(Int)throws->Void
    @State private var draft:CADBuildingElement
    @State private var expected:Int
    @State private var error:String?
    @Environment(\.dismiss) private var dismiss
    init(element:CADBuildingElement,model:CADBuildingDocument,changeCount:Int,
         save:@escaping(CADBuildingElement,Int)throws->Void,remove:@escaping(Int)throws->Void) {
        self.model=model;self.save=save;self.remove=remove
        _draft=State(initialValue:element);_expected=State(initialValue:changeCount)
    }
    static func newElement(kind:CADBuildingElement.Kind,model:CADBuildingDocument,storeyID:UUID)->CADBuildingElement {
        let floor=model.storeys.first {$0.id == storeyID} ?? model.storeys[0]
        var value=CADBuildingElement(storeyID:floor.id,kind:kind,name:kind.title+" \(model.elements.count+1)",
            a:[0,0],b:[4000,0],heightMM:floor.heightMM)
        switch kind {
        case .slab,.roof,.space: value.b=[6000,4000];value.thicknessMM=200
            if kind == .roof { value.baseOffsetMM=floor.heightMM }
        case .beam: value.thicknessMM=200;value.heightMM=400;value.baseOffsetMM=floor.heightMM-400
        case .column:value.b=[1,0];value.thicknessMM=300
        case .stair:value.thicknessMM=1000;value.stepCount=12
        case .pipe,.duct:value.thicknessMM=100;value.heightMM=100;value.baseOffsetMM=2500
        case .door,.window:
            if let wall=model.elements.first(where:{$0.kind == .wall && $0.storeyID == floor.id}) {
                value.hostID=wall.id;value.a=wall.a;value.b=wall.b
            }
            value.offsetMM=500;value.widthMM=900;value.thicknessMM=30
            value.heightMM=kind == .door ? 2100:1200;value.baseOffsetMM=kind == .door ? 0:900
        default:break
        };return value
    }
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    TextField(bt("name","Name"),text:$draft.name)
                    LabeledContent(bt("type","Type"),value:draft.kind.title)
                }
                if [.door,.window].contains(draft.kind) {
                    Section(bt("opening","Wall opening")) {
                        Picker(bt("hostWall","Host wall"),selection:$draft.hostID) {
                            Text(bt("chooseWall","Choose a wall")).tag(UUID?.none)
                            ForEach(model.elements.filter {$0.kind == .wall && $0.storeyID == draft.storeyID}) { wall in Text(wall.name).tag(Optional(wall.id)) }
                        }
                        field(bt("offset","Offset (mm)"),value:Binding(get:{draft.offsetMM ?? 0},set:{draft.offsetMM=$0}))
                        field(bt("width","Width (mm)"),value:Binding(get:{draft.widthMM ?? 900},set:{draft.widthMM=$0}))
                    }
                } else {
                    Section(bt("planCoordinates","Plan coordinates (mm)")) {
                        field("U₁",value:$draft.a[0]);field("V₁",value:$draft.a[1])
                        field("U₂",value:$draft.b[0]);field("V₂",value:$draft.b[1])
                    }
                }
                Section(bt("dimensions","Dimensions (mm)")) {
                    field(bt("thickness","Thickness / width"),value:$draft.thicknessMM)
                    field(bt("height","Height"),value:$draft.heightMM)
                    field(bt("baseOffset","Base elevation above floor"),value:$draft.baseOffsetMM)
                    if draft.kind == .stair {
                        Stepper(bt("steps","Steps")+" \(draft.stepCount ?? 12)",value:Binding(get:{draft.stepCount ?? 12},set:{draft.stepCount=$0}),in:2...64)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
                if model.elements.contains(where:{$0.id == draft.id}) {
                    Section {
                        Button(bt("delete","Delete element and hosted openings"),role:.destructive) { perform { try remove(expected) } }
                    }
                }
            }.navigationTitle(draft.kind.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(bt("cancel","Cancel")) { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button(bt("apply","Apply")) { perform { try save(draft,expected) } }.disabled(draft.name.isEmpty).accessibilityIdentifier("building.element.apply") }
            }
        }
    }
    private func field(_ title:String,value:Binding<Double>)->some View {
        LabeledContent(title) { TextField(title,value:value,format:.number).multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation).frame(maxWidth:160) }
    }
    private func perform(_ operation:()throws->Void) { do { try operation();dismiss() } catch { self.error=error.localizedDescription } }
}

struct CADBuildingPlanImportView:View {
    let document:FloeCADDocument
    let transfer:CADSketchTransferEnvelope
    let storeyID:UUID
    let apply:(CADBuildingDocument,Int)throws->Void
    @State private var unit="source"
    @State private var thickness=200.0
    @State private var height=3000.0
    @State private var acceptUnsupported=false
    @State private var candidate:CADBuildingDocument?
    @State private var expected=0
    @State private var error:String?
    @Environment(\.dismiss) private var dismiss
    private var scale:Double? {
        switch unit { case "mm":return 1;case "cm":return 10;case "m":return 1000;case "in":return 25.4;case "ft":return 304.8;default:return transfer.snapshot.unitScaleMM }
    }
    private var unsupported:Int { transfer.snapshot.omissions.count+transfer.snapshot.curves.filter {$0.kind != .line}.count }
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    Text(transfer.sourceName).font(.headline)
                    Text(bt("centreLines","Selected straight lines become wall centre lines. Review double-line walls and remove dimensions or furniture from the selection in the drawing editor."))
                        .font(.callout).foregroundStyle(.secondary)
                    LabeledContent(bt("lineCount","Straight lines"),value:"\(transfer.snapshot.curves.filter {$0.kind == .line}.count)")
                    Picker(bt("units","Drawing units"),selection:$unit) {
                        Text(transfer.snapshot.unitScaleMM == nil ? bt("chooseUnits","Choose units"):transfer.snapshot.unitName).tag("source")
                        ForEach(["mm","cm","m","in","ft"],id:\.self) { Text($0).tag($0) }
                    }.accessibilityIdentifier("building.import.units")
                    TextField(bt("thickness","Thickness / width"),value:$thickness,format:.number)
                    TextField(bt("height","Height"),value:$height,format:.number)
                    if unsupported > 0 {
                        LabeledContent(bt("unsupported","Curves and omitted objects"),value:"\(unsupported)")
                        Toggle(bt("acceptUnsupported","Import straight lines and retain the other source objects as evidence"),isOn:$acceptUnsupported)
                    }
                    Button(bt("preview","Preview walls")) { preview() }.disabled(scale == nil || (unsupported>0 && !acceptUnsupported))
                        .accessibilityIdentifier("building.import.preview")
                }
                if let candidate {
                    Section(bt("preview","Preview walls")) {
                        CADBuildingPlanView(elements:candidate.elements.filter {$0.storeyID == storeyID},allElements:candidate.elements,onTap:{_ in}).frame(height:260)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            }
            .navigationTitle(bt("import","Import floor plan…")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(bt("cancel","Cancel")) { dismiss() } }
                if let candidate {
                    ToolbarItem(placement:.confirmationAction) {
                        Button(bt("generate","Generate building model")) {
                            do { try apply(candidate,expected);dismiss() } catch { self.error=error.localizedDescription }
                        }.accessibilityIdentifier("building.import.generate")
                    }
                }
            }
            .onChange(of:unit) { _,_ in candidate=nil }
            .onChange(of:height) { _,_ in candidate=nil }
            .onChange(of:thickness) { _,_ in candidate=nil }
            .onChange(of:acceptUnsupported) { _,_ in candidate=nil }
        }
    }
    private func preview() {
        do {
            var source=transfer
            var placement=source.placement ?? CADSketchTransferPlacement(target:.top)
            placement.target = .top;placement.unitScaleMM=scale;placement.acceptOmissions=acceptUnsupported
            source.placement=placement
            expected=document.buildingChangeCount
            candidate=try document.buildingCandidate(from:source,storeyID:storeyID,unitScaleMM:scale,
                wallThicknessMM:thickness,wallHeightMM:height,acceptUnsupported:acceptUnsupported)
            error=nil
        } catch { candidate=nil; self.error=error.localizedDescription }
    }
}

struct CADBuildingSettingsView:View {
    let currentFloorID:UUID
    let save:(CADBuildingDocument,Int)throws->Void
    @State private var draft:CADBuildingDocument
    @State private var expected:Int
    @State private var error:String?
    @Environment(\.dismiss) private var dismiss
    init(model:CADBuildingDocument,currentFloorID:UUID,changeCount:Int,save:@escaping(CADBuildingDocument,Int)throws->Void) {
        self.currentFloorID=currentFloorID;self.save=save
        _draft=State(initialValue:model);_expected=State(initialValue:changeCount)
    }
    var body:some View {
        NavigationStack {
            Form {
                Section { TextField(bt("name","Name"),text:$draft.name) }
                Section(bt("floors","Floors")) {
                    ForEach($draft.storeys) { $floor in
                        DisclosureGroup(floor.name) {
                            TextField(bt("name","Name"),text:$floor.name)
                            TextField(bt("floorElevation","Elevation (mm)"),value:$floor.elevationMM,format:.number)
                            TextField(bt("height","Height"),value:$floor.heightMM,format:.number)
                        }
                    }
                    Button(bt("addFloor","Add floor")) { addFloor(copy:false) }
                    Button(bt("copyFloor","Duplicate current floor")) { addFloor(copy:true) }
                }
                Section(bt("region","Region and applicability")) {
                    Picker(bt("country","Country / region"),selection:$draft.jurisdiction.country) {
                        ForEach(["AU","CN","US","GB","EU","CA","NZ","SG","OTHER"],id:\.self) { Text(bt("country."+$0,$0)).tag($0) }
                    }
                    TextField(bt("subdivision","State / local authority"),text:$draft.jurisdiction.subdivision)
                    TextField(bt("use","Building use / classification"),text:$draft.jurisdiction.buildingUse)
                    TextField(bt("edition","Code edition and adoption date"),text:$draft.jurisdiction.edition)
                    if let url=referenceURL {
                        Link(bt("officialReferences","Official reference documents"),destination:url)
                    }
                }
                Section(bt("rules.title","Project rules")) {
                    Text(bt("rules.scope","Add only rules whose source and applicability you have checked. Results cover the listed measurements; other regulations remain unevaluated."))
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach($draft.rules) { $rule in
                        DisclosureGroup(rule.clause.isEmpty ? bt("rule","Rule"):rule.clause) {
                            Picker(bt("metric","Measurement"),selection:$rule.metric) {
                                ForEach(CADBuildingRule.Metric.allCases,id:\.self) { metric in Text(bt("metric."+metric.rawValue,metric.rawValue)).tag(metric) }
                            }
                            TextField(rule.metric == .spaceArea ? bt("minimumArea","Minimum (m²)"):bt("minimumMM","Minimum (mm)"),value:$rule.minimum,format:.number)
                            TextField(bt("clause","Clause"),text:$rule.clause)
                            TextField(bt("sourceURL","Source URL"),text:$rule.sourceURL).textInputAutocapitalization(.never).keyboardType(.URL)
                            Button(bt("removeRule","Remove rule"),role:.destructive) { draft.rules.removeAll {$0.id == rule.id} }
                        }
                    }
                    Button(bt("addRule","Add sourced rule")) { draft.rules.append(CADBuildingRule(metric:.doorWidth,minimum:0,clause:"",sourceURL:"")) }
                }
                if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            }.navigationTitle(bt("settings","Building settings")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(bt("cancel","Cancel")) { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button(bt("apply","Apply")) {
                    do { try save(draft,expected);dismiss() } catch { self.error=error.localizedDescription }
                }.accessibilityIdentifier("building.settings.apply") }
            }
        }
    }
    private func addFloor(copy:Bool) {
        guard draft.storeys.count<128 else { return }
        let source=draft.storeys.first {$0.id == currentFloorID} ?? draft.storeys[0]
        let elevation=(draft.storeys.map {$0.elevationMM+$0.heightMM}.max() ?? 0)
        let next=CADBuildingStorey(name:bt("floor","Floor")+" \(draft.storeys.count+1)",elevationMM:elevation,heightMM:source.heightMM)
        if copy {
            let originals=draft.elements.filter {$0.storeyID == source.id}
            let ids=Dictionary(uniqueKeysWithValues:originals.map {($0.id,UUID())})
            draft.elements += originals.map { old in var element=old;element.id=ids[old.id]!;element.storeyID=next.id
                if let host=old.hostID { element.hostID=ids[host] };return element }
        }
        draft.storeys.append(next)
    }
    private var referenceURL:URL? {
        let sources=[
            "AU":"https://ncc.abcb.gov.au/",
            "CN":"https://www.mohurd.gov.cn/",
            "US":"https://www.iccsafe.org/products-and-services/i-codes/ibc/",
            "GB":"https://www.gov.uk/government/collections/approved-documents",
            "EU":"https://eurocodes.jrc.ec.europa.eu/",
            "CA":"https://nrc.canada.ca/en/certifications-evaluations-standards/codes-canada/codes-canada-publications/national-building-code-canada-2025",
            "NZ":"https://www.building.govt.nz/building-code-compliance",
            "SG":"https://www1.bca.gov.sg/safety-and-standards/building-control-act/"
        ]
        return sources[draft.jurisdiction.country].flatMap(URL.init(string:))
    }
}
#endif
