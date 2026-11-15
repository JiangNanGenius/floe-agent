// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

/// Errors from the pure quick-estimate radio source.
///
/// `needsInput` is deliberately separate from `invalidInput`: a ray that crosses a
/// wall without matching material attenuation is an unresolved engineering input,
/// not a value that may be silently replaced by a guessed default.
public enum RadioEstimateError: Error, Equatable, Sendable {
    case invalidInput(String)
    case needsInput(String)
    case budgetExceeded(Int)
    case cancelled
}

extension RadioEstimateError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidInput(let field): "Invalid radio estimate input: \(field)"
        case .needsInput(let detail): "Radio estimate needs input: \(detail)"
        case .budgetExceeded(let count): "Radio estimate work budget exceeded: \(count)"
        case .cancelled: "Radio estimate cancelled"
        }
    }
}

/// Radio planning coordinates are explicitly metres, X/Y horizontal and Z up.
///
/// No implicit unit conversion is performed. A value entered in millimetres must be
/// divided by 1000 before it reaches this type. The sample fixture and tests keep this
/// distinction visible because a silent unit mix-up would change every distance and
/// wall-intersection result.
public struct RadioPoint3D: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
    public func distance(to other: RadioPoint3D) -> Double {
        let dx = x - other.x, dy = y - other.y, dz = z - other.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
    func validate(_ field: String) throws {
        guard isFinite else { throw RadioEstimateError.invalidInput(field) }
    }
    static func + (a: Self, b: Self) -> Self { .init(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: Self, b: Self) -> Self { .init(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: Self, b: Double) -> Self { .init(a.x * b, a.y * b, a.z * b) }
    static func / (a: Self, b: Double) -> Self { .init(a.x / b, a.y / b, a.z / b) }
    func dot(_ other: Self) -> Double { x * other.x + y * other.y + z * other.z }
    func cross(_ other: Self) -> Self {
        .init(y * other.z - z * other.y,
              z * other.x - x * other.z,
              x * other.y - y * other.x)
    }
    func normalized() throws -> Self {
        let lengthSquared = x * x + y * y + z * z
        guard isFinite, lengthSquared.isFinite, lengthSquared > 1e-20 else {
            throw RadioEstimateError.invalidInput("direction")
        }
        return self / lengthSquared.squareRoot()
    }
}

/// One radio band with its actual centre frequency and channel width.
///
/// Attenuation data is keyed by the full value, not only by `id`. Changing the centre
/// frequency or channel width therefore requires matching material data instead of
/// reusing an unrelated band's attenuation.
public struct RadioBand: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var centerFrequencyMHz: Double
    public var channelWidthMHz: Double
    public init(id: String, centerFrequencyMHz: Double, channelWidthMHz: Double) {
        self.id = id
        self.centerFrequencyMHz = centerFrequencyMHz
        self.channelWidthMHz = channelWidthMHz
    }
    func validate() throws {
        guard !id.isEmpty,
              centerFrequencyMHz.isFinite, centerFrequencyMHz > 0,
              channelWidthMHz.isFinite, channelWidthMHz > 0,
              channelWidthMHz <= centerFrequencyMHz else {
            throw RadioEstimateError.invalidInput("band")
        }
    }
}

/// A source-backed attenuation value for one band.
public struct RadioBandAttenuation: Codable, Equatable, Sendable {
    public var band: RadioBand
    public var attenuationDB: Double
    public var sourceID: String
    public init(band: RadioBand, attenuationDB: Double, sourceID: String) {
        self.band = band
        self.attenuationDB = attenuationDB
        self.sourceID = sourceID
    }
    func validate() throws {
        try band.validate()
        guard attenuationDB.isFinite, attenuationDB >= 0 else {
            throw RadioEstimateError.invalidInput("wall attenuation")
        }
        guard !sourceID.isEmpty else {
            throw RadioEstimateError.invalidInput("wall attenuation source")
        }
    }
}

/// A finite vertical wall segment with explicit height and thickness.
///
/// `startM` and `endM` are the bottom edge of the wall in plan. Their Z values must be
/// equal; `heightM` extends upward from that elevation. The Z values are used for the
/// vertical overlap test, so an AP/receiver ray that passes above the wall does not
/// receive wall attenuation.
///
/// Thickness is retained as a source record. The v1 quick estimate counts one
/// attenuation event when the horizontal ray crosses the finite centreline segment and
/// the ray height lies inside the wall; it does not compute a path length through the
/// thickness. That limitation is reported in every result.
public struct RadioWall: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var startM: RadioPoint3D
    public var endM: RadioPoint3D
    public var heightM: Double
    public var thicknessM: Double
    public var attenuation: [RadioBandAttenuation]
    public init(id: String, startM: RadioPoint3D, endM: RadioPoint3D,
                heightM: Double, thicknessM: Double,
                attenuation: [RadioBandAttenuation]) {
        self.id = id
        self.startM = startM
        self.endM = endM
        self.heightM = heightM
        self.thicknessM = thicknessM
        self.attenuation = attenuation
    }

    func validate() throws {
        guard !id.isEmpty else { throw RadioEstimateError.invalidInput("wall id") }
        try startM.validate("wall start")
        try endM.validate("wall end")
        guard abs(startM.z - endM.z) <= 1e-9 else {
            throw RadioEstimateError.invalidInput("wall base")
        }
        let dx = endM.x - startM.x, dy = endM.y - startM.y
        guard (dx * dx + dy * dy).squareRoot() > 1e-6 else {
            throw RadioEstimateError.invalidInput("wall segment")
        }
        guard heightM.isFinite, heightM > 0 else {
            throw RadioEstimateError.invalidInput("wall height")
        }
        guard thicknessM.isFinite, thicknessM > 0 else {
            throw RadioEstimateError.invalidInput("wall thickness")
        }
        guard attenuation.count <= 32 else {
            throw RadioEstimateError.invalidInput("wall attenuation")
        }
        var bands = Set<RadioBand>()
        for entry in attenuation {
            try entry.validate()
            guard bands.insert(entry.band).inserted else {
                throw RadioEstimateError.invalidInput("wall attenuation band")
            }
        }
    }

    /// Returns the fraction along `start -> end` where the horizontal ray crosses
    /// this finite wall segment at a height inside the wall, or nil when it misses.
    /// Segment endpoints and exact top/base elevations are treated as misses.
    func crossingFraction(from start: RadioPoint3D, to end: RadioPoint3D) -> Double? {
        let rayX = end.x - start.x, rayY = end.y - start.y
        let wallX = endM.x - startM.x, wallY = endM.y - startM.y
        let denominator = rayX * wallY - rayY * wallX
        guard denominator.isFinite, abs(denominator) > 1e-12 else { return nil }
        let offsetX = startM.x - start.x, offsetY = startM.y - start.y
        let rayFraction = (offsetX * wallY - offsetY * wallX) / denominator
        let wallFraction = (offsetX * rayY - offsetY * rayX) / denominator
        guard rayFraction.isFinite, wallFraction.isFinite,
              rayFraction > 1e-9, rayFraction < 1 - 1e-9,
              wallFraction > 1e-9, wallFraction < 1 - 1e-9 else { return nil }
        let elevation = start.z + rayFraction * (end.z - start.z)
        let base = startM.z, top = startM.z + heightM
        guard elevation > base + 1e-9, elevation < top - 1e-9 else { return nil }
        return rayFraction
    }

    func attenuationDB(for band: RadioBand) throws -> Double {
        guard let entry = attenuation.first(where: { $0.band == band }) else {
            throw RadioEstimateError.needsInput(
                "wall \(id): no attenuation for band \(band.id) at \(band.centerFrequencyMHz) MHz")
        }
        return entry.attenuationDB
    }
}

/// Deterministic SHA-256 binding for request snapshots and evidence.
public enum RadioFingerprint: Sendable {
    public static func hash<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return dataHash(try encoder.encode(value))
    }
    public static func dataHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
