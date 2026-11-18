// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeToolboxUtilities
import FloeMacMediaSystem
@testable import FloeMacToolbox

private enum ClockFixtureError: Error { case write }

private actor ClockGate {
    private var entered = false
    private var observer: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true; observer?.resume(); observer = nil
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}

private actor FakeSilentClockStore: MacSilentClockStoring {
    private var archive: ToolboxTimekeepingArchive
    private let loadGate: ClockGate?
    private let saveGate: ClockGate?
    private var failCount: Int
    private let commitBeforeFailure: Bool
    private(set) var loads = 0
    init(loadGate: ClockGate? = nil, saveGate: ClockGate? = nil, failCount: Int = 0,
         commitBeforeFailure: Bool = false, initial: ToolboxTimekeepingArchive = .init()) {
        self.loadGate = loadGate; self.saveGate = saveGate; self.failCount = failCount
        self.commitBeforeFailure = commitBeforeFailure
        self.archive = initial
    }
    func load() async throws -> ToolboxTimekeepingArchive {
        loads += 1
        if let loadGate { await loadGate.wait() }
        return archive
    }
    func save(_ value: ToolboxTimekeepingArchive) async throws {
        if let saveGate { await saveGate.wait() }
        if failCount > 0 {
            failCount -= 1
            if commitBeforeFailure { archive = value }
            throw ClockFixtureError.write
        }
        archive = value
    }
    func snapshot() -> ToolboxTimekeepingArchive { archive }
}

@Suite("Mac silent timekeeping owner", .serialized)
@MainActor struct MacSilentTimekeepingTests {
    @Test func firstTimerCreationAfterQuitDrainRemainsClosedUntilQuitIsCancelled() async throws {
        let root = try MacToolboxTestRoot.unique("silent-clock-late-owner")
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = MacToolboxServices(storageRoot: root, mediaEnvironment: MacToolboxMediaEnvironment())
        owner.closeAdmissionsForTermination()
        #expect(await owner.drainForTermination())

        let timer = owner.silentTimekeeping()
        await timer.load()
        timer.addTimer(name: "Too late", seconds: 60)
        #expect(!timer.loaded)
        #expect(timer.archive.timers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("MacTimekeeping").path))
        #expect(await owner.drainForTermination())

        owner.resumeAfterCancelledTermination()
        await timer.load()
        #expect(timer.loaded)
        timer.addTimer(name: "After cancellation", seconds: 60)
        owner.closeAdmissionsForTermination()
        #expect(await owner.drainForTermination())
        #expect(timer.archive.timers.map(\.label) == ["After cancellation"])
    }

    @Test func terminalOwnerCannotReviveLateTimerWhenQuitCancellationArrives() async throws {
        let root = try MacToolboxTestRoot.unique("silent-clock-terminal-owner")
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = MacToolboxServices(storageRoot: root, mediaEnvironment: MacToolboxMediaEnvironment())
        owner.shutdown()
        owner.resumeAfterCancelledTermination()
        let timer = owner.silentTimekeeping()
        await timer.load()
        timer.addTimer(name: "Too late", seconds: 60)
        #expect(!timer.loaded)
        #expect(timer.archive.timers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("MacTimekeeping").path))
    }

    @Test func fastReopenJoinsOwnerLoadInsteadOfUsingExpiredPage() async {
        let gate = ClockGate(), store = FakeSilentClockStore(loadGate: gate)
        let service = MacSilentTimekeeping(store: store)
        let first = Task { await service.load() }
        await gate.waitUntilEntered()
        first.cancel()
        let second = Task { await service.load() }
        await gate.release()
        await first.value; await second.value
        #expect(service.loaded)
        #expect(await store.loads == 1)
    }

    @Test func acceptedWriteSurvivesPageAndQuitWaitsUntilItFinishes() async {
        let gate = ClockGate(), store = FakeSilentClockStore(saveGate: gate)
        let service = MacSilentTimekeeping(store: store)
        await service.load()
        service.addTimer(name: "Fixture", seconds: 300)
        await gate.waitUntilEntered()
        service.closeAdmissions()
        service.addTimer(name: "Too late", seconds: 60)
        #expect(!(await service.drain(timeout: 0.05)))
        await gate.release()
        #expect(await service.drain(timeout: 2))
        #expect((await store.snapshot()).timers.map(\.label) == ["Fixture"])
        service.resumeAfterCancelledTermination()
        #expect(service.archive.timers.map(\.label) == ["Fixture"])
    }

    @Test func failedWriteBlocksQuitUntilRetryOrExplicitOneShotChoice() async {
        let store = FakeSilentClockStore(failCount: 2)
        let service = MacSilentTimekeeping(store: store)
        await service.load()
        service.addTimer(name: "Fixture", seconds: 300)
        service.closeAdmissions()
        #expect(!(await service.drain(timeout: 2)))
        #expect(service.issue == .save)
        service.resumeAfterCancelledTermination()
        service.allowExitWithoutConfirmedSave()
        service.closeAdmissions()
        #expect(await service.drain(timeout: 2))
        service.resumeAfterCancelledTermination()
        service.closeAdmissions()
        #expect(!(await service.drain(timeout: 2)))
        service.resumeAfterCancelledTermination()
        service.retrySave()
        service.closeAdmissions()
        #expect(!(await service.drain(timeout: 2)))
        service.resumeAfterCancelledTermination()
        service.retrySave()
        service.closeAdmissions()
        #expect(await service.drain(timeout: 2))
        #expect((await store.snapshot()).timers.map(\.label) == ["Fixture"])
    }

    @Test func realIsolatedStoreRetainsStateAndRejectsSecondOwner() async throws {
        let root = try MacToolboxTestRoot.unique("silent-clock")
        defer { try? FileManager.default.removeItem(at: root) }
        let privateRoot = root.appendingPathComponent("private-clock", isDirectory: true)
        let store = MacSilentClockStore(root: privateRoot)
        let service = MacSilentTimekeeping(store: store)
        await service.load()
        service.addTimer(name: "Fixture", seconds: 300)
        service.closeAdmissions()
        #expect(await service.drain(timeout: 2))
        #expect(try await store.load().timers.map(\.label) == ["Fixture"])
        let other = MacSilentClockStore(root: privateRoot)
        await #expect(throws: ToolboxTimekeepingError.staleArchive) { try await other.load() }
    }

    @Test func postCommitErrorRetryKeepsOneTimerAndBlocksQuitUntilConfirmed() async {
        let store = FakeSilentClockStore(failCount: 1, commitBeforeFailure: true)
        let service = MacSilentTimekeeping(store: store)
        await service.load()
        service.addTimer(name: "Fixture", seconds: 300)
        service.closeAdmissions()
        #expect(!(await service.drain(timeout: 2)))
        #expect((await store.snapshot()).timers.count == 1)
        service.resumeAfterCancelledTermination()
        service.retrySave()
        service.closeAdmissions()
        #expect(await service.drain(timeout: 2))
        #expect((await store.snapshot()).timers.count == 1)
    }

    @Test func corruptArchiveIsPreservedAndCannotBeOverwritten() async throws {
        let root = try MacToolboxTestRoot.unique("silent-clock-corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let privateRoot = root.appendingPathComponent("private-clock", isDirectory: true)
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = privateRoot.appendingPathComponent("state.json")
        let original = Data("{broken".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let service = MacSilentTimekeeping(store: MacSilentClockStore(root: privateRoot))
        await service.load()
        #expect(service.issue == .load)
        service.addTimer(name: "Must not write", seconds: 60)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func silentCountdownFinishesWithoutAnAttachedPage() async throws {
        let store = FakeSilentClockStore()
        let service = MacSilentTimekeeping(store: store)
        await service.load()
        service.addTimer(name: "Short", seconds: 0.05)
        let deadline = ContinuousClock.now + .seconds(2)
        while service.archive.timers.first?.phase != .finished, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(service.archive.timers.first?.phase == .finished)
        service.closeAdmissions()
        #expect(await service.drain(timeout: 2))
        #expect((await store.snapshot()).timers.first?.phase == .finished)
    }

    @Test func savedTimerLoadsIntoARecreatedOwner() async {
        let store = FakeSilentClockStore()
        let first = MacSilentTimekeeping(store: store)
        await first.load()
        first.addTimer(name: "Saved", seconds: 300)
        first.closeAdmissions()
        #expect(await first.drain(timeout: 2))
        let reopened = MacSilentTimekeeping(store: store)
        await reopened.load()
        #expect(reopened.archive.timers.map(\.label) == ["Saved"])
    }

    @Test func retryAfterOneShotQuitChoiceRevokesThatChoiceIfRetryFails() async {
        let store = FakeSilentClockStore(failCount: 2)
        let service = MacSilentTimekeeping(store: store)
        await service.load()
        service.addTimer(name: "Fixture", seconds: 300)
        service.closeAdmissions()
        #expect(!(await service.drain(timeout: 2)))
        service.resumeAfterCancelledTermination()
        service.allowExitWithoutConfirmedSave()
        service.retrySave()
        service.closeAdmissions()
        #expect(!(await service.drain(timeout: 2)))
        #expect(service.issue == .save)
    }

    @Test func otherErrorsCannotHideAnUnconfirmedSave() async throws {
        var full = ToolboxTimekeepingArchive()
        for index in 0..<ToolboxTimekeepingArchive.maximumTimers {
            full.timers.append(try ToolboxCountdown(label: "Timer \(index)", duration: 300, now: .now))
        }
        for initial in [ToolboxTimekeepingArchive(), full] {
            let store = FakeSilentClockStore(failCount: 1, initial: initial)
            let service = MacSilentTimekeeping(store: store)
            await service.load()
            service.startStopwatch()
            service.closeAdmissions()
            #expect(!(await service.drain(timeout: 2)))
            service.resumeAfterCancelledTermination()
            service.addTimer(name: "", seconds: 60)
            #expect(service.issue == .save)
            service.closeAdmissions()
            #expect(!(await service.drain(timeout: 2)))
        }
    }
}
