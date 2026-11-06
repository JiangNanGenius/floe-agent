// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeManufacturingCore

struct CAMToolEditor: View {
    @Binding var tool:ManufacturingCAM.Tool
    let parameters:()->Void
    @State private var assemblySheet:AssemblySheet?
    private struct AssemblySheet:Identifiable { let id = UUID(); let study:ManufacturingStudy }
    var body:some View {
        Form {
            Section(L("切削部分","Cutting part")) {
                TextField(L("名称","Name"),text:$tool.name).accessibilityIdentifier("cam.tool.name")
                Picker(L("刀形","Shape"),selection:$tool.kind) {
                    ForEach(["flatEndMill","ballNose","drill"],id:\.self) { Text(toolKind($0)).tag($0) }
                }.accessibilityIdentifier("cam.tool.kind")
                ManufacturingNumber(L("直径 · mm","Diameter · mm"),value:$tool.diameterMM,id:"cam.tool.diameter")
                ManufacturingNumber(L("有效刃长 · mm","Cutting length · mm"),value:$tool.cuttingLengthMM,id:"cam.tool.length")
                Stepper(L("刃数","Flutes")+" · \(tool.flutes ?? 4)",value:Binding(get:{ tool.flutes ?? 4 },set:{ tool.flutes = $0 }),in:1...100)
                if tool.kind == "drill" { ManufacturingNumber(L("钻尖夹角 · °","Tip included angle · °"),value:Binding(get:{ tool.tipAngleDegrees ?? 118 },set:{ tool.tipAngleDegrees = $0 }),id:"cam.tool.tipAngle") }
            }
            Section(L("刀杆与刀柄","Shank and holder")) {
                if let assembly = tool.assembly { Text(assembly.name); LabeledContent(L("刀杆直径","Shank diameter"),value:String(format:"%.2f mm",assembly.shankDiameterMM)) }
                Button(L("编辑总成","Edit assembly"),systemImage:"wrench.and.screwdriver") { editAssembly() }.accessibilityIdentifier("cam.tool.assembly")
                if tool.assembly != nil { Button(L("移除总成","Remove assembly"),role:.destructive) { tool.assembly = nil } }
                Toggle(L("设置机床量规长度","Set machine gauge length"),isOn:Binding(get:{ tool.gaugeLengthMM != nil },set:{ tool.gaugeLengthMM = $0 ? 50 : nil }))
                if tool.gaugeLengthMM != nil { ManufacturingNumber(L("刀尖至量规点 · mm","Tip to gauge point · mm"),value:Binding(get:{ tool.gaugeLengthMM ?? 50 },set:{ tool.gaugeLengthMM = $0 }),id:"cam.tool.gauge") }
                Text(L("刀具主轴转速由各工序设置；它与 C 轴定位分别保存。","Live-tool spindle speed belongs to each operation and is separate from C-axis positioning.")).font(.caption).foregroundStyle(.secondary)
            }
            Section { Button(L("全部刀具参数","All tool parameters"),systemImage:"slider.horizontal.3",action:parameters).accessibilityIdentifier("cam.tool.parameters") }
        }.navigationTitle(tool.name)
        .onChange(of:tool.kind) { _,kind in if kind == "drill", tool.tipAngleDegrees == nil { tool.tipAngleDegrees = 118 } }
        .sheet(item:$assemblySheet) { sheet in
            ToolAssemblyEditor(study:sheet.study,cuttingPartName:toolKind(tool.kind)) { tool.assembly = $0.millingAssembly }
        }
    }
    private func editAssembly() {
        var carrier = ManufacturingStudy.shaft(milled:true)
        carrier.milling.toolRadiusMM = tool.diameterMM/2; carrier.milling.widthMM = tool.diameterMM
        carrier.milling.toolLengthMM = tool.cuttingLengthMM; carrier.millingAssembly = tool.assembly
        assemblySheet = .init(study:carrier)
    }
}

struct CAMOperationEditor: View {
    @Binding var operation:ManufacturingCAM.Operation
    let tools:[ManufacturingCAM.Tool]
    let parameters:()->Void
    var body:some View {
        Form {
            Section {
                TextField(L("名称","Name"),text:$operation.name).accessibilityIdentifier("cam.operation.name")
                Toggle(L("执行此工序","Execute this operation"),isOn:$operation.enabled)
                Picker(L("策略","Strategy"),selection:$operation.strategy) { ForEach(["face","pocket","contour","drill","surfaceRaster","swarf"],id:\.self) { Text(strategyName($0)).tag($0) } }
                Picker(L("刀具","Tool"),selection:$operation.toolID) { ForEach(tools) { Text($0.name).tag($0.id) } }.accessibilityIdentifier("cam.operation.tool")
            }
            Section(L("加工特征 · mm","Feature · mm")) {
                if ["face","surfaceRaster"].contains(operation.strategy) {
                    CoordinateFields(label:L("UV 下界","UV minimum"),values:$operation.minUVMM,labels:["U","V"])
                    CoordinateFields(label:L("UV 上界","UV maximum"),values:$operation.maxUVMM,labels:["U","V"])
                }
                if ["pocket","contour","swarf"].contains(operation.strategy) {
                    CoordinateFields(label:L("圆心 UV","Center UV"),values:$operation.centerUVMM,labels:["U","V"])
                    if operation.strategy != "swarf" { ManufacturingNumber(L("圆半径","Circle radius"),value:$operation.radiusMM,id:"cam.operation.radius") }
                }
                if operation.strategy == "contour" {
                    JSONCoordinateField(label:L("矩形顶点 UV；留空使用圆","Rectangle UV vertices; empty uses circle"),values:$operation.contourUVMM)
                    Text(L("非空矩形顶点会替代圆形特征；圆参数会保留。仅支持圆形及轴对齐矩形，其他多边形会明确拒绝。","Nonempty rectangle vertices override the circular feature; circle settings are retained. Supports circles and axis-aligned rectangles; other polygons are rejected.")).font(.caption).foregroundStyle(.secondary)
                }
                if operation.strategy == "drill" { JSONCoordinateField(label:L("孔位 [[U,V],…]","Hole centers [[U,V],…]"),values:$operation.holesUVMM) }
                if operation.strategy != "surfaceRaster" { ManufacturingNumber(L("深度","Depth"),value:$operation.depthMM,id:"cam.operation.depth") }
                if operation.strategy != "drill" {
                    if operation.strategy != "surfaceRaster" {
                    ManufacturingNumber(L("轴向切深","Step down"),value:$operation.stepDownMM,id:"cam.operation.stepDown")
                    }
                    if operation.strategy != "contour" { ManufacturingNumber(L("横向步距","Step over"),value:$operation.stepOverMM,id:"cam.operation.stepOver") }
                    if operation.strategy == "contour" { Toggle(L("顺铣","Climb cutting"),isOn:$operation.climb) }
                }
                if ["pocket","contour","surfaceRaster"].contains(operation.strategy) { ManufacturingNumber(L("侧壁留量","Wall stock"),value:$operation.wallStockMM) }
                if ["face","pocket","contour"].contains(operation.strategy) {
                    ManufacturingNumber(L("底面留量","Floor stock"),value:$operation.floorStockMM)
                    if operation.strategy == "contour" { Stepper(L("重复精修","Spring passes")+" · \(operation.springPasses)",value:$operation.springPasses,in:0...10) }
                }
                if ["surfaceRaster","swarf"].contains(operation.strategy) { Text(L("需要参考网格；采样缺面或姿态不可达会停止并保留错误。侧刃策略的适用范围见能力详情。","Requires a reference mesh. Missing sampled surfaces or unreachable poses stop with an explicit error. Swarf applicability is listed in capability details.")).font(.caption).foregroundStyle(.secondary) }
            }
            if operation.strategy == "drill" { holeCycle }
            feedSettings
            Section(L("坐标系","Coordinate frame")) {
                CoordinateFields(label:L("表面原点","Surface origin"),values:$operation.frame.originMM,labels:["X","Y","Z"])
                CoordinateFields(label:L("单位刀轴（朝主轴）","Unit tool axis (toward spindle)"),values:$operation.frame.axis,labels:["X","Y","Z"])
                CoordinateFields(label:L("单位 U 方向","Unit U direction"),values:$operation.frame.xDirection,labels:["X","Y","Z"])
                Text(L("深度沿刀轴反向；U 与刀轴需单位正交，V 由叉积确定。","Depth is opposite the tool axis. U and the tool axis must be unit and perpendicular; V is their cross product.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("运动与接近","Motion and approach")) {
                ManufacturingNumber(L("安全高度 · mm","Clearance height · mm"),value:$operation.clearanceMM)
                ManufacturingNumber(L("快移 · mm/min","Rapid · mm/min"),value:$operation.rapidMMPerMinute)
                Toggle(L("求解相交 A/C 机型","Solve intersecting A/C machine"),isOn:Binding(get:{ operation.acSeed != nil },set:{ operation.acSeed = $0 ? [0,0,50,0,0] : nil }))
                if operation.acSeed != nil {
                    CoordinateFields(label:L("初始关节","Joint seed"),values:Binding(get:{ operation.acSeed ?? [0,0,50,0,0] },set:{ operation.acSeed = $0 }),labels:["X","Y","Z","A","C"])
                    Text(L("对应刀具需填写量规长度。保留旋转分支，不可达会明确失败。","The tool needs a gauge length. Rotary branches are preserved; unreachable poses fail explicitly.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section { Button(L("全部工序参数","All operation parameters"),systemImage:"slider.horizontal.3",action:parameters).accessibilityIdentifier("cam.operation.parameters") }
        }.navigationTitle(operation.name)
    }
    private var holeCycle:some View {
        Section(L("孔循环","Hole cycle")) {
            Picker(L("循环","Cycle"),selection:$operation.cycle) {
                Text(L("钻孔","Drill")).tag("drill"); Text(L("沉孔停留","Counterbore dwell")).tag("counterBore")
                Text(L("啄钻全退","Peck with full retract")).tag("peck"); Text(L("断屑短退","Chip-break retract")).tag("chipBreak"); Text(L("镗孔进给退刀","Bore with feed retract")).tag("bore")
            }
            if ["peck","chipBreak"].contains(operation.cycle) { ManufacturingNumber(L("分层深度 · mm","Peck depth · mm"),value:$operation.peckDepthMM) }
            if operation.cycle == "chipBreak" { ManufacturingNumber(L("短退量 · mm","Short retract · mm"),value:$operation.chipBreakRetractMM) }
            if operation.cycle == "counterBore" { ManufacturingNumber(L("孔底停留 · s","Bottom dwell · s"),value:$operation.dwellSeconds) }
            ManufacturingNumber(L("突破量 · mm","Breakthrough · mm"),value:$operation.breakThroughMM)
        }
    }
    private var feedSettings:some View {
        Section(L("切削速度与进给","Cutting speeds and feeds")) {
            Toggle(L("记录动力刀具主轴转速","Record live-tool spindle speed"),isOn:Binding(get:{ operation.cutting != nil },set:{ operation.cutting = $0 ? .init(mode:"perMinute",toolSpindleRPM:2000,feedPerToothMM:0.025,feedPerRevolutionMM:0.1) : nil }))
            if operation.cutting != nil {
                Picker(L("进给方式","Feed mode"),selection:Binding(get:{ operation.cutting?.mode ?? "perMinute" },set:{ operation.cutting?.mode = $0 })) {
                    Text("mm/min").tag("perMinute"); Text(L("mm/齿","mm/tooth")).tag("perTooth"); Text(L("mm/转","mm/rev")).tag("perRevolution")
                }
                ManufacturingNumber(L("主轴 · rpm","Spindle · rpm"),value:Binding(get:{ operation.cutting?.toolSpindleRPM ?? 2000 },set:{ operation.cutting?.toolSpindleRPM = $0 }))
                if operation.cutting?.mode == "perTooth" { ManufacturingNumber(L("每齿 · mm","Per tooth · mm"),value:Binding(get:{ operation.cutting?.feedPerToothMM ?? 0.025 },set:{ operation.cutting?.feedPerToothMM = $0 })) }
                if operation.cutting?.mode == "perRevolution" { ManufacturingNumber(L("每转 · mm","Per revolution · mm"),value:Binding(get:{ operation.cutting?.feedPerRevolutionMM ?? 0.1 },set:{ operation.cutting?.feedPerRevolutionMM = $0 })) }
            }
            if operation.cutting == nil || operation.cutting?.mode == "perMinute" { ManufacturingNumber(L("切削进给 · mm/min","Cut feed · mm/min"),value:$operation.feedMMPerMinute,id:"cam.operation.feed") }
            ManufacturingNumber(L("下刀进给 · mm/min","Plunge feed · mm/min"),value:$operation.plungeFeedMMPerMinute)
            if let tool = tools.first(where:{ $0.id == operation.toolID }), let feed = try? operation.effectiveFeed(tool:tool) { LabeledContent(L("换算切削进给","Resolved cut feed"),value:String(format:"%.2f mm/min",feed)) }
        }
    }
}

struct ManufacturingNumber:View {
    let label:String
    @Binding var value:Double
    var id = ""
    init(_ label:String,value:Binding<Double>,id:String = "") { self.label = label; _value = value; self.id = id }
    var body:some View {
        HStack { Text(label); Spacer(); TextField(label,value:$value,format:.number).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).frame(maxWidth:150).accessibilityIdentifier(id) }.frame(minHeight:44)
    }
}
struct CoordinateFields:View {
    let label:String
    @Binding var values:[Double]
    let labels:[String]
    var body:some View {
        DisclosureGroup(label) {
            ForEach(labels.indices,id:\.self) { index in
                ManufacturingNumber(labels[index],value:Binding(get:{ values.indices.contains(index) ? values[index] : 0 },set:{ value in if values.count == labels.count { values[index] = value } }))
            }
        }
    }
}
struct JSONCoordinateField:View {
    let label:String
    @Binding var values:[[Double]]
    @State private var text = ""
    @State private var problem = ""
    var body:some View {
        DisclosureGroup(label) {
            TextEditor(text:$text).font(.body.monospaced()).frame(minHeight:100).autocorrectionDisabled()
            Button(L("应用坐标列表","Apply coordinate list")) {
                do {
                    guard text.utf8.count <= 64_000 else { throw ManufacturingError.invalid("coordinate list budget") }
                    let parsed = try JSONDecoder().decode([[Double]].self,from:Data(text.utf8))
                    guard parsed.count <= 256, parsed.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isFinite && abs($0) <= 100_000 } }) else { throw ManufacturingError.invalid("coordinate list requires at most 256 [U,V] points") }
                    values = parsed; problem = ""
                } catch { problem = error.localizedDescription }
            }
            if !problem.isEmpty { Text(problem).font(.caption).foregroundStyle(.orange) }
        }.onAppear { text = String(decoding:(try? ManufacturingStudy.encoder.encode(values)) ?? Data("[]".utf8),as:UTF8.self) }
    }
}
#endif
