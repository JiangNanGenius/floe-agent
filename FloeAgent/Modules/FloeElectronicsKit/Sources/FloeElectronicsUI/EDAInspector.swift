// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeElectronicsCore

struct EDAInspector: View {
    @Bindable var session: EDWorkbenchSession
    let context: EDADocumentContext?
    @ViewBuilder var body: some View {
        switch context {
        case .schematic(let sheetID):
            if let placement = session.project.sheets.first(where: { $0.id == sheetID })?.symbols.first(where: { session.selection.objectIDs.contains($0.id) }),
               let component = session.project.components.first(where: { $0.id == placement.componentID }) {
                EDComponentProperties(session: session, sheetID: sheetID, placement: placement, component: component).id(placement.id)
            } else if let value=EDBusInspectorSelection.read(session.project,sheetID:sheetID,objectIDs:session.selection.objectIDs) {
                switch value {
                case .bus(let bus):EDBusProperties(session:session,sheetID:sheetID,value:bus).id(bus.id)
                case .entry(let busID,let entry):EDBusEntryProperties(session:session,sheetID:sheetID,busID:busID,value:entry).id(entry.id)
                }
            } else {
                ContentUnavailableView(edText("未选择对象", "No selection"), systemImage: "cursorarrow", description: Text(edText("在画布上选择元件、总线或引出线以编辑属性。", "Select a component, bus or entry on the canvas to edit its properties.")))
            }
        case .board(let boardID):
            if let board = session.project.boards.first(where: { $0.id == boardID }) {
                if let item = board.footprints.first(where: { session.selection.objectIDs.contains($0.id) }) {
                    EDFootprintProperties(session: session, boardID: boardID, value: item).id(item.id)
                } else if let item = board.tracks.first(where: { session.selection.objectIDs.contains($0.id) }) {
                    EDTrackProperties(session: session, boardID: boardID, value: item).id(item.id)
                } else if let item = board.vias.first(where: { session.selection.objectIDs.contains($0.id) }) {
                    EDViaProperties(session: session, boardID: boardID, value: item).id(item.id)
                } else if let item = board.holes.first(where: { session.selection.objectIDs.contains($0.id) }) {
                    EDHoleProperties(session: session, boardID: boardID, value: item).id(item.id)
                } else if let zone = board.zones.first(where: { session.selection.objectIDs.contains($0.id) }) {
                    EDCopperZoneProperties(session: session, boardID: boardID, value: zone).id(zone.id)
                } else {
                    ContentUnavailableView(edText("未选择对象", "No selection"), systemImage: "cursorarrow", description: Text(edText("在画布上点选元件、走线、孔或铜区。PCB 设置位于画布选项。", "Select a component, track, hole or zone on the canvas. Board setup is in Canvas options.")))
                }
            }
        case .symbol(let id):
            if let value = session.project.symbols.first(where: { $0.id == id }) { EDSymbolProperties(session: session, value: value).id(id) }
        case .footprint(let id):
            if let value = session.project.footprints.first(where: { $0.id == id }) { EDLibraryFootprintProperties(session: session, value: value).id(id) }
        case nil: EmptyView()
        }
    }
}

private struct EDComponentProperties: View {
    let session: EDWorkbenchSession
    let sheetID: UUID
    let placement: EDASymbolPlacement
    let component: EDAComponent
    var body: some View {
        EDInspectorEditor(session: session, value: EDComponentInspectorValue(placement: placement, component: component),
            source: { EDComponentInspectorValue.read($0, sheetID: sheetID, placementID: placement.id) },
            edits: { try EDInspectorEdits.component($0, sheetID: sheetID, project: $1) },
            duplicate: { value, project in
                _ = try EDInspectorEdits.component(value, sheetID: sheetID, project: project)
                return try EDCanvasInteraction.edits(for: .duplicate, project: project, context: .schematic(sheetID: sheetID), objectIDs: [value.placement.id])
            }, delete: { value, project in
                _ = try EDInspectorEdits.component(value, sheetID: sheetID, project: project)
                return try EDCanvasInteraction.edits(for: .delete, project: project, context: .schematic(sheetID: sheetID), objectIDs: [value.placement.id])
            }) { value in
                EDInspectorPreview(title: value.wrappedValue.component.reference,
                    subtitle: session.project.symbols.first(where: { $0.id == component.symbolID })?.name ?? "",
                    scene: .component(value.wrappedValue, sheetID: sheetID, project: session.project))
                EDInspectorTextField(edText("编号", "Reference"), text: value.component.reference)
                EDInspectorTextField(edText("值", "Value"), text: value.component.value)
                HStack {
                    EDInspectorNumberField(edText("旋转 (°)", "Rotation (°)"), value: value.placement.angle)
                    Button { value.placement.angle.wrappedValue += 90 } label: { Image(systemName: "rotate.right") }
                        .frame(minWidth: 44, minHeight: 44).accessibilityLabel(edText("旋转 90°", "Rotate 90°"))
                }
                Toggle(edText("镜像", "Mirror"), isOn: value.placement.mirrored)
                DisclosureGroup(edText("精确位置与封装", "Position and footprint")) {
                    VStack(alignment: .leading, spacing: 12) {
                        EDInspectorPointFields(value.placement.position)
                        EDInspectorIntegerField(edText("符号单元", "Symbol unit"), value: value.placement.unit)
                        Picker(edText("封装", "Footprint"), selection: value.component.footprintID) {
                            Text(edText("未分配", "Unassigned")).tag(Optional<UUID>.none)
                            ForEach(session.project.footprints) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }.padding(.top, 8)
                }
            }
    }
}

private struct EDFootprintProperties: View {
    let session: EDWorkbenchSession
    let boardID: UUID
    let value: EDAFootprint
    var body: some View {
        EDInspectorEditor(session: session, value: value,
            source: { $0.boards.first(where: { $0.id == boardID })?.footprints.first(where: { $0.id == value.id }) },
            edits: { try EDInspectorEdits.footprint($0, boardID: boardID, project: $1) },
            duplicate: { value, project in
                _ = try EDInspectorEdits.footprint(value, boardID: boardID, project: project)
                return try EDCanvasInteraction.edits(for: .duplicate, project: project, context: .board(boardID: boardID), objectIDs: [value.id])
            }, delete: { try EDInspectorEdits.deleteBoardObject($0.id, boardID: boardID, project: $1) },
            deleteLocked: { value, project in value.locked || project.boards.first(where: { $0.id == boardID })?.footprints.first(where: { $0.id == value.id })?.locked == true }) { draft in
                EDInspectorPreview(title: draft.wrappedValue.reference,
                    subtitle: session.project.footprints.first(where: { $0.id == value.definitionID })?.name ?? "",
                    scene: .footprint(draft.wrappedValue, boardID: boardID, project: session.project))
                EDInspectorTextField(edText("编号", "Reference"), text: draft.reference)
                EDInspectorTextField(edText("值", "Value"), text: draft.value)
                HStack {
                    EDInspectorNumberField(edText("旋转 (°)", "Rotation (°)"), value: draft.angle)
                    Button { draft.angle.wrappedValue += 90 } label: { Image(systemName: "rotate.right") }
                        .frame(minWidth: 44, minHeight: 44).accessibilityLabel(edText("旋转 90°", "Rotate 90°"))
                }.disabled(draft.wrappedValue.locked)
                Picker(edText("板面", "Side"), selection: draft.side) {
                    Text(edText("正面", "Front")).tag("F.Cu"); Text(edText("背面", "Back")).tag("B.Cu")
                }.pickerStyle(.segmented).disabled(draft.wrappedValue.locked)
                Toggle(edText("锁定", "Locked"), isOn: draft.locked)
                DisclosureGroup(edText("精确位置", "Position")) { EDInspectorPointFields(draft.position).padding(.top, 8).disabled(draft.wrappedValue.locked) }
            }
    }
}

private struct EDTrackProperties: View {
    let session: EDWorkbenchSession
    let boardID: UUID
    let value: EDATrack
    var body: some View {
        EDInspectorEditor(session: session, value: value,
            source: { $0.boards.first(where: { $0.id == boardID })?.tracks.first(where: { $0.id == value.id }) },
            edits: { try EDInspectorEdits.track($0, boardID: boardID, project: $1) },
            delete: { try EDInspectorEdits.deleteBoardObject($0.id, boardID: boardID, project: $1) },
            deleteLocked: { value, project in value.locked || project.boards.first(where: { $0.id == boardID })?.tracks.first(where: { $0.id == value.id })?.locked == true }) { draft in
                EDInspectorPreview(title: edText("走线", "Track"), subtitle: draft.wrappedValue.layer,
                    scene: .track(draft.wrappedValue, boardID: boardID, project: session.project))
                VStack(alignment: .leading, spacing: 12) {
                    EDInspectorNumberField(edText("线宽 (mm)", "Width (mm)"), value: draft.width)
                    EDInspectorNetPicker(session: session, netID: draft.netID)
                    EDInspectorCopperLayerPicker(title: edText("铜层", "Copper layer"), board: session.project.boards.first(where: { $0.id == boardID }), layer: draft.layer)
                    DisclosureGroup(edText("精确路径", "Path coordinates")) {
                        ForEach(draft.wrappedValue.points.indices, id: \.self) { i in
                            EDInspectorPointFields(draft.points[i], prefix: "\(i + 1) · ")
                        }.padding(.top, 8)
                    }
                }.disabled(draft.wrappedValue.locked)
                Toggle(edText("锁定", "Locked"), isOn: draft.locked)
            }
    }
}

private struct EDViaProperties: View {
    let session: EDWorkbenchSession
    let boardID: UUID
    let value: EDAVia
    var body: some View {
        EDInspectorEditor(session: session, value: value,
            source: { $0.boards.first(where: { $0.id == boardID })?.vias.first(where: { $0.id == value.id }) },
            edits: { try EDInspectorEdits.via($0, boardID: boardID, project: $1) },
            delete: { try EDInspectorEdits.deleteBoardObject($0.id, boardID: boardID, project: $1) }) { draft in
                EDInspectorPreview(title: edText("过孔", "Via"), subtitle: draft.wrappedValue.startLayer + " → " + draft.wrappedValue.endLayer,
                    scene: .via(draft.wrappedValue, boardID: boardID, project: session.project))
                HStack {
                    EDInspectorNumberField(edText("外径 (mm)", "Diameter (mm)"), value: draft.diameter)
                    EDInspectorNumberField(edText("孔径 (mm)", "Drill (mm)"), value: draft.drill)
                }
                EDInspectorNetPicker(session: session, netID: draft.netID)
                EDViaMaskFields(value:draft)
                DisclosureGroup(edText("精确位置与层", "Position and layers")) {
                    VStack(alignment: .leading, spacing: 12) {
                        EDInspectorPointFields(draft.position)
                        EDInspectorCopperLayerPicker(title: edText("起始层", "Start layer"), board: session.project.boards.first(where: { $0.id == boardID }), layer: draft.startLayer)
                        EDInspectorCopperLayerPicker(title: edText("结束层", "End layer"), board: session.project.boards.first(where: { $0.id == boardID }), layer: draft.endLayer)
                    }.padding(.top, 8)
                }
            }
    }
}

private struct EDHoleProperties: View {
    let session: EDWorkbenchSession
    let boardID: UUID
    let value: EDAHole
    var body: some View {
        EDInspectorEditor(session: session, value: value,
            source: { $0.boards.first(where: { $0.id == boardID })?.holes.first(where: { $0.id == value.id }) },
            edits: { try EDInspectorEdits.hole($0, boardID: boardID, project: $1) },
            delete: { try EDInspectorEdits.deleteBoardObject($0.id, boardID: boardID, project: $1) }) { draft in
                EDInspectorPreview(title: edText("钻孔与槽孔", "Drilled hole or slot"), subtitle: "",
                    scene: .hole(draft.wrappedValue, boardID: boardID, project: session.project))
                EDInspectorHoleFields(value: draft)
            }
    }
}

private struct EDInspectorHoleFields: View {
    @Binding var value: EDAHole
    var body: some View {
        EDInspectorNumberField(edText("孔径／槽宽 (mm)", "Hole diameter / slot width (mm)"), value: $value.diameter)
        Toggle(edText("孔壁电镀", "Plated hole"), isOn: $value.plated)
        Toggle(edText("直槽", "Straight slot"), isOn: Binding(get: { value.endPosition != nil }, set: { enabled in
            value.endPosition = enabled ? value.position + EDAPoint(max(1, value.diameter * 2), 0) : nil
        }))
        DisclosureGroup(edText("精确位置", "Position")) {
            VStack(alignment: .leading, spacing: 12) {
                EDInspectorPointFields($value.position, prefix: edText("起点 ", "Start "))
                if value.endPosition != nil {
                    EDInspectorPointFields(Binding(get: { value.endPosition ?? value.position }, set: { value.endPosition = $0 }), prefix: edText("终点 ", "End "))
                }
            }.padding(.top, 8)
        }
    }
}

struct EDBoardProperties: View {
    let session: EDWorkbenchSession
    let value: EDABoard
    var body: some View {
        EDInspectorEditor(session: session, value: value,
            source: { $0.boards.first(where: { $0.id == value.id }) },
            edits: { try EDInspectorEdits.board($0, project: $1) }) { draft in
                Text(edText("PCB 设置", "Board settings")).font(.headline)
                EDInspectorTextField(edText("名称", "Name"), text: draft.name)
                DisclosureGroup(edText("制造与板边", "Manufacturing and board edge")) {
                    VStack(alignment: .leading, spacing: 12) {
                        EDInspectorNumberField(edText("板边净距 (mm)", "Edge clearance (mm)"), value: draft.boardEdgeClearance)
                        EDPlatingPicker(title: edText("板边电镀", "Edge plating"), value: draft.edgePlated)
                    }.padding(.top, 8)
                }
                DisclosureGroup(edText("铜区", "Copper zones")) { EDCopperZonesSection(session: session, boardID: value.id) }
                DisclosureGroup(edText("板框顶点 (mm)", "Outline vertices (mm)")) {
                    VStack(spacing: 12) {
                        ForEach(draft.wrappedValue.outline.indices, id: \.self) { i in
                            EDInspectorPointFields(draft.outline[i], prefix: "\(i + 1) · ")
                        }
                    }.padding(.top, 8)
                }
                DisclosureGroup(edText("钻孔与槽孔", "Drilled holes and slots")) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(draft.holes) { hole in
                            VStack(alignment: .leading, spacing: 10) {
                                EDInspectorHoleFields(value: hole)
                                Button(edText("移除此孔", "Remove hole"), role: .destructive) { draft.holes.wrappedValue.removeAll { $0.id == hole.wrappedValue.id } }
                            }
                            Divider()
                        }
                        Button(edText("添加圆形非镀孔", "Add round NPTH")) { draft.holes.wrappedValue.append(.init(position: .init(10, 10), diameter: 1, plated: false)) }
                    }.padding(.top, 8)
                }
                DisclosureGroup(edText("层叠", "Stackup")) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(draft.layers) { layer in
                            Text(layer.wrappedValue.id).font(.subheadline)
                            EDInspectorNumberField(edText("厚度 (mm)", "Thickness (mm)"), value: layer.thickness)
                            EDInspectorTextField(edText("材料", "Material"), text: layer.material)
                        }
                    }.padding(.top, 8)
                }
                EDGraphicsEditor(graphics: draft.graphics, layers: draft.graphicLayers,
                    additionalLayers: draft.wrappedValue.layers.filter { $0.kind != .dielectric }.map { .init(layerID: $0.id, kind: $0.kind) })
            }
    }
}

private struct EDSymbolProperties: View {
    let session: EDWorkbenchSession
    let value: EDASymbolDefinition
    var body: some View {
        EDInspectorEditor(session: session, value: value, source: { $0.symbols.first(where: { $0.id == value.id }) },
            saveTitle: edText("保存符号", "Save symbol"), edits: { try EDInspectorEdits.symbolDefinition($0, project: $1) }) { draft in
                EDInspectorPreview(title: draft.wrappedValue.name, subtitle: edText("符号", "Symbol"), scene: .symbol(draft.wrappedValue, project: session.project))
                EDInspectorTextField(edText("名称", "Name"), text: draft.name)
                EDInspectorTextField(edText("编号前缀", "Reference prefix"), text: draft.referencePrefix)
                DisclosureGroup(edText("引脚", "Pins") + " (\(draft.wrappedValue.pins.count))") {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(draft.pins) { pin in
                            EDInspectorPinFields(value: pin)
                            Button(edText("移除此引脚", "Remove pin"), role: .destructive) { draft.pins.wrappedValue.removeAll { $0.id == pin.wrappedValue.id } }
                            Divider()
                        }
                        Button(edText("添加引脚", "Add pin")) { draft.pins.wrappedValue.append(.init(number: EDLibraryEditing.nextPinNumber(draft.wrappedValue.pins), position: .init(0, Double(draft.wrappedValue.pins.count) * 2.54))) }
                    }.padding(.top, 8)
                }
                EDGraphicsEditor(graphics: draft.graphics)
            }
    }
}

private struct EDInspectorPinFields: View {
    @Binding var value: EDAPin
    var body: some View {
        HStack {
            EDInspectorTextField(edText("脚号", "Number"), text: $value.number)
            EDInspectorTextField(edText("名称", "Name"), text: $value.name)
        }
        DisclosureGroup(edText("精确位置与电气类型", "Position and electrical type")) {
            VStack(alignment: .leading, spacing: 12) {
                EDInspectorPointFields($value.position)
                EDInspectorIntegerField(edText("符号单元", "Symbol unit"), value: $value.unit)
                Picker(edText("电气类型", "Electrical type"), selection: $value.type) { ForEach(EDAPinType.allCases, id: \.self) { Text(edaPinTypeTitle($0)).tag($0) } }
            }.padding(.top, 8)
        }
    }
}

private struct EDLibraryFootprintProperties: View {
    let session: EDWorkbenchSession
    let value: EDAFootprintDefinition
    var body: some View {
        EDInspectorEditor(session: session, value: value, source: { $0.footprints.first(where: { $0.id == value.id }) },
            saveTitle: edText("保存封装", "Save footprint"), edits: { try EDInspectorEdits.footprintDefinition($0, project: $1) }) { draft in
                EDInspectorPreview(title: draft.wrappedValue.name, subtitle: edText("封装", "Footprint"), scene: .libraryFootprint(draft.wrappedValue, project: session.project))
                EDInspectorTextField(edText("名称", "Name"), text: draft.name)
                DisclosureGroup(edText("焊盘", "Pads") + " (\(draft.wrappedValue.pads.count))") {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(draft.pads) { pad in
                            EDInspectorPadFields(value: pad)
                            Button(edText("移除此焊盘", "Remove pad"), role: .destructive) { draft.pads.wrappedValue.removeAll { $0.id == pad.wrappedValue.id } }
                            Divider()
                        }
                        Button(edText("添加焊盘", "Add pad")) { draft.pads.wrappedValue.append(.init(number: EDLibraryEditing.nextPadNumber(draft.wrappedValue.pads), position: .init(Double(draft.wrappedValue.pads.count) * 2.54, 0))) }
                    }.padding(.top, 8)
                }
                EDGraphicsEditor(graphics: draft.graphics, layers: draft.graphicLayers,
                    additionalLayers: session.project.boards.flatMap(\.layers).filter { $0.kind != .dielectric }.map { .init(layerID: $0.id, kind: $0.kind) })
            }
    }
}

private struct EDInspectorPadFields: View {
    @Binding var value: EDAPad
    var body: some View {
        EDInspectorTextField(edText("焊盘号", "Pad number"), text: $value.number)
        DisclosureGroup(edText("精确位置与形状", "Position and shape")) {
            VStack(alignment: .leading, spacing: 12) {
                EDInspectorPointFields($value.position)
                HStack {
                    EDInspectorNumberField(edText("宽度 (mm)", "Width (mm)"), value: $value.size.x)
                    EDInspectorNumberField(edText("高度 (mm)", "Height (mm)"), value: $value.size.y)
                }
                Picker(edText("形状", "Shape"), selection: $value.shape) { ForEach(EDAPadShape.allCases, id: \.self) { Text(edaPadShapeTitle($0)).tag($0) } }
                EDInspectorNumberField(edText("旋转 (°)", "Rotation (°)"), value: $value.angle)
                Toggle(edText("通孔", "Through hole"), isOn: Binding(get: { value.drill != nil }, set: { value.drill = $0 ? 0.8 : nil; if !$0 { value.drillPlated = nil } }))
                if value.drill != nil {
                    EDInspectorNumberField(edText("孔径 (mm)", "Drill (mm)"), value: Binding(get: { value.drill ?? 0.8 }, set: { value.drill = $0 }))
                    EDPlatingPicker(title: edText("孔壁电镀", "Hole plating"), value: $value.drillPlated)
                }
                EDPadOpeningFields(value:$value)
                ForEach(value.layers.indices, id: \.self) { i in
                    HStack(alignment: .bottom) {
                        EDInspectorTextField(edText("图层", "Layer") + " \(i + 1)", text: $value.layers[i])
                        Button(role: .destructive) { value.layers.remove(at: i) } label: { Image(systemName: "minus.circle") }
                            .frame(minWidth: 44, minHeight: 44).disabled(value.layers.count <= 1)
                            .accessibilityLabel(edText("移除此图层", "Remove layer"))
                    }
                }
                Button(edText("添加图层", "Add layer")) {
                    let next = ["F.Cu", "B.Cu", "F.Mask", "B.Mask", "F.Paste", "B.Paste"].first { !value.layers.contains($0) }
                    if let next { value.layers.append(next) }
                }.disabled(["F.Cu", "B.Cu", "F.Mask", "B.Mask", "F.Paste", "B.Paste"].allSatisfy { value.layers.contains($0) })
            }.padding(.top, 8)
        }
    }
}

private struct EDGraphicsEditor:View {
    @Binding var graphics:[EDAGraphic]
    var layers:Binding<[EDAGraphicLayerAssignment?]?>? = nil
    var additionalLayers:[EDAGraphicLayerAssignment] = []
    @State private var newLayer:EDAGraphicLayerAssignment?
    @State private var editFailure:String?
    @State private var x1=0.0
    @State private var y1=0.0
    @State private var x2=5.0
    @State private var y2=5.0
    @State private var width=0.2
    @State private var text=""
    private var choices:[EDAGraphicLayerAssignment] {
        var result=EDAGraphicLayers.standardAssignments
        for value in additionalLayers where !result.contains(value){result.append(value)}
        return result
    }
    var body:some View{DisclosureGroup(edText("图形","Graphics")){VStack(alignment:.leading,spacing:12){
        if graphics.isEmpty{Text(edText("尚无图形，可在上方输入坐标添加，或直接在图纸上拖拽绘制。","No graphics yet. Add coordinates above or drag on the drawing.")).font(.caption).foregroundStyle(.secondary)}
        ForEach(graphics.indices,id:\.self){i in graphicRow(i)}
        if layers != nil {
            Picker(edText("新图形层","New graphic layer"),selection:$newLayer){layerOptions(current:newLayer)}
        }
        HStack{EDInspectorNumberField("X1 (mm)",value:$x1);EDInspectorNumberField("Y1 (mm)",value:$y1)}
        HStack{EDInspectorNumberField("X2 (mm)",value:$x2);EDInspectorNumberField("Y2 (mm)",value:$y2)}
        EDInspectorNumberField(edText("线宽 (mm)","Stroke (mm)"),value:$width)
        Button(edText("添加线段","Add line")){if let value=EDLibraryEditing.lineShape(from:.init(x1,y1),to:.init(x2,y2),stroke:width){append(value)}}
        Button(edText("添加矩形","Add rectangle")){if let value=EDLibraryEditing.rectangleShape(from:.init(x1,y1),to:.init(x2,y2),stroke:width){append(value)}}
        Button(edText("添加圆","Add circle")){if let value=EDLibraryEditing.circleShape(from:.init(x1,y1),to:.init(x2,y2),stroke:width){append(value)}}
        EDInspectorTextField(edText("文字","Text"),text:$text);Button(edText("添加文字","Add text")){append(.text(text,position:.init(x1,y1),height:1.8,angle:0))}
        if let editFailure {DisclosureGroup(edText("图形编辑详情","Graphic edit details")){Text(editFailure).font(.caption)}}
    }}}
    private func append(_ value:EDAGraphic){change{g,l in try EDAGraphicEditing.append(value,layer:layers == nil ? nil:newLayer,graphics:&g,layers:&l)}}
    private func change(_ operation:(inout [EDAGraphic],inout [EDAGraphicLayerAssignment?]?)throws->Void){
        var g=graphics,l=layers?.wrappedValue
        do{try operation(&g,&l);graphics=g;layers?.wrappedValue=l;editFailure=nil}catch{editFailure=String(describing:error)}
    }
    @ViewBuilder private func layerOptions(current:EDAGraphicLayerAssignment?)->some View {
        Text(edText("未分配","Unassigned")).tag(Optional<EDAGraphicLayerAssignment>.none)
        if let current,!choices.contains(current){Text(layerTitle(current)).tag(Optional(current))}
        ForEach(choices,id:\.self){Text(layerTitle($0)).tag(Optional($0))}
    }
    private func layerTitle(_ value:EDAGraphicLayerAssignment)->String {
        let kind:String
        switch value.kind {
        case .copper:kind=edText("铜层","Copper")
        case .silkscreen:kind=edText("丝印","Silkscreen")
        case .fabrication:kind=edText("制造图","Fabrication")
        case .courtyard:kind=edText("庭院","Courtyard")
        case .mask:kind=edText("阻焊","Solder mask")
        case .paste:kind=edText("钢网","Solder paste")
        case .dielectric:kind=edText("介质","Dielectric")
        }
        return value.layerID+" · "+kind
    }
    private func graphicRow(_ index:Int)->some View {
        VStack(alignment:.leading,spacing:6){
            Text(edaGraphicKindTitle(graphics[index]));Text(edaGraphicSummary(graphics[index])).font(.caption).foregroundStyle(.secondary)
            if layers != nil {
                let current=layers?.wrappedValue?[index] ?? nil
                Picker(edText("图层","Layer"),selection:Binding(get:{layers?.wrappedValue?[index] ?? nil},set:{value in
                    change{g,l in try EDAGraphicEditing.assign(value,at:index,graphics:g,layers:&l)}
                })){layerOptions(current:current)}
                if current?.kind == .copper {Text(edText("当前铜层输出尚不支持自由图形。","Copper output does not yet support graphic shapes.")).font(.caption).foregroundStyle(.secondary)}
                else if current?.kind == .mask || current?.kind == .paste {Text(edText("此图形层的输出尚未支持。","Output for this graphic layer is not supported yet.")).font(.caption).foregroundStyle(.secondary)}
                else if current == nil {Text(edText("请选择图层后输出。","Assign a layer before plotting.")).font(.caption).foregroundStyle(.secondary)}
            }
            HStack{
                Button{change{g,l in try EDAGraphicEditing.move(from:index,to:index-1,graphics:&g,layers:&l)}}label:{Image(systemName:"arrow.up")}.disabled(index==0).accessibilityLabel(edText("上移图形","Move graphic up"))
                Button{change{g,l in try EDAGraphicEditing.move(from:index,to:index+1,graphics:&g,layers:&l)}}label:{Image(systemName:"arrow.down")}.disabled(index+1>=graphics.count).accessibilityLabel(edText("下移图形","Move graphic down"))
                Button{change{g,l in try EDAGraphicEditing.duplicate(at:index,graphics:&g,layers:&l)}}label:{Image(systemName:"plus.square.on.square")}.accessibilityLabel(edText("复制图形","Duplicate graphic"))
                Spacer()
                Button(role:.destructive){change{g,l in try EDAGraphicEditing.remove(at:index,graphics:&g,layers:&l)}}label:{Image(systemName:"trash")}.accessibilityLabel(edText("删除图形","Delete graphic"))
            }.buttonStyle(.borderless)
        }
    }
}

private struct EDPlatingPicker:View {
    let title:String
    @Binding var value:Bool?
    var body:some View {Picker(title,selection:$value){
        Text(edText("未指定","Not specified")).tag(Optional<Bool>.none)
        Text(edText("不电镀","Non-plated")).tag(Optional(false))
        Text(edText("电镀","Plated")).tag(Optional(true))
    }}
}

private struct EDViaMaskFields:View {
    @Binding var value:EDAVia
    private var surfaces:Set<String>{Set([value.startLayer,value.endLayer])}
    var body:some View {
        Picker(edText("阻焊开窗","Solder mask openings"),selection:Binding(get:{value.maskLayers?.sorted()},set:{value.maskLayers=$0})){
            Text(edText("未指定","Unspecified")).tag([String]?.none)
            Text(edText("盖油","Tented")).tag(Optional([String]()))
            if surfaces.contains("F.Cu"){Text(edText("正面开窗","Front opening")).tag(Optional(["F.Mask"]))}
            if surfaces.contains("B.Cu"){Text(edText("背面开窗","Back opening")).tag(Optional(["B.Mask"]))}
            if surfaces.contains("F.Cu") && surfaces.contains("B.Cu"){Text(edText("双面开窗","Both sides open")).tag(Optional(["B.Mask","F.Mask"]))}
        }
    }
}
private struct EDPadOpeningFields:View {
    @Binding var value:EDAPad
    private func opening(_ layer:String)->Binding<Bool>{Binding(get:{value.layers.contains(layer)},set:{enabled in
        if enabled{if !value.layers.contains(layer){value.layers.append(layer)}}else{value.layers.removeAll{$0==layer}}
    })}
    var body:some View {
        DisclosureGroup(edText("阻焊与钢网开窗","Mask and paste openings")){
            Toggle(edText("正面阻焊","Front solder mask"),isOn:opening("F.Mask"))
            Toggle(edText("背面阻焊","Back solder mask"),isOn:opening("B.Mask"))
            Toggle(edText("正面钢网","Front solder paste"),isOn:opening("F.Paste"))
            Toggle(edText("背面钢网","Back solder paste"),isOn:opening("B.Paste"))
            Text(edText("开窗与焊盘同尺寸。","Openings match the pad size.")).font(.caption).foregroundStyle(.secondary)
        }
    }
}
