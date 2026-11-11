import Foundation
import Testing
import FloeToolboxUtilities
@testable import FloeToolboxWorkbenches

@MainActor
struct EverydayWorkbenchStateTests {
    @Test func rulerInitialEmptyLayoutWaitsForTheFirstUsableCanvas() throws {
        let model = makeRuler()
        let initial = points(model)
        model.placeMarks(in: .zero, displayScale: 2)
        model.clampMarks(in: .zero, displayScale: 2)
        model.resetMarks()
        #expect(points(model) == initial)

        let bounds = CGSize(width: 400, height: 300)
        model.placeMarks(in: bounds, displayScale: 2)
        #expect(model.markA.x == 100 && model.markB.x == 300)
        #expect(model.markA.y == EverydayRulerModel.distanceTrackY(in: bounds))
        #expect(model.markB.y == model.markA.y)
        #expect(abs(model.markB.x - model.markA.x) >= 10)
        #expect(model.referenceMillimetres != nil)
        let angle = try #require(model.angleDegrees())
        #expect(angle > 0 && angle < 180)
    }

    @Test func rulerBoundsUpdateCanPerformTheFirstPlacement() {
        let model = makeRuler()
        model.placeMarks(in: .zero, displayScale: 2)
        // A size-change path must initialize even when onAppear had no size.
        model.clampMarks(in: CGSize(width: 400, height: 300), displayScale: 2)
        #expect(model.markA.x == 100 && model.markB.x == 300)
        #expect(model.vertex == CGPoint(x: 200, y: 165))
        #expect(model.armEnd1 != model.vertex && model.armEnd2 != model.vertex)
    }

    @Test func rulerTransientBoundsPreserveMarkersAndTheLastResetViewport() {
        let model = makeRuler()
        let bounds = CGSize(width: 640, height: 400)
        model.placeMarks(in: bounds, displayScale: 2)
        let calibration = makeCalibration(for: bounds)
        model.calibration = calibration
        model.clampMarks(in: bounds, displayScale: 2)
        let placed = points(model)

        model.clampMarks(in: .zero, displayScale: 2)
        model.placeMarks(in: CGSize(width: 50, height: 60), displayScale: 2)
        model.clampMarks(in: CGSize(width: CGFloat.nan, height: 400), displayScale: 2)
        #expect(points(model) == placed)
        #expect(model.calibration == calibration && !model.calibrationInvalid)

        model.markA = CGPoint(x: 250, y: 30)
        model.markB = CGPoint(x: 300, y: 30)
        model.resetMarks()
        #expect(model.markA.x == 160 && model.markB.x == 480)
        #expect(model.markA.y == EverydayRulerModel.distanceTrackY(in: bounds))
        #expect(model.markB.y == model.markA.y)
        #expect(model.calibration == calibration && !model.calibrationInvalid)
    }

    @Test func rulerResizeKeepsAUsableSpanAndInvalidatesViewportCalibration() {
        let model = makeRuler()
        let originalBounds = CGSize(width: 640, height: 400)
        model.placeMarks(in: originalBounds, displayScale: 2)
        let calibration = makeCalibration(for: originalBounds)
        model.calibration = calibration
        model.placeMarks(in: originalBounds, displayScale: 2)
        #expect(model.pointsPerMillimeter == 2)

        let resized = CGSize(width: 320, height: 300)
        model.placeMarks(in: resized, displayScale: 2)
        #expect(model.markA.x == 22 && model.markB.x == 298)
        #expect(model.markA.y == model.markB.y && model.markA.y == EverydayRulerModel.distanceTrackY(in: resized))
        #expect(model.calibration == calibration && model.calibrationInvalid && model.pointsPerMillimeter == nil)
        model.resetMarks()
        #expect(model.markA.x == 80 && model.markB.x == 240)
        #expect(model.calibration == calibration && model.calibrationInvalid)

        model.placeMarks(in: originalBounds, displayScale: 2)
        #expect(!model.calibrationInvalid && model.pointsPerMillimeter == 2)
        model.placeMarks(in: originalBounds, displayScale: 3)
        #expect(model.calibrationInvalid && model.pointsPerMillimeter == nil)
    }

    @Test func rulerResizeMovesAReversedDistancePairTogether() {
        let model = makeRuler()
        model.placeMarks(in: CGSize(width: 640, height: 400), displayScale: 2)
        model.markA = CGPoint(x: 590, y: 255)
        model.markB = CGPoint(x: 450, y: 255)
        model.placeMarks(in: CGSize(width: 320, height: 300), displayScale: 2)
        #expect(model.markA.x == 298 && model.markB.x == 158)
        #expect(model.markA.x - model.markB.x == 140)
        #expect(model.markA.y == model.markB.y)
    }

    private func makeRuler() -> EverydayRulerModel {
        // These tests never load/save; the injected store also isolates them
        // from the user's persistent calibration if a test gains I/O later.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EverydayWorkbenchStateTests-\(UUID().uuidString).json")
        return EverydayRulerModel(store: EverydayRulerCalibrationStore(url: url))
    }

    private func points(_ model: EverydayRulerModel) -> [CGPoint] {
        [model.markA, model.markB, model.vertex, model.armEnd1, model.armEnd2]
    }

    private func makeCalibration(for bounds: CGSize) -> EverydayRulerCalibration {
        EverydayRulerCalibration(pointsPerMillimeter: 2, nativeScale: 2,
                                 viewportKey: EverydayRulerModel.viewportKey(for: bounds),
                                 timestamp: Date(timeIntervalSince1970: 1_700_000_000))
    }
}
