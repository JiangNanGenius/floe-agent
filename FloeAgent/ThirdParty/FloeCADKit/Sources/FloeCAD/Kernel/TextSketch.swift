//
//  TextSketch.swift
//  openshape3d
//
//  Text tool kernel half (spec §1.12): Core Text glyph outlines flattened
//  into closed line polylines in sketch-plane coordinates. Counter loops
//  (the hole in 'O') come out as separate closed loops; ProfileDetector's
//  nesting turns them into holes, so the result extrudes like any sketch.
//

import Foundation
import CoreGraphics
import CoreText
import simd

nonisolated enum TextSketch {

    /// Sketch entities (closed line loops) for `text`, laid out on the
    /// baseline starting at `origin` and scaled so the font's cap height
    /// equals `height`. `fontName` nil falls back to Helvetica. Curves are
    /// subdivided to roughly `0.02 * height` chords.
    static func glyphEntities(
        text: String,
        fontName: String? = nil,
        height: Double,
        at origin: SIMD2<Double> = .zero
    ) -> [SketchEntity] {
        guard !text.isEmpty, height > 1e-9 else { return [] }

        let fontSize: CGFloat = 100
        let font = CTFontCreateWithName((fontName ?? "Helvetica") as CFString, fontSize, nil)
        var capHeight = Double(CTFontGetCapHeight(font))
        if capHeight <= 1e-9 { capHeight = Double(fontSize) * 0.7 }
        let scale = height / capHeight
        // Chord tolerance in font units so flattened chords come out
        // ~0.02 * height in plane units.
        let chordFont = 0.02 * capHeight
        // Weld tolerance in plane units, well under a chord length.
        let weldTolerance = 0.001 * height

        let attributed = NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return [] }

        var entities: [SketchEntity] = []
        for run in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            CTRunGetGlyphs(run, CFRangeMake(0, 0), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, 0), &positions)

            // The run's font can differ from the requested one (fallback
            // substitution); glyph IDs are only valid against the run font.
            let runFont = runFontAttribute(of: run) ?? font

            for g in 0..<glyphCount {
                guard let path = CTFontCreatePathForGlyph(runFont, glyphs[g], nil) else {
                    continue // whitespace and empty glyphs
                }
                let advance = SIMD2(Double(positions[g].x), Double(positions[g].y))
                for loop in flatten(path, maxChord: chordFont) {
                    let planeLoop = loop.map { origin + ($0 + advance) * scale }
                    entities.append(contentsOf: lineEntities(
                        closedLoop: planeLoop, weldTolerance: weldTolerance
                    ))
                }
            }
        }
        return entities
    }

    // MARK: - Path flattening

    /// Closed subpaths of `path` as polylines (first point not repeated at
    /// the end). Quads/cubics are subdivided into segments of roughly
    /// `maxChord` length.
    private static func flatten(_ path: CGPath, maxChord: Double) -> [[SIMD2<Double>]] {
        var loops: [[SIMD2<Double>]] = []
        var current: [SIMD2<Double>] = []

        func point(_ p: CGPoint) -> SIMD2<Double> {
            SIMD2(Double(p.x), Double(p.y))
        }
        func closeCurrent() {
            if current.count >= 3 { loops.append(current) }
            current = []
        }
        func segmentCount(forEstimatedLength length: Double) -> Int {
            max(1, min(64, Int((length / max(maxChord, 1e-9)).rounded(.up))))
        }

        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                closeCurrent()
                current = [point(element.points[0])]
            case .addLineToPoint:
                current.append(point(element.points[0]))
            case .addQuadCurveToPoint:
                guard let start = current.last else { break }
                let control = point(element.points[0])
                let end = point(element.points[1])
                let estimate = simd_length(control - start) + simd_length(end - control)
                let n = segmentCount(forEstimatedLength: estimate)
                for i in 1...n {
                    let t = Double(i) / Double(n)
                    let a = mix(start, control, t: t)
                    let b = mix(control, end, t: t)
                    current.append(mix(a, b, t: t))
                }
            case .addCurveToPoint:
                guard let start = current.last else { break }
                let c1 = point(element.points[0])
                let c2 = point(element.points[1])
                let end = point(element.points[2])
                let estimate = simd_length(c1 - start) + simd_length(c2 - c1)
                    + simd_length(end - c2)
                let n = segmentCount(forEstimatedLength: estimate)
                for i in 1...n {
                    let t = Double(i) / Double(n)
                    let a = mix(start, c1, t: t)
                    let b = mix(c1, c2, t: t)
                    let c = mix(c2, end, t: t)
                    let ab = mix(a, b, t: t)
                    let bc = mix(b, c, t: t)
                    current.append(mix(ab, bc, t: t))
                }
            case .closeSubpath:
                closeCurrent()
            @unknown default:
                break
            }
        }
        closeCurrent()
        return loops
    }

    private static func mix(
        _ a: SIMD2<Double>, _ b: SIMD2<Double>, t: Double
    ) -> SIMD2<Double> {
        a + (b - a) * t
    }

    /// Closed loop → line entities, welding near-duplicate points so
    /// ProfileDetector's endpoint quantization never sees micro-segments.
    private static func lineEntities(
        closedLoop points: [SIMD2<Double>], weldTolerance: Double
    ) -> [SketchEntity] {
        var cleaned: [SIMD2<Double>] = []
        for p in points {
            if let last = cleaned.last, simd_length(p - last) < weldTolerance { continue }
            cleaned.append(p)
        }
        while cleaned.count > 1,
              simd_length(cleaned.first! - cleaned.last!) < weldTolerance {
            cleaned.removeLast()
        }
        guard cleaned.count >= 3 else { return [] }
        return cleaned.indices.map { i in
            .line(id: UUID(), a: cleaned[i], b: cleaned[(i + 1) % cleaned.count])
        }
    }

    private static func runFontAttribute(of run: CTRun) -> CTFont? {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let value = attributes[kCTFontAttributeName as String] else { return nil }
        let object = value as CFTypeRef
        guard CFGetTypeID(object) == CTFontGetTypeID() else { return nil }
        return (object as! CTFont)
    }
}
