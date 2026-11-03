// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

struct CADMechanicalPanel: View {
    let document: FloeCADDocument
    @Bindable var viewModel: EditorViewModel
    @State private var selected: UUID?
    @State private var operation: CADMechanicalDefinition.Operation = .singleBendSheet
    @State private var fields: [String:String] = [:]
    @State private var initialFields: [String:String] = [:]
    @State private var member: UUID?
    @State private var profile: CADWeldmentMember.Stock = .rectangularTube
    @State private var initialProfile: CADWeldmentMember.Stock = .rectangularTube
    @State private var material = "Steel"
    @State private var initialMaterial = "Steel"
    @State private var quantity = 2
    @State private var teeth = 20
    @State private var initialTeeth = 20
    @State private var generation = 0
    @State private var busy = false
    @State private var message = ""
    @State private var diagnostic = ""
    @State private var cutRows: [[String:Any]] = []
    private func t(_ key: String, _ fallback: String) -> String { FloeCADStrings.text("cad.mechanical."+key,fallback) }
    private var features: [FeatureNode] {
        document.session.document.features.nodes.filter { if case .mechanical = $0.kind { return true }; return false }
    }
    private var editing: (FeatureNode,CADMechanicalDefinition)? {
        guard let selected, let node = features.first(where:{ $0.id.raw == selected }),
              case let .mechanical(definition,_) = node.kind else { return nil }; return (node,definition)
    }
    private var sheetFields: [(String,String)] {
        [("flange_a",t("flangeA","First flange (mm)")),("flange_b",t("flangeB","Second flange (mm)")),
         ("width",t("width","Width (mm)")),("thickness",t("thickness","Thickness (mm)")),
         ("inner_radius",t("radius","Inside radius (mm)")),("bend_degrees",t("angle","Bend angle (°)")),
         ("k_factor",t("k","K factor"))]
    }
    private var gearFields: [(String,String)] {
        [("module",t("module","Module (mm)")),("width",t("width","Width (mm)")),
         ("bore_diameter",t("bore","Bore diameter (mm)")),("maximum_deviation",t("gearPrecision","Involute error limit (mm)"))]
    }
    private var memberFields: [(String,String)] {
        var result = [("width",profile == .roundBar || profile == .roundTube ? t("diameter","Outside diameter (mm)") : t("width","Width (mm)"))]
        if profile == .flatBar || profile == .rectangularTube { result.append(("depth",t("depth","Depth (mm)"))) }
        if profile == .rectangularTube || profile == .roundTube { result.append(("wall",t("wall","Wall (mm)"))) }
        result.append(("length",t("length","Length (mm)"))); return result
    }
    private func profileTitle(_ p: CADWeldmentMember.Stock) -> String {
        switch p {
        case .flatBar: return t("flatBar","Flat bar")
        case .rectangularTube: return t("rectangularTube","Rectangular tube")
        case .roundBar: return t("roundBar","Round bar")
        case .roundTube: return t("roundTube","Round tube")
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Picker(t("part","Part"),selection:$selected) {
                Text(t("new","New part")).tag(UUID?.none)
                ForEach(features) { node in Text(node.name).tag(Optional(node.id.raw)) }
            }
            if selected == nil {
                Picker(t("type","Type"),selection:$operation) {
                    Text(t("sheet","Single bend sheet")).tag(CADMechanicalDefinition.Operation.singleBendSheet)
                    Text(t("weldment","Straight weldment")).tag(CADMechanicalDefinition.Operation.straightWeldment)
                    Text(t("gearBody","Spur gear")).tag(CADMechanicalDefinition.Operation.spurGear)
                }.pickerStyle(.segmented)
            }
            if operation == .spurGear {
                Stepper(t("teeth","Teeth")+": \(teeth)",value:$teeth,in:18...160)
                    .accessibilityIdentifier("CADGearTeeth")
                dimensionFields(gearFields)
                Text(t("gearGrade","B-Rep with approximated involute. 20° straight teeth."))
                    .font(.footnote).foregroundStyle(.secondary)
                Text(t("gearLimits","Full-depth external gear, zero backlash and profile shift. Circular root transition; no cutter undercut or manufacturing quality grade."))
                    .font(.footnote).foregroundStyle(.secondary)
                if let (node,_) = editing, let id=node.outputBodyIDs.first {
                    PanelActionButton(title:LocalizedStringKey(t("gearSelect","Select gear")),systemImage:"gearshape") { viewModel.selectItemBody(id) }
                }
                DisclosureGroup(t("licenses","Licenses")) {
                    Text(CADSpurGearAttribution.notices).font(.footnote).textSelection(.enabled)
                }
            } else if operation == .singleBendSheet {
                Text(t("tangent","Flange lengths start at the bend tangencies. K is your process value."))
                    .font(.footnote).foregroundStyle(.secondary)
                dimensionFields(sheetFields)
                if let (node,_) = editing, node.outputBodyIDs.count == 2 {
                    PanelActionGrid {
                        PanelActionButton(title:LocalizedStringKey(t("formed","Select formed part")),systemImage:"cube") {
                            viewModel.selectItemBody(node.outputBodyIDs[0])
                        }
                        PanelActionButton(title:LocalizedStringKey(t("flat","Select flat blank")),systemImage:"rectangle") {
                            viewModel.selectItemBody(node.outputBodyIDs[1])
                        }
                    }
                }
            } else {
                if let (_,definition) = editing {
                    Picker(t("member","Member"),selection:$member) {
                        ForEach(Array(definition.members.enumerated()),id:\.element.id) { index,m in
                            Text("\(index+1) · \(profileTitle(m.profile))").tag(Optional(m.id))
                        }
                    }
                }
                Picker(t("profile","Stock profile"),selection:$profile) {
                    ForEach(CADWeldmentMember.Stock.allCases,id:\.rawValue) { p in Text(profileTitle(p)).tag(p) }
                }
                dimensionFields(memberFields)
                TextField(t("material","Material"),text:$material).textFieldStyle(.roundedBorder)
                if selected == nil { Stepper(t("quantity","Quantity") + ": \(quantity)",value:$quantity,in:1...16) }
                Text(t("squareEnds","Straight stock with square cut ends."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            PanelActionGrid {
                PanelActionButton(title:LocalizedStringKey(selected == nil ? t("create","Create part") : t("apply","Apply changes")),
                                  systemImage:"checkmark",disabled:busy || document.isReadOnly) { apply() }
                if selected != nil, operation == .straightWeldment {
                    PanelActionButton(title:LocalizedStringKey(t("cutList","Cut list")),systemImage:"list.bullet.rectangle",disabled:busy) { readCutList() }
                }
            }
            if !message.isEmpty { Text(message).font(.callout).accessibilityIdentifier("CADMechanicalStatus") }
            if !cutRows.isEmpty {
                PanelSection(title:t("cutList","Cut list")) {
                    ForEach(cutRows.indices,id:\.self) { index in
                        let row = cutRows[index]
                        let stock = (row["profile"] as? String).flatMap(CADWeldmentMember.Stock.init(rawValue:)) ?? .flatBar
                        let length = (row["length"] as? Double) ?? 0
                        Text("\(profileTitle(stock)) \(stockSize(row, stock)) · \(row["material"] as? String ?? "") · \(String(format:"%.3f",length)) mm × \(row["quantity"] as? Int ?? 1)")
                            .font(.callout).textSelection(.enabled)
                    }
                }
            }
            if !diagnostic.isEmpty {
                DisclosureGroup(t("details","Details")) { Text(diagnostic).font(.footnote).textSelection(.enabled) }
            }
            Text(t("scope","One straight bend, square-cut stock or a 20° external spur gear. Multiple bends, miters and other gear types are unavailable."))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .disabled(busy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CADMechanicalPanel")
        .onAppear { load() }
        .onChange(of:selected) { _,_ in load() }
        .onChange(of:operation) { _,_ in if selected == nil { loadDefaults() } }
        .onChange(of:member) { _,_ in loadMember() }
    }
    private func stockSize(_ row: [String:Any], _ stock: CADWeldmentMember.Stock) -> String {
        func n(_ key: String) -> String { String(format:"%.3g",row[key] as? Double ?? 0) }
        switch stock {
        case .flatBar: return n("width") + "×" + n("depth") + " mm"
        case .rectangularTube: return n("width") + "×" + n("depth") + "×" + n("wall") + " mm"
        case .roundBar: return "Ø" + n("width") + " mm"
        case .roundTube: return "Ø" + n("width") + "×" + n("wall") + " mm"
        }
    }
    private func dimensionFields(_ rows: [(String,String)]) -> some View {
        ForEach(rows,id:\.0) { key,title in
            HStack {
                Text(title).font(.callout)
                Spacer()
                TextField("mm",text:Binding(get:{ fields[key] ?? "" },set:{ fields[key] = $0 }))
                    .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder).frame(maxWidth:200)
                    .accessibilityIdentifier("CADMechanicalField."+key)
            }.frame(minHeight:44)
        }
    }
    private func string(_ e: Expr) -> String { e.formula ?? String(e.value) }
    private func loadDefaults() {
        fields = ["flange_a":"40","flange_b":"30","width":operation == .singleBendSheet ? "25" : "20",
                  "thickness":"2","inner_radius":"4","bend_degrees":"90","k_factor":"0.5",
                  "depth":"10","wall":"2","length":"100"]
        if operation == .spurGear { fields=["module":"2","width":"8","bore_diameter":"10","maximum_deviation":"0.001"] }
        teeth=20;initialTeeth=20
        initialFields = fields; material = "Steel"; initialMaterial = material
        profile = .rectangularTube; initialProfile = profile
        generation = document.session.changeCount; cutRows = []
    }
    private func load() {
        message = ""; diagnostic = ""; cutRows = []
        guard let (_,definition) = editing else { loadDefaults(); return }
        operation = definition.operation; generation = document.session.changeCount
        if let gear=definition.gear {
            fields=Dictionary(uniqueKeysWithValues:definition.expressions.map { ($0.name,string($0.expr)) })
            initialFields=fields;teeth=gear.teeth;initialTeeth=teeth;member=nil
        } else if definition.sheet != nil {
            fields = Dictionary(uniqueKeysWithValues:definition.expressions.map { ($0.name,string($0.expr)) })
            initialFields = fields; member = nil
        } else { member = definition.members.first?.id; loadMember() }
    }
    private func loadMember() {
        guard let (_,definition) = editing, let m = definition.members.first(where:{ $0.id == member }) else { return }
        fields = ["width":string(m.width),"depth":string(m.depth),"wall":string(m.wall),"length":string(m.length)]
        initialFields = fields; profile = m.profile; initialProfile = profile
        material = m.material; initialMaterial = material
        generation = document.session.changeCount; cutRows = []
    }
    private func apply() {
        guard generation == document.session.changeCount else {
            message = t("stale","The design changed. Reopen the part settings."); return
        }
        let action: String, args: [String:Any]
        if let (node,_) = editing {
            var changes: [String:Any] = fields.filter { initialFields[$0.key] != $0.value }.mapValues { $0 as Any }
            if operation == .spurGear,teeth != initialTeeth { changes["teeth"]=teeth }
            if operation == .straightWeldment {
                if profile != initialProfile { changes["profile"] = profile.rawValue }
                if material != initialMaterial { changes["material"] = material }
                if let member { changes["member_id"] = member.uuidString }
            }
            guard !changes.isEmpty, !(changes.count == 1 && changes["member_id"] != nil) else { return }
            action = "mechanical.update"; args = ["feature_id":node.id.raw.uuidString,"changes":changes,"expected_change_count":generation]
        } else if operation == .spurGear {
            action="gear.create"
            var values:[String:Any]=["teeth":teeth,"expected_change_count":generation]
            for (key,_) in gearFields { values[key]=fields[key] }
            args=values
        } else if operation == .singleBendSheet {
            action = "sheetMetal.create"
            var values: [String:Any] = [:]; for (key,_) in sheetFields { values[key] = fields[key] }
            values["expected_change_count"] = generation; args = values
        } else {
            action = "weldment.create"
            let width = ExpressionEvaluator.evaluate(fields["width"] ?? "20",variables:document.session.variableValues()) ?? 20
            let rows: [[String:Any]] = (0..<quantity).map { index in
                ["profile":profile.rawValue,"width":fields["width"] ?? "20","depth":fields["depth"] ?? "10",
                 "wall":fields["wall"] ?? "2","length":fields["length"] ?? "100","material":material,
                 "placement":["translation":[Double(index)*(width+10),0,0],"rotation":[0,0,0,1],"scale":1]]
            }
            args = ["members":rows,"expected_change_count":generation]
        }
        busy = true
        let reply = CADParameterService(document:document).handle(action:action,args:args)
        guard reply["ok"] as? Bool == true else {
            busy = false; message = t("failed","The part could not be updated. The previous shape was kept.")
            diagnostic = (reply["details"] as? [String])?.joined(separator:"\n") ?? reply["message"] as? String ?? ""
            // A rejected transaction may advance its fence while restoring the exact state.
            generation = document.session.changeCount; return
        }
        if let raw = reply["feature_id"] as? String { selected = UUID(uuidString:raw) }
        Task { @MainActor in
            let saved = await document.save(); busy = false; load()
            message = saved.succeeded ? t("applied","Applied") : t("saveFailed","The part changed but could not be saved. Try saving again.")
            if !saved.succeeded { diagnostic = saved.error ?? "" }
        }
    }
    private func readCutList() {
        guard let selected else { return }
        let reply = CADParameterService(document:document).handle(action:"weldment.cutList",args:["feature_id":selected.uuidString])
        cutRows = reply["groups"] as? [[String:Any]] ?? []
        if reply["ok"] as? Bool != true {
            message = t("listFailed","The cut list is unavailable for these edited members.")
            diagnostic = reply["message"] as? String ?? ""
        } else { message = ""; diagnostic = "" }
    }
}
#endif
