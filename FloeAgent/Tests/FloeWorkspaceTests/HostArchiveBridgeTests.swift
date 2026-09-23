// FloeWorkspaceTests — optional guest → host archive bridge (host side).
//
// The bridge is the host half of `floe-host archive …`: capability
// negotiation, environment/token binding, shared-directory containment and
// bounded control messages. These tests use a real temporary share directory
// and the real archive engine.

import Foundation
import Testing
@testable import FloeWorkspace
import FloeCore
import FloeTools

@Suite("FloeWorkspace.HostArchiveBridge")
struct HostArchiveBridgeTests {

    private struct Mapping: HostArchivePathMapping {
        let guestRoot: String
        let hostRoot: URL

        func hostURL(forGuestPath path: String) -> URL? {
            guard path == guestRoot || path.hasPrefix(guestRoot + "/") else { return nil }
            let relative = path == guestRoot ? "" : String(path.dropFirst(guestRoot.count + 1))
            guard !relative.split(separator: "/").contains("..") else { return nil }
            return hostRoot.appendingPathComponent(relative)
        }

        func guestPath(forHostPath path: String) -> String? {
            let host = hostRoot.standardizedFileURL.path
            guard path == host || path.hasPrefix(host + "/") else { return nil }
            return guestRoot + String(path.dropFirst(host.count))
        }
    }

    private final class Fixture: @unchecked Sendable {
        let root: URL
        let mapping: Mapping

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-host-archive-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            mapping = Mapping(guestRoot: "/workspace", hostRoot: root)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func write(_ relative: String, _ content: String) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        func bridge(
            token: String = "tok-1",
            capabilities: Set<HostArchiveCapability> = Set(HostArchiveCapability.allCases)
        ) -> HostArchiveBridge {
            HostArchiveBridge(environmentID: "env-1", token: token, capabilities: capabilities, mapping: mapping)
        }

        func guestURL(_ guestPath: String) -> URL {
            mapping.hostURL(forGuestPath: guestPath)!
        }
    }

    // MARK: protocol

    @Test("Control messages round-trip and stay bounded and small")
    func protocolRoundTrip() throws {
        let request = HostArchiveRequest(action: .create, format: "tgz", source: "/workspace/中文 目录", destination: "/workspace/包.tar.gz")
        let encoded = HostArchiveProtocol.encode(request, token: "tok-9")
        #expect(encoded.utf8.count <= HostArchiveProtocol.maxPayloadBytes)
        #expect(!encoded.contains("\n"))
        let decoded = try HostArchiveProtocol.decode(encoded)
        #expect(decoded.token == "tok-9")
        #expect(decoded.request == request)

        let listing = HostArchiveRequest(action: .list, format: "tar", source: "/workspace/a.tar", destination: nil)
        let listingDecoded = try HostArchiveProtocol.decode(HostArchiveProtocol.encode(listing, token: "t"))
        #expect(listingDecoded.request.destination == nil)
    }

    @Test("Malformed and oversized control messages are refused")
    func protocolRejections() {
        #expect(throws: HostArchiveBridgeError.self) {
            _ = try HostArchiveProtocol.decode("action=create")
        }
        #expect(throws: HostArchiveBridgeError.self) {
            _ = try HostArchiveProtocol.decode("v1 token=t action=frobnicate format=zip source=/workspace/a")
        }
        #expect(throws: HostArchiveBridgeError.self) {
            _ = try HostArchiveProtocol.decode("v1 token=t action=create format=zip")
        }
        #expect(throws: HostArchiveBridgeError.self) {
            _ = try HostArchiveProtocol.decode("v1 token=" + String(repeating: "x", count: 4096) + " action=list format=zip source=/a")
        }
    }

    // MARK: authorization

    @Test("Requests from another token or environment are refused before any work")
    func authorization() async throws {
        let f = try Fixture()
        try f.write("notes.txt", "hello")
        let bridge = f.bridge(token: "tok-1", capabilities: [.create, .list])
        let otherToken = HostArchiveProtocol.encode(
            HostArchiveRequest(action: .create, format: "zip", source: "/workspace/notes.txt", destination: "/workspace/out.zip"),
            token: "tok-2"
        )
        let reply = await bridge.handle(otherToken)
        #expect(reply.contains("status=error"))
        #expect(reply.contains("token-mismatch"))
        #expect(!FileManager.default.fileExists(atPath: f.guestURL("/workspace/out.zip").path))

        // Another environment's bridge has its own token and cannot serve this
        // environment's connection.
        let other = HostArchiveBridge(environmentID: "env-2", token: "tok-3", capabilities: [.create], mapping: f.mapping)
        let reply2 = await other.handle(otherToken)
        #expect(reply2.contains("status=error"))
        #expect(reply2.contains("token-mismatch"))
        #expect(!FileManager.default.fileExists(atPath: f.guestURL("/workspace/out.zip").path))
    }

    @Test("An action that was not negotiated is refused; paths outside the share never reach the engine")
    func capabilityAndContainment() async throws {
        let f = try Fixture()
        try f.write("notes.txt", "hello")
        let bridge = f.bridge(capabilities: [.create])
        let extract = HostArchiveProtocol.encode(
            HostArchiveRequest(action: .extract, format: "zip", source: "/workspace/a.zip", destination: "/workspace/out"),
            token: "tok-1"
        )
        let reply = await bridge.handle(extract)
        #expect(reply.contains("status=error"))
        #expect(reply.contains("unsupported-action"))

        let outside = HostArchiveProtocol.encode(
            HostArchiveRequest(action: .create, format: "zip", source: "/etc/passwd", destination: "/workspace/out.zip"),
            token: "tok-1"
        )
        let refused = await bridge.handle(outside)
        #expect(refused.contains("status=error"))
        #expect(refused.contains("path-outside-share"))

        let traversal = HostArchiveProtocol.encode(
            HostArchiveRequest(action: .create, format: "zip", source: "/workspace/../etc/passwd", destination: "/workspace/out.zip"),
            token: "tok-1"
        )
        let refused2 = await bridge.handle(traversal)
        #expect(refused2.contains("status=error"))
        #expect(refused2.contains("path-outside-share"), "reply was: \(refused2)")
    }

    // MARK: operations

    @Test("create, list, extract and decompress run on the shared directory")
    func operations() async throws {
        let f = try Fixture()
        try f.write("src/a.txt", "alpha")
        try f.write("src/nested/b.txt", "beta")
        let bridge = f.bridge()

        let create = await bridge.handle(HostArchiveProtocol.encode(
            HostArchiveRequest(action: .create, format: "tgz", source: "/workspace/src", destination: "/workspace/src.tar.gz"),
            token: "tok-1"
        ))
        #expect(create.contains("status=ok"), "create reply was: \(create)")
        #expect(create.contains("action=create"))
        #expect(create.contains("entries=2"))
        #expect(create.contains("path=/workspace/src.tar.gz"))
        #expect(FileManager.default.fileExists(atPath: f.guestURL("/workspace/src.tar.gz").path))
        // The reply carries no file bytes: it stays far below the payload cap.
        #expect(create.utf8.count < 512)

        let list = await bridge.handle(HostArchiveProtocol.encode(
            HostArchiveRequest(action: .list, format: "tgz", source: "/workspace/src.tar.gz"),
            token: "tok-1"
        ))
        #expect(list.contains("status=ok"))
        #expect(list.contains("action=list"))
        // Two files plus the two directory records the tar carries.
        #expect(list.contains("entries=4"), "list reply was: \(list)")
        // The listing is written into the share; only its path crosses the wire.
        guard let listingPath = list.split(separator: " ").first(where: { $0.hasPrefix("path=") })?.dropFirst(5) else {
            Issue.record("listing reply has no path: \(list)")
            return
        }
        let listingURL = try #require(f.mapping.hostURL(forGuestPath: String(listingPath)))
        let listingText = try String(contentsOf: listingURL, encoding: .utf8)
        #expect(listingText.contains("src/a.txt"))
        #expect(listingText.contains("src/nested/b.txt"))
        #expect(list.utf8.count < 512)

        let extract = await bridge.handle(HostArchiveProtocol.encode(
            HostArchiveRequest(action: .extract, format: "tgz", source: "/workspace/src.tar.gz", destination: "/workspace/unpacked"),
            token: "tok-1"
        ))
        #expect(extract.contains("status=ok"), "extract reply was: \(extract)")
        #expect(extract.contains("entries=2"))
        #expect(try String(contentsOf: f.guestURL("/workspace/unpacked/src/nested/b.txt"), encoding: .utf8) == "beta")

        // A second extract into the same destination is refused, not overwritten.
        let again = await bridge.handle(HostArchiveProtocol.encode(
            HostArchiveRequest(action: .extract, format: "tgz", source: "/workspace/src.tar.gz", destination: "/workspace/unpacked"),
            token: "tok-1"
        ))
        #expect(again.contains("status=error"))
        #expect(again.contains("already exists"))

        let decompress = await bridge.handle(HostArchiveProtocol.encode(
            HostArchiveRequest(action: .decompress, format: "gz", source: "/workspace/src/a.txt.gz", destination: "/workspace/a.txt"),
            token: "tok-1"
        ))
        // No gzip source exists yet: the failure is reported as a small structured error.
        #expect(decompress.contains("status=error"))
    }

    @Test("A successful decompress writes the file into the share")
    func decompressOperation() async throws {
        let f = try Fixture()
        try f.write("blob.txt", String(repeating: "payload ", count: 32))
        _ = try ArchiveEngine.create(
            format: "gz",
            sources: [f.guestURL("/workspace/blob.txt")],
            destination: f.guestURL("/workspace/blob.txt.gz"),
            cancellation: CancellationToken()
        )
        let bridge = f.bridge()
        let reply = await bridge.handle(HostArchiveProtocol.encode(
            HostArchiveRequest(action: .decompress, format: "gz", source: "/workspace/blob.txt.gz", destination: "/workspace/blob-restored.txt"),
            token: "tok-1"
        ))
        #expect(reply.contains("status=ok"), "reply was: \(reply)")
        #expect(reply.contains("entries=1"))
        #expect(try String(contentsOf: f.guestURL("/workspace/blob-restored.txt"), encoding: .utf8) == String(repeating: "payload ", count: 32))
    }

    @Test("Concurrent requests for one environment serialize without a pool dependency")
    func concurrentSerialization() async throws {
        let f = try Fixture()
        try f.write("src/one.txt", "one")
        let bridge = f.bridge()
        async let first = bridge.handle(HostArchiveProtocol.encode(
            HostArchiveRequest(action: .create, format: "zip", source: "/workspace/src", destination: "/workspace/one.zip"),
            token: "tok-1"
        ))
        async let second = bridge.handle(HostArchiveProtocol.encode(
            HostArchiveRequest(action: .create, format: "tar", source: "/workspace/src", destination: "/workspace/two.tar"),
            token: "tok-1"
        ))
        let replies = await [first, second]
        #expect(replies.allSatisfy { $0.contains("status=ok") })
        #expect(FileManager.default.fileExists(atPath: f.guestURL("/workspace/one.zip").path))
        #expect(FileManager.default.fileExists(atPath: f.guestURL("/workspace/two.tar").path))
    }

    @Test("Advertised capability rendering is canonical")
    func capabilityRendering() {
        #expect(HostArchiveCapability.wireValue([.decompress, .create]) == "create,decompress")
        #expect(HostArchiveCapability.parse("create,extract") == [.create, .extract])
        #expect(HostArchiveCapability.parse("archive") == Set(HostArchiveCapability.allCases))
        #expect(HostArchiveCapability.parse("bogus") == [])
    }
}
