// SPDX-License-Identifier: MPL-2.0
import Foundation
import IrohLib
import Synchronization

public enum FloeDeviceLinkError: Error, Sendable, Equatable {
    case endpointClosed
    case relayUnavailable
    case relayNotAllowed
    case missingAddress
    case tooManyDirectAddresses
    case selfConnection
    case peerNotAuthorized
    case unexpectedProtocol
    case emptyPayload
    case payloadTooLarge
    case responseAlreadyUsed
}

/// An Iroh device identity. Store the private bytes in the host's credential store.
public struct FloeDeviceLinkIdentity: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate let key: SecretKey

    public init(privateKeyBytes: Data) throws {
        key = try SecretKey.fromBytes(bytes: privateKeyBytes)
    }

    private init(key: SecretKey) {
        self.key = key
    }

    public static func generate() -> Self {
        Self(key: SecretKey.generate())
    }

    public var endpointID: String { key.public().description }
    public var description: String { endpointID }
    public var debugDescription: String { endpointID }

    public func privateKeyBytes() -> Data {
        key.toBytes()
    }
}

/// Share these hints through the host's pairing flow. Only the endpoint ID authenticates the peer.
public struct FloeDeviceLinkAddress: Codable, Sendable, Equatable {
    public let endpointID: String
    public let relayURL: String?
    public let directAddresses: [String]

    public init(endpointID: String, relayURL: String? = nil, directAddresses: [String] = []) {
        self.endpointID = endpointID
        self.relayURL = relayURL
        self.directAddresses = directAddresses
    }
}

public enum FloeDeviceLinkRelay: Sendable {
    case publicIroh
    case disabled
    case custom(URL)
}

/// A host-owned endpoint. Changing peer approvals does not change its address.
public final class FloeDeviceLink: Sendable {
    private static let alpn = Data("floe/device-link/1".utf8)
    private static let maximumDirectAddresses = 16
    private let endpoint: Endpoint
    private let trustedPeers: Mutex<Set<EndpointId>>
    private let relayURLs: Set<String>

    private init(endpoint: Endpoint, trustedPeers: Set<EndpointId>, relayURLs: Set<String>) {
        self.endpoint = endpoint
        self.trustedPeers = Mutex(trustedPeers)
        self.relayURLs = relayURLs
    }

    public static func bind(
        identity: FloeDeviceLinkIdentity,
        trustedEndpointIDs: Set<String>,
        relay: FloeDeviceLinkRelay = .publicIroh,
        bindAddress: String? = nil
    ) async throws -> FloeDeviceLink {
        let trustedPeers = try Set(trustedEndpointIDs.map { try EndpointId.fromString(s: $0) })
        guard !trustedPeers.contains(identity.key.public()) else {
            throw FloeDeviceLinkError.selfConnection
        }
        try Task.checkCancellation()
        let mode: RelayMode
        switch relay {
        case .publicIroh: mode = RelayMode.defaultMode()
        case .disabled: mode = RelayMode.disabled()
        case .custom(let url):
            guard url.scheme == "https", url.host() != nil, url.user() == nil, url.password() == nil,
                  url.query() == nil, url.fragment() == nil else { throw FloeDeviceLinkError.relayNotAllowed }
            mode = try RelayMode.customFromUrls(urls: [url.absoluteString])
        }
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: presetMinimal(),
            bindAddr: bindAddress,
            secretKey: identity.privateKeyBytes(),
            alpns: [alpn],
            relayMode: mode
        ))
        if Task.isCancelled {
            try? await endpoint.close()
            throw CancellationError()
        }
        return FloeDeviceLink(endpoint: endpoint, trustedPeers: trustedPeers, relayURLs: Set(mode.relayMap().urls()))
    }

    var boundSockets: [String] { endpoint.boundSockets() }
    public var listeningPort: UInt16? {
        boundSockets.compactMap { $0.split(separator: ":").last.flatMap { UInt16($0) } }.first
    }

    public static func canonicalEndpointID(_ value: String) throws -> String {
        try EndpointId.fromString(s: value).description
    }

    public func replaceTrustedEndpointIDs(_ values: Set<String>) throws {
        let peers = try Set(values.map { try EndpointId.fromString(s: $0) })
        guard !peers.contains(endpoint.id()) else { throw FloeDeviceLinkError.selfConnection }
        trustedPeers.withLock { $0 = peers }
    }

    public func address(includeDirectAddresses: Bool = true) -> FloeDeviceLinkAddress {
        let address = endpoint.addr()
        return FloeDeviceLinkAddress(
            endpointID: address.id().description,
            relayURL: address.relayUrl(),
            directAddresses: includeDirectAddresses
                ? Array(address.directAddresses().prefix(Self.maximumDirectAddresses))
                : []
        )
    }

    /// Wait for Iroh's home relay registration. Cancelling this startup wait closes the endpoint.
    public func waitForRelayAddress() async throws -> FloeDeviceLinkAddress {
        guard !endpoint.isClosed() else { throw FloeDeviceLinkError.endpointClosed }
        guard !relayURLs.isEmpty else { throw FloeDeviceLinkError.relayUnavailable }
        return try await withTaskCancellationHandler {
            await endpoint.online()
            try Task.checkCancellation()
            guard !endpoint.isClosed() else { throw FloeDeviceLinkError.endpointClosed }
            let address = address(includeDirectAddresses: false)
            guard let relayURL = address.relayURL, relayURLs.contains(relayURL) else {
                throw FloeDeviceLinkError.relayUnavailable
            }
            return address
        } onCancel: {
            Task { try? await self.close() }
        }
    }

    public func connect(to address: FloeDeviceLinkAddress) async throws -> FloeDeviceLinkConnection {
        guard !endpoint.isClosed() else { throw FloeDeviceLinkError.endpointClosed }
        let expectedPeer = try EndpointId.fromString(s: address.endpointID)
        guard expectedPeer != endpoint.id() else { throw FloeDeviceLinkError.selfConnection }
        guard trustedPeers.withLock({ $0.contains(expectedPeer) }) else { throw FloeDeviceLinkError.peerNotAuthorized }
        guard address.directAddresses.count <= Self.maximumDirectAddresses else {
            throw FloeDeviceLinkError.tooManyDirectAddresses
        }
        if let relayURL = address.relayURL, !relayURLs.contains(relayURL) {
            throw FloeDeviceLinkError.relayNotAllowed
        }
        guard address.relayURL != nil || !address.directAddresses.isEmpty else {
            throw FloeDeviceLinkError.missingAddress
        }
        try Task.checkCancellation()
        let destination = EndpointAddr(id: expectedPeer, relayUrl: address.relayURL, addresses: address.directAddresses)
        let connection = try await endpoint.connect(addr: destination, alpn: Self.alpn)
        return try validate(connection, expectedPeer: expectedPeer)
    }

    /// Accept one authenticated connection. Call this from the host's listener.
    /// Closing the endpoint unblocks a listener waiting for the next connection.
    public func acceptNext() async throws -> FloeDeviceLinkConnection? {
        try Task.checkCancellation()
        guard let incoming = await endpoint.acceptNext() else { return nil }
        if Task.isCancelled {
            try? await incoming.refuse()
            throw CancellationError()
        }
        let accepting = try await incoming.accept()
        let connection = try await accepting.connect()
        return try validate(connection)
    }

    public func close() async throws {
        try await endpoint.close()
    }

    private func validate(
        _ connection: Connection,
        expectedPeer: EndpointId? = nil
    ) throws -> FloeDeviceLinkConnection {
        do {
            try Task.checkCancellation()
            guard connection.alpn() == Self.alpn else { throw FloeDeviceLinkError.unexpectedProtocol }
            let actualPeer = connection.remoteId()
            guard trustedPeers.withLock({ $0.contains(actualPeer) }),
                  expectedPeer.map({ $0 == actualPeer }) ?? true else {
                throw FloeDeviceLinkError.peerNotAuthorized
            }
            try connection.setMaxConcurrentBiStreams(count: 8)
            try connection.setMaxConcurrentUniStreams(count: 0)
            return FloeDeviceLinkConnection(connection: connection, peerEndpointID: actualPeer.description)
        } catch {
            try? connection.close(errorCode: 1, reason: Data())
            throw error
        }
    }
}
