import Foundation
import FloeToolboxCore

/// Retained by the host session owner. View reconstruction never starts a second reader.
public actor SerialReceiveService {
    public typealias Update = @Sendable () async -> Void
    private let session: SerialSession
    private let updated: Update
    private var reader: Task<Void,Never>?
    private var generation = UUID()
    public private(set) var lastFailure = false
    public init(session: SerialSession, updated: @escaping Update = {}) { self.session = session; self.updated = updated }
    public func start() throws {
        guard reader == nil else { throw ClientError.busy }
        let run = UUID(); generation = run; lastFailure = false
        reader = Task { await self.receiveLoop(run) }
    }
    private func receiveLoop(_ run: UUID) async {
        defer { if run == generation { reader = nil } }
        do {
            while run == generation, !Task.isCancelled {
                _ = try await session.receive(expected:session.lease)
                guard run == generation, !Task.isCancelled else { return }; await updated()
            }
        } catch { if run == generation, !Task.isCancelled { lastFailure = true; await updated() } }
    }
    public func close() async {
        generation = UUID(); reader?.cancel(); reader = nil
        await session.close()
    }
}

/// Adapts the App's existing BLE GATT service. `exchange` is bound to the host's immutable
/// run/session/peripheral IDs; this adapter never scans or chooses another accessory.
public actor HostBluetoothSerialConnection: SerialConnection {
    public typealias Exchange = @Sendable (Data?,TimeInterval,Int) async throws -> Data
    private struct Job: Sendable { let bytes: Data?; let maximum: Int; let gate: ClientCompletion<Data> }
    private let exchange: Exchange
    private let closeHost: @Sendable () async -> Void
    private let maximumWriteBytes: Int
    private var closed = false, draining = false
    private var jobs: [Job] = []
    private var pending = Data()
    private var activeGate: ClientCompletion<Data>?
    /// Default 20 is the minimum ATT payload. The host may supply the peripheral's actual
    /// maximumWriteValueLength; no oversized value is passed to CoreBluetooth.
    public init(maximumWriteBytes: Int = 20, exchange: @escaping Exchange, close: @escaping @Sendable () async -> Void) throws {
        guard (1...512).contains(maximumWriteBytes) else { throw ClientError.invalidConfiguration }
        self.maximumWriteBytes = maximumWriteBytes; self.exchange = exchange; closeHost = close
    }
    private func submit(_ bytes: Data?, maximum: Int) async throws -> Data {
        guard !closed, !Task.isCancelled else { throw ClientError.closed }
        guard jobs.count < 8, (bytes?.count ?? 0) <= 65536, (1...65536).contains(maximum) else { throw ClientError.tooLarge }
        let gate = ClientCompletion<Data>(); jobs.append(Job(bytes:bytes,maximum:maximum,gate:gate))
        if !draining { draining = true; Task { await self.drain() } }
        return try await gate.wait(seconds:300)
    }
    private func drain() async {
        while !closed, !jobs.isEmpty {
            let job = jobs.removeFirst(); guard job.gate.isPending else { continue }; activeGate = job.gate
            do {
                if let bytes = job.bytes {
                    var offset = 0
                    while offset < bytes.count {
                        guard !closed, job.gate.isPending else { throw CancellationError() }
                        let chunk = Data(bytes.dropFirst(offset).prefix(maximumWriteBytes))
                        let received = try await exchange(chunk,0,65536)
                        guard !closed, received.count <= 65536, pending.count+received.count <= 256*1024 else { throw ClientError.tooLarge }
                        pending += received; offset += chunk.count
                    }
                    job.gate.finish(.success(Data()))
                } else {
                    if pending.isEmpty {
                        let bytes = try await exchange(nil,0.2,job.maximum)
                        guard !closed, bytes.count <= job.maximum else { throw ClientError.tooLarge }; pending += bytes
                    }
                    let value = Data(pending.prefix(job.maximum)); pending.removeFirst(value.count); job.gate.finish(.success(value))
                }
            } catch { job.gate.finish(.failure(error)); if !closed { await close() } }
            activeGate = nil
        }
        draining = false
    }
    public func send(_ bytes: Data) async throws { _ = try await submit(bytes,maximum:65536) }
    public func receive(maximumBytes: Int) async throws -> Data { try await submit(nil,maximum:maximumBytes) }
    public func close() async {
        guard !closed else { return }; closed = true; activeGate?.finish(.failure(ClientError.closed))
        for job in jobs { job.gate.finish(.failure(ClientError.closed)) }; jobs.removeAll(); pending.removeAll(); await closeHost()
    }
}
