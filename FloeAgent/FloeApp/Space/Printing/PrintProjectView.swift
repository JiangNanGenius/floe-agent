// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloePrintCore
import UniformTypeIdentifiers

struct PrintProjectView: View {
    @Bindable var session: PrintProjectSession
    @State private var importing = false
    @State private var stage: Stage = .prepare
    @State private var inspector: Inspector = .process
    @State private var showingMachine = false
    @State private var showingInspector = true
    @State private var showingAssistant = false
    @State private var tool: ObjectTool = .select
    @State private var transformX = 0.0
    @State private var transformY = 0.0
    @State private var transformZ = 0.0
    @State private var rotation = 90.0
    @State private var scale = 100.0
    @State private var viewReset = 0
    @State private var exportConfiguration: URL?
    enum Stage: String, CaseIterable { case prepare, preview, export }
    enum Inspector: String, CaseIterable { case process, support, material, model }
    enum ObjectTool: String, CaseIterable { case select, move, rotate, scale }
    private var disabled: Bool { session.isBusy || session.isEditing }
    private var plateName: String { session.plates.first(where: { $0.id == session.document.plateID })?.name ?? text("打印盘", "Plate") }
    private func text(_ zh: String, _ en: String) -> String { IDELanguageRunText.t(zh, en) }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                Divider()
                commandBar
                Divider()
                Group {
                if geometry.size.width >= 960 {
                    HStack(alignment: .top, spacing: 0) {
                        objectSidebar.frame(width: 176)
                        Divider()
                        viewport
                        if showingInspector { Divider(); inspectorPanel.frame(width: 264) }
                    }
                } else if geometry.size.width >= 680 {
                    VStack(spacing: 0) {
                        compactPlates
                        Divider()
                        HStack(alignment: .top, spacing: 0) { viewport; if showingInspector { Divider(); inspectorPanel.frame(width: 250) } }
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            compactPlates
                            viewport.frame(height: max(360, geometry.size.height * 0.56))
                            if showingInspector { Divider(); inspectorPanel }
                        }
                    }
                }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
                Divider()
                footer
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .background(Color(uiColor: .systemBackground))
            .clipped()
            .accessibilityElement(children: .contain)
        }
        .sheet(isPresented: $showingMachine) { PrintMachineEditor(session: session) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "stl") ?? .data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { for url in urls { await session.importSTL(url) } }
            case .failure(let error): session.diagnostic = error.localizedDescription
            }
        }
        .onChange(of: session.completed) { _, completed in if completed && session.result != nil { stage = .preview } }
        .onChange(of: session.document.plateID) { _, _ in stage = .prepare }
        .task(id: session.document.resultAsset) { exportConfiguration = nil }
        .accessibilityIdentifier("printing.workbench")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "printer").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(text("打印工作台", "Print workbench")).font(.headline)
                Text(session.hasUnsavedSettings ? text("设置尚未保存", "Unsaved settings") : text("项目已保存", "Project saved")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Picker(text("打印方式", "Printing method"), selection: Binding(get: { session.preset }, set: { session.changePreset($0); stage = .prepare })) {
                Text("FDM").tag(PrintPreset.genericMarlinPLA)
                Text(text("光固化", "Resin")).tag(PrintPreset.genericCTBV3)
            }.pickerStyle(.segmented).frame(maxWidth: 176).disabled(disabled)
            Button { showingAssistant.toggle() } label: { Image(systemName: "sparkles").frame(width: 44, height: 44) }
                .accessibilityLabel(text("打印助手", "Print assistant"))
            Menu {
                Button(text("机器配置", "Machine configuration"), systemImage: "slider.horizontal.3") { showingMachine = true }
                Button(text("保存项目", "Save project"), systemImage: "square.and.arrow.down") { Task { await session.saveSettings() } }.disabled(disabled)
                Button(text("撤销", "Undo"), systemImage: "arrow.uturn.backward") { Task { await session.undo() } }.disabled(!session.canUndo)
                Button(text("重做", "Redo"), systemImage: "arrow.uturn.forward") { Task { await session.redo() } }.disabled(!session.canRedo)
            } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
            .accessibilityLabel(text("项目菜单", "Project menu"))
        }.padding(.horizontal, 14).padding(.vertical, 8)
    }
    private var commandBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { stagePicker; Spacer(); prepareActions; inspectorButton }
            HStack(spacing: 4) { stagePicker; Spacer(minLength: 0); importButton.labelStyle(.iconOnly); inspectorButton }
        }.padding(.horizontal, 12).padding(.vertical, 4)
    }
    private var stagePicker: some View {
        HStack(spacing: 2) {
            stageButton(.prepare, text("准备", "Prepare"), "cube")
            stageButton(.preview, text("逐层预览", "Preview"), "square.stack.3d.up")
            stageButton(.export, text("导出", "Export"), "square.and.arrow.up")
        }
    }
    private func stageButton(_ value: Stage, _ title: String, _ icon: String) -> some View {
        Button { stage = value } label: { Label(title, systemImage: icon).font(.subheadline.weight(stage == value ? .semibold : .regular)).padding(.horizontal, 10).frame(minHeight: 44).background(stage == value ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8)) }
            .buttonStyle(.plain).foregroundStyle(stage == value ? Color.accentColor : Color.primary)
            .accessibilityIdentifier("printing.stage.\(value.rawValue)")
    }
    private var importButton: some View {
        Button { importing = true } label: { Label(text("导入", "Import"), systemImage: "square.and.arrow.down").frame(minHeight: 44) }
            .disabled(disabled).accessibilityIdentifier("printing.import")
    }
    private var prepareActions: some View {
        HStack(spacing: 14) {
            importButton
            Button { Task { await session.perform(.init(action: .arrange)) } } label: { Label(text("排列", "Arrange"), systemImage: "square.grid.2x2").frame(minHeight: 44) }.disabled(disabled || session.objects.isEmpty)
            Button { Task { await session.editMesh(.dropToBed) } } label: { Label(text("落到平台", "Drop to bed"), systemImage: "arrow.down.to.line").frame(minHeight: 44) }.disabled(disabled || session.selectedObject == nil)
            Button { Task { await session.undo() } } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }.disabled(!session.canUndo).accessibilityLabel(text("撤销", "Undo"))
        }.font(.subheadline)
    }
    private var inspectorButton: some View {
        Button { showingInspector.toggle() } label: { Image(systemName: "sidebar.right").frame(width: 44, height: 44) }.accessibilityLabel(text("显示或隐藏检查器", "Show or hide inspector"))
    }
    private var objectSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(text("打印盘", "Plates")).font(.subheadline.weight(.semibold)); Spacer(); addPlateButton }.padding(.leading, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 6) { ForEach(session.plates) { plate in plateButton(plate, compact: false) } }.padding(.horizontal, 8)
                Divider().padding(.vertical, 12)
                HStack { Text(text("模型", "Objects")).font(.subheadline.weight(.semibold)); Spacer(); addObjectMenu }.padding(.leading, 12)
                VStack(spacing: 3) {
                    ForEach(session.objects) { object in
                        Button { session.selectedObjectID = object.id; inspector = .model } label: {
                            HStack(spacing: 8) { Image(systemName: "cube.fill").foregroundStyle(object.toolID == 0 ? Color.teal : Color.orange); Text(object.name).lineLimit(2); Spacer(minLength: 0) }
                                .font(.subheadline).padding(.horizontal, 10).frame(minHeight: 44)
                                .background(session.selectedObject?.id == object.id ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).contextMenu { objectMenu(object) }
                    }
                    if session.objects.isEmpty { Text(text("当前盘没有模型", "No objects on this plate")).font(.caption).foregroundStyle(.secondary).padding() }
                }.padding(.horizontal, 8)
                }
            }.frame(maxHeight: .infinity)
            Label(text("毫米", "Millimetres"), systemImage: "ruler").font(.caption).foregroundStyle(.secondary).padding(12)
        }.frame(maxHeight: .infinity, alignment: .top).background(Color(uiColor: .secondarySystemBackground))
    }
    private var addPlateButton: some View {
        Button { Task { await session.perform(.init(action: .addPlate)) } } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.disabled(disabled).accessibilityLabel(text("添加打印盘", "Add plate"))
    }
    private var addObjectMenu: some View {
        Menu {
            Button(text("导入 STL", "Import STL"), systemImage: "square.and.arrow.down") { importing = true }
            Button(text("添加 20 mm 立方体", "Add 20 mm cube"), systemImage: "cube") { Task { await session.addCube() } }
        } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.disabled(disabled).accessibilityIdentifier("printing.addObject")
    }
    private func plateButton(_ plate: PrintPlateDocument, compact: Bool) -> some View {
        Button { Task { await session.perform(.init(action: .selectPlate, plateID: plate.id)) } } label: {
            HStack(spacing: 9) {
                Image(systemName: "square.3.layers.3d").font(compact ? .body : .title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plate.name).font(.subheadline.weight(.medium))
                    if !compact { Text(text("模型", "Objects") + " \((session.document.objects ?? []).filter { $0.plateID == plate.id }.count)").font(.caption).foregroundStyle(.secondary) }
                }
                if !compact { Spacer(minLength: 0) }
            }.padding(.horizontal, 10).frame(minHeight: compact ? 44 : 62)
                .background(plate.id == session.document.plateID ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(disabled)
            .contextMenu { if session.plates.count > 1 { Button(text("移除打印盘及模型", "Remove plate and objects"), role: .destructive) { Task { await session.perform(.init(action: .removePlate, plateID: plate.id)) } } } }
    }
    private var compactPlates: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(session.plates) { plate in plateButton(plate, compact: true) }
                addPlateButton
                Divider().frame(height: 24)
                Menu {
                    ForEach(session.objects) { object in Button(object.name) { session.selectedObjectID = object.id; inspector = .model } }
                } label: { Label(text("模型", "Objects") + " \(session.objects.count)", systemImage: "cube").frame(minHeight: 44) }
                addObjectMenu
            }.padding(.horizontal, 10)
        }.background(Color(uiColor: .secondarySystemBackground))
    }
    private var viewport: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if stage == .prepare {
                    PrintMeshPreview(disk: session.disk, document: session.document, machine: session.machine, selectedObjectID: session.selectedObject?.id, reset: viewReset) { id in session.selectedObjectID = id }
                    if session.objects.isEmpty {
                        VStack {
                            Spacer()
                            HStack(spacing: 12) {
                                Button(text("导入 STL", "Import STL")) { importing = true }.buttonStyle(.borderedProminent).disabled(disabled)
                                Button(text("添加立方体", "Add cube")) { Task { await session.addCube() } }.frame(minHeight: 44).disabled(disabled).accessibilityIdentifier("printing.cube")
                            }.padding(.bottom, 42)
                        }.frame(maxWidth: .infinity)
                    }
                } else if stage == .preview, session.resultIsCurrent, let result = session.result {
                    PrintResultPreview(url: result, preset: session.document.preset, machine: session.document.machine ?? .generic(for: session.document.preset))
                } else if stage == .export { exportPanel }
                else {
                    ContentUnavailableView {
                        Label(text("准备好后开始切片", "Slice when ready"), systemImage: "square.stack.3d.up")
                    } description: { Text(text("切片完成后，可以查看真实逐层路径或曝光图。", "After slicing, inspect actual layer paths or exposure images.")) }
                    actions: { Button(text("返回准备", "Back to prepare")) { stage = .prepare } }
                }
                if stage == .prepare {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(plateName).font(.subheadline.weight(.semibold)); Spacer(); Button { viewReset += 1 } label: { Image(systemName: "viewfinder").frame(width: 44, height: 44) }.accessibilityLabel(text("适应视图", "Fit view")) }
                        objectTools
                        Spacer()
                        Text(text("拖动旋转视角 · 双指缩放", "Drag to orbit · Pinch to zoom")).font(.caption).foregroundStyle(.secondary)
                    }.padding(12)
                }
                if session.isBusy {
                    VStack { Spacer(); VStack(alignment: .leading, spacing: 10) {
                        ProgressView(value: session.progress) { Text(session.isCancelling ? text("正在停止", "Stopping") : text("正在切片", "Slicing")) }
                        Button(text("停止", "Stop"), role: .destructive) { session.cancel() }.disabled(session.isCancelling)
                    }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding() }.accessibilityIdentifier("printing.progress")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .secondarySystemGroupedBackground))
            if showingAssistant { assistantPanel }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var objectTools: some View {
        VStack(spacing: 0) {
            ForEach(ObjectTool.allCases, id: \.self) { item in
                Button { tool = item; if item != .select { inspector = .model; showingInspector = true } } label: {
                    Image(systemName: item == .select ? "cursorarrow" : item == .move ? "move.3d" : item == .rotate ? "rotate.3d" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 44, height: 44).background(tool == item ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                }.accessibilityLabel(item == .select ? text("选择", "Select") : item == .move ? text("移动", "Move") : item == .rotate ? text("旋转", "Rotate") : text("缩放", "Scale"))
            }
            Divider().frame(width: 28)
            Button { inspector = .support; showingInspector = true } label: { Image(systemName: "point.3.connected.trianglepath.dotted").frame(width: 44, height: 44) }.accessibilityLabel(text("支撑", "Supports"))
        }.padding(4).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11)).disabled(disabled)
    }
    private var inspectorPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button { showingMachine = true } label: {
                    HStack { Image(systemName: session.preset == .genericMarlinPLA ? "printer" : "cube.transparent"); VStack(alignment: .leading, spacing: 3) { Text(session.machine.name).font(.subheadline.weight(.semibold)).lineLimit(2); Text(String(format: "%.0f × %.0f × %.0f mm", session.machine.bedWidth, session.machine.bedDepth, session.machine.buildHeight)).font(.caption).foregroundStyle(.secondary) }; Spacer(minLength: 2); Image(systemName: "chevron.right").font(.caption) }.frame(minHeight: 44)
                }.buttonStyle(.plain)
                HStack(spacing: 0) {
                    inspectorTab(.process, text("工艺", "Process")); inspectorTab(.support, text("支撑", "Support")); inspectorTab(.material, text("材料", "Material")); inspectorTab(.model, text("模型", "Model"))
                }
                Group {
                    switch inspector { case .process: processInspector; case .support: supportInspector; case .material: materialInspector; case .model: modelInspector }
                }.disabled(disabled)
                if let diagnostic = session.diagnostic {
                    Divider()
                    Label(text("操作未完成", "Operation did not finish"), systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
                    DisclosureGroup(text("详情", "Details")) { Text(diagnostic).font(.caption).textSelection(.enabled) }
                }
                Spacer(minLength: 12)
            }.padding(14)
        }.frame(maxHeight: .infinity, alignment: .top).background(Color(uiColor: .systemBackground)).clipped()
    }
    private func inspectorTab(_ value: Inspector, _ title: String) -> some View {
        Button { inspector = value } label: { Text(title).font(.caption.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44).background(inspector == value ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain).foregroundStyle(inspector == value ? Color.accentColor : Color.secondary)
    }
    private var processInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            numberField(text("层高", "Layer height") + " · mm", value: $session.layerHeight).accessibilityIdentifier("printing.layerHeight")
            if session.preset == .genericMarlinPLA {
                numericSlider(text("填充密度", "Infill"), key: "sliceFillSparse", default: 0.15, range: 0...1, percent: true)
                numberField(text("外壁层数", "Walls"), value: setting("sliceShells", 2))
                numberField(text("顶层", "Top layers"), value: setting("sliceTopLayers", 4))
                numberField(text("底层", "Bottom layers"), value: setting("sliceBottomLayers", 4))
                numberField(text("打印速度", "Print speed") + " · mm/s", value: setting("outputFeedrate", 45))
                Toggle(text("生成支撑", "Generate supports"), isOn: flag("sliceSupportEnable"))
            } else {
                numberField(text("曝光", "Exposure") + " · s", value: setting("slaLayerOn", 2.5))
                numberField(text("底层曝光", "Bottom exposure") + " · s", value: setting("slaBaseOn", 25))
                numberField(text("壳体厚度", "Shell thickness") + " · mm", value: setting("slaShell", 0))
                numberField(text("底层数", "Bottom layers"), value: Binding(get: { Double(session.machine.resin.bottomLayers) }, set: { session.machine.resin.bottomLayers = Int($0.isFinite ? $0.clamped(to: 0...1_000) : 0) }))
                Button(text("平台、升降与曝光布局", "Platform, lift and exposure layout"), systemImage: "slider.horizontal.3") { showingMachine = true }.frame(minHeight: 44)
            }
            Divider()
            HStack { Text(text("当前盘", "Current plate")).foregroundStyle(.secondary); Spacer(); Text("\(session.objects.count) " + text("个模型", "objects")) }.font(.caption)
            if let layers = session.document.resultLayerCount { HStack { Text(text("切片层数", "Sliced layers")).foregroundStyle(.secondary); Spacer(); Text(layers.formatted()).monospacedDigit() }.font(.caption) }
            Button { Task { await session.saveSettings() } } label: { Label(text("保存配置", "Save settings"), systemImage: "checkmark").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.bordered).disabled(!session.hasUnsavedSettings)
        }
    }
    private var supportInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(text("生成支撑", "Generate supports"), isOn: flag(session.preset == .genericMarlinPLA ? "sliceSupportEnable" : "slaSupportEnable"))
            numericSlider(text("支撑密度", "Support density"), key: session.preset == .genericMarlinPLA ? "sliceSupportDensity" : "slaSupportDensity", default: 0.15, range: 0.01...1, percent: true)
            if session.preset == .genericMarlinPLA { numberField(text("悬垂角度", "Overhang angle") + " · °", value: setting("sliceSupportAngle", 45)) }
            else { numberField(text("支撑直径", "Support diameter") + " · mm", value: setting("slaSupportSize", 0.4)); numberField(text("基座层数", "Raft layers"), value: setting("slaSupportLayers", 5)) }
            Text(text("自动支撑会在下次切片时生成。", "Automatic supports are generated during the next slice.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var materialInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            if session.preset == .genericMarlinPLA {
                ForEach(session.machine.tools) { nozzle in
                    HStack { Circle().fill(nozzle.id == 0 ? Color.teal : Color.orange).frame(width: 12, height: 12); Text(text("工具", "Tool") + " \(nozzle.id) · " + String(format: "%.2f mm", nozzle.nozzleDiameter)); Spacer() }.font(.subheadline)
                }
                if let object = session.selectedObject {
                    Picker(text("所选模型的工具", "Selected object tool"), selection: Binding(get: { object.toolID }, set: { value in Task { await session.perform(.init(action: .assignTool, objectID: object.id, toolID: value)) } })) {
                        ForEach(session.machine.tools) { nozzle in Text(text("工具", "Tool") + " \(nozzle.id)").tag(nozzle.id) }
                    }
                }
                numberField(text("喷嘴温度", "Nozzle temperature") + " · °C", value: setting("outputTemp", 200))
                numberField(text("热床温度", "Bed temperature") + " · °C", value: setting("outputBedTemp", 60))
                Button(text("喷头与工具偏移", "Nozzles and tool offsets"), systemImage: "wrench.adjustable") { showingMachine = true }.frame(minHeight: 44)
                Text(text("每盘使用一个工具。不同工具的模型可分盘切片。", "Use one tool per plate. Slice different tools on separate plates.")).font(.caption).foregroundStyle(.secondary)
            } else {
                Label(text("树脂 · CTB v3", "Resin · CTB v3"), systemImage: "drop.fill").foregroundStyle(.purple)
                numberField(text("曝光", "Exposure") + " · s", value: setting("slaLayerOn", 2.5))
                numberField(text("底层曝光", "Bottom exposure") + " · s", value: setting("slaBaseOn", 25))
                Button(text("曝光布局", "Exposure layout"), systemImage: "rectangle.and.hand.point.up.left") { showingMachine = true }.frame(minHeight: 44)
            }
        }
    }
    private var modelInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let object = session.selectedObject {
                Label(object.name, systemImage: "cube.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.teal)
                if tool == .select || tool == .move {
                    numberField("ΔX · mm", value: $transformX); numberField("ΔY · mm", value: $transformY); numberField("ΔZ · mm", value: $transformZ)
                    Button(text("应用移动", "Apply move"), systemImage: "move.3d") { Task { await session.editMesh(.translate(transformX, transformY, transformZ)); transformX = 0; transformY = 0; transformZ = 0 } }.frame(minHeight: 44)
                }
                if tool == .select || tool == .rotate {
                    numberField(text("旋转角度", "Rotation") + " · °", value: $rotation)
                    HStack { ForEach(0..<3) { axis in Button("\(["X", "Y", "Z"][axis])") { Task { await session.editMesh(.rotate(axis: axis, degrees: rotation)) } }.buttonStyle(.bordered).frame(maxWidth: .infinity, minHeight: 44) } }
                }
                if tool == .select || tool == .scale {
                    numberField(text("缩放", "Scale") + " · %", value: $scale)
                    Button(text("应用缩放", "Apply scale"), systemImage: "arrow.up.left.and.arrow.down.right") { Task { await session.editMesh(.scale(scale / 100)); scale = 100 } }.frame(minHeight: 44)
                }
                Divider()
                Button(text("居中", "Center"), systemImage: "scope") { Task { await session.editMesh(.center) } }.frame(minHeight: 44)
                Button(text("落到平台", "Drop to bed"), systemImage: "arrow.down.to.line") { Task { await session.editMesh(.dropToBed) } }.frame(minHeight: 44)
                objectMenu(object)
            } else { Text(text("选择模型以调整位置和尺寸。", "Select an object to adjust its position and size.")).foregroundStyle(.secondary) }
        }
    }
    @ViewBuilder private func objectMenu(_ object: PrintObjectDocument) -> some View {
        Button(text("复制到当前盘", "Duplicate on plate"), systemImage: "doc.on.doc") { Task { await session.perform(.init(action: .duplicateObject, objectID: object.id)) } }.frame(minHeight: 44)
        Menu(text("移到另一打印盘", "Move to another plate"), systemImage: "square.3.layers.3d") {
            ForEach(session.plates.filter { $0.id != object.plateID }) { plate in Button(plate.name) { Task { await session.perform(.init(action: .moveObject, objectID: object.id, plateID: plate.id)) } } }
        }.frame(minHeight: 44).disabled(session.plates.count < 2)
        Button(text("移除模型", "Remove object"), systemImage: "trash", role: .destructive) { Task { await session.perform(.init(action: .removeObject, objectID: object.id)) } }.frame(minHeight: 44)
    }
    private var assistantPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Label(text("打印助手", "Print assistant"), systemImage: "sparkles").font(.subheadline.weight(.semibold)); Spacer(); Button { showingAssistant = false } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel(text("收起助手", "Close assistant")) }
            ScrollView(.horizontal) { HStack {
                Button(text("排好这一盘", "Arrange this plate")) { Task { await session.perform(.init(action: .arrange)) } }
                Button(text("优先考虑强度", "Prioritize strength")) { session.processSettings["sliceFillSparse"] = 0.4; session.processSettings["sliceShells"] = 4; Task { await session.saveSettings() } }.disabled(session.preset != .genericMarlinPLA)
                Button(text("减少支撑用料", "Reduce support material")) { session.processSettings[session.preset == .genericMarlinPLA ? "sliceSupportDensity" : "slaSupportDensity"] = 0.1; Task { await session.saveSettings() } }
            }.buttonStyle(.bordered).disabled(disabled) }
            Text(text("这些快捷调整会直接应用，可撤销。也可在对话中让 AI 编辑此项目。", "Quick adjustments apply directly and can be undone. You can also ask AI to edit this project in a conversation.")).font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 14).padding(.bottom, 12).background(.bar)
    }
    private var exportPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label(text("导出打印文件", "Export print file"), systemImage: "square.and.arrow.up").font(.title2.weight(.semibold))
                if let result = session.result {
                    Text(result.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    if !session.resultIsCurrent { Label(text("设置或模型已更改，请重新切片。", "Settings or objects changed. Slice again."), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    LabeledContent(text("文件格式", "Format"), value: result.pathExtension.uppercased())
                    if let count = session.document.resultLayerCount { LabeledContent(text("层数", "Layers"), value: count.formatted()) }
                    ShareLink(item: result) { Label(text("存储或共享完整文件", "Save or share complete file"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.borderedProminent).disabled(!session.resultIsCurrent).accessibilityIdentifier("printing.export")
                    Button(text("保存配置副本", "Save configuration copy"), systemImage: "doc.badge.gearshape") { Task { exportConfiguration = await session.exportConfiguration() } }.frame(minHeight: 44)
                    if let exportConfiguration { ShareLink(item: exportConfiguration) { Label(text("共享机器与工艺配置", "Share machine and process settings"), systemImage: "square.and.arrow.up") }.frame(minHeight: 44) }
                    Text(text("如需发送到打印机，请在共享菜单中选择设备支持的应用。", "To send to a printer, choose its supported app from the share menu.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(text("完成切片后可以导出完整 G-code 或 CTB 文件。", "Slice first to export a complete G-code or CTB file.")).foregroundStyle(.secondary)
                    Button(text("返回准备", "Back to prepare")) { stage = .prepare }.buttonStyle(.bordered)
                }
            }.padding(24).frame(maxWidth: 480).frame(maxWidth: .infinity)
        }
    }
    private var footer: some View {
        HStack(spacing: 12) {
            Label(plateName + " · \(session.objects.count) " + text("个模型", "objects"), systemImage: "square.3.layers.3d").font(.caption).lineLimit(1)
            Spacer(minLength: 0)
            if session.isBusy { Text(session.progress.formatted(.percent.precision(.fractionLength(0)))).font(.caption).monospacedDigit() }
            Button {
                if stage == .preview && session.resultIsCurrent { stage = .export }
                else if stage == .export && session.resultIsCurrent { stage = .preview }
                else { session.slice() }
            } label: { Label(stage == .preview && session.resultIsCurrent ? text("导出文件", "Export file") : stage == .export && session.resultIsCurrent ? text("查看逐层预览", "View layers") : text("切片预览", "Slice preview"), systemImage: stage == .preview ? "square.and.arrow.up" : "play.fill").font(.subheadline.weight(.semibold)).frame(minHeight: 44).padding(.horizontal, 10) }
                .buttonStyle(.borderedProminent).disabled(disabled || session.objects.isEmpty).accessibilityIdentifier("printing.slice")
        }.padding(.horizontal, 14).padding(.vertical, 8).background(.bar)
    }
    private func setting(_ key: String, _ fallback: Double) -> Binding<Double> { Binding(get: { session.processSettings[key] ?? fallback }, set: { session.processSettings[key] = $0 }) }
    private func flag(_ key: String) -> Binding<Bool> { Binding(get: { (session.processSettings[key] ?? 0) != 0 }, set: { session.processSettings[key] = $0 ? 1 : 0 }) }
    private func numberField(_ title: String, value: Binding<Double>) -> some View {
        HStack { Text(title).font(.subheadline); Spacer(minLength: 6); TextField(title, value: value, format: .number.precision(.fractionLength(0...3))).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).frame(width: 90).padding(.horizontal, 8).frame(minHeight: 44).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6)) }.accessibilityElement(children: .contain)
    }
    private func numericSlider(_ title: String, key: String, default fallback: Double, range: ClosedRange<Double>, percent: Bool = false) -> some View {
        VStack(spacing: 6) { HStack { Text(title); Spacer(); Text(percent ? (session.processSettings[key] ?? fallback).formatted(.percent.precision(.fractionLength(0))) : (session.processSettings[key] ?? fallback).formatted()).monospacedDigit().foregroundStyle(.secondary) }.font(.subheadline); Slider(value: setting(key, fallback), in: range).accessibilityLabel(title) }
    }
}
private extension Double { func clamped(to range: ClosedRange<Double>) -> Double { min(range.upperBound, max(range.lowerBound, self)) } }
#endif
