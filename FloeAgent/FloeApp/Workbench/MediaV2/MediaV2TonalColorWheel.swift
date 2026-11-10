// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkbench

struct MediaV2TonalColorWheel: View {
    @Binding var value: ImageRGBBalance
    private var point: CGPoint {
        CGPoint(x: (2*value.red-value.green-value.blue)/3,y: (value.green-value.blue)/sqrt(3))
    }
    private var hue: Double { var h = atan2(Double(point.y),Double(point.x))*180 / .pi;if h<0 { h += 360 };return h }
    private var strength: Double { min(1,hypot(Double(point.x),Double(point.y))) }
    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                let size = min(geometry.size.width,geometry.size.height),radius = size/2-10,center = CGPoint(x:geometry.size.width/2,y:geometry.size.height/2)
                Canvas { context,_ in
                    for index in 0..<120 {
                        let a = Double(index)*2 * .pi/120,b = Double(index+1)*2 * .pi/120
                        var sector = Path();sector.move(to: center)
                        sector.addArc(center: center,radius: radius,startAngle:.radians(-b),endAngle:.radians(-a),clockwise: false);sector.closeSubpath()
                        context.fill(sector,with: .radialGradient(.init(colors:[.white,Color(hue: Double(index)/120,saturation:1,brightness:1)]),center:center,startRadius:0,endRadius:radius))
                    }
                    var crosshair = Path();crosshair.move(to:.init(x:center.x-8,y:center.y));crosshair.addLine(to:.init(x:center.x+8,y:center.y));crosshair.move(to:.init(x:center.x,y:center.y-8));crosshair.addLine(to:.init(x:center.x,y:center.y+8));context.stroke(crosshair,with:.color(.black.opacity(0.35)),lineWidth:1)
                    let length = max(1,hypot(point.x,point.y)),knob = CGPoint(x:center.x+point.x/length*radius,y:center.y-point.y/length*radius)
                    let ring = Path(ellipseIn:.init(x:knob.x-7,y:knob.y-7,width:14,height:14))
                    context.stroke(ring,with:.color(.black),lineWidth:4);context.stroke(ring,with:.color(.white),lineWidth:2)
                }.contentShape(Circle()).gesture(DragGesture(minimumDistance:0).onChanged { drag in
                    let dx = Double((drag.location.x-center.x)/radius),dy = Double((center.y-drag.location.y)/radius),length = max(1,hypot(dx,dy))
                    set(x: dx/length,y: dy/length)
                })
            }.frame(height:180)
            MusicValueSlider(title:WorkbenchText.t("色相", "Hue"),value:hue,range:0...360,suffix:"°") { set(hue: $0,strength:strength) }
            MusicValueSlider(title:WorkbenchText.t("强度", "Strength"),value:strength,range:0...1) { set(hue:hue,strength:$0) }
        }.accessibilityElement(children: .contain)
    }
    private func set(hue: Double,strength: Double) { let angle = hue * .pi/180;set(x: cos(angle)*strength,y: sin(angle)*strength) }
    private func set(x: Double,y: Double) {
        value = .init(red:x,green:-x/2+sqrt(3)*y/2,blue:-x/2-sqrt(3)*y/2)
    }
}
#endif
