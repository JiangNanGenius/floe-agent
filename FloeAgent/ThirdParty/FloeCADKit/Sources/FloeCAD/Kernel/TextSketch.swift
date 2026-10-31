//
//  TextSketch.swift
//  openshape3d
//
//  Text tool kernel half (spec §1.12): Core Text glyph outlines flattened
//  into closed line polylines in sketch-plane coordinates. Counter loops
//  (the hole in 'O') come out as separate closed loops; ProfileDetector's
//  nesting turns them into holes, so the result extrudes like any sketch.
//
//  X07 (2026-10-31): `shape` is the one native text-outline source shared by
//  the interactive Text sheet and the typed `sketch.addText` Agent command.
//  It reports the real font runs and any visible character with no vector
//  outline instead of silently substituting a font or skipping a glyph.
//  `glyphEntities` remains the legacy outline-only entry point.
//

import Foundation
import CoreGraphics
import CoreText
import simd

nonisolated enum TextSketch {

    /// Bounds of the emitted outlines in sketch-plane millimetres.
    struct Bounds: Sendable, Equatable {
        var min: SIMD2<Double>
        var max: SIMD2<Double>

        var width: Double { max.x - min.x }
        var height: Double { max.y - min.y }
    }

    /// One shaped string. `entities` are closed line loops only. Callers MUST
    /// refuse when `unsupportedFontName != nil`, `missingCharacters` is
    /// non-empty or `tooComplex` is true: a partial word is never committed.
    struct ShapedText: Sendable {
        var entities: [SketchEntity] = []
        var requestedFontName: String?
        var resolvedFontNames: [String] = []
        var fallbackFontNames: [String] = []
        var unsupportedFontName: String?
        var missingCharacters: [String] = []
        var glyphCount: Int = 0
        var outlineLoopCount: Int = 0
        var advanceWidthMM: Double = 0
        var bounds: Bounds?
        var heightMM: Double = 0
        var origin: SIMD2<Double> = .zero
        var tooComplex: Bool = false
        var maximumEntityCount: Int = 0
    }

    /// Bounded so a hostile/accidental model request cannot spend minutes
    /// tessellating an enormous string. The interactive sheet reaches the
    /// same limit through `tooComplex` (it may type longer text than an Agent
    /// request, so the kernel itself remains the final bound).
    static let maximumTextUTF16Count = 256
    static let maximumOutlineEntities = 40_000

    /// Sketch entities (closed line loops) for `text`, laid out on the
    /// baseline starting at `origin` and scaled so the primary font's cap
    /// height equals `height` millimetres. `fontName` nil means Helvetica.
    /// Curves are subdivided to roughly `0.02 * height` chords.
    ///
    /// This legacy entry point does not refuse unsupported glyphs; new
    /// callers use `shape` and inspect its diagnostics.
    static func glyphEntities(
        text: String,
        fontName: String? = nil,
        height: Double,
        at origin: SIMD2<Double> = .zero
    ) -> [SketchEntity] {
        shape(text: text, fontName: fontName, height: height, at: origin).entities
    }

    /// Native outlines flattened to sketch lines, with font/glyph diagnostics.
    /// Font sizes and the input `height` are millimetres.
    static func shape(
        text: String,
        fontName: String? = nil,
        height: Double,
        at origin: SIMD2<Double> = .zero
    ) -> ShapedText {
        var result = ShapedText(heightMM: height, origin: origin,
                                maximumEntityCount: maximumOutlineEntities)
        let trimmedName = fontName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedName = (trimmedName?.isEmpty == false) ? trimmedName : nil
        result.requestedFontName = requestedName
        guard !text.isEmpty, height.isFinite, height > 1e-9 else { return result }

        let selection = resolveFont(requestedName ?? "Helvetica")
        result.resolvedFontNames = selection.names
        guard selection.matched else {
            result.unsupportedFontName = requestedName ?? "Helvetica"
            return result
        }

        let font = selection.font
        let fontSize: CGFloat = 100
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
        let runs = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
        result.advanceWidthMM = Double(CTLineGetTypographicBounds(line, nil, nil, nil)) * scale

        var missingUTF16 = Set<Int>()
        var runFontNames = Set<String>([selection.primaryName])
        var fallbackNames = Set<String>()
        var runRanges: [Range<Int>] = []
        var entities: [SketchEntity] = []
        var loopCount = 0
        var minPoint = SIMD2<Double>(.infinity, .infinity)
        var maxPoint = SIMD2<Double>(-.infinity, -.infinity)
        var tooComplex = false

        runLoop: for run in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            let runRange = CTRunGetStringRange(run)
            if runRange.length > 0 {
                let start = Int(runRange.location)
                runRanges.append(start..<(start + Int(runRange.length)))
            }
            guard glyphCount > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            var stringIndices = [CFIndex](repeating: 0, count: glyphCount)
            CTRunGetGlyphs(run, CFRangeMake(0, 0), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, 0), &positions)
            CTRunGetStringIndices(run, CFRangeMake(0, 0), &stringIndices)

            // The run's font can differ from the requested one (fallback
            // substitution); glyph IDs are only valid against the run font.
            let runFont = runFontAttribute(of: run) ?? font
            let runName = postScriptName(runFont)
            runFontNames.insert(runName)
            if !sameFont(runName, selection.primaryName) {
                fallbackNames.insert(runName)
            }
            // CoreText's LastResort face draws a visible placeholder box, not
            // the requested character. Treat it exactly like a missing glyph.
            let placeholderFont = isLastResort(runName) || isLastResort(familyName(runFont))

            for g in 0..<glyphCount {
                let stringIndex = Int(stringIndices[g])
                if glyphs[g] == 0 || placeholderFont {
                    missingUTF16.insert(stringIndex)
                    continue
                }
                guard let path = CTFontCreatePathForGlyph(runFont, glyphs[g], nil) else {
                    // A visible character with no vector path (colour emoji,
                    // bitmap glyph) has no CAD outline.
                    missingUTF16.insert(stringIndex)
                    continue
                }
                let advance = SIMD2(Double(positions[g].x), Double(positions[g].y))
                for loop in flatten(path, maxChord: chordFont) {
                    let planeLoop = loop.map { origin + ($0 + advance) * scale }
                    loopCount += 1
                    for point in planeLoop {
                        minPoint = simd_min(minPoint, point)
                        maxPoint = simd_max(maxPoint, point)
                    }
                    entities.append(contentsOf: lineEntities(
                        closedLoop: planeLoop, weldTolerance: weldTolerance
                    ))
                    if entities.count > maximumOutlineEntities {
                        tooComplex = true
                        break runLoop
                    }
                }
            }
        }

        if !tooComplex {
            // A visible character CoreText drops entirely has no glyph index
            // and no run coverage. Report it instead of letting it vanish.
            let text16 = text as NSString
            var cluster = 0
            while cluster < text16.length {
                let range = text16.rangeOfComposedCharacterSequence(at: cluster)
                let value = text16.substring(with: range)
                if isVisibleCluster(value) {
                    let clusterRange = range.location..<(range.location + range.length)
                    if !runRanges.contains(where: { $0.overlaps(clusterRange) }) {
                        missingUTF16.insert(range.location)
                    }
                }
                cluster = range.location + range.length
            }
        }

        result.entities = entities
        result.glyphCount = runs.reduce(0) { $0 + Int(CTRunGetGlyphCount($1)) }
        result.outlineLoopCount = loopCount
        result.missingCharacters = missingLabels(text: text, indices: missingUTF16)
        result.resolvedFontNames = runFontNames.sorted()
        result.fallbackFontNames = fallbackNames.sorted()
        result.tooComplex = tooComplex
        if entities.isEmpty {
            result.bounds = nil
        } else {
            result.bounds = Bounds(min: minPoint, max: maxPoint)
        }
        return result
    }

    // MARK: - Font resolution / diagnostics

    private struct FontSelection {
        let font: CTFont
        let primaryName: String
        let names: [String]
        let matched: Bool
    }

    /// Refuse a name CoreText silently substituted. An installed family,
    /// full name or PostScript name is honoured; `NoSuchFont` must not become
    /// Helvetica while the reply still claims the requested font.
    private static func resolveFont(_ requested: String) -> FontSelection {
        let font = CTFontCreateWithName(requested as CFString, 100, nil)
        let postScript = postScriptName(font)
        let family = familyName(font)
        let full = fullName(font)
        let normalized = normalizeFontName(requested)
        let matchesResolved = [postScript, family, full].contains {
            normalizeFontName($0) == normalized
        }
        let matchesInstalledFamily = installedFontFamilies().contains(normalized)
        var names = [postScript, family, full]
        var seen = Set<String>()
        names = names.filter { seen.insert($0).inserted }
        return FontSelection(font: font, primaryName: postScript, names: names,
                             matched: matchesResolved || matchesInstalledFamily)
    }

    private static func installedFontFamilies() -> Set<String> {
        let names = (CTFontManagerCopyAvailableFontFamilyNames() as NSArray? as? [String]) ?? []
        return Set(names.map(normalizeFontName))
    }

    private static func normalizeFontName(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func sameFont(_ a: String, _ b: String) -> Bool {
        normalizeFontName(a) == normalizeFontName(b)
    }

    private static func postScriptName(_ font: CTFont) -> String {
        CTFontCopyPostScriptName(font) as String
    }

    private static func familyName(_ font: CTFont) -> String {
        CTFontCopyFamilyName(font) as String
    }

    private static func fullName(_ font: CTFont) -> String {
        CTFontCopyFullName(font) as String
    }

    private static func isLastResort(_ name: String) -> Bool {
        name.range(of: "lastresort", options: .caseInsensitive) != nil
    }

    /// U+XXXX labels for visible characters without a real vector outline.
    /// Whitespace/control/format/mark-only clusters are not text glyphs and
    /// are deliberately not reported.
    private static func missingLabels(text: String, indices: Set<Int>) -> [String] {
        let text16 = text as NSString
        guard text16.length > 0 else { return [] }
        var labels = Set<String>()
        for index in indices.sorted() {
            let safe = min(max(index, 0), text16.length - 1)
            let range = text16.rangeOfComposedCharacterSequence(at: safe)
            let value = text16.substring(with: range)
            guard isVisibleCluster(value) else { continue }
            for scalar in value.unicodeScalars {
                labels.insert(String(format: "U+%04X", scalar.value))
            }
        }
        return labels.sorted()
    }

    private static func isVisibleCluster(_ value: String) -> Bool {
        for scalar in value.unicodeScalars {
            let properties = scalar.properties
            if properties.isWhitespace { continue }
            switch properties.generalCategory {
            case .control, .format, .nonspacingMark, .enclosingMark,
                 .lineSeparator, .paragraphSeparator, .spaceSeparator:
                continue
            default:
                return true
            }
        }
        return false
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
