// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeInteriorCore

struct CabinetWorkbenchPanel:BuildingLocalizedView {
    @Environment(\.locale) var buildingLocale
    let session: BuildingWorkspaceSession
    var body: some View {
        @Bindable var editor=session.editors.cabinet
        @Bindable var state=session
        ScrollView {
            VStack(alignment:.leading,spacing:24){
                ViewThatFits(in:.horizontal){HStack{dimensions};VStack{dimensions}}
                if session.projectActions != nil {
                    Button{session.applyCabinet()}label:{Label(buildingText("放入或更新模型","Place or update model"),systemImage:"cube")}
                        .buttonStyle(.bordered).accessibilityIdentifier("building.cabinet.apply")
                }
                if let error=session.panelErrors[.cabinet]{Text(error).foregroundStyle(.red)}
                if let assembly=session.editors.cabinetAssembly,let sheet=session.editors.cabinetSheet {
                    HStack(spacing:24){
                        LabeledContent(buildingText("板件","Panels"),value:String(assembly.panels.count))
                        LabeledContent(buildingText("视图","Views"),value:String(sheet.views.count))
                    }
                    Text(buildingText("组合页预览 · 示意","Combination sheet preview · Schematic")).font(.headline)
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:230))],spacing:18){
                        ForEach(sheet.views){view in
                            VStack(alignment:.leading){
                                CabinetViewThumbnail(assembly:assembly,view:view).frame(height:170)
                                Text(viewTitle(view.kind)).font(.subheadline.bold())
                                Text("1:"+String(Int(view.scaleDenominator))).font(.caption).foregroundStyle(.secondary)
                            }.padding().background(.quaternary,in:RoundedRectangle(cornerRadius:12))
                        }
                    }
                    Text(buildingText("当前检查视图与尺寸关联；正式 CAD 投影、隐藏线和图纸文件另行验证。","This preview checks view and dimension associations. Final CAD projection, hidden lines and drawing files require separate verification."))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(buildingText("关联尺寸（毫米）","Associated dimensions (mm)")).font(.headline)
                    ForEach(sheet.dimensions.filter{$0.role.hasPrefix("overall") || $0.role=="carcass-depth"}){dimension in
                        LabeledContent(dimensionTitle(dimension.role),value:dimension.valueMM.formatted(.number.precision(.fractionLength(1))))
                    }
                    HStack{
                        TextField(buildingText("图纸补充说明","Sheet note"),text:$state.cabinetNoteDraft)
                        Button(buildingText("添加说明","Add note")){
                            editor.value.manualNotes.append(.init(text:session.cabinetNoteDraft,positionMM:.init(20,280)))
                            session.cabinetNoteDraft=""
                        }.disabled(session.cabinetNoteDraft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    }
                    ForEach(editor.value.manualNotes){Text($0.text).font(.callout)}
                    if !sheet.orphanedPresentation.isEmpty {
                        Text(buildingText("部分人工标注需要重新关联。","Some manual annotations need reassociation.")).foregroundStyle(.orange)
                    }
                }
            }.padding(24)
        }.disabled(session.busy)
        .onAppear{rebuild()}
        .onChange(of:editor.value){_,_ in rebuild()}
    }
    @ViewBuilder private var dimensions:some View {
        @Bindable var editor=session.editors.cabinet
        BuildingNumberField(title:buildingText("宽 mm","Width mm"),value:$editor.value.recipe.widthMM,inputs:session.numberInputs,id:"cabinet.width")
        BuildingNumberField(title:buildingText("高 mm","Height mm"),value:$editor.value.recipe.heightMM,inputs:session.numberInputs,id:"cabinet.height")
        BuildingNumberField(title:buildingText("柜身深 mm","Carcass depth mm"),value:$editor.value.recipe.carcassDepthMM,inputs:session.numberInputs,id:"cabinet.depth")
    }
    private func rebuild(){
        guard session.numberInputs.commit(prefix:"cabinet") else{return}
        do {
            let value=session.editors.cabinet.value
            let built=try CabinetBuilder.build(value.recipe)
            var previous=try session.editors.cabinetSheet ?? CabinetSheetPlanner.make(built)
            previous.manualNotes=value.manualNotes;previous.dimensionPresentation=value.dimensionPresentation;previous.orphanedPresentation=[]
            let sheet=try CabinetSheetPlanner.make(built,previous:previous)
            session.editors.cabinetAssembly=built;session.editors.cabinetSheet=sheet;session.panelErrors[.cabinet]=nil
        } catch {session.panelErrors[.cabinet]=buildingError(error)}
    }
    private func viewTitle(_ kind:CabinetTechnicalView)->String{switch kind {
        case .front:buildingText("正视图","Front");case .side:buildingText("侧视图","Side")
        case .top:buildingText("顶视图","Top");case .section:buildingText("剖视规划","Section plan")
        case .isometric:buildingText("斜视图","Isometric");case .internalElevation:buildingText("内部立面","Internal elevation")
    }}
    private func dimensionTitle(_ role:String)->String{switch role {
        case "overall-width":buildingText("整体宽度","Overall width")
        case "overall-height":buildingText("整体高度","Overall height")
        case "carcass-depth":buildingText("柜身深度","Carcass depth")
        default:buildingText("含门板总深度","Overall depth with fronts")
    }}
}

/// An edge-only inspection thumbnail. It does not produce CAD geometry or claim
/// hidden-line removal/cutting. Sections are deliberately labelled as plans.
private struct CabinetViewThumbnail:BuildingLocalizedView {
    @Environment(\.locale) var buildingLocale
    let assembly: CabinetAssembly
    let view: CabinetSheetViewSpec
    var body: some View {
        Canvas { context, size in
            let panels = assembly.panels.filter { view.panelIDs.contains($0.id) }
            func dot(_ p: InteriorVector3, _ axis: InteriorVector3) -> Double { p.x * axis.x + p.y * axis.y + p.z * axis.z }
            let points = panels.flatMap { panel in
                [0.0, panel.sizeMM.x].flatMap { x in
                    [0.0, panel.sizeMM.y].flatMap { y in
                        [0.0, panel.sizeMM.z].map { z in InteriorVector3(panel.originMM.x + x, panel.originMM.y + y, panel.originMM.z + z) }
                    }
                }
            }
            let xs = points.map { dot($0, view.horizontalInBuilding) }, ys = points.map { dot($0, view.verticalInBuilding) }
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return }
            let scale = min((size.width - 16) / max(1, maxX - minX), (size.height - 16) / max(1, maxY - minY))
            func projected(_ p: InteriorVector3) -> CGPoint {
                .init(x: (dot(p, view.horizontalInBuilding) - (minX + maxX) / 2) * scale + size.width / 2,
                      y: size.height / 2 - (dot(p, view.verticalInBuilding) - (minY + maxY) / 2) * scale)
            }
            for panel in panels {
                var path = Path()
                for axis in 0..<3 {
                    for a in [0.0, 1.0] { for b in [0.0, 1.0] {
                        var first = [panel.originMM.x, panel.originMM.y, panel.originMM.z]
                        let sizes = [panel.sizeMM.x, panel.sizeMM.y, panel.sizeMM.z]
                        first[(axis + 1) % 3] += a * sizes[(axis + 1) % 3]
                        first[(axis + 2) % 3] += b * sizes[(axis + 2) % 3]
                        var second = first; second[axis] += sizes[axis]
                        path.move(to: projected(.init(first[0], first[1], first[2])))
                        path.addLine(to: projected(.init(second[0], second[1], second[2])))
                    } }
                }
                context.stroke(path, with: .color(panel.role == .front ? .orange : .accentColor), lineWidth: 0.7)
            }
        }.accessibilityLabel(buildingText("柜体边线示意预览", "Cabinet edge schematic preview"))
    }
}
