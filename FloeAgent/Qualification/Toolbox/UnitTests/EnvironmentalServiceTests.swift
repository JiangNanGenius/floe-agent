import Foundation
import Testing
@testable import FloeToolboxWorkbenches

#if os(iOS)
@MainActor private final class PressureDeliveryReceipt {
    var accepted: Bool?
}

private enum PressureTestFrame: Sendable {
    case empty
    case failure(String)
}

@MainActor
struct EnvironmentalServiceTests {
    @Test func pressureProductionHandlerAcceptsAnEmptyBackgroundDelivery() async {
        let service = ToolboxPressureService()
        let receipt = PressureDeliveryReceipt()
        let handler = service.prepareStreamHandler { receipt.accepted = $0 }
        defer { service.pause() }

        let accepted = await deliver(handler, frame: .empty, receipt: receipt)
        #expect(accepted == false)
        #expect(service.phase == .starting)
        #expect(service.latest == nil)
        #expect(service.streamError == nil)
    }

    @Test func pressureProductionHandlerCopiesBackgroundErrorAndStopsOnMainActor() async {
        let service = ToolboxPressureService()
        let receipt = PressureDeliveryReceipt()
        let handler = service.prepareStreamHandler { receipt.accepted = $0 }

        let accepted = await deliver(handler, frame: .failure("background pressure failure"), receipt: receipt)
        #expect(accepted == true)
        #expect(service.phase == .idle)
        #expect(service.streamError == "background pressure failure")
        #expect(service.latest == nil)
    }

    @Test func pressureProductionHandlerRejectsADeliveryAfterPause() async {
        let service = ToolboxPressureService()
        let receipt = PressureDeliveryReceipt()
        let handler = service.prepareStreamHandler { receipt.accepted = $0 }
        service.pause()

        let accepted = await deliver(handler, frame: .failure("late paused error"), receipt: receipt)
        #expect(accepted == false)
        #expect(service.phase == .idle)
        #expect(service.streamError == nil)
    }

    @Test func pressureProductionHandlerCannotStopANewerGeneration() async {
        let service = ToolboxPressureService()
        let oldReceipt = PressureDeliveryReceipt()
        let oldHandler = service.prepareStreamHandler { oldReceipt.accepted = $0 }
        service.pause()
        let currentReceipt = PressureDeliveryReceipt()
        let currentHandler = service.prepareStreamHandler { currentReceipt.accepted = $0 }
        defer { service.pause() }

        let oldAccepted = await deliver(oldHandler, frame: .failure("old generation"), receipt: oldReceipt)
        #expect(oldAccepted == false)
        #expect(service.phase == .starting)
        #expect(service.streamError == nil)

        let currentAccepted = await deliver(currentHandler, frame: .failure("current generation"), receipt: currentReceipt)
        #expect(currentAccepted == true)
        #expect(service.phase == .idle)
        #expect(service.streamError == "current generation")
    }

    @Test func pressureRejectsInvalidInputBeforeUpdatingHistory() {
        let service = ToolboxPressureService()
        let invalidSamples = [
            ToolboxPressureSample(timestamp: .nan, receivedAt: Date(), pressureHpa: 1013, relativeAltitude: 0),
            ToolboxPressureSample(timestamp: -1, receivedAt: Date(), pressureHpa: 1013, relativeAltitude: 0),
            ToolboxPressureSample(timestamp: 100, receivedAt: Date(), pressureHpa: .infinity, relativeAltitude: 0),
            ToolboxPressureSample(timestamp: 100, receivedAt: Date(), pressureHpa: 0, relativeAltitude: 0),
            ToolboxPressureSample(timestamp: 100, receivedAt: Date(), pressureHpa: 1013, relativeAltitude: .nan)
        ]
        for sample in invalidSamples { service.accept(sample) }
        #expect(service.latest == nil)
        #expect(service.history.isEmpty)
        #expect(service.zeroBaseline == nil)
        service.accept(sample(time: 100, altitude: 2))
        #expect(service.history.count == 1)
        #expect(service.displayedAltitude == 0)
    }

    @Test func pressureHistoryKeepsItsClockAcrossStreamRestarts() {
        let service = ToolboxPressureService()
        service.accept(sample(time: 100, altitude: 0))
        service.accept(sample(time: 102, altitude: 1))
        service.pause()
        service.accept(sample(time: 120, altitude: 0))
        service.accept(sample(time: 121, altitude: 0.5))
        #expect(service.history.values.map(\.timestamp) == [0, 2, 20, 21])
        #expect(service.makeCSV().contains("20.000,"))
    }

    @Test func clearingPressureHistoryStartsANewClockWithoutMovingTheAltitudeReference() {
        let service = ToolboxPressureService()
        service.accept(sample(time: 100, altitude: 0))
        service.accept(sample(time: 102, altitude: 4))
        let baseline = service.zeroBaseline
        service.resetHistory()
        service.accept(sample(time: 110, altitude: 5))
        service.accept(sample(time: 111, altitude: 6))
        #expect(service.history.values.map(\.timestamp) == [0, 1])
        #expect(service.zeroBaseline == baseline)
        #expect(service.displayedAltitude == 6)
    }

    private func sample(time: TimeInterval, altitude: Double) -> ToolboxPressureSample {
        .init(timestamp: time, receivedAt: Date(timeIntervalSince1970: time),
              pressureHpa: 1013, relativeAltitude: altitude)
    }

    /// Invokes the handler returned by the production factory, never a substitute
    /// SDK callback. No test starts CMAltimeter updates or requests authorization.
    private func deliver(
        _ handler: @escaping ToolboxPressureService.AltitudeHandler,
        frame: PressureTestFrame, receipt: PressureDeliveryReceipt
    ) async -> Bool? {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        defer { queue.cancelAllOperations() }
        queue.addOperation { @Sendable in
            #expect(!Thread.isMainThread)
            switch frame {
            case .empty: handler(nil, nil)
            case .failure(let message):
                handler(nil, NSError(domain: "FloePressureQualification", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message]))
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while receipt.accepted == nil, clock.now < deadline, !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
        }
        #expect(receipt.accepted != nil, "The production MainActor receiver did not acknowledge delivery before the timeout")
        return receipt.accepted
    }
}
#endif

#if os(iOS)
import AVFoundation
import Dispatch
import FloeToolboxUtilities

@MainActor private final class SoundTapReceipt {
    var generation = 1
    var inputSucceeded: Bool?
    var checkedStreams: [Int] = []
    var receivedStreams: [Int] = []
    var results: [SoundAnalysisCore.Result] = []
}

@MainActor
struct SoundCallbackIsolationTests {
    @Test func productionTapCopiesPCMAndKeepsTheHandoffBoundedOffMainActor() async throws {
        let receipt = SoundTapReceipt()
        let relay = SoundFrameRelay()
        let queue = DispatchQueue(label: "com.floe.qualification.sound.copy")
        let fft = try #require(EnvironmentalSignalFFT(frameSize: 4096))
        let core = SoundAnalysisCore(sampleRate: 48_000, fft: fft, frameSize: 4096)
        let tap = ToolboxSoundService.makeInputTap(maxFrames: 8192, relay: relay,
            analysisQueue: queue, core: core, generation: 1,
            currentGeneration: {
                MainActor.assertIsolated()
                receipt.checkedStreams.append(1)
                return receipt.generation
            }, receive: { result in
                MainActor.assertIsolated()
                receipt.receivedStreams.append(1)
                receipt.results.append(result)
            })

        // Keep analysis behind the tap so buffer reuse and an overrun happen
        // before any consumer can read the copied samples.
        queue.suspend()
        var suspended = true
        defer { if suspended { queue.resume() } }
        Self.enqueueInput(tap, frequency: 750, replayThenClear: true) {
            receipt.inputSucceeded = $0
        }
        guard await waitFor("background PCM delivery", until: { receipt.inputSucceeded != nil }) else { return }
        #expect(receipt.inputSucceeded == true)
        #expect(!relay.offer([0]), "The production tap must keep at most one frame pending")
        queue.resume()
        suspended = false

        guard await waitFor("MainActor sound result", until: { !receipt.results.isEmpty }) else { return }
        let result = try #require(receipt.results.first)
        #expect(receipt.checkedStreams == [1])
        #expect(receipt.receivedStreams == [1])
        #expect(abs(result.levelDBFS - (-9.0309)) < 0.01)
        #expect(abs(result.peakDBFS - (-6.0206)) < 0.01)
        let frequency = try #require(result.dominantFrequency)
        #expect(abs(frequency - 750) < 1)
        #expect(result.spectrum.bands.count == 40)
        #expect(result.spectrum.bands.count == result.spectrum.bandFrequencies.count)
        #expect(!result.appendToHistory)
    }

    @Test func productionTapDropsAnOldGenerationAndDeliversTheCurrentGeneration() async throws {
        let receipt = SoundTapReceipt()
        let queue = DispatchQueue(label: "com.floe.qualification.sound.generation")
        let oldTap = makeTap(generation: 1, queue: queue, receipt: receipt)
        queue.suspend()
        var suspended = true
        defer { if suspended { queue.resume() } }
        Self.enqueueInput(oldTap, frequency: 750) { receipt.inputSucceeded = $0 }
        guard await waitFor("old background PCM delivery", until: { receipt.inputSucceeded != nil }) else { return }
        #expect(receipt.inputSucceeded == true)

        // The real production fence sees a new generation before analysis can
        // deliver the old result. The receiver deliberately performs no filter.
        receipt.generation = 2
        receipt.inputSucceeded = nil
        let currentTap = makeTap(generation: 2, queue: queue, receipt: receipt)
        queue.resume()
        suspended = false
        Self.enqueueInput(currentTap, frequency: 1500) { receipt.inputSucceeded = $0 }
        guard await waitFor("both generation checks", until: {
            receipt.inputSucceeded != nil && receipt.checkedStreams.contains(1)
                && receipt.checkedStreams.contains(2) && !receipt.results.isEmpty
        }) else { return }

        #expect(receipt.inputSucceeded == true)
        #expect(receipt.receivedStreams == [2])
        #expect(receipt.results.count == 1)
        let result = try #require(receipt.results.first)
        let frequency = try #require(result.dominantFrequency)
        #expect(abs(frequency - 1500) < 1)
    }

    private func makeTap(generation: Int, queue: DispatchQueue, receipt: SoundTapReceipt)
        -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        let core = SoundAnalysisCore(sampleRate: 48_000,
            fft: EnvironmentalSignalFFT(frameSize: 4096), frameSize: 4096)
        return ToolboxSoundService.makeInputTap(maxFrames: 8192, relay: SoundFrameRelay(),
            analysisQueue: queue, core: core, generation: generation,
            currentGeneration: {
                MainActor.assertIsolated()
                receipt.checkedStreams.append(generation)
                return receipt.generation
            }, receive: { result in
                MainActor.assertIsolated()
                receipt.receivedStreams.append(generation)
                receipt.results.append(result)
            })
    }

    /// SDK buffers/timestamps are created, reused and discarded on this queue.
    /// No microphone, engine or audio-session mutation is involved.
    nonisolated private static func enqueueInput(
        _ tap: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        frequency: Double, replayThenClear: Bool = false,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { @Sendable in
            #expect(!Thread.isMainThread)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
                  let samples = buffer.floatChannelData?[0] else {
                Task { @MainActor in completion(false) }
                return
            }
            buffer.frameLength = 4096
            for index in 0..<4096 {
                samples[index] = Float(0.5 * sin(2 * .pi * frequency * Double(index) / 48_000))
            }
            tap(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
            if replayThenClear {
                for index in 0..<4096 {
                    samples[index] = Float(0.1 * sin(2 * .pi * 1500 * Double(index) / 48_000))
                }
                tap(buffer, AVAudioTime(sampleTime: 4096, atRate: 48_000))
                for index in 0..<4096 { samples[index] = 0 }
            }
            Task { @MainActor in completion(true) }
        }
    }

    private func waitFor(_ description: String, until condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !condition(), clock.now < deadline, !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
        }
        let completed = condition()
        #expect(completed, "Timed out waiting for \(description)")
        return completed
    }
}
#endif
