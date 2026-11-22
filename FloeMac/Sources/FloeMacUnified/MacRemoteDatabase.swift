// SPDX-License-Identifier: MPL-2.0

import FloeCore
import FloeModels
import FloePersistence
import Foundation

/// Adapts the native OpenSSH and VNC controls to the same host and session
/// tables used by iPad. Mac-created entries use system authentication.
actor MacRemoteDatabase: MacRemoteHostStore, MacRemoteSessionRegistry {
    private enum HostAuthentication: Codable { case none }
    private struct StoredEndpoint: Codable {
        let id: UUID
        let displayName: String
        let host: String
        let port: Int
        let transport: String
    }

    typealias Storage = (hosts: RemoteHostStore, sessions: SQLiteRemoteSessionRegistry)
    private let storage: @Sendable () async throws -> Storage

    init(storage: @escaping @Sendable () async throws -> Storage) {
        self.storage = storage
    }

    func hosts() async throws -> [MacRemoteHostProfile] {
        let store = try await storage().hosts
        return try await store.hosts().compactMap { row in
            guard Self.isSystemHost(row) else { return nil }
            let endpoints = try row.vncEndpointsJSON.map {
                try JSONDecoder().decode([StoredEndpoint].self, from: Data($0.utf8))
            } ?? []
            return MacRemoteHostProfile(id: row.id, displayName: row.displayName,
                address: row.address, port: row.port, user: row.user,
                vncEndpoints: endpoints.filter { $0.transport == "direct" }.map {
                    MacRemoteVNCEndpoint(id: $0.id, displayName: $0.displayName, host: $0.host, port: $0.port)
                })
        }
    }

    func saveHost(_ host: MacRemoteHostProfile) async throws {
        let host = try host.validated()
        let store = try await storage().hosts
        if let current = try await store.host(id: host.id), !Self.isSystemHost(current) {
            throw FloeError.validationFailed("This host uses a different connection profile.")
        }
        let endpoints = host.vncEndpoints.map {
            StoredEndpoint(id: $0.id, displayName: $0.displayName, host: $0.host, port: $0.port, transport: "direct")
        }
        try await store.saveHost(id: host.id, displayName: host.displayName, address: host.address, port: host.port,
            user: host.user, authJSON: String(decoding: try JSONEncoder().encode(HostAuthentication.none), as: UTF8.self),
            jumpChainJSON: "[]", hostKeyPolicy: "trustOnFirstUse", allowsLegacyAlgorithms: false, vncEndpointJSON: nil,
            isRemoteExecutionEnvironment: false, vncEndpointsJSON: String(decoding: try JSONEncoder().encode(endpoints), as: UTF8.self))
    }

    func deleteHost(id: UUID) async throws {
        let stores = try await storage()
        guard let host = try await stores.hosts.host(id: id), Self.isSystemHost(host) else { return }
        guard try await stores.sessions.activeSessions().allSatisfy({ $0.hostID != id }) else {
            throw FloeError.validationFailed("Disconnect this host before deleting it.")
        }
        try await stores.hosts.deleteHost(id: id)
    }

    func upsert(_ session: MacRemoteSessionRecord) async throws {
        let row = try Self.convert(session, to: RemoteSessionRecord.self)
        try await storage().sessions.upsert(row)
    }

    func session(id: UUID) async throws -> MacRemoteSessionRecord? {
        try await storage().sessions.session(id: id).map { try Self.convert($0, to: MacRemoteSessionRecord.self) }
    }

    func sessions(hostID: UUID) async throws -> [MacRemoteSessionRecord] {
        try await storage().sessions.sessions(hostID: hostID).map { try Self.convert($0, to: MacRemoteSessionRecord.self) }
    }

    func activeSessions() async throws -> [MacRemoteSessionRecord] {
        try await storage().sessions.activeSessions().map { try Self.convert($0, to: MacRemoteSessionRecord.self) }
    }

    func updateState(id: UUID, state: MacRemoteSessionRecord.State, lastHeartbeatAt: Date?) async throws {
        guard let translated = RemoteSessionRecord.State(rawValue: state.rawValue) else {
            throw FloeError.validationFailed("Unknown remote session state.")
        }
        try await storage().sessions.updateState(id: id, state: translated, lastHeartbeatAt: lastHeartbeatAt)
    }

    func removeSession(id: UUID) async throws {
        try await storage().sessions.removeSession(id: id)
    }

    private static func isSystemHost(_ row: RemoteHostStore.StoredHost) -> Bool {
        row.isRemoteExecutionEnvironment == false && row.hostKeyPolicy == "trustOnFirstUse" &&
            !row.allowsLegacyAlgorithms && row.jumpChainJSON == "[]" &&
            (try? JSONDecoder().decode(HostAuthentication.self, from: Data(row.authJSON.utf8))) != nil
    }

    private static func convert<T: Encodable, U: Decodable>(_ value: T, to type: U.Type) throws -> U {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
}
