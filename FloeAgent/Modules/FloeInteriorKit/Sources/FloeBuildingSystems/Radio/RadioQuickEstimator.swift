// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Evidence class carried by radio results. The quick estimator only emits
/// `modelEstimate` or `calibratedModel`; it never labels output as measured or as a
/// detailed propagation computation.
public enum RadioEvidenceClass: String, Codable, Equatable, Sendable {
    case modelEstimate = "MODEL_ESTIMATE"
    case rayComputation = "RAY_COMPUTATION"
    case fieldMeasurement = "FIELD_MEASUREMENT"
    case calibratedModel = "CALIBRATED_MODEL"
}

/// One AP's estimated power at a receiver sample.
public struct RadioAccessPointEstimate: Codable, Equatable, Sendable {
    public var accessPointID: String
    public var estimatedReceivedPowerDBm: Double
    public var referencePowerBasis: RadioReferencePowerBasis
    public var referenceSourceID: String
    public var estimatedWallLossDB: Double
    public var crossedWallIDs: [String]
    public init(accessPointID: String, estimatedReceivedPowerDBm: Double,
                referencePowerBasis: RadioReferencePowerBasis,
                referenceSourceID: String, estimatedWallLossDB: Double,
                crossedWallIDs: [String]) {
        self.accessPointID = accessPointID
        self.estimatedReceivedPowerDBm = estimatedReceivedPowerDBm
        self.referencePowerBasis = referencePowerBasis
        self.referenceSourceID = referenceSourceID
        self.estimatedWallLossDB = estimatedWallLossDB
        self.crossedWallIDs = crossedWallIDs
    }
}

/// All AP powers plus the strongest AP for one receiver position.
///
/// The strongest selection is deterministic (highest power, then lexicographically
/// smaller AP identifier on a tie). Powers are estimates, not measured RSSI.
public struct RadioEstimateSample: Codable, Equatable, Sendable {
    public var positionM: RadioPoint3D
    public var perAccessPoint: [RadioAccessPointEstimate]
    public var strongestAccessPointID: String
    public var strongestEstimatedPowerDBm: Double
    public init(positionM: RadioPoint3D,
                perAccessPoint: [RadioAccessPointEstimate],
                strongestAccessPointID: String,
                strongestEstimatedPowerDBm: Double) {
        self.positionM = positionM
        self.perAccessPoint = perAccessPoint
        self.strongestAccessPointID = strongestAccessPointID
        self.strongestEstimatedPowerDBm = strongestEstimatedPowerDBm
    }
}

/// A complete, Codable quick-estimate snapshot.
///
/// `label` is always `"ESTIMATE"` for this solver. The result records the input
/// fingerprint, model identifier, solver version, explicit assumptions and calibration
/// version so a later project change can be detected with `isStale(for:)`.
public struct RadioEstimateResult: Codable, Equatable, Sendable {
    public var label: String
    public var evidenceClass: RadioEvidenceClass
    public var modelIdentifier: String
    public var solverVersion: Int
    public var inputFingerprint: String
    public var projectRevision: Int
    public var band: RadioBand
    public var assumptions: RadioPropagationAssumptions
    public var columns: Int
    public var rows: Int
    public var samples: [RadioEstimateSample]
    public var minimumEstimatedPowerDBm: Double
    public var maximumEstimatedPowerDBm: Double
    public var calibrationID: String?
    public var calibrationVersion: Int?
    public var limitations: [String]
    public init(label: String, evidenceClass: RadioEvidenceClass,
                modelIdentifier: String, solverVersion: Int,
                inputFingerprint: String, projectRevision: Int,
                band: RadioBand, assumptions: RadioPropagationAssumptions,
                columns: Int, rows: Int, samples: [RadioEstimateSample],
                minimumEstimatedPowerDBm: Double,
                maximumEstimatedPowerDBm: Double,
                calibrationID: String?, calibrationVersion: Int?,
                limitations: [String]) {
        self.label = label
        self.evidenceClass = evidenceClass
        self.modelIdentifier = modelIdentifier
        self.solverVersion = solverVersion
        self.inputFingerprint = inputFingerprint
        self.projectRevision = projectRevision
        self.band = band
        self.assumptions = assumptions
        self.columns = columns
        self.rows = rows
        self.samples = samples
        self.minimumEstimatedPowerDBm = minimumEstimatedPowerDBm
        self.maximumEstimatedPowerDBm = maximumEstimatedPowerDBm
        self.calibrationID = calibrationID
        self.calibrationVersion = calibrationVersion
        self.limitations = limitations
    }
    public func isStale(for request: RadioEstimateRequest) throws -> Bool {
        inputFingerprint != (try request.fingerprint())
    }
}

/// Pure Swift quick-estimate solver.
///
/// This is deliberately a log-distance reference-loss estimate plus explicit wall
/// attenuation counts. It is not ray tracing, does not use measured RSSI as an input,
/// and has no Sionna/engine dependency. Every unknown material/band pair that affects a
/// ray throws `RadioEstimateError.needsInput` rather than using a default.
///
/// Budget checks run before the sample array is allocated. Cancellation is checked
/// before work and at every receiver cell. Results are safe to persist and compare by
/// fingerprint; a changed wall, AP, calibration, grid or revision makes the result stale.
public enum RadioQuickEstimator: Sendable {
    public static let modelIdentifier = "radio-log-distance-reference-wall-v1"
    public static let solverVersion = 1
    public static let estimateLabel = "ESTIMATE"

    public static func estimate(_ request: RadioEstimateRequest,
                                maximumCells: Int = 250_000,
                                maximumWallChecks: Int = 50_000_000,
                                cancelled: () -> Bool = { false }) throws -> RadioEstimateResult {
        guard request.projectRevision >= 0 else {
            throw RadioEstimateError.invalidInput("project revision")
        }
        try request.band.validate()
        try request.assumptions.validate()
        let plane = try request.receiverPlane.validate()
        guard !request.accessPoints.isEmpty, request.accessPoints.count <= 64 else {
            throw RadioEstimateError.invalidInput("access points")
        }
        guard request.walls.count <= 4096 else {
            throw RadioEstimateError.invalidInput("walls")
        }

        var accessPointIDs = Set<String>()
        for accessPoint in request.accessPoints {
            try accessPoint.validate(expectedBand: request.band)
            guard accessPointIDs.insert(accessPoint.id).inserted else {
                throw RadioEstimateError.invalidInput("duplicate access point id")
            }
        }
        var wallIDs = Set<String>()
        for wall in request.walls {
            try wall.validate()
            guard wallIDs.insert(wall.id).inserted else {
                throw RadioEstimateError.invalidInput("duplicate wall id")
            }
        }
        if let calibration = request.adoptedCalibration {
            try calibration.validate()
            guard calibration.band == request.band else {
                throw RadioEstimateError.invalidInput("calibration band")
            }
        }

        guard maximumCells > 0 else {
            throw RadioEstimateError.invalidInput("cell budget")
        }
        guard maximumWallChecks > 0 else {
            throw RadioEstimateError.invalidInput("wall-check budget")
        }
        let columns = request.receiverPlane.columns
        let rows = request.receiverPlane.rows
        let (cellCount, cellOverflow) = columns.multipliedReportingOverflow(by: rows)
        guard !cellOverflow else { throw RadioEstimateError.budgetExceeded(Int.max) }
        guard cellCount <= maximumCells else {
            throw RadioEstimateError.budgetExceeded(cellCount)
        }
        if !request.walls.isEmpty {
            let checksPerCell = request.accessPoints.count * request.walls.count
            let (work, workOverflow) = cellCount.multipliedReportingOverflow(by: checksPerCell)
            guard !workOverflow, work <= maximumWallChecks else {
                throw RadioEstimateError.budgetExceeded(workOverflow ? Int.max : work)
            }
        }

        if cancelled() { throw RadioEstimateError.cancelled }
        let calibrationCorrectionDB = request.adoptedCalibration?.correctionDB ?? 0
        var samples: [RadioEstimateSample] = []
        samples.reserveCapacity(cellCount)
        for row in 0..<rows {
            for column in 0..<columns {
                if cancelled() { throw RadioEstimateError.cancelled }
                let rightOffset = columns == 1
                    ? 0
                    : request.receiverPlane.widthM * Double(column) / Double(columns - 1)
                let upOffset = rows == 1
                    ? 0
                    : request.receiverPlane.heightM * Double(row) / Double(rows - 1)
                let point = request.receiverPlane.originM
                    + plane.right * rightOffset
                    + plane.up * upOffset
                guard point.isFinite else {
                    throw RadioEstimateError.invalidInput("receiver point")
                }

                var perAccessPoint: [RadioAccessPointEstimate] = []
                perAccessPoint.reserveCapacity(request.accessPoints.count)
                for accessPoint in request.accessPoints {
                    let distance = point.distance(to: accessPoint.positionM)
                    let effectiveDistance = max(distance, request.assumptions.referenceDistanceM)
                    let pathLossDB = 10 * request.assumptions.pathLossExponent
                        * log10(effectiveDistance / request.assumptions.referenceDistanceM)
                    var wallLossDB = 0.0
                    var crossedWallIDs: [String] = []
                    for wall in request.walls {
                        guard wall.crossingFraction(from: accessPoint.positionM, to: point) != nil else {
                            continue
                        }
                        wallLossDB += try wall.attenuationDB(for: request.band)
                        crossedWallIDs.append(wall.id)
                    }
                    let receivedPowerDBm = accessPoint.referencePower.dBm
                        - pathLossDB - wallLossDB + calibrationCorrectionDB
                    guard receivedPowerDBm.isFinite, pathLossDB.isFinite, wallLossDB.isFinite else {
                        throw RadioEstimateError.invalidInput("estimated received power")
                    }
                    perAccessPoint.append(RadioAccessPointEstimate(
                        accessPointID: accessPoint.id,
                        estimatedReceivedPowerDBm: receivedPowerDBm,
                        referencePowerBasis: accessPoint.referencePower.basis,
                        referenceSourceID: accessPoint.referencePower.sourceID,
                        estimatedWallLossDB: wallLossDB,
                        crossedWallIDs: crossedWallIDs))
                }
                guard let first = perAccessPoint.first else {
                    throw RadioEstimateError.invalidInput("access points")
                }
                var strongest = first
                for estimate in perAccessPoint.dropFirst() {
                    if estimate.estimatedReceivedPowerDBm > strongest.estimatedReceivedPowerDBm
                        || (estimate.estimatedReceivedPowerDBm == strongest.estimatedReceivedPowerDBm
                            && estimate.accessPointID < strongest.accessPointID) {
                        strongest = estimate
                    }
                }
                samples.append(RadioEstimateSample(
                    positionM: point,
                    perAccessPoint: perAccessPoint,
                    strongestAccessPointID: strongest.accessPointID,
                    strongestEstimatedPowerDBm: strongest.estimatedReceivedPowerDBm))
            }
        }
        let powers = samples.map(\.strongestEstimatedPowerDBm)
        guard let minimum = powers.min(), let maximum = powers.max() else {
            throw RadioEstimateError.invalidInput("samples")
        }
        var limitations = [
            "quick log-distance reference-loss estimate; not ray tracing or a full propagation simulation",
            "not measured RSSI; field measurement records are separate evidence",
            "omnidirectional antenna pattern only; access point orientation is not applied",
            "no interference, MIMO, beamforming, SINR or capacity calculation",
            "wall thickness is recorded but v1 counts one attenuation event per crossed centreline segment",
            "door/window openings are not inferred; represent them as separate wall segments with source-backed attenuation",
            "path-loss assumptions and wall attenuation are caller-supplied evidence"
        ]
        if let calibration = request.adoptedCalibration {
            limitations.append(
                "applied adopted calibration \(calibration.id) version \(calibration.version); raw field measurements remain separate records")
        }
        return RadioEstimateResult(
            label: estimateLabel,
            evidenceClass: request.adoptedCalibration == nil ? .modelEstimate : .calibratedModel,
            modelIdentifier: modelIdentifier,
            solverVersion: solverVersion,
            inputFingerprint: try request.fingerprint(),
            projectRevision: request.projectRevision,
            band: request.band,
            assumptions: request.assumptions,
            columns: columns,
            rows: rows,
            samples: samples,
            minimumEstimatedPowerDBm: minimum,
            maximumEstimatedPowerDBm: maximum,
            calibrationID: request.adoptedCalibration?.id,
            calibrationVersion: request.adoptedCalibration?.version,
            limitations: limitations)
    }
}
