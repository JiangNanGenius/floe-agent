// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import UIKit
import FloeHeavyEditorSupport

private nonisolated struct GISPreviewPoint: Sendable { let x: Double; let y: Double }
private nonisolated struct GISPreviewShape: Sendable { let parts: [[GISPreviewPoint]]; let polygon: Bool }
private nonisolated struct GISPreviewProjection: Sendable {
    let title: String
    let crs: String
    let layerCount: Int
    let vectorCount: Int
    let rasterCount: Int
    let tileCount: Int
    let shapes: [GISPreviewShape]
    let subset: Bool
    var summary: String {
        let layers = previewText("图层", "Layers"), vectors = previewText("矢量要素", "Vector features")
        let rasters = previewText("栅格", "Rasters"), tiles = previewText("瓦片图层", "Tile layers")
        return "\(title)\n\(crs)\n\(layers): \(layerCount)\n\(vectors): \(vectorCount)\n\(rasters): \(rasterCount) · \(tiles): \(tileCount)"
    }
    static func read(_ saved: GISProjectSavedSnapshot) throws -> Self {
        let state = saved.state, projectCRS = state["crs"].string ?? "", layers = state["layers"].array
        var shapes: [GISPreviewShape] = [], vertices = 0, subset = false
        func point(_ source: EditorJSON, from crs: String) -> GISPreviewPoint? {
            let v = source.array
            guard v.count >= 2, let x = v[0].number, let y = v[1].number, x.isFinite, y.isFinite else { return nil }
            if crs == projectCRS { return .init(x: x, y: y) }
            if crs == "EPSG:4326", projectCRS == "EPSG:3857" {
                return .init(x: x * .pi * 6_378_137 / 180, y: log(tan(.pi / 4 + min(85.05112878, max(-85.05112878, y)) * .pi / 360)) * 6_378_137)
            }
            if crs == "EPSG:3857", projectCRS == "EPSG:4326" {
                return .init(x: x * 180 / (.pi * 6_378_137), y: (2 * atan(exp(y / 6_378_137)) - .pi / 2) * 180 / .pi)
            }
            subset = true; return nil // No guessed custom projection in a read-only cover.
        }
        func line(_ values: [EditorJSON], crs: String) -> [GISPreviewPoint] {
            var output: [GISPreviewPoint] = []
            for item in values {
                if vertices >= 20_000 { subset = true; break }
                if let value = point(item, from: crs) { output.append(value); vertices += 1 }
            }
            return output
        }
        func geometry(_ value: EditorJSON, crs: String) throws {
            try Task.checkCancellation()
            guard vertices < 20_000 else { subset = true; return }
            let c = value["coordinates"].array
            switch value["type"].string {
            case "Point": if let p = point(value["coordinates"], from: crs) { shapes.append(.init(parts: [[p]], polygon: false)); vertices += 1 }
            case "MultiPoint": for item in c { try geometry(.object(["type": .string("Point"), "coordinates": item]), crs: crs) }
            case "LineString": shapes.append(.init(parts: [line(c, crs: crs)], polygon: false))
            case "MultiLineString": for item in c { shapes.append(.init(parts: [line(item.array, crs: crs)], polygon: false)) }
            case "Polygon": shapes.append(.init(parts: c.map { line($0.array, crs: crs) }, polygon: true))
            case "MultiPolygon": for item in c { shapes.append(.init(parts: item.array.map { line($0.array, crs: crs) }, polygon: true)) }
            case "GeometryCollection": for child in value["geometries"].array { try geometry(child, crs: crs) }
            default: break
            }
        }
        var vectorCount = 0, rasterCount = 0, tileCount = 0
        for layer in layers {
            if layer["kind"].string == "raster" { rasterCount += 1; continue }
            if layer["kind"].string == "tiles" { tileCount += 1; continue }
            let features = layer["data"]["features"].array; vectorCount += features.count
            guard layer["visible"].bool != false else { continue }
            for feature in features {
                if vertices >= 20_000 { subset = true; break }
                try geometry(feature["geometry"], crs: layer["crs"].string ?? projectCRS)
            }
        }
        return .init(title: saved.document.title, crs: projectCRS, layerCount: layers.count, vectorCount: vectorCount,
                     rasterCount: rasterCount, tileCount: tileCount, shapes: shapes, subset: subset)
    }
    @MainActor func image(pixels: Int) throws -> Data {
        let width = CGFloat(pixels), height = width * 0.7
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: .init(width: width, height: height), format: format).image { renderer in
            let context = renderer.cgContext
            UIColor.secondarySystemBackground.setFill(); context.fill(.init(x: 0, y: 0, width: width, height: height))
            let points = shapes.flatMap(\.parts).flatMap { $0 }
            guard let first = points.first else { return }
            let minX = points.reduce(first.x) { min($0, $1.x) }, maxX = points.reduce(first.x) { max($0, $1.x) }
            let minY = points.reduce(first.y) { min($0, $1.y) }, maxY = points.reduce(first.y) { max($0, $1.y) }
            let frame = CGRect(x: 16, y: 16, width: max(1, width - 32), height: max(1, height - 66))
            let dx = max(0.000001, maxX - minX), dy = max(0.000001, maxY - minY)
            let scale = min(Double(frame.width) / dx, Double(frame.height) / dy)
            func screen(_ p: GISPreviewPoint) -> CGPoint {
                .init(x: frame.midX + CGFloat((p.x - (minX + maxX) / 2) * scale), y: frame.midY - CGFloat((p.y - (minY + maxY) / 2) * scale))
            }
            context.setStrokeColor(UIColor.systemBlue.cgColor); context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.16).cgColor); context.setLineWidth(1.4)
            for shape in shapes {
                let path = CGMutablePath()
                for part in shape.parts {
                    guard let first = part.first else { continue }
                    if part.count == 1 { let p = screen(first); path.addEllipse(in: .init(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)); continue }
                    path.move(to: screen(first)); for p in part.dropFirst() { path.addLine(to: screen(p)) }
                    if shape.polygon { path.closeSubpath() }
                }
                context.addPath(path); context.drawPath(using: shape.polygon ? .eoFillStroke : .stroke)
            }
            let layers = previewText("图层", "layers")
            let label = "\(crs) · \(layerCount) \(layers)"
            (label as NSString).draw(in: .init(x: 14, y: height - 35, width: width - 28, height: 28),
                withAttributes: [.font: UIFont.systemFont(ofSize: max(10, width / 40)), .foregroundColor: UIColor.secondaryLabel])
        }
        guard let bytes = image.pngData() else { throw PersonalContentPreviewError.unavailable }
        return bytes
    }
}

extension PersonalContentPreviewService {
    func savedGIS(record: PersonalContentRecord, directory: URL, ownerID: String, maximumPixelSize: Int,
                  validate: @escaping @MainActor @Sendable () async throws -> Void) async throws -> PersonalContentPreviewRequest {
        let saved = try await personalPreviewOffMain { try GISProjectOriginal.read(id: record.id, directory: directory, maximumBytes: 128 * 1_024 * 1_024) }
        let projection = try await personalPreviewOffMain { try GISPreviewProjection.read(saved) }
        let key = PersonalContentPreviewKey(ownerID: ownerID, objectID: record.id.uuidString, revision: String(saved.document.revision),
            variant: "gis-saved:\(saved.sha256):\(saved.file.identity.token)", maximumPixelSize: maximumPixelSize)
        return .init(key: key, validate: { try await validate(); try saved.validate() }, produce: {
            try await validate(); try saved.validate()
            if projection.shapes.allSatisfy({ $0.parts.allSatisfy(\.isEmpty) }) {
                return .init(.text(projection.summary), provenance: .moduleSnapshot, detail: previewText("已保存图层摘要", "Saved layer summary"))
            }
            return .init(.image(try projection.image(pixels: key.maximumPixelSize)), provenance: .moduleSnapshot,
                         detail: projection.subset ? previewText("已保存矢量概览；部分要素", "Saved vector overview; feature subset") : previewText("已保存矢量概览", "Saved vector overview"))
        })
    }
}
#endif
