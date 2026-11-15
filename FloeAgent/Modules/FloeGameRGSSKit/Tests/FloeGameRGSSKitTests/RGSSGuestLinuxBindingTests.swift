// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameRGSS

private actor FakeJobService: RGSSGuestJobService {
    var launches: [RGSSGuestJobLaunch] = []
    var stopped: [UUID] = []
    var returnJobID: UUID?
    var state: RGSSGuestJobState = .running(frameRevision: 1)

    func startOwnedJob(_ launch: RGSSGuestJobLaunch) async throws -> RGSSGuestJobHandle {
        launches.append(launch)
        return RGSSGuestJobHandle(jobID: returnJobID ?? launch.jobID, ownerToken: launch.ownerToken)
    }

    func jobStatus(_ handle: RGSSGuestJobHandle) async throws -> RGSSGuestJobStatus {
        RGSSGuestJobStatus(handle: handle, state: state, elapsedMilliseconds: 1)
    }

    func stopOwnedJob(_ handle: RGSSGuestJobHandle) async throws {
        stopped.append(handle.jobID)
    }

    func launchCount() -> Int { launches.count }
    func stoppedIDs() -> [UUID] { stopped }
}

private struct FakeTargets: RGSSGuestTargetResolver {
    let target: RGSSGuestExecutionTarget
    func resolve(_ request: RGSSGuestLaunchRequest) async throws -> RGSSGuestExecutionTarget { target }
}

private actor FakeInputSession: RGSSGuestInputSession {
    var events: [String] = []
    var pressed: [RGSSGuestInputKey] = []
    func sendChord(_ keys: [RGSSGuestInputKey]) async throws {
        for key in keys {
            events.append("down:\(key.rawValue)")
            pressed.append(key)
        }
    }
    func releaseAll() async {
        for key in pressed.reversed() { events.append("up:\(key.rawValue)") }
        pressed.removeAll()
    }
    func invalidate() async { await releaseAll() }
    func recorded() -> [String] { events }
}

private actor FakeInputProvider: RGSSGuestInputPortProviding {
    var sessions: [FakeInputSession] = []
    func makeInputSession(for session: RGSSGuestSession) async throws -> any RGSSGuestInputSession {
        let s = FakeInputSession()
        sessions.append(s)
        return s
    }
    func last() -> FakeInputSession? { sessions.last }
}

private actor FakeContexts: RGSSGuestContextHost {
    var current: GameProjectContext
    init(_ current: GameProjectContext) { self.current = current }
    func currentContext(for captured: GameProjectContext) async throws -> GameProjectContext { current }
    func set(_ value: GameProjectContext) { current = value }
}

private func makeContext(root: URL, environmentID: String = "env-1") throws -> GameProjectContext {
    let id = UUID()
    return try GameProjectContext(projectID: id, owner: .space(recordID: id),
                                  rootURL: root, savedRevision: "rev-1", environmentID: environmentID)
}

private func makeRequest(context: GameProjectContext, engine: GameEngineID) throws -> RGSSGuestLaunchRequest {
    try RGSSGuestLaunchRequest(
        context: context, engine: engine, environmentID: context.environmentID!,
        projectRoot: context.rootURL, revision: context.savedRevision,
        sourceDigest: String(repeating: "a", count: 64),
        displayServiceID: "display-1", jobID: UUID())
}

final class RGSSGuestLinuxBindingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rgss-guest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeTarget(_ context: GameProjectContext, binary: String = "tapir-x",
                            environmentID: String = "env-1") throws -> RGSSGuestExecutionTarget {
        try RGSSGuestExecutionTarget(
            environmentID: environmentID,
            ownerToken: UUID(),
            guestProjectDirectory: "/workspace/project",
            guestRunDirectory: "/workspace/project/.floe/run-rev-1",
            guestHomeDirectory: "/workspace/project/.floe/home",
            guestEngineBinary: "/opt/floe/rgss/\(binary)",
            guestLibraryPath: "/opt/floe/rgss/lib",
            guestDisplay: ":0",
            hostLogFile: root.appendingPathComponent("engine.log"),
            environment: ["SDL_AUDIODRIVER": "dummy", "LC_ALL": "C.UTF-8"])
    }

    func testLaunchPlanIsFixedArgvNotShell() throws {
        let context = try makeContext(root: root)
        let request = try makeRequest(context: context, engine: .rpgMakerXP)
        let target = try makeTarget(context)
        let plan = try RGSSGuestLaunchPlanner.plan(request: request, target: target)
        XCTAssertEqual(plan.argv, ["/opt/floe/rgss/tapir-x", "-d", "/workspace/project/.floe/run-rev-1"])
        XCTAssertEqual(plan.workingDirectory, "/workspace/project/.floe/run-rev-1")
        XCTAssertEqual(plan.environment["HOME"], "/workspace/project/.floe/home")
        XCTAssertEqual(plan.environment["LD_LIBRARY_PATH"], "/opt/floe/rgss/lib")
        XCTAssertEqual(plan.environment["DISPLAY"], ":0")
        XCTAssertEqual(plan.environment["SDL_AUDIODRIVER"], "dummy")
        XCTAssertFalse(plan.argv.joined(separator: " ").contains(";"))
    }

    func testEnvironmentAndEngineMismatchFailClosed() throws {
        let context = try makeContext(root: root)
        let request = try makeRequest(context: context, engine: .rpgMakerXP)
        let wrongEnv = try makeTarget(context, environmentID: "env-2")
        XCTAssertThrowsError(try RGSSGuestLaunchPlanner.plan(request: request, target: wrongEnv)) {
            XCTAssertEqual($0 as? RGSSGuestHostError, .targetEnvironmentMismatch)
        }
        let wrongBinary = try makeTarget(context, binary: "tapir-v")
        XCTAssertThrowsError(try RGSSGuestLaunchPlanner.plan(request: request, target: wrongBinary)) {
            XCTAssertEqual($0 as? RGSSGuestHostError, .targetEngineMismatch)
        }
    }

    func testTargetRejectsTraversalAndArbitraryEnvironment() {
        XCTAssertThrowsError(try RGSSGuestExecutionTarget(
            environmentID: "env-1", ownerToken: UUID(),
            guestProjectDirectory: "/workspace/project",
            guestRunDirectory: "/workspace/project/../run",
            guestHomeDirectory: "/workspace/home",
            guestEngineBinary: "/opt/floe/rgss/tapir-x",
            guestDisplay: "localhost:0",
            hostLogFile: root.appendingPathComponent("log")))
        XCTAssertThrowsError(try RGSSGuestExecutionTarget(
            environmentID: "env-1", ownerToken: UUID(),
            guestProjectDirectory: "/workspace/project",
            guestRunDirectory: "/workspace/run",
            guestHomeDirectory: "/workspace/home",
            guestEngineBinary: "/opt/floe/rgss/tapir-x",
            guestDisplay: ":0",
            hostLogFile: root.appendingPathComponent("log"),
            environment: ["SECRET_TOKEN": "nope"]))
        XCTAssertThrowsError(try RGSSGuestExecutionTarget(
            environmentID: "env-1", ownerToken: UUID(),
            guestProjectDirectory: "/workspace/project",
            guestRunDirectory: "/workspace/run",
            guestHomeDirectory: "/workspace/home",
            guestEngineBinary: "/opt/floe/rgss/tapir-x",
            guestDisplay: "localhost:0",
            hostLogFile: root.appendingPathComponent("log")))
    }

    func testPortRejectsChangedJobIdentityAndStopsIt() async throws {
        let context = try makeContext(root: root)
        let request = try makeRequest(context: context, engine: .rpgMakerXP)
        let target = try makeTarget(context)
        let jobs = FakeJobService()
        await jobs.setReturnJobID(UUID())
        let port = RGSSLinuxGuestRuntimePort(targets: FakeTargets(target: target), jobs: jobs)
        do {
            _ = try await port.launch(request)
            XCTFail("expected jobIdentityMismatch")
        } catch {
            XCTAssertEqual(error as? RGSSGuestHostError, .jobIdentityMismatch)
        }
        let stopped = await jobs.stoppedIDs()
        XCTAssertEqual(stopped.count, 1)
    }

    func testSessionLifecycleAndOldCloseFencing() async throws {
        let context = try makeContext(root: root)
        let target = try makeTarget(context)
        let jobs = FakeJobService()
        let provider = FakeInputProvider()
        let contexts = FakeContexts(context)
        let controller = RGSSGuestHostController(
            targets: FakeTargets(target: target), jobs: jobs, inputs: provider, contexts: contexts)

        let first = try await controller.start(context: context, engine: .rpgMakerXP,
                                               displayServiceID: "display-1",
                                               sourceDigest: String(repeating: "a", count: 64))
        let second = try await controller.start(context: context, engine: .rpgMakerXP,
                                                displayServiceID: "display-1",
                                                sourceDigest: String(repeating: "a", count: 64))
        XCTAssertNotEqual(first.jobID, second.jobID)
        let stoppedAfterFence = await jobs.stoppedIDs()
        XCTAssertEqual(stoppedAfterFence, [first.jobID])

        do {
            try await controller.stop(first)
            XCTFail("old session must be fenced")
        } catch {
            XCTAssertEqual(error as? RGSSGuestHostError, .staleSession)
        }
        let stillStopped = await jobs.stoppedIDs()
        XCTAssertEqual(stillStopped, [first.jobID])

        try await controller.stop(second)
        let finalStopped = await jobs.stoppedIDs()
        XCTAssertEqual(finalStopped, [first.jobID, second.jobID])
    }

    func testDetachReleasesInputButKeepsJob() async throws {
        let context = try makeContext(root: root)
        let target = try makeTarget(context)
        let jobs = FakeJobService()
        let provider = FakeInputProvider()
        let controller = RGSSGuestHostController(
            targets: FakeTargets(target: target), jobs: jobs, inputs: provider, contexts: FakeContexts(context))
        let session = try await controller.start(context: context, engine: .rpgMakerXP,
                                                 displayServiceID: "display-1",
                                                 sourceDigest: String(repeating: "a", count: 64))
        try await controller.sendChord([.control, .right], for: session)
        let input = await provider.last()
        var beforeDetach: [String] = []
        if let input { beforeDetach = await input.recorded() }
        XCTAssertEqual(beforeDetach, ["down:control", "down:right"])
        try await controller.detachInput(session)
        var afterDetach: [String] = []
        if let input { afterDetach = await input.recorded() }
        XCTAssertEqual(afterDetach, ["down:control", "down:right", "up:right", "up:control"])
        let stopped = await jobs.stoppedIDs()
        XCTAssertTrue(stopped.isEmpty)
        try await controller.stop(session)
        let stoppedAfter = await jobs.stoppedIDs()
        XCTAssertEqual(stoppedAfter, [session.jobID])
    }

    func testChordOrderAndRelease() async throws {
        let port = RecordingInputPort()
        let controller = RGSSGuestInputController(port: port, profile: .standard(for: .rgss1))
        try await controller.sendChord([.right, .control, .shift])
        let down = await port.events()
        XCTAssertEqual(down, ["down:control", "down:shift", "down:right"])
        await controller.releaseAll()
        let all = await port.events()
        XCTAssertEqual(Array(all.suffix(3)), ["up:right", "up:shift", "up:control"])
        await controller.invalidate()
        do {
            try await controller.sendChord([.z])
            XCTFail("invalidated input must fail")
        } catch {
            XCTAssertEqual(error as? RGSSGuestHostError, .sessionNotActive)
        }
    }

    func testStandardInputProfilesMatchTapirDefaults() {
        let xp = RGSSGuestInputProfile.standard(for: .rgss1)
        XCTAssertEqual(xp.action(for: .z), .a)
        XCTAssertEqual(xp.action(for: .shift), .a)
        XCTAssertEqual(xp.action(for: .c), .c)
        XCTAssertEqual(xp.action(for: .enter), .c)
        XCTAssertEqual(xp.action(for: .x), .b)

        for version in [RGSSVersion.rgss2, .rgss3] {
            let vx = RGSSGuestInputProfile.standard(for: version)
            XCTAssertEqual(vx.action(for: .z), .c)
            XCTAssertNil(vx.action(for: .c))
            XCTAssertEqual(vx.action(for: .x), .b)
            XCTAssertEqual(vx.action(for: .shift), .a)
            XCTAssertEqual(vx.action(for: .enter), .c)
            XCTAssertEqual(vx.action(for: .q), .l)
            XCTAssertEqual(vx.action(for: .w), .r)
            XCTAssertEqual(vx.action(for: .a), .x)
            XCTAssertEqual(vx.action(for: .s), .y)
            XCTAssertEqual(vx.action(for: .d), .z)
        }
    }

    func testClosureBindingsLaunchAndInput() async throws {
        let context = try makeContext(root: root)
        let target = try makeTarget(context)
        let jobs = FakeJobService()
        let bindings = RGSSGuestHostBindings(
            resolveTarget: { _ in target },
            startJob: { launch in try await jobs.startOwnedJob(launch) },
            jobStatus: { handle in try await jobs.jobStatus(handle) },
            stopJob: { handle in try await jobs.stopOwnedJob(handle) },
            makeInput: { _ in FakeInputSession() })
        let controller = RGSSGuestHostController(bindings: bindings, contexts: FakeContexts(context))
        let session = try await controller.start(context: context, engine: .rpgMakerXP,
                                                 displayServiceID: "display-1",
                                                 sourceDigest: String(repeating: "a", count: 64))
        XCTAssertEqual(session.environmentID, "env-1")
        try await controller.sendChord([.c], for: session)
        try await controller.stop(session)
        let stopped = await jobs.stoppedIDs()
        XCTAssertEqual(stopped, [session.jobID])
    }

    func testX11KeySymRoundTrip() {
        for key in RGSSGuestInputKey.allCases {
            XCTAssertEqual(RGSSGuestInputKey(x11KeySym: key.x11KeySym), key)
        }
    }

    func testRunLayoutRejectsSourceMutation() throws {
        let source = root.appendingPathComponent("source")
        let run = root.appendingPathComponent("run")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let layout = try RGSSGuestRunLayout(sourceRoot: source, hostRunRoot: run,
                                            hostSaveDirectory: run.appendingPathComponent("Save"))
        XCTAssertEqual(layout.sourceRoot, source.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertThrowsError(try RGSSGuestRunLayout(
            sourceRoot: source, hostRunRoot: source.appendingPathComponent("run"),
            hostSaveDirectory: source.appendingPathComponent("run/Save")))
        XCTAssertThrowsError(try RGSSGuestRunLayout(
            sourceRoot: source, hostRunRoot: run,
            hostSaveDirectory: source.appendingPathComponent("Save")))
    }

    func testContextChangeInvalidatesStatus() async throws {
        let context = try makeContext(root: root)
        let target = try makeTarget(context)
        let jobs = FakeJobService()
        let provider = FakeInputProvider()
        let contexts = FakeContexts(context)
        let controller = RGSSGuestHostController(
            targets: FakeTargets(target: target), jobs: jobs, inputs: provider, contexts: contexts)
        let session = try await controller.start(context: context, engine: .rpgMakerXP,
                                                 displayServiceID: "display-1",
                                                 sourceDigest: String(repeating: "a", count: 64))
        let changed = try makeContext(root: root)
        await contexts.set(changed)
        do {
            _ = try await controller.status(session)
            XCTFail("changed context must invalidate status")
        } catch {
            XCTAssertEqual(error as? RGSSRuntimeError, .guestContextMismatch)
        }
    }
}

private actor RecordingInputPort: RGSSGuestInputPort {
    private var recorded: [String] = []
    func keyDown(_ key: RGSSGuestInputKey) async throws { recorded.append("down:\(key.rawValue)") }
    func keyUp(_ key: RGSSGuestInputKey) async throws { recorded.append("up:\(key.rawValue)") }
    func releaseAll() async {}
    func events() -> [String] { recorded }
}

private extension FakeJobService {
    func setReturnJobID(_ id: UUID) { returnJobID = id }
}
