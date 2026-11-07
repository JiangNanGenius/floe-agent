// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeTools
import FloeToolboxCore
import FloeToolboxUSB

/// The native USB executor is single-flight; the existing serial UI has an
/// independent receive pump and sender. Serialize their real USB operations,
/// without busy retries, replay, a second driver or a substitute transport.
actor ToolboxUSBTransport: SerialConnection {
    private nonisolated enum Operation: Sendable {
        case send(Data), receive(Int)
        var writeBytes: Int { if case .send(let bytes) = self { bytes.count } else { 0 } }
    }
    private nonisolated struct Job: Sendable {
        let id: UUID
        let operation: Operation
        let cancellation: CancellationToken
        let completion: CheckedContinuation<Data, any Error>
    }
    private let connection: any SerialConnection
    private let failed: @Sendable (ToolboxUSBFailure) async -> Void
    private var jobs: [Job] = []
    private var active: Job?
    private var reservedBytes = 0
    private var closed = false
    private var draining: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private(set) var failure: ToolboxUSBFailure?
    var queuedRequestCount: Int { jobs.count }
    var reservedWriteByteCount: Int { reservedBytes }

    init(connection: any SerialConnection, failed: @escaping @Sendable (ToolboxUSBFailure) async -> Void = { _ in }) {
        self.connection = connection; self.failed = failed
    }
    func send(_ bytes: Data) async throws {
        guard bytes.count <= 65_536 else { throw ToolboxError.limit("USB write") }
        _ = try await submit(.send(bytes))
    }
    func receive(maximumBytes: Int) async throws -> Data {
        guard (1...65_536).contains(maximumBytes) else { throw ToolboxError.limit("USB read") }
        return try await submit(.receive(maximumBytes))
    }
    private func submit(_ operation: Operation) async throws -> Data {
        let id = UUID(), cancellation = CancellationToken()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { completion in
                guard !closed else { completion.resume(throwing: ToolboxError.staleSession); return }
                guard jobs.count + (active == nil ? 0 : 1) < 8,
                      reservedBytes + operation.writeBytes <= 256 * 1024 else {
                    completion.resume(throwing: ToolboxError.limit("USB pending operations")); return
                }
                guard !cancellation.isCancelled, !Task.isCancelled else { completion.resume(throwing: CancellationError()); return }
                jobs.append(Job(id: id, operation: operation, cancellation: cancellation, completion: completion))
                reservedBytes += operation.writeBytes
                if draining == nil { draining = Task { await self.drain() } }
            }
        } onCancel: {
            cancellation.cancel() // Visible before the actor processes cancel(id).
            Task { await self.cancel(id) }
        }
    }
    private func cancel(_ id: UUID) async {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            let job = jobs.remove(at: index); reservedBytes -= job.operation.writeBytes
            job.completion.resume(throwing: CancellationError())
        } else if let job = active, job.id == id {
            active = nil; reservedBytes -= job.operation.writeBytes
            job.completion.resume(throwing: CancellationError())
            await close() // An in-flight write cannot safely be replayed.
            await failed(.closed)
        }
    }
    private func drain() async {
        defer { draining = nil }
        while !closed, !jobs.isEmpty {
            let job = jobs.removeFirst()
            if job.cancellation.isCancelled {
                reservedBytes -= job.operation.writeBytes
                job.completion.resume(throwing: CancellationError()); continue
            }
            active = job
            do {
                let bytes: Data
                switch job.operation {
                case .send(let payload):
                    try await connection.send(payload); bytes = Data()
                case .receive(let maximum):
                    do { bytes = try await connection.receive(maximumBytes: maximum) }
                    catch USBClientError.io(let code) where code == Int32(bitPattern: 0xe00002d6) {
                        // Public IOReturn.h: kIOReturnTimeout = iokit_common_err(0x2d6).
                        // Only a verified USB READ poll timeout is idle. A write
                        // timeout or an IOKit call/permission error is not hidden.
                        bytes = Data()
                    }
                    if bytes.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
                }
                guard !closed, active?.id == job.id else { return }
                active = nil; reservedBytes -= job.operation.writeBytes
                job.completion.resume(returning: bytes)
            } catch {
                guard !closed, active?.id == job.id else { return }
                active = nil; reservedBytes -= job.operation.writeBytes
                job.completion.resume(throwing: error)
                let value = ToolboxUSBFailure.from(error); failure = value
                await close()
                await failed(value)
                return
            }
        }
    }
    func close() async {
        if let closing { await closing.value; return }
        closed = true // Fence new requests before clearing any waiter.
        draining?.cancel()
        if let active { active.completion.resume(throwing: ToolboxError.staleSession) }
        active = nil
        let pending = jobs; jobs.removeAll(); reservedBytes = 0
        for job in pending { job.completion.resume(throwing: ToolboxError.staleSession) }
        let connection = connection
        let task = Task { await connection.close() }
        closing = task
        await task.value // Coalesces concurrent closes; never waits for drain/read.
    }
}
#endif
