// SPDX-License-Identifier: MPL-2.0

// Non-destructive video grading for the Mac timeline editor.
//
// Behavior-preserving port of the shipping iPad grading stack
// (`MediaVideoGrade` + `ImageColorBalance`/`MediaHSLSecondary`/
// `ImageColorLUT` + the `MediaNativeColor` extended filter vocabulary,
// v1.8.73). The Mac app target does not link `FloeWorkbench`, so the grade
// model, validation, LUT parsing and the Core Image application order are
// mirrored here with the same constants:
//
//   * tone curve: five ordered normalized control points through CIToneCurve.
//   * color balance: shadow/midtone/highlight RGB shifts baked into a
//     16-sample CIColorCube with luminance preservation, gains × 0.5.
//   * HSL secondary: hue qualifier with circular feathering, independent
//     saturation/lightness ranges, baked into a 32-sample CIColorCube.
//   * 3D LUT: .cube text parser (2...33 samples, optional domains) applied
//     through CIColorMatrix domain normalization + CIColorCube.
//   * built-in filters: the same six supported CIFilter names.
//
// Everything is UI-free and deterministic: the same grade applied to the
// same pixels always produces the same output.

import CoreImage
import FloeCore
import Foundation

// MARK: - Errors

enum MacVideoGradeError: Error, Hashable, LocalizedError {
    case invalidToneCurve
    case invalidBalance
    case invalidSecondary(String)
    case invalidLUT(String)
    case unsupportedFilter(String)
    case conflict(String)

    var errorDescription: String? {
        switch self {
        case .invalidToneCurve:
            return MacGradeStrings.invalidToneCurve
        case .invalidBalance:
            return MacGradeStrings.invalidBalance
        case .invalidSecondary(let detail):
            return String(format: MacGradeStrings.invalidSecondaryFormat, detail)
        case .invalidLUT(let detail):
            return String(format: MacGradeStrings.invalidLUTFormat, detail)
        case .unsupportedFilter(let name):
            return String(format: MacGradeStrings.unsupportedFilterFormat, name)
        case .conflict(let detail):
            return String(format: MacGradeStrings.conflictFormat, detail)
        }
    }
}

// MARK: - Model

/// One normalized control point for the tone curve; mirrors
/// `ImageFreehandStroke.Point` grading usage.
struct MacCurvePoint: Codable, Sendable, Hashable {
    var x: Double
    var y: Double
    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Per-channel RGB shift in -1...1; mirrors `ImageRGBBalance`.
struct MacRGBBalance: Codable, Sendable, Hashable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double = 0, green: Double = 0, blue: Double = 0) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    private enum Keys: String, CodingKey { case red, green, blue }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        red = try c.decodeIfPresent(Double.self, forKey: .red) ?? 0
        green = try c.decodeIfPresent(Double.self, forKey: .green) ?? 0
        blue = try c.decodeIfPresent(Double.self, forKey: .blue) ?? 0
    }
}

/// Tonal-range color balance; mirrors `ImageColorBalance`.
struct MacColorBalance: Codable, Sendable, Hashable {
    var shadows: MacRGBBalance
    var midtones: MacRGBBalance
    var highlights: MacRGBBalance
    var preserveLuminance: Bool

    init(shadows: MacRGBBalance = .init(), midtones: MacRGBBalance = .init(),
         highlights: MacRGBBalance = .init(), preserveLuminance: Bool = true) {
        self.shadows = shadows
        self.midtones = midtones
        self.highlights = highlights
        self.preserveLuminance = preserveLuminance
    }

    private enum Keys: String, CodingKey { case shadows, midtones, highlights, preserveLuminance }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        shadows = try c.decodeIfPresent(MacRGBBalance.self, forKey: .shadows) ?? .init()
        midtones = try c.decodeIfPresent(MacRGBBalance.self, forKey: .midtones) ?? .init()
        highlights = try c.decodeIfPresent(MacRGBBalance.self, forKey: .highlights) ?? .init()
        preserveLuminance = try c.decodeIfPresent(Bool.self, forKey: .preserveLuminance) ?? true
    }
}

/// HSL qualifier and correction; mirrors `MediaHSLSecondary`. Hue distance is
/// circular, so a red qualifier includes both sides of 0 degrees.
/// Saturation/lightness qualify independently.
struct MacHSLSecondary: Codable, Sendable, Hashable {
    var hueCenter: Double
    var hueWidth: Double
    var hueFeather: Double
    var saturationMin: Double
    var saturationMax: Double
    var lightnessMin: Double
    var lightnessMax: Double
    var rangeFeather: Double
    var hueShift: Double
    var saturationScale: Double
    var lightnessShift: Double
    var mix: Double

    init(hueCenter: Double = 0, hueWidth: Double = 25, hueFeather: Double = 15,
         saturationMin: Double = 0.15, saturationMax: Double = 1,
         lightnessMin: Double = 0, lightnessMax: Double = 1, rangeFeather: Double = 0.05,
         hueShift: Double = 0, saturationScale: Double = 1, lightnessShift: Double = 0, mix: Double = 1) {
        self.hueCenter = hueCenter
        self.hueWidth = hueWidth
        self.hueFeather = hueFeather
        self.saturationMin = saturationMin
        self.saturationMax = saturationMax
        self.lightnessMin = lightnessMin
        self.lightnessMax = lightnessMax
        self.rangeFeather = rangeFeather
        self.hueShift = hueShift
        self.saturationScale = saturationScale
        self.lightnessShift = lightnessShift
        self.mix = mix
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case hueCenter, hueWidth, hueFeather, saturationMin, saturationMax
        case lightnessMin, lightnessMax, rangeFeather, hueShift, saturationScale
        case lightnessShift, mix
    }

    init(from decoder: any Decoder) throws {
        try MacCodableFields.check(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        hueCenter = try c.decodeIfPresent(Double.self, forKey: .hueCenter) ?? hueCenter
        hueWidth = try c.decodeIfPresent(Double.self, forKey: .hueWidth) ?? hueWidth
        hueFeather = try c.decodeIfPresent(Double.self, forKey: .hueFeather) ?? hueFeather
        saturationMin = try c.decodeIfPresent(Double.self, forKey: .saturationMin) ?? saturationMin
        saturationMax = try c.decodeIfPresent(Double.self, forKey: .saturationMax) ?? saturationMax
        lightnessMin = try c.decodeIfPresent(Double.self, forKey: .lightnessMin) ?? lightnessMin
        lightnessMax = try c.decodeIfPresent(Double.self, forKey: .lightnessMax) ?? lightnessMax
        rangeFeather = try c.decodeIfPresent(Double.self, forKey: .rangeFeather) ?? rangeFeather
        hueShift = try c.decodeIfPresent(Double.self, forKey: .hueShift) ?? hueShift
        saturationScale = try c.decodeIfPresent(Double.self, forKey: .saturationScale) ?? saturationScale
        lightnessShift = try c.decodeIfPresent(Double.self, forKey: .lightnessShift) ?? lightnessShift
        mix = try c.decodeIfPresent(Double.self, forKey: .mix) ?? mix
    }

    func validate() throws {
        let values = [hueCenter, hueWidth, hueFeather, saturationMin, saturationMax,
                      lightnessMin, lightnessMax, rangeFeather, hueShift, saturationScale,
                      lightnessShift, mix]
        guard values.allSatisfy(\.isFinite), (0...360).contains(hueCenter),
              (0...180).contains(hueWidth), (0...180).contains(hueFeather),
              (0...1).contains(saturationMin), (saturationMin...1).contains(saturationMax),
              (0...1).contains(lightnessMin), (lightnessMin...1).contains(lightnessMax),
              (0...1).contains(rangeFeather), (-180...180).contains(hueShift),
              (0...2).contains(saturationScale), (-1...1).contains(lightnessShift),
              (0...1).contains(mix) else {
            throw MacVideoGradeError.invalidSecondary("HSL qualifier or correction is outside its finite range")
        }
    }

    /// Bakes the qualifier into a 32-sample RGBA cube (red index fastest,
    /// the .cube/CIColorCube convention).
    func cubeData() throws -> Data {
        try validate()
        let size = 32
        var values = [Float]()
        values.reserveCapacity(size * size * size * 4)
        for b in 0..<size {
            try Task.checkCancellation()
            for g in 0..<size {
                for r in 0..<size {
                    let rgb = [Double(r) / 31, Double(g) / 31, Double(b) / 31]
                    let hsl = Self.hsl(rgb)
                    let delta = abs(hsl.0 - hueCenter)
                    let distance = min(delta, 360 - delta)
                    let hueWeight = hueWidth == 180 ? 1 : Self.falloff(distance, edge: hueWidth, feather: hueFeather)
                    let rangeWeight = Self.rangeWeight(hsl.1, lower: saturationMin, upper: saturationMax, feather: rangeFeather)
                        * Self.rangeWeight(hsl.2, lower: lightnessMin, upper: lightnessMax, feather: rangeFeather)
                    let weight = hueWeight * rangeWeight * mix
                    let corrected = Self.rgb(hue: hsl.0 + hueShift,
                                             saturation: min(1, max(0, hsl.1 * saturationScale)),
                                             lightness: min(1, max(0, hsl.2 + lightnessShift)))
                    values += zip(rgb, corrected).map { Float($0 + ($1 - $0) * weight) } + [1]
                }
            }
        }
        return values.withUnsafeBytes { Data($0) }
    }

    private static func smooth(_ t: Double) -> Double {
        let v = min(1, max(0, t))
        return v * v * (3 - 2 * v)
    }

    private static func falloff(_ x: Double, edge: Double, feather: Double) -> Double {
        x <= edge ? 1 : feather > 0 ? 1 - smooth((x - edge) / feather) : 0
    }

    private static func rangeWeight(_ value: Double, lower: Double, upper: Double, feather: Double) -> Double {
        if value < lower { return feather > 0 ? 1 - smooth((lower - value) / feather) : 0 }
        if value > upper { return feather > 0 ? 1 - smooth((value - upper) / feather) : 0 }
        return 1
    }

    private static func hsl(_ rgb: [Double]) -> (Double, Double, Double) {
        let r = rgb[0], g = rgb[1], b = rgb[2]
        let hi = max(r, max(g, b)), lo = min(r, min(g, b))
        let d = hi - lo, l = (hi + lo) / 2
        guard d > 0.000_001 else { return (0, 0, l) }
        let s = d / max(0.000_001, 1 - abs(2 * l - 1))
        var h = hi == r ? (g - b) / d : hi == g ? (b - r) / d + 2 : (r - g) / d + 4
        h = (h * 60).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return (h, s, l)
    }

    private static func rgb(hue: Double, saturation: Double, lightness: Double) -> [Double] {
        var h = hue.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        h /= 60
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - c / 2
        let channels: [Double]
        switch h {
        case ..<1: channels = [c, x, 0]
        case ..<2: channels = [x, c, 0]
        case ..<3: channels = [0, c, x]
        case ..<4: channels = [0, x, c]
        case ..<5: channels = [x, 0, c]
        default: channels = [c, 0, x]
        }
        return channels.map { $0 + m }
    }
}

/// 3D color LUT; mirrors `ImageColorLUT`. Data is native little-endian
/// Float32 RGBA with the red index changing fastest (.cube convention).
struct MacColorLUT: Codable, Sendable, Hashable {
    let dimension: Int
    let rgba: Data
    let domainMin: [Double]
    let domainMax: [Double]

    init(dimension: Int, rgba: Data, domainMin: [Double] = [0, 0, 0], domainMax: [Double] = [1, 1, 1]) throws {
        self.dimension = dimension
        self.rgba = rgba
        self.domainMin = domainMin
        self.domainMax = domainMax
        try validate()
    }

    func validate() throws {
        guard (2...33).contains(dimension), rgba.count == dimension * dimension * dimension * 16,
              domainMin.count == 3, domainMax.count == 3,
              zip(domainMin, domainMax).allSatisfy({ $0.isFinite && $1.isFinite && $0 < $1 && ($1 - $0).isFinite }) else {
            throw MacVideoGradeError.invalidLUT("3D LUT requires 2...33 samples per edge, finite domains and exact Float32 RGBA data")
        }
        try rgba.withUnsafeBytes { bytes in
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let value = bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)
                guard value.isFinite, abs(value) <= 16 else {
                    throw MacVideoGradeError.invalidLUT("LUT has invalid output values")
                }
            }
        }
    }

    /// Parses an Adobe/Resolve .cube text LUT; same grammar and limits as the
    /// iPad `ImageColorLUT.parseCube`.
    static func parseCube(_ text: String) throws -> Self {
        guard text.utf8.count <= 2_097_152 else {
            throw MacVideoGradeError.invalidLUT("LUT text exceeds 2 MiB")
        }
        var dimension: Int?
        var minimum = [0.0, 0, 0]
        var maximum = [1.0, 1, 1]
        var values = [Float]()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if line.isEmpty || line.hasPrefix("TITLE") { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            switch parts[0] {
            case "LUT_3D_SIZE":
                guard dimension == nil, parts.count == 2, let size = Int(parts[1]), (2...33).contains(size) else {
                    throw MacVideoGradeError.invalidLUT("LUT_3D_SIZE must be 2...33")
                }
                dimension = size
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard parts.count == 4 else {
                    throw MacVideoGradeError.invalidLUT("LUT domain needs three values")
                }
                let numbers = parts.dropFirst().compactMap(Double.init)
                guard numbers.count == 3, numbers.allSatisfy(\.isFinite) else {
                    throw MacVideoGradeError.invalidLUT("invalid LUT domain")
                }
                if parts[0] == "DOMAIN_MIN" { minimum = numbers } else { maximum = numbers }
            default:
                guard parts.count == 3, let size = dimension,
                      values.count < size * size * size * 4 else {
                    throw MacVideoGradeError.invalidLUT("unsupported or excess LUT rows")
                }
                let numbers = parts.compactMap(Float.init)
                guard numbers.count == 3, numbers.allSatisfy({ $0.isFinite && abs($0) <= 16 }) else {
                    throw MacVideoGradeError.invalidLUT("invalid LUT sample")
                }
                values += numbers + [1]
            }
        }
        guard let size = dimension, values.count == size * size * size * 4 else {
            throw MacVideoGradeError.invalidLUT("LUT sample count does not match its dimension")
        }
        return try Self(dimension: size, rgba: values.withUnsafeBytes { Data($0) },
                        domainMin: minimum, domainMax: maximum)
    }
}

/// Persistent, non-destructive clip grading. Each inspector updates one
/// field; other grades remain intact and the same value is frozen into
/// export plans. Mirrors `MediaVideoGrade` (without color-match, which has
/// no Mac surface in this round).
struct MacVideoGrade: Codable, Sendable, Hashable {
    var toneCurve: [MacCurvePoint]?
    var colorBalance: MacColorBalance?
    var secondary: MacHSLSecondary?
    var colorLUT: MacColorLUT?
    var filterID: String?
    var lutName: String?

    init(toneCurve: [MacCurvePoint]? = nil, colorBalance: MacColorBalance? = nil,
         secondary: MacHSLSecondary? = nil, colorLUT: MacColorLUT? = nil,
         filterID: String? = nil, lutName: String? = nil) {
        self.toneCurve = toneCurve
        self.colorBalance = colorBalance
        self.secondary = secondary
        self.colorLUT = colorLUT
        self.filterID = filterID
        self.lutName = lutName
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case toneCurve, colorBalance, secondary, colorLUT, filterID, lutName
    }

    init(from decoder: any Decoder) throws {
        try MacCodableFields.check(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toneCurve = try c.decodeIfPresent([MacCurvePoint].self, forKey: .toneCurve)
        colorBalance = try c.decodeIfPresent(MacColorBalance.self, forKey: .colorBalance)
        secondary = try c.decodeIfPresent(MacHSLSecondary.self, forKey: .secondary)
        colorLUT = try c.decodeIfPresent(MacColorLUT.self, forKey: .colorLUT)
        filterID = try c.decodeIfPresent(String.self, forKey: .filterID)
        lutName = try c.decodeIfPresent(String.self, forKey: .lutName)
    }

    var isEmpty: Bool {
        toneCurve == nil && colorBalance == nil && secondary == nil
            && colorLUT == nil && filterID == nil
    }

    /// The six built-in filters, exactly the iPad-supported set.
    static let supportedFilterIDs = [
        "CIPhotoEffectMono", "CIPhotoEffectNoir", "CIPhotoEffectChrome",
        "CIPhotoEffectFade", "CIPhotoEffectInstant", "CISepiaTone",
    ]

    func validate() throws {
        if let curve = toneCurve {
            guard curve.count == 5,
                  curve.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
                  zip(curve, curve.dropFirst()).allSatisfy({ $0.x < $1.x }) else {
                throw MacVideoGradeError.invalidToneCurve
            }
        }
        if let balance = colorBalance {
            for range in [balance.shadows, balance.midtones, balance.highlights] {
                guard [range.red, range.green, range.blue].allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
                    throw MacVideoGradeError.invalidBalance
                }
            }
        }
        try secondary?.validate()
        try colorLUT?.validate()
        guard filterID.map(Self.supportedFilterIDs.contains) ?? true,
              !(filterID != nil && colorLUT != nil),
              lutName.map({ $0.utf8.count <= 256 }) ?? true else {
            throw MacVideoGradeError.conflict("video grade needs one supported filter or one bounded 3D LUT")
        }
    }

    /// Applies the grade in the iPad order: built-in filter, tone curve,
    /// color balance, LUT, then HSL secondary. Deterministic for identical
    /// inputs.
    func apply(to image: CIImage) throws -> CIImage {
        try validate()
        var result = image
        if let filterID, let applied = Self.builtInFilter(named: filterID, image: result) {
            result = applied
        }
        if let curve = toneCurve {
            var parameters: [String: Any] = [:]
            for (index, point) in curve.enumerated() {
                parameters["inputPoint\(index)"] = CIVector(x: point.x, y: point.y)
            }
            result = result.applyingFilter("CIToneCurve", parameters: parameters)
        }
        if let balance = colorBalance {
            let lut = try Self.balanceLUT(balance)
            result = result.applyingFilter("CIColorCube",
                                           parameters: ["inputCubeDimension": lut.dimension, "inputCubeData": lut.rgba])
        }
        if let lut = colorLUT {
            let spans = zip(lut.domainMin, lut.domainMax).map { $1 - $0 }
            result = result.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 / spans[0], y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 / spans[1], z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 / spans[2], w: 0),
                "inputBiasVector": CIVector(x: -lut.domainMin[0] / spans[0],
                                            y: -lut.domainMin[1] / spans[1],
                                            z: -lut.domainMin[2] / spans[2], w: 0),
            ])
            result = result.applyingFilter("CIColorCube",
                                           parameters: ["inputCubeDimension": lut.dimension, "inputCubeData": lut.rgba])
        }
        if let secondary {
            let cube = try secondary.cubeData()
            result = result.applyingFilter("CIColorCube",
                                           parameters: ["inputCubeDimension": 32, "inputCubeData": cube])
        }
        return result.cropped(to: image.extent)
    }

    private static func builtInFilter(named name: String, image: CIImage) -> CIImage? {
        guard supportedFilterIDs.contains(name), let filter = CIFilter(name: name) else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage
    }

    /// Bakes a tonal-range balance into a 16-sample cube with the iPad
    /// weighting: shadow (1-l)², highlight l², midtone remainder, channel
    /// gains × 0.5 and optional luminance preservation.
    static func balanceLUT(_ settings: MacColorBalance) throws -> MacColorLUT {
        let size = 16
        var values = [Float]()
        values.reserveCapacity(size * size * size * 4)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let rgb = [Double(r), Double(g), Double(b)].map { $0 / Double(size - 1) }
                    let l = rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
                    let shadow = (1 - l) * (1 - l)
                    let highlight = l * l
                    let mid = max(0, 1 - shadow - highlight)
                    let shifts = [settings.shadows, settings.midtones, settings.highlights]
                    let weights = [shadow, mid, highlight]
                    var output = rgb
                    for i in 0..<3 {
                        let channels = shifts.map { i == 0 ? $0.red : i == 1 ? $0.green : $0.blue }
                        output[i] += zip(channels, weights).reduce(0) { $0 + $1.0 * $1.1 } * 0.5
                    }
                    if settings.preserveLuminance {
                        let difference = l - (output[0] * 0.2126 + output[1] * 0.7152 + output[2] * 0.0722)
                        output = output.map { $0 + difference }
                    }
                    values += output.map { Float(min(1, max(0, $0))) } + [1]
                }
            }
        }
        return try MacColorLUT(dimension: size, rgba: values.withUnsafeBytes { Data($0) })
    }
}

// MARK: - Bilingual strings

enum MacGradeStrings {
    static var invalidToneCurve: String {
        t(en: "The tone curve needs five ordered control points inside the unit square.",
           zh: "色调曲线需要五个位于单位正方形内的有序控制点。")
    }
    static var invalidBalance: String {
        t(en: "Color balance channels must be between -1 and 1.", zh: "色彩平衡通道必须在 -1 到 1 之间。")
    }
    static var invalidSecondaryFormat: String { t(en: "HSL adjustment is invalid: %@.", zh: "HSL 调整无效：%@。") }
    static var invalidLUTFormat: String { t(en: "The 3D LUT is invalid: %@.", zh: "3D LUT 无效：%@。") }
    static var unsupportedFilterFormat: String {
        t(en: "The filter %@ is not supported.", zh: "不支持滤镜 %@。")
    }
    static var conflictFormat: String { t(en: "The grade is conflicting: %@.", zh: "调色设置冲突：%@。") }

    private static func t(en: String, zh: String) -> String {
        FloeL10n.isChinese ? zh : en
    }
}
