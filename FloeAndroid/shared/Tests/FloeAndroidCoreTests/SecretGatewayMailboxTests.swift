import XCTest
@testable import FloeAndroidCore

/// Deterministic H-layer source tests for the P1 mailbox. These are AUTHORED
/// test sources: no compiler or test runner is invoked by the source package
/// that produced them. They exercise the real C ABI/in-process mailbox with
/// synthetic fixed bytes only.
final class SecretGatewayMailboxTests: XCTestCase {
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 1_000
        var now: UInt64 {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func advance(_ milliseconds: UInt64) {
            lock.lock(); value += milliseconds; lock.unlock()
        }
    }

    private var clock: TestClock!

    override func setUp() {
        super.setUp()
        _ = floeSecretGatewayRemove()
        SecretGatewayRegistry.shared.unregister()
        SecretRequestMailbox.shared.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        let testClock = TestClock()
        clock = testClock
        SecretRequestMailbox.shared.configureForTesting(
            clock: { testClock.now },
            heartbeatStaleMillis: 60_000,
            watchdogStaleMillis: 60_000,
            watchdogTickMillis: 10,
            backendProgressWindowMillis: 10_000
        )
        XCTAssertEqual(floeSecretMailboxBind(1), 0)
    }

    override func tearDown() {
        _ = floeSecretGatewayRemove()
        SecretGatewayRegistry.shared.unregister()
        SecretRequestMailbox.shared.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        clock = nil
        super.tearDown()
    }

    // MARK: Helpers

    private func reference(_ account: String) -> String {
        SecretGatewayNaming.opaqueReference(namespace: "keychainAccount", account: account)
    }

    private func startWrite(_ bytes: Data, reference: String) -> Task<Void, Error> {
        Task { try await MailboxSecretGateway.shared.write(reference: reference, value: bytes) }
    }

    private func startRead(_ reference: String) -> Task<Data?, Error> {
        Task { try await MailboxSecretGateway.shared.read(reference: reference) }
    }

    private func startDelete(_ reference: String) -> Task<Void, Error> {
        Task { try await MailboxSecretGateway.shared.delete(reference: reference) }
    }

    private func statsObject() -> [String: Any] {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            floeSecretMailboxStats(pointer.baseAddress, Int32(pointer.count))
        }
        guard length >= 0,
              let data = String(cString: buffer).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func intStat(_ key: String) -> Int {
        (statsObject()[key] as? NSNumber)?.intValue ?? -1
    }

    private func counter(_ key: String) -> Int {
        guard let counters = statsObject()["counters"] as? [String: Any] else { return -1 }
        return (counters[key] as? NSNumber)?.intValue ?? -1
    }

    private func waitFor(_ condition: @escaping () -> Bool,
                         timeout: TimeInterval = 2.0,
                         file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not met before timeout", file: file, line: line)
    }

    private func waitForQueued(_ count: Int,
                               file: StaticString = #filePath, line: UInt = #line) async {
        await waitFor({ self.intStat("queued") == count }, file: file, line: line)
    }

    private func expectFailure<T>(_ task: Task<T, Error>, _ expected: SecretBackendError,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as SecretBackendError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    private func expectCancellation<T>(_ task: Task<T, Error>,
                                       file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("expected cancellation", file: file, line: line)
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    private func claim(_ timeout: Int32 = 1_000) -> Int64 {
        floeSecretMailboxAwait(timeout)
    }

    private func complete(_ claim: Int64, _ status: Int32, value: Data? = nil) -> Int32 {
        if let value, !value.isEmpty {
            return value.withUnsafeBytes { raw in
                floeSecretMailboxComplete(claim, status,
                    raw.bindMemory(to: UInt8.self).baseAddress, Int32(value.count))
            }
        }
        return floeSecretMailboxComplete(claim, status, nil, 0)
    }

    private func describe(_ claim: Int64, capacity: Int32 = 512) -> (Int32, String?) {
        var buffer = [CChar](repeating: 0, count: max(1, Int(capacity)))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            floeSecretMailboxDescribe(claim, pointer.baseAddress, capacity)
        }
        return (result, result >= 0 ? String(cString: buffer) : nil)
    }

    private func take(_ claim: Int64) -> (Int32, Data) {
        let length = floeSecretMailboxPayloadLength(claim)
        guard length >= 0 else { return (length, Data()) }
        var bytes = [UInt8](repeating: 0, count: Int(length))
        let result = bytes.withUnsafeMutableBufferPointer { pointer in
            floeSecretMailboxTakePayload(claim, pointer.baseAddress, Int32(pointer.count))
        }
        return (result, Data(bytes))
    }

    // MARK: FIFO / descriptor / payload

    func testFIFOClaimsDescriptorAndPayloadBounds() async throws {
        let first = startWrite(Data([0x41]), reference: reference("provider.fifo.a"))
        await waitForQueued(1)
        let second = startWrite(Data([0x42]), reference: reference("provider.fifo.b"))
        await waitForQueued(2)
        let third = startWrite(Data([0x43]), reference: reference("provider.fifo.c"))
        await waitForQueued(3)

        let token1 = claim()
        let token2 = claim()
        let token3 = claim()
        XCTAssertGreaterThan(token1, 0)
        XCTAssertGreaterThan(token2, token1)
        XCTAssertGreaterThan(token3, token2)

        let (describeCode, descriptor) = describe(token1)
        XCTAssertGreaterThanOrEqual(describeCode, 0)
        let descriptorData = try XCTUnwrap(descriptor?.data(using: .utf8))
        let descriptorObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: descriptorData) as? [String: Any])
        XCTAssertEqual(descriptorObject["op"] as? String, "write")
        XCTAssertEqual(descriptorObject["reference"] as? String,
                       reference("provider.fifo.a"))

        XCTAssertEqual(floeSecretMailboxPayloadLength(token1), 1)
        XCTAssertEqual(describe(token1, capacity: 8).0, -106, "small descriptor buffer")
        XCTAssertEqual(describe(token1).0, describeCode, "descriptor unchanged after -106")

        var shortBytes = [UInt8](repeating: 0, count: 1)
        XCTAssertEqual(shortBytes.withUnsafeMutableBufferPointer {
            floeSecretMailboxTakePayload(token1, $0.baseAddress, 0)
        }, -106)
        XCTAssertEqual(floeSecretMailboxPayloadLength(token1), 1, "take failure is non-consuming")

        let (takeCode, value) = take(token1)
        XCTAssertEqual(takeCode, 1)
        XCTAssertEqual(value, Data([0x41]))
        XCTAssertEqual(take(token1).0, -107)

        XCTAssertEqual(complete(token1, 3), 0)
        XCTAssertEqual(complete(token2, 3), 0)
        XCTAssertEqual(complete(token3, 3), 0)
        try await first.value
        try await second.value
        try await third.value
        XCTAssertEqual(intStat("queued"), 0)
        XCTAssertEqual(intStat("permitsHeld"), 0)
    }

    // MARK: Saturation

    func testQueueAndPendingByteSaturation() async throws {
        var tasks: [Task<Void, Error>] = []
        for index in 0..<32 {
            tasks.append(startWrite(Data([UInt8(index)]),
                                    reference: reference("provider.queue.\(index)")))
        }
        await waitForQueued(32)
        let rejected = startWrite(Data([0x01]), reference: reference("provider.queue.33"))
        await expectFailure(rejected, .mailboxSaturated)
        XCTAssertGreaterThan(counter("saturated"), 0)

        for task in tasks { task.cancel() }
        for task in tasks { await expectCancellation(task) }
        await waitForQueued(0)

        let large = Data(repeating: 0x5A, count: 65_536)
        var byteTasks: [Task<Void, Error>] = []
        for index in 0..<4 {
            byteTasks.append(startWrite(large, reference: reference("provider.bytes.\(index)")))
        }
        await waitForQueued(4)
        let byteRejected = startWrite(Data([0x01]), reference: reference("provider.bytes.5"))
        await expectFailure(byteRejected, .mailboxSaturated)
        for task in byteTasks { task.cancel() }
        for task in byteTasks { await expectCancellation(task) }
        await waitForQueued(0)
        XCTAssertEqual(intStat("pendingPayloadBytes"), 0)
    }

    func testPermitsBlockAwaitAndWakeOnSettle() async throws {
        var tasks: [Task<Void, Error>] = []
        for index in 0..<17 {
            tasks.append(startWrite(Data([0x11]), reference: reference("provider.permit.\(index)")))
        }
        await waitForQueued(17)
        var claims: [Int64] = []
        for _ in 0..<16 {
            claims.append(claim())
        }
        XCTAssertFalse(claims.contains(0))
        let start = Date()
        XCTAssertEqual(claim(120), 0, "permits exhausted: await blocks full timeout")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.08)

        XCTAssertEqual(complete(claims[0], 3), 0)
        let seventeenth = claim(1_000)
        XCTAssertGreaterThan(seventeenth, 0)
        XCTAssertEqual(complete(seventeenth, 3), 0)
        for token in claims.dropFirst() {
            XCTAssertEqual(complete(token, 3), 0)
        }
        for task in tasks { try await task.value }
        XCTAssertEqual(intStat("permitsHeld"), 0)
    }

    // MARK: Cancellation

    func testFrozenBusinessClockStillBoundsActualPollTimeout() async throws {
        // Regression for the real non-terminating wait: the injected business
        // clock is frozen here, so only the independent monotonic poll
        // deadline can end claim(30). The business clock value must not move
        // and the call must return well inside a bounded real interval.
        let frozen = clock.now
        XCTAssertEqual(frozen, 1_000)
        let started = Date()
        XCTAssertEqual(claim(30), 0)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.020,
                                    "claim(30) returned without waiting its real poll interval")
        XCTAssertLessThan(elapsed, 5.0, "frozen business clock stalled the poll deadline")
        XCTAssertEqual(claim(120), 0, "full remaining real timeout still returns empty")
        XCTAssertEqual(clock.now, frozen,
                       "poll timeout must not advance or mutate the business clock")
    }

    func testCancellationBeforeClaimRemovesAndZerosPayload() async throws {
        let task = startWrite(Data(repeating: 0x31, count: 16),
                              reference: reference("provider.cancel.before"))
        await waitForQueued(1)
        task.cancel()
        await expectCancellation(task)
        await waitForQueued(0)
        XCTAssertEqual(intStat("pendingPayloadBytes"), 0)
        XCTAssertEqual(claim(30), 0)
        XCTAssertGreaterThanOrEqual(counter("droppedCanceled"), 1)
    }

    func testCancellationAfterClaimBeforeTakeIsNotLive() async throws {
        let task = startWrite(Data(repeating: 0x32, count: 16),
                              reference: reference("provider.cancel.claimed"))
        await waitForQueued(1)
        let token = claim()
        XCTAssertGreaterThan(token, 0)
        XCTAssertEqual(floeSecretMailboxIsLive(token), 1)
        task.cancel()
        await expectCancellation(task)
        XCTAssertEqual(floeSecretMailboxIsLive(token), 0)
        XCTAssertEqual(take(token).0, -103)
        XCTAssertEqual(complete(token, -13), -103)
        XCTAssertEqual(intStat("permitsHeld"), 0)
    }

    func testCancelBeforeAttachDoesNotLeaveAQueuedTicket() async throws {
        let task = startRead(reference("provider.cancel.attach"))
        task.cancel()
        await expectCancellation(task)
        XCTAssertEqual(intStat("queued"), 0)
        XCTAssertEqual(intStat("permitsHeld"), 0)
    }

    func testCompletionAfterCallerSettlementUsesAuthoritativeStatus() async throws {
        let task = startRead(reference("provider.cancel.completion"))
        await waitForQueued(1)
        let token = claim()
        task.cancel()
        await expectCancellation(task)
        XCTAssertEqual(intStat("permitsHeld"), 1)
        XCTAssertEqual(floeSecretMailboxComplete(token, -3, nil, 0), -103)
        XCTAssertEqual(intStat("permitsHeld"), 0)
        XCTAssertGreaterThanOrEqual(counter("effectFailed"), 1)
    }

    // MARK: Generation / remove

    func testGenerationReplacementSettlesAndLateCompletionIsEpochMismatch() async throws {
        let first = startWrite(Data([0x01]), reference: reference("provider.epoch.a"))
        let second = startWrite(Data([0x02]), reference: reference("provider.epoch.b"))
        await waitForQueued(2)
        let claimed = claim()
        XCTAssertGreaterThan(claimed, 0)

        XCTAssertEqual(floeSecretMailboxBind(2), 0)
        await expectFailure(first, .dispatcherReplaced)
        await expectFailure(second, .dispatcherReplaced)
        XCTAssertEqual(complete(claimed, -13), -102)
        XCTAssertEqual(intStat("queued"), 0)
        XCTAssertEqual(intStat("permitsHeld"), 0)
        XCTAssertGreaterThanOrEqual(counter("settledRebind"), 2)

        let fresh = startWrite(Data([0x03]), reference: reference("provider.epoch.fresh"))
        await waitForQueued(1)
        let freshToken = claim()
        XCTAssertGreaterThan(freshToken, 0)
        XCTAssertEqual(complete(freshToken, 3), 0)
        try await fresh.value
    }

    func testRemoveSettlesGatewayClosedAndReinstallWorks() async throws {
        let task = startWrite(Data([0x01]), reference: reference("provider.remove"))
        await waitForQueued(1)
        _ = floeSecretGatewayRemove()
        await expectFailure(task, .gatewayClosed)
        XCTAssertEqual(floeSecretMailboxAwait(10), -104)
        XCTAssertFalse(SecretGatewayRegistry.shared.isRegistered)

        XCTAssertEqual(floeSecretMailboxBind(2), 0)
        XCTAssertEqual(floeSecretGatewayInstall(), 0)
        XCTAssertTrue(SecretGatewayRegistry.shared.isRegistered)
        let read = startRead(reference("provider.remove.read"))
        await waitForQueued(1)
        let token = claim()
        XCTAssertEqual(complete(token, 2), 0)
        let value = try await read.value
        XCTAssertNil(value)
    }

    // MARK: Completion semantics

    func testEmptyVersusAbsentAndInvalidCompleteMatrix() async throws {
        let emptyRead = startRead(reference("provider.empty"))
        await waitForQueued(1)
        let emptyToken = claim()
        XCTAssertEqual(complete(emptyToken, 1, value: Data()), 0)
        let emptyValue = try await emptyRead.value
        XCTAssertNotNil(emptyValue)
        XCTAssertEqual(emptyValue, Data())

        let absentRead = startRead(reference("provider.absent"))
        await waitForQueued(1)
        let absentToken = claim()
        XCTAssertEqual(complete(absentToken, 2), 0)
        let absentValue = try await absentRead.value
        XCTAssertNil(absentValue)

        let invalidRead = startRead(reference("provider.invalid.complete"))
        await waitForQueued(1)
        let invalidToken = claim()
        XCTAssertEqual(floeSecretMailboxComplete(invalidToken, 1, nil, 5), -105)
        XCTAssertEqual(floeSecretMailboxIsLive(invalidToken), 1)
        XCTAssertEqual(complete(invalidToken, -14), 0)
        await expectFailure(invalidRead, .abandoned)

        let pointerRead = startRead(reference("provider.invalid.pointer"))
        await waitForQueued(1)
        let pointerToken = claim()
        var byte: UInt8 = 0x41
        let pointerCode = withUnsafePointer(to: &byte) {
            floeSecretMailboxComplete(pointerToken, 2, $0, 1)
        }
        XCTAssertEqual(pointerCode, -105)
        XCTAssertEqual(complete(pointerToken, -14), 0)
        await expectFailure(pointerRead, .abandoned)
    }

    func testPositiveStatusMustMatchClaimedOperation() async throws {
        func expectWrong<T>(_ task: Task<T, Error>, status: Int32, value: Data?,
                            file: StaticString = #filePath,
                            line: UInt = #line) async {
            await waitForQueued(1, file: file, line: line)
            let token = claim()
            XCTAssertGreaterThan(token, 0, file: file, line: line)
            let unknownBefore = counter("effectUnknown")
            XCTAssertEqual(complete(token, status, value: value), -105,
                           "wrong positive status must be nonterminal", file: file, line: line)
            XCTAssertEqual(floeSecretMailboxIsLive(token), 1,
                           "claim/continuation/permits unchanged", file: file, line: line)
            XCTAssertEqual(counter("effectUnknown"), unknownBefore,
                           "operation/status mismatch must not change effect accounting",
                           file: file, line: line)
            XCTAssertEqual(intStat("permitsHeld"), 1, file: file, line: line)
            XCTAssertEqual(complete(token, -14), 0, file: file, line: line)
            await expectFailure(task, .abandoned, file: file, line: line)
        }

        var index = 0
        for status in [Int32(3), Int32(4)] {
            let task = startRead(reference("provider.status.read.\(index)"))
            await expectWrong(task, status: status, value: nil)
            index += 1
        }
        for status in [Int32(1), Int32(2), Int32(4)] {
            let task = startWrite(Data([0x41]), reference: reference("provider.status.write.\(index)"))
            await expectWrong(task, status: status,
                              value: status == 1 ? Data([0x42]) : nil)
            index += 1
        }
        for status in [Int32(1), Int32(2), Int32(3)] {
            let task = startDelete(reference("provider.status.delete.\(index)"))
            await expectWrong(task, status: status,
                              value: status == 1 ? Data([0x42]) : nil)
            index += 1
        }
    }

    // MARK: Watchdog / health

    func testWatchdogSettlesClaimedCallerAndRetainsPermit() async throws {
        SecretRequestMailbox.shared.configureForTesting(
            heartbeatStaleMillis: 60_000,
            watchdogStaleMillis: 40,
            watchdogTickMillis: 10
        )
        let task = startWrite(Data([0x55]), reference: reference("provider.watchdog"))
        await waitForQueued(1)
        let token = claim()
        XCTAssertGreaterThan(token, 0)
        clock.advance(200)
        await waitFor({ self.counter("watchdogSettled") >= 1 }, timeout: 2.0)
        await expectFailure(task, .dispatcherUnresponsive)
        XCTAssertEqual(intStat("permitsHeld"), 1, "watchdog never frees execution permits")
        XCTAssertEqual(intStat("callerSettledOutstanding"), 1)
        XCTAssertEqual(complete(token, -13), -103)
        XCTAssertEqual(intStat("permitsHeld"), 0)
        XCTAssertGreaterThanOrEqual(counter("skippedNoEffect"), 1)
        _ = floeSecretGatewayRemove()
        XCTAssertEqual((statsObject()["watchdogRunning"] as? NSNumber)?.boolValue, false)
    }

    func testCallerCancelAndWatchdogUnknownEffectsArePerTicket() async throws {
        SecretRequestMailbox.shared.configureForTesting(
            heartbeatStaleMillis: 60_000,
            watchdogStaleMillis: 40,
            watchdogTickMillis: 10
        )
        let aTask = startRead(reference("provider.unknown.a"))
        let bTask = startRead(reference("provider.unknown.b"))
        await waitForQueued(2)
        let a = claim()
        let b = claim()
        XCTAssertGreaterThan(a, 0)
        XCTAssertGreaterThan(b, 0)

        bTask.cancel()
        await expectCancellation(bTask)
        XCTAssertEqual(counter("effectUnknown"), 1,
                       "canceled claimed B contributes one unknown effect")

        clock.advance(200)
        await waitFor({ self.counter("watchdogSettled") >= 1 }, timeout: 2.0)
        await expectFailure(aTask, .dispatcherUnresponsive)
        XCTAssertEqual(counter("effectUnknown"), 2,
                       "watchdog-settled A contributes its own unknown effect")

        XCTAssertEqual(complete(b, 1, value: Data([0x42])), -103)
        XCTAssertEqual(counter("effectUnknown"), 1,
                       "B's late authoritative success may decrement only B")
        XCTAssertGreaterThanOrEqual(counter("effectCommitted"), 1)

        XCTAssertEqual(floeSecretMailboxComplete(a, -13, nil, 0), -103)
        XCTAssertEqual(counter("effectUnknown"), 0)
        XCTAssertGreaterThanOrEqual(counter("skippedNoEffect"), 1)
    }

    func testBackendBusyAndStaleHeartbeatAreDistinct() async throws {
        SecretRequestMailbox.shared.configureForTesting(
            heartbeatStaleMillis: 60_000,
            backendProgressWindowMillis: 50
        )
        var tasks: [Task<Void, Error>] = []
        for index in 0..<16 {
            tasks.append(startWrite(Data([0x21]), reference: reference("provider.busy.\(index)")))
        }
        await waitForQueued(16)
        var claims: [Int64] = []
        for _ in 0..<16 { claims.append(claim()) }
        clock.advance(200)
        let busy = startWrite(Data([0x22]), reference: reference("provider.busy.17"))
        await expectFailure(busy, .backendBusy)
        XCTAssertGreaterThanOrEqual(counter("backendBusy"), 1)

        XCTAssertEqual(complete(claims[0], 3), 0)
        let recovered = startWrite(Data([0x23]), reference: reference("provider.busy.recover"))
        await waitForQueued(1)
        let recoveredToken = claim()
        XCTAssertGreaterThan(recoveredToken, 0)
        XCTAssertEqual(complete(recoveredToken, 3), 0)
        try await recovered.value
        for token in claims.dropFirst() { XCTAssertEqual(complete(token, 3), 0) }
        for task in tasks { try await task.value }

        SecretRequestMailbox.shared.configureForTesting(heartbeatStaleMillis: 30)
        clock.advance(200)
        let stale = startWrite(Data([0x24]), reference: reference("provider.stale"))
        await expectFailure(stale, .dispatcherUnresponsive)
        XCTAssertEqual(floeSecretMailboxBind(2), 0)
        let refreshed = startWrite(Data([0x25]), reference: reference("provider.stale.fresh"))
        await waitForQueued(1)
        let refreshedToken = claim()
        XCTAssertEqual(complete(refreshedToken, 3), 0)
        try await refreshed.value
    }

    // MARK: Hygiene / identity

    func testStatsContainCountersOnly() async throws {
        let secret = Data("super-secret-value-never-in-stats".utf8)
        let account = "provider.stats.hygiene"
        let task = startWrite(secret, reference: reference(account))
        await waitForQueued(1)
        let token = claim()
        _ = take(token)
        let stats = statsObject()
        for key in ["epoch", "bound", "readyAcked", "heartbeatAgeMillis",
                    "watchdogRunning", "lastWatchdogAt", "queued", "permitsHeld",
                    "pendingPayloadBytes", "callerSettledOutstanding",
                    "intentsLive", "leasesActive", "leasesCloseFailed", "counters"] {
            XCTAssertNotNil(stats[key], "missing stats key \(key)")
        }
        let counters = try XCTUnwrap(stats["counters"] as? [String: Any])
        XCTAssertNotNil(counters["watchdogSettled"])
        XCTAssertNotNil(counters["effectUnknown"])
        let encoded = String(data: try JSONSerialization.data(withJSONObject: stats), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("super-secret-value"))
        XCTAssertFalse(encoded.contains("ref:v1:"))
        XCTAssertFalse(encoded.contains(account))
        XCTAssertFalse(encoded.contains("reference"))
        XCTAssertEqual(complete(token, 3), 0)
        try await task.value
    }

    func testReferenceStrictness() async throws {
        do {
            _ = try await MailboxSecretGateway.shared.read(reference: "ref:v1:abcd")
            XCTFail("short reference accepted")
        } catch let error as SecretBackendError {
            XCTAssertEqual(error, .invalidReference)
        }
        let valid = reference("provider.strict")
        XCTAssertEqual(valid.utf8.count, 71)
        let overlong = valid + "0"
        do {
            _ = try await MailboxSecretGateway.shared.read(reference: overlong)
            XCTFail("72-byte reference accepted as logical 71")
        } catch let error as SecretBackendError {
            XCTAssertEqual(error, .invalidReference)
        }
        let uppercase = "ref:v1:" + String(repeating: "A", count: 64)
        do {
            _ = try await MailboxSecretGateway.shared.read(reference: uppercase)
            XCTFail("uppercase reference accepted")
        } catch let error as SecretBackendError {
            XCTAssertEqual(error, .invalidReference)
        }
        let task = startRead(valid)
        await waitForQueued(1)
        let token = claim()
        XCTAssertEqual(complete(token, 2), 0)
        let readValue = try await task.value
        XCTAssertNil(readValue)
    }

    func testDeleteReturnsKnownNoEffectStatuses() async throws {
        let task = startDelete(reference("provider.delete"))
        await waitForQueued(1)
        let token = claim()
        let (describeCode, descriptor) = describe(token)
        XCTAssertGreaterThanOrEqual(describeCode, 0)
        XCTAssertEqual(descriptor?.contains("\"op\":\"delete\"") == true, true)
        XCTAssertEqual(complete(token, 4), 0)
        try await task.value
        XCTAssertGreaterThanOrEqual(counter("effectCommitted"), 1)
    }
}
