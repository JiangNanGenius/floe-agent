// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameRGSS

private actor SuspendedKeyboard: RGSSGuestInputPort {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var recorded: [String] = []
    private let failRight: Bool
    private let suspend: Bool
    init(suspend: Bool = true, failRight: Bool = false) {
        self.suspend = suspend; self.failRight = failRight
    }
    func keyDown(_ key: RGSSGuestInputKey) async throws {
        if key == .right && suspend {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        recorded.append("down:"+key.rawValue)
        if key == .right && failRight { throw RGSSGuestHostError.inputUnavailable }
    }
    func keyUp(_ key: RGSSGuestInputKey) async throws { recorded.append("up:"+key.rawValue) }
    func releaseAll() async {}
    func resume() { continuation?.resume(); continuation = nil }
    func events() -> [String] { recorded }
}

private actor SessionKeyboard: RGSSGuestInputSession {
    func sendChord(_ keys: [RGSSGuestInputKey]) async throws {}
    func releaseAll() async {}
    func invalidate() async {}
}

private actor SuspendedInputProvider: RGSSGuestInputPortProviding {
    var count = 0
    private var continuation: CheckedContinuation<Void,Never>?
    func makeInputSession(for session: RGSSGuestSession) async throws -> any RGSSGuestInputSession {
        count += 1
        if count == 1 { await withCheckedContinuation { continuation = $0 } }
        return SessionKeyboard()
    }
    func resume() { continuation?.resume(); continuation = nil }
}

private actor SessionJobs: RGSSGuestRuntimePort {
    private var stopped: [UUID] = []
    func launch(_ request: RGSSGuestLaunchRequest) async throws -> RGSSGuestJobHandle {
        .init(jobID: request.jobID, ownerToken: UUID())
    }
    func status(_ handle: RGSSGuestJobHandle) async throws -> RGSSGuestJobStatus {
        .init(handle: handle, state: .running(frameRevision: 1))
    }
    func stop(_ handle: RGSSGuestJobHandle) async throws { stopped.append(handle.jobID) }
    func stoppedJobs() -> [UUID] { stopped }
}

private struct FixedGuestContext: RGSSGuestContextHost {
    let context: GameProjectContext
    func currentContext(for captured: GameProjectContext) async throws -> GameProjectContext { context }
}

final class RGSSInputLifecycleTests: XCTestCase {
    private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw RGSSGuestHostError.sessionNotActive
    }

    func testInvalidateCompensatesADownThatCompletesLate() async throws {
        let port = SuspendedKeyboard()
        let input = RGSSGuestInputController(port: port, profile: .standard(for: .rgss1))
        let down = Task { try await input.sendChord([.right]) }
        try await waitUntil { await port.entered }
        let close = Task { await input.invalidate() }
        try await waitUntil { await input.invalidated }
        await port.resume()
        await close.value
        do { try await down.value; XCTFail("late down must be fenced") }
        catch { XCTAssertEqual(error as? RGSSGuestHostError, .sessionNotActive) }
        let events = await port.events(), held = await input.currentPressedKeys()
        XCTAssertEqual(events, ["down:right","up:right"])
        XCTAssertTrue(held.isEmpty)
    }

    func testFailedDownReleasesAttemptedKeyAndEarlierModifier() async throws {
        let port = SuspendedKeyboard(suspend: false, failRight: true)
        let input = RGSSGuestInputController(port: port, profile: .standard(for: .rgss1))
        do { try await input.sendChord([.control,.right]); XCTFail("transport failure must propagate") }
        catch { XCTAssertEqual(error as? RGSSGuestHostError, .inputUnavailable) }
        let events = await port.events(), held = await input.currentPressedKeys()
        XCTAssertEqual(events, ["down:control","down:right","up:right","up:control"])
        XCTAssertTrue(held.isEmpty)
    }

    func testReleaseIsSerializedBeforeANewerChord() async throws {
        let port = SuspendedKeyboard()
        let input = RGSSGuestInputController(port: port, profile: .standard(for: .rgss1))
        let old = Task { try await input.sendChord([.right]) }
        try await waitUntil { await port.entered }
        let release = Task { await input.releaseAll() }
        try await waitUntil { await input.generation > 0 }
        let newer = Task { try await input.sendChord([.z]) }
        await port.resume()
        _ = try? await old.value
        await release.value
        try await newer.value
        let events = await port.events()
        XCTAssertEqual(events, ["down:right","up:right","down:z"])
        await input.invalidate()
    }

    func testLateSessionCreationCannotReplaceTheNewSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let context = try GameProjectContext(projectID: id, owner: .space(recordID: id),
            rootURL: root, savedRevision: "saved", environmentID: "guest-test")
        let jobs = SessionJobs(), inputs = SuspendedInputProvider()
        let host = RGSSGuestHostController(port: jobs, inputs: inputs, contexts: FixedGuestContext(context: context))
        let first = Task { try await host.start(context: context, engine: .rpgMakerXP,
            displayServiceID: "display", sourceDigest: String(repeating: "a",count: 64)) }
        try await waitUntil { await inputs.count == 1 }
        let second = try await host.start(context: context, engine: .rpgMakerXP,
            displayServiceID: "display", sourceDigest: String(repeating: "a",count: 64))
        await inputs.resume()
        do { _ = try await first.value; XCTFail("late old start must be fenced") }
        catch { XCTAssertEqual(error as? RGSSGuestHostError, .staleSession) }
        try await host.sendChord([.z], for: second)
        let stopped = await jobs.stoppedJobs()
        XCTAssertEqual(stopped.count, 1)
        XCTAssertFalse(stopped.contains(second.jobID))
        try await host.stop(second)
    }
}
