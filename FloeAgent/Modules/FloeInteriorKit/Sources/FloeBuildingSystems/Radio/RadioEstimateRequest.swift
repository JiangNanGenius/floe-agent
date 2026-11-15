// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A finite receiver plane and grid, in metres.
///
/// `originM` is one corner; `right` and `up` are non-parallel directions. Grid points
/// are placed inclusively from one edge to the other. A one-cell axis is valid and
/// positions that row/column at the origin edge; otherwise width and height must be
/// positive. One request covers one plane and one band; per-floor/per-band maps are
/// composed from separate requests with the same project revision.
public struct RadioReceiverPlane: Codable, Equatable, Sendable {
    public var originM: RadioPoint3D
    public var right: RadioPoint3D
    public var up: RadioPoint3D
    public var widthM: Double
    public var heightM: Double
    public var columns: Int
    public var rows: Int
    public init(originM: RadioPoint3D, right: RadioPoint3D, up: RadioPoint3D,
                widthM: Double, heightM: Double, columns: Int, rows: Int) {
        self.originM = originM
        self.right = right
        self.up = up
        self.widthM = widthM
        self.heightM = heightM
        self.columns = columns
        self.rows = rows
    }

    func validate() throws -> (right: RadioPoint3D, up: RadioPoint3D) {
        try originM.validate("receiver plane origin")
        let rightDirection = try right.normalized()
        let upDirection = try up.normalized()
        guard abs(rightDirection.dot(upDirection)) < 1e-8 else {
            throw RadioEstimateError.invalidInput("receiver plane axes")
        }
        guard widthM.isFinite, widthM >= 0, widthM <= 1000,
              heightM.isFinite, heightM >= 0, heightM <= 1000 else {
            throw RadioEstimateError.invalidInput("receiver plane size")
        }
        guard columns >= 1, rows >= 1, columns <= 100_000, rows <= 100_000 else {
            throw RadioEstimateError.invalidInput("receiver plane grid")
        }
        guard columns == 1 || widthM > 0 else {
            throw RadioEstimateError.invalidInput("receiver plane size")
        }
        guard rows == 1 || heightM > 0 else {
            throw RadioEstimateError.invalidInput("receiver plane size")
        }
        return (rightDirection, upDirection)
    }
}

/// Explicit assumptions for the quick log-distance model.
///
/// At the reference distance the estimated power equals the AP's supplied reference
/// power (minus wall attenuation). Beyond it the loss grows by
/// `10 * pathLossExponent * log10(distance / referenceDistance)`. No exponent,
/// reference distance or evidence identifier is defaulted by the estimator; these are
/// caller-owned engineering assumptions and are echoed in every result.
public struct RadioPropagationAssumptions: Codable, Equatable, Sendable {
    public var referenceDistanceM: Double
    public var pathLossExponent: Double
    public var evidenceID: String
    public init(referenceDistanceM: Double, pathLossExponent: Double, evidenceID: String) {
        self.referenceDistanceM = referenceDistanceM
        self.pathLossExponent = pathLossExponent
        self.evidenceID = evidenceID
    }
    func validate() throws {
        guard referenceDistanceM.isFinite, referenceDistanceM > 0 else {
            throw RadioEstimateError.invalidInput("reference distance")
        }
        guard pathLossExponent.isFinite, pathLossExponent > 0 else {
            throw RadioEstimateError.invalidInput("path loss exponent")
        }
        guard !evidenceID.isEmpty else {
            throw RadioEstimateError.invalidInput("assumption evidence")
        }
    }
}

/// Complete input snapshot for one quick-estimate run.
///
/// `projectRevision` binds the estimate to the project state. `adoptedCalibration` is
/// optional; when present it must match the request band and is reported separately
/// from the raw field observations. The fingerprint covers every field in this request
/// (including the calibration) so dependent changes can mark a result stale.
public struct RadioEstimateRequest: Codable, Equatable, Sendable {
    public var projectRevision: Int
    public var band: RadioBand
    public var accessPoints: [RadioAccessPoint]
    public var walls: [RadioWall]
    public var receiverPlane: RadioReceiverPlane
    public var assumptions: RadioPropagationAssumptions
    public var adoptedCalibration: RadioCalibration?
    public init(projectRevision: Int, band: RadioBand,
                accessPoints: [RadioAccessPoint], walls: [RadioWall],
                receiverPlane: RadioReceiverPlane,
                assumptions: RadioPropagationAssumptions,
                adoptedCalibration: RadioCalibration? = nil) {
        self.projectRevision = projectRevision
        self.band = band
        self.accessPoints = accessPoints
        self.walls = walls
        self.receiverPlane = receiverPlane
        self.assumptions = assumptions
        self.adoptedCalibration = adoptedCalibration
    }
    public func fingerprint() throws -> String { try RadioFingerprint.hash(self) }
}
