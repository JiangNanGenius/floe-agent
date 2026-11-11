import Foundation
import Testing
import FloeToolboxUtilities
@testable import FloeToolboxWorkbenches
#if os(iOS)
import CoreMotion
import Dispatch
#endif

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

#if os(iOS)
@MainActor
struct InstrumentMotionCallbackIsolationTests {
    @Test(arguments: InstrumentStreamKind.allCases)
    func productionHandlerAcceptsBackgroundSDKCallbacks(_ kind: InstrumentStreamKind) async throws {
        let probe = MotionCallbackProbe()
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let timeout = finishAfterTimeout(continuation)
        defer { timeout.cancel(); continuation.finish() }
        let callback = handler(for: kind, generation: 1, probe: probe, events: continuation)
        DispatchQueue(label: "qualification.motion.callback.\(kind.rawValue)").async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            // Even an empty SDK delivery enters the exact production block;
            // a MainActor-inferred block would trap before it can return.
            callback(nil, nil)
            callback(nil, NSError(domain: "FloeMotionCallbackQA", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "background callback error"]))
        }
        for await _ in events {
            if !probe.deliveries.isEmpty { break }
        }
        #expect(probe.checkedGenerations == [1])
        #expect(probe.deliveries.count == 1)
        let delivery = try #require(probe.deliveries.first)
        #expect(delivery.sample == nil)
        #expect(delivery.message == "background callback error")
    }

    @Test func productionHandlerRejectsALateGenerationBeforeMainActorDelivery() async {
        let probe = MotionCallbackProbe()
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let timeout = finishAfterTimeout(continuation)
        defer { timeout.cancel(); continuation.finish() }
        let previous = handler(for: .compass, generation: 1, probe: probe, events: continuation)
        let queue = DispatchQueue(label: "qualification.motion.late-generation")
        let invoked = DispatchSemaphore(value: 0)
        queue.async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            previous(nil, NSError(domain: "FloeMotionCallbackQA", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "stale callback error"]))
            invoked.signal()
        }
        // Briefly keep this MainActor turn until the real background callback
        // has queued its delivery, then retire its generation before yielding.
        // async (not queue.sync) ensures the callback really leaves this actor.
        let didInvoke = waitForCallback(invoked)
        probe.generation = 2
        #expect(didInvoke)
        guard didInvoke else { return }
        let current = handler(for: .compass, generation: 2, probe: probe, events: continuation)
        queue.async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            current(nil, NSError(domain: "FloeMotionCallbackQA", code: 3,
                                 userInfo: [NSLocalizedDescriptionKey: "current callback error"]))
        }
        for await _ in events {
            if probe.checkedGenerations.contains(1), probe.checkedGenerations.contains(2),
               probe.deliveries.contains(where: { $0.message == "current callback error" }) { break }
        }
        #expect(Set(probe.checkedGenerations) == Set([1, 2]))
        #expect(probe.deliveries.count == 1)
        #expect(probe.deliveries.first?.message == "current callback error")
        #expect(probe.deliveries.first?.sample == nil)
    }

    private func handler(
        for kind: InstrumentStreamKind, generation: Int, probe: MotionCallbackProbe,
        events: AsyncStream<Void>.Continuation
    ) -> @Sendable (CMDeviceMotion?, (any Error)?) -> Void {
        InstrumentMotionService.makeDeviceMotionHandler(
            for: kind, generation: generation,
            currentGeneration: {
                MainActor.assertIsolated()
                probe.checkedGenerations.append(generation)
                events.yield(())
                return probe.generation
            },
            receive: { sample, message in
                MainActor.assertIsolated()
                probe.deliveries.append((sample, message))
                events.yield(())
            })
    }

    nonisolated private func finishAfterTimeout(_ events: AsyncStream<Void>.Continuation) -> Task<Void, Never> {
        Task.detached {
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            events.finish()
        }
    }

    nonisolated private func waitForCallback(_ invoked: DispatchSemaphore) -> Bool {
        invoked.wait(timeout: .now() + 2) == .success
    }
}

@MainActor
private final class MotionCallbackProbe {
    var generation = 1
    var checkedGenerations: [Int] = []
    var deliveries: [(sample: InstrumentMotionSample?, message: String?)] = []
}
#endif

#if os(iOS)
import AVFoundation

/// Synthetic lifecycle/geometry contracts only. These tests never construct an
/// ARView, start ARSession, request native permission, or claim a hardware hit.
@MainActor
struct SpatialMeasurementSessionContractTests {
    @Test func unsupportedWorldTrackingNeverRequestsCameraOrLease() {
        let probe = SpatialAccessProbe()
        probe.supported = false
        let model = SpatialMeasurementSession(access: probe.access())
        model.requestStart()
        #expect(model.phase == .unavailable)
        #expect(probe.acquireCount == 0 && probe.permission == nil)
    }

    @Test func deniedCameraRecoversToExplicitStartAfterSettings() async {
        let probe = SpatialAccessProbe()
        probe.authorization = .denied
        let model = SpatialMeasurementSession(access: probe.access())
        model.requestStart()
        #expect(model.phase == .denied && probe.lease == nil)
        probe.authorization = .authorized
        model.sceneBecameActive()
        #expect(model.phase == .idle && probe.prepareCount == 0)
        model.requestStart()
        #expect(await waitUntil { model.phase == .running })
        #expect(probe.prepareCount == 1 && probe.lease != nil)
        model.stop()
        #expect(probe.lease == nil)
    }

    @Test func firstGrantOnBackgroundQueueWaitsForTheSceneToBecomeActive() async throws {
        let probe = SpatialAccessProbe()
        probe.authorization = .notDetermined
        let model = SpatialMeasurementSession(access: probe.access())
        model.requestStart()
        let callback = try #require(probe.permission)
        probe.active = false
        model.sceneBecameInactive(fullyBackground: false)
        probe.authorization = .authorized
        DispatchQueue(label: "qualification.spatial.permission").async { @Sendable in
            dispatchPrecondition(condition: .notOnQueue(.main))
            callback(true)
        }
        #expect(await waitUntil { model.pendingPermissionGeneration == nil })
        #expect(model.phase == .idle && model.isStarting && probe.prepareCount == 0)
        probe.active = true
        model.sceneBecameActive()
        #expect(await waitUntil { model.phase == .running })
        model.stop()
    }

    @Test func stoppedPermissionCallbackCannotReopenOrReacquireCamera() async throws {
        let probe = SpatialAccessProbe()
        probe.authorization = .notDetermined
        let model = SpatialMeasurementSession(access: probe.access())
        model.requestStart()
        let token = try #require(model.pendingPermissionGeneration)
        let callback = SpatialMeasurementSession.makePermissionHandler(for: model, token: token) {
            MainActor.assertIsolated()
            probe.permissionAccepted = $0
        }
        model.stop()
        probe.authorization = .authorized
        DispatchQueue(label: "qualification.spatial.late-permission").async { @Sendable in
            dispatchPrecondition(condition: .notOnQueue(.main))
            callback(true)
        }
        #expect(await waitUntil { probe.permissionAccepted != nil })
        #expect(probe.permissionAccepted == false)
        #expect(model.phase == .idle && !model.isStarting)
        #expect(probe.lease == nil && probe.prepareCount == 0)
    }

    @Test func stoppingDuringExternalCameraBarrierFencesItsLateReceipt() async throws {
        let probe = SpatialAccessProbe()
        probe.holdPreparation = true
        let model = SpatialMeasurementSession(access: probe.access())
        defer { probe.completePreparation(false); model.stop() }
        model.requestStart()
        guard await waitUntil({ probe.preparationGate != nil }) else {
            Issue.record("The injected camera barrier was not reached"); return
        }
        let pending = try #require(model.preparation)
        model.stop()
        probe.completePreparation(true)
        await pending.value
        #expect(model.phase == .idle && !model.isStarting)
        #expect(probe.lease == nil)
    }

    @Test func busyCameraKeepsTheOtherOwnersLeaseAndDoesNotAskPermission() {
        let probe = SpatialAccessProbe()
        let foreignLease = OpticsCaptureLease()
        probe.lease = foreignLease
        probe.authorization = .notDetermined
        let model = SpatialMeasurementSession(access: probe.access())
        model.requestStart()
        #expect(model.phase == .cameraBusy && !model.isStarting)
        #expect(probe.lease == foreignLease)
        #expect(probe.permission == nil && probe.prepareCount == 0)
        model.stop()
        #expect(probe.lease == foreignLease)
    }

    @Test func emptyModeEditsDuplicatePointsAndTrackingLossDoNotInventMeasurements() async {
        let probe = SpatialAccessProbe()
        let model = SpatialMeasurementSession(access: probe.access())
        defer { model.stop() }
        model.setMode(.area)
        model.setMode(.length)
        #expect(model.readout.segmentLengths.isEmpty && model.readout.totalLength == 0)
        model.requestStart()
        #expect(await waitUntil { model.phase == .running })
        let first = sample(0, 0)
        model.updateTracking(.limited("insufficientFeatures"))
        #expect(!model.record(first))
        model.updateTracking(.normal)
        #expect(!model.canPlacePoint, "Tracking alone is not a native raycast hit")
        #expect(model.record(first))
        #expect(!model.record(first))
        #expect(model.samples.count == 1 && model.readout.totalLength == 0)
        #expect(model.record(sample(1, 0)))
        #expect(model.readout.totalLength == 1)
        model.updateTracking(.notAvailable)
        #expect(!model.record(sample(2, 0)))
        model.pause()
        #expect(probe.lease == nil && model.samples.count == 2)
        model.undo()
        model.undo()
        #expect(model.samples.isEmpty && model.readout.segmentLengths.isEmpty)
        model.setMode(.area)
        #expect(model.readout.area == nil && !model.readout.canClose)
    }

    @Test func detectedCoplanarAnchorChangesKeepAreaAndClosingEdgeComplete() async {
        let probe = SpatialAccessProbe()
        let model = SpatialMeasurementSession(access: probe.access())
        defer { model.stop() }
        model.requestStart()
        #expect(await waitUntil { model.phase == .running })
        model.updateTracking(.normal)
        model.setMode(.area)
        #expect(!model.record(sample(0, 0, estimated: true)))
        for point in [sample(0, 0), sample(1, 0), sample(1, 1), sample(0, 1)] {
            #expect(model.record(point))
        }
        #expect(model.readout.area == 1 && model.readout.totalLength == 3)
        #expect(model.readout.canClose)
        model.closePolygon()
        #expect(model.polygonClosed && model.readout.totalLength == 4)
        #expect(model.readout.segmentLengths.count == 4)
        model.undo()
        #expect(!model.polygonClosed && model.samples.count == 4)
        #expect(model.readout.totalLength == 3)
        model.clear()
        #expect(model.samples.isEmpty && model.readout.area == nil)
    }

    private func sample(_ x: Float, _ z: Float, estimated: Bool = false) -> SpatialMeasurementSample {
        SpatialMeasurementSample(id: UUID(), position: SIMD3(x, 0, z), planeID: estimated ? nil : UUID(),
                                 surfaceNormal: estimated ? nil : SIMD3(0, 1, 0), estimated: estimated)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !condition(), clock.now < deadline, !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
        }
        return condition()
    }
}

@MainActor
private final class SpatialAccessProbe {
    var supported = true
    var authorization: AVAuthorizationStatus = .authorized
    var active = true
    var lease: OpticsCaptureLease?
    var acquireCount = 0
    var prepareCount = 0
    var permission: (@Sendable (Bool) -> Void)?
    var permissionAccepted: Bool?
    var holdPreparation = false
    var preparationGate: CheckedContinuation<Bool, Never>?

    func access() -> SpatialMeasurementSession.Access {
        .init(supported: { self.supported }, authorization: { self.authorization },
              requestPermission: { self.permission = $0 }, active: { self.active },
              acquire: {
                  guard self.lease == nil else { return nil }
                  let lease = OpticsCaptureLease()
                  self.lease = lease
                  self.acquireCount += 1
                  return lease
              }, owns: { self.lease == $0 },
              prepare: { lease in
                  self.prepareCount += 1
                  if self.holdPreparation {
                      return await withCheckedContinuation { self.preparationGate = $0 }
                  }
                  return self.lease == lease
              }, release: { if self.lease == $0 { self.lease = nil } })
    }

    func completePreparation(_ ready: Bool) {
        let gate = preparationGate
        preparationGate = nil
        gate?.resume(returning: ready)
    }
}
#endif
