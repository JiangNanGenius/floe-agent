import XCTest
@testable import FloeMacMediaCore
import FloeToolboxUtilities

/// Delays each prompt independently so a cancelled generation can finish
/// after a newer one. No system authorization or audio device is accessed.
private final class OrderedSoundAuthorizer: MacMediaAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<MacMediaAuthorization, Never>] = []
    func authorization(for kind: MacMediaKind) -> MacMediaAuthorization { .notDetermined }
    func requestAuthorization(for kind: MacMediaKind) async -> MacMediaAuthorization {
        await withCheckedContinuation { continuation in
            lock.withLock { continuations.append(continuation) }
        }
    }
    var pendingCount: Int { lock.withLock { continuations.count } }
    func resumeFirst(_ result: MacMediaAuthorization) {
        let next = lock.withLock { continuations.removeFirst() }
        next.resume(returning: result)
    }
}

private final class ControlledSoundSource: MacAudioInputSource, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let stopGate = DispatchSemaphore(value: 0)
    private let blocked: Bool
    private let blockedStop: Bool
    private let unconfirmedStops: Int
    private var reader: (@Sendable (MacSoundReading) -> Void)?
    private var failer: (@Sendable (MacMediaFailure) -> Void)?
    private var starts = 0
    private var stops = 0
    init(blocked: Bool, blockedStop: Bool = false, unconfirmedStops: Int = 0) {
        self.blocked = blocked; self.blockedStop = blockedStop; self.unconfirmedStops = unconfirmedStops
    }
    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }
    var stopConfirmed: Bool { lock.withLock { stops > unconfirmedStops } }
    func releaseStart() { gate.signal() }
    func releaseStop() { stopGate.signal() }
    func start(onReading: @escaping @Sendable (MacSoundReading) -> Void,
               onFailure: @escaping @Sendable (MacMediaFailure) -> Void) throws {
        lock.withLock { starts += 1; reader = onReading; failer = onFailure }
        if blocked { _ = gate.wait(timeout: .now() + 5) }
    }
    func stop() {
        lock.withLock { stops += 1 }
        if blockedStop { _ = stopGate.wait(timeout: .now() + 5) }
    }
    func emit(_ reading: MacSoundReading) { lock.withLock { reader }?(reading) }
    func fail(_ failure: MacMediaFailure) { lock.withLock { failer }?(failure) }
}

private final class ControlledSoundProvider: MacAudioInputProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    let sources: [ControlledSoundSource]
    init(_ sources: [ControlledSoundSource]) { self.sources = sources }
    func inputAvailable() -> Bool { true }
    func makeSource() throws -> any MacAudioInputSource {
        try lock.withLock {
            guard next < sources.count else { throw MacMediaFailure.noDevice }
            let source = sources[next]
            next += 1
            return source
        }
    }
}

private final class BlockingMakeSoundProvider: MacAudioInputProviding, @unchecked Sendable {
    let source = ControlledSoundSource(blocked: false)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _entered = false
    var entered: Bool { lock.withLock { _entered } }
    func inputAvailable() -> Bool { true }
    func makeSource() throws -> any MacAudioInputSource {
        lock.withLock { _entered = true }
        _ = release.wait(timeout: .now() + 5)
        return source
    }
}

@MainActor
final class MacSoundAnalysisTests: XCTestCase {
    func testRejectsInvalidConfiguration() {
        XCTAssertNil(MacSoundAnalyzer(sampleRate: 0))
        XCTAssertNil(MacSoundAnalyzer(sampleRate: 48_000, frameSize: 1_000))
        XCTAssertNil(MacSoundAnalyzer(sampleRate: 48_000, historyEveryFrames: 0))
    }

    func testSineLevelPeakAndDominantFrequency() throws {
        let analyzer = try XCTUnwrap(MacSoundAnalyzer(sampleRate: 48_000, frameSize: 4_096))
        let frame = MacTestFixtures.sine(frequency: 440, sampleRate: 48_000,
                                         frameCount: 4_096, amplitude: 0.5)
        let reading = try XCTUnwrap(analyzer.process(frame))
        // RMS of a 0.5-amplitude sine is 0.3536 → -9.03 dBFS; peak 0.5 → -6.02.
        XCTAssertEqual(reading.levelDBFS, -9.03, accuracy: 0.25)
        XCTAssertEqual(reading.peakDBFS, -6.02, accuracy: 0.25)
        let frequency = try XCTUnwrap(reading.dominantFrequency)
        XCTAssertEqual(frequency, 440, accuracy: 2)
        XCTAssertEqual(reading.spectrum.bands.count, analyzer.bandCount)
        XCTAssertEqual(reading.spectrum.bands.count, 40)
        XCTAssertEqual(reading.spectrum.bandFrequencies.count, 40)
        XCTAssertTrue(zip(reading.spectrum.bandFrequencies, reading.spectrum.bandFrequencies.dropFirst())
            .allSatisfy { $0 < $1 })
        XCTAssertTrue(reading.spectrum.bands.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertGreaterThan(reading.spectrum.bands.max() ?? 0, 0.2)
        XCTAssertFalse(reading.appendToHistory)
    }

    func testHistoryCadenceEveryFifthFrame() throws {
        let analyzer = try XCTUnwrap(MacSoundAnalyzer(sampleRate: 48_000, frameSize: 4_096))
        let frame = MacTestFixtures.sine(frequency: 1_000, sampleRate: 48_000,
                                         frameCount: 4_096, amplitude: 0.2)
        var flags: [Bool] = []
        for _ in 0..<10 {
            flags.append(try XCTUnwrap(analyzer.process(frame)).appendToHistory)
        }
        XCTAssertEqual(flags, [false, false, false, false, true, false, false, false, false, true])
    }

    func testSilenceHasNoInventedTone() throws {
        let analyzer = try XCTUnwrap(MacSoundAnalyzer(sampleRate: 48_000, frameSize: 4_096))
        let reading = try XCTUnwrap(analyzer.process([Float](repeating: 0, count: 4_096)))
        XCTAssertEqual(reading.levelDBFS, EnvironmentalSignalMath.dbFloor)
        XCTAssertEqual(reading.peakDBFS, EnvironmentalSignalMath.dbFloor)
        XCTAssertNil(reading.dominantFrequency)
    }

    func testResetRestartsSmoothingAndCadence() throws {
        let analyzer = try XCTUnwrap(MacSoundAnalyzer(sampleRate: 48_000, frameSize: 4_096))
        let loud = MacTestFixtures.sine(frequency: 440, sampleRate: 48_000,
                                        frameCount: 4_096, amplitude: 0.8)
        XCTAssertGreaterThan(try XCTUnwrap(analyzer.process(loud)).levelDBFS, -20)
        analyzer.reset()
        let quiet = [Float](repeating: 0, count: 4_096)
        let reading = try XCTUnwrap(analyzer.process(quiet))
        XCTAssertEqual(reading.levelDBFS, EnvironmentalSignalMath.dbFloor)
        XCTAssertFalse(reading.appendToHistory)
    }

    func testEmptyFrameProducesNoReading() throws {
        let analyzer = try XCTUnwrap(MacSoundAnalyzer(sampleRate: 48_000, frameSize: 4_096))
        XCTAssertNil(analyzer.process([]))
    }
}

@MainActor
final class MacSoundSessionTests: XCTestCase {
    func testOwnerTerminationWaitsForStopAndRecoversAfterCancellation() async {
        let source = ControlledSoundSource(blocked: false, blockedStop: true)
        let broker = MacDeviceLeaseBroker()
        let session = MacSoundSession(authorizer: MacFixedAuthorizer(statuses: [.microphone: .authorized]),
                                     broker: broker, provider: ControlledSoundProvider([source]))
        let owner = MacSoundOwner(session: session)
        owner.appear { true }
        guard let ticket = owner.makeStartTicket() else { return XCTFail("missing ticket") }
        let started = await owner.start(ticket: ticket)
        XCTAssertTrue(started)
        owner.beginTermination()
        XCTAssertNil(owner.makeStartTicket())
        await MacTestFixtures.waitUntil { source.stopCount > 0 }
        let early = await owner.drain(timeout: 0.05)
        XCTAssertFalse(early)
        XCTAssertNotNil(broker.activeLease)
        source.releaseStop()
        let drained = await owner.drain(timeout: 2)
        XCTAssertTrue(drained)
        owner.cancelTermination()
        XCTAssertNotNil(owner.makeStartTicket())
        let stale = await owner.start(ticket: ticket)
        XCTAssertFalse(stale)
        owner.shutdown()
        owner.cancelTermination()
        XCTAssertNil(owner.makeStartTicket())
    }

    func testOwnerClosesPendingPermissionAndDisallowsLateSurface() async {
        let authorizer = OrderedSoundAuthorizer(), provider = MacFakeAudioProvider()
        let session = MacSoundSession(authorizer: authorizer, broker: MacDeviceLeaseBroker(), provider: provider)
        let owner = MacSoundOwner(session: session)
        owner.appear { true }
        guard let ticket = owner.makeStartTicket() else { return XCTFail("missing ticket") }
        let start = Task { await owner.start(ticket: ticket) }
        await MacTestFixtures.waitUntil { authorizer.pendingCount == 1 }
        guard authorizer.pendingCount == 1 else { return XCTFail("missing permission request") }
        owner.beginTermination()
        owner.disappear()
        owner.appear { true }
        XCTAssertNil(owner.makeStartTicket())
        authorizer.resumeFirst(.authorized)
        let started = await start.value
        XCTAssertFalse(started)
        XCTAssertEqual(provider.source.startCount, 0)
        let drained = await owner.drain(timeout: 2)
        XCTAssertTrue(drained)
        owner.cancelTermination()
        XCTAssertNotNil(owner.makeStartTicket())
    }
    func testStopWhileSourceCreationQueuedPreventsStartAndDrains() async {
        let provider = BlockingMakeSoundProvider(), broker = MacDeviceLeaseBroker()
        let session = MacSoundSession(authorizer: MacFixedAuthorizer(statuses: [.microphone: .authorized]),
                                     broker: broker, provider: provider, captureAvailability: { true })
        let start = Task { await session.start() }
        await MacTestFixtures.waitUntil { provider.entered }
        guard provider.entered else { provider.release.signal(); _ = await start.value; return XCTFail("source creation not reached") }
        session.stop()
        XCTAssertNotNil(broker.activeLease)
        provider.release.signal()
        let started = await start.value
        XCTAssertFalse(started)
        let stopped = await session.waitUntilStopped()
        XCTAssertTrue(stopped)
        XCTAssertEqual(provider.source.startCount, 0)
        XCTAssertNil(broker.activeLease)
    }
    func testUnconfirmedStopRetainsLeaseAndCanBeRetried() async {
        let source = ControlledSoundSource(blocked: false, unconfirmedStops: 2)
        let broker = MacDeviceLeaseBroker()
        let session = MacSoundSession(authorizer: MacFixedAuthorizer(statuses: [.microphone: .authorized]),
                                     broker: broker, provider: ControlledSoundProvider([source]),
                                     captureAvailability: { true })
        let started = await session.start()
        XCTAssertTrue(started)
        session.stop()
        let firstDrain = await session.waitUntilStopped()
        XCTAssertFalse(firstDrain)
        XCTAssertNotNil(broker.activeLease)
        XCTAssertEqual(session.phase, .stopping)
        XCTAssertNil(broker.acquire(.microphone, owner: UUID()))
        let secondDrain = await session.waitUntilStopped()
        XCTAssertTrue(secondDrain)
        XCTAssertNil(broker.activeLease)
    }
    func testSlowConsumerHasOneDrainAndOnlyLatestPendingReading() {
        let relay = MacSoundLatestReadingRelay()
        var scheduled = 0
        for index in 0..<20_000 {
            if relay.offer(MacTestFixtures.reading(level: Double(index), append: true)) { scheduled += 1 }
        }
        XCTAssertEqual(scheduled, 1)
        XCTAssertEqual(relay.take()?.levelDBFS, 19_999)
        XCTAssertFalse(relay.offer(MacTestFixtures.reading(level: 20_000, append: true)))
        XCTAssertEqual(relay.take()?.levelDBFS, 20_000)
        XCTAssertNil(relay.take())
        XCTAssertTrue(relay.offer(MacTestFixtures.reading(level: 20_001, append: true)))
        relay.invalidate()
        XCTAssertNil(relay.take())
        XCTAssertFalse(relay.offer(MacTestFixtures.reading(level: 20_002, append: true)))
        XCTAssertFalse(relay.claimFailure())
    }

    func testOnlyOneFailureCanBeQueuedPerRun() {
        let relay = MacSoundLatestReadingRelay()
        XCTAssertTrue(relay.claimFailure())
        XCTAssertFalse(relay.claimFailure())
        relay.invalidate()
        XCTAssertFalse(relay.claimFailure())
    }

    func testCoalescingKeepsPeakAndHistoryIntent() {
        let relay = MacSoundLatestReadingRelay()
        XCTAssertTrue(relay.offer(MacTestFixtures.reading(level: -5, peak: -1, append: true)))
        XCTAssertFalse(relay.offer(MacTestFixtures.reading(level: -30, peak: -20, append: false)))
        let merged = relay.take()
        XCTAssertEqual(merged?.levelDBFS, -30)
        XCTAssertEqual(merged?.peakDBFS, -1)
        XCTAssertEqual(merged?.appendToHistory, true)
    }

    func testAuthorizationReturningWhileInvisibleNeverOpensMicrophone() async {
        let authorizer = OrderedSoundAuthorizer()
        let provider = MacFakeAudioProvider()
        let broker = MacDeviceLeaseBroker()
        var visible = true
        let session = MacSoundSession(authorizer: authorizer, broker: broker, provider: provider,
                                      captureAvailability: { visible })
        let start = Task { await session.start() }
        await MacTestFixtures.waitUntil { authorizer.pendingCount == 1 }
        guard authorizer.pendingCount == 1 else { start.cancel(); return XCTFail("permission not reached") }
        visible = false
        authorizer.resumeFirst(.authorized)
        let started = await start.value
        XCTAssertFalse(started)
        XCTAssertEqual(provider.source.startCount, 0)
        XCTAssertNil(broker.activeLease)
        XCTAssertEqual(session.phase, .idle)
    }

    func testCloseDuringPermissionFencesLateResponse() async {
        let authorizer = OrderedSoundAuthorizer()
        let provider = MacFakeAudioProvider()
        let broker = MacDeviceLeaseBroker()
        let session = MacSoundSession(authorizer: authorizer, broker: broker, provider: provider,
                                      captureAvailability: { true })
        let start = Task { await session.start() }
        await MacTestFixtures.waitUntil { authorizer.pendingCount == 1 }
        guard authorizer.pendingCount == 1 else { start.cancel(); return XCTFail("permission not reached") }
        session.setCaptureAvailability { false }
        authorizer.resumeFirst(.authorized)
        let started = await start.value
        XCTAssertFalse(started)
        XCTAssertEqual(provider.source.startCount, 0)
        XCTAssertNil(broker.activeLease)
    }

    func testStopDoesNotWaitForBlockedStartAndRestartFencesOldFrames() async {
        let first = ControlledSoundSource(blocked: true)
        let second = ControlledSoundSource(blocked: false)
        let provider = ControlledSoundProvider([first, second])
        let broker = MacDeviceLeaseBroker()
        let session = MacSoundSession(authorizer: MacFixedAuthorizer(statuses: [.microphone: .authorized]),
                                      broker: broker, provider: provider, captureAvailability: { true })
        let old = Task { await session.start() }
        await MacTestFixtures.waitUntil { first.startCount == 1 }
        guard first.startCount == 1 else { first.releaseStart(); return XCTFail("start was not reached") }
        let oldLease = broker.activeLease
        let before = ContinuousClock.now
        session.stop()
        XCTAssertLessThan(before.duration(to: .now), .seconds(1))
        XCTAssertEqual(session.phase, .stopping)
        XCTAssertEqual(broker.activeLease, oldLease)
        let restart = Task { await session.restart() }
        await Task.yield()
        XCTAssertEqual(second.startCount, 0)
        first.releaseStart()
        let oldResult = await old.value
        let restartResult = await restart.value
        XCTAssertFalse(oldResult)
        XCTAssertTrue(restartResult)
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(second.startCount, 1)
        let newLease = broker.activeLease
        XCTAssertNotEqual(oldLease, newLease)
        first.emit(MacTestFixtures.reading(level: -1, append: true))
        first.fail(.mediaServicesReset)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(session.levelDBFS)
        XCTAssertNil(session.streamFailure)
        XCTAssertEqual(session.phase, .running)
        XCTAssertEqual(broker.activeLease, newLease)
        session.stop()
        await MacTestFixtures.waitUntil { session.phase == .idle }
        XCTAssertNil(broker.activeLease)
    }

    func testRestartIsFencedIfOwnerClosesWhileStopPending() async {
        let first = ControlledSoundSource(blocked: true)
        let second = ControlledSoundSource(blocked: false)
        let provider = ControlledSoundProvider([first, second])
        let broker = MacDeviceLeaseBroker()
        var visible = true
        let session = MacSoundSession(authorizer: MacFixedAuthorizer(statuses: [.microphone: .authorized]),
                                      broker: broker, provider: provider, captureAvailability: { visible })
        let old = Task { await session.start() }
        await MacTestFixtures.waitUntil { first.startCount == 1 }
        guard first.startCount == 1 else { first.releaseStart(); return XCTFail("start was not reached") }
        let restart = Task { await session.restart() }
        await MacTestFixtures.waitUntil { session.phase == .stopping }
        visible = false
        session.stop()
        first.releaseStart()
        let oldResult = await old.value
        let restartResult = await restart.value
        XCTAssertFalse(oldResult)
        XCTAssertFalse(restartResult)
        XCTAssertEqual(second.startCount, 0)
        XCTAssertNil(broker.activeLease)
    }

    func testStopReturnsWhileDeviceStopIsBlockedAndRetainsLease() async {
        let source = ControlledSoundSource(blocked: false, blockedStop: true)
        let broker = MacDeviceLeaseBroker()
        let session = MacSoundSession(authorizer: MacFixedAuthorizer(statuses: [.microphone: .authorized]),
                                      broker: broker, provider: ControlledSoundProvider([source]),
                                      captureAvailability: { true })
        let started = await session.start()
        guard started else { source.releaseStop(); return XCTFail("start failed") }
        let held = broker.activeLease
        let before = ContinuousClock.now
        session.stop()
        XCTAssertLessThan(before.duration(to: .now), .seconds(1))
        await MacTestFixtures.waitUntil { source.stopCount == 1 }
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertEqual(broker.activeLease, held)
        source.releaseStop()
        await MacTestFixtures.waitUntil { session.phase == .idle }
        XCTAssertNil(broker.activeLease)
    }

    func testStalePermissionCannotClearNewPromptOrRunningSession() async {
        let authorizer = OrderedSoundAuthorizer()
        let provider = MacFakeAudioProvider()
        let broker = MacDeviceLeaseBroker()
        let session = MacSoundSession(authorizer: authorizer, broker: broker, provider: provider, captureAvailability: { true })
        let oldStart = Task { await session.start() }
        await MacTestFixtures.waitUntil { authorizer.pendingCount == 1 }
        XCTAssertEqual(authorizer.pendingCount, 1)
        session.stop()
        await MacTestFixtures.waitUntil { session.phase == .idle }
        let newStart = Task { await session.start() }
        await MacTestFixtures.waitUntil { authorizer.pendingCount == 2 }
        XCTAssertEqual(authorizer.pendingCount, 2)
        authorizer.resumeFirst(.authorized)
        let oldResult = await oldStart.value
        XCTAssertFalse(oldResult)
        XCTAssertEqual(session.phase, .starting)
        XCTAssertTrue(session.awaitingPermissionPrompt)
        authorizer.resumeFirst(.authorized)
        let newResult = await newStart.value
        XCTAssertTrue(newResult)
        XCTAssertEqual(session.phase, .running)
        XCTAssertNotNil(broker.activeLease)
        session.stop()
        await MacTestFixtures.waitUntil { session.phase == .idle }
        XCTAssertNil(broker.activeLease)
    }

    private func makeSession(
        status: MacMediaAuthorization = .authorized,
        requestResult: MacMediaAuthorization = .authorized,
        historyCapacity: Int = 600
    ) -> (MacSoundSession, MacFakeAudioProvider, MacDeviceLeaseBroker) {
        let authorizer = MacFixedAuthorizer(statuses: [.microphone: status], requestResult: requestResult)
        let provider = MacFakeAudioProvider()
        let broker = MacDeviceLeaseBroker()
        let session = MacSoundSession(
            authorizer: authorizer,
            broker: broker,
            provider: provider,
            historyCapacity: historyCapacity,
            captureAvailability: { true }
        )
        return (session, provider, broker)
    }

    func testBlockedMainActorReceivesOnlyLatestFrame() async {
        let (session, provider, _) = makeSession()
        let started = await session.start()
        guard started else { return XCTFail("start failed") }
        // This loop deliberately keeps the main actor busy while the fake
        // source delivers readings; the drain cannot run until we yield.
        for index in 0..<10_000 {
            provider.source.emit(MacTestFixtures.reading(level: -Double(index), append: true))
        }
        await MacTestFixtures.waitUntil { session.levelDBFS == -9_999 }
        XCTAssertEqual(session.levelDBFS, -9_999)
        XCTAssertEqual(session.history.count, 1)
        session.stop()
        await MacTestFixtures.waitUntil { session.phase == .idle }
    }

    func testExplicitStartRunsAndHoldsLease() async {
        let (session, provider, broker) = makeSession(status: .notDetermined, requestResult: .authorized)
        let started = await session.start()
        XCTAssertTrue(started)
        XCTAssertEqual(session.phase, .running)
        XCTAssertEqual(session.authorization, .authorized)
        XCTAssertNotNil(session.lease)
        XCTAssertNotNil(broker.activeLease)
        XCTAssertEqual(provider.source.startCount, 1)
        session.stop()
        await MacTestFixtures.waitUntil { session.phase == .idle }
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(broker.activeLease)
        XCTAssertEqual(provider.source.stopCount, 1)
    }

    func testDeniedPermissionDoesNotAcquireOrOpenInput() async {
        let (session, provider, broker) = makeSession(status: .notDetermined, requestResult: .denied)
        let started = await session.start()
        XCTAssertFalse(started)
        XCTAssertEqual(session.authorization, .denied)
        XCTAssertEqual(session.streamFailure, .notAuthorized)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(session.lease)
        XCTAssertNil(broker.activeLease)
        XCTAssertEqual(provider.source.startCount, 0)
    }

    func testSecondWindowIsBusyInsteadOfStealingDevice() async {
        let (session, provider, broker) = makeSession()
        guard let other = broker.acquire(.microphone, owner: UUID()) else {
            return XCTFail("first lease should succeed")
        }
        let started = await session.start()
        XCTAssertFalse(started)
        XCTAssertEqual(session.streamFailure, .deviceBusy)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(provider.source.startCount, 0)
        XCTAssertEqual(broker.activeLease, other)
        broker.release(other)
    }

    func testReadingsPublishAndStopDropsLateFrames() async {
        let (session, provider, _) = makeSession()
        let started = await session.start()
        XCTAssertTrue(started)
        provider.source.emit(MacTestFixtures.reading(level: -12, peak: -6, frequency: 880, append: true))
        await MacTestFixtures.waitUntil { session.history.count == 1 }
        XCTAssertEqual(session.levelDBFS ?? .nan, -12)
        XCTAssertEqual(session.peakDBFS ?? .nan, -6)
        XCTAssertEqual(session.dominantFrequency ?? .nan, 880)

        session.stop()
        await MacTestFixtures.waitUntil { session.phase == .idle }
        provider.source.emit(MacTestFixtures.reading(level: -3, peak: -1, frequency: 100, append: true))
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(session.history.count, 1)
        XCTAssertEqual(session.levelDBFS ?? .nan, -12)
        XCTAssertEqual(session.phase, .idle)
    }

    func testHistoryCapacityDropsOldestSamples() async {
        let (session, provider, _) = makeSession(historyCapacity: 2)
        let started = await session.start()
        XCTAssertTrue(started)
        for index in 0..<5 {
            provider.source.emit(MacTestFixtures.reading(level: -20 - Double(index), append: true))
            await MacTestFixtures.waitUntil { session.history.count + session.droppedHistoryCount == index + 1 }
        }
        await MacTestFixtures.waitUntil { session.history.count == 2 }
        XCTAssertEqual(session.history.count, 2)
        XCTAssertEqual(session.droppedHistoryCount, 3)
        XCTAssertTrue(session.history.allSatisfy { (-24.0...(-20.0)).contains($0.levelDBFS) })
        session.stop()
        await MacTestFixtures.waitUntil { session.phase == .idle }
    }

    func testCSVUsesHonestHeadersAndRetainedRows() async {
        let (session, provider, _) = makeSession()
        let started = await session.start()
        XCTAssertTrue(started)
        provider.source.emit(MacTestFixtures.reading(level: -20.5, peak: -10.24, frequency: 440, append: true))
        await MacTestFixtures.waitUntil { session.history.count == 1 }
        session.stop()
        await MacTestFixtures.waitUntil { session.phase == .idle }
        let lines = session.makeCSV().split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.first, "time_s,level_dbfs,peak_dbfs,dominant_hz")
        XCTAssertEqual(lines.count, 3) // header + one row + trailing newline
        let fields = lines[1].split(separator: ",")
        XCTAssertEqual(fields.count, 4)
        XCTAssertEqual(String(fields[1]), "-20.5")
        XCTAssertEqual(String(fields[2]), "-10.2")
        XCTAssertEqual(String(fields[3]), "440.0")
    }

    func testStopWhilePermissionPendingNeverStarts() async {
        let authorizer = MacDeferredAuthorizer(status: .notDetermined)
        let provider = MacFakeAudioProvider()
        let broker = MacDeviceLeaseBroker()
        let session = MacSoundSession(authorizer: authorizer, broker: broker, provider: provider, captureAvailability: { true })
        let task = Task { await session.start() }
        await MacTestFixtures.waitUntil { authorizer.hasPendingRequest }
        XCTAssertEqual(session.phase, .starting)
        session.stop()
        await MacTestFixtures.waitUntil { session.phase == .idle }
        authorizer.resume(.authorized)
        let started = await task.value
        XCTAssertFalse(started)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(broker.activeLease)
        XCTAssertEqual(provider.source.startCount, 0)
        XCTAssertEqual(authorizer.requestCount, 1)
    }

    func testDeviceLossStopsAndReleasesLease() async {
        let (session, provider, broker) = makeSession()
        let started = await session.start()
        XCTAssertTrue(started)
        provider.source.fail(.mediaServicesReset)
        await MacTestFixtures.waitUntil { session.streamFailure == .mediaServicesReset && session.phase == .idle }
        XCTAssertEqual(session.streamFailure, .mediaServicesReset)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(broker.activeLease)
        XCTAssertNil(session.lease)
        XCTAssertGreaterThanOrEqual(provider.source.stopCount, 1)
    }

    func testStartFailureReturnsLeaseAndReportsFailure() async {
        let (session, provider, broker) = makeSession()
        provider.makeError = .engine("boom")
        let started = await session.start()
        XCTAssertFalse(started)
        XCTAssertEqual(session.streamFailure, .engine("boom"))
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(broker.activeLease)
        XCTAssertNil(session.lease)
    }

    func testNoInputDeviceReportsNoDevice() async {
        let (session, provider, broker) = makeSession()
        provider.available = false
        let started = await session.start()
        XCTAssertFalse(started)
        XCTAssertEqual(session.streamFailure, .noDevice)
        XCTAssertNil(broker.activeLease)
    }

    func testResetClearsRetainedStateWithoutStoppingPhase() async {
        let (session, provider, _) = makeSession()
        let started = await session.start()
        XCTAssertTrue(started)
        provider.source.emit(MacTestFixtures.reading(append: true))
        await MacTestFixtures.waitUntil { session.history.count == 1 }
        session.reset()
        XCTAssertTrue(session.history.isEmpty)
        XCTAssertNil(session.levelDBFS)
        XCTAssertNil(session.peakDBFS)
        XCTAssertNil(session.spectrum)
        XCTAssertEqual(session.phase, .running)
        session.stop()
        await MacTestFixtures.waitUntil { session.phase == .idle }
    }
}
