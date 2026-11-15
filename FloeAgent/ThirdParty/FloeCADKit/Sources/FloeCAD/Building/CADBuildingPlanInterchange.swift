// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import CoreText
import simd

/// Floor-specific world coordinates for independent plan exchange. DXF uses
/// model-space millimetres; PDF fits each complete floor to its own vector page.
nonisolated struct CADBuildingPlanDrawing {
    struct Layer {
        let id: UUID
        let name: String
        let segments: [(SIMD2<Double>, SIMD2<Double>)]
        var sourceLayer: String? = nil
    }
    struct Floor {
        let name: String
        let elevationMM: Double
        var layers: [Layer]
    }
    let floors: [Floor]

    func dxf() -> Data {
        var output = "999\nFloeCAD drawing export (units: mm)\n0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1009\n9\n$DWGCODEPAGE\n3\nANSI_1252\n9\n$INSUNITS\n70\n4\n9\n$MEASUREMENT\n70\n1\n0\nENDSEC\n"
        output += "0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLTYPE\n70\n1\n0\nLTYPE\n2\nCONTINUOUS\n70\n0\n3\nSolid line\n72\n65\n73\n0\n40\n0\n0\nENDTAB\n"
        var labels: [UUID: String] = [:]
        var table: [String] = []
        let ascii = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        for (floorIndex, floor) in floors.enumerated() {
            var sourceLabels: [String: String] = [:]
            for (layerIndex, layer) in floor.layers.enumerated() {
                if let source = layer.sourceLayer, let existing = sourceLabels[source] {
                    labels[layer.id] = existing
                    continue
                }
                let prefix = "F\(floorIndex + 1)_\(layerIndex + 1)_"
                let title = (floor.name + "-" + (layer.sourceLayer ?? layer.name)).unicodeScalars.filter(ascii.contains).map(String.init).joined()
                let suffix = title.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
                let label = prefix + String((suffix.isEmpty ? layer.id.uuidString : suffix).prefix(31 - prefix.count))
                labels[layer.id] = label
                if let source = layer.sourceLayer { sourceLabels[source] = label }
                table.append(label)
            }
        }
        output += "0\nTABLE\n2\nLAYER\n70\n\(table.count + 1)\n0\nLAYER\n2\n0\n70\n0\n62\n7\n6\nCONTINUOUS\n"
        for name in table { output += "0\nLAYER\n2\n\(name)\n70\n0\n62\n7\n6\nCONTINUOUS\n" }
        output += "0\nENDTAB\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n"
        for floor in floors {
            for layer in floor.layers {
                let name = labels[layer.id]!
                for (a, b) in layer.segments {
                    output += "0\nLINE\n8\n\(name)\n10\n\(a.x)\n20\n\(a.y)\n30\n\(floor.elevationMM)\n11\n\(b.x)\n21\n\(b.y)\n31\n\(floor.elevationMM)\n"
                }
            }
        }
        output += "0\nENDSEC\n0\nEOF\n"
        return Data(output.utf8)
    }

    func pdf() throws -> Data {
        let storage = NSMutableData()
        var page = CGRect(x: 0, y: 0, width: 842, height: 595)
        guard let consumer = CGDataConsumer(data: storage as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &page, nil) else {
            throw CADBuildingError.invalid("The floor-plan PDF could not be created.")
        }
        let plot = page.insetBy(dx: 32, dy: 52)
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 15, nil)]
        for floor in floors {
            var lo = SIMD2<Double>(repeating: .infinity), hi = SIMD2<Double>(repeating: -.infinity)
            for layer in floor.layers {
                for (a, b) in layer.segments { lo = simd_min(lo, simd_min(a, b)); hi = simd_max(hi, simd_max(a, b)) }
            }
            let scale = min(plot.width / max(hi.x - lo.x, 1), plot.height / max(hi.y - lo.y, 1))
            func point(_ p: SIMD2<Double>) -> CGPoint {
                CGPoint(x: plot.midX + (p.x - (lo.x + hi.x) / 2) * scale, y: plot.midY + (p.y - (lo.y + hi.y) / 2) * scale)
            }
            context.beginPDFPage(nil)
            let caption = "\(floor.name)  ·  \(floor.elevationMM) mm"
            let title = NSAttributedString(string: caption, attributes: attributes)
            context.textPosition = CGPoint(x: 32, y: page.height - 32)
            CTLineDraw(CTLineCreateWithAttributedString(title), context)
            context.setLineWidth(0.65)
            context.setStrokeColor(gray: 0, alpha: 1)
            for layer in floor.layers {
                context.beginPath()
                for (a, b) in layer.segments { context.move(to: point(a)); context.addLine(to: point(b)) }
                context.strokePath()
            }
            context.endPDFPage()
        }
        context.closePDF()
        let data = storage as Data
        guard let provider = CGDataProvider(data: data as CFData), CGPDFDocument(provider)?.numberOfPages == floors.count else {
            throw CADBuildingError.invalid("The floor-plan PDF did not reopen with all selected pages.")
        }
        return data
    }
}

#if canImport(UIKit)
@MainActor public extension FloeCADDocument {
    /// Reads an independent native plan created by createScopedBuildingPlan.
    func buildingPlanInterchange(format: String, storeys: [CADBuildingStorey]) throws -> Data {
        guard !isClosed, !hasUnsavedChanges, session.document.bodies.isEmpty, !session.document.sketches.isEmpty else {
            throw CADBuildingError.invalid("Use a saved, independent floor-plan drawing.")
        }
        let folders = session.document.itemFolders
        let floorIDs = Set(storeys.map(\.id))
        var floorBySketch: [SketchID: UUID] = [:]
        var layerBySketch: [SketchID: String] = [:]
        for folder in folders {
            let owner = floorIDs.contains(folder.id.raw) ? folder.id.raw : folder.parentID?.raw
            guard let floor = owner, floorIDs.contains(floor) else { continue }
            for member in folder.members {
                if case .sketch(let id) = member {
                    floorBySketch[id] = floor
                    if folder.parentID?.raw == floor { layerBySketch[id] = folder.name }
                }
            }
        }
        var groups: [UUID: [CADBuildingPlanDrawing.Layer]] = [:]
        var other: [CADBuildingPlanDrawing.Floor] = []
        var total = 0
        for sketch in session.document.sketches {
            try Task.checkCancellation()
            let plane = sketch.plane
            guard abs(abs(plane.normal.y) - 1) < 1e-8 else {
                throw CADBuildingError.invalid("Choose a drawing page for sketches on non-horizontal planes.")
            }
            var segments: [(SIMD2<Double>, SIMD2<Double>)] = []
            for entity in sketch.entities {
                let lines = SketchTrimmer.segments(for: [entity])
                guard !lines.isEmpty, total + lines.count <= 200_000 else {
                    throw CADBuildingError.invalid("A plan entity could not be represented within the vector drawing budget.")
                }
                for (localA, localB) in lines {
                    let a = SketchPlane.ground.toLocal(plane.toWorld(localA)), b = SketchPlane.ground.toLocal(plane.toWorld(localB))
                    guard [a.x, a.y, b.x, b.y, plane.origin.y].allSatisfy({ $0.isFinite && abs($0) <= 1e12 }), a != b else {
                        throw CADBuildingError.invalid("A plan entity contains a collapsed or invalid segment.")
                    }
                    segments.append((a, b))
                }
                total += lines.count
            }
            guard !segments.isEmpty else { throw CADBuildingError.invalid("A selected native sketch contains no planar geometry.") }
            let layer = CADBuildingPlanDrawing.Layer(id: sketch.id.raw, name: sketch.name, segments: segments, sourceLayer: layerBySketch[sketch.id])
            if let floor = floorBySketch[sketch.id] { groups[floor, default: []].append(layer) }
            else { other.append(.init(name: sketch.name, elevationMM: plane.origin.y, layers: [layer])) }
        }
        let floors = storeys.compactMap { storey -> CADBuildingPlanDrawing.Floor? in
            guard let layers = groups[storey.id] else { return nil }
            return .init(name: storey.name, elevationMM: storey.elevationMM, layers: layers)
        } + other
        guard !floors.isEmpty else { throw CADBuildingError.invalid("The selected drawing contains no plan geometry.") }
        let drawing = CADBuildingPlanDrawing(floors: floors)
        switch format {
        case "pdf": return try drawing.pdf()
        case "dxf": return drawing.dxf()
        default: throw CADBuildingError.invalid("Choose DXF or PDF for native floor linework.")
        }
    }
}
#endif
