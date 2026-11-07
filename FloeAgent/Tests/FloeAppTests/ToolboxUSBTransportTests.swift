// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeToolboxCore
import FloeToolboxUSB
@testable import FloeApp

private actor HeldUSBConnection: SerialConnection {
    private(set) var writes: [Data] = []
    private(set) var closeCount = 0
    private(set) var maximumInFlight = 0
    private var inFlight = 0
    private var heldRead: CheckedContinuation<Data, any Error>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    func waitUntilReading() async {
        if heldRead != nil { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
    func releaseRead() {
        let value = heldRead; heldRead = nil
        if closed { value?.resume(throwing: ToolboxError.staleSession) }
        else { value?.resume(returning: Data([7])) }
    }
    func send(_ bytes: Data) throws {
        guard !closed else { throw ToolboxError.staleSession }
        inFlight += 1; maximumInFlight = max(maximumInFlight, inFlight)
        writes.append(bytes); inFlight -= 1
    }
    func receive(maximumBytes: Int) async throws -> Data {
        guard !closed else { throw ToolboxError.staleSession }
        inFlight += 1; maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            heldRead = continuation
            let values = startedWaiters; startedWaiters.removeAll(); for value in values { value.resume() }
        }
    }
    func close() { closed = true; closeCount += 1 } // Does not release the held read; adapter close must not wait for it.
}
private actor TimeoutUSBConnection: SerialConnection {
    let readError: Bool
    private(set) var sends = 0, reads = 0, closes = 0
    init(readError: Bool) { self.readError = readError }
    func send(_ bytes: Data) throws { sends += 1; if !readError { throw USBClientError.io(Int32(bitPattern: 0xe00002d6)) } }
    func receive(maximumBytes: Int) throws -> Data {
        reads += 1
        if readError { throw USBClientError.io(Int32(bitPattern: 0xe00002d6)) }
        return Data([7])
    }
    func close() { closes += 1 }
}
private nonisolated func awaitUSBQueue(_ transport: ToolboxUSBTransport, count: Int) async throws {
    let deadline = Date().addingTimeInterval(2)
    while await transport.queuedRequestCount != count, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(await transport.queuedRequestCount == count)
}

@Suite("Bounded USB App transport", .serialized, .timeLimit(.minutes(1)))
struct ToolboxUSBTransportTests {
    @Test func simultaneousPumpAndSenderUseOneRealOperationAtATimeWithoutReplay() async throws {
        let native = HeldUSBConnection(), transport = ToolboxUSBTransport(connection: native)
        let read = Task { try await transport.receive(maximumBytes: 1024) }
        await native.waitUntilReading()
        let send = Task { try await transport.send(Data([1, 2])) }
        try await awaitUSBQueue(transport, count: 1)
        #expect(await native.writes.isEmpty)
        await native.releaseRead()
        #expect(try await read.value == Data([7])); try await send.value
        #expect(await native.writes == [Data([1, 2])])
        #expect(await native.maximumInFlight == 1)
        await transport.close()
    }
    @Test func cancelledQueuedSendNeverReachesNativeConnection() async throws {
        let native = HeldUSBConnection(), transport = ToolboxUSBTransport(connection: native)
        let read = Task { try await transport.receive(maximumBytes: 1024) }; await native.waitUntilReading()
        let send = Task { try await transport.send(Data([99])) }
        try await awaitUSBQueue(transport, count: 1)
        send.cancel()
        await #expect(throws: CancellationError.self) { try await send.value }
        await native.releaseRead(); _ = try await read.value
        #expect(await native.writes.isEmpty)
        #expect(await transport.reservedWriteByteCount == 0)
        await transport.close()
    }
    @Test func closeResumesReadAndQueuedSenderBeforeNativeReadCompletesAndClosesOnlyOnce() async throws {
        let native = HeldUSBConnection(), transport = ToolboxUSBTransport(connection: native)
        let read = Task { try await transport.receive(maximumBytes: 1024) }; await native.waitUntilReading()
        let send = Task { try await transport.send(Data([88])) }
        try await awaitUSBQueue(transport, count: 1)
        await transport.close(); await transport.close()
        await #expect(throws: ToolboxError.staleSession) { _ = try await read.value }
        await #expect(throws: ToolboxError.staleSession) { try await send.value }
        #expect(await native.closeCount == 1)
        #expect(await native.writes.isEmpty)
        await #expect(throws: ToolboxError.staleSession) { try await transport.send(Data([77])) }
        await native.releaseRead() // Drain the test fixture only after close assertions.
    }
    @Test func activeCancellationClosesOwnedChannelAndFencesQueuedSendWithoutReplay() async throws {
        let native = HeldUSBConnection(), transport = ToolboxUSBTransport(connection: native)
        let read = Task { try await transport.receive(maximumBytes: 1024) }; await native.waitUntilReading()
        let send = Task { try await transport.send(Data([66])) }
        try await awaitUSBQueue(transport, count: 1)
        read.cancel()
        await #expect(throws: CancellationError.self) { _ = try await read.value }
        await #expect(throws: ToolboxError.staleSession) { try await send.value }
        await transport.close()
        #expect(await native.closeCount == 1)
        #expect(await native.writes.isEmpty)
        await native.releaseRead()
    }
    @Test func pendingByteBudgetRejectsExcessBeforeNativeWriteAndCleanupReleasesAllReservations() async throws {
        let native = HeldUSBConnection(), transport = ToolboxUSBTransport(connection: native)
        let read = Task { try await transport.receive(maximumBytes: 1024) }; await native.waitUntilReading()
        var pending: [Task<Void, any Error>] = []
        for index in 1...4 {
            pending.append(Task { try await transport.send(Data(repeating: UInt8(index), count: 65_536)) })
            try await awaitUSBQueue(transport, count: index)
        }
        await #expect(throws: ToolboxError.self) { try await transport.send(Data([5])) }
        #expect(await transport.reservedWriteByteCount == 256 * 1024)
        await transport.close()
        _ = try? await read.value; for task in pending { _ = try? await task.value }
        #expect(await native.writes.isEmpty)
        #expect(await transport.reservedWriteByteCount == 0)
        await native.releaseRead()
    }
    @Test func requestCountBudgetRejectsNinthOperationWithoutDroppingTheFirstEight() async throws {
        let native = HeldUSBConnection(), transport = ToolboxUSBTransport(connection: native)
        let read = Task { try await transport.receive(maximumBytes: 1024) }; await native.waitUntilReading()
        var pending: [Task<Void, any Error>] = []
        for index in 1...7 {
            pending.append(Task { try await transport.send(Data([UInt8(index)])) })
            try await awaitUSBQueue(transport, count: index)
        }
        await #expect(throws: ToolboxError.self) { try await transport.send(Data([9])) }
        #expect(await transport.queuedRequestCount == 7)
        await transport.close(); _ = try? await read.value
        for task in pending { _ = try? await task.value }; await native.releaseRead()
    }
    @Test func readPollTimeoutIsIdleButWriteTimeoutIsReportedClosedAndNeverRetried() async throws {
        let idle = TimeoutUSBConnection(readError: true), readTransport = ToolboxUSBTransport(connection: idle)
        #expect(try await readTransport.receive(maximumBytes: 1024).isEmpty)
        try await readTransport.send(Data([1]))
        #expect(await idle.reads == 1); #expect(await idle.sends == 1)
        await readTransport.close()
        let failed = TimeoutUSBConnection(readError: false), writeTransport = ToolboxUSBTransport(connection: failed)
        await #expect(throws: USBClientError.self) { try await writeTransport.send(Data([2])) }
        await writeTransport.close()
        #expect(await failed.sends == 1); #expect(await failed.closes == 1)
        await #expect(throws: ToolboxError.staleSession) { try await writeTransport.send(Data([3])) }
    }
}
#endif
