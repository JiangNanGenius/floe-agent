// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameRGSS
import FloeGameWebKit
import FloeGameRGSSHostCore

private enum PlayStartupError: Error { case stop }
private actor PlayStartupJobs: RGSSGuestJobService {
    var failures: Int
    private(set) var stops = 0
    private(set) var launches = 0
    init(failures: Int) { self.failures = failures }
    func startOwnedJob(_ launch: RGSSGuestJobLaunch) async throws -> RGSSGuestJobHandle {
        launches += 1
        return .init(jobID: launch.jobID, ownerToken: launch.ownerToken)
    }
    func jobStatus(_ handle: RGSSGuestJobHandle) async throws -> RGSSGuestJobStatus {
        .init(handle: handle, state: .failed("fixture failed before publication"))
    }
    func stopOwnedJob(_ handle: RGSSGuestJobHandle) async throws {
        stops += 1
        if failures > 0 { failures -= 1; throw PlayStartupError.stop }
    }
}
private actor PlayStartupPhysicalInput: RGSSGuestPhysicalInputPort {
    func keyDown(_ key: GameKeyboardKey) async throws {}
    func keyUp(_ key: GameKeyboardKey) async throws {}
    func releaseAll() async {}
}
private struct PlayStartupDisplays: RGSSGuestDisplayProviding {
    func attach(_ request: RGSSGuestDisplayRequest) async throws -> RGSSGuestDisplayAttachment {
        try .init(environmentID: request.environmentID, displayServiceID: request.displayServiceID,
            guestDisplay: ":0", inputPort: PlayStartupPhysicalInput(),
            captureScreenshot: { nil }, detachViewer: {})
    }
    func detach(_ attachment: RGSSGuestDisplayAttachment) async {}
}
private struct PlayStartupContexts: GameRunContextHost {
    let context: GameProjectContext
    func currentContext(for captured: GameProjectContext) async throws -> GameProjectContext { context }
}
private struct PlayStartupMapping: RGSSGuestHostPathMapping {
    let root: URL
    func hostURL(forGuestPath path: String) throws -> URL {
        guard path.hasPrefix("/floe/env/") else { throw PlayStartupError.stop }
        return root.appendingPathComponent(String(path.dropFirst("/floe/env/".count)))
    }
}
private struct PlayStartupTarget: RGSSGuestTargetResolver {
    let value: RGSSGuestExecutionTarget
    func resolve(_ request: RGSSGuestLaunchRequest) async throws -> RGSSGuestExecutionTarget { value }
}
private struct PlayStartupTargets: RGSSGuestTargetResolverProviding {
    let root: URL
    func makeTarget(for staged: RGSSGuestStagedRun, display: RGSSGuestDisplayAttachment) async throws -> RGSSGuestTargetBinding {
        let value = try RGSSGuestExecutionTarget(environmentID: staged.request.environmentID,
            ownerToken: UUID(), guestProjectDirectory: "/workspace/source",
            guestRunDirectory: "/workspace/run", guestHomeDirectory: "/workspace/home",
            guestEngineBinary: "/floe/env/opt/floe/rgss/bin/tapir-x", guestDisplay: ":0",
            hostLogFile: root.appendingPathComponent("fixture.log"))
        return try .init(resolver: PlayStartupTarget(value: value),
            guestRunDirectory: value.guestRunDirectory, guestHomeDirectory: value.guestHomeDirectory,
            guestEngineBinary: value.guestEngineBinary, fileMapping: PlayStartupMapping(root: root))
    }
}

@MainActor
final class RGSSGuestStartupRetentionTests: XCTestCase {
    private func makeSession(failures: Int) throws -> (RGSSGuestPlaySession, PlayStartupJobs, URL) {
        let source = try RGSSGuestTestSupport.makeProject()
        let id = UUID()
        let context = try RGSSGuestTestSupport.context(for: id, owner: .space(recordID: id), root: source)
        let request = try RGSSGuestRunRequest(workspaceID: UUID(), context: context,
            engine: .rpgMakerXP, displayServiceID: "fixture-display")
        let root = try RGSSGuestTestSupport.temporaryDirectory("play-startup")
        let engineRoot = root.appendingPathComponent("opt/floe/rgss")
        let binary = engineRoot.appendingPathComponent("bin/tapir-x")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Synthetic ELF metadata fixture only. Jobs below never execute it.
        var header = [UInt8](repeating: 0, count: 64)
        header.replaceSubrange(0..<6, with: [0x7F, 0x45, 0x4C, 0x46, 2, 1])
        header[18] = 0xB7
        try Data(header).write(to: binary)
        let manifest: [String: Any] = ["engine": RGSSGuestEngineInstall.pinID,
            "sourcePins": ["tapir": RGSSGuestEngineInstall.sourceCommit],
            "binaries": ["xp": ["sha256": GameDigest.sha256(Data(header))]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: engineRoot.appendingPathComponent("VERSION.json"))
        for relative in ["licenses/tapir/LICENSE-APACHE", "licenses/tapir/COPYRIGHT", "licenses/ruby181/COPYING", "SOURCE-OFFER.md"] {
            try RGSSGuestTestSupport.write("synthetic fixture notice", to: engineRoot.appendingPathComponent(relative))
        }
        let jobs = PlayStartupJobs(failures: failures)
        let stager = RGSSGuestRunStager(layout: try .init(baseDirectory: root.appendingPathComponent("runs")))
        let play = RGSSGuestPlaySession(request: request, stager: stager, displays: PlayStartupDisplays(),
            targets: PlayStartupTargets(root: root), jobs: jobs, contexts: PlayStartupContexts(context: context))
        return (play, jobs, source)
    }

    func testFailedStartupAndUnconfirmedCleanupRetainRealJobForExplicitStop() async throws {
        let (play, jobs, source) = try makeSession(failures: 3)
        let before = try RGSSGuestSafeTreeDigestProbe.digest(source)
        do { try await play.start(); XCTFail("fixture start must fail") } catch {}
        XCTAssertNotNil(play.session, "unconfirmed startup cleanup must retain the concrete handle")
        XCTAssertEqual(play.lastStopOutcome?.status, .stopUnconfirmed)
        XCTAssertFalse(play.isRunning)
        let launches = await jobs.launches
        XCTAssertEqual(launches, 1)
        let outcome = await play.stop()
        XCTAssertEqual(outcome.status, .stopped)
        XCTAssertNil(play.session)
        XCTAssertEqual(try RGSSGuestSafeTreeDigestProbe.digest(source), before)
    }

    func testConfirmedFailedStartupCleanupReleasesTheSession() async throws {
        let (play, jobs, _) = try makeSession(failures: 0)
        do { try await play.start(); XCTFail("fixture start must fail") } catch {}
        XCTAssertNil(play.session)
        let outcome = await play.stop()
        XCTAssertEqual(outcome.status, .alreadyStopped)
        let stops = await jobs.stops
        XCTAssertEqual(stops, 1, "confirmed adapter cleanup should not issue an unrelated stop")
    }
}
