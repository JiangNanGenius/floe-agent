#if canImport(Network) && canImport(CoreGraphics)
import Foundation
import Network
import Testing
import FloeCore
import FloeTools
@testable import FloeVNC

/// Real loopback RFB 3.8 peer. This validates bytes sent through RoyalVNCKit,
/// not a mocked successful tool result or an external desktop acceptance.
private final class RFBTestPeer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "floe.test.rfb")
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
        throw FloeError.validationFailed("Loopback RFB listener did not become ready")
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
                // 64x64, 32bpp little endian true color, R16/G8/B0.
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

@Suite("VNC wire and post-action integration", .serialized)
struct VNCWireIntegrationTests {
    @Test("Click sends press/release and returns reusable observation without another observe")
    func clickEvidence() async throws {
        let peer = try RFBTestPeer()
        let port = try await peer.start()
        defer { peer.stop() }
        let session = VNCSession(host: "127.0.0.1", port: port, password: nil)
        session.connect()
        defer { session.disconnect() }
        for _ in 0..<150 {
            if session.isConnected, (try? session.captureJPEG()) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(session.isConnected, "RFB handshake must finish before exercising input")
        let handle = VNCSessionHandle(id: UUID(), session: session)
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        let observation = try await VNCObserveTool(sessionProvider: { handle }).execute(.init(), context: context)
        let first = try #require(JSONSerialization.jsonObject(with: Data(observation.summary.utf8)) as? [String: Any])
        let hash = try #require(first["screenshotSHA256"] as? String)
        let click = VNCClickTool(sessionProvider: { handle })
        let result = try await click.execute(.init(x: 20, y: 30, screenshotSHA256: hash), context: context)
        let json = try #require(JSONSerialization.jsonObject(with: Data(result.summary.utf8)) as? [String: Any])
        #expect(json["coordinateSpace"] as? String == "framebufferPixels")
        #expect(json["pixelWidth"] as? Int == 64)
        #expect(json["elements"] is [[String: Any]])
        #expect(json["serverAcknowledged"] as? Bool == false)
        #expect(json["evidenceStatus"] as? String == "current")
        #expect(result.artifacts.count == 1)
        #expect(peer.pointers.contains { event in event.0 == 1 && event.1 == 20 && event.2 == 30 })
        #expect(peer.pointers.last?.0 == 0)
        let nextHash = try #require(json["screenshotSHA256"] as? String)
        #expect(session.currentStructuredEvidence?.screenshotSHA256 == nextHash)
        let second = try await click.execute(.init(x: 21, y: 31, screenshotSHA256: nextHash), context: context)
        #expect(peer.pointers.contains { event in event.0 == 1 && event.1 == 21 && event.2 == 31 })
        let secondJSON = try #require(JSONSerialization.jsonObject(with: Data(second.summary.utf8)) as? [String: Any])
        let dragHash = try #require(secondJSON["screenshotSHA256"] as? String)
        let drag = VNCDragTool(sessionProvider: { handle })
        let dragged = try await drag.execute(.init(fromX: 21, fromY: 31, toX: 40, toY: 50,
                                                   screenshotSHA256: dragHash, durationMilliseconds: 100), context: context)
        #expect(dragged.artifacts.count == 1)
        #expect(peer.pointers.contains { $0.0 == 1 && $0.1 == 40 && $0.2 == 50 })
        #expect(peer.pointers.last?.0 == 0)
        let draggedJSON = try #require(JSONSerialization.jsonObject(with: Data(dragged.summary.utf8)) as? [String: Any])
        let cancelHash = try #require(draggedJSON["screenshotSHA256"] as? String)
        let cancellation = CancellationToken()
        let cancelledContext = ToolContext(runID: context.runID, cancellation: cancellation)
        let countBefore = peer.pointers.count
        let cancelledDrag = Task {
            try await drag.execute(.init(fromX: 40, fromY: 50, toX: 5, toY: 5,
                                          screenshotSHA256: cancelHash, durationMilliseconds: 3000), context: cancelledContext)
        }
        for _ in 0..<50 {
            if peer.pointers.count > countBefore + 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        cancellation.cancel()
        let interrupted = try await cancelledDrag.value
        #expect(interrupted.summary.contains("partialSuccess"))
        #expect(interrupted.summary.contains("\"retryInput\":false"))
        for _ in 0..<50 {
            if peer.pointers.last?.0 == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(peer.pointers.last?.0 == 0, "Cancelled drag must release the button on the wire")
    }
}
#endif
