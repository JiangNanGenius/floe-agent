// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeElectronicsCore

struct EDCanvasEditor:View {
    @Bindable var session:EDWorkbenchSession
    let context:EDADocumentContext
    let mode:EDCanvasMode
    let symbolID:UUID?
    let footprintID:UUID?
    let labelName:String
    let layer:String
    let width:Double
    let netID:String
    let holeDiameter:Double
    let showGrid:Bool
    @Binding var placementAngle:Double
    @Binding var placementFlipped:Bool
    let onCancel:()->Void
    let onProperties:()->Void
    var onWireToolRequested:(()->Void)?=nil
    @State private var bounds:CGRect?
    @State private var center:EDAPoint?
    @State private var zoom=1.0
    @State private var anchor:EDAPoint?
    /// Start of the in-progress drawing gesture (world mm, snapped).
    @State private var dragStart:EDAPoint?
    @State private var dragEnd:EDAPoint?
    @State private var pointer:EDAPoint?
    @State private var polygon:[EDAPoint]=[]
    @State private var draftRevision:UInt64?
    @State private var movingIDs:Set<UUID>=[]
    @State private var committing=false
    @State private var gestureGeneration=UUID()
    @State private var ownedEdit:Task<Void,Never>?
    @State private var pendingBusUnfold:EDBusUnfoldDraft?
    @State private var choosingBusMember=false
    private var editingEnabled:Bool{!committing && !session.busy && !session.isRouting && !session.isFilling && !session.isClosed}
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
    static func hitTolerance(for projection:EDAProjection)->Double {max(0.05,min(6.0,14.0/projection.scale))}
    var body:some View {
        VStack(spacing:0){
            gestureStatus
            drawing
            if !session.selection.objectIDs.isEmpty && session.selection.context==context {selectionActions}
        }.popover(isPresented:$choosingBusMember){if let bus=selectedBus{EDBusMemberPicker(bus:bus){beginBusUnfold($0)}}}

    }
    private var drawing:some View {
        GeometryReader{geometry in
            let projection=EDAProjection(bounds:bounds ?? EDAPlot.bounds(session.project,context:context),size:geometry.size,center:center,zoom:zoom)
            ZStack(alignment:.bottomTrailing){
                Canvas{canvas,_ in
                    if showGrid{EDAPlot.drawGrid(projection:projection,spacing:session.gridSizeMillimetres,in:&canvas)}
                    let offset=tool == .select && !movingIDs.isEmpty ? (dragEnd ?? .zero)-(dragStart ?? .zero):.zero
                    EDAPlot.draw(project:session.project,context:context,projection:projection,selected:session.selection.objectIDs,selectionOffset:offset,in:&canvas)
                    if let previewGraphic{EDAPlot.drawPreview(previewGraphic,projection:projection,in:&canvas)}
                    if tool == .place,!isLibraryContext{EDAPlot.drawPlacement(project:session.project,context:context,definitionID:placementDefinitionID,position:pointer ?? projection.center,angle:placementAngle,flipped:placementFlipped,projection:projection,in:&canvas)}
                    if let draft=pendingBusUnfold,let tip=anchor ?? pointer{EDAPlot.drawPolylinePreview([draft.busPosition,tip],projection:projection,in:&canvas)}
                    if let anchor,let pointer{
                        let points=wirePoints(from:anchor,to:connectionPoint(pointer,tolerance:Self.hitTolerance(for:projection)))
                        EDAPlot.drawPolylinePreview(points,projection:projection,in:&canvas)
                    }
                    if !polygon.isEmpty{EDAPlot.drawPolylinePreview(polygon+(pointer.map{[$0]} ?? []),projection:projection,in:&canvas)}
                }.background(.background)
#if canImport(UIKit)
                EDAInputSurface(fingerDrawing:session.fingerDrawingEnabled,
                    identity:.init(context:context,mode:mode,generation:gestureGeneration,center:projection.center,scale:projection.scale,size:geometry.size),editingEnabled:editingEnabled,
                    tap:{tap(projection.world($0),tolerance:Self.hitTolerance(for:projection))},
                    move:{move(projection.world($0),projection.world($1),tolerance:Self.hitTolerance(for:projection))},
                    stroke:{stroke(projection.world($0),tolerance:Self.hitTolerance(for:projection))},
                    hover:{pointer=snapped(projection.world($0))},
                    select:{select(projection.world($0),tolerance:Self.hitTolerance(for:projection))},
                    cancel:{resetGesture()},command:{command($0)},canCommand:{canCommand($0)},
                    pan:{delta in center = projection.center - .init(delta.width/projection.scale,-delta.height/projection.scale)},
                    zoom:{zoom=min(50,max(0.05,zoom*Double($0)))})
#else
                Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged{value in
                    if dragStart == nil{stroke(projection.world(value.startLocation),tolerance:Self.hitTolerance(for:projection))}
                    stroke(projection.world(value.location),tolerance:Self.hitTolerance(for:projection))
                }.onEnded{value in
                    if abs(value.translation.width)+abs(value.translation.height)<3{tap(projection.world(value.location),tolerance:Self.hitTolerance(for:projection))}else{move(projection.world(value.startLocation),projection.world(value.location),tolerance:Self.hitTolerance(for:projection))}
                }).onContinuousHover{phase in if case .active(let point)=phase{pointer=snapped(projection.world(point))}}
#endif
                HStack(spacing:0){
                    Button{zoom=max(0.05,zoom/1.5)}label:{Image(systemName:"minus.magnifyingglass").frame(width:44,height:44).contentShape(Rectangle())}.accessibilityLabel(edText("缩小","Zoom out"))
                    Button{fit()}label:{Text(edText("适合画面","Fit")).frame(minWidth:56,minHeight:44).contentShape(Rectangle())}
                    Button{zoom=min(50,zoom*1.5)}label:{Image(systemName:"plus.magnifyingglass").frame(width:44,height:44).contentShape(Rectangle())}.accessibilityLabel(edText("放大","Zoom in"))}
                    .buttonStyle(.plain).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)).padding(8)
            }
            .onAppear{fit();if let request=session.focusRequest,request.context==context{center=request.positionMillimetres}}
            .onChange(of:context){_,_ in fit();resetGesture();if let request=session.focusRequest,request.context==context{center=request.positionMillimetres}}
            .onChange(of:mode){_,newMode in if pendingBusUnfold != nil,case .schematic(.wire)=newMode{return};resetGesture()}.onChange(of:layer){_,_ in anchor=nil}
            .onChange(of:session.fingerDrawingEnabled){_,_ in resetGesture()}
            .onDisappear{resetGesture()}
            .onChange(of:session.focusRequest){_,request in if let request,request.context==context{center=request.positionMillimetres}}
        }
    }
    private var placementDefinitionID:UUID?{if case .board=context{return footprintID};return symbolID}
    private var drawingInstruction:String{
        if let draft=pendingBusUnfold{return draft.member + " · " + (anchor == nil ? edText("点选引出端，再继续连线","Choose the entry tip, then continue the wire"):edText("继续点按连线；取消放弃本次展开","Continue the wire; cancel to discard this unfold"))}
        if isLibraryContext{return edText("直接绘制或拖动；选中后可调整属性","Draw or drag; select to adjust properties")}
        switch tool{
        case .select:return edText("点选对象，拖动移动","Select an object; drag to move")
        case .place:return edText("点按放置，可连续放置","Tap to place; repeat for another")
        case .wire:return anchor == nil ? (isBoard ? edText("从已连接的焊盘或走线开始","Start on a connected pad or track"):edText("点选起点，再点选终点","Choose a start, then an endpoint")):edText("继续点按连线；完成后按取消","Tap to continue; cancel to finish")
        case .zone,.outline:return edText("逐点绘制边界，最后点完成","Draw the boundary point by point, then Finish")
        case .via:return edText("选择网络，在画布上放置过孔","Choose a net, then place a via")
        case .hole:return edText("在画布上点按放置安装孔","Tap the canvas to place a mounting hole")
        case .junction:return edText("在连线上放置连接点","Place a junction on a wire")
        case .label:return edText("输入网络名称，再点按放置","Enter a net name, then tap to place")
        case .erase:return edText("点按要移除的对象","Tap an object to remove it")
        }
    }
    private var isBoard:Bool{if case .board=context{return true};return false}
    private var gestureStatus:some View{
        HStack(spacing:6){
            VStack(alignment:.leading,spacing:2){
                Text(drawingInstruction)
                if !session.fingerDrawingEnabled && (tool != .select || libraryTool.map({$0 != .select}) == true){
                    Text(edText("使用 Pencil／鼠标，或开启左下角手指绘图","Use Pencil or mouse, or enable finger drawing at the lower left"))
                }
            }.font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength:0)
            if !polygon.isEmpty{
                Button{polygon.removeLast()}label:{Image(systemName:"arrow.uturn.backward").frame(minWidth:44,minHeight:44).contentShape(Rectangle())}.accessibilityLabel(edText("撤销上一点","Undo last point"))
                Button(edText("完成","Finish")){finishPolygon()}.disabled(polygon.count<3 || committing).frame(minHeight:44).accessibilityIdentifier("electronics.finishPolygon")
            }
            if tool != .select || libraryTool.map({$0 != .select}) == true{
                Button{resetGesture();onCancel()}label:{Image(systemName:"xmark").frame(width:44,height:44).contentShape(Rectangle())}.accessibilityLabel(edText("取消当前工具","Cancel current tool"))
            }
        }.padding(.horizontal,10).frame(minHeight:36).background(.bar)
    }
    private var selectionActions:some View{
        HStack(spacing:0){
            Button(action:onProperties){Label(edText("属性","Properties"),systemImage:"slider.horizontal.3")}.frame(minHeight:44)
            Spacer(minLength:4)
            Button{editSelection(.rotate)}label:{Image(systemName:"rotate.right").frame(width:44,height:44).contentShape(Rectangle())}.accessibilityLabel(edText("旋转 90°","Rotate 90°"))
                .disabled(!selectionCapabilities.contains(.rotate))
            Button{editSelection(.flip)}label:{Image(systemName:"arrow.left.and.right.righttriangle.left.righttriangle.right").frame(width:44,height:44).contentShape(Rectangle())}.accessibilityLabel(edText("翻转","Flip"))
                .disabled(!selectionCapabilities.contains(.flip))
            Menu{
                if selectedBus != nil{Button(edText("展开成员…","Unfold member…"),systemImage:"arrow.up.right"){choosingBusMember=true}.disabled(onWireToolRequested == nil)}
                Button(edText("复制","Duplicate"),systemImage:"plus.square.on.square"){editSelection(.duplicate)}
                    .disabled(!selectionCapabilities.contains(.duplicate))
                Button(edText("删除","Delete"),systemImage:"trash",role:.destructive){editSelection(.delete)}
                    .disabled(!selectionCapabilities.contains(.delete))
            }label:{Image(systemName:"ellipsis.circle").frame(width:44,height:44).contentShape(Rectangle())}.accessibilityLabel(edText("所选对象操作","Selection actions"))
        }.buttonStyle(.plain).padding(.horizontal,10).background(.bar).disabled(!editingEnabled)
    }
    private var selectionCapabilities:Set<EDCanvasInteraction.Action>{EDCanvasInteraction.availableActions(project:session.project,context:context,objectIDs:session.selection.objectIDs)}
    private func canCommand(_ value:EDCanvasCommand)->Bool{
        if value != .cancel && value != .properties && !editingEnabled{return false}
        switch value{
        case .cancel:return true
        case .properties:return !session.selection.objectIDs.isEmpty
        case .rotate:return tool == .place || selectionCapabilities.contains(.rotate)
        case .flip:return tool == .place || selectionCapabilities.contains(.flip)
        case .duplicate:return selectionCapabilities.contains(.duplicate)
        case .delete:return selectionCapabilities.contains(.delete)
        }
    }
    private func editSelection(_ action:EDCanvasInteraction.Action){
        do{let edits=try EDCanvasInteraction.edits(for:action,project:session.project,context:context,objectIDs:session.selection.objectIDs)
            guard !edits.isEmpty else{return};apply(edits);if action == .delete{session.selection = .none}
        }catch{session.report(error)}
    }
    private func command(_ command:EDCanvasCommand){
        guard canCommand(command) else{return}
        switch command{
        case .cancel:resetGesture();onCancel()
        case .properties:onProperties()
        case .rotate:if tool == .place{placementAngle=(placementAngle+90).truncatingRemainder(dividingBy:360)}else{editSelection(.rotate)}
        case .flip:if tool == .place{placementFlipped.toggle()}else{editSelection(.flip)}
        case .duplicate:editSelection(.duplicate)
        case .delete:editSelection(.delete)
        }
    }
    private func resetGesture(){ownedEdit?.cancel();anchor=nil;dragStart=nil;dragEnd=nil;pointer=nil;polygon=[];movingIDs=[];draftRevision=nil;pendingBusUnfold=nil;choosingBusMember=false;gestureGeneration=UUID()}
    private var selectedBus:EDABus?{
        guard case .schematic(let sheet)=context,session.selection.objectIDs.count==1 else{return nil}
        return session.project.sheets.first(where:{$0.id==sheet})?.buses.first{session.selection.objectIDs.contains($0.id)}
    }
    private func beginBusUnfold(_ member:String){
        guard editingEnabled,case .schematic(let sheet)=context,let bus=selectedBus else{return}
        do{
            let draft=try EDBusUnfoldDraft(project:session.project,sheetID:sheet,busID:bus.id,member:member,at:pointer ?? bus.points.first ?? .zero)
            resetGesture();pendingBusUnfold=draft;draftRevision=draft.source.revision;onWireToolRequested?()
        }catch{session.report(error)}
    }
    private func fit(){bounds=EDAPlot.bounds(session.project,context:context);center=nil;zoom=1}
    private func snapped(_ point:EDAPoint)->EDAPoint{session.snapToGrid ? point.snapped(to:session.gridSizeMillimetres):point}
    private func nearest(_ point:EDAPoint,tolerance:Double)->UUID?{EDCanvasInteraction.hit(project:session.project,context:context,at:point,tolerance:tolerance)}
    private func select(_ point:EDAPoint,tolerance:Double){
        if isLibraryContext{
            var object:UUID?
            if case .symbol(let id)=context,let definition=session.project.symbols.first(where:{$0.id==id}),case .pin(let pin)=EDLibraryEditing.hitSymbol(definition,at:point,tolerance:tolerance){object=pin}
            if case .footprint(let id)=context,let definition=session.project.footprints.first(where:{$0.id==id}),case .pad(let pad)=EDLibraryEditing.hitFootprint(definition,at:point,tolerance:tolerance){object=pad}
            session.selection = .init(context:context,objectIDs:Set(object.map{[$0]} ?? []));return
        }
        session.selection = .init(context:context,objectIDs:Set(nearest(point,tolerance:tolerance).map{[$0]} ?? []))
    }
    private func tap(_ raw:EDAPoint,tolerance:Double){let p=snapped(raw)
        guard editingEnabled else{return}
        defer{if tool != .wire && tool != .zone && tool != .outline{dragStart=nil;dragEnd=nil;movingIDs=[];draftRevision=nil}}
        if isLibraryContext{libraryTap(p,tolerance:tolerance);return}
        switch tool {
        case .select:select(raw,tolerance:tolerance)
        case .erase:if let id=nearest(raw,tolerance:tolerance){session.selection = .init(context:context,objectIDs:[id]);editSelection(.delete)}
        case .place:
            switch context {
            case .schematic(let sheet):guard let definition=session.project.symbols.first(where:{$0.id==symbolID}) else{return}
                let footprint=session.project.footprints.first(where:{$0.name == (definition.referencePrefix=="U" ? "DIP-8":definition.referencePrefix=="Q" ? "SOT-23":definition.referencePrefix=="J" ? "Header 1x02":"0603")})
                let component=EDAComponent(symbolID:definition.id,footprintID:footprint?.id,reference:EDABuiltinLibrary.nextReference(definition.referencePrefix,in:session.project),value:definition.name)
                apply([.putComponent(component),.placeSymbol(sheet:sheet,.init(componentID:component.id,position:p,angle:placementAngle,mirrored:placementFlipped))])
            case .board(let board):guard let definition=session.project.footprints.first(where:{$0.id==footprintID}) else{return};apply([.putFootprint(board:board,.init(definitionID:definition.id,reference:nextFootprintReference(board),position:p,angle:placementAngle,side:placementFlipped ? "B.Cu":"F.Cu"))])
            default:break
            }
        case .wire:
            if case .board(let board) = context {
                do {
                    if let first = anchor {
                        let end=try EDAInteractiveRouting.anchor(session.project,boardID:board,at:raw,layer:layer)?.position ?? p
                        guard !committing else{return};committing=true
                        let generation=gestureGeneration,expected=draftRevision ?? session.revision
                        ownedEdit=Task { defer{committing=false;ownedEdit=nil};do { try Task.checkCancellation();try await session.route(boardID:board,from:first,to:end,layer:layer,width:width,expectedRevision:expected);if generation==gestureGeneration{anchor=end;draftRevision=expected<UInt64.max ? expected+1:expected} } catch { session.report(error) } }
                    } else if let start = try EDAInteractiveRouting.anchor(session.project,boardID:board,at:raw,layer:layer) {
                        anchor = start.position
                        draftRevision=session.revision
                        session.selection = .init(context:context,objectIDs:[start.objectID])
                    } else { session.report(EDAError.invalid("start routing on a connected pad, track or via")) }
                } catch { session.report(error) }
                return
            }
            let endpoint=connectionPoint(raw,tolerance:tolerance)
            guard let first=anchor else{anchor=endpoint;draftRevision=session.revision;return};guard first != endpoint else{return}
            switch context {
            case .schematic(let sheet):
                let generation=gestureGeneration,expected=draftRevision ?? session.revision
                if let draft=pendingBusUnfold{applyBusUnfold(draft,wirePoints:wirePoints(from:first,to:endpoint),endpoint:endpoint)}
                else{apply([.putWire(sheet:sheet,.init(points:wirePoints(from:first,to:endpoint)))],expectedRevision:expected){if generation==gestureGeneration{anchor=endpoint;draftRevision=expected<UInt64.max ? expected+1:expected}}}
            default:break
            }
        case .junction:if case .schematic(let sheet)=context{apply([.putJunction(sheet:sheet,.init(position:p))])}
        case .label:if case .schematic(let sheet)=context{apply([.putLabel(sheet:sheet,.init(name:labelName,position:p))])}
        case .outline,.zone:
            if draftRevision == nil{draftRevision=session.revision};if polygon.last != p{polygon.append(p)}
        case .hole:if case .board(let board)=context{apply([.putHole(board:board,.init(position:p,diameter:holeDiameter,plated:false))])}
        case .via:
            guard case .board(let board)=context,!netID.isEmpty else{session.report(EDAError.invalid(edText("请先选择过孔网络。","Choose a net for the via.")));return}
            apply([.putVia(board:board,.init(netID:netID,position:p,maskLayers:[]))])
        }
    }
    private func stroke(_ raw:EDAPoint,tolerance:Double){
        let point=snapped(raw)
        pointer=point
        guard shapeTool != nil || tool == .select || libraryTool == .select else{return}
        if dragStart == nil{
            dragStart=point;draftRevision=session.revision
            if !isLibraryContext,let id=nearest(raw,tolerance:tolerance){
                movingIDs=session.selection.objectIDs.contains(id) ? session.selection.objectIDs:[id]
                session.selection = .init(context:context,objectIDs:movingIDs)
            }
        };dragEnd=point
    }
    private func move(_ from:EDAPoint,_ to:EDAPoint,tolerance:Double){
        if isLibraryContext{libraryMove(from,to,tolerance:tolerance);return}
        defer{dragStart=nil;dragEnd=nil;movingIDs=[];draftRevision=nil}
        guard tool == .select,let id=nearest(from,tolerance:tolerance) else{return}
        let ids=movingIDs.isEmpty ? (session.selection.objectIDs.contains(id) ? session.selection.objectIDs:[id]):movingIDs
        let delta=snapped(to)-snapped(from);guard delta != .zero else{return}
        do{let edits=try EDCanvasInteraction.move(project:session.project,context:context,objectIDs:ids,by:delta);apply(edits,expectedRevision:draftRevision)}catch{session.report(error)}
    }
    private func nextFootprintReference(_ boardID:UUID)->String{
        let used=Set(session.project.boards.first(where:{$0.id==boardID})?.footprints.map(\.reference) ?? [])
        var i=1;while used.contains("FP"+String(i)){i += 1};return "FP"+String(i)
    }
    private func connectionPoint(_ raw:EDAPoint,tolerance:Double)->EDAPoint{
        guard case .schematic(let id)=context,let sheet=session.project.sheets.first(where:{$0.id==id}) else{return snapped(raw)}
        var points=sheet.wires.flatMap(\.points)+sheet.junctions.map(\.position)
        for placed in sheet.symbols{
            guard let component=session.project.components.first(where:{$0.id==placed.componentID}),let symbol=session.project.symbols.first(where:{$0.id==component.symbolID}) else{continue}
            points += symbol.pins.filter{$0.unit==0 || $0.unit==placed.unit}.map{$0.position.transformed(origin:placed.position,angle:placed.angle,mirrored:placed.mirrored)}
        }
        return points.filter{$0.distance(to:raw)<=tolerance}.min{$0.distance(to:raw)<$1.distance(to:raw)} ?? snapped(raw)
    }
    private func wirePoints(from start:EDAPoint,to end:EDAPoint)->[EDAPoint]{
        let delta=end-start
        let bend:EDAPoint
        if isBoard{let d=min(abs(delta.x),abs(delta.y));bend=start + .init(delta.x<0 ? -d:d,delta.y<0 ? -d:d)}
        else{bend = .init(end.x,start.y)}
        return bend==start || bend==end ? [start,end]:[start,bend,end]
    }
    private func finishPolygon(){
        guard case .board(let id)=context,polygon.count>=3,!committing else{return}
        let points=polygon.last==polygon.first ? Array(polygon.dropLast()):polygon
        guard points.count>=3 else{return};let expected=draftRevision ?? session.revision
        let generation=gestureGeneration,isZone=tool == .zone;committing=true
        ownedEdit=Task{
            defer{committing=false;ownedEdit=nil}
            do{
                guard generation==gestureGeneration else{return}
                try Task.checkCancellation()
                if isZone{try await session.createCopperZone(boardID:id,netID:netID,layer:layer,outline:points,expectedRevision:expected,cancelBeforeCommit:true)}
                else if var board=session.project.boards.first(where:{$0.id==id}){board.outline=points;try await session.apply([.putBoard(board)],expectedRevision:expected,cancelBeforeCommit:true)}
                if generation==gestureGeneration{polygon=[];draftRevision=nil;pointer=nil}
            }catch{session.report(error)}
        }
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
                let pad=EDAPad(number:EDLibraryEditing.nextPadNumber(definition.pads),position:p,layers:["F.Cu","F.Mask","F.Paste"])
                definition.pads.append(pad);apply([.putFootprintDefinition(definition)])
                session.selection = .init(context:context,objectIDs:[pad.id])
            case .erase:
                guard let hit=EDLibraryEditing.hitFootprint(definition,at:p,tolerance:tolerance) else{return}
                switch hit {
                case .pad(let padID):definition.pads.removeAll{$0.id==padID}
                case .graphic(let index):
                    do{try EDAGraphicEditing.remove(at:index,graphics:&definition.graphics,layers:&definition.graphicLayers)}catch{session.report(error);return}
                default:return
                }
                apply([.putFootprintDefinition(definition)]);session.selection = .none
            default:break
            }
        default:break
        }
    }
    private func libraryMove(_ from:EDAPoint,_ to:EDAPoint,tolerance:Double){
        defer{dragStart=nil;dragEnd=nil;draftRevision=nil;movingIDs=[]}
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
                do{try EDAGraphicEditing.append(graphic,graphics:&definition.graphics,layers:&definition.graphicLayers)}catch{session.report(error);return}
                apply([.putFootprintDefinition(definition)])
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
                let moved=EDLibraryEditing.translated(definition.graphics[index],by:delta)
                do{try EDAGraphicEditing.replace(at:index,with:moved,graphics:&definition.graphics,layers:definition.graphicLayers)}catch{session.report(error);return}
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
    private func applyBusUnfold(_ draft:EDBusUnfoldDraft,wirePoints:[EDAPoint],endpoint:EDAPoint){
        guard editingEnabled else{return};let generation=gestureGeneration;committing=true
        ownedEdit=Task{
            defer{committing=false;ownedEdit=nil}
            let worker=Task.detached(priority:.userInitiated){try draft.plan(wirePoints:wirePoints,cancelled:{Task.isCancelled})}
            do{
                let plan=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
                try Task.checkCancellation();try plan.validateSource(session.project)
                try await session.apply(plan.edits,expectedRevision:plan.revision,cancelBeforeCommit:true)
                if generation==gestureGeneration{pendingBusUnfold=nil;anchor=endpoint;draftRevision=plan.revision<UInt64.max ? plan.revision+1:plan.revision}
            }catch{session.report(error)}
        }
    }
    private func apply(_ edits:[EDAEdit],expectedRevision:UInt64?=nil,onSuccess:(()->Void)?=nil){
        guard !edits.isEmpty,editingEnabled else{return};let expected=expectedRevision ?? draftRevision ?? session.revision
        let generation=gestureGeneration;committing=true
        ownedEdit=Task{defer{committing=false;ownedEdit=nil};do{try Task.checkCancellation();try await session.apply(edits,expectedRevision:expected,cancelBeforeCommit:true);if generation==gestureGeneration{onSuccess?()}}catch{session.report(error)}}
    }
}
