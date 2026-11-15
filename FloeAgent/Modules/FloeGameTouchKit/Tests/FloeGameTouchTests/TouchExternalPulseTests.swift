// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameWebKit
@testable import FloeGameTouch

@MainActor
private final class PulseRecordingSink: GameTouchInputSink {
    struct Event: Equatable { let key: GameKeyboardKey; let down: Bool }
    var events: [Event] = []
    var failDown: GameKeyboardKey?
    private var waiters: [GameKeyboardKey: [CheckedContinuation<Void, Never>]] = [:]
    enum Failure: Error { case transport }

    func set(_ binding: GameTouchBinding, pressed: Bool) async throws {
        guard case .key(let key) = binding else { throw Failure.transport }
        events.append(.init(key: key, down: pressed))
        if pressed {
            let callbacks = waiters.removeValue(forKey: key) ?? []
            for callback in callbacks { callback.resume() }
            if key == failDown { throw Failure.transport }
        }
    }

    func waitForDown(_ key: GameKeyboardKey) async {
        if events.contains(.init(key: key, down: true)) { return }
        await withCheckedContinuation { waiters[key, default: []].append($0) }
    }
}

@MainActor
final class TouchExternalPulseTests: XCTestCase {
    private func service(_ sink: PulseRecordingSink) async -> GameTouchInputService {
        let value = GameTouchInputService(profile: .standard(.rpgMakerXP, keyboardTransport: .x11))
        await value.attach(sink)
        return value
    }

    func testFinitePulseDeliversOneDownAndOneUp() async throws {
        let sink = PulseRecordingSink()
        let input = await service(sink)
        try await input.performPulse(.key(.z), durationMilliseconds: 16)
        XCTAssertEqual(sink.events, [.init(key: .z, down: true), .init(key: .z, down: false)])
        await input.detach()
    }

    func testCancellationDrainsHeldPulseBeforeReturning() async throws {
        let sink = PulseRecordingSink()
        let input = await service(sink)
        let pulse = Task { try await input.performPulse(.key(.z), durationMilliseconds: 2_000) }
        await sink.waitForDown(.z)
        pulse.cancel()
        do { try await pulse.value; XCTFail("cancelled pulse") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(sink.events, [.init(key: .z, down: true), .init(key: .z, down: false)])
        await input.detach()
    }

    func testPulseCannotReleaseTheSameKeyHeldByDirectionControl() async throws {
        let sink = PulseRecordingSink()
        let input = await service(sink)
        input.direction(.left, pressed: true)
        await input.flush()
        try await input.performPulse(.key(.left), durationMilliseconds: 16)
        XCTAssertEqual(sink.events, [.init(key: .left, down: true)])
        input.direction(.left, pressed: false)
        await input.flush()
        XCTAssertEqual(sink.events.last, .init(key: .left, down: false))
        await input.detach()
    }

    func testOverlappingAIPulsesRetainSharedModifierUntilLastSourceEnds() async throws {
        let sink = PulseRecordingSink()
        let input = await service(sink)
        let first = Task {
            try await input.performPulse(.chord(try .init(keys: [.control, .z])), durationMilliseconds: 2_000)
        }
        await sink.waitForDown(.z)
        let second = Task {
            try await input.performPulse(.chord(try .init(keys: [.control, .x])), durationMilliseconds: 2_000)
        }
        await sink.waitForDown(.x)
        first.cancel()
        _ = try? await first.value
        XCTAssertFalse(sink.events.contains(.init(key: .control, down: false)))
        XCTAssertFalse(sink.events.contains(.init(key: .x, down: false)))
        second.cancel()
        _ = try? await second.value
        XCTAssertEqual(sink.events.filter { $0.key == .control && $0.down }.count, 1)
        XCTAssertEqual(sink.events.filter { $0.key == .control && !$0.down }.count, 1)
        XCTAssertEqual(sink.events.last, .init(key: .control, down: false))
        await input.detach()
    }

    func testDetachCancelsOldPulseWithoutTouchingNewAttachment() async throws {
        let old = PulseRecordingSink()
        let newer = PulseRecordingSink()
        let input = await service(old)
        let pulse = Task { try await input.performPulse(.key(.z), durationMilliseconds: 2_000) }
        await old.waitForDown(.z)
        await input.attach(newer)
        input.direction(.left, pressed: true)
        await input.flush()
        _ = try? await pulse.value
        XCTAssertEqual(newer.events, [.init(key: .left, down: true)])
        XCTAssertEqual(old.events.last, .init(key: .z, down: false))
        await input.detach()
    }

    func testUnattachedAndInvalidDurationDoNotSendInput() async throws {
        let input = GameTouchInputService(profile: .standard(.rpgMakerXP))
        do { try await input.performPulse(.key(.z)); XCTFail("no attachment") }
        catch { XCTAssertEqual(error as? GameTouchPulseError, .unavailable) }
        do { try await input.performPulse(.key(.z), durationMilliseconds: 0); XCTFail("bad duration") }
        catch { XCTAssertEqual(error as? GameTouchPulseError, .invalidDuration) }
    }

    func testTransportFailureSurfacesAndNoFurtherPulseIsSent() async throws {
        let sink = PulseRecordingSink()
        sink.failDown = .z
        let input = await service(sink)
        do { try await input.performPulse(.key(.z)); XCTFail("transport error") }
        catch {}
        XCTAssertNotNil(input.lastError)
        XCTAssertTrue(sink.events.contains(.init(key: .z, down: false)),
                      "a failed acknowledgement may already have delivered the attempted down")
        let before = sink.events
        do { try await input.performPulse(.key(.x)); XCTFail("failed transport must be reset") }
        catch {}
        XCTAssertEqual(sink.events, before)
        await input.detach()
    }
}
