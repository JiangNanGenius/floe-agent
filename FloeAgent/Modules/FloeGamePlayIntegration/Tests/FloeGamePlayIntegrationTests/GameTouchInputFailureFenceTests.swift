// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameTouch
@testable import FloeGamePlayIntegration

@MainActor final class GameTouchInputFailureFenceTests: XCTestCase {
    func testHealthyConnectionPreservesPhysicalDownAndUp() async throws {
        let sink = RecordingSink()
        var temporary: RecordingSink? = RecordingSink()
        let fence = GameTouchInputFailureFence(sink: try XCTUnwrap(temporary))
        temporary = nil
        // A run owns its real sink strongly; this separate fence checks that it
        // cannot silently find another player after the captured sink disappears.
        do { try await fence.set(.key(.z), pressed: true); XCTFail("No captured sink") }
        catch { XCTAssertEqual(error as? GameTouchInputDeliveryError, .sinkUnavailable) }
        let connected = GameTouchInputFailureFence(sink: sink)
        try await connected.set(.key(.z), pressed: true)
        try await connected.set(.key(.z), pressed: false)
        XCTAssertEqual(sink.events.map(\.pressed), [true, false])
        XCTAssertTrue(sink.events.allSatisfy { $0.binding == .key(.z) })
        XCTAssertFalse(connected.failed)
    }

    func testFirstFailurePreventsRepeatedSlowDeliveryDuringCompensation() async throws {
        let sink = RecordingSink(), fence = GameTouchInputFailureFence(sink: sink)
        try await fence.set(.key(.control), pressed: true)
        sink.nextFailure = .transport
        do { try await fence.set(.key(.z), pressed: true); XCTFail("Transport fails") }
        catch { XCTAssertEqual(error as? RecordingSink.Failure, .transport) }
        for _ in 0..<64 {
            do { try await fence.set(.key(.control), pressed: false); XCTFail("Do not retry the failed transport") }
            catch { XCTAssertEqual(error as? GameTouchInputDeliveryError, .previousFailure) }
        }
        XCTAssertEqual(sink.events.count, 2)
        XCTAssertTrue(fence.failed)
    }

    func testInvalidationCannotSendToTheCapturedOrAnotherRun() async throws {
        let first = RecordingSink(), second = RecordingSink()
        let oldFence = GameTouchInputFailureFence(sink: first)
        let currentFence = GameTouchInputFailureFence(sink: second)
        oldFence.invalidate()
        do { try await oldFence.set(.key(.x), pressed: false); XCTFail("Old run is fenced") }
        catch { XCTAssertEqual(error as? GameTouchInputDeliveryError, .invalidated) }
        try await currentFence.set(.key(.x), pressed: true)
        XCTAssertTrue(first.events.isEmpty)
        XCTAssertEqual(second.events.count, 1)
    }

    func testCancellationWithUnknownDeliveryDoesNotRearmConnection() async throws {
        let sink = RecordingSink(), fence = GameTouchInputFailureFence(sink: sink)
        sink.nextFailure = .cancelled
        do { try await fence.set(.key(.z), pressed: true); XCTFail("Cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { try await fence.set(.key(.z), pressed: true); XCTFail("Do not replay an uncertain press") }
        catch { XCTAssertEqual(error as? GameTouchInputDeliveryError, .previousFailure) }
        XCTAssertEqual(sink.events.count, 1)
    }

    func testActualTouchQueueCanSwitchAfterFailedOldConnectionWithoutReleasingNewKeys() async throws {
        let profile = GameTouchProfile.standard(.rpgMakerVX)
        let button = try XCTUnwrap(profile.buttons.first)
        let service = GameTouchInputService(profile: profile)
        let oldSink = RecordingSink(), newSink = RecordingSink()
        let oldFence = GameTouchInputFailureFence(sink: oldSink)
        let newFence = GameTouchInputFailureFence(sink: newSink)
        await service.attach(oldFence)
        let oldAttachment = try XCTUnwrap(service.attachmentID)
        service.button(button.id, pressed: true, forAttachment: oldAttachment)
        await service.flush()
        XCTAssertEqual(oldSink.events.count, 1)
        oldSink.nextFailure = .transport
        await service.attach(newFence)
        XCTAssertTrue(oldFence.failed)
        let currentAttachment = try XCTUnwrap(service.attachmentID)
        XCTAssertNotEqual(currentAttachment, oldAttachment)
        service.button(button.id, pressed: true, forAttachment: currentAttachment)
        await service.flush()
        oldFence.invalidate()
        await service.releaseAll(forAttachment: oldAttachment)
        XCTAssertEqual(newSink.events.map(\.pressed), [true])
        await service.detach()
        XCTAssertEqual(newSink.events.map(\.pressed), [true, false])
        XCTAssertFalse(newFence.failed)
    }

    func testInvalidationDuringPendingDeliveryRejectsItsLateAcknowledgement() async throws {
        let sink = SuspendedSink(), fence = GameTouchInputFailureFence(sink: sink)
        let operation = Task { try await fence.set(.key(.z), pressed: true) }
        await sink.waitForAttempt()
        fence.invalidate()
        sink.complete()
        do { try await operation.value; XCTFail("The invalidated run cannot acknowledge a late result") }
        catch { XCTAssertEqual(error as? GameTouchInputDeliveryError, .invalidated) }
        XCTAssertFalse(fence.failed)
    }
}

@MainActor private final class SuspendedSink: GameTouchInputSink {
    private var delivery: CheckedContinuation<Void, Never>?
    private var attempt: CheckedContinuation<Void, Never>?
    private var started = false
    func set(_ binding: GameTouchBinding, pressed: Bool) async throws {
        await withCheckedContinuation { continuation in
            delivery = continuation; started = true
            attempt?.resume(); attempt = nil
        }
    }
    func waitForAttempt() async {
        if started { return }
        await withCheckedContinuation { attempt = $0 }
    }
    func complete() { delivery?.resume(); delivery = nil }
}

@MainActor private final class RecordingSink: GameTouchInputSink {
    struct Event { let binding: GameTouchBinding; let pressed: Bool }
    enum Failure: Error, Equatable { case transport, cancelled }
    var events: [Event] = []
    var nextFailure: Failure?
    func set(_ binding: GameTouchBinding, pressed: Bool) async throws {
        events.append(.init(binding: binding, pressed: pressed))
        if let failure = nextFailure {
            nextFailure = nil
            if failure == .cancelled { throw CancellationError() }
            throw failure
        }
    }
}
