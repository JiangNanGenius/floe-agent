// FloeExecutionTests — durable 9P share-access lease lifecycle.
//
// An external workspace share (an iOS security-scoped Files folder) is only
// readable while its grant is held, so the registry must: acquire it once per
// boot before the shares are used, release it only after the VM is confirmed
// stopped AND its runtime disk/slot work finished, keep it while a refused
// stop leaves a quarantined session behind, and fail the start closed when the
// provider reports the grant unavailable. Providers without durable share
// access (focused tests, host tools) keep the nil default unchanged.

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

// MARK: - Fakes

private final class LeaseLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var acquireCount = 0
    private var releaseCount = 0

    func didAcquire() { lock.lock(); acquireCount += 1; lock.unlock() }
    func didRelease() { lock.lock(); releaseCount += 1; lock.unlock() }

    var counts: (acquires: Int, releases: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (acquireCount, releaseCount)
    }
}

/// Provider with durable share access: counts acquires/releases or throws a
/// configured typed failure instead of handing out a lease.
private struct LeaseEnvironmentProvider: LinuxGuestEnvironmentProviding {
    let ledger: LeaseLedger
    let descriptors: [String: LinuxGuestEnvironmentDescriptor]
    var failure: LinuxGuestError?

    func linuxGuestEnvironment(id: String) async -> LinuxGuestEnvironmentDescriptor? { descriptors[id] }

    func acquireShareAccess(
        environmentID: String,
        descriptor: LinuxGuestEnvironmentDescriptor
    ) async throws -> LinuxGuestShareAccessLease? {
        if let failure { throw failure }
        ledger.didAcquire()
        return LinuxGuestShareAccessLease { [ledger] in ledger.didRelease() }
    }
}

private struct LeaseImageResolver: LinuxGuestImageResolving {
    let images: [String: LinuxGuestImage]

    func linuxGuestImage(id: String) async -> LinuxGuestImage? { images[id] }
}

private actor LeaseHandleState {
    private var running = false
    private var refusesStop = false

    func setRefusesStop(_ value: Bool) { refusesStop = value }
    func didStart() { running = true }
    func didStop() { if !refusesStop { running = false } }
    func isRunning() -> Bool { running }
}

/// Handles that can refuse the first stop (the engine budget case), leaving
/// the session quarantined with its lease still held.
private struct LeaseSessionFactory: LinuxGuestSessionCreating {
    let state: LeaseHandleState

    func makeSession(
        descriptor: LinuxGuestEnvironmentDescriptor,
        image: LinuxGuestImage,
        limits: LinuxGuestLimits
    ) throws -> LinuxGuestSessionHandle {
        let console = TestLinuxGuestConsole()
        return LinuxGuestSessionHandle(
            transport: console,
            start: { await state.didStart() },
            stop: { await state.didStop() },
            close: { await state.didStop() },
            isRunning: { await state.isRunning() },
            addForward: { _ in },
            removeForward: { _ in }
        )
    }
}

private func makeLeaseImage(qualified: Bool = true) -> LinuxGuestImage {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-lease-image-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let bios = directory.appendingPathComponent("bbl64.bin")
    let contents = Data("lease-bios".utf8)
    FileManager.default.createFile(atPath: bios.path, contents: contents)
    let artifacts = [
        LinuxGuestImageArtifact(
            role: .bios,
            path: bios.path,
            sha512: FloeDigest.sha512Hex(contents),
            bytes: Int64(contents.count)
        )
    ]
    return LinuxGuestImage(
        id: "lease-image",
        biosPath: bios.path,
        qualified: qualified,
        qualificationEvidence: qualified ? "lease protocol check" : nil,
        qualificationRun: qualified ? "run-lease" : nil,
        artifacts: qualified ? artifacts : nil
    )
}

private func makeWorkspaceDescriptor(id: String, imageID: String = "lease-image") -> (LinuxGuestEnvironmentDescriptor, URL) {
    let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-lease-workspace-\(UUID().uuidString)", isDirectory: true)
    let descriptor = LinuxGuestEnvironmentDescriptor(
        id: id,
        ownerID: "owner",
        shares: [LinuxGuestShare(tag: LinuxGuestShare.workspaceTag, hostDirectory: workspace)],
        imageID: imageID
    )
    return (descriptor, workspace)
}

private func makeRegistry(
    provider: LeaseEnvironmentProvider,
    image: LinuxGuestImage,
    factory: LeaseSessionFactory
) -> TinyEMULinuxGuestRegistry {
    TinyEMULinuxGuestRegistry(
        environments: provider,
        images: LeaseImageResolver(images: [image.id: image]),
        limits: .standard,
        factory: factory
    )
}

final class LinuxGuestShareAccessLeaseTests: XCTestCase {

    func testSuccessfulStartHoldsOneLeaseUntilTheConfirmedStop() async throws {
        let ledger = LeaseLedger()
        let state = LeaseHandleState()
        let (descriptor, _) = makeWorkspaceDescriptor(id: "env-lease")
        let registry = makeRegistry(
            provider: LeaseEnvironmentProvider(ledger: ledger, descriptors: ["env-lease": descriptor]),
            image: makeLeaseImage(),
            factory: LeaseSessionFactory(state: state)
        )

        let started = try await registry.start(environmentID: "env-lease", taskID: nil)
        XCTAssertTrue(started)
        XCTAssertEqual(ledger.counts.acquires, 1)
        XCTAssertEqual(ledger.counts.releases, 0, "the running VM must still hold its share access")

        // A second start of the already-running guest is a no-op: no second
        // hold is taken.
        _ = try await registry.start(environmentID: "env-lease", taskID: nil)
        XCTAssertEqual(ledger.counts.acquires, 1)

        await registry.stop(environmentID: "env-lease")
        XCTAssertEqual(ledger.counts.releases, 1, "a confirmed stop releases the share access exactly once")
        let running = await registry.status(environmentID: "env-lease").running
        XCTAssertFalse(running)
    }

    func testFailedStartReleasesTheLeaseBeforeAnyVmBoots() async throws {
        let ledger = LeaseLedger()
        let state = LeaseHandleState()
        let (descriptor, _) = makeWorkspaceDescriptor(id: "env-lease")
        let registry = makeRegistry(
            provider: LeaseEnvironmentProvider(ledger: ledger, descriptors: ["env-lease": descriptor]),
            image: makeLeaseImage(qualified: false),
            factory: LeaseSessionFactory(state: state)
        )

        do {
            _ = try await registry.start(environmentID: "env-lease", taskID: nil)
            XCTFail("an unqualified image must not start")
        } catch let error as LinuxGuestError {
            guard case .imageNotQualified = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertEqual(ledger.counts.acquires, 1)
        XCTAssertEqual(ledger.counts.releases, 1, "a start that never registered a session must not keep the grant open")
    }

    func testRefusedStopKeepsTheLeaseUntilALaterConfirmedStop() async throws {
        let ledger = LeaseLedger()
        let state = LeaseHandleState()
        await state.setRefusesStop(true)
        let (descriptor, _) = makeWorkspaceDescriptor(id: "env-lease")
        let registry = makeRegistry(
            provider: LeaseEnvironmentProvider(ledger: ledger, descriptors: ["env-lease": descriptor]),
            image: makeLeaseImage(),
            factory: LeaseSessionFactory(state: state)
        )
        _ = try await registry.start(environmentID: "env-lease", taskID: nil)

        await registry.stop(environmentID: "env-lease")
        XCTAssertEqual(ledger.counts.releases, 0, "a quarantined VM may still touch its shares; the lease stays held")
        let stillRunning = await registry.status(environmentID: "env-lease").running
        XCTAssertTrue(stillRunning)

        await state.setRefusesStop(false)
        await registry.stop(environmentID: "env-lease")
        XCTAssertEqual(ledger.counts.releases, 1, "the later successful stop is the one that releases the lease")
        let running = await registry.status(environmentID: "env-lease").running
        XCTAssertFalse(running)
    }

    func testUnavailableShareAccessFailsClosedBeforeTheVmBoots() async throws {
        let ledger = LeaseLedger()
        let state = LeaseHandleState()
        let (descriptor, _) = makeWorkspaceDescriptor(id: "env-lease")
        let provider = LeaseEnvironmentProvider(
            ledger: ledger,
            descriptors: ["env-lease": descriptor],
            failure: .shareAccessUnavailable(environmentID: "env-lease", detail: "grant refused")
        )
        let registry = makeRegistry(
            provider: provider,
            image: makeLeaseImage(),
            factory: LeaseSessionFactory(state: state)
        )

        do {
            _ = try await registry.start(environmentID: "env-lease", taskID: nil)
            XCTFail("a known external workspace without its grant must not start a VM")
        } catch let error as LinuxGuestError {
            guard case .shareAccessUnavailable(let id, let detail) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(id, "env-lease")
            XCTAssertEqual(detail, "grant refused")
        }
        let running = await registry.status(environmentID: "env-lease").running
        XCTAssertFalse(running)
        XCTAssertEqual(ledger.counts.acquires, 0, "nothing was acquired, so nothing may be released")
        // The failed start left no in-flight state behind: a later start with
        // a working provider succeeds on the same environment id.
        let working = makeRegistry(
            provider: LeaseEnvironmentProvider(ledger: LeaseLedger(), descriptors: ["env-lease": descriptor]),
            image: makeLeaseImage(),
            factory: LeaseSessionFactory(state: state)
        )
        let retry = try await working.start(environmentID: "env-lease", taskID: nil)
        XCTAssertTrue(retry)
    }

    func testProviderWithoutDurableShareAccessKeepsThePreviousBehavior() async throws {
        let ledger = FakeSessionLedger()
        let factory = FakeSessionFactory(ledger: ledger) { _, _ in [] }
        let (descriptor, _) = makeWorkspaceDescriptor(id: "env-legacy")
        let registry = TinyEMULinuxGuestRegistry(
            environments: FakeEnvironmentProvider(descriptors: ["env-legacy": descriptor]),
            images: LeaseImageResolver(images: ["lease-image": makeLeaseImage()]),
            limits: .standard,
            factory: factory
        )

        let started = try await registry.start(environmentID: "env-legacy", taskID: nil)
        XCTAssertTrue(started)
        await registry.stop(environmentID: "env-legacy")
        let running = await registry.status(environmentID: "env-legacy").running
        XCTAssertFalse(running)
    }
}
