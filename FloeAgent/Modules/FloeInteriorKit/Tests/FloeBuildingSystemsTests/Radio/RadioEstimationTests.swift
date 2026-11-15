// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeBuildingSystems

private let radioBand24 = RadioBand(id: "2.4ghz", centerFrequencyMHz: 2437, channelWidthMHz: 20)
private let radioBand5 = RadioBand(id: "5ghz", centerFrequencyMHz: 5180, channelWidthMHz: 80)
private let radioAssumptions = RadioPropagationAssumptions(
    referenceDistanceM: 1, pathLossExponent: 2, evidenceID: "synthetic-path-loss@1")

final class RadioEstimationTests: XCTestCase {
    private func makeAP(id: String = "ap-a", band: RadioBand = radioBand24,
                        position: RadioPoint3D = RadioPoint3D(0, 0, 2.5),
                        referenceDBm: Double = -40) -> RadioAccessPoint {
        RadioAccessPoint(
            id: id,
            band: band,
            positionM: position,
            referencePower: RadioReferencePower(
                dBm: referenceDBm, basis: .model, sourceID: "synthetic-ap@1"),
            antenna: RadioAntennaAssumption(
                modelID: "synthetic-omni", peakGainDBi: 2, pattern: .omnidirectional))
    }

    private func makeWall(id: String = "wall-a", band: RadioBand = radioBand24,
                          attenuationDB: Double = 12,
                          x: Double = 4, y0: Double = -3, y1: Double = 3,
                          height: Double = 3, thickness: Double = 0.15) -> RadioWall {
        RadioWall(
            id: id,
            startM: RadioPoint3D(x, y0, 0),
            endM: RadioPoint3D(x, y1, 0),
            heightM: height,
            thicknessM: thickness,
            attenuation: [
                RadioBandAttenuation(
                    band: band, attenuationDB: attenuationDB,
                    sourceID: "synthetic-material@1")
            ])
    }

    private func makeRequest(projectRevision: Int = 1,
                             band: RadioBand = radioBand24,
                             accessPoints: [RadioAccessPoint]? = nil,
                             walls: [RadioWall]? = nil,
                             origin: RadioPoint3D = RadioPoint3D(8, 0, 1.2),
                             right: RadioPoint3D = RadioPoint3D(1, 0, 0),
                             up: RadioPoint3D = RadioPoint3D(0, 1, 0),
                             width: Double = 4, height: Double = 2,
                             columns: Int = 2, rows: Int = 2,
                             assumptions: RadioPropagationAssumptions = radioAssumptions,
                             calibration: RadioCalibration? = nil) -> RadioEstimateRequest {
        RadioEstimateRequest(
            projectRevision: projectRevision,
            band: band,
            accessPoints: accessPoints ?? [makeAP()],
            walls: walls ?? [makeWall()],
            receiverPlane: RadioReceiverPlane(
                originM: origin, right: right, up: up,
                widthM: width, heightM: height, columns: columns, rows: rows),
            assumptions: assumptions,
            adoptedCalibration: calibration)
    }

    private func assertRadioError(_ expected: RadioEstimateError,
                                  file: StaticString = #filePath, line: UInt = #line,
                                  _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? RadioEstimateError, expected, file: file, line: line)
        }
    }

    private func assertNeedsInput(file: StaticString = #filePath, line: UInt = #line,
                                  _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case .some(.needsInput) = (error as? RadioEstimateError) else {
                XCTFail("expected needsInput, got \(error)", file: file, line: line)
                return
            }
        }
    }

    func testCoordinatesAreMetresNotMillimetres() throws {
        let wallInMetres = try RadioQuickEstimator.estimate(makeRequest(walls: [makeWall(x: 4)]))
        XCTAssertEqual(wallInMetres.samples[0].perAccessPoint[0].crossedWallIDs, ["wall-a"])

        let millimetreNumbers = try RadioQuickEstimator.estimate(
            makeRequest(walls: [makeWall(x: 4000)]))
        XCTAssertEqual(millimetreNumbers.samples[0].perAccessPoint[0].crossedWallIDs, [])
        XCTAssertEqual(
            RadioPoint3D(4000, 0, 0).distance(to: RadioPoint3D(0, 0, 0)),
            4000, accuracy: 1e-12)
    }

    func testReferenceDistanceAndLogDistanceScaling() throws {
        let oneMetre = try RadioQuickEstimator.estimate(makeRequest(
            walls: [], origin: RadioPoint3D(1, 0, 2.5),
            width: 0, height: 0, columns: 1, rows: 1))
        XCTAssertEqual(oneMetre.samples[0].strongestEstimatedPowerDBm, -40, accuracy: 1e-12)

        let tenMetres = try RadioQuickEstimator.estimate(makeRequest(
            walls: [], origin: RadioPoint3D(10, 0, 2.5),
            width: 0, height: 0, columns: 1, rows: 1))
        XCTAssertEqual(tenMetres.samples[0].strongestEstimatedPowerDBm, -60, accuracy: 1e-12)

        var steeper = makeRequest(
            walls: [], origin: RadioPoint3D(10, 0, 2.5),
            width: 0, height: 0, columns: 1, rows: 1)
        steeper.assumptions.pathLossExponent = 2.5
        XCTAssertEqual(
            try RadioQuickEstimator.estimate(steeper).samples[0].strongestEstimatedPowerDBm,
            -65, accuracy: 1e-12)

        let insideReference = try RadioQuickEstimator.estimate(makeRequest(
            walls: [], origin: RadioPoint3D(0.25, 0, 2.5),
            width: 0, height: 0, columns: 1, rows: 1))
        XCTAssertEqual(
            insideReference.samples[0].strongestEstimatedPowerDBm, -40, accuracy: 1e-12)
    }

    func testWallAttenuationRequiresFiniteSegmentAndHeightCrossing() throws {
        let open = try RadioQuickEstimator.estimate(makeRequest(walls: []))
        let crossed = try RadioQuickEstimator.estimate(makeRequest(walls: [makeWall()]))
        XCTAssertEqual(
            crossed.samples[0].strongestEstimatedPowerDBm,
            open.samples[0].strongestEstimatedPowerDBm - 12, accuracy: 1e-9)
        XCTAssertEqual(crossed.samples[0].perAccessPoint[0].crossedWallIDs, ["wall-a"])
        XCTAssertEqual(
            crossed.samples[0].perAccessPoint[0].estimatedWallLossDB, 12, accuracy: 1e-12)

        let beyondSegment = try RadioQuickEstimator.estimate(
            makeRequest(walls: [makeWall(x: 4, y0: 6, y1: 8)]))
        XCTAssertTrue(beyondSegment.samples[0].perAccessPoint[0].crossedWallIDs.isEmpty)
        XCTAssertEqual(
            beyondSegment.samples[0].strongestEstimatedPowerDBm,
            open.samples[0].strongestEstimatedPowerDBm, accuracy: 1e-12)

        let aboveWall = try RadioQuickEstimator.estimate(
            makeRequest(walls: [makeWall(x: 4, height: 1.0)]))
        XCTAssertTrue(aboveWall.samples[0].perAccessPoint[0].crossedWallIDs.isEmpty)

        let behindAccessPoint = try RadioQuickEstimator.estimate(
            makeRequest(walls: [makeWall(x: -4)]))
        XCTAssertTrue(behindAccessPoint.samples[0].perAccessPoint[0].crossedWallIDs.isEmpty)
    }

    func testFrequencyChangeNeedsMatchingBandDataAndMatchingAPBand() throws {
        let unsupported = makeRequest(
            band: radioBand5, accessPoints: [makeAP(band: radioBand5)],
            walls: [makeWall(band: radioBand24)])
        assertNeedsInput { _ = try RadioQuickEstimator.estimate(unsupported) }

        let supplied = makeRequest(
            band: radioBand5, accessPoints: [makeAP(band: radioBand5)],
            walls: [makeWall(band: radioBand5, attenuationDB: 18)])
        let result5 = try RadioQuickEstimator.estimate(supplied)
        let baseline = try RadioQuickEstimator.estimate(makeRequest(
            band: radioBand24, accessPoints: [makeAP(band: radioBand24)], walls: []))
        XCTAssertEqual(
            result5.samples[0].strongestEstimatedPowerDBm,
            baseline.samples[0].strongestEstimatedPowerDBm - 18, accuracy: 1e-9)

        let shiftedBand = RadioBand(id: "2.4ghz", centerFrequencyMHz: 2450, channelWidthMHz: 20)
        let shifted = makeRequest(
            band: shiftedBand, accessPoints: [makeAP(band: shiftedBand)],
            walls: [makeWall(band: radioBand24)])
        assertNeedsInput { _ = try RadioQuickEstimator.estimate(shifted) }

        let mismatch = makeRequest(accessPoints: [makeAP(band: radioBand5)])
        assertRadioError(.invalidInput("access point band")) {
            _ = try RadioQuickEstimator.estimate(mismatch)
        }
    }

    func testUnknownWallBandIsNeedsInputNotDefaulted() throws {
        let input = makeRequest(walls: [makeWall(band: radioBand5)])
        assertNeedsInput { _ = try RadioQuickEstimator.estimate(input) }
    }

    func testMultipleAccessPointsExposePerAPPowerAndStrongest() throws {
        let accessPoints = [
            makeAP(id: "ap-far", position: RadioPoint3D(0, 0, 2.5), referenceDBm: -40),
            makeAP(id: "ap-near", position: RadioPoint3D(8, 0, 2.5), referenceDBm: -50)
        ]
        let result = try RadioQuickEstimator.estimate(makeRequest(
            accessPoints: accessPoints, walls: [],
            origin: RadioPoint3D(8, 0, 1.2),
            width: 0, height: 0, columns: 1, rows: 1))
        let sample = result.samples[0]
        XCTAssertEqual(sample.perAccessPoint.map(\.accessPointID), ["ap-far", "ap-near"])
        XCTAssertEqual(
            sample.perAccessPoint[0].estimatedReceivedPowerDBm,
            -40 - 20 * log10((65.69 as Double).squareRoot()), accuracy: 1e-9)
        XCTAssertEqual(
            sample.perAccessPoint[1].estimatedReceivedPowerDBm,
            -50 - 20 * log10(1.3), accuracy: 1e-9)
        XCTAssertEqual(sample.strongestAccessPointID, "ap-near")
        XCTAssertEqual(
            sample.strongestEstimatedPowerDBm,
            sample.perAccessPoint[1].estimatedReceivedPowerDBm)
    }

    func testMeasuredReferencePowerIsAcceptedAndEchoed() throws {
        let measuredAP = RadioAccessPoint(
            id: "ap-measured", band: radioBand24,
            positionM: RadioPoint3D(0, 0, 2.5),
            referencePower: RadioReferencePower(
                dBm: -35, basis: .measured, sourceID: "field-reference-1"),
            antenna: RadioAntennaAssumption(
                modelID: "synthetic-omni", peakGainDBi: 2, pattern: .omnidirectional))
        let result = try RadioQuickEstimator.estimate(makeRequest(
            accessPoints: [measuredAP], walls: [],
            origin: RadioPoint3D(1, 0, 2.5),
            width: 0, height: 0, columns: 1, rows: 1))
        XCTAssertEqual(
            result.samples[0].perAccessPoint[0].referencePowerBasis, .measured)
        XCTAssertEqual(
            result.samples[0].perAccessPoint[0].referenceSourceID, "field-reference-1")
        XCTAssertEqual(
            result.samples[0].strongestEstimatedPowerDBm, -35, accuracy: 1e-12)
    }

    func testResultCarriesEstimateModelConfigAndFingerprint() throws {
        let request = makeRequest()
        let result = try RadioQuickEstimator.estimate(request)
        XCTAssertEqual(result.label, "ESTIMATE")
        XCTAssertEqual(result.evidenceClass, .modelEstimate)
        XCTAssertEqual(result.modelIdentifier, RadioQuickEstimator.modelIdentifier)
        XCTAssertEqual(result.solverVersion, RadioQuickEstimator.solverVersion)
        XCTAssertEqual(result.inputFingerprint, try request.fingerprint())
        XCTAssertEqual(result.assumptions, request.assumptions)
        XCTAssertEqual(result.projectRevision, request.projectRevision)
        XCTAssertEqual(result.columns, 2)
        XCTAssertEqual(result.rows, 2)
        XCTAssertEqual(result.samples.count, 4)
        XCTAssertTrue(result.limitations.contains(
            "not measured RSSI; field measurement records are separate evidence"))
        let expectedMinimum = try XCTUnwrap(
            result.samples.map(\.strongestEstimatedPowerDBm).min())
        let expectedMaximum = try XCTUnwrap(
            result.samples.map(\.strongestEstimatedPowerDBm).max())
        XCTAssertEqual(result.minimumEstimatedPowerDBm, expectedMinimum)
        XCTAssertEqual(result.maximumEstimatedPowerDBm, expectedMaximum)
    }

    func testInvalidInputsAndBudgetsFailBeforeWork() throws {
        var input = makeRequest(walls: [])
        input.accessPoints[0].positionM.x = .nan
        assertRadioError(.invalidInput("access point position")) {
            _ = try RadioQuickEstimator.estimate(input)
        }

        input = makeRequest(walls: [makeWall(x: .nan)])
        assertRadioError(.invalidInput("wall start")) {
            _ = try RadioQuickEstimator.estimate(input)
        }

        input = makeRequest(walls: [])
        input.assumptions.pathLossExponent = 0
        assertRadioError(.invalidInput("path loss exponent")) {
            _ = try RadioQuickEstimator.estimate(input)
        }

        input = makeRequest(walls: [])
        input.assumptions.evidenceID = ""
        assertRadioError(.invalidInput("assumption evidence")) {
            _ = try RadioQuickEstimator.estimate(input)
        }

        input = makeRequest(walls: [])
        input.receiverPlane.right = input.receiverPlane.up
        assertRadioError(.invalidInput("receiver plane axes")) {
            _ = try RadioQuickEstimator.estimate(input)
        }

        input = makeRequest(walls: [])
        input.receiverPlane.widthM = 0
        assertRadioError(.invalidInput("receiver plane size")) {
            _ = try RadioQuickEstimator.estimate(input)
        }

        input = makeRequest(walls: [])
        input.accessPoints.append(makeAP(id: "ap-a"))
        assertRadioError(.invalidInput("duplicate access point id")) {
            _ = try RadioQuickEstimator.estimate(input)
        }

        input = makeRequest(walls: [makeWall(), makeWall()])
        assertRadioError(.invalidInput("duplicate wall id")) {
            _ = try RadioQuickEstimator.estimate(input)
        }

        input = makeRequest(walls: [])
        input.accessPoints[0].id = ""
        assertRadioError(.invalidInput("access point id")) {
            _ = try RadioQuickEstimator.estimate(input)
        }

        var cancellationCalls = 0
        assertRadioError(.budgetExceeded(4)) {
            _ = try RadioQuickEstimator.estimate(
                makeRequest(), maximumCells: 3,
                cancelled: { cancellationCalls += 1; return true })
        }
        XCTAssertEqual(cancellationCalls, 0)

        let twoAPs = [makeAP(), makeAP(id: "ap-b")]
        assertRadioError(.budgetExceeded(8)) {
            _ = try RadioQuickEstimator.estimate(
                makeRequest(accessPoints: twoAPs, walls: [makeWall()]),
                maximumWallChecks: 7)
        }

        assertRadioError(.invalidInput("cell budget")) {
            _ = try RadioQuickEstimator.estimate(makeRequest(), maximumCells: 0)
        }
    }

    func testCancellationStopsDuringGridWork() throws {
        assertRadioError(.cancelled) {
            _ = try RadioQuickEstimator.estimate(makeRequest(), cancelled: { true })
        }

        var calls = 0
        assertRadioError(.cancelled) {
            _ = try RadioQuickEstimator.estimate(makeRequest(), cancelled: {
                calls += 1
                return calls > 1
            })
        }
        XCTAssertGreaterThan(calls, 1)
    }

    func testResultRoundTripsAndDetectsStaleInputs() throws {
        let request = makeRequest()
        let result = try RadioQuickEstimator.estimate(request)
        let decoded = try JSONDecoder().decode(
            RadioEstimateResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded, result)
        XCTAssertFalse(try result.isStale(for: request))

        var revision = request
        revision.projectRevision += 1
        XCTAssertTrue(try result.isStale(for: revision))

        var wall = request
        wall.walls[0].attenuation[0].attenuationDB += 1
        XCTAssertTrue(try result.isStale(for: wall))

        var plane = request
        plane.receiverPlane.originM.x += 0.5
        XCTAssertTrue(try result.isStale(for: plane))

        let decodedRequest = try JSONDecoder().decode(
            RadioEstimateRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(try decodedRequest.fingerprint(), try request.fingerprint())
    }

    func testCalibrationKeepsRawObservationsAndAppliesVersionedCorrection() throws {
        let measurements = [
            RadioFieldMeasurement(
                id: "m1", deviceModel: "survey-phone", deviceIdentifier: "dev-1",
                band: radioBand24, positionM: RadioPoint3D(8, 0, 1.2),
                orientationDegrees: 0, conditions: "doors closed; occupied",
                rawReceivedPowerDBm: -55,
                measuredAtISO8601: "2026-11-13T00:00:00Z"),
            RadioFieldMeasurement(
                id: "m2", deviceModel: "survey-phone", deviceIdentifier: "dev-1",
                band: radioBand24, positionM: RadioPoint3D(12, 0, 1.2),
                orientationDegrees: 0, conditions: "doors closed; occupied",
                rawReceivedPowerDBm: -60,
                measuredAtISO8601: "2026-11-13T00:05:00Z")
        ]
        let calibration = try RadioCalibration.adopt(
            id: "cal-1", version: 2, band: radioBand24,
            correctionDB: 3.5, measurements: measurements,
            method: "mean-residual-v1",
            adoptedAtISO8601: "2026-11-13T01:00:00Z")
        XCTAssertEqual(calibration.sourceMeasurementIDs, ["m1", "m2"])
        XCTAssertEqual(measurements.map(\.rawReceivedPowerDBm), [-55, -60])

        let open = try RadioQuickEstimator.estimate(makeRequest(walls: []))
        let calibrated = try RadioQuickEstimator.estimate(
            makeRequest(walls: [], calibration: calibration))
        XCTAssertEqual(calibrated.label, "ESTIMATE")
        XCTAssertEqual(calibrated.evidenceClass, .calibratedModel)
        XCTAssertEqual(calibrated.calibrationID, "cal-1")
        XCTAssertEqual(calibrated.calibrationVersion, 2)
        XCTAssertEqual(
            calibrated.samples[0].strongestEstimatedPowerDBm,
            open.samples[0].strongestEstimatedPowerDBm + 3.5, accuracy: 1e-9)

        let decoded = try JSONDecoder().decode(
            [RadioFieldMeasurement].self, from: JSONEncoder().encode(measurements))
        XCTAssertEqual(decoded, measurements)
    }

    func testCalibrationRequiresMatchingBandAndValidVersion() throws {
        let measurement = RadioFieldMeasurement(
            id: "m1", deviceModel: "survey-phone", deviceIdentifier: "dev-1",
            band: radioBand24, positionM: RadioPoint3D(8, 0, 1.2),
            orientationDegrees: 0, conditions: "occupied",
            rawReceivedPowerDBm: -55,
            measuredAtISO8601: "2026-11-13T00:00:00Z")
        assertRadioError(.invalidInput("calibration measurement band")) {
            _ = try RadioCalibration.adopt(
                id: "cal", version: 1, band: radioBand5,
                correctionDB: 1, measurements: [measurement],
                method: "mean-residual-v1",
                adoptedAtISO8601: "2026-11-13T00:00:00Z")
        }

        let invalidVersion = RadioCalibration(
            id: "cal", version: 0, band: radioBand24,
            correctionDB: 1, sourceMeasurementIDs: ["m1"],
            method: "mean-residual-v1",
            adoptedAtISO8601: "2026-11-13T00:00:00Z")
        assertRadioError(.invalidInput("calibration version")) {
            _ = try RadioQuickEstimator.estimate(
                makeRequest(walls: [], calibration: invalidVersion))
        }

        let calibration24 = try RadioCalibration.adopt(
            id: "cal-24", version: 1, band: radioBand24,
            correctionDB: 1, measurements: [measurement],
            method: "mean-residual-v1",
            adoptedAtISO8601: "2026-11-13T00:00:00Z")
        let mismatched = makeRequest(
            band: radioBand5, accessPoints: [makeAP(band: radioBand5)],
            walls: [makeWall(band: radioBand5)], calibration: calibration24)
        assertRadioError(.invalidInput("calibration band")) {
            _ = try RadioQuickEstimator.estimate(mismatched)
        }
    }

    func testSampleFixtureSolvesAndBecomesStaleAfterRevisionChange() throws {
        let request = RadioSampleFixtures.twoRoomRequest()
        let result = try RadioQuickEstimator.estimate(request)
        XCTAssertEqual(result.samples.count, 6)
        XCTAssertEqual(result.label, "ESTIMATE")
        XCTAssertEqual(
            result.samples.map(\.strongestAccessPointID),
            Array(repeating: "ap-living", count: 6))
        var changed = request
        changed.projectRevision = 8
        XCTAssertTrue(try result.isStale(for: changed))
    }
}
