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
    case unsupportedVersion, unavailable, notShared, invalidResponse, tooLarge, disconnected, busy, conflict, cursorExpired
}

public struct DeviceHistoryPage: Sendable {
    let archive: Data
    let nextCursor: String?
    let through: Int64
    let hasMore: Bool

    public init(archive: Data, nextCursor: String?, through: Int64, hasMore: Bool) {
        self.archive = archive
        self.nextCursor = nextCursor
        self.through = through
        self.hasMore = hasMore
    }
}

public enum DeviceHistoryDelivery: Sendable {
    case archive(Data)
    case page(Data, nextCursor: String?)
}

/// App-owned endpoints for a single native conversation store. The wire only
/// reads through this boundary. The recipient explicitly imports verified
/// bytes from its own UI after selecting an offered conversation.
public struct DeviceHistorySource: Sendable {
    let list: @Sendable (Set<UUID>) async throws -> [DeviceHistoryOffer]
    let export: @Sendable (UUID) async throws -> Data
    let exportPage: (@Sendable (UUID, String?, Int64?) async throws -> DeviceHistoryPage)?

    public init(list: @escaping @Sendable (Set<UUID>) async throws -> [DeviceHistoryOffer],
                export: @escaping @Sendable (UUID) async throws -> Data,
                exportPage: (@Sendable (UUID, String?, Int64?) async throws -> DeviceHistoryPage)? = nil) {
        self.list = list
        self.export = export
        self.exportPage = exportPage
    }
}

public actor DeviceHistorySync {
    public static let maximumArchiveBytes = 32 * 1_024 * 1_024
    public static let maximumSharedTasks = 200
    private static let chunkSize = 384 * 1_024
    private static let maximumSessions = 4
    private static let maximumCursorBytes = 160

    private struct Request: Codable {
        enum Operation: String, Codable { case offers, prepare, chunk, preparePage }
        var version = 1
        let operation: Operation
        var taskID: UUID? = nil
        var offset: Int? = nil
        var after: String? = nil
        var through: Int64? = nil
    }

    private struct Reply: Codable {
        var version = 1
        var failure: String? = nil
        var offers: [DeviceHistoryOffer]? = nil
        var size: Int? = nil
        var digest: String? = nil
        var bytes: Data? = nil
        var historyPages: Bool? = nil
        var nextCursor: String? = nil
        var through: Int64? = nil
        var hasMore: Bool? = nil
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
            try await Self.fetchOffers(on: connection).offers
        }
    }

    public func history(_ taskID: UUID, from peer: FloeDeviceLinkAddress) async throws -> Data {
        try await withConnection(to: peer) { connection in
            let manifest = try await Self.request(.init(operation: .prepare, taskID: taskID), on: connection)
            return try await Self.readArchive(manifest, taskID: taskID, on: connection)
        }
    }

    /// Each delivered page has been fully received and verified. The caller
    /// commits it before the sender is asked for the next page.
    public func transferHistory(
        _ taskID: UUID, from peer: FloeDeviceLinkAddress, after savedCursor: String?,
        onPage: @Sendable (DeviceHistoryDelivery) async throws -> Void
    ) async throws {
        guard Self.validCursor(savedCursor) else { throw DeviceHistorySyncError.invalidResponse }
        try await withConnection(to: peer) { connection in
            let offered = try await Self.fetchOffers(on: connection)
            guard offered.offers.contains(where: { $0.id == taskID }) else { throw DeviceHistorySyncError.notShared }
            guard offered.historyPages else {
                let manifest = try await Self.request(.init(operation: .prepare, taskID: taskID), on: connection)
                let data = try await Self.readArchive(manifest, taskID: taskID, on: connection)
                try await onPage(.archive(data))
                return
            }

            var cursor = savedCursor
            var through: Int64?
            var visitedCursors = Set<String>()
            while true {
                try Task.checkCancellation()
                let manifest: Reply
                do {
                    manifest = try await Self.request(.init(operation: .preparePage, taskID: taskID,
                                                            after: cursor, through: through), on: connection)
                } catch DeviceHistorySyncError.cursorExpired where through == nil && cursor != nil {
                    // The peer may have restored an older database. Re-read
                    // from the beginning and let the store deduplicate.
                    cursor = nil
                    continue
                }
                guard let upperBound = manifest.through, upperBound >= 0,
                      through == nil || through == upperBound,
                      let hasMore = manifest.hasMore, Self.validCursor(manifest.nextCursor) else {
                    throw DeviceHistorySyncError.invalidResponse
                }
                if hasMore {
                    guard let next = manifest.nextCursor, next != cursor,
                          visitedCursors.insert(next).inserted, visitedCursors.count < upperBound else {
                        throw DeviceHistorySyncError.invalidResponse
                    }
                }
                let data = try await Self.readArchive(manifest, taskID: taskID, on: connection)
                try await onPage(.page(data, nextCursor: manifest.nextCursor))
                if !hasMore { return }
                through = upperBound
                cursor = manifest.nextCursor
            }
        }
    }

    private static func fetchOffers(on connection: FloeDeviceLinkConnection) async throws
        -> (offers: [DeviceHistoryOffer], historyPages: Bool) {
        let reply = try await request(.init(operation: .offers), on: connection)
        guard let offers = reply.offers, offers.count <= maximumSharedTasks,
              Set(offers.map(\.id)).count == offers.count,
              offers.allSatisfy({ !$0.title.isEmpty && $0.title.utf8.count <= 1_024 }) else {
            throw DeviceHistorySyncError.invalidResponse
        }
        return (offers, reply.historyPages == true)
    }

    private static func validCursor(_ cursor: String?) -> Bool {
        cursor.map { !$0.isEmpty && $0.utf8.count <= maximumCursorBytes } ?? true
    }

    private static func readArchive(_ manifest: Reply, taskID: UUID, on connection: FloeDeviceLinkConnection) async throws -> Data {
        guard let size = manifest.size, size > 0, size <= maximumArchiveBytes,
              let expected = manifest.digest else { throw DeviceHistorySyncError.invalidResponse }
        let digest = try ContentDigest(validating: expected)
        var data = Data()
        data.reserveCapacity(size)
        while data.count < size {
            try Task.checkCancellation()
            let reply = try await request(.init(operation: .chunk, taskID: taskID, offset: data.count), on: connection)
            let count = min(size - data.count, chunkSize)
            guard let bytes = reply.bytes, bytes.count == count else { throw DeviceHistorySyncError.invalidResponse }
            data.append(bytes)
        }
        guard ContentDigest.compute(Array(data)) == digest else { throw DeviceHistorySyncError.invalidResponse }
        return data
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
            return (Reply(offers: Array(safe), historyPages: source.exportPage == nil ? nil : true), nil)
        }
        guard let taskID = request.taskID, allowed.contains(taskID) else { throw DeviceHistorySyncError.notShared }
        switch request.operation {
        case .offers:
            throw DeviceHistorySyncError.invalidResponse
        case .prepare:
            let data = try await source.export(taskID)
            guard !stopped, shares[peer]?.contains(taskID) == true else { throw DeviceHistorySyncError.notShared }
            return try Self.manifest(for: data, taskID: taskID)
        case .preparePage:
            guard let exportPage = source.exportPage else { throw DeviceHistorySyncError.unsupportedVersion }
            guard request.offset == nil, Self.validCursor(request.after),
                  request.through.map({ $0 >= 0 && request.after != nil }) ?? true else {
                throw DeviceHistorySyncError.invalidResponse
            }
            let page = try await exportPage(taskID, request.after, request.through)
            guard !stopped, shares[peer]?.contains(taskID) == true else { throw DeviceHistorySyncError.notShared }
            guard page.through >= 0, request.through == nil || request.through == page.through,
                  Self.validCursor(page.nextCursor),
                  !page.hasMore || (page.nextCursor != nil && page.nextCursor != request.after) else {
                throw DeviceHistorySyncError.invalidResponse
            }
            let (manifest, prepared) = try Self.manifest(for: page.archive, taskID: taskID)
            var reply = manifest
            reply.nextCursor = page.nextCursor
            reply.through = page.through
            reply.hasMore = page.hasMore
            return (reply, prepared)
        case .chunk:
            guard let archive, archive.taskID == taskID,
                  let offset = request.offset, offset >= 0, offset < archive.data.count else {
                throw DeviceHistorySyncError.invalidResponse
            }
            let end = min(offset + Self.chunkSize, archive.data.count)
            return (Reply(bytes: archive.data.subdata(in: offset..<end)), end == archive.data.count ? nil : archive)
        }
    }

    private static func manifest(for data: Data, taskID: UUID) throws -> (Reply, Archive) {
        guard !data.isEmpty, data.count <= maximumArchiveBytes else { throw DeviceHistorySyncError.tooLarge }
        return (Reply(size: data.count, digest: ContentDigest.compute(Array(data)).description), Archive(taskID: taskID, data: data))
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
