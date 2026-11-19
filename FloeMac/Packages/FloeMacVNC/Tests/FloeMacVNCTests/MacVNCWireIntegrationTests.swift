// SPDX-License-Identifier: MPL-2.0
//
// Real transport fidelity proof against a synthetic loopback RFB 3.8 peer.
// This validates RoyalVNCKit bytes end to end — handshake, framebuffer,
// pointer input, and orderly teardown — with no external network access and
// no real desktop target.

import Foundation
import Network
import RoyalVNCKit
import Testing
@testable import FloeMacVNC

/// Minimal RFB 3.8 server on 127.0.0.1 with a 64x64 raw-encoded framebuffer.
private final class RFBTestPeer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "floe.macvnc.test.rfb")
    private let lock = NSLock()
    private let listener: NWListener
    private var connection: NWConnection?
    private var buffer = Data()
    private var phase = 0
    private var color: UInt8 = 10
    private var pendingUpdate = false
    private var recorded: [(UInt8, Int, Int)] = []
    var pointers: [(UInt8, Int, Int)] { lock.withLock { recorded } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connection = connection
            connection.start(queue: self.queue)
            self.send(Data("RFB 003.008\n".utf8))
            self.receive()
        }
        listener.start(queue: queue)
        for _ in 0..<100 {
            if let port = listener.port, port.rawValue != 0 { return port.rawValue }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "RFBTestPeer", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Loopback RFB listener did not become ready"
        ])
    }

    func stop() {
        queue.async { [self] in connection?.cancel(); listener.cancel() }
    }

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.buffer.append(data); self.consume() }
            if !done && error == nil { self.receive() }
        }
    }

    private func consume() {
        while !buffer.isEmpty {
            let bytes = [UInt8](buffer)
            let length: Int
            switch phase {
            case 0: length = 12
            case 1, 2: length = 1
            default:
                switch bytes[0] {
                case 0: length = 20
                case 2:
                    guard bytes.count >= 4 else { return }
                    length = 4 + (Int(bytes[2]) * 256 + Int(bytes[3])) * 4
                case 3: length = 10
                case 4: length = 8
                case 5: length = 6
                default: connection?.cancel(); return
                }
            }
            guard bytes.count >= length else { return }
            buffer.removeFirst(length)
            if phase == 0 { phase = 1; send(Data([1, 1])); continue }
            if phase == 1 { phase = 2; send(Data([0, 0, 0, 0])); continue }
            if phase == 2 {
                phase = 3
                // 64x64, 32bpp little-endian true color, R16/G8/B0.
                var hello: [UInt8] = [0, 64, 0, 64, 32, 24, 0, 1,
                                      0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0,
                                      0, 0, 0, 4]
                hello += Array("test".utf8)
                send(Data(hello)); continue
            }
            if bytes[0] == 3 {
                pendingUpdate = true
                if bytes[1] == 0 { publishFrame() }
            } else if bytes[0] == 5 {
                let point = (bytes[1], Int(bytes[2]) * 256 + Int(bytes[3]), Int(bytes[4]) * 256 + Int(bytes[5]))
                lock.withLock { recorded.append(point) }
                color &+= 17
                if pendingUpdate { publishFrame() }
            }
        }
    }

    private func publishFrame() {
        pendingUpdate = false
        var frame = Data([0, 0, 0, 1, 0, 0, 0, 0, 0, 64, 0, 64, 0, 0, 0, 0])
        for _ in 0..<(64 * 64) { frame.append(contentsOf: [color, color, color, 0]) }
        send(frame)
    }
}

@Suite("VNC wire integration", .serialized)
@MainActor
struct MacVNCWireIntegrationTests {
    private func waitFor(
        _ predicate: () -> Bool,
        timeout: Duration = .seconds(20)
    ) async -> Bool {
        let start = ContinuousClock.now
        while !predicate() {
            if start.duration(to: .now) >= timeout { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test("Handshake, framebuffer, pointer input, and drain against synthetic RFB peer")
    func wireRoundTrip() async throws {
        let peer = try RFBTestPeer()
        let port = try await peer.start()
        defer { peer.stop() }

        let owner = MacVNCSessionOwner()
        try owner.connect(using: MacVNCConfiguration(host: "127.0.0.1", port: Int(port)))

        let ready = await waitFor { owner.isConnected && owner.displaySurface != nil }
        #expect(ready, "RFB handshake must complete against the loopback peer")
        let surface = try #require(owner.displaySurface)
        #expect(surface.framebuffer.size.cgSize == CGSize(width: 64, height: 64))

        // Pointer input travels through RoyalVNCKit's real send path and is
        // observed as wire bytes at the peer; the peer answers the pending
        // update request with a fresh frame.
        surface.connection.mouseMove(x: 20, y: 30)
        surface.connection.mouseButtonDown(.left, x: 20, y: 30)
        surface.connection.mouseButtonUp(.left, x: 20, y: 30)
        let sawClick = await waitFor {
            peer.pointers.contains { $0.0 == 1 && $0.1 == 20 && $0.2 == 30 }
        }
        #expect(sawClick, "peer must observe the press at the requested coordinates")
        let released = await waitFor { peer.pointers.last?.0 == 0 }
        #expect(released, "peer must observe the release so the button is never left down")

        // The delivered framebuffer must be renderable through the macOS
        // NSImage path the embedded surface relies on.
        let rendered = await waitFor { surface.framebuffer.nsImage != nil }
        #expect(rendered, "macOS rendering surface must expose an NSImage once frames flow")

        // Bind the real embedded view exactly as MacVNCRemoteSurface does and
        // confirm it takes over rendering/input while forwarding state and
        // credential callbacks to the session.
        let frameworkView = VNCCAFramebufferView(
            frame: NSRect(x: 0, y: 0, width: 128, height: 128),
            framebuffer: surface.framebuffer,
            connection: surface.connection,
            connectionDelegate: surface.session
        )
        #expect(frameworkView.connection === surface.connection)
        #expect(frameworkView.delegate === surface.session)
        #expect(surface.connection.delegate === frameworkView)

        owner.close()
        #expect(owner.state == .closing)
        let closed = await waitFor { owner.state == .closed }
        #expect(closed)
        let didSettle = await owner.drain()
        #expect(didSettle, "drain must confirm the real disconnect, not time out")
    }

    @Test("Frame ticks advance while the peer keeps pushing updates")
    func frameTicksAdvance() async throws {
        let peer = try RFBTestPeer()
        let port = try await peer.start()
        defer { peer.stop() }

        let owner = MacVNCSessionOwner()
        try owner.connect(using: MacVNCConfiguration(host: "127.0.0.1", port: Int(port)))
        let ready = await waitFor { owner.isConnected && owner.displaySurface != nil }
        #expect(ready)

        // Request a full update; the peer publishes a frame on pointer input.
        let surface = try #require(owner.displaySurface)
        surface.connection.mouseMove(x: 1, y: 1)
        let ticked = await waitFor { owner.framesPerSecond > 0 }
        #expect(ticked, "frame callbacks must feed the owner FPS counter")
        async let firstDrain = owner.drain()
        async let secondDrain = owner.drain()
        let results = await [firstDrain, secondDrain]
        #expect(results == [true, true])
        #expect(surface.session.hasTerminated)
        #expect(!owner.canConnect)
    }

    @Test("Password credential is supplied in memory for password auth only")
    func passwordCredentialFlow() throws {
        let config = try MacVNCConfiguration(host: "10.0.0.2", password: "s3cret").validated()
        let session = MacVNCSession(configuration: config)
        var credential: (any VNCCredential)?
        session.connection(session.connection, credentialFor: .vnc) { credential = $0 }
        #expect((credential as? VNCPasswordCredential)?.password == "s3cret")

        let noPassword = try MacVNCConfiguration(host: "10.0.0.2").validated()
        let passwordless = MacVNCSession(configuration: noPassword)
        var missing: (any VNCCredential)?
        passwordless.connection(passwordless.connection, credentialFor: .vnc) { missing = $0 }
        #expect(missing == nil, "no credential may be invented when none is configured")
    }
}
