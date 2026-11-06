// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloePrintCore

struct PrintMachineEditor: View {
    let session: PrintProjectSession
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PrintMachineConfiguration
    @State private var tab = 0
    @State private var diagnostic: String?
    @State private var saving = false
    @State private var pauseLayers = ""
    init(session: PrintProjectSession) { self.session = session; _draft = State(initialValue: session.machine); _pauseLayers = State(initialValue: session.machine.pauseLayers.map(String.init).joined(separator: ", ")) }
    private func t(_ zh: String, _ en: String) -> String { IDELanguageRunText.t(zh, en) }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(t("配置内容", "Configuration"), selection: $tab) {
                    Text(t("机器", "Machine")).tag(0)
                    if session.preset == .genericMarlinPLA { Text(t("喷头", "Tools")).tag(1); Text("G-code").tag(2) }
                    else { Text(t("平台与曝光", "Platform & exposure")).tag(3) }
                }.pickerStyle(.segmented).padding()
                Form {
                    if tab == 0 { machineSection }
                    if tab == 1 { toolsSection }
                    if tab == 2 { scriptsSection }
                    if tab == 3 { resinSection }
                    if let diagnostic { Section { Label(diagnostic, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
                }
            }
            .navigationTitle(t("打印机配置", "Printer configuration")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(t("取消", "Cancel")) { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(t("保存", "Save")) {
                        Task {
                            saving = true; defer { saving = false }
                            do {
                                let entries = pauseLayers.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace })
                                guard entries.allSatisfy({ Int($0) != nil }) else { throw PrintError.invalidSetting("pause layer") }
                                draft.pauseLayers = entries.compactMap { Int($0) }
                                try draft.validate()
                                try await session.apply([.init(action: .settings, preset: session.preset, layerHeight: session.layerHeight, processSettings: session.processSettings, machine: draft)], expectedRevision: session.document.revision)
                                dismiss()
                            } catch { diagnostic = error.localizedDescription }
                        }
                    }.disabled(saving)
                }
            }
        }.presentationDetents([.large])
    }
    private var machineSection: some View {
        Group {
            Section(t("机器", "Machine")) {
                TextField(t("名称", "Name"), text: $draft.name)
                if session.preset == .genericMarlinPLA {
                    Picker(t("运动结构", "Kinematics"), selection: $draft.kinematics) {
                        ForEach(PrintMachineConfiguration.Kinematics.allCases, id: \.self) { value in Text(value == .cartesian ? t("笛卡尔", "Cartesian") : value == .i3 ? "i3" : value == .coreXY ? "CoreXY" : value == .delta ? "Delta" : "SCARA").tag(value) }
                    }
                }
                number(t("宽度", "Width") + " · mm", $draft.bedWidth)
                number(t("深度", "Depth") + " · mm", $draft.bedDepth)
                number(t("高度", "Height") + " · mm", $draft.buildHeight)
            }
            if session.preset == .genericMarlinPLA {
                Section(t("坐标原点", "Coordinate origin")) {
                    Picker(t("平台原点", "Bed origin"), selection: $draft.origin) {
                        Text(t("左前角", "Front left")).tag(PrintMachineConfiguration.Origin.frontLeft)
                        Text(t("平台中心", "Bed centre")).tag(PrintMachineConfiguration.Origin.center)
                        Text(t("左后角", "Rear left")).tag(PrintMachineConfiguration.Origin.rearLeft)
                        Text(t("自定义", "Custom")).tag(PrintMachineConfiguration.Origin.custom)
                    }
                    number("X · mm", $draft.originX); number("Y · mm", $draft.originY); number("Z · mm", $draft.originZ)
                }
                Section(t("喷头中心偏移", "Head centre offset")) {
                    number("X · mm", $draft.headOffsetX); number("Y · mm", $draft.headOffsetY); number("Z · mm", $draft.headOffsetZ)
                }
                Section { Text(t("输出使用机器的笛卡尔坐标。CoreXY、i3 等电机运动由固件换算；工具偏移由本配置应用一次。", "Output uses Cartesian machine coordinates. Firmware maps CoreXY, i3 and other motor motion; this configuration applies tool offsets once.")).font(.caption).foregroundStyle(.secondary) }
            } else {
                Section { Button(t("平台、升降与曝光布局", "Platform, lift and exposure layout")) { tab = 3 } }
            }
        }
    }
    private var toolsSection: some View {
        Group {
            Section {
                Picker(t("默认工具", "Default tool"), selection: $draft.selectedTool) { ForEach(draft.tools) { tool in Text("T\(tool.id)").tag(tool.id) } }
            }
            ForEach($draft.tools) { $tool in
                Section("T\(tool.id)") {
                    number(t("喷嘴直径", "Nozzle diameter") + " · mm", $tool.nozzleDiameter)
                    number(t("耗材直径", "Filament diameter") + " · mm", $tool.filamentDiameter)
                    number(t("工具偏移 X", "Tool offset X") + " · mm", $tool.offsetX)
                    number(t("工具偏移 Y", "Tool offset Y") + " · mm", $tool.offsetY)
                    number(t("工具偏移 Z", "Tool offset Z") + " · mm", $tool.offsetZ)
                    if draft.tools.count > 1 {
                        Button(t("移除此工具", "Remove tool"), role: .destructive) {
                            let id = tool.id; draft.tools.removeAll { $0.id == id }
                            if draft.selectedTool == id { draft.selectedTool = draft.tools[0].id }
                        }
                    }
                }
            }
            Section {
                Button(t("添加工具", "Add tool"), systemImage: "plus") {
                    if let id = (0..<16).first(where: { id in !draft.tools.contains { $0.id == id } }) { draft.tools.append(.init(id: id)) }
                }.disabled(draft.tools.count >= 16)
                Text(t("每盘以一个工具生成路径。工具切换代码在该盘开始时输出。", "Each plate generates paths for one tool. Its tool-change code is emitted at the start of the plate.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var scriptsSection: some View {
        Group {
            codeSection(t("开头代码", "Start G-code"), $draft.scripts.start)
            codeSection(t("结尾代码", "End G-code"), $draft.scripts.end)
            codeSection(t("换头代码", "Tool-change G-code"), $draft.scripts.toolChange)
            codeSection(t("每层之前", "Before each layer"), $draft.scripts.beforeLayer)
            codeSection(t("每层之后", "After each layer"), $draft.scripts.afterLayer)
            codeSection(t("暂停代码", "Pause G-code"), $draft.scripts.pause)
            Section(t("在这些层暂停", "Pause at these layers")) { TextField(t("层号，用逗号分隔", "Layer numbers, separated by commas"), text: $pauseLayers).keyboardType(.numbersAndPunctuation) }
            Section {
                DisclosureGroup(t("可用占位符", "Available placeholders")) {
                    Text("{nozzle_temperature}\n{bed_temperature}\n{tool}\n{layer}\n{layer_z}\n{bed_width}\n{bed_depth}").font(.caption.monospaced()).textSelection(.enabled)
                    Text(t("代码中的坐标按机器输出坐标填写。自定义代码不会作为脚本求值。", "Enter coordinates in machine output space. Custom G-code is never evaluated as a script.")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var resinSection: some View {
        Group {
            Section(t("平台", "Platform")) {
                Toggle(t("倒置平台", "Inverted platform"), isOn: $draft.resin.invertedPlatform)
                Picker(t("模型构建方向", "Model build direction"), selection: $draft.resin.buildDirection) {
                    Text(t("远离平台", "Away from platform")).tag(PrintResinConfiguration.BuildDirection.awayFromPlatform)
                    Text(t("朝向平台", "Toward platform")).tag(PrintResinConfiguration.BuildDirection.towardPlatform)
                }
                Text(t("方向决定切片的模型 Z 朝向；升降距离写入 CTB，实际电机方向由打印机配置控制。", "Direction determines the model Z orientation used for slicing. Lift distances are written to CTB; the printer configuration controls motor direction.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(t("升降", "Lift")) {
                number(t("升降距离", "Lift distance") + " · mm", $draft.resin.liftDistance)
                number(t("底层升降", "Bottom lift") + " · mm", $draft.resin.bottomLiftDistance)
                number(t("升降速度", "Lift speed") + " · mm/s", $draft.resin.liftSpeed)
                number(t("回落速度", "Retract speed") + " · mm/s", $draft.resin.retractSpeed)
                number(t("关灯等待", "Light-off delay") + " · s", $draft.resin.lightOffSeconds)
            }
            Section(t("曝光布局", "Exposure layout")) {
                intNumber(t("分辨率 X", "Resolution X"), $draft.resin.resolutionX)
                intNumber(t("分辨率 Y", "Resolution Y"), $draft.resin.resolutionY)
                Toggle(t("水平镜像", "Mirror X"), isOn: $draft.resin.mirrorX)
                Toggle(t("垂直镜像", "Mirror Y"), isOn: $draft.resin.mirrorY)
                Picker(t("旋转", "Rotation"), selection: $draft.resin.rotationDegrees) { ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) } }
                Text(t("镜像和旋转会应用到实际曝光图。", "Mirroring and rotation apply to the actual exposure images.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func number(_ title: String, _ value: Binding<Double>) -> some View { HStack { Text(title); Spacer(); TextField(title, value: value, format: .number).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).frame(maxWidth: 130).frame(minHeight: 44) } }
    private func intNumber(_ title: String, _ value: Binding<Int>) -> some View { HStack { Text(title); Spacer(); TextField(title, value: value, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 130).frame(minHeight: 44) } }
    private func codeSection(_ title: String, _ code: Binding<String>) -> some View { Section(title) { TextEditor(text: code).font(.system(.caption, design: .monospaced)).frame(minHeight: 112).autocorrectionDisabled().textInputAutocapitalization(.never) } }
}
#endif
