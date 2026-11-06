// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

public struct GCodeSummary: Sendable, Equatable {
    public let layerCount: Int, extrusionMoves: Int
    public let filamentMM: Double
    public let minimum: [Double], maximum: [Double]
}

public enum GCodeInspector {
    /// Reads actual G0/G1, G90/G91, M82/M83 and G92 state. Unsupported motion is rejected.
    public static func inspect(_ data: Data) throws -> GCodeSummary {
        guard data.count <= 64*1024*1024, let text = String(data: data, encoding: .utf8) else { throw PrintError.invalidArtifact }
        var position = [0.0, 0, 0], e = 0.0, absolute = true, absoluteE = true
        var lo = [Double](repeating: .infinity, count: 3), hi = [Double](repeating: -.infinity, count: 3)
        var layers = Set<Int64>(), moves = 0, used = 0.0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let words = line.split(whereSeparator: \.isWhitespace)
            guard let command = words.first else { continue }
            if command == "G2" || command == "G3" || command == "G20" { throw PrintError.unsupportedFormat }
            if command == "G90" { absolute = true }; if command == "G91" { absolute = false }
            if command == "M82" { absoluteE = true }; if command == "M83" { absoluteE = false }
            var values: [Character: Double] = [:]
            for word in words.dropFirst() {
                if let key = word.first, "XYZEF".contains(key) {
                    guard let value = Double(word.dropFirst()), value.isFinite else { throw PrintError.invalidArtifact }
                    values[key] = value
                }
            }
            if command == "G92" {
                for (i,key) in Array("XYZ").enumerated() { if let v = values[key] { position[i] = v } }
                if let v = values["E"] { e = v }; continue
            }
            guard ["G0", "G00", "G1", "G01"].contains(String(command)) else { continue }
            let start = position
            for (i,key) in Array("XYZ").enumerated() { if let v = values[key] { position[i] = absolute ? v : position[i]+v } }
            let nextE = values["E"].map { absoluteE ? $0 : e+$0 } ?? e
            guard position.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }), nextE.isFinite, abs(nextE) <= 1_000_000_000 else { throw PrintError.invalidArtifact }
            let delta = nextE-e; e = nextE
            if delta > 1e-7, start != position {
                used += delta; moves += 1; layers.insert(Int64((position[2]*10000).rounded()))
                for i in 0..<3 { lo[i] = min(lo[i], start[i], position[i]); hi[i] = max(hi[i], start[i], position[i]) }
            }
        }
        guard moves > 0, !layers.isEmpty else { throw PrintError.invalidArtifact }
        return GCodeSummary(layerCount: layers.count, extrusionMoves: moves, filamentMM: used, minimum: lo, maximum: hi)
    }
}

public struct CTBHeader: Sendable, Equatable {
    public let version: Int, widthPixels: Int, heightPixels: Int, layerCount: Int
    public let bedWidthMM: Float, bedDepthMM: Float, layerHeightMM: Float
    public let exposureSeconds: Float, bottomExposureSeconds: Float, bottomLayers: Int

    /// Metadata/extent inspection only. Full independent layer decoding lives in qualification.
    public static func inspect(_ data: Data) throws -> CTBHeader {
        guard data.count >= 112, data.count <= 128*1024*1024 else { throw PrintError.invalidArtifact }
        let b = [UInt8](data)
        func u(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o+1])<<8 | UInt32(b[o+2])<<16 | UInt32(b[o+3])<<24 }
        func f(_ o: Int) -> Float { Float(bitPattern: u(o)) }
        guard u(0) == 0x12fd0086, u(4) == 3 else { throw PrintError.unsupportedFormat }
        let w = Int(u(0x34)), h = Int(u(0x38)), n = Int(u(0x44)), table = Int(u(0x40))
        guard (1...16384).contains(w), (1...16384).contains(h), (1...100000).contains(n),
              table >= 112, table <= data.count, n <= (data.count-table)/36,
              [f(8),f(12),f(0x20),f(0x24),f(0x28)].allSatisfy({ $0.isFinite && $0 > 0 }) else { throw PrintError.invalidArtifact }
        var previous: Float = 0
        for i in 0..<n {
            let o = table + i*36, z = f(o), offset = Int(u(o+12)), length = Int(u(o+16))
            guard z.isFinite, z > previous, f(o+4).isFinite, f(o+4)>0,
                  offset >= 112, offset <= data.count, length > 0, length <= data.count-offset else { throw PrintError.invalidArtifact }
            previous = z
        }
        return CTBHeader(version: 3, widthPixels: w, heightPixels: h, layerCount: n,
                         bedWidthMM: f(8), bedDepthMM: f(12), layerHeightMM: f(0x20),
                         exposureSeconds: f(0x24), bottomExposureSeconds: f(0x28), bottomLayers: Int(u(0x30)))
    }
}

public struct PrintArtifact: Sendable {
    public let identity: PrintRequestIdentity, format: PrintFormat
    public let inputFingerprint: String, sha256: String, data: Data
    public let layerCount: Int

    public init(request: PrintRequest, data: Data) throws {
        let layers: Int
        switch request.input.preset.format {
        case .gcode:
            let summary = try GCodeInspector.inspect(data)
            let bed = request.input.preset.bed
            guard summary.minimum.allSatisfy({ $0 >= -0.01 }), summary.maximum[0] <= bed.width+0.01,
                  summary.maximum[1] <= bed.depth+0.01, summary.maximum[2] <= bed.height+0.01 else { throw PrintError.invalidArtifact }
            layers = summary.layerCount
        case .ctbV3:
            let header = try CTBHeader.inspect(data)
            let layerHeight = request.input.overrides["slaSlice"] ?? 0.1
            let exposure = request.input.overrides["slaLayerOn"] ?? 2.5
            let bottom = request.input.overrides["slaBaseOn"] ?? 25
            guard header.widthPixels == 960, header.heightPixels == 544,
                  abs(header.bedWidthMM-120) < 0.001, abs(header.bedDepthMM-68) < 0.001,
                  abs(Double(header.layerHeightMM)-layerHeight) < 0.00001,
                  abs(Double(header.exposureSeconds)-exposure) < 0.00001,
                  abs(Double(header.bottomExposureSeconds)-bottom) < 0.00001,
                  header.bottomLayers == 5 else { throw PrintError.invalidArtifact }
            layers = header.layerCount
        }
        self.identity = request.identity; self.inputFingerprint = request.input.fingerprint
        self.format = request.input.preset.format; self.data = data; self.layerCount = layers
        self.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
