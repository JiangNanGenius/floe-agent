// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameRGSS

private enum OwnedStopFailure: Error { case transport }

private actor RetryableOwnedJobs: RGSSGuestJobService {
    private var remainingFailures: Int
    private var launches = 0
    private var stops = 0
    private var substituteStatusOwner = false

    init(failures: Int = 1) { remainingFailures = failures }

    func startOwnedJob(_ launch: RGSSGuestJobLaunch) async throws -> RGSSGuestJobHandle {
        launches += 1
        return .init(jobID: launch.jobID, ownerToken: launch.ownerToken)
    }
    func jobStatus(_ handle: RGSSGuestJobHandle) async throws -> RGSSGuestJobStatus {
        let result = substituteStatusOwner
            ? RGSSGuestJobHandle(jobID: handle.jobID, ownerToken: UUID()) : handle
        return .init(handle: result, state: .running(frameRevision: 0))
    }
    func stopOwnedJob(_ handle: RGSSGuestJobHandle) async throws {
        stops += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw OwnedStopFailure.transport
        }
    }
    func counts() -> (launches: Int, stops: Int) { (launches, stops) }
    func changeStatusOwner() { substituteStatusOwner = true }
}

private struct OwnedStopTarget: RGSSGuestTargetResolver {
    let target: RGSSGuestExecutionTarget
    func resolve(_ request: RGSSGuestLaunchRequest) async throws -> RGSSGuestExecutionTarget { target }
}

private struct OwnedStopContext: RGSSGuestContextHost {
    let context: GameProjectContext
    func currentContext(for captured: GameProjectContext) async throws -> GameProjectContext { context }
}

private actor OwnedStopInput: RGSSGuestInputSession {
    func sendChord(_ keys: [RGSSGuestInputKey]) async throws {}
    func releaseAll() async {}
    func invalidate() async {}
}

private struct OwnedStopInputs: RGSSGuestInputPortProviding {
    func makeInputSession(for session: RGSSGuestSession) async throws -> any RGSSGuestInputSession {
        OwnedStopInput()
    }
}

@MainActor
final class RGSSOwnedStopRegressionTests: XCTestCase {
    private struct Fixture {
        let context: GameProjectContext
        let request: RGSSGuestLaunchRequest
        let targets: OwnedStopTarget
        let jobs: RetryableOwnedJobs
        let port: RGSSLinuxGuestRuntimePort

        func controller() -> RGSSGuestHostController {
            .init(port: port, inputs: OwnedStopInputs(), contexts: OwnedStopContext(context: context))
        }
    }

    private func fixture(failures: Int = 1) throws -> Fixture {
        let id = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("owned-stop-\(id)")
        let context = try GameProjectContext(projectID: id, owner: .space(recordID: id),
            rootURL: root, savedRevision: "saved", environmentID: "owned-env")
        let request = try RGSSGuestLaunchRequest(context: context, engine: .rpgMakerXP,
            environmentID: "owned-env", projectRoot: root, revision: "saved",
            sourceDigest: String(repeating: "a", count: 64), displayServiceID: "display", jobID: UUID())
        let target = try RGSSGuestExecutionTarget(environmentID: "owned-env", ownerToken: UUID(),
            guestProjectDirectory: "/workspace/source", guestRunDirectory: "/workspace/run",
            guestHomeDirectory: "/workspace/home", guestEngineBinary: "/opt/floe/rgss/tapir-x",
            guestDisplay: ":0", hostLogFile: root.appendingPathComponent("run.log"))
        let jobs = RetryableOwnedJobs(failures: failures)
        let targets = OwnedStopTarget(target: target)
        return Fixture(context: context, request: request, targets: targets,
                       jobs: jobs, port: RGSSLinuxGuestRuntimePort(targets: targets, jobs: jobs))
    }

    private func start(_ controller: RGSSGuestHostController, _ fixture: Fixture) async throws -> RGSSGuestSession {
        try await controller.start(context: fixture.context, engine: .rpgMakerXP,
            displayServiceID: "display", sourceDigest: String(repeating: "a", count: 64))
    }

    func testFailedStopRetainsExactOwnerForStatusAndRetry() async throws {
        let f = try fixture()
        let handle = try await f.port.launch(f.request)
        do { try await f.port.stop(handle); XCTFail("transport failure must propagate") }
        catch { XCTAssertTrue(error is OwnedStopFailure) }
        let status = try await f.port.status(handle)
        XCTAssertEqual(status.handle, handle)
        try await f.port.stop(handle)
        let counts = await f.jobs.counts()
        XCTAssertEqual(counts.stops, 2)
        do { _ = try await f.port.status(handle); XCTFail("confirmed stop must retire ownership") }
        catch { XCTAssertEqual(error as? RGSSGuestHostError, .jobNotOwned) }
    }

    func testWrongOwnerCannotStatusOrConsumeAnotherOwnersStop() async throws {
        let f = try fixture(failures: 0)
        let handle = try await f.port.launch(f.request)
        let wrong = RGSSGuestJobHandle(jobID: handle.jobID, ownerToken: UUID())
        do { _ = try await f.port.status(wrong); XCTFail("wrong owner") }
        catch { XCTAssertEqual(error as? RGSSGuestHostError, .jobNotOwned) }
        do { try await f.port.stop(wrong); XCTFail("wrong owner") }
        catch { XCTAssertEqual(error as? RGSSGuestHostError, .jobNotOwned) }
        let before = await f.jobs.counts()
        XCTAssertEqual(before.stops, 0)
        try await f.port.stop(handle)
    }

    func testStatusCannotSubstituteAnUnrelatedHandle() async throws {
        let f = try fixture(failures: 0)
        let handle = try await f.port.launch(f.request)
        await f.jobs.changeStatusOwner()
        do { _ = try await f.port.status(handle); XCTFail("substituted identity") }
        catch { XCTAssertEqual(error as? RGSSGuestHostError, .jobIdentityMismatch) }
        try await f.port.stop(handle)
    }

    func testDuplicateLaunchCannotReplaceOwnedJob() async throws {
        let f = try fixture(failures: 0)
        let handle = try await f.port.launch(f.request)
        do { _ = try await f.port.launch(f.request); XCTFail("duplicate job identity") }
        catch { XCTAssertEqual(error as? RGSSGuestHostError, .jobIdentityMismatch) }
        let counts = await f.jobs.counts()
        XCTAssertEqual(counts.launches, 1)
        try await f.port.stop(handle)
    }

    func testControllerStopCanRetryAfterHostFailure() async throws {
        let f = try fixture()
        let controller = f.controller()
        let session = try await start(controller, f)
        do { try await controller.stop(session); XCTFail("first stop must fail") }
        catch { XCTAssertTrue(error is OwnedStopFailure) }
        let status = try await controller.status(session)
        XCTAssertEqual(status.handle.jobID, session.jobID)
        try await controller.stop(session)
        let counts = await f.jobs.counts()
        XCTAssertEqual(counts.stops, 2)
    }

    func testFailedReplacementDoesNotAbandonOrLaunchOverOwnedJob() async throws {
        let f = try fixture()
        let controller = f.controller()
        let session = try await start(controller, f)
        do { _ = try await start(controller, f); XCTFail("unconfirmed old stop must block replacement") }
        catch { XCTAssertTrue(error is OwnedStopFailure) }
        let counts = await f.jobs.counts()
        XCTAssertEqual(counts.launches, 1)
        let status = try await controller.status(session)
        XCTAssertEqual(status.handle.jobID, session.jobID)
        try await controller.stop(session)
    }

    func testBestEffortCloseDoesNotForgetAnUnconfirmedJob() async throws {
        let f = try fixture()
        let controller = f.controller()
        let session = try await start(controller, f)
        await controller.closeIfActive(session)
        let status = try await controller.status(session)
        XCTAssertEqual(status.handle.jobID, session.jobID)
        try await controller.stop(session)
        let counts = await f.jobs.counts()
        XCTAssertEqual(counts.stops, 2)
    }
}
