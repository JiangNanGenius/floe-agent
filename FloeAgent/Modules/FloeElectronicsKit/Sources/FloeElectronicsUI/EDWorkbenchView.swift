// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeElectronicsCore

func edText(_ zh:String,_ en:String)->String {Locale.preferredLanguages.first?.hasPrefix("zh")==true ? zh:en}

private enum EDWorkspaceTab:String,CaseIterable,Identifiable {
    case schematic,board,symbols,footprints,checks,outputs,threeD
    var id:Self{self}
    var title:String{switch self{case .schematic:edText("原理图","Schematic");case .board:"PCB";case .symbols:edText("符号库","Symbols");case .footprints:edText("封装库","Footprints");case .checks:edText("检查","Checks");case .outputs:edText("输出","Outputs");case .threeD:edText("三维","3D")}}
}
private enum EDCanvasTool:String,CaseIterable,Identifiable {
    case select,place,wire,junction,label,erase
    var id:Self{self}
    var title:String{switch self{case .select:edText("选择","Select");case .place:edText("放置","Place");case .wire:edText("连线","Wire");case .junction:edText("连接点","Junction");case .label:edText("标签","Label");case .erase:edText("擦除","Erase")}}
    var image:String{switch self{case .select:"cursorarrow";case .place:"plus.square";case .wire:"point.topleft.down.to.point.bottomright.curvepath";case .junction:"circle.fill";case .label:"tag";case .erase:"eraser"}}
}
/// Drawing actions offered on the symbol and footprint library canvases.
private enum EDLibraryTool:String,CaseIterable,Identifiable {
    case select,line,rectangle,circle,pin,pad,erase
    var id:Self{self}
    var title:String{switch self{case .select:edText("选择","Select");case .line:edText("线段","Line");case .rectangle:edText("矩形","Rectangle");case .circle:edText("圆","Circle");case .pin:edText("引脚","Pin");case .pad:edText("焊盘","Pad");case .erase:edText("擦除","Erase")}}
    var image:String{switch self{case .select:"cursorarrow";case .line:"slash";case .rectangle:"rectangle";case .circle:"circle";case .pin:"pin.fill";case .pad:"square.fill";case .erase:"eraser"}}
    /// Familiar schematic-editor actions for symbol definitions.
    static let symbolTools:[Self]=[.select,.line,.rectangle,.circle,.pin,.erase]
    /// Pad placement plus the same drawing actions for footprint definitions.
    static let footprintTools:[Self]=[.select,.pad,.line,.rectangle,.circle,.erase]
}
private enum EDCanvasMode:Equatable {
    case schematic(EDCanvasTool),board(EDCanvasTool),symbol(EDLibraryTool),footprint(EDLibraryTool)
}

public struct EDWorkbenchView:View {
    @Bindable var session:EDWorkbenchSession
    let onAssistant:(()->Void)?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var tab=EDWorkspaceTab.schematic
    @State private var inspector=false
    @State private var library=false
    @State private var sheetID:UUID?
    @State private var boardID:UUID?
    @State private var symbolID:UUID?
    @State private var footprintID:UUID?
    @State private var tool=EDCanvasTool.select
    @State private var libraryTool=EDLibraryTool.select
    @State private var query=""
    @State private var labelName="NET"
    @State private var activeLayer="F.Cu"
    @State private var wireWidth=0.25
    @State private var reload=false
    @State private var viewportWidth:CGFloat=0
    private var usesCompactPanels:Bool {sizeClass == .compact || viewportWidth<950}
    public init(session:EDWorkbenchSession,onAssistant:(()->Void)?=nil){self.session=session;self.onAssistant=onAssistant}
    private var context:EDADocumentContext? {
        switch tab {
        case .schematic:return (sheetID ?? session.project.sheets.first?.id).map{.schematic(sheetID:$0)}
        case .board,.threeD:return (boardID ?? session.project.boards.first?.id).map{.board(boardID:$0)}
        case .symbols:return (symbolID ?? session.project.symbols.first?.id).map{.symbol(definitionID:$0)}
        case .footprints:return (footprintID ?? session.project.footprints.first?.id).map{.footprint(definitionID:$0)}
        default:return nil
        }
    }
    private var canvasMode:EDCanvasMode {
        switch tab {
        case .board:return .board(tool)
        case .symbols:return .symbol(libraryTool)
        case .footprints:return .footprint(libraryTool)
        default:return .schematic(tool)
        }
    }
    private var isDrawingTab:Bool {tab == .schematic || tab == .board || tab == .symbols || tab == .footprints}
    public var body:some View {
        VStack(spacing:0){
            ScrollView(.horizontal){HStack(spacing:6){ForEach(EDWorkspaceTab.allCases){item in
                Button(item.title){tab=item;session.selection = .none}.buttonStyle(.bordered).tint(tab==item ? .accentColor:.secondary).accessibilityIdentifier("electronics.tab."+item.rawValue)
            }}.padding(.horizontal,10).padding(.vertical,6)}.scrollIndicators(.hidden)
            Divider()
            if let failure=session.lastError {
                HStack{Image(systemName:"exclamationmark.triangle");Text(failure.message).font(.caption);Spacer()
                    if session.conflictWithOriginal{Button(edText("重新载入","Reload")){reload=true}}
                }.padding(8).background(.orange.opacity(0.12))
            }
            if tab == .checks {EDAChecksView(session:session,onFocus:{request in
                session.requestFocus(request);switch request.context{case .schematic(let id):sheetID=id;tab = .schematic;case .board(let id):boardID=id;tab = .board;default:break}
            })}
            else if tab == .outputs {EDAOutputsView(session:session)}
            else if tab == .threeD {EDABoard3DView(project:session.project,boardID:boardID ?? session.project.boards.first?.id)}
            else {
                if usesCompactPanels {HStack{Button(edText("图页与元件","Sheets & parts")){library=true};Spacer();Button(edText("属性","Properties")){inspector=true}}.padding(.horizontal,12).padding(.vertical,6)}
                HStack(spacing:0){
                    if !usesCompactPanels {navigator.frame(width:210);Divider()}
                    VStack(spacing:0){canvasTools;Divider()
                        if let context {EDCanvasEditor(session:session,context:context,mode:canvasMode,symbolID:symbolID,footprintID:footprintID,labelName:labelName,layer:activeLayer,width:wireWidth)}
                        else{ContentUnavailableView(edText("选择图页或库项目","Select a sheet or library item"),systemImage:"square.dashed")}
                    }.frame(maxWidth:.infinity,maxHeight:.infinity)
                    if !usesCompactPanels {Divider();EDAInspector(session:session,context:context).frame(width:245)}
                }
            }
            HStack{Text(session.isRouting ? edText("正在布线…","Routing…"):(session.busy ? edText("正在保存…","Saving…"):(session.isDirty ? edText("有未保存的修改","Unsaved changes"):edText("已保存","Saved"))))
                Spacer();if session.isRouting{Button(edText("停止","Stop")){session.cancelRouting()}};Text("mm");if session.busy || session.isRouting{ProgressView().controlSize(.small)}}.font(.caption).foregroundStyle(.secondary).padding(.horizontal,12).padding(.vertical,5)
        }
        .accessibilityIdentifier("electronics.workbench")
        .onGeometryChange(for:CGFloat.self){$0.size.width}action:{viewportWidth=$0}
        .toolbar{ToolbarItemGroup(placement:.automatic){
            Button{Task{do{try await session.undo()}catch{session.report(error)}}}label:{Image(systemName:"arrow.uturn.backward")}.disabled(!session.canUndo).accessibilityLabel(edText("撤销","Undo"))
            Button{Task{do{try await session.redo()}catch{session.report(error)}}}label:{Image(systemName:"arrow.uturn.forward")}.disabled(!session.canRedo).accessibilityLabel(edText("重做","Redo"))
            if let onAssistant{Button(action:onAssistant){Label(edText("助手","Assistant"),systemImage:"sparkles")}}
        }}
        .sheet(isPresented:$inspector){NavigationStack{EDAInspector(session:session,context:context).toolbar{ToolbarItem(placement:.confirmationAction){Button(edText("完成","Done")){inspector=false}}}}}
        .sheet(isPresented:$library){NavigationStack{navigator.toolbar{ToolbarItem(placement:.confirmationAction){Button(edText("完成","Done")){library=false}}}}}
        .confirmationDialog(edText("放弃未保存的修改并重新载入？","Discard unsaved changes and reload?"),isPresented:$reload,titleVisibility:.visible){
            Button(edText("重新载入","Reload"),role:.destructive){Task{do{try await session.refresh(discardChanges:true)}catch{session.report(error)}}}
        }
        .onChange(of:session.focusRequest){_,request in guard let request else{return};switch request.context{case .schematic(let id):sheetID=id;tab = .schematic;case .board(let id):boardID=id;tab = .board;default:break}}
    }
    private var canvasTools:some View {
        ScrollView(.horizontal){HStack(spacing:8){
            switch tab {
            case .schematic,.board:
                ForEach(EDCanvasTool.allCases){item in Button{tool=item}label:{Label(item.title,systemImage:item.image)}.buttonStyle(.bordered).tint(tool==item ? .accentColor:.secondary).accessibilityIdentifier("electronics.tool."+item.rawValue)}
                if tool == .label{TextField(edText("网络名称","Net name"),text:$labelName).frame(width:110).textFieldStyle(.roundedBorder)}
                if tab == .board {
                    Picker(edText("铜层","Copper layer"),selection:$activeLayer){ForEach((session.project.boards.first(where:{$0.id == boardID}) ?? session.project.boards.first)?.layers.filter{$0.kind == .copper} ?? [],id:\.id){Text($0.id).tag($0.id)}}.frame(width:105)
                    TextField(edText("线宽","Width"),value:$wireWidth,format:.number).frame(width:60).textFieldStyle(.roundedBorder)
                    Button(edText("从原理图更新","Update from schematic")){guard let id=boardID ?? session.project.boards.first?.id else{return};Task{do{try await session.forwardAnnotation(boardID:id)}catch{session.report(error)}}}
                }
            case .symbols:
                ForEach(EDLibraryTool.symbolTools){item in Button{libraryTool=item}label:{Label(item.title,systemImage:item.image)}.buttonStyle(.bordered).tint(libraryTool==item ? .accentColor:.secondary).accessibilityIdentifier("electronics.tool."+item.rawValue)}
            case .footprints:
                ForEach(EDLibraryTool.footprintTools){item in Button{libraryTool=item}label:{Label(item.title,systemImage:item.image)}.buttonStyle(.bordered).tint(libraryTool==item ? .accentColor:.secondary).accessibilityIdentifier("electronics.tool."+item.rawValue)}
            default:EmptyView()
            }
            if isDrawingTab {
                Toggle(isOn:$session.fingerDrawingEnabled){Label(edText("手指绘图","Finger drawing"),systemImage:"hand.draw")}.toggleStyle(.button).accessibilityIdentifier("electronics.fingerDrawing")
            }
        }.padding(8)}.scrollIndicators(.hidden)
    }
    private var navigator:some View {
        List{
            if tab == .schematic {
                Section(edText("图页","Sheets")){ForEach(session.project.sheets){item in Button{sheetID=item.id;library=false}label:{Label(item.name,systemImage:"doc")}}
                    Button(edText("添加图页","Add sheet"),systemImage:"plus"){let item=EDASheet(name:edText("图页 ","Sheet ")+String(session.project.sheets.count+1));perform([.putSheet(item)]);sheetID=item.id}}
            }
            if tab == .board {Section("PCB"){ForEach(session.project.boards){item in Button{boardID=item.id;library=false}label:{Label(item.name,systemImage:"cpu")}}}}
            if tab == .schematic || tab == .symbols {
                Section(edText("元件符号","Symbols")){ForEach(session.project.symbols.filter{query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)}){item in
                    Button{symbolID=item.id;if tab == .schematic{tool = .place;library=false}}label:{HStack{Text(item.name);if symbolID==item.id{Image(systemName:"checkmark")}}}
                }
                    if tab == .symbols{Button(edText("新建符号","New symbol"),systemImage:"plus"){let item=EDASymbolDefinition(name:edText("自建符号","Custom symbol"),pins:[.init(number:"1",position:.init(-2.54,0)),.init(number:"2",position:.init(2.54,0))],graphics:[.rectangle(.init(-1.27,-1.27),.init(1.27,1.27),width:0.2)]);perform([.putSymbol(item)]);symbolID=item.id}}
                }
            }
            if tab == .board || tab == .footprints {
                Section(edText("封装","Footprints")){ForEach(session.project.footprints.filter{query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)}){item in
                    Button{footprintID=item.id;if tab == .board{tool = .place;library=false}}label:{HStack{Text(item.name);if footprintID==item.id{Image(systemName:"checkmark")}}}
                }
                    if tab == .footprints{Button(edText("新建封装","New footprint"),systemImage:"plus"){let item=EDAFootprintDefinition(name:edText("自建封装","Custom footprint"),pads:[.init(number:"1",position:.zero)]);perform([.putFootprintDefinition(item)]);footprintID=item.id}}
                }
            }
        }.listStyle(.sidebar).searchable(text:$query,prompt:edText("搜索元件","Search parts"))
    }
    private func perform(_ edits:[EDAEdit]){Task{do{try await session.apply(edits)}catch{session.report(error)}}}
}

private struct EDCanvasEditor:View {
    @Bindable var session:EDWorkbenchSession
    let context:EDADocumentContext
    let mode:EDCanvasMode
    let symbolID:UUID?
    let footprintID:UUID?
    let labelName:String
    let layer:String
    let width:Double
    @State private var bounds:CGRect?
    @State private var center:EDAPoint?
    @State private var zoom=1.0
    @State private var anchor:EDAPoint?
    /// Start of the in-progress drawing gesture (world mm, snapped).
    @State private var dragStart:EDAPoint?
    @State private var dragEnd:EDAPoint?
    private var tool:EDCanvasTool {
        switch mode { case .schematic(let value),.board(let value):return value;default:return .select }
    }
    private var libraryTool:EDLibraryTool? {
        switch mode { case .symbol(let value),.footprint(let value):return value;default:return nil }
    }
    private var isLibraryContext:Bool {libraryTool != nil}
    private var shapeTool:EDLibraryTool? {
        guard let value=libraryTool,value == .line || value == .rectangle || value == .circle else{return nil}
        return value
    }
    private var previewGraphic:EDAGraphic? {
        guard let start=dragStart,let end=dragEnd,let tool=shapeTool else{return nil}
        switch tool {
        case .line:return EDLibraryEditing.lineShape(from:start,to:end)
        case .rectangle:return EDLibraryEditing.rectangleShape(from:start,to:end)
        case .circle:return EDLibraryEditing.circleShape(from:start,to:end)
        default:return nil
        }
    }
    static func hitTolerance(for projection:EDAProjection)->Double {max(1.2,min(6.0,14.0/projection.scale))}
    var body:some View {
        GeometryReader{geometry in
            let projection=EDAProjection(bounds:bounds ?? EDAPlot.bounds(session.project,context:context),size:geometry.size,center:center,zoom:zoom)
            ZStack(alignment:.bottomTrailing){
                Canvas{canvas,_ in
                    EDAPlot.draw(project:session.project,context:context,projection:projection,selected:session.selection.objectIDs,in:&canvas)
                    if let previewGraphic{EDAPlot.drawPreview(previewGraphic,projection:projection,in:&canvas)}
                }.background(.background)
#if canImport(UIKit)
                EDAInputSurface(fingerDrawing:session.fingerDrawingEnabled,
                    tap:{tap(projection.world($0),tolerance:Self.hitTolerance(for:projection))},
                    move:{move(projection.world($0),projection.world($1),tolerance:Self.hitTolerance(for:projection))},
                    stroke:{stroke(projection.world($0))},
                    pan:{delta in center = projection.center - .init(delta.width/projection.scale,-delta.height/projection.scale)},
                    zoom:{zoom=min(50,max(0.05,zoom*Double($0)))})
#else
                Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged{value in
                    guard shapeTool != nil else{return}
                    if dragStart == nil{dragStart=snapped(projection.world(value.startLocation))}
                    dragEnd=snapped(projection.world(value.location))
                }.onEnded{value in
                    if abs(value.translation.width)+abs(value.translation.height)<3{tap(projection.world(value.location),tolerance:Self.hitTolerance(for:projection))}else{move(projection.world(value.startLocation),projection.world(value.location),tolerance:Self.hitTolerance(for:projection))}
                })
#endif
                HStack{
                    if anchor != nil { Button(edText("取消连线","Cancel wire")){anchor=nil} }
                    Button{zoom=max(0.05,zoom/1.5)}label:{Image(systemName:"minus.magnifyingglass")};Button(edText("适合画面","Fit")){fit()};Button{zoom=min(50,zoom*1.5)}label:{Image(systemName:"plus.magnifyingglass")}}
                    .buttonStyle(.bordered).padding(8).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)).padding(8)
            }
            .onAppear{fit()}.onChange(of:context){_,_ in fit();resetGesture()}
            .onChange(of:mode){_,_ in resetGesture()}.onChange(of:layer){_,_ in anchor=nil}
            .onChange(of:session.focusRequest){_,request in if let request,request.context==context{center=request.positionMillimetres}}
        }
    }
    private func resetGesture(){anchor=nil;dragStart=nil;dragEnd=nil}
    private func fit(){bounds=EDAPlot.bounds(session.project,context:context);center=nil;zoom=1}
    private func snapped(_ point:EDAPoint)->EDAPoint{session.snapToGrid ? point.snapped(to:session.gridSizeMillimetres):point}
    private func nearest(_ point:EDAPoint)->UUID? {
        let candidates:[(UUID,EDAPoint)]
        switch context {
        case .schematic(let id):let sheet=session.project.sheets.first{$0.id==id};candidates=(sheet?.symbols.map{($0.id,$0.position)} ?? [])+(sheet?.wires.flatMap{item in item.points.map{(item.id,$0)}} ?? [])+(sheet?.labels.map{($0.id,$0.position)} ?? [])+(sheet?.junctions.map{($0.id,$0.position)} ?? [])
        case .board(let id):let board=session.project.boards.first{$0.id==id};candidates=(board?.footprints.map{($0.id,$0.position)} ?? [])+(board?.tracks.flatMap{item in item.points.map{(item.id,$0)}} ?? [])+(board?.vias.map{($0.id,$0.position)} ?? [])
        default:return nil
        }
        return candidates.filter{$0.1.distance(to:point)<10}.min{$0.1.distance(to:point)<$1.1.distance(to:point)}?.0
    }
    private func tap(_ raw:EDAPoint,tolerance:Double){let p=snapped(raw)
        if isLibraryContext{libraryTap(p,tolerance:tolerance);return}
        switch tool {
        case .select:session.selection = .init(context:context,objectIDs:Set(nearest(raw).map{[$0]} ?? []))
        case .erase:if let id=nearest(raw){remove(id)}
        case .place:
            switch context {
            case .schematic(let sheet):guard let definition=session.project.symbols.first(where:{$0.id==symbolID}) ?? session.project.symbols.first else{return}
                let footprint=session.project.footprints.first(where:{$0.name == (definition.referencePrefix=="U" ? "DIP-8":definition.referencePrefix=="Q" ? "SOT-23":definition.referencePrefix=="J" ? "Header 1x02":"0603")})
                let component=EDAComponent(symbolID:definition.id,footprintID:footprint?.id,reference:EDABuiltinLibrary.nextReference(definition.referencePrefix,in:session.project),value:definition.name)
                apply([.putComponent(component),.placeSymbol(sheet:sheet,.init(componentID:component.id,position:p))])
            case .board(let board):guard let definition=session.project.footprints.first(where:{$0.id==footprintID}) ?? session.project.footprints.first else{return};apply([.putFootprint(board:board,.init(definitionID:definition.id,reference:"FP"+String((session.project.boards.first{$0.id==board}?.footprints.count ?? 0)+1),position:p))])
            default:break
            }
        case .wire:
            if case .board(let board) = context {
                do {
                    if let first = anchor {
                        anchor = nil
                        let end=try EDAInteractiveRouting.anchor(session.project,boardID:board,at:raw,layer:layer)?.position ?? p
                        Task { do { try await session.route(boardID:board,from:first,to:end,layer:layer,width:width) } catch { session.report(error) } }
                    } else if let start = try EDAInteractiveRouting.anchor(session.project,boardID:board,at:raw,layer:layer) {
                        anchor = start.position
                        session.selection = .init(context:context,objectIDs:[start.objectID])
                    } else { session.report(EDAError.invalid("start routing on a connected pad, track or via")) }
                } catch { session.report(error) }
                return
            }
            guard let first=anchor else{anchor=p;return};anchor=nil;guard first != p else{return}
            switch context {
            case .schematic(let sheet):apply([.putWire(sheet:sheet,.init(points:[first,p]))])
            default:break
            }
        case .junction:if case .schematic(let sheet)=context{apply([.putJunction(sheet:sheet,.init(position:p))])}
        case .label:if case .schematic(let sheet)=context{apply([.putLabel(sheet:sheet,.init(name:labelName,position:p))])}
        }
    }
    private func stroke(_ raw:EDAPoint){
        guard shapeTool != nil else{return}
        let point=snapped(raw)
        if dragStart == nil{dragStart=point}
        dragEnd=point
    }
    private func move(_ from:EDAPoint,_ to:EDAPoint,tolerance:Double){
        if isLibraryContext{libraryMove(from,to,tolerance:tolerance);return}
        guard tool == .select,let id=nearest(from) else{return};let delta=snapped(to)-snapped(from)
        switch context {
        case .schematic(let sheet):
            if var value=session.project.sheets.first(where:{$0.id==sheet})?.symbols.first(where:{$0.id==id}){value.position=value.position+delta;apply([.placeSymbol(sheet:sheet,value)])}
            else if var value=session.project.sheets.first(where:{$0.id==sheet})?.wires.first(where:{$0.id==id}){value.points=value.points.map{$0+delta};apply([.putWire(sheet:sheet,value)])}
        case .board(let board):
            if var value=session.project.boards.first(where:{$0.id==board})?.footprints.first(where:{$0.id==id}){guard !value.locked else{return};value.position=value.position+delta;apply([.putFootprint(board:board,value)])}
            else if var value=session.project.boards.first(where:{$0.id==board})?.tracks.first(where:{$0.id==id}){guard !value.locked else{return};value.points=value.points.map{$0+delta};apply([.putTrack(board:board,value)])}
        default:break
        }
        session.selection = .init(context:context,objectIDs:[id])
    }
    // MARK: - Symbol / footprint library canvas actions
    private func libraryTap(_ p:EDAPoint,tolerance:Double){
        switch mode {
        case .symbol:
            guard case .symbol(let tool)=mode,case .symbol(let id)=context,var definition=session.project.symbols.first(where:{$0.id==id}) else{return}
            switch tool {
            case .select:
                if case .pin(let pinID)=EDLibraryEditing.hitSymbol(definition,at:p,tolerance:tolerance){session.selection = .init(context:context,objectIDs:[pinID])}
                else{session.selection = .init(context:context,objectIDs:[])}
            case .pin:
                let pin=EDAPin(number:EDLibraryEditing.nextPinNumber(definition.pins),position:p)
                definition.pins.append(pin);apply([.putSymbol(definition)])
                session.selection = .init(context:context,objectIDs:[pin.id])
            case .erase:
                guard let hit=EDLibraryEditing.hitSymbol(definition,at:p,tolerance:tolerance) else{return}
                switch hit {
                case .pin(let pinID):definition.pins.removeAll{$0.id==pinID}
                case .graphic(let index):guard definition.graphics.indices.contains(index) else{return};definition.graphics.remove(at:index)
                default:return
                }
                apply([.putSymbol(definition)]);session.selection = .none
            default:break
            }
        case .footprint:
            guard case .footprint(let tool)=mode,case .footprint(let id)=context,var definition=session.project.footprints.first(where:{$0.id==id}) else{return}
            switch tool {
            case .select:
                if case .pad(let padID)=EDLibraryEditing.hitFootprint(definition,at:p,tolerance:tolerance){session.selection = .init(context:context,objectIDs:[padID])}
                else{session.selection = .init(context:context,objectIDs:[])}
            case .pad:
                let pad=EDAPad(number:EDLibraryEditing.nextPadNumber(definition.pads),position:p)
                definition.pads.append(pad);apply([.putFootprintDefinition(definition)])
                session.selection = .init(context:context,objectIDs:[pad.id])
            case .erase:
                guard let hit=EDLibraryEditing.hitFootprint(definition,at:p,tolerance:tolerance) else{return}
                switch hit {
                case .pad(let padID):definition.pads.removeAll{$0.id==padID}
                case .graphic(let index):guard definition.graphics.indices.contains(index) else{return};definition.graphics.remove(at:index)
                default:return
                }
                apply([.putFootprintDefinition(definition)]);session.selection = .none
            default:break
            }
        default:break
        }
    }
    private func libraryMove(_ from:EDAPoint,_ to:EDAPoint,tolerance:Double){
        defer{dragStart=nil;dragEnd=nil}
        let start=snapped(from),end=snapped(to)
        if let tool=shapeTool{
            guard start != end else{return}
            let graphic:EDAGraphic?
            switch tool {
            case .line:graphic=EDLibraryEditing.lineShape(from:start,to:end)
            case .rectangle:graphic=EDLibraryEditing.rectangleShape(from:start,to:end)
            case .circle:graphic=EDLibraryEditing.circleShape(from:start,to:end)
            default:graphic=nil
            }
            guard let graphic else{return}
            switch mode {
            case .symbol:
                guard case .symbol(let id)=context,var definition=session.project.symbols.first(where:{$0.id==id}) else{return}
                definition.graphics.append(graphic);apply([.putSymbol(definition)])
            case .footprint:
                guard case .footprint(let id)=context,var definition=session.project.footprints.first(where:{$0.id==id}) else{return}
                definition.graphics.append(graphic);apply([.putFootprintDefinition(definition)])
            default:return
            }
            return
        }
        guard let tool=libraryTool,tool == .select else{return}
        let delta=end-start
        guard delta != .zero else{return}
        switch mode {
        case .symbol:
            guard case .symbol(let id)=context,var definition=session.project.symbols.first(where:{$0.id==id}) else{return}
            guard let hit=EDLibraryEditing.hitSymbol(definition,at:start,tolerance:tolerance) else{return}
            switch hit {
            case .pin(let pinID):
                guard let index=definition.pins.firstIndex(where:{$0.id==pinID}) else{return}
                definition.pins[index].position=definition.pins[index].position+delta
                apply([.putSymbol(definition)])
                session.selection = .init(context:context,objectIDs:[pinID])
            case .graphic(let index):
                guard definition.graphics.indices.contains(index) else{return}
                definition.graphics[index]=EDLibraryEditing.translated(definition.graphics[index],by:delta)
                apply([.putSymbol(definition)])
            default:return
            }
        case .footprint:
            guard case .footprint(let id)=context,var definition=session.project.footprints.first(where:{$0.id==id}) else{return}
            guard let hit=EDLibraryEditing.hitFootprint(definition,at:start,tolerance:tolerance) else{return}
            switch hit {
            case .pad(let padID):
                guard let index=definition.pads.firstIndex(where:{$0.id==padID}) else{return}
                definition.pads[index].position=definition.pads[index].position+delta
                apply([.putFootprintDefinition(definition)])
                session.selection = .init(context:context,objectIDs:[padID])
            case .graphic(let index):
                guard definition.graphics.indices.contains(index) else{return}
                definition.graphics[index]=EDLibraryEditing.translated(definition.graphics[index],by:delta)
                apply([.putFootprintDefinition(definition)])
            default:return
            }
        default:return
        }
    }
    private func remove(_ id:UUID){
        switch context {
        case .schematic(let sheet):
            if let value=session.project.sheets.first(where:{$0.id==sheet})?.symbols.first(where:{$0.id==id}),
               session.project.sheets.flatMap(\.symbols).filter({$0.componentID==value.componentID}).count==1 {
                apply([.removeComponent(value.componentID)])
            } else {apply([.removeSchematicObject(sheet:sheet,object:id)])}
        case .board(let board):apply([.removeBoardObject(board:board,object:id)])
        default:break
        }
        session.selection = .none
    }
    private func apply(_ edits:[EDAEdit]){Task{do{try await session.apply(edits)}catch{session.report(error)}}}
}
