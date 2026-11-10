// SPDX-License-Identifier: MPL-2.0
#if canImport(CoreGraphics)
import Foundation
import CoreGraphics
import CoreText
import FloeNativeChartsCore

public enum NativeChartCGRenderer {
    public static func draw(_ scene:NativeChartScene,in context:CGContext) {
        context.saveGState();defer{context.restoreGState()}
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:scene.frame.width,height:scene.frame.height))
        for primitive in scene.layout.primitives {
            if Task.isCancelled{return}
            if primitive.styleToken == "hitOnly"{continue}
            context.saveGState()
            if case .text(let value,let rect)=primitive.shape {drawText(value,frame:rect,token:primitive.styleToken,in:context);context.restoreGState();continue}
            let path=path(for:primitive.shape),color=color(primitive.styleToken),soft=primitive.styleToken.hasSuffix(".soft")
            context.setFillColor(color.copy(alpha:soft ? 0.3:0.9)!);context.setStrokeColor(color)
            context.setLineWidth(lineWidth(primitive.styleToken));context.setLineJoin(.round);context.setLineCap(.round)
            context.addPath(path)
            switch primitive.shape {
            case .polyline:context.strokePath()
            default:
                if primitive.styleToken.hasSuffix(".outline") || primitive.styleToken.hasPrefix("edge") || primitive.styleToken == "axis" || primitive.styleToken == "grid" {context.strokePath()}
                else {context.drawPath(using:.fillStroke)}
            }
            context.restoreGState()
        }
        var x:Double=16,y=scene.frame.height-42
        var drawnCount=0
        let visible=Array(scene.legend.prefix(32))
        for item in visible {
            if x+140>scene.frame.width-12{x=16;y+=18}
            if y>scene.frame.height-20{break}
            drawnCount+=1;context.setFillColor(color(item.styleToken));context.fill(CGRect(x:x,y:y+3,width:10,height:10))
            context.saveGState();drawText(item.label,frame:.init(x:x+15,y:y,width:120,height:17),token:"text",in:context);context.restoreGState();x+=145
        }
        var footnote=scene.notes.last ?? ""
        if scene.legend.count>drawnCount{footnote="Legend: first \(drawnCount) of \(scene.legend.count); full data is in JSON. " + footnote}
        if !footnote.isEmpty{context.saveGState();drawText(String(footnote.prefix(150)),frame:.init(x:16,y:scene.frame.height-17,width:scene.frame.width-32,height:16),token:"caption",in:context);context.restoreGState()}
    }
    public static func path(for shape:ChartShape)->CGPath {
        let path=CGMutablePath()
        func point(_ p:ChartPoint)->CGPoint{.init(x:p.x,y:p.y)}
        switch shape {
        case .point(let p):path.addEllipse(in:.init(x:p.x-2,y:p.y-2,width:4,height:4))
        case .polyline(let values),.polygon(let values):
            if let first=values.first{path.move(to:point(first));for p in values.dropFirst(){path.addLine(to:point(p))}}
            if case .polygon=shape{path.closeSubpath()}
        case .rectangle(let r):path.addRect(.init(x:r.x,y:r.y,width:r.width,height:r.height))
        case .circle(let p,let r):path.addEllipse(in:.init(x:p.x-r,y:p.y-r,width:r*2,height:r*2))
        case .path(let segments):
            for segment in segments {switch segment {case .move(let p):path.move(to:point(p));case .line(let p):path.addLine(to:point(p));case .cubic(let a,let b,let c):path.addCurve(to:point(c),control1:point(a),control2:point(b));case .close:path.closeSubpath()}}
        case .text(_,let r):path.addRect(.init(x:r.x,y:r.y,width:r.width,height:r.height))
        }
        return path
    }
    static func lineWidth(_ token:String)->CGFloat {
        if token.hasPrefix("edge."),let value=Double(token.dropFirst(5)){return CGFloat(min(12,max(0.5,value)))}
        return token == "grid" || token.hasPrefix("grid.") ? 0.6:1.4
    }
    static func color(_ token:String)->CGColor {
        if token == "missing"{return CGColor(gray:0.93,alpha:1)}
        if token.hasPrefix("heat."),let index=Int(token.split(separator:".")[1]){let f=Double(index)/9;return CGColor(red:0.15+0.7*f,green:0.35+0.2*(1-abs(f-0.5)*2),blue:0.85-0.65*f,alpha:1)}
        if token == "positive"{return CGColor(red:0.05,green:0.55,blue:0.3,alpha:1)}
        if token == "negative"{return CGColor(red:0.8,green:0.16,blue:0.2,alpha:1)}
        if token == "grid" || token.hasPrefix("grid."){return CGColor(gray:0.82,alpha:1)}
        if token.hasPrefix("series.") {
            let colors:[[Double]]=[[0.12,0.42,0.82],[0.92,0.4,0.1],[0.12,0.62,0.48],[0.62,0.28,0.8],[0.85,0.22,0.45],[0.05,0.61,0.72],[0.7,0.57,0.08],[0.38,0.4,0.48]]
            let index=Int(token.split(separator:".").dropFirst().first ?? "0") ?? 0,c=colors[abs(index)%colors.count]
            return CGColor(red:c[0],green:c[1],blue:c[2],alpha:1)
        }
        return CGColor(gray:token.hasPrefix("edge") ? 0.38:0.18,alpha:1)
    }
    static func drawText(_ text:String,frame:ChartRect,token:String,in context:CGContext) {
        let size:CGFloat=token == "title" ? 20:(token == "caption" ? 9:11)
        let font=CTFontCreateWithName((token == "title" ? "Helvetica-Bold":"Helvetica") as CFString,size,nil)
        let value=NSAttributedString(string:text,attributes:[.init(kCTFontAttributeName as String):font,.init(kCTForegroundColorAttributeName as String):color("text")])
        let setter=CTFramesetterCreateWithAttributedString(value),path=CGPath(rect:.init(x:0,y:0,width:frame.width,height:frame.height),transform:nil)
        context.translateBy(x:frame.x,y:frame.y+frame.height);context.scaleBy(x:1,y:-1)
        context.clip(to:.init(x:0,y:0,width:frame.width,height:frame.height))
        CTFrameDraw(CTFramesetterCreateFrame(setter,CFRange(location:0,length:0),path,nil),context)
    }
}

public struct NativeChartHitTester: Sendable {
    private let scene:NativeChartScene
    public init(scene:NativeChartScene){self.scene=scene}
    public func readout(at point:ChartPoint)->ChartReadout? {
        let primitives=Dictionary(uniqueKeysWithValues:scene.layout.primitives.map{($0.id,$0)})
        let location=CGPoint(x:point.x,y:point.y)
        for hit in scene.hits.reversed() where hit.bounds.contains(point) {
            guard let primitive=primitives[hit.primitiveID] else{continue}
            if primitive.styleToken == "hitOnly"{return hit.readout}
            let path=NativeChartCGRenderer.path(for:primitive.shape)
            switch primitive.shape {
            case .polyline:
                if path.copy(strokingWithWidth:max(8,NativeChartCGRenderer.lineWidth(primitive.styleToken)),lineCap:.round,lineJoin:.round,miterLimit:2).contains(location){return hit.readout}
            default:
                if primitive.styleToken.hasSuffix(".outline") {
                    if path.copy(strokingWithWidth:8,lineCap:.round,lineJoin:.round,miterLimit:2).contains(location){return hit.readout}
                }else if path.contains(location,using:.evenOdd){return hit.readout}
            }
        }
        return nil
    }
}
#endif
