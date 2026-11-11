import Foundation
import FloeToolboxCore

// MARK: - Unit conversion

public enum EverydayUnitCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case length, area, volume, temperature, pressure, mass, speed
    public var id: String { rawValue }
}

/// One unit of measure. `factor`/`offset` define the affine map to and from
/// the category base unit: base = value * factor + offset. Temperature is the
/// only affine category; everything else uses offset zero.
public struct EverydayUnit: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let category: EverydayUnitCategory
    public let symbol: String
    let factor: Double
    let offset: Double

    public init(id: String, category: EverydayUnitCategory, symbol: String, factor: Double, offset: Double = 0) {
        self.id = id; self.category = category; self.symbol = symbol
        self.factor = factor; self.offset = offset
    }
}

public enum EverydayUnitConverter {
    public static func units(for category: EverydayUnitCategory) -> [EverydayUnit] {
        switch category {
        case .length:
            return [unit("mm", .length, "mm", 0.001), unit("cm", .length, "cm", 0.01), unit("m", .length, "m", 1),
                    unit("km", .length, "km", 1000), unit("in", .length, "in", 0.0254), unit("ft", .length, "ft", 0.3048),
                    unit("yd", .length, "yd", 0.9144), unit("mi", .length, "mi", 1609.344)]
        case .area:
            return [unit("mm2", .area, "mm²", 0.000001), unit("cm2", .area, "cm²", 0.0001), unit("m2", .area, "m²", 1),
                    unit("km2", .area, "km²", 1_000_000), unit("ha", .area, "ha", 10_000), unit("ft2", .area, "ft²", 0.09290304),
                    unit("ac", .area, "ac", 4046.8564224)]
        case .volume:
            return [unit("ml", .volume, "mL", 0.000001), unit("l", .volume, "L", 0.001), unit("cm3", .volume, "cm³", 0.000001),
                    unit("m3", .volume, "m³", 1), unit("ft3", .volume, "ft³", 0.028316846592), unit("gal", .volume, "gal", 0.003785411784)]
        case .temperature:
            return [EverydayUnit(id: "c", category: .temperature, symbol: "°C", factor: 1, offset: 0),
                    EverydayUnit(id: "f", category: .temperature, symbol: "°F", factor: 5.0 / 9.0, offset: -160.0 / 9.0),
                    EverydayUnit(id: "k", category: .temperature, symbol: "K", factor: 1, offset: -273.15)]
        case .pressure:
            return [unit("pa", .pressure, "Pa", 1), unit("kpa", .pressure, "kPa", 1000), unit("bar", .pressure, "bar", 100_000),
                    unit("atm", .pressure, "atm", 101_325), unit("psi", .pressure, "psi", 6894.757293168), unit("mmhg", .pressure, "mmHg", 133.322387415)]
        case .mass:
            return [unit("mg", .mass, "mg", 0.000001), unit("g", .mass, "g", 0.001), unit("kg", .mass, "kg", 1),
                    unit("t", .mass, "t", 1000), unit("oz", .mass, "oz", 0.028349523125), unit("lb", .mass, "lb", 0.45359237)]
        case .speed:
            return [unit("ms", .speed, "m/s", 1), unit("kmh", .speed, "km/h", 1.0 / 3.6), unit("mph", .speed, "mph", 0.44704),
                    unit("kn", .speed, "kn", 0.514444), unit("fts", .speed, "ft/s", 0.3048)]
        }
    }

    private static func unit(_ id: String, _ category: EverydayUnitCategory, _ symbol: String, _ factor: Double) -> EverydayUnit {
        EverydayUnit(id: id, category: category, symbol: symbol, factor: factor)
    }

    /// Base unit for temperature is Celsius, so absolute zero sits at
    /// base == -273.15; solve value * factor + offset == -273.15 per unit.
    private static func absoluteZero(in unit: EverydayUnit) -> Double {
        (-273.15 - unit.offset) / unit.factor
    }

    public static func convert(_ value: Double, from source: EverydayUnit, to target: EverydayUnit) throws -> Double {
        guard source.category == target.category else { throw ToolboxError.invalid("incompatible units") }
        guard value.isFinite else { throw ToolboxError.invalid("unit value") }
        if source.category == .temperature {
            guard value >= absoluteZero(in: source) else { throw ToolboxError.invalid("below absolute zero") }
        }
        let base = value * source.factor + source.offset
        let result = (base - target.offset) / target.factor
        guard result.isFinite, abs(result) <= 1e15 else { throw ToolboxError.limit("unit conversion") }
        return result
    }
}

// MARK: - Ruler calibration
// Physical size is never inferred from the device model or from points: the
// user calibrates against a known real-world length, and the calibration only
// stays valid while the display environment it was measured on is unchanged.

public struct EverydayRulerCalibration: Codable, Equatable, Sendable {
    public var pointsPerMillimeter: Double
    /// The screen's native pixel scale at calibration time (e.g. 2.0, 3.0).
    public var nativeScale: Double
    /// A caller-defined viewport identity (size band, orientation, display).
    public var viewportKey: String
    public var timestamp: Date

    public init(pointsPerMillimeter: Double, nativeScale: Double, viewportKey: String, timestamp: Date = Date()) {
        self.pointsPerMillimeter = pointsPerMillimeter
        self.nativeScale = nativeScale
        self.viewportKey = viewportKey
        self.timestamp = timestamp
    }

    /// A calibration is only reusable on the same display density and a
    /// compatible viewport; moving windows across displays or a meaningful
    /// geometry change invalidates it and forces re-calibration.
    public func isCompatible(nativeScale: Double, viewportKey: String) -> Bool {
        self.nativeScale.isFinite && self.viewportKey == viewportKey && abs(self.nativeScale - nativeScale) < 0.01
    }
}

public enum EverydayRulerGeometry {
    /// Builds a calibration from a known physical length and its measured
    /// on-screen length in points. This is the only sanctioned way to obtain
    /// points-per-millimeter; nothing here assumes a fixed DPI.
    public static func calibrate(knownMillimeters: Double, measuredPoints: Double, nativeScale: Double, viewportKey: String) throws -> EverydayRulerCalibration {
        guard knownMillimeters.isFinite, (0.1...1000).contains(knownMillimeters) else { throw ToolboxError.invalid("reference length") }
        guard measuredPoints.isFinite, measuredPoints > 0, measuredPoints <= 100_000 else { throw ToolboxError.invalid("measured length") }
        guard nativeScale.isFinite, nativeScale > 0 else { throw ToolboxError.invalid("display scale") }
        let value = measuredPoints / knownMillimeters
        guard value.isFinite, value > 0 else { throw ToolboxError.invalid("calibration") }
        return EverydayRulerCalibration(pointsPerMillimeter: value, nativeScale: nativeScale, viewportKey: viewportKey)
    }

    public static func millimeters(for points: Double, using calibration: EverydayRulerCalibration) throws -> Double {
        guard points.isFinite, calibration.pointsPerMillimeter.isFinite, calibration.pointsPerMillimeter > 0 else {
            throw ToolboxError.invalid("calibration")
        }
        let value = points / calibration.pointsPerMillimeter
        guard value.isFinite, value >= 0 else { throw ToolboxError.invalid("calibration") }
        return value
    }

    public static func points(forMillimeters millimeters: Double, using calibration: EverydayRulerCalibration) throws -> Double {
        guard millimeters.isFinite, millimeters >= 0, calibration.pointsPerMillimeter.isFinite, calibration.pointsPerMillimeter > 0 else {
            throw ToolboxError.invalid("calibration")
        }
        let value = millimeters * calibration.pointsPerMillimeter
        guard value.isFinite else { throw ToolboxError.invalid("calibration") }
        return value
    }

    public static func distanceMillimeters(from start: CGPoint, to end: CGPoint, using calibration: EverydayRulerCalibration) throws -> Double {
        let dx = end.x - start.x, dy = end.y - start.y
        guard dx.isFinite, dy.isFinite else { throw ToolboxError.invalid("measurement") }
        return try millimeters(for: (dx * dx + dy * dy).squareRoot(), using: calibration)
    }

    /// Smaller angle between the two rays, reported in degrees within
    /// 0...180. Zero-length or non-finite rays are rejected, never guessed.
    public static func angleDegrees(vertex: CGPoint, first: CGPoint, second: CGPoint) throws -> Double {
        let v1x = first.x - vertex.x, v1y = first.y - vertex.y
        let v2x = second.x - vertex.x, v2y = second.y - vertex.y
        guard v1x.isFinite, v1y.isFinite, v2x.isFinite, v2y.isFinite else { throw ToolboxError.invalid("angle") }
        let length1 = (v1x * v1x + v1y * v1y).squareRoot()
        let length2 = (v2x * v2x + v2y * v2y).squareRoot()
        guard length1 > 1e-6, length2 > 1e-6 else { throw ToolboxError.invalid("angle") }
        var cosine = (v1x * v2x + v1y * v2y) / (length1 * length2)
        // Rounding can leave exact-collinear rays at 1 ± 1e-16; snap so the
        // documented 0...180 range hits its endpoints exactly.
        if cosine > 1 - 1e-12 { cosine = 1 }
        else if cosine < -1 + 1e-12 { cosine = -1 }
        cosine = max(-1, min(1, cosine))
        let degrees = acos(cosine) * 180 / Double.pi
        guard degrees.isFinite else { throw ToolboxError.invalid("angle") }
        return min(180, max(0, degrees))
    }
}

public actor EverydayRulerCalibrationStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> EverydayRulerCalibration? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 65_536 else { throw ToolboxError.limit("ruler calibration") }
        let value: EverydayRulerCalibration
        do { value = try JSONDecoder().decode(EverydayRulerCalibration.self, from: Data(contentsOf: url)) }
        catch { throw ToolboxError.corruptStore }
        guard value.pointsPerMillimeter.isFinite, value.pointsPerMillimeter > 0,
              value.nativeScale.isFinite, value.nativeScale > 0, !value.viewportKey.isEmpty,
              value.timestamp.timeIntervalSince1970.isFinite else { throw ToolboxError.corruptStore }
        return value
    }

    public func save(_ calibration: EverydayRulerCalibration) throws {
        guard calibration.pointsPerMillimeter.isFinite, calibration.pointsPerMillimeter > 0 else {
            throw ToolboxError.invalid("calibration")
        }
        let data = try JSONEncoder().encode(calibration)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
