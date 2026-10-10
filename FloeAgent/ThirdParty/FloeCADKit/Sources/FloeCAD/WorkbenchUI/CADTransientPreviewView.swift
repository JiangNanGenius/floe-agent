//
//  CADTransientPreviewView.swift
//  FloeCADKit
//
//  SwiftUI Canvas render of a TRANSIENT result mesh (`CADTransientMeshPreview`
//  payload): the actual evaluated/changed geometry, drawn with a plain
//  isometric projection and depth-sorted painter fill. Used by the ShapeScript
//  and mesh panels BEFORE apply — the document is not touched to show it.
//
//  SPDX-License-Identifier: MPL-2.0
//

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import simd

struct CADTransientPreviewView: View {
    /// Payload from `CADTransientMeshPreview.payload(_:)`.
    let mesh: [String: Any]

    private var positions: [Double] { mesh["positions"] as? [Double] ?? [] }
    private var indices: [Int] { mesh["indices"] as? [Int] ?? [] }
    private var truncated: Bool { mesh["truncated"] as? Bool ?? false }
    private var triangleCount: Int { mesh["triangleCount"] as? Int ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                let triangles = projectedTriangles()
                guard !triangles.isEmpty else { return }
                var minPoint = CGPoint(x: CGFloat.greatestFiniteMagnitude, y: CGFloat.greatestFiniteMagnitude)
                var maxPoint = CGPoint(x: -CGFloat.greatestFiniteMagnitude, y: -CGFloat.greatestFiniteMagnitude)
                for triangle in triangles {
                    for point in triangle.points {
                        minPoint.x = min(minPoint.x, point.x)
                        minPoint.y = min(minPoint.y, point.y)
                        maxPoint.x = max(maxPoint.x, point.x)
                        maxPoint.y = max(maxPoint.y, point.y)
                    }
                }
                let width = max(maxPoint.x - minPoint.x, 1e-6)
                let height = max(maxPoint.y - minPoint.y, 1e-6)
                let inset: CGFloat = 10
                let scale = min((size.width - inset * 2) / width,
                                (size.height - inset * 2) / height)
                let offsetX = (size.width - width * scale) / 2 - minPoint.x * scale
                let offsetY = (size.height - height * scale) / 2 - minPoint.y * scale

                var sorted = triangles
                sorted.sort { $0.depth < $1.depth } // far first
                let depthRange = max(sorted.last!.depth - sorted.first!.depth, 1e-9)
                for triangle in sorted {
                    var path = Path()
                    let mapped = triangle.points.map {
                        CGPoint(x: $0.x * scale + offsetX, y: $0.y * scale + offsetY)
                    }
                    path.move(to: mapped[0])
                    path.addLine(to: mapped[1])
                    path.addLine(to: mapped[2])
                    path.closeSubpath()
                    let shade = 0.75 - 0.45 * ((triangle.depth - sorted.first!.depth) / depthRange)
                    context.fill(path, with: .color(Color(uiColor: .secondarySystemFill).opacity(shade)))
                    context.stroke(path, with: .color(.secondary.opacity(0.7)),
                                   style: StrokeStyle(lineWidth: 0.5))
                }
            }
            .frame(minHeight: 200, maxHeight: 260)
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            .accessibilityIdentifier("CADTransientPreview")

            HStack(spacing: 8) {
                Text(FloeCADStrings.format("cad.workbench.preview.triangles", "%@ triangles", triangleCount))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if truncated {
                    PanelBadge(text: FloeCADStrings.text("cad.workbench.preview.truncated",
                                                         "preview truncated"),
                               tint: .orange)
                }
                Text(FloeCADStrings.text("cad.workbench.preview.transient",
                                         "Transient preview — not written"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("CADTransientPreviewContainer")
    }

    private struct ProjectedTriangle {
        var points: [CGPoint]
        var depth: Double
    }

    /// Classic isometric projection; depth is the view-space ordering key.
    private func projectedTriangles() -> [ProjectedTriangle] {
        var result: [ProjectedTriangle] = []
        let roots = sqrt3
        var cursor = 0
        while cursor + 2 < indices.count {
            let i0 = indices[cursor]
            let i1 = indices[cursor + 1]
            let i2 = indices[cursor + 2]
            cursor += 3
            guard i0 * 3 + 2 < positions.count,
                  i1 * 3 + 2 < positions.count,
                  i2 * 3 + 2 < positions.count else { continue }
            var points: [CGPoint] = []
            var depth = 0.0
            var valid = true
            for vertex in [i0, i1, i2] {
                let x = positions[vertex * 3]
                let y = positions[vertex * 3 + 1]
                let z = positions[vertex * 3 + 2]
                guard x.isFinite, y.isFinite, z.isFinite else { valid = false; break }
                let u = (x - y) / roots
                let v = (x + y) / 2.449489742783178 - z * 0.816496580927726
                points.append(CGPoint(x: u, y: -v))
                depth += x + y + z
            }
            guard valid, points.count == 3 else { continue }
            result.append(ProjectedTriangle(points: points, depth: depth / 3))
        }
        return result
    }

    private var sqrt3: Double { 1.4142135623730951 }
}
#endif
