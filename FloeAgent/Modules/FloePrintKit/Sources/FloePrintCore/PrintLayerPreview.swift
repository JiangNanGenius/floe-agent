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
    public static func read(_ data: Data, maximumSegments: Int = 500_000) throws -> Self {
        guard (1...500_000).contains(maximumSegments) else { throw PrintError.sizeLimit }
        let summary = try GCodeInspector.inspect(data)
        guard let text = String(data: data, encoding: .utf8) else { throw PrintError.invalidArtifact }
        var xyz = [0.0, 0, 0], extrusion = 0.0, absolute = true, absoluteE = true, feed = 0.0
        var kind = PrintPathSegment.Kind.shell, seconds = 0.0, count = 0, truncated = false
        var paths: [Int64: [PrintPathSegment]] = [:], currentZ: Int64?
        for raw in text.split(whereSeparator: \.isNewline) {
            try Task.checkCancellation()
            if raw.contains("feature") {
                let comment = raw.lowercased()
                kind = comment.contains("support") ? .support : (comment.contains("shell") ? .shell : .infill)
            }
            let code = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let words = code.split(whereSeparator: \.isWhitespace)
            guard let command = words.first else { continue }
            if command == "G90" { absolute = true }; if command == "G91" { absolute = false }
            if command == "M82" { absoluteE = true }; if command == "M83" { absoluteE = false }
            var values: [Character: Double] = [:]
            for word in words.dropFirst() {
                if let key = word.first, "XYZEF".contains(key), let value = Double(word.dropFirst()), value.isFinite { values[key] = value }
            }
            if command == "G92" {
                for (index, key) in Array("XYZ").enumerated() { if let value = values[key] { xyz[index] = value } }
                if let value = values["E"] { extrusion = value }; continue
            }
            guard ["G0", "G00", "G1", "G01"].contains(String(command)) else { continue }
            let start = xyz
            for (index, key) in Array("XYZ").enumerated() { if let value = values[key] { xyz[index] = absolute ? value : xyz[index] + value } }
            if let value = values["F"], value > 0 { feed = value }
            let nextE = values["E"].map { absoluteE ? $0 : extrusion + $0 } ?? extrusion
            let extrudes = nextE - extrusion > 1e-7; extrusion = nextE
            guard start != xyz else { continue }
            let distance = sqrt(zip(start, xyz).reduce(0.0) { $0 + pow($1.1 - $1.0, 2) })
            if feed > 0 { seconds += distance / feed * 60 }
            if extrudes {
                let z = Int64((xyz[2] * 10_000).rounded()); currentZ = z
                if paths[z] == nil { paths[z] = [] }
            }
            guard let z = currentZ else { continue }
            guard count < maximumSegments else { truncated = true; continue }
            paths[z, default: []].append(.init(start: start.map(Float.init), end: xyz.map(Float.init), kind: extrudes ? kind : .travel)); count += 1
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
