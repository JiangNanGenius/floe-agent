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
    init(bounds: CGRect, size: CGSize, center: EDAPoint? = nil, zoom: Double = 1) {
        self.bounds = bounds; self.size = size
        self.center = center ?? .init(bounds.midX, bounds.midY)
        scale = max(0.001, min((size.width-40)/max(bounds.width, 1), (size.height-40)/max(bounds.height, 1))) * zoom
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
                points=board.outline+board.tracks.flatMap(\.points)+board.footprints.map(\.position)
            }
        case .schematic(let id):
            if let sheet=project.sheets.first(where:{$0.id==id}) {
                points=sheet.wires.flatMap(\.points)+sheet.symbols.flatMap { [$0.position + .init(-10,-10),$0.position + .init(10,10)] }+sheet.labels.map(\.position)
            }
        case .symbol(let id): points=project.symbols.first(where:{$0.id==id})?.pins.map(\.position) ?? []
        case .footprint(let id): points=project.footprints.first(where:{$0.id==id})?.pads.map(\.position) ?? []
        case nil: break
        }
        guard let first=points.first else { return CGRect(x:-25,y:-20,width:50,height:40) }
        let x=points.map(\.x), y=points.map(\.y)
        return CGRect(x:(x.min() ?? first.x)-10,y:(y.min() ?? first.y)-10,
                      width:max(30,(x.max() ?? first.x)-(x.min() ?? first.x)+20),height:max(25,(y.max() ?? first.y)-(y.min() ?? first.y)+20))
    }
    static func draw(project: EDAProject, context: EDADocumentContext?, projection p: EDAProjection,
                     selected: Set<UUID> = [], in canvas: inout GraphicsContext) {
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
            case .circle:
                let points=(0...32).map { i in transform(.init(cos(Double(i)*2*Double.pi/32)*w,sin(Double(i)*2*Double.pi/32)*h)) }
                line(points,color,0.12,closed:true,fill:true)
            case .oval:
                let r=min(w,h),a=EDAPoint(w>h ? w-r:0,w>h ? 0:h-r)
                let points=(0...32).map { i -> EDAPoint in let theta=Double(i)*2*Double.pi/32;return transform(.init(cos(theta)*r+(cos(theta)>=0 ? a.x:-a.x),sin(theta)*r+(sin(theta)>=0 ? a.y:-a.y))) }
                line(points,color,0.12,closed:true,fill:true)
            case .rectangle,.roundRectangle:
                // No corner radius exists in the current native model.
                // Show its measured outer extent; do not invent a radius.
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
            line(board.outline,.green,0.3,closed:true,fill:true)
            for cutout in board.cutouts{line(cutout,.gray,closed:true)}
            for zone in board.zones.prefix(10_000){
                if zone.fillRevision==project.revision{for polygon in zone.filledPolygons{line(polygon,.green,closed:true,fill:true)}}
                else{line(zone.outline,.green,0.1,closed:true)}
            }
            for keepout in board.keepouts.prefix(10_000){line(keepout.outline,.purple,0.2,closed:true)}
            for track in board.tracks.prefix(10_000){line(track.points,selected.contains(track.id) ? .cyan:(track.layer=="B.Cu" ? .blue:.red),track.width)}
            for via in board.vias.prefix(10_000){circle(via.position,via.diameter/2,.orange);circle(via.position,via.drill/2,.white)}
            for hole in board.holes.prefix(10_000){circle(hole.position,hole.diameter/2,.white);circle(hole.position,hole.diameter/2,.gray,fill:false)}
            for item in board.footprints.prefix(10_000){if let definition=project.footprints.first(where:{$0.id==item.definitionID}){footprint(item,definition)}}
            graphics(board.graphics)
        case .schematic(let id):
            guard let sheet=project.sheets.first(where:{$0.id==id}) else{return}
            for wire in sheet.wires.prefix(10_000){line(wire.points,selected.contains(wire.id) ? .cyan:.green)}
            for junction in sheet.junctions.prefix(10_000){circle(junction.position,0.4,.green)}
            for item in sheet.symbols.prefix(10_000){
                guard let component=project.components.first(where:{$0.id==item.componentID}),let definition=project.symbols.first(where:{$0.id==component.symbolID}) else{continue}
                func transform(_ q:EDAPoint)->EDAPoint{q.transformed(origin:item.position,angle:item.angle,mirrored:item.mirrored)}
                let color:Color=selected.contains(item.id) ? .blue:.primary
                graphics(definition.graphics,transform:transform,color:color)
                for pin in definition.pins where pin.unit==0 || pin.unit==item.unit{circle(transform(pin.position),0.2,color);label(pin.number,transform(pin.position + .init(0,0.5)),color,0.9)}
                label(component.reference+" "+component.value,item.position + .init(0,4),color)
            }
            for item in sheet.labels.prefix(10_000){label(item.name,item.position,.red)}
            for item in sheet.noConnects.prefix(10_000){line([item.position + .init(-0.6,-0.6),item.position + .init(0.6,0.6)],.blue);line([item.position + .init(-0.6,0.6),item.position + .init(0.6,-0.6)],.blue)}
            for bus in sheet.buses.prefix(10_000){line(bus.points,.blue,0.6);if let point=bus.points.first{label(bus.name,point,.blue)}}
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

#if canImport(UIKit)
/// UIKit reports the input source; no hidden "saw Pencil" mode switching.
struct EDAInputSurface: UIViewRepresentable {
    var fingerDrawing: Bool
    let tap: (CGPoint)->Void
    let move: (CGPoint,CGPoint)->Void
    /// Drag location updates while a drawing gesture is in progress (preview).
    let stroke: ((CGPoint)->Void)?
    let pan: (CGSize)->Void
    let zoom: (CGFloat)->Void
    func makeUIView(context:Context)->InputView{let view=InputView();view.update(self);return view}
    func updateUIView(_ view:InputView,context:Context){view.update(self)}
    final class InputView:UIView,UIGestureRecognizerDelegate {
        var input:EDAInputSurface?
        private var start=CGPoint.zero
        private lazy var editTap=UITapGestureRecognizer(target:self,action:#selector(tapped))
        private lazy var editDrag=UIPanGestureRecognizer(target:self,action:#selector(dragged))
        private lazy var viewPan=UIPanGestureRecognizer(target:self,action:#selector(panned))
        private lazy var pinch=UIPinchGestureRecognizer(target:self,action:#selector(pinched))
        override init(frame:CGRect){super.init(frame:frame);backgroundColor = .clear
            for gesture in [editTap,editDrag,viewPan,pinch]{gesture.delegate=self;addGestureRecognizer(gesture)}
            editTap.require(toFail:editDrag);editDrag.maximumNumberOfTouches=1
            viewPan.allowedTouchTypes=[NSNumber(value:UITouch.TouchType.direct.rawValue)]
        }
        required init?(coder:NSCoder){fatalError("init(coder:) is unavailable")}
        func update(_ value:EDAInputSurface){input=value
            var types=[NSNumber(value:UITouch.TouchType.pencil.rawValue),NSNumber(value:UITouch.TouchType.indirectPointer.rawValue)]
            if value.fingerDrawing{types.append(NSNumber(value:UITouch.TouchType.direct.rawValue))}
            editTap.allowedTouchTypes=types;editDrag.allowedTouchTypes=types
            viewPan.minimumNumberOfTouches=value.fingerDrawing ? 2:1
        }
        @objc private func tapped(_ g:UITapGestureRecognizer){input?.tap(g.location(in:self))}
        @objc private func dragged(_ g:UIPanGestureRecognizer){
            switch g.state {
            case .began:
                start=g.location(in:self);input?.stroke?(start)
            case .changed:
                input?.stroke?(g.location(in:self))
            case .ended,.cancelled,.failed:
                input?.move(start,g.location(in:self))
            default:break
            }
        }
        @objc private func panned(_ g:UIPanGestureRecognizer){let t=g.translation(in:self);if g.state == .changed{input?.pan(.init(width:t.x,height:t.y));g.setTranslation(.zero,in:self)}}
        @objc private func pinched(_ g:UIPinchGestureRecognizer){if g.state == .changed{input?.zoom(g.scale);g.scale=1}}
        func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith otherGestureRecognizer:UIGestureRecognizer)->Bool{gestureRecognizer===pinch || otherGestureRecognizer===pinch}
    }
}
#endif
