// FloeExecutionTests — ContainerLifecycle deletion participates in the fixed
// legacy-recovery-domain authority through the opaque App hook.
//
// The module stays independent of FloeExecution: the hook is a plain
// `ContainerLifecycleMaintenanceUse`. These tests prove the wrapper acquires
// the use BEFORE any registry/layer/disk work and always ends it, and that a
// refusing hook (the App adapter when exclusive maintenance owns the domain)
// aborts deletion with no side effect.

import Foundation
import XCTest
import FloeCore
import FloeEnvironments

final class ContainerLifecycleMaintenanceHookTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-lifecycle-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDeletionAcquiresAndEndsTheDomainUse() async throws {
        let recorder = UseRecorder()
        let lifecycle = try await makeLifecycle { _ in
            recorder.acquire()
            return recorder
        }
        let report = try await lifecycle.destroy(containerID: EnvironmentRegistry.sharedContainerID)
        XCTAssertNotNil(report)
        XCTAssertEqual(report?.containerID, EnvironmentRegistry.sharedContainerID)
        XCTAssertEqual(recorder.acquired, 1)
        XCTAssertEqual(recorder.ended, 1)
    }

    func testRefusingHookPreventsDeletion() async throws {
        let recorder = UseRecorder()
        let lifecycle = try await makeLifecycle { _ in
            recorder.acquire()
            throw BusyDomain()
        }
        do {
            _ = try await lifecycle.destroy(containerID: EnvironmentRegistry.sharedContainerID)
            XCTFail("a refusing maintenance hook must prevent deletion")
        } catch is BusyDomain {
            // Expected: nothing was read, moved or deleted.
        }
        XCTAssertEqual(recorder.acquired, 1)
        XCTAssertEqual(recorder.ended, 0)
    }

    private func makeLifecycle(
        hook: @escaping @Sendable (String) async throws -> (any ContainerLifecycleMaintenanceUse)?
    ) async throws -> ContainerLifecycle {
        let roots = EnvironmentRoots(rootURL: root)
        let registry = EnvironmentRegistry(roots: roots, baseRevision: "test")
        try await registry.prepare()
        let cas = ContainerCAS(roots: roots)
        return ContainerLifecycle(
            roots: roots,
            registry: registry,
            cas: cas,
            hooks: ContainerLifecycle.Hooks(beginMaintenanceUse: hook)
        )
    }
}

private struct BusyDomain: Error {}

private final class UseRecorder: ContainerLifecycleMaintenanceUse, @unchecked Sendable {
    private let lock = NSLock()
    private var acquiredCount = 0
    private var endedCount = 0

    func acquire() {
        lock.lock(); defer { lock.unlock() }
        acquiredCount += 1
    }

    var acquired: Int {
        lock.lock(); defer { lock.unlock() }
        return acquiredCount
    }

    var ended: Int {
        lock.lock(); defer { lock.unlock() }
        return endedCount
    }

    func end() async {
        lock.withLock { endedCount += 1 }
    }
}
