// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeElectronicsCore

struct EDAInspector:View {
    @Bindable var session:EDWorkbenchSession
    let context:EDADocumentContext?
    @ViewBuilder var body:some View {
        switch context {
        case .schematic(let sheetID):
            if let placement=session.project.sheets.first(where:{$0.id==sheetID})?.symbols.first(where:{session.selection.objectIDs.contains($0.id)}),let component=session.project.components.first(where:{$0.id==placement.componentID}){
                EDComponentProperties(session:session,sheetID:sheetID,placement:placement,component:component).id(placement.id)
            }else{Form{Section(edText("选择","Selection")){Text(edText("选择元件后编辑属性。","Select a component to edit its properties."));Text(edText("选择符号后使用“放置”，再点绘图区。","Choose a symbol and Place, then tap the drawing."))}}}
        case .board(let boardID):
            if let board=session.project.boards.first(where:{$0.id==boardID}){
                if let item=board.footprints.first(where:{session.selection.objectIDs.contains($0.id)}){EDFootprintProperties(session:session,boardID:boardID,value:item).id(item.id)}
                else{EDBoardProperties(session:session,value:board).id(boardID)}
            }
        case .symbol(let id):if let value=session.project.symbols.first(where:{$0.id==id}){EDSymbolProperties(session:session,value:value).id(id)}
        case .footprint(let id):if let value=session.project.footprints.first(where:{$0.id==id}){EDLibraryFootprintProperties(session:session,value:value).id(id)}
        case nil:EmptyView()
        }
    }
}

private struct EDComponentProperties:View {
    let session:EDWorkbenchSession;let sheetID:UUID
    @State var placement:EDASymbolPlacement
    @State var component:EDAComponent
    @State private var revision:UInt64?
    var body:some View {Form{
        Section(edText("元件","Component")){
            TextField(edText("编号","Reference"),text:$component.reference)
            TextField(edText("值","Value"),text:$component.value)
            TextField("X (mm)",value:$placement.position.x,format:.number)
            TextField("Y (mm)",value:$placement.position.y,format:.number)
            TextField(edText("角度 (°)","Angle (°)"),value:$placement.angle,format:.number)
            Toggle(edText("镜像","Mirror"),isOn:$placement.mirrored)
            Picker(edText("封装","Footprint"),selection:$component.footprintID){Text(edText("未分配","Unassigned")).tag(Optional<UUID>.none);ForEach(session.project.footprints){Text($0.name).tag(Optional($0.id))}}
            Button(edText("应用修改","Apply changes")){commit([.putComponent(component),.placeSymbol(sheet:sheetID,placement)])}
        }
        Section{
            Button(edText("旋转 90°","Rotate 90°")){placement.angle += 90;commit([.placeSymbol(sheet:sheetID,placement)])}
            Button(edText("复制","Duplicate")){
                var part=component;part.id=UUID();let prefix=session.project.symbols.first{$0.id==component.symbolID}?.referencePrefix ?? "U";part.reference=EDABuiltinLibrary.nextReference(prefix,in:session.project)
                var instance=placement;instance.id=UUID();instance.componentID=part.id;instance.position=instance.position + .init(5.08,-5.08)
                commit([.putComponent(part),.placeSymbol(sheet:sheetID,instance)])
            }
            Button(edText("删除","Delete"),role:.destructive){commit([.removeComponent(component.id)])}
        }
    }.onAppear{revision=session.revision}}
    private func commit(_ edits:[EDAEdit]){Task{do{try await session.apply(edits,expectedRevision:revision);revision=session.revision}catch{session.report(error)}}}
}

private struct EDFootprintProperties:View {
    let session:EDWorkbenchSession;let boardID:UUID
    @State var value:EDAFootprint
    @State private var revision:UInt64?
    var body:some View {Form{
        Section(edText("封装","Footprint")){
            TextField(edText("编号","Reference"),text:$value.reference);TextField(edText("值","Value"),text:$value.value)
            TextField("X (mm)",value:$value.position.x,format:.number);TextField("Y (mm)",value:$value.position.y,format:.number)
            TextField(edText("角度 (°)","Angle (°)"),value:$value.angle,format:.number)
            Picker(edText("板面","Side"),selection:$value.side){Text(edText("正面","Front")).tag("F.Cu");Text(edText("背面","Back")).tag("B.Cu")}
            Toggle(edText("锁定","Locked"),isOn:$value.locked)
            Button(edText("应用修改","Apply changes")){commit([.putFootprint(board:boardID,value)])}
        }
        Section{
            Button(edText("旋转 90°","Rotate 90°")){guard !value.locked else{return};value.angle += 90;commit([.putFootprint(board:boardID,value)])}.disabled(value.locked)
            Button(edText("复制封装","Duplicate footprint")){var copy=value;copy.id=UUID();copy.componentID=nil;copy.reference += "-copy";copy.position=copy.position + .init(5,5);copy.locked=false;commit([.putFootprint(board:boardID,copy)])}
            Button(edText("删除","Delete"),role:.destructive){commit([.removeBoardObject(board:boardID,object:value.id)])}.disabled(value.locked)
        }
    }.onAppear{revision=session.revision}}
    private func commit(_ edits:[EDAEdit]){Task{do{try await session.apply(edits,expectedRevision:revision);revision=session.revision}catch{session.report(error)}}}
}

private struct EDBoardProperties:View {
    let session:EDWorkbenchSession
    @State var value:EDABoard
    @State private var revision:UInt64?
    var body:some View {Form{
        Section(edText("PCB 设置","Board settings")){
            TextField(edText("名称","Name"),text:$value.name)
            TextField(edText("板边净距 (mm)","Edge clearance (mm)"),value:$value.boardEdgeClearance,format:.number)
        }
        Section(edText("板框顶点（mm）","Outline vertices (mm)")){
            ForEach(value.outline.indices,id:\.self){i in HStack{TextField("X",value:$value.outline[i].x,format:.number);TextField("Y",value:$value.outline[i].y,format:.number)}}
        }
        Section(edText("层叠","Stackup")){
            ForEach(value.layers.indices,id:\.self){i in VStack(alignment:.leading){Text(value.layers[i].id);TextField(edText("厚度 (mm)","Thickness (mm)"),value:$value.layers[i].thickness,format:.number);TextField(edText("材料","Material"),text:$value.layers[i].material)}}
        }
        Button(edText("应用修改","Apply changes")){Task{do{try await session.apply([.putBoard(value)],expectedRevision:revision);revision=session.revision}catch{session.report(error)}}}
    }.onAppear{revision=session.revision}}
}

private struct EDSymbolProperties:View {
    let session:EDWorkbenchSession
    @State var value:EDASymbolDefinition
    @State private var revision:UInt64?
    var body:some View{Form{
        Section(edText("符号","Symbol")){TextField(edText("名称","Name"),text:$value.name);TextField(edText("编号前缀","Reference prefix"),text:$value.referencePrefix)}
        Section(edText("引脚","Pins")){
            ForEach(value.pins.indices,id:\.self){i in VStack(alignment:.leading,spacing:6){HStack{TextField(edText("脚号","Number"),text:$value.pins[i].number);TextField(edText("名称","Name"),text:$value.pins[i].name)};HStack{TextField("X (mm)",value:$value.pins[i].position.x,format:.number);TextField("Y (mm)",value:$value.pins[i].position.y,format:.number)};Picker(edText("电气类型","Electrical type"),selection:$value.pins[i].type){ForEach(EDAPinType.allCases,id:\.self){Text(edaPinTypeTitle($0)).tag($0)}};Button(edText("移除此引脚","Remove pin"),role:.destructive){value.pins.remove(at:i)}}}
            Button(edText("添加引脚","Add pin")){value.pins.append(.init(number:EDLibraryEditing.nextPinNumber(value.pins),position:.init(0,Double(value.pins.count)*2.54)))}
        }
        EDGraphicsEditor(graphics:$value.graphics)
        Button(edText("保存符号","Save symbol")){Task{do{try await session.apply([.putSymbol(value)],expectedRevision:revision);revision=session.revision}catch{session.report(error)}}}
    }.onAppear{revision=session.revision}}
}

private struct EDLibraryFootprintProperties:View {
    let session:EDWorkbenchSession
    @State var value:EDAFootprintDefinition
    @State private var revision:UInt64?
    var body:some View{Form{
        Section(edText("封装","Footprint")){TextField(edText("名称","Name"),text:$value.name)}
        Section(edText("焊盘","Pads")){
            ForEach(value.pads.indices,id:\.self){i in VStack(alignment:.leading,spacing:6){
                TextField(edText("焊盘号","Pad number"),text:$value.pads[i].number)
                HStack{TextField("X (mm)",value:$value.pads[i].position.x,format:.number);TextField("Y (mm)",value:$value.pads[i].position.y,format:.number)}
                HStack{TextField(edText("宽度 (mm)","Width (mm)"),value:$value.pads[i].size.x,format:.number);TextField(edText("高度 (mm)","Height (mm)"),value:$value.pads[i].size.y,format:.number)}
                Picker(edText("形状","Shape"),selection:$value.pads[i].shape){ForEach(EDAPadShape.allCases,id:\.self){Text(edaPadShapeTitle($0)).tag($0)}}
                TextField(edText("角度 (°)","Angle (°)"),value:$value.pads[i].angle,format:.number)
                Toggle(edText("通孔","Through hole"),isOn:Binding(get:{value.pads[i].drill != nil},set:{value.pads[i].drill=$0 ? 0.8:nil}))
                if value.pads[i].drill != nil {TextField(edText("孔径 (mm)","Drill (mm)"),value:Binding(get:{value.pads[i].drill ?? 0.8},set:{value.pads[i].drill=$0}),format:.number)}
                Button(edText("移除此焊盘","Remove pad"),role:.destructive){value.pads.remove(at:i)}
            }}
            Button(edText("添加焊盘","Add pad")){value.pads.append(.init(number:EDLibraryEditing.nextPadNumber(value.pads),position:.init(Double(value.pads.count)*2.54,0)))}
        }
        EDGraphicsEditor(graphics:$value.graphics)
        Button(edText("保存封装","Save footprint")){Task{do{try await session.apply([.putFootprintDefinition(value)],expectedRevision:revision);revision=session.revision}catch{session.report(error)}}}
    }.onAppear{revision=session.revision}}
}

private struct EDGraphicsEditor:View {
    @Binding var graphics:[EDAGraphic]
    @State private var x1=0.0
    @State private var y1=0.0
    @State private var x2=5.0
    @State private var y2=5.0
    @State private var width=0.2
    @State private var text=""
    var body:some View{Section(edText("图形","Graphics")){
        if graphics.isEmpty{Text(edText("尚无图形，可在上方输入坐标添加，或直接在图纸上拖拽绘制。","No graphics yet. Add coordinates above or drag on the drawing.")).font(.caption).foregroundStyle(.secondary)}
        ForEach(graphics.indices,id:\.self){i in HStack(alignment:.top){VStack(alignment:.leading){Text(edaGraphicKindTitle(graphics[i]));Text(edaGraphicSummary(graphics[i])).font(.caption).foregroundStyle(.secondary)};Spacer();Button(role:.destructive){graphics.remove(at:i)}label:{Image(systemName:"trash")}}}
        HStack{TextField("X1 (mm)",value:$x1,format:.number);TextField("Y1 (mm)",value:$y1,format:.number)}
        HStack{TextField("X2 (mm)",value:$x2,format:.number);TextField("Y2 (mm)",value:$y2,format:.number)}
        TextField(edText("线宽 (mm)","Stroke (mm)"),value:$width,format:.number)
        Button(edText("添加线段","Add line")){if let value=EDLibraryEditing.lineShape(from:.init(x1,y1),to:.init(x2,y2),stroke:width){graphics.append(value)}}
        Button(edText("添加矩形","Add rectangle")){if let value=EDLibraryEditing.rectangleShape(from:.init(x1,y1),to:.init(x2,y2),stroke:width){graphics.append(value)}}
        Button(edText("添加圆","Add circle")){if let value=EDLibraryEditing.circleShape(from:.init(x1,y1),to:.init(x2,y2),stroke:width){graphics.append(value)}}
        TextField(edText("文字","Text"),text:$text);Button(edText("添加文字","Add text")){graphics.append(.text(text,position:.init(x1,y1),height:1.8,angle:0))}
    }}
}
