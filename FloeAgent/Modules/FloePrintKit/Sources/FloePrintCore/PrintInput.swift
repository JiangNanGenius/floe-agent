// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

public enum PrintError: Error, LocalizedError, Sendable, Equatable {
    case invalidMesh, sizeLimit, unsupportedFormat, invalidSetting(String), outsideBed
    case busy, cancelled, staleResult, invalidArtifact
    public var errorDescription: String? {
        let chinese = Locale.current.language.languageCode?.identifier == "zh"
        switch self {
        case .invalidMesh: return chinese ? "没有可切片的模型，或模型几何无效。请检查 CAD 模型后重新准备打印。" : "There is no sliceable model, or its geometry is invalid. Check the CAD model and prepare the print again."
        case .sizeLimit: return chinese ? "模型过大，请减少面数或分盘处理。" : "The model is too large. Reduce its triangle count or use separate plates."
        case .unsupportedFormat: return chinese ? "不支持此文件格式，请选择 STL、OBJ 或当前打印机支持的结果格式。" : "This format is not supported. Choose STL, OBJ, or an output format supported by the selected printer."
        case .invalidSetting(let detail): return chinese ? "打印设置有误：\(detail)" : "Invalid print settings: \(detail)"
        case .outsideBed: return chinese ? "模型超出打印区域，请调整位置、尺寸或打印机设置。" : "The model is outside the build area. Adjust its position, size, or printer settings."
        case .busy: return chinese ? "正在处理打印工程，请完成或取消当前操作后重试。" : "The print project is busy. Finish or cancel the current operation before trying again."
        case .cancelled: return chinese ? "切片已取消。" : "Slicing was cancelled."
        case .staleResult: return chinese ? "模型或设置已改变，请重新切片。" : "The model or settings changed. Slice again."
        case .invalidArtifact: return chinese ? "切片没有生成有效结果，请查看计算详情后重试。" : "Slicing did not produce a valid result. Check the calculation details and try again."
        }
    }
}

public enum PrintPreset: String, Codable, Sendable, CaseIterable {
    /// Original qualification presets. These names do not certify manufacturer hardware.
    case genericMarlinPLA = "generic-marlin-pla-v1"
    case genericCTBV3 = "generic-ctb-v3-v1"

    public var format: PrintFormat { self == .genericMarlinPLA ? .gcode : .ctbV3 }
    public var bed: (width: Double, depth: Double, height: Double) {
        self == .genericMarlinPLA ? (220, 220, 250) : (120, 68, 150)
    }
    public var profileRevision: Int { 1 }
}

public enum PrintFormat: String, Codable, Sendable {
    case gcode = "gcode-text"
    case ctbV3 = "ctb-v3"

    public init(fileExtension: String, version: Int? = nil) throws {
        switch (fileExtension.lowercased(), version) {
        case ("gcode", nil): self = .gcode
        case ("ctb", 3): self = .ctbV3
        default: throw PrintError.unsupportedFormat
        }
    }
}

/// Expanded triangle vertices in millimetres, relative to the bed centre; Z starts at zero.
public struct PrintMesh: Sendable, Equatable {
    public let positions: [Float]
    public var triangleCount: Int { positions.count / 9 }

    public init(positions: [Float]) throws {
        guard positions.count >= 9, positions.count % 9 == 0 else { throw PrintError.invalidMesh }
        guard positions.count <= 9_000_000 else { throw PrintError.sizeLimit }
        guard positions.allSatisfy(\.isFinite) else { throw PrintError.invalidMesh }
        var hasArea = false
        for i in stride(from: 0, to: positions.count, by: 9) {
            let ax = Double(positions[i+3])-Double(positions[i])
            let ay = Double(positions[i+4])-Double(positions[i+1])
            let az = Double(positions[i+5])-Double(positions[i+2])
            let bx = Double(positions[i+6])-Double(positions[i])
            let by = Double(positions[i+7])-Double(positions[i+1])
            let bz = Double(positions[i+8])-Double(positions[i+2])
            if abs(ay*bz-az*by) + abs(az*bx-ax*bz) + abs(ax*by-ay*bx) > 1e-10 { hasArea = true }
        }
        guard hasArea else { throw PrintError.invalidMesh }
        self.positions = positions.map { $0 == 0 ? 0 : $0 }
    }

    public init(binarySTL data: Data) throws {
        guard data.count >= 84, data.count <= 50_000_084 else { throw PrintError.invalidMesh }
        let bytes = [UInt8](data)
        func u32(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) | UInt32(bytes[i+1]) << 8 | UInt32(bytes[i+2]) << 16 | UInt32(bytes[i+3]) << 24
        }
        let count = Int(u32(80))
        guard count > 0, count <= 1_000_000 else { throw PrintError.sizeLimit }
        guard data.count == 84 + count * 50 else { throw PrintError.invalidMesh }
        var positions = [Float](); positions.reserveCapacity(count * 9)
        for t in 0..<count {
            for k in 0..<9 { positions.append(Float(bitPattern: u32(84 + t*50 + 12 + k*4))) }
        }
        try self.init(positions: positions)
    }

    public var sha256: String {
        var hash = SHA256()
        var buffer = Data(); buffer.reserveCapacity(4096)
        for value in positions {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { buffer.append(contentsOf: $0) }
            if buffer.count >= 4096 { hash.update(data: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        hash.update(data: buffer)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct PrintInput: Sendable {
    public static let enginePin = "ff7692241c48c3495da0bb8eb7455f906f3abb2d"
    public static let adapterVersion = "floe-print-app-5"
    public let mesh: PrintMesh
    public let preset: PrintPreset
    public let overrides: [String: Double]
    public let machine: PrintMachineConfiguration
    public let fingerprint: String

    /// Normalize the three previously persisted human-facing FDM names and
    /// validate before committing settings, rather than discovering them only
    /// after an otherwise valid model has been sent to slicing.
    public static func validatedOverrides(_ proposed: [String: Double], preset: PrintPreset) throws -> [String: Double] {
        var overrides = proposed
        if preset == .genericMarlinPLA {
            for (alias, canonical, divisor) in [("infillPercent", "sliceFillSparse", 100.0),
                ("topLayers", "sliceTopLayers", 1.0), ("bottomLayers", "sliceBottomLayers", 1.0)] {
                if let value = overrides.removeValue(forKey: alias) {
                    let normalized = value / divisor
                    if let explicit = overrides[canonical], explicit != normalized {
                        throw PrintError.invalidSetting("Conflicting \(alias) and \(canonical)")
                    }
                    overrides[canonical] = normalized
                }
            }
        }
        let limits: [String: ClosedRange<Double>] = preset == .genericMarlinPLA
            ? ["sliceHeight": 0.02...1, "outputTemp": 100...450, "outputBedTemp": 0...150, "outputFeedrate": 1...500,
               "sliceFillSparse": 0...1, "sliceShells": 0...20, "sliceTopLayers": 0...30, "sliceBottomLayers": 0...30,
               "sliceSupportEnable": 0...1, "sliceSupportDensity": 0.01...1, "sliceSupportAngle": 0...90]
            : ["slaSlice": 0.005...0.5, "slaLayerOn": 0.1...120, "slaBaseOn": 0.1...600,
               "slaShell": 0...20, "slaSupportEnable": 0...1, "slaSupportDensity": 0.01...1,
               "slaSupportSize": 0.1...5, "slaSupportLayers": 0...100]
        for (key, value) in overrides {
            guard let limit = limits[key], value.isFinite, limit.contains(value) else { throw PrintError.invalidSetting(key) }
            if ["sliceShells", "sliceTopLayers", "sliceBottomLayers", "slaSupportLayers", "sliceSupportEnable", "slaSupportEnable"].contains(key), value.rounded() != value {
                throw PrintError.invalidSetting(key)
            }
        }
        return overrides
    }

    public init(mesh: PrintMesh, preset: PrintPreset, overrides: [String: Double] = [:], machine: PrintMachineConfiguration? = nil) throws {
        let machine = machine ?? .generic(for: preset)
        try machine.validate()
        let overrides = try Self.validatedOverrides(overrides, preset: preset)
        let bed = (width: machine.bedWidth, depth: machine.bedDepth, height: machine.buildHeight)
        for i in stride(from: 0, to: mesh.positions.count, by: 3) {
            guard abs(Double(mesh.positions[i])) <= bed.width/2,
                  abs(Double(mesh.positions[i+1])) <= bed.depth/2,
                  (0...bed.height).contains(Double(mesh.positions[i+2])) else { throw PrintError.outsideBed }
        }
        struct Key: Encodable {
            let geometry: String, preset: PrintPreset, format: PrintFormat, engine: String, adapter: String
            let profileRevision: Int
            let overrides: [String: Double]
            let machine: PrintMachineConfiguration
        }
        var effective: [String:Double] = preset == .genericMarlinPLA
            ? ["sliceHeight":0.2,"outputTemp":200,"outputBedTemp":60,"outputFeedrate":45]
            : ["slaSlice":0.1,"slaLayerOn":2.5,"slaBaseOn":25]
        effective.merge(overrides) { _, new in new }
        let key = Key(geometry: mesh.sha256, preset: preset, format: preset.format,
                      engine: Self.enginePin, adapter: Self.adapterVersion,
                      profileRevision: preset.profileRevision, overrides: effective, machine: machine)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(key)
        self.mesh = mesh; self.preset = preset; self.overrides = overrides; self.machine = machine
        self.fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct PrintRequestIdentity: Sendable, Equatable, Codable {
    public let jobID: UUID, projectID: UUID, plateID: UUID
    public let revision: UInt64
    public init(jobID: UUID = UUID(), projectID: UUID, plateID: UUID, revision: UInt64) {
        self.jobID = jobID; self.projectID = projectID; self.plateID = plateID; self.revision = revision
    }
}

public struct PrintRequest: Sendable {
    public let identity: PrintRequestIdentity
    public let input: PrintInput
    public init(identity: PrintRequestIdentity, input: PrintInput) { self.identity = identity; self.input = input }
}
