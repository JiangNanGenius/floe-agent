// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeDeviceLink

struct FloeDeviceLinkTests {
    @Test func identityRoundTrips() throws {
        let identity = FloeDeviceLinkIdentity.generate()
        let restored = try FloeDeviceLinkIdentity(privateKeyBytes: identity.privateKeyBytes())
        #expect(restored.endpointID == identity.endpointID)
    }

    @Test func exchangesBytesAndEnforcesPayloadBounds() async throws {
        try await withEndpoints { server, client in
            let address = try loopbackAddress(of: server)
            let (outgoing, incoming) = try await connect(client: client, server: server, address: address)
            #expect(outgoing.peerEndpointID == address.endpointID)
            #expect(incoming.peerEndpointID == client.address().endpointID)
            #expect(outgoing.paths().contains { $0.kind == .direct && $0.isSelected })

            await #expect(throws: FloeDeviceLinkError.emptyPayload) {
                try await outgoing.request(Data())
            }
            let oversized = Data(count: FloeDeviceLinkConnection.maximumPayloadBytes + 1)
            await #expect(throws: FloeDeviceLinkError.payloadTooLarge) {
                try await outgoing.request(oversized)
            }

            let payload = Data([0, 1, 255])
            let response = Task { try await outgoing.request(payload) }
            let request = try await incoming.receiveRequest()
            #expect(request.payload == payload)
            await #expect(throws: FloeDeviceLinkError.payloadTooLarge) {
                try await request.respond(oversized)
            }
            try await request.respond(request.payload)
            await #expect(throws: FloeDeviceLinkError.responseAlreadyUsed) {
                try await request.respond(payload)
            }
            #expect(try await response.value == payload)
        }
    }

    @Test func rejectsUnapprovedPeersBeforeExchange() async throws {
        try await withEndpoints(trustClient: false) { server, client in
            let serverAddress = try loopbackAddress(of: server)
            await #expect(throws: FloeDeviceLinkError.peerNotAuthorized) {
                try await server.connect(to: client.address())
            }

            let acceptance = Task { try await server.acceptNext() }
            do {
                _ = try await client.connect(to: serverAddress)
            } catch {
                // The listener may have already closed QUIC by the time the dial returns.
                try? await server.close()
            }
            await #expect(throws: FloeDeviceLinkError.peerNotAuthorized) {
                try await acceptance.value
            }
        }
    }

    @Test func rejectsUnconfiguredRelayBeforeDial() async throws {
        try await withEndpoints { server, client in
            let address = FloeDeviceLinkAddress(
                endpointID: server.address().endpointID,
                relayURL: "https://example.invalid/"
            )
            await #expect(throws: FloeDeviceLinkError.relayNotAllowed) {
                try await client.connect(to: address)
            }
        }
    }

    @Test func cancellationUnblocksAnOutstandingRequestAndAllowsReconnect() async throws {
        try await withEndpoints { server, client in
            let address = try loopbackAddress(of: server)
            let (outgoing, incoming) = try await connect(client: client, server: server, address: address)
            let request = Task { try await outgoing.request(Data([42])) }
            let unanswered = try await incoming.receiveRequest()
            #expect(unanswered.payload == Data([42]))
            request.cancel()
            await #expect(throws: CancellationError.self) {
                try await request.value
            }
            await #expect(throws: (any Error).self) {
                try await outgoing.request(Data([1]))
            }

            let (reconnected, peer) = try await connect(client: client, server: server, address: address)
            #expect(reconnected.peerEndpointID == outgoing.peerEndpointID)
            let payload = Data([7, 8, 9])
            let retry = Task { try await reconnected.request(payload) }
            let newRequest = try await peer.receiveRequest()
            try await newRequest.respond(newRequest.payload)
            #expect(try await retry.value == payload)
        }
    }

    @Test func closeUnblocksListener() async throws {
        let link = try await FloeDeviceLink.bind(
            identity: .generate(),
            trustedEndpointIDs: [],
            relay: .disabled
        )
        let listener = Task { try await link.acceptNext() }
        try await link.close()
        #expect(try await listener.value == nil)
    }
}

struct FloeDeviceLinkPublicRelayTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FLOE_DEVICE_LINK_PUBLIC_RELAY_TEST"] == "1"))
    func publicRelayBootstrapsAuthenticatedExchange() async throws {
        try await withEndpoints(relay: .publicIroh) { server, client in
            async let serverReady = relayAddress(of: server)
            async let clientReady = relayAddress(of: client)
            let address = try await serverReady
            _ = try await clientReady
            #expect(address.directAddresses.isEmpty)
            let (outgoing, incoming) = try await connect(client: client, server: server, address: address)
            let before = outgoing.paths()
            let payload = Data(repeating: 42, count: 128 * 1024)
            let response = Task { try await outgoing.request(payload) }
            let request = try await incoming.receiveRequest()
            #expect(request.payload == payload)
            try await request.respond(request.payload)
            #expect(try await response.value == payload)

            let after = outgoing.paths()
            #expect((before + after).contains { $0.kind == .relay && $0.bytesSent > 0 })
            for (phase, paths) in [("connected", before), ("after exchange", after)] {
                for path in paths {
                    print("Public relay probe: \(phase) \(path.kind) selected=\(path.isSelected) sent=\(path.bytesSent) received=\(path.bytesReceived)")
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FLOE_DEVICE_LINK_ANDROID_INTEROP_DIR"] != nil))
    func androidPeerExchangesBytesWithMac() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["FLOE_DEVICE_LINK_ANDROID_INTEROP_DIR"])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let androidID = try await readAndroidID(in: directory)
        let server = try await FloeDeviceLink.bind(identity: .generate(), trustedEndpointIDs: [androidID])
        let timeout = Task {
            try await Task.sleep(for: .seconds(45))
            try await server.close()
        }
        defer { timeout.cancel() }
        do {
            let address = try await relayAddress(of: server)
            try JSONEncoder().encode(address).write(
                to: directory.appendingPathComponent("mac-address.json"), options: .atomic
            )
            let connection = try await #require(server.acceptNext())
            #expect(connection.peerEndpointID == androidID)
            let request = try await connection.receiveRequest()
            let expected = Data((0..<(128 * 1024)).map { UInt8($0 % 251) })
            #expect(request.payload == expected)
            try await request.respond(request.payload)
            // The Android runner closes after confirming it received the full response.
            await #expect(throws: (any Error).self) {
                try await connection.receiveRequest()
            }
        } catch {
            try? await server.close()
            throw error
        }
        try await server.close()
    }
}

private enum ProbeError: Error {
    case relayTimedOut
    case androidPeerTimedOut
}

private func readAndroidID(in directory: URL) async throws -> String {
    let identityFile = directory.appendingPathComponent("android-peer-id")
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if let id = try? String(contentsOf: identityFile, encoding: .utf8) {
            return id.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw ProbeError.androidPeerTimedOut
}

private func withEndpoints(
    relay: FloeDeviceLinkRelay = .disabled,
    trustClient: Bool = true,
    _ operation: (FloeDeviceLink, FloeDeviceLink) async throws -> Void
) async throws {
    let clientIdentity = FloeDeviceLinkIdentity.generate()
    let serverIdentity = FloeDeviceLinkIdentity.generate()
    let bindAddress = relay == .disabled ? "127.0.0.1:0" : nil
    let server = try await FloeDeviceLink.bind(
        identity: serverIdentity,
        trustedEndpointIDs: trustClient ? [clientIdentity.endpointID] : [],
        relay: relay,
        bindAddress: bindAddress
    )
    do {
        let client = try await FloeDeviceLink.bind(
            identity: clientIdentity,
            trustedEndpointIDs: [serverIdentity.endpointID],
            relay: relay,
            bindAddress: bindAddress
        )
        do {
            try await operation(server, client)
        } catch {
            try? await client.close()
            throw error
        }
        try await client.close()
    } catch {
        try? await server.close()
        throw error
    }
    try await server.close()
}

private func loopbackAddress(of endpoint: FloeDeviceLink) throws -> FloeDeviceLinkAddress {
    let socket = try #require(endpoint.boundSockets.first { $0.hasPrefix("127.0.0.1:") })
    return FloeDeviceLinkAddress(endpointID: endpoint.address().endpointID, directAddresses: [socket])
}

private func relayAddress(of endpoint: FloeDeviceLink) async throws -> FloeDeviceLinkAddress {
    try await withThrowingTaskGroup(of: FloeDeviceLinkAddress.self) { group in
        group.addTask { try await endpoint.waitForRelayAddress() }
        group.addTask {
            try await Task.sleep(for: .seconds(25))
            throw ProbeError.relayTimedOut
        }
        defer { group.cancelAll() }
        return try await #require(group.next())
    }
}

private func connect(
    client: FloeDeviceLink,
    server: FloeDeviceLink,
    address: FloeDeviceLinkAddress
) async throws -> (FloeDeviceLinkConnection, FloeDeviceLinkConnection) {
    let acceptance = Task { try await server.acceptNext() }
    do {
        let outgoing = try await client.connect(to: address)
        let incoming = try await #require(acceptance.value)
        return (outgoing, incoming)
    } catch {
        try? await server.close()
        _ = await acceptance.result
        throw error
    }
}
