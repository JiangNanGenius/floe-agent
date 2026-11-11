// SPDX-License-Identifier: MPL-2.0
#if !TOOLBOX_LOCATION_ONLY
import SwiftUI
import UIKit
import FloeToolboxWorkbenches

/// Explicit synthetic input and an observable export callback, component QA only.
struct QualificationPhoto: View {
    let fixture: Bool
    @State private var exportedBytes = 0
    var body: some View {
        ToolboxPhotoMeasureView(importImage: { fixture ? Self.fixturePNG() : nil },
            exportImage: { exportedBytes = $0.count })
        .safeAreaInset(edge: .top) {
            if fixture {
                VStack(spacing: 4) {
                    Text("合成测量样例 · 非相机照片 / Synthetic measurement fixture")
                    if exportedBytes > 0 { Text("PNG exported: \(exportedBytes) bytes").accessibilityIdentifier("qualification.photo.exported") }
                }.font(.caption).padding(6).frame(maxWidth: .infinity).background(.yellow.opacity(0.15))
            }
        }
    }
    private static func fixturePNG() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 800, height: 500), format: format).pngData { context in
            UIColor.systemBackground.setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
            let rectangle = CGRect(x: 120, y: 90, width: 560, height: 320)
            UIColor.systemBlue.withAlphaComponent(0.10).setFill(); context.fill(rectangle)
            UIColor.systemBlue.setStroke(); context.cgContext.setLineWidth(3); context.stroke(rectangle)
            for x in stride(from: 120, through: 680, by: 40) {
                context.cgContext.move(to: CGPoint(x: x, y: 400)); context.cgContext.addLine(to: CGPoint(x: x, y: 410))
            }
            context.cgContext.strokePath()
            ("SYNTHETIC FIXTURE" as NSString).draw(at: CGPoint(x: 260, y: 230), withAttributes: [
                .font: UIFont.systemFont(ofSize: 24, weight: .medium), .foregroundColor: UIColor.secondaryLabel
            ])
        }
    }
}
#endif
