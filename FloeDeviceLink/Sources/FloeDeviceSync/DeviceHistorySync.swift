// SPDX-License-Identifier: MPL-2.0

import FloeDesktopSync
import FloeDeviceLink
import Foundation

public struct DeviceHistoryOffer: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String

    public init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }
}

public enum DeviceHistorySyncError: String, Error, Sendable {
    case unsupportedVersion, unavailable, notShared, invalidResponse, tooLarge, disconnected, busy, conflict
}

/// App-owned endpoints for a single native conversation store. The wire only
/// reads through this boundary. The recipient explicitly imports verified
/// bytes from its own UI after selecting an offered conversation.
public struct DeviceHistorySource: Sendable {
    let list: @Sendable (Set<UUID>) async throws -> [DeviceHistoryOffer]
    let export: @Sendable (UUID) async throws -> Data

    public init(list: @escaping @Sendable (Set<UUID>) async throws -> [DeviceHistoryOffer],
                export: @escaping @Sendable (UUID) async throws -> Data) {
        self.list = list
        self.export = export
    }
}

public actor DeviceHistorySync {
    public static let maximumArchiveBytes = 32 * 1_024 * 1_024
    public static let maximumSharedTasks = 200
    private static let chunkSize = 384 * 1_024
    private static let maximumSessions = 4

    private struct Request: Codable {
        enum Operation: String, Codable { case offers, prepare, chunk }
        var version = 1
        let operation: Operation
        let taskID: UUID?
        let offset: Int?
    }

    private struct Reply: Codable {
        var version = 1
        var failure: String? = nil
        var offers: [DeviceHistoryOffer]? = nil
        var size: Int? = nil
        var digest: String? = nil
        var bytes: Data? = nil
    }

    private struct Archive: Sendable {
        let taskID: UUID
        let data: Data
    }

    private let link: FloeDeviceLink
    private let source: DeviceHistorySource
    private var shares: [String: Set<UUID>]
    private var listener: Task<Void, Never>?
    private var sessions: [UUID: FloeDeviceLinkConnection] = [:]
    private var stopped = false

    public init(link: FloeDeviceLink, shares: [String: Set<UUID>], source: DeviceHistorySource) {
        self.link = link
        self.shares = shares
        self.source = source
    }

    public func start() {
        guard !stopped, listener == nil else { return }
        listener = Task { [weak self, link] in
            while !Task.isCancelled {
                do {
                    guard let connection = try await link.acceptNext() else { return }
                    await self?.accept(connection)
                } catch is CancellationError {
                    return
                } catch {
                    // Authentication, transport closure, and failed handshakes
                    // never enter the request handler.
                    if !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
                }
            }
        }
    }

    public var localAddress: FloeDeviceLinkAddress { link.address() }

    public func replaceShares(_ shares: [String: Set<UUID>]) throws {
        try link.replaceTrustedEndpointIDs(Set(shares.keys))
        self.shares = shares
        for connection in sessions.values where shares[connection.peerEndpointID] == nil {
            try? connection.close()
        }
    }

    public func stop() async {
        stopped = true
        listener?.cancel()
        listener = nil
        for connection in sessions.values { try? connection.close() }
        sessions.removeAll()
        try? await link.close()
    }

    public func offers(from peer: FloeDeviceLinkAddress) async throws -> [DeviceHistoryOffer] {
        try await withConnection(to: peer) { connection in
            let reply = try await Self.request(.init(operation: .offers, taskID: nil, offset: nil), on: connection)
            guard let offers = reply.offers, offers.count <= Self.maximumSharedTasks,
                  Set(offers.map(\.id)).count == offers.count,
                  offers.allSatisfy({ !$0.title.isEmpty && $0.title.utf8.count <= 1_024 }) else {
                throw DeviceHistorySyncError.invalidResponse
            }
            return offers
        }
    }

    public func history(_ taskID: UUID, from peer: FloeDeviceLinkAddress) async throws -> Data {
        try await withConnection(to: peer) { connection in
            let manifest = try await Self.request(.init(operation: .prepare, taskID: taskID, offset: nil), on: connection)
            guard let size = manifest.size, size > 0, size <= Self.maximumArchiveBytes,
                  let expected = manifest.digest else { throw DeviceHistorySyncError.invalidResponse }
            let digest = try ContentDigest(validating: expected)
            var data = Data()
            data.reserveCapacity(size)
            while data.count < size {
                try Task.checkCancellation()
                let reply = try await Self.request(.init(operation: .chunk, taskID: taskID, offset: data.count), on: connection)
                let count = min(size - data.count, Self.chunkSize)
                guard let bytes = reply.bytes, bytes.count == count else { throw DeviceHistorySyncError.invalidResponse }
                data.append(bytes)
            }
            guard ContentDigest.compute(Array(data)) == digest else { throw DeviceHistorySyncError.invalidResponse }
            return data
        }
    }

    private func withConnection<T: Sendable>(to peer: FloeDeviceLinkAddress,
                                             operation: @Sendable (FloeDeviceLinkConnection) async throws -> T) async throws -> T {
        guard !stopped else { throw DeviceHistorySyncError.disconnected }
        let connection = try await link.connect(to: peer)
        defer { try? connection.close() }
        guard !stopped else { throw DeviceHistorySyncError.disconnected }
        return try await operation(connection)
    }

    private func accept(_ connection: FloeDeviceLinkConnection) {
        guard !stopped, sessions.count < Self.maximumSessions else {
            try? connection.close()
            return
        }
        let id = UUID()
        sessions[id] = connection
        Task { [weak self] in await self?.serve(connection, id: id) }
    }

    private func serve(_ connection: FloeDeviceLinkConnection, id: UUID) async {
        defer {
            sessions.removeValue(forKey: id)
            try? connection.close()
        }
        var archive: Archive?
        while !stopped {
            do {
                let stream = try await connection.receiveRequest()
                let request = try JSONDecoder().decode(Request.self, from: stream.payload)
                do {
                    let result = try await response(to: request, peer: connection.peerEndpointID, archive: archive)
                    archive = result.archive
                    try await stream.respond(JSONEncoder().encode(result.reply))
                } catch let failure as DeviceHistorySyncError {
                    try await stream.respond(JSONEncoder().encode(Reply(failure: failure.rawValue)))
                } catch {
                    try await stream.respond(JSONEncoder().encode(Reply(failure: DeviceHistorySyncError.unavailable.rawValue)))
                }
            } catch {
                return
            }
        }
    }

    private func response(to request: Request, peer: String, archive: Archive?) async throws -> (reply: Reply, archive: Archive?) {
        guard !stopped else { throw DeviceHistorySyncError.disconnected }
        guard request.version == 1 else { throw DeviceHistorySyncError.unsupportedVersion }
        let allowed = shares[peer, default: []]
        if request.operation == .offers {
            let offers = try await source.list(allowed)
            guard !stopped else { throw DeviceHistorySyncError.disconnected }
            let current = shares[peer, default: []]
            let safe = offers.filter { current.contains($0.id) }.prefix(Self.maximumSharedTasks)
            return (Reply(offers: Array(safe)), nil)
        }
        guard let taskID = request.taskID, allowed.contains(taskID) else { throw DeviceHistorySyncError.notShared }
        switch request.operation {
        case .offers:
            throw DeviceHistorySyncError.invalidResponse
        case .prepare:
            let data = try await source.export(taskID)
            guard !stopped, shares[peer]?.contains(taskID) == true else { throw DeviceHistorySyncError.notShared }
            guard !data.isEmpty, data.count <= Self.maximumArchiveBytes else { throw DeviceHistorySyncError.tooLarge }
            return (Reply(size: data.count, digest: ContentDigest.compute(Array(data)).description), Archive(taskID: taskID, data: data))
        case .chunk:
            guard let archive, archive.taskID == taskID,
                  let offset = request.offset, offset >= 0, offset < archive.data.count else {
                throw DeviceHistorySyncError.invalidResponse
            }
            let end = min(offset + Self.chunkSize, archive.data.count)
            return (Reply(bytes: archive.data.subdata(in: offset..<end)), end == archive.data.count ? nil : archive)
        }
    }

    private static func request(_ request: Request, on connection: FloeDeviceLinkConnection) async throws -> Reply {
        let data = try await connection.request(JSONEncoder().encode(request))
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.version == 1 else { throw DeviceHistorySyncError.unsupportedVersion }
        if let failure = reply.failure {
            throw DeviceHistorySyncError(rawValue: failure) ?? .invalidResponse
        }
        return reply
    }
}
