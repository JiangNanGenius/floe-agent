// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct PrintPathSegment: Sendable {
    public enum Kind: String, Sendable { case shell, infill, support, travel }
    public let start: [Float], end: [Float]
    public let kind: Kind
}
public struct PrintPathLayer: Sendable, Identifiable {
    public let id: Int
    public let z: Double
    public let segments: [PrintPathSegment]
}
public struct PrintGCodePreview: Sendable {
    public let layers: [PrintPathLayer]
    public let summary: GCodeSummary
    public let movementSeconds: Double
    public let truncated: Bool

    /// Preview the validated output bytes; neither the source mesh nor a
    /// synthetic clipping plane stands in for actual extrusion paths.
    /// G0/G1 linear moves plus G2/G3 arcs (XY IJ or R centres, helical Z
    /// interpolation and P repeats) are tessellated into bounded segments.
    public static func read(_ data: Data, maximumSegments: Int = 500_000) throws -> Self {
        guard (1...500_000).contains(maximumSegments) else { throw PrintError.sizeLimit }
        let summary = try GCodeInspector.inspect(data)
        guard let text = String(data: data, encoding: .utf8) else { throw PrintError.invalidArtifact }
        var xyz = [0.0, 0, 0], extrusion = 0.0, absolute = true, absoluteE = true, feed = 0.0
        var planeXY = true
        var kind = PrintPathSegment.Kind.shell, seconds = 0.0, count = 0, truncated = false
        var paths: [Int64: [PrintPathSegment]] = [:], currentZ: Int64?

        func emit(_ from: [Double], _ to: [Double], extrudes: Bool, bucketZ: Double? = nil) {
            let distance = sqrt(zip(from, to).reduce(0.0) { $0 + pow($1.1 - $1.0, 2) })
            if feed > 0 { seconds += distance / feed * 60 }
            if extrudes {
                // Helical arc steps all belong to the commanded destination
                // layer; planar moves keep their own end height.
                let z = Int64(((bucketZ ?? to[2]) * 10_000).rounded()); currentZ = z
                if paths[z] == nil { paths[z] = [] }
            }
            guard let z = currentZ else { return }
            guard count < maximumSegments else { truncated = true; return }
            paths[z, default: []].append(.init(start: from.map(Float.init), end: to.map(Float.init), kind: extrudes ? kind : .travel)); count += 1
        }

        for raw in text.split(whereSeparator: \.isNewline) {
            try Task.checkCancellation()
            if let marker = raw.firstIndex(of: ";") {
                let comment = raw[marker...].lowercased()
                if comment.contains("feature") || comment.contains("type:") {
                    kind = comment.contains("support") ? .support
                        : (["wall", "shell", "perimeter", "tower", "brim", "skirt"].contains { comment.contains($0) } ? .shell : .infill)
                }
            }
            let code = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let words = code.split(whereSeparator: \.isWhitespace)
            guard let command = words.first else { continue }
            if command == "G90" { absolute = true }; if command == "G91" { absolute = false }
            if command == "M82" { absoluteE = true }; if command == "M83" { absoluteE = false }
            if command == "G17" { planeXY = true }
            if command == "G18" || command == "G19" { planeXY = false }
            var values: [Character: Double] = [:]
            for word in words.dropFirst() {
                if let key = word.first, "XYZEFIJRP".contains(key), let value = Double(word.dropFirst()), value.isFinite { values[key] = value }
            }
            if command == "G92" {
                for (index, key) in Array("XYZ").enumerated() { if let value = values[key] { xyz[index] = value } }
                if let value = values["E"] { extrusion = value }; continue
            }
            guard ["G0", "G00", "G1", "G01", "G2", "G02", "G3", "G03"].contains(String(command)) else { continue }
            let isArc = command == "G2" || command == "G02" || command == "G3" || command == "G03"
            // Arcs exist only in the XY plane; a G18/G19 arc would render
            // wrong geometry, so the read fails clearly instead.
            guard planeXY || !isArc else { throw PrintError.unsupportedFormat }
            let start = xyz
            var end = xyz
            for (index, key) in Array("XYZ").enumerated() {
                if let value = values[key] { end[index] = absolute ? value : end[index] + value }
            }
            if let value = values["F"], value > 0 { feed = value }
            let nextE = values["E"].map { absoluteE ? $0 : extrusion + $0 } ?? extrusion
            let eDelta = nextE - extrusion
            if isArc, let geometry = PrintArcGeometry.solve(
                startX: start[0], startY: start[1], endX: end[0], endY: end[1],
                i: values["I"], j: values["J"], r: values["R"],
                clockwise: command == "G2" || command == "G02",
                repeats: PrintArcGeometry.boundedRepeats(values["P"])) {
                let steps = max(1, min(720, Int((abs(geometry.sweep) / (.pi / 18)).rounded(.up))))
                var previous = start
                for step in 1...steps {
                    let fraction = Double(step) / Double(steps)
                    let angle = geometry.startAngle + geometry.sweep * fraction
                    var point = [geometry.centerX + geometry.radius * cos(angle),
                                 geometry.centerY + geometry.radius * sin(angle),
                                 start[2] + (end[2] - start[2]) * fraction]
                    if step == steps { point = end } // land exactly on the commanded end
                    emit(previous, point, extrudes: eDelta > 1e-7, bucketZ: eDelta > 1e-7 ? end[2] : nil)
                    previous = point
                }
                xyz = end; extrusion = nextE
                continue
            }
            xyz = end; extrusion = nextE
            // Zero-motion moves (including degenerate arcs and pure E primes)
            // never became segments; the inspector skips them identically.
            guard start != xyz else { continue }
            emit(start, xyz, extrudes: eDelta > 1e-7)
        }
        let layers = paths.keys.sorted().enumerated().map { index, z in
            PrintPathLayer(id: index, z: Double(z) / 10_000, segments: paths[z] ?? [])
        }
        return Self(layers: layers, summary: summary, movementSeconds: seconds, truncated: truncated)
    }
}

public struct PrintCTBLayer: Sendable {
    public let width: Int, height: Int
    public let z: Float
    public let pixels: Data
}

/// Bounded CTB v3 layer decoding for the format emitted by the pinned
/// Kiri:Moto adapter. Upstream MIT notice remains bundled with that component.
public struct PrintCTBPreview: Sendable {
    public let header: CTBHeader
    private let data: Data
    public init(data: Data) throws { let owned = Data(data); header = try CTBHeader.inspect(owned); self.data = owned }
    public func layer(_ index: Int) throws -> PrintCTBLayer {
        guard (0..<header.layerCount).contains(index), header.widthPixels * header.heightPixels <= 16_777_216 else { throw PrintError.sizeLimit }
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        let entry = Int(u32(0x40)) + index * 36, offset = Int(u32(entry + 12)), length = Int(u32(entry + 16))
        guard offset <= data.count, length <= data.count - offset else { throw PrintError.invalidArtifact }
        var bytes = Array(data[offset..<offset + length])
        let seed = u32(0x64)
        if seed != 0 {
            let initial = seed &* 0x2d83cdac &+ 0xd8a83423
            var key = (UInt32(index) &* 0x1e1530cd &+ 0xec3d47cd) &* initial
            for i in bytes.indices {
                bytes[i] ^= UInt8(truncatingIfNeeded: key >> (8 * (i % 4)))
                if i % 4 == 3 { key = key &+ initial }
            }
        }
        var pixels = [UInt8](repeating: 0, count: header.widthPixels * header.heightPixels), cursor = 0, output = 0
        while cursor < bytes.count, output < pixels.count {
            try Task.checkCancellation()
            let code = bytes[cursor]; cursor += 1
            var count = 1
            if code & 0x80 != 0 {
                guard cursor < bytes.count else { throw PrintError.invalidArtifact }
                let first = bytes[cursor]; cursor += 1
                let extra: Int
                if first & 0x80 == 0 { count = Int(first); extra = 0 }
                else if first & 0xc0 == 0x80 { count = Int(first & 0x3f); extra = 1 }
                else if first & 0xe0 == 0xc0 { count = Int(first & 0x1f); extra = 2 }
                else if first & 0xf0 == 0xe0 { count = Int(first & 0x0f); extra = 3 }
                else { throw PrintError.invalidArtifact }
                guard extra <= bytes.count - cursor else { throw PrintError.invalidArtifact }
                for _ in 0..<extra { count = count << 8 | Int(bytes[cursor]); cursor += 1 }
            }
            guard count > 0, count <= pixels.count - output else { throw PrintError.invalidArtifact }
            let value: UInt8 = code & 0x7f == 0 ? 0 : (code & 0x7f) << 1 | 1
            for i in output..<output + count { pixels[i] = value }; output += count
        }
        guard output == pixels.count, cursor == bytes.count else { throw PrintError.invalidArtifact }
        return .init(width: header.widthPixels, height: header.heightPixels,
            z: Float(bitPattern: u32(entry)), pixels: Data(pixels))
    }
}
