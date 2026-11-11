import Foundation
import Testing
@testable import FloeToolboxUtilities

private let clockProcess = UUID()
private func clock(_ elapsed: Double, wallDelta: Double = 0, process: UUID = clockProcess) -> ToolboxTimeSample {
    .init(wall: Date(timeIntervalSince1970: 1_800_000_000 + elapsed + wallDelta), continuous: 10_000 + elapsed, process: process)
}

@Test func stopwatchPauseResumeAndLapUseContinuousTime() throws {
    var watch = ToolboxStopwatch()
    watch.start(at: clock(0)); try watch.lap(at: clock(10)); try watch.lap(at: clock(17))
    #expect(watch.laps.map(\.split) == [10, 7])
    watch.pause(at: clock(20))
    #expect(watch.elapsed(at: clock(100)) == 20)
    watch.start(at: clock(100))
    #expect(watch.elapsed(at: clock(110, wallDelta: -3600)) == 30)
    watch.pause(at: clock(115, wallDelta: 3600))
    #expect(watch.accumulated == 35)
    watch.reset(); #expect(watch.accumulated == 0 && watch.laps.isEmpty && !watch.running)
}

@Test func clockContinuitySurvivesRelaunchButDetectsRebootOrTimeChange() {
    #expect(clock(50, process: UUID()).elapsed(since: clock(0)).continuous)
    let rebooted = ToolboxTimeSample(wall: clock(100).wall, continuous: 5, process: UUID())
    #expect(!rebooted.elapsed(since: clock(0)).continuous)
    #expect(rebooted.elapsed(since: clock(0)).seconds == 100)
    #expect(!clock(50, wallDelta: -7200, process: UUID()).elapsed(since: clock(0)).continuous)
}

@Test func countdownPauseResetFinishAndIndependentTimers() throws {
    var first = try ToolboxCountdown(label: "Tea", duration: 60, now: clock(0))
    let second = try ToolboxCountdown(label: "Laundry", duration: 300, now: clock(0))
    first.pause(at: clock(20))
    #expect(first.remaining(at: clock(90)) == 40 && first.phase == .paused)
    first.resume(at: clock(100))
    #expect(first.remaining(at: clock(110, wallDelta: 10000)) == 30)
    #expect(second.remaining(at: clock(110)) == 190)
    let finished = first.finishIfNeeded(at: clock(145))
    #expect(finished)
    #expect(first.phase == .finished && first.remaining(at: clock(200)) == 0)
    let finishedAgain = first.finishIfNeeded(at: clock(200))
    #expect(!finishedAgain)
    first.reset(); #expect(first.phase == .paused && first.retained == 60 && first.generation > 0)
}

@Test func uncertainRecoveryPausesRunningValuesAndMarksReview() throws {
    var state = ToolboxTimekeepingArchive()
    state.stopwatch.start(at: clock(0))
    state.timers = [try .init(label: "Check", duration: 300, now: clock(0))]
    let reboot = ToolboxTimeSample(wall: clock(100).wall, continuous: 5, process: UUID())
    state.recover(at: reboot)
    #expect(state.clockReview && !state.stopwatch.running)
    #expect(state.stopwatch.accumulated == 100)
    #expect(state.timers[0].phase == .paused && state.timers[0].retained == 200)
}

@Test func normalRelaunchKeepsRunningStateAndExpiredTimerSettlesOnce() throws {
    var state = ToolboxTimekeepingArchive()
    state.stopwatch.start(at: clock(0))
    state.timers = [try .init(label: "Short", duration: 10, now: clock(0))]
    state.recover(at: clock(20, process: UUID()))
    #expect(state.stopwatch.running && !state.clockReview)
    #expect(state.timers[0].phase == .finished)
    let generation = state.timers[0].generation
    state.recover(at: clock(30, process: UUID()))
    #expect(state.timers[0].generation == generation)
}

@Test func timerInputAndArchiveBoundsRejectInvalidData() throws {
    for duration in [0, -1, Double.nan, .infinity, ToolboxCountdown.maximumDuration + 1] {
        #expect(throws: ToolboxTimekeepingError.self) { try ToolboxCountdown(label: "Test", duration: duration, now: clock(0)) }
    }
    #expect(throws: ToolboxTimekeepingError.self) { try ToolboxCountdown(label: " ", duration: 10, now: clock(0)) }
    var state = ToolboxTimekeepingArchive()
    let timer = try ToolboxCountdown(label: "Timer", duration: 10, now: clock(0))
    state.timers = [timer, timer]; #expect(!state.isValid)
    state.timers = [timer]; state.timers[0].retained = .nan; #expect(!state.isValid)
    state.timers = (0...ToolboxTimekeepingArchive.maximumTimers).map { _ in timer }; #expect(!state.isValid)
}

@Test func stopwatchLapCapacityIsBounded() throws {
    var watch = ToolboxStopwatch(); watch.start(at: clock(0))
    for index in 0..<ToolboxStopwatch.maximumLaps { try watch.lap(at: clock(Double(index + 1))) }
    #expect(throws: ToolboxTimekeepingError.limit) { try watch.lap(at: clock(999)) }
    #expect(watch.laps.count == ToolboxStopwatch.maximumLaps)
}

@Test func timerStorePersistsAndRejectsStaleSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ToolboxTimekeepingStore(url: root.appendingPathComponent("timers.json"))
    var state = ToolboxTimekeepingArchive(); state.revision = 2
    state.timers = [try .init(label: "Saved", duration: 600, now: clock(0))]
    try await store.save(state)
    #expect(try await store.load() == state)
    var stale = state; stale.revision = 1
    await #expect(throws: ToolboxTimekeepingError.staleArchive) { try await store.save(stale) }
    #expect(try await store.load() == state)
}

@Test func timerStorePreservesCorruptFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("timers.json"), original = Data("{corrupt".utf8)
    try original.write(to: url)
    let store = ToolboxTimekeepingStore(url: url)
    await #expect(throws: ToolboxTimekeepingError.corruptArchive) { try await store.load() }
    await #expect(throws: ToolboxTimekeepingError.corruptArchive) { try await store.save(.init()) }
    #expect(try Data(contentsOf: url) == original)
    let rebuilt = try await store.rebuildPreservingOriginal()
    #expect(try await store.load() == rebuilt)
    #expect(rebuilt.timers.isEmpty && rebuilt.stopwatch.accumulated == 0)
    let backup = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("state-recovery-") })
    #expect(try Data(contentsOf: backup) == original)
}

@Test func durationFormattingKeepsLongHoursAndHundredths() {
    #expect(ToolboxTimeText.duration(3661) == "01:01:01")
    #expect(ToolboxTimeText.duration(1.25, hundredths: true) == "00:00:01.25")
    #expect(ToolboxTimeText.duration(31 * 86400) == "744:00:00")
    #expect(ToolboxTimeText.duration(.nan) == "00:00:00")
}
