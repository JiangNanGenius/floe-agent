// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Radio quick-estimate public guide and deterministic synthetic sample.
///
/// ## Units and frames
/// - Every `RadioPoint3D` is **metres**, with X/Y horizontal and Z up. `1000 mm = 1.0`.
///   There is no implicit conversion; keeping a millimetre value in a metre field is a
///   caller error that produces visibly wrong distances.
/// - Wall `startM`/`endM` are the bottom edge in plan. Their Z must match; `heightM`
///   extends upward. A ray receives wall attenuation only when it crosses the finite
///   plan segment and its interpolated height is inside the wall.
///
/// ## Model and evidence
/// ```swift
/// let request = RadioSampleFixtures.twoRoomRequest()
/// let result = try RadioQuickEstimator.estimate(request)
/// // result.label == "ESTIMATE"
/// // result.evidenceClass == .modelEstimate
/// // result.samples[i].perAccessPoint[j].estimatedReceivedPowerDBm
/// // result.samples[i].strongestAccessPointID
/// ```
/// The estimate is `referencePowerDBm - 10*n*log10(max(d, d0)/d0) - wallLoss`.
/// It is a quick model estimate: not measured RSSI and not a ray-tracing or full
/// propagation result. Replacing a band's centre frequency/channel width requires
/// matching wall attenuation for that exact band; missing data throws
/// `RadioEstimateError.needsInput` instead of using a default.
///
/// ## Field measurements and calibration
/// `RadioFieldMeasurement` keeps the raw device, band, position, orientation,
/// conditions, time and observed power. `RadioCalibration.adopt(...)` validates that
/// the referenced measurements match the calibration band and stores a versioned
/// additive correction plus source IDs. It never rewrites observations and contains no
/// AP configuration or deployment action. Pass an adopted calibration in the request
/// to apply it; the result then reports `.calibratedModel` while retaining the
/// `"ESTIMATE"` label and pointing back to the calibration version.
///
/// ## Staleness
/// `RadioEstimateResult.isStale(for:)` compares the persisted request fingerprint.
/// Changing project revision, AP/wall values, grid, assumptions, band or calibration
/// makes the old heatmap stale; solver budget arguments do not affect the fingerprint
/// because they cannot change a completed result.
public enum RadioSampleFixtures: Sendable {
    /// Synthetic two-room sample. All numbers are fictional test inputs.
    ///
    /// AP at `(0, 0, 2.5) m`, reference power `-40 dBm` at `1 m`, exponent `2.7`.
    /// One `12 dB` wall at `x = 4 m`, spanning `y = -3...3 m`, base `0 m`,
    /// height `3 m`, thickness `0.15 m`. Receiver plane at `z = 1.2 m`, covering
    /// `x = 8...12 m` and `y = 0...2 m` with a `3 x 2` grid.
    public static func twoRoomRequest() -> RadioEstimateRequest {
        let band = RadioBand(id: "2.4ghz", centerFrequencyMHz: 2437, channelWidthMHz: 20)
        let accessPoint = RadioAccessPoint(
            id: "ap-living",
            band: band,
            positionM: RadioPoint3D(0, 0, 2.5),
            referencePower: RadioReferencePower(
                dBm: -40, basis: .model, sourceID: "synthetic-ap-model@1"),
            antenna: RadioAntennaAssumption(
                modelID: "synthetic-omni", peakGainDBi: 2, pattern: .omnidirectional))
        let wall = RadioWall(
            id: "wall-living-study",
            startM: RadioPoint3D(4, -3, 0),
            endM: RadioPoint3D(4, 3, 0),
            heightM: 3,
            thicknessM: 0.15,
            attenuation: [
                RadioBandAttenuation(
                    band: band, attenuationDB: 12,
                    sourceID: "synthetic-material@1")
            ])
        return RadioEstimateRequest(
            projectRevision: 7,
            band: band,
            accessPoints: [accessPoint],
            walls: [wall],
            receiverPlane: RadioReceiverPlane(
                originM: RadioPoint3D(8, 0, 1.2),
                right: RadioPoint3D(1, 0, 0),
                up: RadioPoint3D(0, 1, 0),
                widthM: 4,
                heightM: 2,
                columns: 3,
                rows: 2),
            assumptions: RadioPropagationAssumptions(
                referenceDistanceM: 1,
                pathLossExponent: 2.7,
                evidenceID: "synthetic-path-loss@1"))
    }
}
