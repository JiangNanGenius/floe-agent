import SwiftUI
import CoreGraphics
import CoreText
import FloeChemistryCore
#if os(iOS)
import UIKit
#endif

struct ChemicalViewport {
    var scale: CGFloat = 48
    var origin = CGPoint.zero
    func screen(_ p:ChemicalPoint) -> CGPoint { CGPoint(x:origin.x+CGFloat(p.x)*scale,y:origin.y-CGFloat(p.y)*scale) }
    func model(_ p:CGPoint) -> ChemicalPoint { ChemicalPoint(Double((p.x-origin.x)/scale),Double((origin.y-p.y)/scale)) }
    mutating func fit(_ document:ChemicalDrawing2D,size:CGSize) {
        let points = document.atoms.map(\.point) + document.annotations.flatMap { [$0.point] + ($0.end.map { [$0] } ?? []) }
        guard let first = points.first else { origin = CGPoint(x:size.width/2,y:size.height/2); scale = 48; return }
        let minX = points.map(\.x).min() ?? first.x, maxX = points.map(\.x).max() ?? first.x
        let minY = points.map(\.y).min() ?? first.y, maxY = points.map(\.y).max() ?? first.y
        scale = min(56,max(8,min((size.width-80)/CGFloat(maxX-minX+2),(size.height-80)/CGFloat(maxY-minY+2))))
        origin = CGPoint(x:size.width/2-CGFloat((minX+maxX)/2)*scale,y:size.height/2+CGFloat((minY+maxY)/2)*scale)
    }
}
struct ChemicalCanvasPreview {
    var start:CGPoint?; var end:CGPoint?; var path:[CGPoint] = []
    var moving = false; var hover:CGPoint?
}

@MainActor enum ChemicalCanvasRenderer {
    static func atomColor(_ label:String,dark:Bool,highContrast:Bool = false) -> CGColor {
        let rgb:(Double,Double,Double)
        switch label {
        case "O": rgb = dark ? (1.0,0.38,0.38) : (0.75,0.05,0.07)
        case "N": rgb = dark ? (0.45,0.64,1.0) : (0.05,0.25,0.75)
        case "F","Cl": rgb = dark ? (0.30,0.82,0.40) : (0.02,0.40,0.10)
        case "Br": rgb = dark ? (1.0,0.55,0.43) : (0.52,0.10,0.07)
        case "I": rgb = dark ? (0.82,0.59,1.0) : (0.44,0.12,0.60)
        case "S": rgb = dark ? (1.0,0.84,0.27) : (0.43,0.32,0.0)
        case "P": rgb = dark ? (1.0,0.63,0.24) : (0.65,0.26,0.0)
        default: rgb = dark ? (0.94,0.94,0.94) : (0.08,0.08,0.08)
        }
        func adapted(_ v:Double) -> CGFloat {CGFloat(highContrast ? (dark ? v+(1-v)*0.2 : v*0.8) : v)}
        return CGColor(srgbRed:adapted(rgb.0),green:adapted(rgb.1),blue:adapted(rgb.2),alpha:1)
    }
    static func text(_ value:String,at point:CGPoint,size:CGFloat,color:CGColor,in context:CGContext) {
        let font = CTFontCreateUIFontForLanguage(.system,size,nil)!
        let attributes:[NSAttributedString.Key:Any] = [NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string:value,attributes:attributes))
        let bounds = CTLineGetBoundsWithOptions(line,.useGlyphPathBounds)
        context.saveGState(); context.translateBy(x:point.x-bounds.width/2-bounds.minX,y:point.y+bounds.height/2)
        context.scaleBy(x:1,y:-1); context.textMatrix = .identity; context.textPosition = .zero; CTLineDraw(line,context); context.restoreGState()
    }
    static func draw(_ session:NativeDrawingSession,viewport:ChemicalViewport,preview:ChemicalCanvasPreview,size:CGSize,dark:Bool,highContrast:Bool = false,in context:CGContext) {
        draw(session.document,selection:session.selection,tool:session.tool,rectangleSelection:session.rectangleSelection,
             ringSize:session.ringSize,element:session.element,viewport:viewport,preview:preview,size:size,dark:dark,
             highContrast:highContrast,in:context)
    }
    static func draw(_ document:ChemicalDrawing2D,selection:Set<ChemicalAtomID> = [],tool:ChemicalDrawTool = .select,rectangleSelection:Bool = false,ringSize:Int = 6,element:String = "C",viewport:ChemicalViewport,preview:ChemicalCanvasPreview,size:CGSize,dark:Bool,highContrast:Bool = false,in context:CGContext) {
        let background = CGColor(gray:dark ? 0.07 : 1,alpha:1), ink = CGColor(gray:dark ? 0.94 : 0.08,alpha:1)
        let accent = CGColor(srgbRed:0,green:0.46,blue:0.94,alpha:1)
        context.setFillColor(background); context.fill(CGRect(origin:.zero,size:size))
        let atoms = document.atoms, bonds = document.bonds
        let byID = Dictionary(uniqueKeysWithValues:atoms.map { ($0.id,$0) })
        let offset = preview.moving ? CGPoint(x:(preview.end?.x ?? 0)-(preview.start?.x ?? 0),y:(preview.end?.y ?? 0)-(preview.start?.y ?? 0)) : .zero
        func screen(_ atom:ChemicalDrawAtom) -> CGPoint { let p = viewport.screen(atom.point); return selection.contains(atom.id) ? CGPoint(x:p.x+offset.x,y:p.y+offset.y) : p }
        let degrees = Dictionary(grouping:bonds.flatMap { [$0.a,$0.b] },by:{$0}).mapValues(\.count)
        var neighbors:[ChemicalAtomID:[ChemicalAtomID]] = [:]
        for bond in bonds {neighbors[bond.a,default:[]].append(bond.b);neighbors[bond.b,default:[]].append(bond.a)}
        func ringCenter(_ bond:ChemicalDrawBond) -> CGPoint? {
            var queue = [bond.a],seen:Set<ChemicalAtomID> = [bond.a],parents:[ChemicalAtomID:ChemicalAtomID] = [:],cursor = 0
            while cursor < queue.count && cursor < 512 {
                let current = queue[cursor];cursor += 1
                for next in neighbors[current] ?? [] {
                    if (current == bond.a && next == bond.b) || (current == bond.b && next == bond.a) {continue}
                    if seen.insert(next).inserted {parents[next] = current;queue.append(next)}
                    if next == bond.b {
                        var path = [bond.b],item = bond.b
                        while let parent = parents[item] {path.append(parent);item = parent;if item == bond.a {break}}
                        guard item == bond.a,path.count >= 3 else{return nil}
                        let points = path.compactMap {byID[$0].map(screen)}
                        return CGPoint(x:points.map(\.x).reduce(0,+)/CGFloat(points.count),y:points.map(\.y).reduce(0,+)/CGFloat(points.count))
                    }
                }
            }
            return nil
        }
        let fontSize = min(26,max(16,viewport.scale*0.38)), width = min(2.8,max(1.5,viewport.scale*0.035))
        func labeled(_ atom:ChemicalDrawAtom) -> Bool { atom.label != "C" || degrees[atom.id] == nil || atom.charge != 0 || atom.isotope != 0 }
        context.setLineCap(.round); context.setLineJoin(.round); context.setLineWidth(width)
        for bond in bonds.prefix(20000) {
            guard let a = byID[bond.a],let b = byID[bond.b] else { continue }
            var start = screen(a),end = screen(b)
            let dx = end.x-start.x,dy = end.y-start.y,length = hypot(dx,dy)
            guard length > 0.001 else { continue }
            let ux = dx/length,uy = dy/length,nx = -uy,ny = ux
            let startGap:CGFloat = labeled(a) ? fontSize*0.53 : 0, endGap:CGFloat = labeled(b) ? fontSize*0.53 : 0
            start.x += ux*startGap; start.y += uy*startGap; end.x -= ux*endGap; end.y -= uy*endGap
            context.setStrokeColor(ink); context.setFillColor(ink); context.setLineDash(phase:0,lengths:[])
            if bond.order > 4 {
                context.setLineDash(phase:0,lengths:[4,3]);context.move(to:start);context.addLine(to:end);context.strokePath()
                text("?",at:CGPoint(x:(start.x+end.x)/2,y:(start.y+end.y)/2-9),size:12,color:ink,in:context)
            } else if bond.stereo == 1 {
                context.beginPath(); context.move(to:start);context.addLine(to:CGPoint(x:end.x+nx*5,y:end.y+ny*5));context.addLine(to:CGPoint(x:end.x-nx*5,y:end.y-ny*5));context.closePath();context.fillPath()
            } else if bond.stereo == 6 {
                for i in 1...8 { let fraction = CGFloat(i)/8,half = 5*fraction
                    let p = CGPoint(x:start.x+(end.x-start.x)*fraction,y:start.y+(end.y-start.y)*fraction)
                    context.move(to:CGPoint(x:p.x+nx*half,y:p.y+ny*half));context.addLine(to:CGPoint(x:p.x-nx*half,y:p.y-ny*half));context.strokePath()
                }
            } else if bond.stereo == 4 {
                context.beginPath();context.move(to:start)
                for i in 1...20 {let fraction = CGFloat(i)/20;let offset = sin(fraction * .pi*8)*2.5;context.addLine(to:CGPoint(x:start.x+(end.x-start.x)*fraction+nx*offset,y:start.y+(end.y-start.y)*fraction+ny*offset))};context.strokePath()
            } else {
                let count = min(3,max(1,bond.order == 4 ? 2 : bond.order))
                if count == 2,let center = ringCenter(bond) {
                    let mid = CGPoint(x:(start.x+end.x)/2,y:(start.y+end.y)/2)
                    let side:CGFloat = (center.x-mid.x)*nx+(center.y-mid.y)*ny >= 0 ? 1 : -1
                    context.move(to:start);context.addLine(to:end);context.strokePath()
                    let trim = min(9,length*0.18),inset = side*5
                    if bond.order == 4 {context.setLineDash(phase:0,lengths:[3,3])}
                    context.move(to:CGPoint(x:start.x+ux*trim+nx*inset,y:start.y+uy*trim+ny*inset))
                    context.addLine(to:CGPoint(x:end.x-ux*trim+nx*inset,y:end.y-uy*trim+ny*inset));context.strokePath()
                    continue
                }
                for i in 0..<count {
                    let separation = (CGFloat(i)-CGFloat(count-1)/2)*5
                    if bond.order == 4 && i == 1 {context.setLineDash(phase:0,lengths:[3,3])} else {context.setLineDash(phase:0,lengths:[])}
                    context.move(to:CGPoint(x:start.x+nx*separation,y:start.y+ny*separation));context.addLine(to:CGPoint(x:end.x+nx*separation,y:end.y+ny*separation));context.strokePath()
                }
            }
        }
        context.setLineDash(phase:0,lengths:[])
        for atom in atoms.prefix(10000) {
            let p = screen(atom)
            if selection.contains(atom.id) { context.setFillColor(CGColor(srgbRed:0,green:0.46,blue:0.94,alpha:0.15));context.fillEllipse(in:CGRect(x:p.x-14,y:p.y-14,width:28,height:28));context.setStrokeColor(accent);context.setLineWidth(1.5);context.strokeEllipse(in:CGRect(x:p.x-14,y:p.y-14,width:28,height:28)) }
            if labeled(atom) { text(atom.label,at:p,size:fontSize,color:atomColor(atom.label,dark:dark,highContrast:highContrast),in:context) }
            if atom.charge != 0 { let q = abs(atom.charge) == 1 ? "" : String(abs(atom.charge));text(q+(atom.charge > 0 ? "+" : "−"),at:CGPoint(x:p.x+fontSize*0.7,y:p.y-fontSize*0.55),size:fontSize*0.65,color:ink,in:context) }
            if atom.isotope > 0 { text(String(atom.isotope),at:CGPoint(x:p.x-fontSize*0.65,y:p.y-fontSize*0.55),size:fontSize*0.65,color:ink,in:context) }
        }
        for annotation in document.annotations {
            let p = viewport.screen(annotation.point)
            switch annotation.kind {
            case .arrow:
                guard let e = annotation.end else { continue };let end = viewport.screen(e),angle = atan2(end.y-p.y,end.x-p.x)
                context.setStrokeColor(ink);context.setLineWidth(width);context.move(to:p);context.addLine(to:end)
                for offset in [-0.48,0.48] { context.move(to:end);context.addLine(to:CGPoint(x:end.x-cos(angle+offset)*13,y:end.y-sin(angle+offset)*13)) };context.strokePath()
            case .plus: text("+",at:p,size:fontSize*1.4,color:ink,in:context)
            case .text: text(annotation.text,at:p,size:fontSize*0.8,color:ink,in:context)
            case .other: text("◇",at:p,size:fontSize,color:ink,in:context)
            }
        }
        context.setStrokeColor(accent);context.setLineWidth(2);context.setLineDash(phase:0,lengths:[5,4])
        if let start = preview.start,let end = preview.end,!preview.moving {
            if tool == .select {
                if rectangleSelection {context.stroke(CGRect(x:min(start.x,end.x),y:min(start.y,end.y),width:abs(end.x-start.x),height:abs(end.y-start.y)))}
                else if let first = preview.path.first {context.beginPath();context.move(to:first);context.addLines(between:preview.path);context.addLine(to:end);context.strokePath()}
            } else if [.bond,.arrow].contains(tool) {context.move(to:start);context.addLine(to:end);context.strokePath()}
        }
        if let hover = preview.hover {
            context.setLineDash(phase:0,lengths:[])
            if tool == .ring {
                let n = ringSize,radius = viewport.scale*CGFloat(1.5/(2*sin(.pi/Double(n))))
                context.beginPath()
                for i in 0..<n {let angle = Double(i)*2 * .pi/Double(n) + .pi/6;let p = CGPoint(x:hover.x+cos(angle)*radius,y:hover.y-sin(angle)*radius);if i == 0 {context.move(to:p)}else{context.addLine(to:p)}}
                context.closePath();context.strokePath()
            } else if tool == .atom {text(element,at:hover,size:fontSize,color:accent,in:context)}
            else {context.strokeEllipse(in:CGRect(x:hover.x-12,y:hover.y-12,width:24,height:24))}
        }
    }
}

extension NativeDrawingSession {
    func nearestAtom(to point:ChemicalPoint,radius:Double) -> ChemicalDrawAtom? { document.atoms.filter { $0.point.distance(to:point) <= radius }.min { $0.point.distance(to:point) < $1.point.distance(to:point) } }
    func nearestBond(to point:ChemicalPoint,radius:Double) -> ChemicalDrawBond? {
        let atoms = Dictionary(uniqueKeysWithValues:document.atoms.map {($0.id,$0.point)})
        return document.bonds.first { bond in guard let a = atoms[bond.a],let b = atoms[bond.b] else{return false};return Self.segmentDistance(point,a,b) < radius }
    }
    static func segmentDistance(_ p:ChemicalPoint,_ a:ChemicalPoint,_ b:ChemicalPoint) -> Double {
        let dx = b.x-a.x,dy = b.y-a.y,length = dx*dx+dy*dy
        let t = length > 1e-10 ? max(0,min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/length)) : 0
        return p.distance(to:ChemicalPoint(a.x+dx*t,a.y+dy*t))
    }
    func drawGesture(from start:ChemicalPoint,to end:ChemicalPoint,radius:Double) {
        let startAtom = nearestAtom(to:start,radius:radius), endAtom = nearestAtom(to:end,radius:radius)
        switch tool {
        case .atom: commit { if let atom = endAtom {try $0.updateAtom(atom.id,label:element)} else {_ = try $0.addAtom(element,at:end)} }
        case .ring: commit {try $0.addRing(size:ringSize,aromatic:aromaticRing,center:end)}
        case .chargePlus,.chargeMinus:
            if let atom = endAtom {let delta = tool == .chargePlus ? 1 : -1;commit {try $0.updateAtom(atom.id,charge:atom.charge+delta)}}
        case .erase:
            if let atom = endAtom {commit {try $0.removeAtom(atom.id)}}
            else if let bond = nearestBond(to:end,radius:radius*0.6) {commit {try $0.removeBond(bond)}}
            else if let annotation = document.annotations.first(where: { item in item.point.distance(to:end) < radius || item.end.map { Self.segmentDistance(end,item.point,$0) < radius } == true }) {commit {$0.removeAnnotation(at:annotation.index)}}
        case .arrow: commit {$0.addArrow(from:start,to:start.distance(to:end) < radius ? ChemicalPoint(start.x+3,start.y) : end)}
        case .reactionPlus: commit {$0.addReactionPlus(at:end)}
        case .bond:
            if start.distance(to:end) < radius, let bond = nearestBond(to:start,radius:radius*0.6) {
                commit {try $0.updateBond(bond,order:bondStyle == .single ? bond.order%3+1 : bondStyle.order,stereo:bondStyle.stereo,reverse:bond.stereo == bondStyle.stereo && bondStyle.stereo != 0)};return
            }
            let anchor = startAtom?.point ?? start
            var destination = endAtom?.point ?? end
            if start.distance(to:end) < radius {destination = ChemicalPoint(anchor.x+1.5*cos(.pi/6),anchor.y+1.5*sin(.pi/6))}
            else if endAtom == nil {let angle = (atan2(end.y-anchor.y,end.x-anchor.x)/(.pi/6)).rounded()*(.pi/6);destination = ChemicalPoint(anchor.x+1.5*cos(angle),anchor.y+1.5*sin(angle))}
            commit { drawing in
                let a = try startAtom?.id ?? drawing.addAtom("C",at:anchor)
                let b = try endAtom.flatMap { $0.id == a ? nil : $0.id } ?? drawing.addAtom(element,at:destination,molecule:a.molecule)
                _ = try drawing.addBond(a,b,order:bondStyle.order,stereo:bondStyle.stereo)
            }
        default: break
        }
    }
}

#if os(iOS)
struct NativeChemicalCanvas:UIViewRepresentable {
    let session:NativeDrawingSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    func makeUIView(context:Context) -> ChemicalPencilCanvas { ChemicalPencilCanvas(frame:.zero) }
    func updateUIView(_ view:ChemicalPencilCanvas,context:Context) {view.update(session,dark:colorScheme == .dark,highContrast:contrast == .increased)}
}

@MainActor final class ChemicalPencilCanvas:UIView,UIGestureRecognizerDelegate,UIPencilInteractionDelegate {
    private var session:NativeDrawingSession?
    private var viewport = ChemicalViewport()
    private var preview = ChemicalCanvasPreview()
    private var dark = false
    private var highContrast = false
    private var fitToken:UUID?
    private var lastSize = CGSize.zero
    private var activeTouch:UITouch?
    private var gestureGeneration:UInt64 = 0
    private var isPanning = false
    private var beginViewport = ChemicalViewport()
    private var pencilActive = false
    private var canvasPan:UIPanGestureRecognizer!
    override init(frame:CGRect) {
        super.init(frame:frame);isMultipleTouchEnabled = true;isExclusiveTouch = true;contentMode = .redraw
        accessibilityIdentifier = "chemistry.nativeCanvas"
        // Claim canvas drags so a navigation controller's full-width Back gesture
        // cannot cancel a chemical stroke. Raw touch handling keeps Pencil semantics.
        canvasPan = UIPanGestureRecognizer(target:self,action:#selector(claimCanvasDrag(_:)))
        canvasPan.minimumNumberOfTouches = 1;canvasPan.maximumNumberOfTouches = 1
        canvasPan.allowedTouchTypes = [UITouch.TouchType.direct,.pencil,.indirectPointer].map {NSNumber(value:$0.rawValue)}
        canvasPan.cancelsTouchesInView = false;canvasPan.delegate = self;addGestureRecognizer(canvasPan)
        let pan = UIPanGestureRecognizer(target:self,action:#selector(panCanvas(_:)));pan.minimumNumberOfTouches = 2;pan.allowedTouchTypes = [NSNumber(value:UITouch.TouchType.direct.rawValue)];pan.delegate = self;addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target:self,action:#selector(pinchCanvas(_:)));pinch.allowedTouchTypes = [NSNumber(value:UITouch.TouchType.direct.rawValue)];pinch.delegate = self;addGestureRecognizer(pinch)
        let hover = UIHoverGestureRecognizer(target:self,action:#selector(hoverPencil(_:)));hover.allowedTouchTypes = [NSNumber(value:UITouch.TouchType.pencil.rawValue)];addGestureRecognizer(hover)
        let doubleTap = UITapGestureRecognizer(target:self,action:#selector(editAtom(_:)));doubleTap.numberOfTapsRequired = 2;doubleTap.allowedTouchTypes = [NSNumber(value:UITouch.TouchType.direct.rawValue)];doubleTap.delaysTouchesEnded = true;addGestureRecognizer(doubleTap)
        addInteraction(UIPencilInteraction(delegate:self))
    }
    required init?(coder:NSCoder) {nil}
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil,let navigation = presenter()?.navigationController {
            navigation.interactivePopGestureRecognizer?.require(toFail:canvasPan)
            navigation.interactiveContentPopGestureRecognizer?.require(toFail:canvasPan)
        }
    }
    @objc private func claimCanvasDrag(_ gesture:UIPanGestureRecognizer) {}
    func update(_ value:NativeDrawingSession,dark:Bool,highContrast:Bool) {
        session = value;self.dark = dark;self.highContrast = highContrast
        if fitToken != value.fitToken {fitToken = value.fitToken;viewport.fit(value.document,size:bounds.size)}
        updateAccessibility();setNeedsDisplay()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize,let session {lastSize = bounds.size;viewport.fit(session.document,size:bounds.size);updateAccessibility()}
    }
    override func draw(_ rect:CGRect) {if let session,let context = UIGraphicsGetCurrentContext() {ChemicalCanvasRenderer.draw(session,viewport:viewport,preview:preview,size:bounds.size,dark:dark,highContrast:highContrast,in:context)}}
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent?) {
        guard let session,session.loaded else{return}
        if pencilActive && !touches.contains(where:{$0.type == .pencil}) {return}
        if (event?.allTouches?.filter {$0.type == .direct && $0.phase != .ended}.count ?? 0) > 1 {cancelGesture();return}
        guard activeTouch == nil,let touch = touches.first(where:{$0.type == .pencil}) ?? touches.first, !pencilActive || touch.type == .pencil else{return}
        activeTouch = touch;pencilActive = touch.type == .pencil;gestureGeneration = session.generation;beginViewport = viewport
        let point = touch.location(in:self)
        isPanning = session.tool == .pan || (touch.type == .direct && !session.drawWithFinger)
        preview.start = point;preview.end = point;preview.path = [point];preview.hover = nil
        if session.tool == .select,let atom = session.nearestAtom(to:viewport.model(point),radius:22/Double(viewport.scale)),session.selection.contains(atom.id) {preview.moving = true}
        setNeedsDisplay()
    }
    override func touchesMoved(_ touches:Set<UITouch>,with event:UIEvent?) {
        guard let touch = activeTouch,touches.contains(touch),let start = preview.start else{return}
        let actual = touch.location(in:self)
        if isPanning {viewport.origin = CGPoint(x:beginViewport.origin.x+actual.x-start.x,y:beginViewport.origin.y+actual.y-start.y)}
        else {
            for sample in event?.coalescedTouches(for:touch) ?? [touch] {if preview.path.count < 1024 {preview.path.append(sample.location(in:self))}}
            // Predicted locations are visual only. Ended/cancelled never commits them.
            preview.end = event?.predictedTouches(for:touch)?.last?.location(in:self) ?? actual
        }
        setNeedsDisplay()
    }
    override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent?) {
        guard let touch = activeTouch,touches.contains(touch),let session,let start = preview.start else{return}
        let end = touch.location(in:self),moving = preview.moving,path = preview.path
        defer {cancelGesture();updateAccessibility()}
        guard !isPanning,gestureGeneration == session.generation else{return}
        let a = viewport.model(start),b = viewport.model(end),radius = 22/Double(viewport.scale)
        if session.tool == .text {presentText(at:b);return}
        if session.tool == .select {
            if moving, hypot(end.x-start.x,end.y-start.y) > 4 {
                let selected = session.selection,atoms = session.document.atoms.filter {selected.contains($0.id)}
                session.commit {doc in for atom in atoms {try doc.updateAtom(atom.id,point:ChemicalPoint(atom.point.x+b.x-a.x,atom.point.y+b.y-a.y))}}
            } else if hypot(end.x-start.x,end.y-start.y) < 8 {
                if let atom = session.nearestAtom(to:b,radius:radius) {if session.selection.contains(atom.id){session.selection.remove(atom.id)}else{session.selection.insert(atom.id)}}else{session.selection = []}
            } else {
                let shape = CGMutablePath()
                if session.rectangleSelection {shape.addRect(CGRect(x:min(start.x,end.x),y:min(start.y,end.y),width:abs(end.x-start.x),height:abs(end.y-start.y)))}
                else {shape.addLines(between:path+[end]);shape.closeSubpath()}
                session.selection = Set(session.document.atoms.filter {shape.contains(viewport.screen($0.point))}.map(\.id))
            }
        } else {session.drawGesture(from:a,to:b,radius:radius)}
    }
    override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent?) {if activeTouch.map(touches.contains) == true {cancelGesture()}}
    private func cancelGesture() {activeTouch = nil;pencilActive = false;isPanning = false;preview = ChemicalCanvasPreview();setNeedsDisplay()}
    @objc private func panCanvas(_ gesture:UIPanGestureRecognizer) {
        if gesture.state == .began {cancelGesture();beginViewport = viewport}
        let delta = gesture.translation(in:self);viewport.origin = CGPoint(x:beginViewport.origin.x+delta.x,y:beginViewport.origin.y+delta.y);setNeedsDisplay();updateAccessibility()
    }
    @objc private func pinchCanvas(_ gesture:UIPinchGestureRecognizer) {
        if gesture.state == .began {cancelGesture();beginViewport = viewport}
        let point = gesture.location(in:self),anchor = beginViewport.model(point)
        viewport.scale = min(240,max(8,beginViewport.scale*gesture.scale))
        viewport.origin = CGPoint(x:point.x-CGFloat(anchor.x)*viewport.scale,y:point.y+CGFloat(anchor.y)*viewport.scale);setNeedsDisplay();updateAccessibility()
    }
    @objc private func hoverPencil(_ gesture:UIHoverGestureRecognizer) {
        guard activeTouch == nil else{return}
        guard UIPencilInteraction.prefersHoverToolPreview else {preview.hover = nil;setNeedsDisplay();return}
        preview.hover = [.began,.changed].contains(gesture.state) ? gesture.location(in:self) : nil;setNeedsDisplay()
    }
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith otherGestureRecognizer:UIGestureRecognizer) -> Bool {
        gestureRecognizer.view === self && otherGestureRecognizer.view === self &&
        !(gestureRecognizer is UITapGestureRecognizer) && !(otherGestureRecognizer is UITapGestureRecognizer)
    }
    func pencilInteraction(_ interaction:UIPencilInteraction,didReceiveTap tap:UIPencilInteraction.Tap) {performPencilAction(UIPencilInteraction.preferredTapAction,at:tap.hoverPose?.location)}
    func pencilInteraction(_ interaction:UIPencilInteraction,didReceiveSqueeze squeeze:UIPencilInteraction.Squeeze) {if squeeze.phase == .ended {performPencilAction(UIPencilInteraction.preferredSqueezeAction,at:squeeze.hoverPose?.location)}}
    private func performPencilAction(_ action:UIPencilPreferredAction,at point:CGPoint?) {
        guard let session else{return}
        switch action {
        case .ignore,.runSystemShortcut:break
        case .switchEraser:session.toggleEraser()
        case .switchPrevious:session.togglePrevious()
        case .showColorPalette,.showInkAttributes,.showContextualPalette:presentPalette(at:point ?? CGPoint(x:bounds.midX,y:bounds.midY))
        @unknown default:break
        }
        setNeedsDisplay()
    }
    private func presenter() -> UIViewController? {var next:UIResponder? = self;while let current = next {if let controller = current as? UIViewController{return controller};next = current.next};return nil}
    private func show(_ alert:UIAlertController,at point:CGPoint) {guard let host = presenter(),host.presentedViewController == nil else{return};alert.popoverPresentationController?.sourceView = self;alert.popoverPresentationController?.sourceRect = CGRect(x:point.x,y:point.y,width:1,height:1);host.present(alert,animated:true)}
    private func presentPalette(at point:CGPoint) {
        let palette = UIAlertController(title:chemistryText("Drawing tools", "绘图工具"),message:nil,preferredStyle:.actionSheet)
        for tool in [ChemicalDrawTool.bond,.atom,.select,.erase,.arrow,.text] {palette.addAction(UIAlertAction(title:tool.title,style:.default){[weak self] _ in self?.session?.choose(tool);self?.setNeedsDisplay()})}
        palette.addAction(UIAlertAction(title:chemistryText("Cancel", "取消"),style:.cancel));show(palette,at:point)
    }
    private func presentText(at point:ChemicalPoint) {
        let alert = UIAlertController(title:chemistryText("Add text", "添加文字"),message:nil,preferredStyle:.alert)
        alert.addTextField {$0.placeholder = chemistryText("Text", "文字")}
        alert.addAction(UIAlertAction(title:chemistryText("Add", "添加"),style:.default){[weak self,weak alert] _ in guard let text = alert?.textFields?.first?.text,!text.isEmpty else{return};self?.session?.commit {try $0.addText(text,at:point)}})
        alert.addAction(UIAlertAction(title:chemistryText("Cancel", "取消"),style:.cancel));show(alert,at:viewport.screen(point))
    }
    @objc private func editAtom(_ gesture:UITapGestureRecognizer) {
        cancelGesture();guard let session,let atom = session.nearestAtom(to:viewport.model(gesture.location(in:self)),radius:22/Double(viewport.scale)) else{return}
        let alert = UIAlertController(title:chemistryText("Atom properties", "原子属性"),message:nil,preferredStyle:.alert)
        for (label,text) in [(chemistryText("Element", "元素"),atom.label),(chemistryText("Charge", "电荷"),String(atom.charge)),(chemistryText("Isotope (0 = natural)", "同位素（0 为自然丰度）"),String(atom.isotope))] {alert.addTextField {$0.placeholder = label;$0.text = text;$0.autocapitalizationType = .none}}
        alert.addAction(UIAlertAction(title:chemistryText("Save", "保存"),style:.default){[weak self,weak alert] _ in guard let fields = alert?.textFields,fields.count == 3,let label = fields[0].text,let charge = Int(fields[1].text ?? ""),let isotope = Int(fields[2].text ?? "") else{return};self?.session?.commit {try $0.updateAtom(atom.id,label:label,charge:charge,isotope:isotope)}})
        alert.addAction(UIAlertAction(title:chemistryText("Cancel", "取消"),style:.cancel));show(alert,at:gesture.location(in:self))
    }
    private func updateAccessibility() {
        guard let session else{return}
        let surface = CanvasAccessibilityElement(accessibilityContainer:self)
        surface.accessibilityLabel = chemistryText("Structure canvas", "结构画布");surface.accessibilityIdentifier = "chemistry.nativeCanvas";surface.accessibilityFrameInContainerSpace = bounds
        var items:[Any] = [surface]
        for (index,atom) in session.document.atoms.prefix(1000).enumerated() {
            let element = CanvasAccessibilityElement(accessibilityContainer:self);element.accessibilityLabel = "\(atom.label), " + chemistryText("atom", "原子") + " \(index+1)";element.accessibilityTraits = session.selection.contains(atom.id) ? [.button,.selected] : [.button]
            let p = viewport.screen(atom.point);element.accessibilityFrameInContainerSpace = CGRect(x:p.x-22,y:p.y-22,width:44,height:44)
            element.activate = {[weak session] in if session?.selection.contains(atom.id) == true {session?.selection.remove(atom.id)}else{session?.selection.insert(atom.id)};return true};items.append(element)
        }
        accessibilityElements = items
    }
}
@MainActor private final class CanvasAccessibilityElement:UIAccessibilityElement {
    var activate:(() -> Bool)?
    override func accessibilityActivate() -> Bool {activate?() ?? false}
}
#else
struct NativeChemicalCanvas:View {
    let session:NativeDrawingSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var viewport = ChemicalViewport()
    @State private var size = CGSize.zero
    @State private var preview = ChemicalCanvasPreview()
    @State private var beginViewport = ChemicalViewport()
    @State private var gestureGeneration:UInt64 = 0
    @State private var textPoint = ChemicalPoint(0,0)
    @State private var textDraft = ""
    @State private var showText = false
    var body:some View {
        GeometryReader { geometry in
            Canvas { context,canvasSize in context.withCGContext {cg in ChemicalCanvasRenderer.draw(session,viewport:viewport,preview:preview,size:canvasSize,dark:colorScheme == .dark,highContrast:contrast == .increased,in:cg)} }
                .gesture(DragGesture(minimumDistance:0).onChanged { value in
                    if preview.start == nil {
                        beginViewport = viewport;gestureGeneration = session.generation;preview.start = value.startLocation
                        if session.tool == .select,let atom = session.nearestAtom(to:viewport.model(value.startLocation),radius:20/Double(viewport.scale)),session.selection.contains(atom.id) {preview.moving = true}
                    }
                    preview.end = value.location;preview.path.append(value.location)
                    if session.tool == .pan {viewport.origin = CGPoint(x:beginViewport.origin.x+value.translation.width,y:beginViewport.origin.y+value.translation.height)}
                }.onEnded {value in
                    defer {preview = ChemicalCanvasPreview()}
                    guard session.generation == gestureGeneration,session.tool != .pan else{return}
                    let start = viewport.model(value.startLocation),end = viewport.model(value.location),radius = 20/Double(viewport.scale)
                    if session.tool == .text {textPoint = end;textDraft = "";showText = true}
                    else if session.tool == .select {
                        if preview.moving {
                            let atoms = session.document.atoms.filter {session.selection.contains($0.id)}
                            session.commit {doc in for atom in atoms {try doc.updateAtom(atom.id,point:ChemicalPoint(atom.point.x+end.x-start.x,atom.point.y+end.y-start.y))}}
                        } else if hypot(value.translation.width,value.translation.height) < 6 {
                            if let atom = session.nearestAtom(to:end,radius:radius) {session.selection = [atom.id]}else{session.selection = []}
                        } else {
                            let shape = CGMutablePath()
                            if session.rectangleSelection {shape.addRect(CGRect(x:min(value.startLocation.x,value.location.x),y:min(value.startLocation.y,value.location.y),width:abs(value.translation.width),height:abs(value.translation.height)))}
                            else {shape.addLines(between:[value.startLocation]+preview.path+[value.location]);shape.closeSubpath()}
                            session.selection = Set(session.document.atoms.filter {shape.contains(viewport.screen($0.point))}.map(\.id))
                        }
                    } else {session.drawGesture(from:start,to:end,radius:radius)}
                })
                .simultaneousGesture(MagnifyGesture().onChanged {value in viewport.scale = min(240,max(8,48*value.magnification))})
                .onContinuousHover {phase in switch phase {case .active(let p):preview.hover = p;case .ended:preview.hover = nil}}
                .onAppear {size = geometry.size;viewport.fit(session.document,size:size)}
                .onChange(of:geometry.size) {_,new in size = new;viewport.fit(session.document,size:size)}
                .onChange(of:session.fitToken) {_,_ in viewport.fit(session.document,size:size)}
        }.accessibilityLabel(chemistryText("Structure canvas", "结构画布"))
            .alert(chemistryText("Add text", "添加文字"),isPresented:$showText){
                TextField(chemistryText("Text", "文字"),text:$textDraft)
                Button(chemistryText("Add", "添加")){session.commit {try $0.addText(textDraft,at:textPoint)}}
                Button(chemistryText("Cancel", "取消"),role:.cancel){}
            }
    }
}
#endif
