// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeElectronicsCore
#if canImport(UIKit)
import UIKit
#endif

struct EDAProjection {
    let bounds: CGRect
    let size: CGSize
    let center: EDAPoint
    let scale: Double
    init(bounds: CGRect, size: CGSize, center: EDAPoint? = nil, zoom: Double = 1, padding: Double = 20) {
        self.bounds = bounds; self.size = size
        self.center = center ?? .init(bounds.midX, bounds.midY)
        let inset = padding.isFinite ? max(0,padding)*2:40
        scale = max(0.001, min((size.width-inset)/max(bounds.width, 1), (size.height-inset)/max(bounds.height, 1))) * zoom
    }
    func screen(_ p: EDAPoint) -> CGPoint { .init(x:size.width/2+(p.x-center.x)*scale,y:size.height/2-(p.y-center.y)*scale) }
    func world(_ p: CGPoint) -> EDAPoint { .init(center.x+(p.x-size.width/2)/scale,center.y-(p.y-size.height/2)/scale) }
}

enum EDAPlot {
    static func context(_ project: EDAProject, _ supplied: EDADocumentContext?) -> EDADocumentContext? {
        supplied ?? project.sheets.first.map { .schematic(sheetID:$0.id) }
    }
    static func bounds(_ project: EDAProject, context: EDADocumentContext?) -> CGRect {
        var points: [EDAPoint] = []
        switch self.context(project, context) {
        case .board(let id):
            if let board=project.boards.first(where:{$0.id==id}) {
                points=board.outline+board.tracks.flatMap(\.points)+board.footprints.flatMap { instance in
                    [instance.position] + (project.footprints.first(where:{$0.id==instance.definitionID})?.pads.filter{$0.shape == .polygon}.flatMap{EDAPolygonPadGeometry.vertices($0,in:instance) ?? []} ?? [])
                }
            }
        case .schematic(let id):
            if let sheet=project.sheets.first(where:{$0.id==id}) {
                points=sheet.wires.flatMap(\.points)+sheet.symbols.flatMap { [$0.position + .init(-10,-10),$0.position + .init(10,10)] }+sheet.labels.map(\.position)
                points += sheet.buses.flatMap(\.points)
                points += sheet.buses.flatMap { ($0.entries ?? []).flatMap { [$0.busPosition,$0.wirePosition] } }
            }
        case .symbol(let id): points=project.symbols.first(where:{$0.id==id})?.pins.map(\.position) ?? []
        case .footprint(let id): points=project.footprints.first(where:{$0.id==id})?.pads.flatMap { pad in
            pad.shape == .polygon ? (EDAPolygonPadGeometry.vertices(pad) ?? []) : [pad.position]
        } ?? []
        case nil: break
        }
        guard let first=points.first else { return CGRect(x:-25,y:-20,width:50,height:40) }
        let x=points.map(\.x), y=points.map(\.y)
        return CGRect(x:(x.min() ?? first.x)-10,y:(y.min() ?? first.y)-10,
                      width:max(30,(x.max() ?? first.x)-(x.min() ?? first.x)+20),height:max(25,(y.max() ?? first.y)-(y.min() ?? first.y)+20))
    }
    static func draw(project: EDAProject, context: EDADocumentContext?, projection p: EDAProjection,
                     selected: Set<UUID> = [], selectionOffset: EDAPoint = .zero, in canvas: inout GraphicsContext) {
        func offset(_ id:UUID)->EDAPoint{selected.contains(id) ? selectionOffset:.zero}
        func line(_ points:[EDAPoint],_ color:Color,_ width:Double=0.2,closed:Bool=false,fill:Bool=false) {
            guard let first=points.first else{return};var path=Path();path.move(to:p.screen(first))
            for point in points.dropFirst(){path.addLine(to:p.screen(point))};if closed{path.closeSubpath()}
            if fill{canvas.fill(path,with:.color(color.opacity(0.15)))}
            canvas.stroke(path,with:.color(color),style:.init(lineWidth:max(1,width*p.scale),lineCap:.round,lineJoin:.round))
        }
        func circle(_ point:EDAPoint,_ radius:Double,_ color:Color,fill:Bool=true) {
            let q=p.screen(point),r=max(1,radius*p.scale),path=Path(ellipseIn:CGRect(x:q.x-r,y:q.y-r,width:r*2,height:r*2))
            if fill{canvas.fill(path,with:.color(color))}else{canvas.stroke(path,with:.color(color),lineWidth:1)}
        }
        func label(_ text:String,_ point:EDAPoint,_ color:Color = .primary,_ height:Double=1.8,
                   angle:Double=0,mirrored:Bool=false) {
            var rotated=canvas
            let location=p.screen(point)
            rotated.translateBy(x:location.x,y:location.y)
            rotated.rotate(by:.degrees(-angle))
            if mirrored{rotated.scaleBy(x:1,y:-1)}
            rotated.draw(Text(text).font(.system(size:max(9,min(26,height*p.scale)))).foregroundColor(color),at:.zero,anchor:.bottomLeading)
        }
        func graphics(_ values:[EDAGraphic], transform:(EDAPoint)->EDAPoint={ $0 },color:Color = .primary) {
            for value in values.prefix(10_000) {
                switch value {
                case .line(let a,let b,let width):line([transform(a),transform(b)],color,width)
                case .rectangle(let a,let b,let width):line([a,.init(b.x,a.y),b,.init(a.x,b.y)].map(transform),color,width,closed:true)
                case .circle(let center,let radius,let width):
                    let points=(0...64).map { i in transform(center + .init(cos(Double(i)*2*Double.pi/64)*radius,sin(Double(i)*2*Double.pi/64)*radius)) }
                    line(points,color,width,closed:true)
                case .arc(let center,let radius,let start,let sweep,let width):
                    let steps=max(2,min(128,Int(abs(sweep)/4)+1))
                    let points=(0...steps).map { i -> EDAPoint in let r=(start+sweep*Double(i)/Double(steps))*Double.pi/180;return transform(center + .init(cos(r)*radius,sin(r)*radius)) }
                    line(points,color,width)
                case .text(let value,let position,let height,let angle):
                    let origin=transform(.zero),x=transform(.init(cos(angle * .pi/180),sin(angle * .pi/180)))-origin
                    let a=transform(.init(1,0))-origin,b=transform(.init(0,1))-origin
                    label(value,transform(position),color,height,angle:atan2(x.y,x.x)*180 / .pi,mirrored:EDAGeometry.cross(a,b)<0)
                case .dimension(let a,let b,let offset):
                    let v=b-a,normal=EDAPoint(-v.y/max(v.length,0.001),v.x/max(v.length,0.001))*offset
                    line([transform(a),transform(a+normal),transform(b+normal),transform(b)],color)
                    label(String(format:"%.2f mm",a.distance(to:b)),transform((a+b)*0.5+normal),color)
                }
            }
        }
        func renderPad(_ pad:EDAPad,world:(EDAPoint)->EDAPoint,color:Color) {
            let center=world(pad.position),w=pad.size.x/2,h=pad.size.y/2
            func transform(_ q:EDAPoint)->EDAPoint {world(q.transformed(origin:pad.position,angle:pad.angle))}
            switch pad.shape {
            case .polygon:
                if let vertices=pad.polygon{line(vertices.map(transform),color,0.12,closed:true,fill:true)}
            case .circle:
                let points=(0...32).map { i in transform(.init(cos(Double(i)*2*Double.pi/32)*w,sin(Double(i)*2*Double.pi/32)*h)) }
                line(points,color,0.12,closed:true,fill:true)
            case .oval:
                let r=min(w,h),a=EDAPoint(w>h ? w-r:0,w>h ? 0:h-r)
                let points=(0...32).map { i -> EDAPoint in let theta=Double(i)*2*Double.pi/32;return transform(.init(cos(theta)*r+(cos(theta)>=0 ? a.x:-a.x),sin(theta)*r+(sin(theta)>=0 ? a.y:-a.y))) }
                line(points,color,0.12,closed:true,fill:true)
            case .roundRectangle:
                if let points = try? EDARoundedPadGeometry.vertices(pad) { line(points.map(world),color,0.12,closed:true,fill:true) }
                else { line([.init(-w,-h),.init(w,-h),.init(w,h),.init(-w,h)].map(transform),color,0.12,closed:true,fill:true) }
            case .rectangle:
                line([.init(-w,-h),.init(w,-h),.init(w,h),.init(-w,h)].map(transform),color,0.12,closed:true,fill:true)
            }
            if let drill=pad.drill{circle(center,drill/2,.white)}
            label(pad.number,center,color,0.9)
        }
        func footprint(_ instance:EDAFootprint,_ definition:EDAFootprintDefinition) {
            let selected=selected.contains(instance.id),color:Color=selected ? .cyan:.orange
            graphics(definition.graphics,transform:instance.point,color:color)
            for pad in definition.pads.prefix(10_000) {renderPad(pad,world:instance.point,color:color)}
            label(instance.reference,instance.position + .init(0,3),selected ? .blue:.primary)
        }
        switch self.context(project,context) {
        case .board(let id):
            guard let board=project.boards.first(where:{$0.id==id}) else{return}
            line(board.outline,.secondary,0.3,closed:true)
            for cutout in board.cutouts{line(cutout,.gray,closed:true)}
            for zone in board.zones.prefix(10_000){
                let color:Color=selected.contains(zone.id) ? .cyan:(zone.layer=="B.Cu" ? .blue:.red)
                let delta=offset(zone.id)
                if zone.fillRevision==project.revision{
                    var path=Path()
                    for polygon in zone.filledPolygons{
                        guard let first=polygon.first else{continue};path.move(to:p.screen(first+delta))
                        for q in polygon.dropFirst(){path.addLine(to:p.screen(q+delta))};path.closeSubpath()
                    }
                    canvas.fill(path,with:.color(color.opacity(0.16)),style:FillStyle(eoFill:true))
                }
                line(zone.outline.map{$0+delta},color,selected.contains(zone.id) ? 0.35:0.1,closed:true)
            }
            for keepout in board.keepouts.prefix(10_000){line(keepout.outline,.purple,0.2,closed:true)}
            for track in board.tracks.prefix(10_000){line(track.points.map{$0+(track.locked ? .zero:offset(track.id))},selected.contains(track.id) ? .cyan:(track.layer=="B.Cu" ? .blue:.red),track.width)}
            for via in board.vias.prefix(10_000){let position=via.position+offset(via.id);circle(position,via.diameter/2,selected.contains(via.id) ? .cyan:.orange);circle(position,via.drill/2,.white)}
            for hole in board.holes.prefix(10_000){
                let delta=offset(hole.id),color:Color=selected.contains(hole.id) ? .cyan:.gray
                if let end=hole.endPosition {line([hole.position+delta,end+delta],color,hole.diameter+0.1);line([hole.position+delta,end+delta],.white,hole.diameter)}
                else{circle(hole.position+delta,hole.diameter/2,.white);circle(hole.position+delta,hole.diameter/2,color,fill:false)}
            }
            for original in board.footprints.prefix(10_000){var item=original;if !item.locked{item.position=item.position+offset(item.id)};if let definition=project.footprints.first(where:{$0.id==item.definitionID}){footprint(item,definition)}}
            graphics(board.graphics)
        case .schematic(let id):
            guard let sheet=project.sheets.first(where:{$0.id==id}) else{return}
            for wire in sheet.wires.prefix(10_000){line(wire.points.map{$0+offset(wire.id)},selected.contains(wire.id) ? .cyan:.green)}
            for junction in sheet.junctions.prefix(10_000){circle(junction.position+offset(junction.id),0.4,selected.contains(junction.id) ? .cyan:.green)}
            for original in sheet.symbols.prefix(10_000){
                var item=original;item.position=item.position+offset(item.id)
                guard let component=project.components.first(where:{$0.id==item.componentID}),let definition=project.symbols.first(where:{$0.id==component.symbolID}) else{continue}
                func transform(_ q:EDAPoint)->EDAPoint{q.transformed(origin:item.position,angle:item.angle,mirrored:item.mirrored)}
                let color:Color=selected.contains(item.id) ? .blue:.primary
                graphics(definition.graphics(forUnit: item.unit),transform:transform,color:color)
                for pin in definition.pins where pin.unit==0 || pin.unit==item.unit{circle(transform(pin.position),0.2,color);label(pin.number,transform(pin.position + .init(0,0.5)),color,0.9)}
                label(component.reference+" "+component.value,item.position + .init(0,4),color)
            }
            for item in sheet.labels.prefix(10_000){label(item.name,item.position+offset(item.id),selected.contains(item.id) ? .cyan:.red)}
            for item in sheet.noConnects.prefix(10_000){line([item.position + .init(-0.6,-0.6),item.position + .init(0.6,0.6)],.blue);line([item.position + .init(-0.6,0.6),item.position + .init(0.6,-0.6)],.blue)}
            for bus in sheet.buses.prefix(10_000){
                let busOffset=offset(bus.id)
                line(bus.points.map{$0+busOffset},selected.contains(bus.id) ? .cyan:.blue,0.6)
                if let point=bus.points.first{label(bus.name,point+busOffset,.blue)}
                for entry in (bus.entries ?? []).prefix(20_000){
                    let translation=busOffset != .zero ? busOffset:offset(entry.id)
                    line([entry.busPosition+translation,entry.wirePosition+translation],selected.contains(entry.id) ? .cyan:.blue,0.25)
                }
            }
            graphics(sheet.graphics)
        case .symbol(let id):
            if let symbol=project.symbols.first(where:{$0.id==id}){
                graphics(symbol.graphics)
                for pin in symbol.pins{
                    let color:Color=selected.contains(pin.id) ? .cyan:.primary
                    circle(pin.position,0.2,color);label(pin.number+" "+pin.name,pin.position,color)
                }
            }
        case .footprint(let id):
            if let definition=project.footprints.first(where:{$0.id==id}){
                graphics(definition.graphics)
                for pad in definition.pads.prefix(10_000){renderPad(pad,world:{$0},color:selected.contains(pad.id) ? .cyan:.orange)}
            }
        case nil:break
        }
    }
    /// Dashed accent rendering of the shape currently being drawn; committed
    /// separately through the session when the gesture ends.
    static func drawPreview(_ graphic: EDAGraphic, projection p: EDAProjection, in canvas: inout GraphicsContext) {
        let color = Color.accentColor
        let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [6, 4])
        func path(_ points: [EDAPoint], closed: Bool = false) -> Path {
            guard let first = points.first else { return Path() }
            var path = Path(); path.move(to: p.screen(first))
            for point in points.dropFirst() { path.addLine(to: p.screen(point)) }
            if closed { path.closeSubpath() }
            return path
        }
        switch graphic {
        case .line(let a, let b, _):
            canvas.stroke(path([a, b]), with: .color(color), style: style)
        case .rectangle(let a, let b, _):
            canvas.stroke(path([a, .init(b.x, a.y), b, .init(a.x, b.y)], closed: true), with: .color(color), style: style)
        case .circle(let center, let radius, _):
            let q = p.screen(center), r = max(1, radius * p.scale)
            canvas.stroke(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2)), with: .color(color), style: style)
        case .arc(let center, let radius, let start, let sweep, _):
            let steps = max(2, min(128, Int(abs(sweep) / 4) + 1))
            let points = (0...steps).map { i -> EDAPoint in
                let r = (start + sweep * Double(i) / Double(steps)) * Double.pi / 180
                return center + .init(cos(r) * radius, sin(r) * radius)
            }
            canvas.stroke(path(points), with: .color(color), style: style)
        case .text(let value, let position, let height, _):
            canvas.draw(Text(value).font(.system(size: max(9, min(26, height * p.scale)))).foregroundColor(color),
                        at: p.screen(position), anchor: .bottomLeading)
        case .dimension(let a, let b, _):
            canvas.stroke(path([a, b]), with: .color(color), style: style)
        }
    }
}

extension EDAPlot {
    static func drawGrid(projection p:EDAProjection,spacing:Double,in canvas:inout GraphicsContext){
        guard spacing.isFinite,spacing>0,p.scale.isFinite else{return}
        var step=spacing
        while step*p.scale<16{step *= 2}
        let a=p.world(.zero),b=p.world(.init(x:p.size.width,y:p.size.height))
        let x0=floor(min(a.x,b.x)/step)*step,y0=floor(min(a.y,b.y)/step)*step
        let columns=min(200,Int(ceil(abs(b.x-a.x)/step))+2),rows=min(200,Int(ceil(abs(b.y-a.y)/step))+2)
        var path=Path()
        for x in 0..<columns{for y in 0..<rows{
            let q=p.screen(.init(x0+Double(x)*step,y0+Double(y)*step))
            path.addEllipse(in:.init(x:q.x-0.6,y:q.y-0.6,width:1.2,height:1.2))
        }}
        canvas.fill(path,with:.color(.secondary.opacity(0.35)))
    }
    static func drawPolylinePreview(_ points:[EDAPoint],projection p:EDAProjection,in canvas:inout GraphicsContext){
        guard let first=points.first else{return};var path=Path();path.move(to:p.screen(first))
        for point in points.dropFirst(){path.addLine(to:p.screen(point))}
        canvas.stroke(path,with:.color(.accentColor),style:.init(lineWidth:1.5,dash:[6,4]))
        for point in points.dropLast(){let q=p.screen(point);canvas.fill(Path(ellipseIn:.init(x:q.x-3,y:q.y-3,width:6,height:6)),with:.color(.accentColor))}
    }
    static func drawPlacement(project:EDAProject,context:EDADocumentContext,definitionID:UUID?,position:EDAPoint,
                              angle:Double,flipped:Bool,projection:EDAProjection,unit:Int=1,in canvas:inout GraphicsContext){
        guard let definitionID else{return}
        var preview=project;preview.components=[];preview.sheets=[];preview.boards=[]
        var selected:Set<UUID>=[]
        switch context{
        case .board(let id):
            guard project.footprints.contains(where:{$0.id==definitionID}) else{return}
            var board=EDABoard(id:id,outline:[])
            let placed=EDAFootprint(definitionID:definitionID,position:position,angle:angle,side:flipped ? "B.Cu":"F.Cu")
            board.footprints=[placed];preview.boards=[board];selected=[placed.id]
        case .schematic(let id):
            guard project.symbols.contains(where:{$0.id==definitionID}) else{return}
            let component=EDAComponent(symbolID:definitionID)
            let placed=EDASymbolPlacement(componentID:component.id,unit:unit,position:position,angle:angle,mirrored:flipped)
            preview.components=[component];preview.sheets=[EDASheet(id:id,symbols:[placed])];selected=[placed.id]
        default:return
        }
        var ghost=canvas;ghost.opacity=0.55
        draw(project:preview,context:context,projection:projection,selected:selected,in:&ghost)
    }
}

/// Saved snapshot only: no editor session, storage write, calculation or audio.
public struct EDAPreviewView: View {
    let project: EDAProject
    let context: EDADocumentContext?
    public init(project: EDAProject, context: EDADocumentContext? = nil) {self.project=project;self.context=context}
    public var body: some View {
        Canvas { canvas,size in
            let projection=EDAProjection(bounds:EDAPlot.bounds(project,context:context),size:size)
            EDAPlot.draw(project:project,context:context,projection:projection,in:&canvas)
        }.background(.background)
    }
}

enum EDCanvasCommand:String {
    case cancel,properties,rotate,flip,duplicate,delete
}

struct EDCanvasInputIdentity:Equatable{
    let context:EDADocumentContext
    let mode:EDCanvasMode
    let generation:UUID
    let center:EDAPoint
    let scale:Double
    let size:CGSize
}

#if canImport(UIKit)
/// UIKit reports the input source; no hidden "saw Pencil" mode switching.
struct EDAInputSurface: UIViewRepresentable {
    var fingerDrawing: Bool
    let identity:EDCanvasInputIdentity
    let editingEnabled:Bool
    let tap: (CGPoint)->Void
    let move: (CGPoint,CGPoint)->Void
    /// Drag location updates while a drawing gesture is in progress (preview).
    let stroke: ((CGPoint)->Void)?
    let hover: (CGPoint)->Void
    let select: (CGPoint)->Void
    let cancel: ()->Void
    let command: (EDCanvasCommand)->Void
    let canCommand:(EDCanvasCommand)->Bool
    let pan: (CGSize)->Void
    let zoom: (CGFloat)->Void
    func makeUIView(context:Context)->InputView{let view=InputView();view.update(self);return view}
    func updateUIView(_ view:InputView,context:Context){view.update(self)}
    final class InputView:UIView,UIGestureRecognizerDelegate,UIContextMenuInteractionDelegate {
        var input:EDAInputSurface?
        private var activeInput:EDAInputSurface?
        private var start=CGPoint.zero
        private lazy var editTap=UITapGestureRecognizer(target:self,action:#selector(tapped))
        private lazy var editDrag=UIPanGestureRecognizer(target:self,action:#selector(dragged))
        private lazy var viewPan=UIPanGestureRecognizer(target:self,action:#selector(panned))
        private lazy var selectionTap=UITapGestureRecognizer(target:self,action:#selector(selected))
        private lazy var pointerHover=UIHoverGestureRecognizer(target:self,action:#selector(hovered))
        private lazy var pinch=UIPinchGestureRecognizer(target:self,action:#selector(pinched))
        override init(frame:CGRect){super.init(frame:frame);backgroundColor = .clear
            isAccessibilityElement = true
            accessibilityLabel = edText("设计画布", "Design canvas")
            accessibilityIdentifier = "electronics.canvas.input"
            for gesture in [editTap,editDrag,viewPan,pinch,selectionTap,pointerHover]{gesture.delegate=self;addGestureRecognizer(gesture)}
            editTap.require(toFail:editDrag);editDrag.maximumNumberOfTouches=1
            selectionTap.allowedTouchTypes=[NSNumber(value:UITouch.TouchType.direct.rawValue)]
            selectionTap.require(toFail:viewPan)
            viewPan.allowedTouchTypes=[NSNumber(value:UITouch.TouchType.direct.rawValue)]
            addInteraction(UIContextMenuInteraction(delegate:self))
        }
        required init?(coder:NSCoder){fatalError("init(coder:) is unavailable")}
        func update(_ value:EDAInputSurface){
            if let activeInput,activeInput.identity != value.identity || activeInput.fingerDrawing != value.fingerDrawing || !value.editingEnabled{
                self.activeInput=nil
                editDrag.isEnabled=false;editDrag.isEnabled=true
                activeInput.cancel()
            }
            input=value
            let types=Self.editingTouchTypes(fingerDrawing:value.fingerDrawing)
            editTap.allowedTouchTypes=types;editDrag.allowedTouchTypes=types
            viewPan.minimumNumberOfTouches=value.fingerDrawing ? 2:1
            selectionTap.isEnabled = !value.fingerDrawing
        }
        static func editingTouchTypes(fingerDrawing:Bool)->[NSNumber]{
            var types=[NSNumber(value:UITouch.TouchType.pencil.rawValue),NSNumber(value:UITouch.TouchType.indirectPointer.rawValue)]
            if fingerDrawing{types.append(NSNumber(value:UITouch.TouchType.direct.rawValue))};return types
        }
        override var canBecomeFirstResponder:Bool{true}
        @objc private func tapped(_ g:UITapGestureRecognizer){becomeFirstResponder();guard input?.editingEnabled==true else{return};input?.tap(g.location(in:self))}
        @objc private func selected(_ g:UITapGestureRecognizer){becomeFirstResponder();input?.select(g.location(in:self))}
        @objc private func hovered(_ g:UIHoverGestureRecognizer){if g.state == .began || g.state == .changed{input?.hover(g.location(in:self))}}
        @objc private func dragged(_ g:UIPanGestureRecognizer){
            switch g.state {
            case .began:
                guard input?.editingEnabled==true else{return}
                becomeFirstResponder()
                let point=g.location(in:self),delta=g.translation(in:self)
                start=CGPoint(x:point.x-delta.x,y:point.y-delta.y);beginEditGesture(at:start);activeInput?.stroke?(point)
            case .changed:
                activeInput?.stroke?(g.location(in:self))
            case .ended:
                finishEditGesture(state:g.state,from:start,to:g.location(in:self))
            case .cancelled,.failed:finishEditGesture(state:g.state,from:start,to:g.location(in:self))
            default:break
            }
        }
        func beginEditGesture(at point:CGPoint){
            guard let input,input.editingEnabled else{return};activeInput=input;start=point;activeInput?.stroke?(point)
        }
        func finishEditGesture(state:UIGestureRecognizer.State,from:CGPoint,to:CGPoint){
            guard let active=activeInput else{return}
            switch state{
            case .ended:
                activeInput=nil
                guard let input,active.identity==input.identity,active.fingerDrawing==input.fingerDrawing,input.editingEnabled else{active.cancel();return}
                active.move(from,to)
            case .cancelled,.failed:activeInput=nil;active.cancel()
            default:break
            }
        }
        @objc private func panned(_ g:UIPanGestureRecognizer){let t=g.translation(in:self);if g.state == .changed{input?.pan(.init(width:t.x,height:t.y));g.setTranslation(.zero,in:self)}}
        @objc private func pinched(_ g:UIPinchGestureRecognizer){if g.state == .changed{input?.zoom(g.scale);g.scale=1}}
        override var keyCommands:[UIKeyCommand]?{[
            UIKeyCommand(input:UIKeyCommand.inputEscape,modifierFlags:[],action:#selector(key)),
            UIKeyCommand(input:"r",modifierFlags:[],action:#selector(key)),
            UIKeyCommand(input:"f",modifierFlags:[],action:#selector(key)),
            UIKeyCommand(input:"e",modifierFlags:[],action:#selector(key)),
            UIKeyCommand(input:"d",modifierFlags:.command,action:#selector(key)),
            UIKeyCommand(input:"\u{8}",modifierFlags:[],action:#selector(key))
        ]}
        @objc private func key(_ key:UIKeyCommand){
            switch key.input{
            case UIKeyCommand.inputEscape:input?.command(.cancel)
            case "r":input?.command(.rotate)
            case "f":input?.command(.flip)
            case "e":input?.command(.properties)
            case "d":input?.command(.duplicate)
            case "\u{8}":input?.command(.delete)
            default:break
            }
        }
        func contextMenuInteraction(_ interaction:UIContextMenuInteraction,configurationForMenuAtLocation location:CGPoint)->UIContextMenuConfiguration?{
            input?.select(location);becomeFirstResponder()
            return UIContextMenuConfiguration(identifier:nil,previewProvider:nil){[weak self] _ in
                UIMenu(children:[
                    self?.menuAction(.properties,title:edText("属性","Properties"),image:"slider.horizontal.3"),
                    self?.menuAction(.rotate,title:edText("旋转 90°","Rotate 90°"),image:"rotate.right"),
                    self?.menuAction(.flip,title:edText("翻转","Flip"),image:"arrow.left.and.right"),
                    self?.menuAction(.duplicate,title:edText("复制","Duplicate"),image:"plus.square.on.square"),
                    self?.menuAction(.delete,title:edText("删除","Delete"),image:"trash")
                ].compactMap{$0})
            }
        }
        private func menuAction(_ value:EDCanvasCommand,title:String,image:String)->UIAction{
            var attributes:UIMenuElement.Attributes=value == .delete ? .destructive:[]
            if input?.canCommand(value) != true{attributes.insert(.disabled)}
            return UIAction(title:title,image:UIImage(systemName:image),attributes:attributes){[weak self] _ in self?.input?.command(value)}
        }
        func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith otherGestureRecognizer:UIGestureRecognizer)->Bool{
            (gestureRecognizer===pinch && otherGestureRecognizer===viewPan) || (gestureRecognizer===viewPan && otherGestureRecognizer===pinch)
        }
    }
}
#endif
