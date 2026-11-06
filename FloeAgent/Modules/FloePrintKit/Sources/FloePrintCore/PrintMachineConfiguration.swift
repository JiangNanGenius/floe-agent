// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Machine-space coordinates remain Cartesian. Motor mixing belongs to firmware.
public struct PrintMachineConfiguration: Codable, Sendable, Equatable {
    public enum Kinematics: String, Codable, CaseIterable, Sendable { case cartesian, i3, coreXY, delta, scara }
    public enum Origin: String, Codable, CaseIterable, Sendable { case frontLeft, center, rearLeft, custom }
    public struct Tool: Codable, Sendable, Equatable, Identifiable {
        public var id: Int
        public var nozzleDiameter: Double = 0.4
        public var filamentDiameter: Double = 1.75
        public var offsetX: Double = 0, offsetY: Double = 0, offsetZ: Double = 0
        public init(id: Int = 0) { self.id = id }
    }
    public var name = "Generic FDM"
    public var kinematics: Kinematics = .cartesian
    public var bedWidth: Double = 220, bedDepth: Double = 220, buildHeight: Double = 250
    public var origin: Origin = .frontLeft
    public var originX: Double = 0, originY: Double = 0, originZ: Double = 0
    public var headOffsetX: Double = 0, headOffsetY: Double = 0, headOffsetZ: Double = 0
    public var selectedTool = 0
    public var tools = [Tool()]
    public var scripts = PrintGCodeScripts()
    public var pauseLayers: [Int] = []
    public var resin = PrintResinConfiguration()

    public init() {}
    public static func generic(for preset: PrintPreset) -> Self {
        var value = Self()
        let bed = preset.bed
        value.bedWidth = bed.width; value.bedDepth = bed.depth; value.buildHeight = bed.height
        if preset == .genericCTBV3 { value.name = "Generic CTB v3" }
        return value
    }
    public var tool: Tool { tools.first(where: { $0.id == selectedTool }) ?? Tool() }
    /// Offset from the bed-centred editor to the emitted Cartesian tool carriage.
    public var coordinateOffset: [Double] {
        let x = origin == .frontLeft || origin == .rearLeft ? bedWidth / 2 : 0
        let y = origin == .frontLeft ? bedDepth / 2 : origin == .rearLeft ? -bedDepth / 2 : 0
        return [x + originX + headOffsetX - tool.offsetX,
                y + originY + headOffsetY - tool.offsetY, originZ + headOffsetZ - tool.offsetZ]
    }
    public func validate() throws {
        guard (1...2_000).contains(bedWidth), (1...2_000).contains(bedDepth), (1...2_000).contains(buildHeight),
              [originX, originY, originZ, headOffsetX, headOffsetY, headOffsetZ].allSatisfy({ $0.isFinite && abs($0) <= 10_000 }),
              (1...16).contains(tools.count), Set(tools.map(\.id)).count == tools.count,
              tools.contains(where: { $0.id == selectedTool }), name.utf8.count <= 160 else { throw PrintError.invalidSetting("machine") }
        for tool in tools {
            guard (0...15).contains(tool.id), (0.05...5).contains(tool.nozzleDiameter), (0.5...10).contains(tool.filamentDiameter),
                  [tool.offsetX, tool.offsetY, tool.offsetZ].allSatisfy({ $0.isFinite && abs($0) <= 1_000 }) else { throw PrintError.invalidSetting("tool") }
        }
        guard pauseLayers.count <= 200, pauseLayers.allSatisfy({ (0...100_000).contains($0) }) else { throw PrintError.invalidSetting("pause layer") }
        try scripts.validate(); try resin.validate()
    }
}

/// Plain G-code with a small literal substitution vocabulary; never JavaScript or an expression evaluator.
public struct PrintGCodeScripts: Codable, Sendable, Equatable {
    public var start = "G21\nG90\nM82\nM104 S{nozzle_temperature}\nM140 S{bed_temperature}\nG28\nM190 S{bed_temperature}\nM109 S{nozzle_temperature}\nG92 E0"
    public var end = "M104 S0\nM140 S0\nM84"
    public var toolChange = "T{tool}"
    public var beforeLayer = ""
    public var afterLayer = ""
    public var pause = "M0"
    public init() {}
    public func validate() throws {
        let allowed = Set(["nozzle_temperature", "bed_temperature", "tool", "layer", "layer_z", "bed_width", "bed_depth"])
        for block in [start, end, toolChange, beforeLayer, afterLayer, pause] {
            guard block.utf8.count <= 32_768, !block.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\r" && $0 != "\t" }) else { throw PrintError.invalidSetting("gcode") }
            var remaining = block[...]
            while let opening = remaining.firstIndex(of: "{") {
                let suffix = remaining[remaining.index(after: opening)...]
                guard let closing = suffix.firstIndex(of: "}"), allowed.contains(String(suffix[..<closing])) else { throw PrintError.invalidSetting("gcode placeholder") }
                remaining = suffix[suffix.index(after: closing)...]
            }
        }
    }
}

public struct PrintResinConfiguration: Codable, Sendable, Equatable {
    public enum BuildDirection: String, Codable, CaseIterable, Sendable { case awayFromPlatform, towardPlatform }
    public var invertedPlatform = true
    public var buildDirection: BuildDirection = .awayFromPlatform
    public var resolutionX = 960, resolutionY = 544
    public var mirrorX = false, mirrorY = false
    public var rotationDegrees = 0
    public var liftDistance: Double = 5, bottomLiftDistance: Double = 6
    public var liftSpeed: Double = 1.5, retractSpeed: Double = 3
    public var bottomLayers = 5
    public var lightOffSeconds: Double = 0.1
    public init() {}
    public func validate() throws {
        guard (100...8_192).contains(resolutionX), (100...8_192).contains(resolutionY), resolutionX * resolutionY <= 16_777_216,
              [0, 90, 180, 270].contains(rotationDegrees), (0...1_000).contains(bottomLayers),
              (0...100).contains(liftDistance), (0...100).contains(bottomLiftDistance),
              (0.01...100).contains(liftSpeed), (0.01...100).contains(retractSpeed), (0...120).contains(lightOffSeconds) else { throw PrintError.invalidSetting("resin") }
    }
}
