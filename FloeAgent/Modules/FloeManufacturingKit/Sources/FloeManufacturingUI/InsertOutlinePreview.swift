// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeManufacturingCore

struct InsertOutlinePreview:View {
    let receipt:TurningSetup.Receipt
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Canvas { context,size in
                let points = receipt.toolProfile
                guard points.count >= 3 else { return }
                let xs = points.map { $0[0] }, zs = points.map { $0[1] }
                let xMin = xs.min()!, xMax = xs.max()!, zMin = zs.min()!, zMax = zs.max()!
                let scale = min((size.width-32)/max(zMax-zMin,1e-6),(size.height-32)/max(xMax-xMin,1e-6))
                func position(_ p:[Double]) -> CGPoint {
                    CGPoint(x:(size.width-(zMax-zMin)*scale)/2+(p[1]-zMin)*scale,
                            y:(size.height+(xMax-xMin)*scale)/2-(p[0]-xMin)*scale)
                }
                var outline = Path(); outline.move(to:position(points[0]))
                for p in points.dropFirst() { outline.addLine(to:position(p)) }; outline.closeSubpath()
                context.fill(outline,with:.color(.teal.opacity(0.12)))
                context.stroke(outline,with:.color(.teal),lineWidth:2)
                let tip = position([0,0])
                context.fill(Path(ellipseIn:CGRect(x:tip.x-3,y:tip.y-3,width:6,height:6)),with:.color(.primary))
            }.frame(height:130).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
            Text(String(format:L("%@ 形 · 边长 %.3f mm · 旋转 %.1f°","%@ insert · edge %.3f mm · rotation %.1f°"),receipt.applied.insertShape,receipt.applied.insertEdgeLengthMM,receipt.applied.insertRotationDegrees)).font(.caption)
            Text(L("来自实际计算回执；X 为径向、Z 为轴向，黑点为刀尖。","From the actual calculation receipt. X is radial, Z axial; the black point marks the tip.")).font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children:.combine).accessibilityIdentifier("turning.insertOutline")
    }
}
#endif
