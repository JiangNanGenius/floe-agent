// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A raw field observation, retained separately from any prediction.
///
/// Device, band, position/orientation and measurement conditions are stored with the
/// raw power so a later calibration can be audited without rewriting the observation.
/// Values are plain Codable value types; adopting a calibration never mutates them.
public struct RadioFieldMeasurement: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var deviceModel: String
    public var deviceIdentifier: String
    public var band: RadioBand
    public var positionM: RadioPoint3D
    public var orientationDegrees: Double
    public var conditions: String
    public var rawReceivedPowerDBm: Double
    public var measuredAtISO8601: String
    public init(id: String, deviceModel: String, deviceIdentifier: String,
                band: RadioBand, positionM: RadioPoint3D,
                orientationDegrees: Double, conditions: String,
                rawReceivedPowerDBm: Double, measuredAtISO8601: String) {
        self.id = id
        self.deviceModel = deviceModel
        self.deviceIdentifier = deviceIdentifier
        self.band = band
        self.positionM = positionM
        self.orientationDegrees = orientationDegrees
        self.conditions = conditions
        self.rawReceivedPowerDBm = rawReceivedPowerDBm
        self.measuredAtISO8601 = measuredAtISO8601
    }
    func validate() throws {
        guard !id.isEmpty else { throw RadioEstimateError.invalidInput("measurement id") }
        guard !deviceModel.isEmpty, !deviceIdentifier.isEmpty else {
            throw RadioEstimateError.invalidInput("measurement device")
        }
        try band.validate()
        try positionM.validate("measurement position")
        guard orientationDegrees.isFinite else {
            throw RadioEstimateError.invalidInput("measurement orientation")
        }
        guard !conditions.isEmpty else {
            throw RadioEstimateError.invalidInput("measurement conditions")
        }
        guard rawReceivedPowerDBm.isFinite else {
            throw RadioEstimateError.invalidInput("measurement power")
        }
        guard !measuredAtISO8601.isEmpty else {
            throw RadioEstimateError.invalidInput("measurement date")
        }
    }
}

/// An adopted, versioned correction to the prediction model for one band.
///
/// This record contains no AP configuration, no deployment command and no live-device
/// control. It only names the raw observations used as evidence and the additive
/// correction (positive means the model under-predicted measured power). The source
/// observations stay in their own records and are never overwritten by adoption.
public struct RadioCalibration: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var version: Int
    public var band: RadioBand
    public var correctionDB: Double
    public var sourceMeasurementIDs: [String]
    public var method: String
    public var adoptedAtISO8601: String
    public init(id: String, version: Int, band: RadioBand,
                correctionDB: Double, sourceMeasurementIDs: [String],
                method: String, adoptedAtISO8601: String) {
        self.id = id
        self.version = version
        self.band = band
        self.correctionDB = correctionDB
        self.sourceMeasurementIDs = sourceMeasurementIDs
        self.method = method
        self.adoptedAtISO8601 = adoptedAtISO8601
    }

    func validate() throws {
        guard !id.isEmpty else { throw RadioEstimateError.invalidInput("calibration id") }
        guard version >= 1 else { throw RadioEstimateError.invalidInput("calibration version") }
        try band.validate()
        guard correctionDB.isFinite else {
            throw RadioEstimateError.invalidInput("calibration correction")
        }
        guard !sourceMeasurementIDs.isEmpty,
              sourceMeasurementIDs.allSatisfy({ !$0.isEmpty }),
              Set(sourceMeasurementIDs).count == sourceMeasurementIDs.count else {
            throw RadioEstimateError.invalidInput("calibration measurements")
        }
        guard !method.isEmpty else { throw RadioEstimateError.invalidInput("calibration method") }
        guard !adoptedAtISO8601.isEmpty else {
            throw RadioEstimateError.invalidInput("calibration adoption date")
        }
    }

    /// Creates an adopted correction only from measurements that actually match the
    /// calibration band. The input observations are validated and referenced, not
    /// modified.
    public static func adopt(id: String, version: Int, band: RadioBand,
                             correctionDB: Double,
                             measurements: [RadioFieldMeasurement],
                             method: String,
                             adoptedAtISO8601: String) throws -> RadioCalibration {
        guard !measurements.isEmpty else {
            throw RadioEstimateError.invalidInput("calibration measurements")
        }
        var seen = Set<String>()
        for measurement in measurements {
            try measurement.validate()
            guard seen.insert(measurement.id).inserted else {
                throw RadioEstimateError.invalidInput("duplicate measurement id")
            }
            guard measurement.band == band else {
                throw RadioEstimateError.invalidInput("calibration measurement band")
            }
        }
        let calibration = RadioCalibration(
            id: id, version: version, band: band, correctionDB: correctionDB,
            sourceMeasurementIDs: measurements.map(\.id), method: method,
            adoptedAtISO8601: adoptedAtISO8601)
        try calibration.validate()
        return calibration
    }
}
