// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

public struct GCodeSummary: Sendable, Equatable {
    public let layerCount: Int, extrusionMoves: Int
    public let filamentMM: Double
    public let minimum: [Double], maximum: [Double]
}

public enum GCodeInspector {
    /// Reads actual G0/G1 linear moves and G2/G3 arcs (XY IJ/R centres,
    /// helical Z), plus G90/G91, M82/M83 and G92 state. Inch-mode output and
    /// unknown units are rejected rather than silently mis-scaled.
    public static func inspect(_ data: Data) throws -> GCodeSummary {
        guard data.count <= 64*1024*1024, let text = String(data: data, encoding: .utf8) else { throw PrintError.invalidArtifact }
        var position = [0.0, 0, 0], e = 0.0, absolute = true, absoluteE = true
        var planeXY = true
        var lo = [Double](repeating: .infinity, count: 3), hi = [Double](repeating: -.infinity, count: 3)
        var layers = Set<Int64>(), moves = 0, used = 0.0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let words = line.split(whereSeparator: \.isWhitespace)
            guard let command = words.first else { continue }
            if command == "G20" { throw PrintError.unsupportedFormat }
            if command == "G90" { absolute = true }; if command == "G91" { absolute = false }
            if command == "M82" { absoluteE = true }; if command == "M83" { absoluteE = false }
            if command == "G17" { planeXY = true }
            if command == "G18" || command == "G19" { planeXY = false }
            let isArc = command == "G2" || command == "G02" || command == "G3" || command == "G03"
            let isMotion = ["G0", "G00", "G1", "G01"].contains(String(command)) || isArc
            // Word validation is strict only for commands the inspector
            // consumes. Firmware dialects (G28 X, M73 L0, ...) carry bare or
            // non-numeric words and must be ignored, not treated as corrupt.
            guard command == "G92" || isMotion else { continue }
            var values: [Character: Double] = [:]
            for word in words.dropFirst() {
                if let key = word.first, "XYZEFIJR".contains(key) {
                    guard let value = Double(word.dropFirst()), value.isFinite else { throw PrintError.invalidArtifact }
                    values[key] = value
                }
            }
            if command == "G92" {
                for (i,key) in Array("XYZ").enumerated() { if let v = values[key] { position[i] = v } }
                if let v = values["E"] { e = v }; continue
            }
            let start = position
            // Arcs exist only in the XY plane; a G18/G19 arc would render
            // wrong geometry, so it is rejected instead of approximated.
            guard planeXY || !isArc else { throw PrintError.unsupportedFormat }
            // Commit the move in place before any extrusion guard: Z-only
            // layer moves carry no E and must still advance the model.
            for (i,key) in Array("XYZ").enumerated() { if let v = values[key] { position[i] = absolute ? v : position[i]+v } }
            let nextE = values["E"].map { absoluteE ? $0 : e+$0 } ?? e
            guard position.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }), nextE.isFinite, abs(nextE) <= 1_000_000_000 else { throw PrintError.invalidArtifact }
            let delta = nextE-e; e = nextE
            var geometry: PrintArcGeometry.Solution?
            if isArc {
                geometry = PrintArcGeometry.solve(
                    startX: start[0], startY: start[1], endX: position[0], endY: position[1],
                    i: values["I"], j: values["J"], r: values["R"],
                    clockwise: command == "G2" || command == "G02",
                    repeats: PrintArcGeometry.boundedRepeats(values["P"]))
            }
            // Pure deretract primes (E only, no carriage motion) never counted
            // as extrusion moves; a full-circle arc sweeps even when its end
            // equals its start.
            guard delta > 1e-7, start != position || geometry != nil else { continue }
            func bound(_ p: [Double]) {
                for i in 0..<3 { lo[i] = min(lo[i], p[i]); hi[i] = max(hi[i], p[i]) }
            }
            bound(start); bound(position)
            if let geometry {
                // Sample the arc so helical extremes stay honest without a
                // full tessellation pass in the inspector.
                let samples = min(16, max(2, Int((abs(geometry.sweep) / (.pi / 8)).rounded(.up))))
                for sample in 1..<samples {
                    let angle = geometry.startAngle + geometry.sweep * Double(sample) / Double(samples)
                    bound([geometry.centerX + geometry.radius * cos(angle),
                           geometry.centerY + geometry.radius * sin(angle),
                           start[2] + (position[2] - start[2]) * Double(sample) / Double(samples)])
                }
            }
            moves += 1; layers.insert(Int64((position[2]*10000).rounded()))
            used += delta
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
            let machine = request.input.machine, offset = machine.coordinateOffset
            let low = [-machine.bedWidth / 2, -machine.bedDepth / 2, 0.0]
            let high = [machine.bedWidth / 2, machine.bedDepth / 2, machine.buildHeight]
            guard (0..<3).allSatisfy({ summary.minimum[$0] >= low[$0] + offset[$0] - 0.01 && summary.maximum[$0] <= high[$0] + offset[$0] + 0.01 }) else { throw PrintError.invalidArtifact }
            layers = summary.layerCount
        case .ctbV3:
            let header = try CTBHeader.inspect(data)
            let layerHeight = request.input.overrides["slaSlice"] ?? 0.1
            let exposure = request.input.overrides["slaLayerOn"] ?? 2.5
            let bottom = request.input.overrides["slaBaseOn"] ?? 25
            let machine = request.input.machine
            guard header.widthPixels == machine.resin.resolutionX, header.heightPixels == machine.resin.resolutionY,
                  abs(Double(header.bedWidthMM)-machine.bedWidth) < 0.001, abs(Double(header.bedDepthMM)-machine.bedDepth) < 0.001,
                  abs(Double(header.layerHeightMM)-layerHeight) < 0.00001,
                  abs(Double(header.exposureSeconds)-exposure) < 0.00001,
                  abs(Double(header.bottomExposureSeconds)-bottom) < 0.00001,
                  header.bottomLayers == machine.resin.bottomLayers else { throw PrintError.invalidArtifact }
            layers = header.layerCount
        }
        self.identity = request.identity; self.inputFingerprint = request.input.fingerprint
        self.format = request.input.preset.format; self.data = data; self.layerCount = layers
        self.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
