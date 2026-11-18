import XCTest
import AVFoundation
import FloeMacMediaCore
@testable import FloeMacMediaSystem

private final class AudioChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class AudioNotificationFixture: @unchecked Sendable {
    let center = NotificationCenter()
    let owner = NSObject()
}

final class MacAudioEngineSourceTests: XCTestCase {
    private func floatBuffer(interleaved: Bool) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                  sampleRate: 48_000, channels: 2,
                                                  interleaved: interleaved))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        let channels = try XCTUnwrap(buffer.floatChannelData)
        let left: [Float] = [0.2, 0.4, 0.6]
        let right: [Float] = [0.6, 0.8, 1.0]
        let stride = Int(buffer.stride)
        for index in 0..<3 {
            channels[0][index * stride] = left[index]
            channels[1][index * stride] = right[index]
        }
        return buffer
    }

    func testInterleavedAndPlanarStereoAverageUsingStride() throws {
        for interleaved in [false, true] {
            let buffer = try floatBuffer(interleaved: interleaved)
            let values = try XCTUnwrap(MacAudioEngineSource.copyMonoFrame(buffer, maxFrames: 3))
            XCTAssertEqual(values.count, 3)
            XCTAssertEqual(values[0], 0.4, accuracy: 0.00001)
            XCTAssertEqual(values[1], 0.6, accuracy: 0.00001)
            XCTAssertEqual(values[2], 0.8, accuracy: 0.00001)
            let bounded = try XCTUnwrap(MacAudioEngineSource.copyMonoFrame(buffer, maxFrames: 2))
            XCTAssertEqual(bounded.count, 2)
        }
    }

    func testNonFloatBufferIsExplicitlyRejected() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                  sampleRate: 48_000, channels: 2,
                                                  interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        XCTAssertNil(buffer.floatChannelData)
        XCTAssertThrowsError(try MacAudioEngineSource.copyMonoFrame(buffer, maxFrames: 2)) {
            XCTAssertEqual($0 as? MacMediaFailure, .invalidFormat)
        }
    }

    func testOnlyOwningConfigurationChangeNotifiesOnceAndStopUnsubscribes() {
        let center = NotificationCenter()
        let owner = NSObject()
        let other = NSObject()
        let counter = AudioChangeCounter()
        let monitor = MacAudioConfigurationMonitor(center: center, object: owner) { counter.increment() }
        center.post(name: .AVAudioEngineConfigurationChange, object: other)
        XCTAssertEqual(counter.count, 0)
        center.post(name: .AVAudioEngineConfigurationChange, object: owner)
        center.post(name: .AVAudioEngineConfigurationChange, object: owner)
        XCTAssertEqual(counter.count, 1)
        monitor.stop()
        center.post(name: .AVAudioEngineConfigurationChange, object: owner)
        XCTAssertEqual(counter.count, 1)
    }

    func testStoppedMonitorIgnoresLateConfigurationChange() {
        let center = NotificationCenter()
        let owner = NSObject()
        let counter = AudioChangeCounter()
        let monitor = MacAudioConfigurationMonitor(center: center, object: owner) { counter.increment() }
        monitor.stop()
        monitor.stop()
        center.post(name: .AVAudioEngineConfigurationChange, object: owner)
        XCTAssertEqual(counter.count, 0)
    }

    func testStopDoesNotWaitForAnAlreadyEnteredNotification() {
        let fixture = AudioNotificationFixture()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let counter = AudioChangeCounter()
        let monitor = MacAudioConfigurationMonitor(center: fixture.center, object: fixture.owner) {
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
            counter.increment()
        }
        DispatchQueue.global().async {
            fixture.center.post(name: .AVAudioEngineConfigurationChange, object: fixture.owner)
            finished.signal()
        }
        let callbackEntered = entered.wait(timeout: .now() + 2)
        monitor.stop()
        fixture.center.post(name: .AVAudioEngineConfigurationChange, object: fixture.owner)
        release.signal()
        let callbackFinished = finished.wait(timeout: .now() + 2)
        XCTAssertEqual(callbackEntered, .success)
        XCTAssertEqual(callbackFinished, .success)
        XCTAssertEqual(counter.count, 1)
    }
}
