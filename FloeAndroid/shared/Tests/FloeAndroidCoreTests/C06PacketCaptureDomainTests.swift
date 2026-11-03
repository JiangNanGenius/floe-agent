// SPDX-License-Identifier: MPL-2.0
//
// C06 focused deterministic contract tests. AUTHORED, NOT EXECUTED by the
// source-only lane. Real VPN/root forwarding remains Main's device
// qualification.
import XCTest
import Foundation
@testable import FloeAndroidCore

final class C06PacketCaptureDomainTests: XCTestCase {

    override func setUp() {
        super.setUp()
        C06CaptureRegistry.shared.reset()
    }

    private func owner() throws -> C06CaptureOwner {
        try C06CaptureOwner(
            ownerID: "capture-test",
            nativeEpoch: 7,
            workspaceID: UUID().uuidString,
        )
    }

    private func request(_ mode: C06CaptureMode = .vpn) throws -> C06CaptureRequest {
        try C06CaptureRequest(
            owner: try owner(),
            mode: mode,
            detailed: true,
            durationMillis: mode == .root ? 60_000 : 300_000,
            maxBytes: 128 * 1024 * 1024,
            maxPackets: 2_000_000,
        )
    }

    private func snapshot(_ sessionID: String, _ phase: C06CapturePhase,
                          packets: Int64 = 0, bytes: Int64 = 0,
                          stopRequested: Bool = false,
                          analysisID: String? = nil) throws -> C06CaptureSnapshot {
        try C06CaptureSnapshot(
            sessionID: sessionID,
            phase: phase,
            capturedPackets: packets,
            capturedBytes: bytes,
            droppedPackets: 0,
            analysisID: analysisID,
            stopRequested: stopRequested,
        )
    }

    func testOwnerAndLimitsAreBounded() throws {
        XCTAssertThrowsError(try C06CaptureOwner(ownerID: "", nativeEpoch: 1))
        XCTAssertThrowsError(try C06CaptureOwner(ownerID: "ok", nativeEpoch: 0))
        XCTAssertThrowsError(try C06CaptureRequest(
            owner: try owner(), mode: .vpn, detailed: false,
            durationMillis: C06CaptureLimits.vpnDurationMillis + 1,
            maxBytes: 128 * 1024 * 1024, maxPackets: 1,
        ))
        XCTAssertThrowsError(try C06CaptureRequest(
            owner: try owner(), mode: .root, detailed: false,
            durationMillis: C06CaptureLimits.rootDurationMillis + 1,
            maxBytes: 128 * 1024 * 1024, maxPackets: 1,
        ))
        let request = try self.request()
        XCTAssertEqual(request.mode, .vpn)
        XCTAssertEqual(request.mtu, 1_500)
    }

    func testBeginUpdateFinishRequiresStopReasonAndAnalysis() throws {
        let registry = C06CaptureRegistry()
        let started = try registry.begin(try request())
        XCTAssertEqual(started.phase, .consentRequired)
        var state = try registry.update(try snapshot(started.sessionID, .starting))
        state = try registry.update(try snapshot(started.sessionID, .running, packets: 3, bytes: 120))
        XCTAssertEqual(state.phase, .running)
        state = try registry.update(try snapshot(
            started.sessionID, .stopping, packets: 3, bytes: 120, stopRequested: true))
        XCTAssertEqual(state.phase, .stopping)
        XCTAssertThrowsError(try registry.finish(try snapshot(
            started.sessionID, .completed, packets: 3, bytes: 120, stopRequested: true)))
        let finished = try registry.finish(try snapshot(
            started.sessionID, .completed, packets: 3, bytes: 120,
            stopRequested: true, analysisID: UUID().uuidString))
        XCTAssertEqual(finished.phase, .completed)
        XCTAssertEqual(registry.activeCount(), 0)
    }

    func testCountersCannotRegressAndCancelIsNotStopped() throws {
        let registry = C06CaptureRegistry()
        let started = try registry.begin(try request())
        _ = try registry.update(try snapshot(started.sessionID, .starting))
        let running = try registry.update(try snapshot(
            started.sessionID, .running, packets: 5, bytes: 200))
        XCTAssertThrowsError(try registry.update(try snapshot(
            started.sessionID, .running, packets: 4, bytes: 200)))
        XCTAssertTrue(registry.requestCancel(sessionID: running.sessionID))
        let cancelled = registry.snapshot(sessionID: running.sessionID)
        XCTAssertEqual(cancelled?.phase, .running)
        XCTAssertEqual(cancelled?.stopRequested, true)
        let terminal = try registry.finish(try snapshot(
            started.sessionID, .cancelled, packets: 5, bytes: 200, stopRequested: true))
        XCTAssertEqual(terminal.phase, .cancelled)
    }

    func testOneActiveSessionAndRootPolicy() throws {
        let registry = C06CaptureRegistry()
        _ = try registry.begin(try request())
        XCTAssertThrowsError(try registry.begin(try request(.root)))
        XCTAssertEqual(C06RootPolicy.evaluate(
            playBuild: true, rootEnabled: true, helperPath: "/data/local/tmp/floe/tcpdump").code,
            "playBuild")
        XCTAssertEqual(C06RootPolicy.evaluate(
            playBuild: false, rootEnabled: false, helperPath: "/data/local/tmp/floe/tcpdump").code,
            "rootNotEnabled")
        XCTAssertEqual(C06RootPolicy.evaluate(
            playBuild: false, rootEnabled: true, helperPath: nil).code,
            "helperUnavailable")
        XCTAssertTrue(C06RootPolicy.evaluate(
            playBuild: false, rootEnabled: true,
            helperPath: "/data/local/tmp/floe/tcpdump").available)
    }

    func testBridgeBeginStatusAndCancelAll() throws {
        let request: [String: Any] = [
            "version": C06CaptureWire.version,
            "operation": "c06.capture.begin",
            "requestID": "test-1",
            "request": try self.request().wire,
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let response = C06PacketCaptureBridge.handle(requestData: data, fallbackRequestID: nil)
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertNotNil(response["sessionId"] as? String)

        let statusRequest: [String: Any] = [
            "version": C06CaptureWire.version,
            "operation": "c06.capture.status",
            "requestID": "test-2",
        ]
        let statusData = try JSONSerialization.data(withJSONObject: statusRequest)
        let status = C06PacketCaptureBridge.handle(requestData: statusData, fallbackRequestID: nil)
        XCTAssertEqual(status["ok"] as? Bool, true)
        XCTAssertEqual((status["activeCount"] as? NSNumber)?.intValue, 1)

        let cancelRequest: [String: Any] = [
            "version": C06CaptureWire.version,
            "operation": "c06.capture.cancelAll",
        ]
        let cancelData = try JSONSerialization.data(withJSONObject: cancelRequest)
        let cancelled = C06PacketCaptureBridge.handle(requestData: cancelData, fallbackRequestID: nil)
        XCTAssertEqual(cancelled["ok"] as? Bool, true)
        XCTAssertEqual((cancelled["cancelled"] as? NSNumber)?.intValue, 1)
    }

    func testHandshakeUsesClosedWireIdentity() throws {
        let request: [String: Any] = [
            "version": C06CaptureWire.version,
            "operation": "handshake",
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let response = C06PacketCaptureBridge.handle(requestData: data, fallbackRequestID: nil)
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(response["schema"] as? String, "floe.capture/10")
        XCTAssertEqual((response["operations"] as? [String])?.count, C06CaptureWire.operations.count)
    }
}
