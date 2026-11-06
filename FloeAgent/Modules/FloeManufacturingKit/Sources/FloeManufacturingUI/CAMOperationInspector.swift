// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeManufacturingCore
import FloeManufacturingParameters

struct CAMOperationInspector:View {
    let value:CAMOperationInspection
    let close:()->Void
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    Text(camChapterName(value.chapter)).font(.headline).accessibilityIdentifier("cam.inspector.operation")
                    Text(value.study.name).font(.subheadline).foregroundStyle(.secondary)
                    row(L("刀路数量","Toolpaths"),String(value.chapter.pathIDs.count))
                    if let a = value.chapter.start,let b = value.chapter.end { row(L("范围","Range"),String(format:"%.2f – %.2f %@",a,b,value.metric == .seconds ? "s":"mm")) }
                }
                if let tool = value.tool {
                    Section(L("刀具","Tool")) {
                        row(L("名称","Name"),tool.name)
                        row(L("直径","Diameter"),number(tool.diameterMM,"mm"),id:"cam.inspector.diameter")
                        row(L("刃长","Cutting length"),number(tool.cuttingLengthMM,"mm"))
                        if let length = tool.gaugeLengthMM { row(L("规长","Gauge length"),number(length,"mm")) }
                        if let flutes = tool.flutes { row(L("刃数","Flutes"),String(flutes)) }
                        if let angle = tool.tipAngleDegrees { row(L("钻尖角","Tip angle"),number(angle,"°")) }
                        NavigationLink(L("全部刀具参数","All tool parameters")) { CAMParameterInspection(study:value.study,scope:.tool(tool.id)) }.accessibilityIdentifier("cam.inspector.tool-parameters")
                    }
                }
                if let setup = value.turningSetup {
                    Section(L("车刀与进退刀","Turning insert and entry/exit")) {
                        row(L("刀片形状","Insert shape"),setup.insertShape)
                        row(L("刀片边长","Insert edge length"),number(setup.insertEdgeLengthMM,"mm"))
                        row(L("安装角","Mounting angle"),number(setup.insertRotationDegrees,"°"))
                        row(L("刀尖半径","Nose radius"),number(value.study.turning.toolNoseRadiusMM,"mm"))
                        row(L("进刀角","Entry angle"),number(setup.leadinAngleDegrees,"°"))
                        row(L("退刀角","Exit angle"),number(setup.leadoutAngleDegrees,"°"))
                        row(L("安全间距","Clearance"),number(setup.clearanceMM,"mm"))
                    }
                    Section(L("车削工艺","Turning process")) {
                        row(L("径向步距","Radial step over"),number(value.study.turning.stepOverMM,"mm"))
                        row(L("余量","Allowance"),number(value.study.turning.allowanceMM,"mm"))
                        if let cutting = value.study.turningCutting {
                            row(L("主轴方式","Spindle mode"),cutting.spindleMode == .fixedRPM ? L("定转速","Fixed RPM"):L("恒线速","Constant surface speed"))
                            if cutting.spindleMode == .fixedRPM { row(L("主轴转速","Spindle speed"),number(cutting.spindleRPM,"rpm")) }
                            else { row(L("切削线速度","Surface speed"),number(cutting.surfaceSpeedMPerMinute,"m/min"));row(L("转速上限","RPM limit"),number(cutting.maxSpindleRPM,"rpm")) }
                            if cutting.feedMode == .mmPerRevolution { row(L("每转进给","Feed per revolution"),number(cutting.feedMMPerRevolution,"mm/rev")) }
                        } else { row(L("主轴转速","Spindle speed"),L("未提供","Not supplied")) }
                    }
                }
                if let op = value.operation {
                    Section(L("工艺参数","Process parameters")) {
                        row(L("加工深度","Depth"),number(op.depthMM,"mm"))
                        row(L("每层切深","Step down"),number(op.stepDownMM,"mm"))
                        row(L("侧向步距","Step over"),number(op.stepOverMM,"mm"))
                        row(L("侧壁余量","Wall allowance"),number(op.wallStockMM,"mm"))
                        row(L("底面余量","Floor allowance"),number(op.floorStockMM,"mm"))
                        row(L("安全高度","Clearance"),number(op.clearanceMM,"mm"))
                        row(L("下刀进给","Plunge feed"),number(op.plungeFeedMMPerMinute,"mm/min"))
                        if let tool = value.tool { row(L("切削进给","Cutting feed"),number((try? op.effectiveFeed(tool:tool)) ?? op.feedMMPerMinute,"mm/min")) }
                        if let cutting = op.cutting { row(L("刀具主轴转速","Tool spindle speed"),number(cutting.toolSpindleRPM,"rpm")) }
                        NavigationLink(L("全部工序参数","All operation parameters")) { CAMParameterInspection(study:value.study,scope:.operation(op.id)) }.accessibilityIdentifier("cam.inspector.operation-parameters")
                    }
                }
                if value.legacyMilling {
                    Section(L("动力刀具铣槽","Live-tool slot milling")) {
                        row(L("刀具直径","Tool diameter"),number(value.study.milling.toolRadiusMM*2,"mm"),id:"cam.inspector.diameter")
                        row(L("刀具长度","Tool length"),number(value.study.milling.toolLengthMM,"mm"))
                        row(L("槽宽","Slot width"),number(value.study.milling.widthMM,"mm"))
                        row(L("槽深","Slot depth"),number(value.study.milling.depthMM,"mm"))
                        row(L("切削进给","Cutting feed"),number(value.study.milling.feedMMPerMinute,"mm/min"))
                        row(L("C轴定位角","C-axis index"),number(value.study.milling.angleDegrees,"°"))
                    }
                }
                Section {
                    if !value.study.stock.isBox { row(L("毛坯半径 R","Stock radius R"),number(value.study.stock.radiusMM,"mm"),id:"cam.inspector.stock-radius") }
                    row(L("网格分辨率","Mesh resolution"),number(value.study.stock.resolutionMM,"mm"))
                    NavigationLink(L("全部参数（含低频项）","All parameters, including rare settings")) { CAMParameterInspection(study:value.study,scope:.study) }.accessibilityIdentifier("cam.inspector.all-parameters")
                } header: { Text(L("工件与机床","Workpiece and machine")) }
                footer: { Text(L("查看当前计算所用的设置。修改后请返回工序设置并重新生成刀路。","These are the settings for the current result. Change them in operation setup, then regenerate toolpaths.")) }
            }.navigationTitle(L("工序与刀具","Operation and tool")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button(L("完成","Done"),action:close).accessibilityIdentifier("cam.inspector.done") } }
        }.accessibilityIdentifier("cam.inspector")
    }
    private func number(_ x:Double,_ unit:String)->String { String(format:"%.3f",x)+" "+unit }
    private func row(_ title:String,_ text:String,id:String? = nil)->some View {
        LabeledContent(title) { Text(text).monospacedDigit().multilineTextAlignment(.trailing).textSelection(.enabled).accessibilityIdentifier(id ?? "cam.inspector.value") }
    }
}

/// Reuses the existing complete catalog and owner-aware projection. Values are
/// immutable; the preview never applies an edited parameter to a stale result.
private struct CAMParameterInspection:View {
    let study:ManufacturingStudy
    let scope:ManufacturingParameterScope
    @State private var query = ""
    @State private var includeRare = true
    private let catalog = ManufacturingParameterCatalog.standard
    var body:some View {
        let snapshot = study.parameterSnapshot(scope:scope)
        let matches = catalog.search(query:query,includeRare:includeRare).filter { study.includesParameter($0,scope:scope) }
        List {
            Section { Toggle(L("包含低频参数","Include rare parameters"),isOn:$includeRare).accessibilityIdentifier("cam.parameters.rare") }
            ForEach(catalog.groups) { group in
                let fields = matches.filter { $0.groupID == group.id }
                if !fields.isEmpty {
                    Section(L(group.nameZH,group.nameEN)) {
                        ForEach(fields,id:\.id) { d in
                            VStack(alignment:.leading,spacing:5) {
                                HStack { Text(L(d.nameZH,d.nameEN));Spacer();Text(parameterUnit(d.unit)).foregroundStyle(.secondary) }
                                Text(parameterText(snapshot.value(d.id))).textSelection(.enabled)
                                HStack { if d.rare { Text(L("低频","Rare")) };Text(parameterSupport(d,active:study.parameterIsActive(d,scope:scope))) }.font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical,3).accessibilityIdentifier("cam.parameter."+d.id)
                        }
                    }
                }
            }
            if !snapshot.values.keys.filter({ catalog.lookup($0) == nil }).isEmpty {
                Section(L("扩展配置","Extension configuration")) {
                    ForEach(snapshot.values.keys.filter { catalog.lookup($0) == nil }.sorted(),id:\.self) { id in LabeledContent(id, value:parameterText(snapshot.value(id))) }
                }
            }
        }.navigationTitle(L("参数明细","Parameter details"))
            .searchable(text:$query,prompt:L("搜索参数","Search parameters"))
            .accessibilityIdentifier("cam.parameters.list")
    }
}
#endif
