// M13: ISO 68-1:2023 BASIC profile only. No ISO 965 fit/tolerance claim.
// Basic-profile formulae: ISO 68-1:2023, clause 5 / figure 1, public preview.
// Reviewed diameter/pitch subset: NBK, ISO General Purpose Metric Screw
// Threads, basic dimensions (JIS B 0205-2/4). Numeric facts transcribed here;
// no third-party code, CSV, diagrams or standard text are redistributed.
import Foundation

nonisolated enum CADThreadError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(v): return "Unsupported thread semantic version \(v)."
        case let .invalid(message): return message
        }
    }
}

nonisolated struct ThreadSpec: Codable, Equatable, Sendable {
    static let supportedVersion = 1
    enum Standard: String, Codable, CaseIterable, Hashable, Sendable { case isoMetricBasic2023 }
    enum Side: String, Codable, CaseIterable, Hashable, Sendable { case external, `internal` }
    enum Hand: String, Codable, CaseIterable, Hashable, Sendable { case right, left }
    enum Representation: String, Codable, CaseIterable, Hashable, Sendable { case geometry, schematic }
    enum Ends: String, Codable, CaseIterable, Hashable, Sendable { case flatTrim, onePitchSetback }

    var version = ThreadSpec.supportedVersion
    var standard: Standard = .isoMetricBasic2023
    var side: Side
    var diameter: Double
    var pitch: Expr
    var hand: Hand = .right
    var effectiveLength: Expr
    var ends: Ends = .flatTrim
    var representation: Representation = .geometry
    /// Stable input identity, frozen to the successful input writer.
    var source: FaceRef
    var sourceVersion: GeometryVersionRef
    /// A physical azimuth, not a favorable kernel-fixture phase.
    var phaseRadians: Double = 0

    private enum CodingKeys: String, CodingKey {
        case version, standard, side, diameter, pitch, hand, effectiveLength
        case ends, representation, source, sourceVersion, phaseRadians
    }
    init(side: Side, diameter: Double, pitch: Expr, hand: Hand = .right,
         effectiveLength: Expr, ends: Ends = .flatTrim,
         representation: Representation = .geometry, source: FaceRef,
         sourceVersion: GeometryVersionRef, phaseRadians: Double = 0) {
        self.side = side; self.diameter = diameter; self.pitch = pitch; self.hand = hand
        self.effectiveLength = effectiveLength; self.ends = ends; self.representation = representation
        self.source = source; self.sourceVersion = sourceVersion; self.phaseRadians = phaseRadians
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int.self, forKey: .version)
        guard v == Self.supportedVersion else { throw CADThreadError.unsupportedVersion(v) }
        version = v
        standard = try c.decode(Standard.self, forKey: .standard)
        side = try c.decode(Side.self, forKey: .side)
        diameter = try c.decode(Double.self, forKey: .diameter)
        pitch = try c.decode(Expr.self, forKey: .pitch)
        hand = try c.decode(Hand.self, forKey: .hand)
        effectiveLength = try c.decode(Expr.self, forKey: .effectiveLength)
        ends = try c.decode(Ends.self, forKey: .ends)
        representation = try c.decode(Representation.self, forKey: .representation)
        source = try c.decode(FaceRef.self, forKey: .source)
        sourceVersion = try c.decode(GeometryVersionRef.self, forKey: .sourceVersion)
        phaseRadians = try c.decode(Double.self, forKey: .phaseRadians)
        try validate()
    }
    func validate() throws {
        guard version == Self.supportedVersion else { throw CADThreadError.unsupportedVersion(version) }
        guard ThreadCatalog.pitches(for: diameter).contains(where: { abs($0 - pitch.value) < 1e-9 }),
              effectiveLength.value.isFinite, effectiveLength.value >= 2 * pitch.value,
              effectiveLength.value / pitch.value <= 32, effectiveLength.value <= 100,
              phaseRadians.isFinite, abs(phaseRadians) <= 2 * Double.pi,
              source.body.bodyID == sourceVersion.bodyID,
              let name = source.elementName, name.isStableFaceIdentity else {
            throw CADThreadError.invalid("Choose a supported metric size/pitch, a length of 2–32 pitches (up to 100 mm), and a current named cylindrical source.")
        }
        if case .kernelFace = name.source {
            throw CADThreadError.invalid("A thread source requires a stable face identity, not a positional index.")
        }
    }
    func resolved(variables: [String: Double]) throws -> ThreadSpec {
        var result = self
        for key in ["pitch", "effective_length"] {
            var e = key == "pitch" ? pitch : effectiveLength
            if let formula = e.formula {
                guard let value = ExpressionEvaluator.evaluate(formula, variables: variables), value.isFinite else {
                    throw CADThreadError.invalid("The thread expression cannot be resolved.")
                }
                e.value = value
            }
            if key == "pitch" { result.pitch = e } else { result.effectiveLength = e }
        }
        try result.validate()
        return result
    }
    var designation: String { String(format: "M%.0f × %.3g", diameter, pitch.value) }
    var basicHeight: Double { 5 * sqrt(3) * pitch.value / 16 }
    var majorRadius: Double { diameter / 2 }
    var minorRadius: Double { majorRadius - basicHeight }
    var pitchDiameter: Double { diameter - 3 * sqrt(3) * pitch.value / 8 }
}

nonisolated enum ThreadCatalog {
    static let diameters: [Double] = [3, 4, 5, 6, 8, 10, 12]
    static func pitches(for diameter: Double) -> [Double] {
        switch diameter {
        case 3: return [0.5, 0.35]
        case 4: return [0.7, 0.5]
        case 5: return [0.8, 0.5]
        case 6: return [1, 0.75]
        case 8: return [1.25, 1, 0.75]
        case 10: return [1.5, 1.25, 1]
        case 12: return [1.75, 1.5, 1.25, 1]
        default: return []
        }
    }
}
