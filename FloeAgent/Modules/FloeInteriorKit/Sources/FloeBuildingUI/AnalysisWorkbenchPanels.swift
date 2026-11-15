// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeBuildingSystems
import FloeBuildingAnalysis

struct RadioWorkbenchPanel:BuildingLocalizedView {
    @Environment(\.locale) var buildingLocale
    let session:BuildingWorkspaceSession
    var body:some View {
        @Bindable var editor=session.editors.radio
        ScrollView {
            VStack(alignment:.leading,spacing:22){
                Text(buildingText("当前示例使用合成 AP 与墙体参数。真实工程需使用对应频段的设备、墙材及现场依据。","The sample uses synthetic AP and wall parameters. Real projects require band-specific equipment, material and field evidence.")).foregroundStyle(.secondary)
                ForEach($editor.value.accessPoints){$ap in
                    GroupBox(ap.id){
                        VStack(alignment:.leading,spacing:10){
                            BuildingNumberField(title:"AP X (m)",value:$ap.positionM.x,inputs:session.numberInputs,id:"radio."+ap.id+".x")
                            BuildingNumberField(title:"AP Y (m)",value:$ap.positionM.y,inputs:session.numberInputs,id:"radio."+ap.id+".y")
                            BuildingNumberField(title:buildingText("安装高度 m","Mount height m"),value:$ap.positionM.z,inputs:session.numberInputs,id:"radio."+ap.id+".z")
                            BuildingNumberField(title:buildingText("参考接收功率 dBm","Reference received power dBm"),value:$ap.referencePower.dBm,inputs:session.numberInputs,id:"radio."+ap.id+".reference")
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }
                }
                BuildingNumberField(title:buildingText("路径损耗指数","Path loss exponent"),value:$editor.value.assumptions.pathLossExponent,inputs:session.numberInputs,id:"radio.exponent")
                Button(buildingText("重新估算","Recalculate")){session.calculateRadio()}.buttonStyle(.borderedProminent).accessibilityIdentifier("building.radio.calculate")
                if let result=session.editors.radioResult {
                    if isStale(result){Text(buildingText("输入或工程版本已变化，请重新估算。","Inputs or project revision changed. Recalculate.")).foregroundStyle(.orange)}
                    BuildingGridMap(values:result.samples.map(\.strongestEstimatedPowerDBm),columns:result.columns,rows:result.rows,low:-95,high:-35,unit:"dBm").frame(height:300)
                    Text(String(format:"%.1f … %.1f dBm",result.minimumEstimatedPowerDBm,result.maximumEstimatedPowerDBm)).font(.headline).accessibilityIdentifier("building.radio.result")
                    Text(buildingText("快速模型不含反射、绕射、干扰或容量计算；精细传播仿真将另行接入。","The quick model omits reflections, diffraction, interference and capacity. Detailed propagation is a separate integration.")).font(.callout).foregroundStyle(.secondary)
                }
            }.padding(24)
        }.disabled(session.busy)
    }
    private func isStale(_ result:RadioEstimateResult)->Bool {
        var current=session.editors.radio.value;current.projectRevision=session.snapshot?.project.revision ?? 0
        return (try? result.isStale(for:current)) != false
    }
}

struct LightingWorkbenchPanel:BuildingLocalizedView {
    @Environment(\.locale) var buildingLocale
    let session:BuildingWorkspaceSession
    var body:some View {
        @Bindable var editor=session.editors.lighting
        ScrollView {
            VStack(alignment:.leading,spacing:22){
                Text(buildingText("当前计算直射照度，并保留 IES 绝对光强；反射、日光和正式照明报告待专业引擎接入。","This stage uses absolute IES intensity for direct illuminance. Specialist integration will add interreflection, daylight and final reports.")).foregroundStyle(.secondary)
                Button(buildingText("使用合成配光示例","Use synthetic photometry")){
                    do {
                        var value=editor.value;value.profile=try IESPhotometryParser.parse(Self.syntheticIES)
                        value.profileName=buildingText("合成测试配光 · 100 cd","Synthetic test photometry · 100 cd");editor.value=value
                    } catch {session.error=buildingError(error)}
                }.accessibilityIdentifier("building.lighting.sample")
                Text(editor.value.profileName.isEmpty ? buildingText("尚未载入配光","No photometry loaded"):editor.value.profileName).font(.headline)
                HStack{
                    BuildingNumberField(title:buildingText("房间宽 m","Room width m"),value:$editor.value.widthM,inputs:session.numberInputs,id:"lighting.width")
                    BuildingNumberField(title:buildingText("房间深 m","Room depth m"),value:$editor.value.depthM,inputs:session.numberInputs,id:"lighting.depth")
                }
                HStack{
                    BuildingNumberField(title:buildingText("灯具高度 m","Luminaire height m"),value:$editor.value.lampHeightM,inputs:session.numberInputs,id:"lighting.lampHeight")
                    BuildingNumberField(title:buildingText("工作面高度 m","Workplane height m"),value:$editor.value.workplaneHeightM,inputs:session.numberInputs,id:"lighting.workplane")
                }
                Slider(value:Binding(get:{session.editors.lightingPreviewOutput ?? editor.value.output},set:{session.editors.lightingPreviewOutput=$0}),in:0...1,onEditingChanged:{active in if !active{session.commitLightingPreview()}}){Text(buildingText("调光比例","Output scale"))}
                Button(buildingText("计算照度","Calculate illuminance")){session.calculateLighting()}.buttonStyle(.borderedProminent).disabled(editor.value.profile==nil).accessibilityIdentifier("building.lighting.calculate")
                if let result=session.editors.lightingResult {
                    if isStale(result){Text(buildingText("输入或工程版本已变化，请重新计算。","Inputs or project revision changed. Recalculate.")).foregroundStyle(.orange)}
                    BuildingGridMap(values:result.samples.map(\.lux),columns:result.columns,rows:result.rows,low:0,high:max(1,result.maximumLux),unit:"lx").frame(height:300)
                    LabeledContent(buildingText("平均照度","Average illuminance"),value:String(format:"%.2f lx",result.averageLux)).accessibilityIdentifier("building.lighting.result")
                    LabeledContent(buildingText("最小／最大","Minimum / maximum"),value:String(format:"%.2f / %.2f lx",result.minimumLux,result.maximumLux))
                    ShareLink(item:result.csv()){Label(buildingText("分享照度数据","Share illuminance data"),systemImage:"square.and.arrow.up")}
                }
            }.padding(24)
        }.disabled(session.busy).onDisappear{session.commitLightingPreview()}
    }
    private func isStale(_ result:LightingAnalysisResult)->Bool {
        guard let current=try? session.editors.lighting.value.request(revision:session.snapshot?.project.revision ?? 0) else{return true}
        return (try? result.isStale(for:current)) != false
    }
    private static let syntheticIES="""
    IESNA:LM-63-2002
    [TEST] SYNTHETIC TEST PROFILE; NOT A PRODUCT
    TILT=NONE
    1 -1 1 3 1 1 2 0.1 0.1 0.05
    1 1 12
    0 90 180
    0
    100 100 100
    """
}

struct HVACWorkbenchPanel:BuildingLocalizedView {
    @Environment(\.locale) var buildingLocale
    let session:BuildingWorkspaceSession
    var body:some View {
        @Bindable var editor=session.editors.hvac
        Form {
            Section {
                Text(buildingText("初始参数为合成示例。当前按给定温差、围护传热、新风和得热计算；不是完整设备选型或规范校核。","Initial values are synthetic. This stage uses supplied temperatures, envelope transfer, outdoor air and gains; complete sizing and compliance are pending."))
            }
            Section(buildingText("设计条件","Design conditions")){
                Picker(buildingText("房间","Room"),selection:$editor.value.roomID){
                    Text(buildingText("示例房间","Synthetic room")).tag("synthetic-room")
                    ForEach(session.snapshot?.rooms ?? []){room in Text(room.name).tag(room.id.rawValue.uuidString)}
                }
                Picker(buildingText("工况","Mode"),selection:$editor.value.mode){
                    Text(buildingText("制冷","Cooling")).tag(HVACDesignMode.cooling)
                    Text(buildingText("供暖","Heating")).tag(HVACDesignMode.heating)
                }
                BuildingNumberField(title:buildingText("室内 °C","Indoor °C"),value:$editor.value.indoorC,inputs:session.numberInputs,id:"hvac.indoor")
                BuildingNumberField(title:buildingText("室外 °C","Outdoor °C"),value:$editor.value.outdoorC,inputs:session.numberInputs,id:"hvac.outdoor")
                BuildingNumberField(title:buildingText("新风 m³/s","Outdoor air m³/s"),value:$editor.value.outdoorAirM3PerS,inputs:session.numberInputs,id:"hvac.air")
                BuildingNumberField(title:buildingText("内部显热 W","Internal sensible W"),value:$editor.value.internalSensibleW,inputs:session.numberInputs,id:"hvac.internal")
                TextField(buildingText("条件来源","Conditions source"),text:$editor.value.conditionsEvidenceID)
            }
            Section(buildingText("围护输入","Envelope input")){
                ForEach(editor.value.envelope.indices,id:\.self){index in
                    BuildingNumberField(title:buildingText("面积 m²","Area m²"),value:$editor.value.envelope[index].areaM2,inputs:session.numberInputs,id:"hvac."+editor.value.envelope[index].id+".area")
                    BuildingNumberField(title:"U (W/m²K)",value:$editor.value.envelope[index].transmittanceWPerM2K,inputs:session.numberInputs,id:"hvac."+editor.value.envelope[index].id+".u")
                    TextField(buildingText("材料依据","Material evidence"),text:$editor.value.envelope[index].evidenceID)
                }
            }
            Section {
                Button(buildingText("计算初步负荷","Calculate screening load")){session.calculateHVAC()}.accessibilityIdentifier("building.hvac.calculate")
                if let result=session.editors.hvacResult {
                    if isStale(result){Text(buildingText("输入或工程版本已变化，请重新计算。","Inputs or project revision changed. Recalculate.")).foregroundStyle(.orange)}
                    LabeledContent(buildingText("初步总负荷","Screening total load"),value:String(format:"%.1f W",result.totalW))
                    LabeledContent(buildingText("围护传热","Envelope transmission"),value:String(format:"%.1f W",result.transmissionW))
                    LabeledContent(buildingText("新风显热","Outdoor-air sensible"),value:String(format:"%.1f W",result.outdoorAirSensibleW))
                }
            }
        }.disabled(session.busy)
    }
    private func isStale(_ result:HVACDesignLoadResult)->Bool {
        var current=session.editors.hvac.value;current.projectRevision=session.snapshot?.project.revision ?? 0
        return (try? result.isStale(for:current)) != false
    }
}

struct BuildingGridMap:BuildingLocalizedView {
    @Environment(\.locale) var buildingLocale
    let values: [Double]
    let columns: Int
    let rows: Int
    let low: Double
    let high: Double
    let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Canvas { context, size in
                guard columns > 0, rows > 0, columns <= 10_000, rows <= 10_000,
                    columns <= 10_000 / rows, values.count == columns * rows else { return }
                let width = size.width / Double(columns), height = size.height / Double(rows)
                for row in 0..<rows { for column in 0..<columns {
                    let value = values[row * columns + column]
                    let t = max(0, min(1, (value - low) / max(1e-6, high - low)))
                    let rect = CGRect(x: Double(column) * width, y: Double(rows - 1 - row) * height, width: width + 0.5, height: height + 0.5)
                    context.fill(Path(rect), with: .color(Color(hue: (1 - t) * 0.65, saturation: 0.72, brightness: 0.88)))
                } }
            }.clipShape(RoundedRectangle(cornerRadius: 12))
            HStack {
                Text(String(format: "%.1f %@", low, unit)); Spacer()
                Text(buildingText("模型计算", "Model calculation")).foregroundStyle(.secondary); Spacer()
                Text(String(format: "%.1f %@", high, unit))
            }.font(.caption)
        }.accessibilityLabel(buildingText("计算结果热力图", "Calculated heatmap") + " \(low) … \(high) \(unit)")
    }
}
