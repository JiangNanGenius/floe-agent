// SPDX-License-Identifier: MPL-2.0
import Foundation

nonisolated struct CADSpurGearSpec: Codable, Equatable, Sendable {
    static let supportedVersion = 1
    enum Basis: String, Codable, Equatable, Sendable { case cqSpur20FullDepthBezierV1 }
    var version = Self.supportedVersion
    var basis: Basis = .cqSpur20FullDepthBezierV1
    var module = Expr(value: 2)
    var teeth = 20
    var width = Expr(value: 8)
    var boreDiameter = Expr(value: 10)
    /// Maximum involute-flank deviation in mm; the circular root is a separate
    /// explicit construction. This is not a manufacturing quality class.
    var maximumDeviation = Expr(value: 0.001)
    var pressureRadians: Double { 20 * .pi / 180 }
    var pitchRadius: Double { module.value * Double(teeth) / 2 }
    var baseRadius: Double { pitchRadius * cos(pressureRadians) }
    var tipRadius: Double { pitchRadius + module.value }
    var rootRadius: Double { pitchRadius - 1.25 * module.value }
    var pitchToothThickness: Double { module.value * .pi / 2 }
    func validate() throws {
        guard version == Self.supportedVersion else { throw CADMechanicalFailure.invalid("Unsupported spur gear semantic version.") }
        guard teeth >= 18 else {
            throw CADMechanicalFailure.invalid("This 20° full-depth spur profile requires at least 18 teeth to avoid unmodelled rack undercut.")
        }
        guard teeth <= 160, module.value.isFinite, (0.5...20).contains(module.value),
              width.value.isFinite, (0.5...200).contains(width.value),
              boreDiameter.value.isFinite, boreDiameter.value >= 0,
              boreDiameter.value / 2 <= rootRadius - module.value,
              maximumDeviation.value.isFinite, (0.00001...0.01).contains(maximumDeviation.value),
              maximumDeviation.value <= module.value * 0.01 else {
            throw CADMechanicalFailure.invalid("Use 18–160 teeth, module 0.5–20 mm, width 0.5–200 mm, at least one module of rim outside the bore, and profile tolerance 0.00001–0.01 mm (up to 1% of module).")
        }
    }
    var expressions: [DocumentSession.FeatureExpressionSlot] {
        [("module",module),("width",width),("bore_diameter",boreDiameter),("maximum_deviation",maximumDeviation)].map {
            DocumentSession.FeatureExpressionSlot(name:$0.0,unit:"mm",storedUnit:"mm",expr:$0.1)
        }
    }
    func replacing(_ key: String, with value: Expr) -> CADSpurGearSpec? {
        var result = self
        switch key {
        case "module": result.module = value
        case "width": result.width = value
        case "bore_diameter": result.boreDiameter = value
        case "maximum_deviation": result.maximumDeviation = value
        default: return nil
        }
        return result
    }
}
