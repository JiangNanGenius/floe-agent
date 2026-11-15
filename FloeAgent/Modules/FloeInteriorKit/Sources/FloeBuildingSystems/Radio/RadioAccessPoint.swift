// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Whether a reference power came from a measurement record or a model/datasheet.
public enum RadioReferencePowerBasis: String, Codable, Equatable, Sendable {
    case measured
    case model
}

/// Received power at a declared reference distance for one band.
///
/// `sourceID` identifies the measurement record, datasheet or model statement used to
/// obtain the value. It must be present; the quick estimator never invents a reference
/// power for an AP whose transmit conditions are unknown.
public struct RadioReferencePower: Codable, Equatable, Sendable {
    public var dBm: Double
    public var basis: RadioReferencePowerBasis
    public var sourceID: String
    public init(dBm: Double, basis: RadioReferencePowerBasis, sourceID: String) {
        self.dBm = dBm
        self.basis = basis
        self.sourceID = sourceID
    }
    func validate() throws {
        guard dBm.isFinite else { throw RadioEstimateError.invalidInput("reference power") }
        guard !sourceID.isEmpty else { throw RadioEstimateError.invalidInput("reference source") }
    }
}

/// Supported antenna pattern assumption.
///
/// The quick estimate currently accepts only an omnidirectional pattern. Directional
/// patterns are not approximated: adding one without an actual pattern model would
/// turn an unknown into a plausible-looking result.
public enum RadioAntennaPattern: String, Codable, Equatable, Sendable {
    case omnidirectional
}

/// AP antenna record used by the estimate.
///
/// `peakGainDBi` is recorded for traceability. The supplied reference power is expected
/// to already include the actual transmit power, gain and cable assumptions at the
/// reference distance; the estimator does not add the gain a second time.
public struct RadioAntennaAssumption: Codable, Equatable, Sendable {
    public var modelID: String
    public var peakGainDBi: Double
    public var pattern: RadioAntennaPattern
    public init(modelID: String, peakGainDBi: Double, pattern: RadioAntennaPattern) {
        self.modelID = modelID
        self.peakGainDBi = peakGainDBi
        self.pattern = pattern
    }
    func validate() throws {
        guard !modelID.isEmpty else { throw RadioEstimateError.invalidInput("antenna model") }
        guard peakGainDBi.isFinite else { throw RadioEstimateError.invalidInput("antenna gain") }
    }
}

/// One access point placed in the same metre-based project coordinates as the walls.
public struct RadioAccessPoint: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var band: RadioBand
    public var positionM: RadioPoint3D
    public var referencePower: RadioReferencePower
    public var antenna: RadioAntennaAssumption
    public init(id: String, band: RadioBand, positionM: RadioPoint3D,
                referencePower: RadioReferencePower,
                antenna: RadioAntennaAssumption) {
        self.id = id
        self.band = band
        self.positionM = positionM
        self.referencePower = referencePower
        self.antenna = antenna
    }
    func validate(expectedBand: RadioBand) throws {
        guard !id.isEmpty else { throw RadioEstimateError.invalidInput("access point id") }
        try band.validate()
        guard band == expectedBand else {
            throw RadioEstimateError.invalidInput("access point band")
        }
        try positionM.validate("access point position")
        try referencePower.validate()
        try antenna.validate()
    }
}
