// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import UIKit
import SwiftUI
import Charts
import FloeChemistryCore

public struct ChemistryNoteImage: Sendable {
    public let png: Data
    public let width: Int
    public let height: Int
    public let kind: String
}

/// Explicit image export over chemistry data. No screen capture, editor
/// selection/undo state, calculation job, model or remote provider is used.
@MainActor public enum ChemistryNoteImageExporter {
    public static func structurePNG(ket: String) throws -> ChemistryNoteImage {
        try Task.checkCancellation()
        let document = try ChemicalDrawing2D(ket)
        let atoms = document.atoms, bonds = document.bonds, annotations = document.annotations
        guard !atoms.isEmpty || !annotations.isEmpty, atoms.count <= 10_000, bonds.count <= 20_000,
              annotations.count <= 1_000, atoms.allSatisfy({ $0.label.utf8.count <= 128 }),
              annotations.allSatisfy({ item in
                  switch item.kind {
                  case .other: false
                  case .arrow: item.end != nil
                  case .text: !item.text.isEmpty && item.text.utf8.count <= 4_096 && !item.text.contains(where: \.isNewline)
                  case .plus: true
                  }
              }), document.nodes.allSatisfy({ node in
                  guard let key = node["$ref"]?.string else { return true }
                  return document.value[key]?["type"]?.string == "molecule"
              }) else { throw ChemistryError.unavailable(chemistryText("This drawing cannot be exported completely as an image.", "这个结构暂不能完整导出为图片。")) }
        let size = CGSize(width: 1_200, height: 900)
        var viewport = ChemicalViewport(); viewport.fit(document, size: size)
        let points = atoms.map(\.point) + annotations.flatMap { [$0.point] + ($0.end.map { [$0] } ?? []) }
        // The interactive fit has a minimum readable zoom. Refuse oversized
        // drawings instead of silently exporting a cropped subset.
        guard points.allSatisfy({ point in
            let screen = viewport.screen(point)
            return screen.x >= 24 && screen.x <= size.width - 24 && screen.y >= 24 && screen.y <= size.height - 24
        }) else { throw ChemistryError.unavailable(chemistryText("The structure is too large for this note image. Export a smaller selection in the project.", "这个结构超出手记图片范围，请先在工程中整理为较小的结构。")) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            ChemicalCanvasRenderer.draw(document, viewport: viewport, preview: .init(), size: size, dark: false, in: context.cgContext)
        }
        try Task.checkCancellation()
        return try result(image, kind: "structure-2d")
    }

    public static func spectrumPNG(csv: String, title: String) throws -> ChemistryNoteImage {
        try Task.checkCancellation()
        let analysis = try SpectrumAnalysis.csv(csv)
        guard analysis.points.count <= 20_000 else { throw ChemistryError.unavailable(chemistryText("This spectrum has too many samples for a note image.", "这个谱图的数据点超出手记图片范围。")) }
        // Same saved points and LineMark as the chemistry workbench. This is
        // a standalone chart export, not a screenshot or invented curve.
        let plot = VStack(alignment: .leading, spacing: 16) {
            Text(String(title.prefix(120))).font(.title2).lineLimit(2)
            Chart(Array(analysis.points.enumerated()), id: \.offset) { entry in
                let point = entry.element
                LineMark(x: .value("x", point.x), y: .value("Signal", point.y))
            }.chartXAxisLabel("x").chartYAxisLabel(chemistryText("Signal", "信号"))
        }.padding(36).frame(width: 1_200, height: 900).background(Color.white).foregroundStyle(Color.black)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: plot); renderer.scale = 1
        guard let image = renderer.uiImage else { throw ChemistryError.unavailable(chemistryText("The chart image could not be exported.", "暂时无法导出谱图图片。")) }
        try Task.checkCancellation()
        return try result(image, kind: "spectrum")
    }
    private static func result(_ image: UIImage, kind: String) throws -> ChemistryNoteImage {
        guard let data = image.pngData(), !data.isEmpty, data.count <= 12 * 1_024 * 1_024 else {
            throw ChemistryError.unavailable(chemistryText("The exported image exceeds its size limit.", "导出图片超过大小限制。"))
        }
        return .init(png: data, width: 1_200, height: 900, kind: kind)
    }
}
#endif
