#if os(macOS)
import Foundation
import Testing
import CryptoKit
import Darwin
import FloeMacBridgeProtocol
@testable import FloeMacBridgeApp

@Suite("Mac bridge absolute file reads", .serialized)
struct BridgeAbsoluteFileReadTests {
    private struct Fixture {
        let service: BridgeService
        let server: Curve25519.Signing.PrivateKey
        let client: Curve25519.Signing.PrivateKey

        func call(_ method: String, _ payload: [String: BridgeValue]) async throws -> [String: BridgeValue] {
            let request = try BridgeRequest(body: BridgeRequestBody(
                clientKey: client.publicKey.rawRepresentation,
                method: method, payload: payload), key: client)
            let delivery = try await service.respondForDelivery(request)
            defer { service.finishDelivery(delivery.lease) }
            return try BridgeWire.decode(BridgeResponse.self, from: delivery.data)
                .verified(for: request.body, pinnedKey: server.publicKey.rawRepresentation)
        }

        func read(path: String, offset: Int64 = 0, limit: Int64 = 65_536,
                  expectedIdentity: String? = nil,
                  sha256: Bool = false) async throws -> [String: BridgeValue] {
            var payload: [String: BridgeValue] = [
                "path": .string(path), "offset": .integer(offset), "limit": .integer(limit),
            ]
            if let expectedIdentity { payload["expectedIdentity"] = .string(expectedIdentity) }
            if sha256 { payload["sha256"] = .bool(true) }
            return try await call("file.readAbsolute", payload)
        }
    }

    private func makeRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-bridge-abs-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFixture() async throws -> (Fixture, URL) {
        let home = try makeRoot("home")
        let server = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x71, count: 32))
        let client = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x72, count: 32))
        let service = try BridgeService(paths: BridgePaths(home: home), signingKey: server)
        let fixture = Fixture(service: service, server: server, client: client)
        let nonce = String(repeating: "a", count: 64)
        _ = try await fixture.call("pair", ["name": .string("Fixture"), "nonce": .string(nonce)])
        let verification = BridgeWire.pairingVerification(
            clientKey: client.publicKey.rawRepresentation,
            serverKey: server.publicKey.rawRepresentation, nonce: nonce)
        try await service.approve(BridgeWire.digest(client.publicKey.rawRepresentation),
                                  verification: verification, allow: true)
        return (fixture, home)
    }

    private func bytes(_ payload: [String: BridgeValue]) throws -> Data {
        try #require(payload["data"]?.string.flatMap { Data(base64Encoded: $0) })
    }

    private func expectRemote(
        containingAny fragments: [String], _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            Issue.record("Expected a remote error containing one of \(fragments)")
        } catch {
            let description = error.localizedDescription
            #expect(fragments.contains(where: { description.contains($0) }),
                    "Unexpected error: \(description)")
        }
    }

    private func expectRemote(
        contains text: String, _ body: () async throws -> Void
    ) async {
        await expectRemote(containingAny: [text], body)
    }

    @Test("Authenticated ping advertises the additive absolute-read capability")
    func capabilityIsAdvertised() async throws {
        let (fixture, home) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let ping = try await fixture.call("ping", [:])
        let capabilities = ping["capabilities"]?.array?.compactMap(\.string) ?? []
        #expect(capabilities.contains(BridgeAbsoluteFileRead.capability))
    }

    @Test("Absolute reads cross workspaces with Unicode and spaces")
    func crossWorkspaceUnicodeRead() async throws {
        let (fixture, home) = try await makeFixture()
        let other = try makeRoot("other-workspace")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: other)
        }
        let file = other.appendingPathComponent("报告 最终-é.txt")
        let content = Data("第一行\nsecond line\n\u{1F600}".utf8)
        try content.write(to: file)

        let page = try await fixture.read(path: file.path, offset: 0, limit: 4)
        #expect(try bytes(page) == content.prefix(4))
        #expect(page["offset"] == .integer(4))
        #expect(page["totalBytes"] == .integer(Int64(content.count)))
        let identity = try #require(page["identity"]?.string)
        #expect(identity.count == 64)

        let next = try await fixture.read(path: file.path, offset: 4, limit: 1_024,
                                          expectedIdentity: identity)
        let assembled = try bytes(page) + bytes(next)
        #expect(assembled == content)
        #expect(next["offset"] == .integer(Int64(content.count)))
    }

    @Test("Binary files transfer in bounded chunks with a verified whole-file receipt")
    func boundedBinaryTransferWithReceipt() async throws {
        let (fixture, home) = try await makeFixture()
        let other = try makeRoot("binary")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: other)
        }
        var data = Data(count: 2_500_003)
        var state: UInt64 = 0x1234_5678_9abc_def0
        for index in data.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            data[index] = UInt8(truncatingIfNeeded: state >> 33)
        }
        let file = other.appendingPathComponent("不可见 二进制.bin")
        try data.write(to: file)

        var assembled = Data()
        var identity: String?
        while assembled.count < data.count {
            let page = try await fixture.read(
                path: file.path, offset: Int64(assembled.count), limit: 16_384,
                expectedIdentity: identity)
            if identity == nil { identity = try #require(page["identity"]?.string) }
            #expect(page["identity"]?.string == identity)
            assembled.append(try bytes(page))
        }
        #expect(assembled == data)

        let receipt = try await fixture.read(
            path: file.path, offset: Int64(assembled.count), limit: 1,
            expectedIdentity: identity, sha256: true)
        #expect(try bytes(receipt).isEmpty)
        #expect(receipt["sha256"]?.string == BridgeWire.digest(data))
        #expect(receipt["totalBytes"] == .integer(Int64(data.count)))
    }

    @Test("Missing, directory, FIFO and relative paths are rejected honestly")
    func nonRegularAndMissingPaths() async throws {
        let (fixture, home) = try await makeFixture()
        let other = try makeRoot("nonregular")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: other)
        }
        let missing = other.appendingPathComponent("does-not-exist.txt").path
        await expectRemote(contains: "No such file or directory") {
            _ = try await fixture.read(path: missing, limit: 64)
        }
        await expectRemote(contains: "Only regular files") {
            _ = try await fixture.read(path: other.path, limit: 64)
        }
        let fifo = other.appendingPathComponent("pipe").path
        #expect(mkfifo(fifo, 0o600) == 0)
        await expectRemote(contains: "Only regular files") {
            _ = try await fixture.read(path: fifo, limit: 64)
        }
        await expectRemote(contains: "outside the selected workspace") {
            _ = try await fixture.read(path: "relative/file.txt", limit: 64)
        }
    }

    @Test("A canonical target inside secret material is denied through an innocent link")
    func secretTargetIsDenied() async throws {
        let (fixture, home) = try await makeFixture()
        let other = try makeRoot("secret")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: other)
        }
        let secretDirectory = other.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: secretDirectory, withIntermediateDirectories: true)
        let secret = secretDirectory.appendingPathComponent("id_ed25519")
        try Data("synthetic-not-a-real-key".utf8).write(to: secret)
        let innocent = other.appendingPathComponent("family-photo.png")
        try FileManager.default.createSymbolicLink(at: innocent, withDestinationURL: secret)

        await expectRemote(containingAny: ["protected credential", "受保护的凭据文件"]) {
            _ = try await fixture.read(path: innocent.path, limit: 64)
        }
        await expectRemote(containingAny: ["protected credential", "受保护的凭据文件"]) {
            _ = try await fixture.read(path: secret.path, limit: 64)
        }
    }

    @Test("Same-size rewrite with restored mtime changes identity through ctime")
    func rewriteWithRestoredMtimeIsDetected() async throws {
        let (fixture, home) = try await makeFixture()
        let other = try makeRoot("changed")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: other)
        }
        let file = other.appendingPathComponent("versioned.txt")
        try Data(repeating: 0x41, count: 4_096).write(to: file)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let first = try await fixture.read(path: file.path, offset: 0, limit: 1_024)
        let identity = try #require(first["identity"]?.string)

        try await Task.sleep(for: .milliseconds(30))
        try Data(repeating: 0x42, count: 4_096).write(to: file)
        if let created = originalAttributes[.creationDate] as? Date,
           let modified = originalAttributes[.modificationDate] as? Date {
            try FileManager.default.setAttributes(
                [.creationDate: created, .modificationDate: modified], ofItemAtPath: file.path)
        }
        await expectRemote(contains: "changed during the read") {
            _ = try await fixture.read(path: file.path, offset: 1_024, limit: 1_024,
                                       expectedIdentity: identity)
        }
    }

    @Test("A truncated file cannot be returned as the same version")
    func truncationIsDetected() async throws {
        let (fixture, home) = try await makeFixture()
        let other = try makeRoot("truncate")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: other)
        }
        let file = other.appendingPathComponent("large.bin")
        try Data(repeating: 0x43, count: 8_192).write(to: file)
        let first = try await fixture.read(path: file.path, offset: 0, limit: 1_024)
        let identity = try #require(first["identity"]?.string)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 16)
        try handle.close()
        await expectRemote(contains: "changed during the read") {
            _ = try await fixture.read(path: file.path, offset: 2_048, limit: 1_024,
                                       expectedIdentity: identity)
        }
    }

    @Test("An invalid UTF-8 symlink target is rejected without unbounded decoding")
    func invalidSymlinkTargetIsRejected() async throws {
        let (fixture, home) = try await makeFixture()
        let other = try makeRoot("symlink")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: other)
        }
        let link = other.appendingPathComponent("bad-link").path
        let targetBytes: [CChar] = [0x2F, 0x2F, CChar(bitPattern: 0xFF), 0]
        let result = targetBytes.withUnsafeBufferPointer { buffer in
            link.withCString { symlink(buffer.baseAddress!, $0) }
        }
        #expect(result == 0)
        await expectRemote(contains: "not a valid path") {
            _ = try await fixture.read(path: link, limit: 64)
        }
    }

    @Test("Absolute and firmlink spellings address the same owned fixture")
    func systemVolumeDataAlias() async throws {
        let (fixture, home) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/CodexBuild/Floe/mac-absolute-read-20261112/fixtures",
                                    isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let file = cache.appendingPathComponent("别名 fixture 图片.png")
        let content = Data("alias fixture bytes".utf8)
        try content.write(to: file)

        let alias = URL(fileURLWithPath: "/System/Volumes/Data" + file.path)
        guard FileManager.default.fileExists(atPath: alias.path) else {
            Issue.record("The /System/Volumes/Data alias is unavailable on this Mac")
            return
        }
        let direct = try await fixture.read(path: file.path, limit: 64)
        let throughAlias = try await fixture.read(path: alias.path, limit: 64)
        #expect(try bytes(direct) == content)
        #expect(try bytes(throughAlias) == content)
        #expect(direct["identity"]?.string == throughAlias["identity"]?.string)
    }

    @Test("The /tmp spelling of an ordinary file is resolved to its canonical target")
    func temporaryDirectoryAlias() async throws {
        let (fixture, home) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = URL(fileURLWithPath: "/tmp/floe-abs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("转存.txt")
        try Data("tmp alias".utf8).write(to: file)
        let page = try await fixture.read(path: file.path, limit: 64)
        #expect(try bytes(page) == Data("tmp alias".utf8))
    }

    @Test("Offsets, limits and expected identity are validated before bytes")
    func requestBoundsAreValidated() async throws {
        let (fixture, home) = try await makeFixture()
        let other = try makeRoot("bounds")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: other)
        }
        let file = other.appendingPathComponent("small.txt")
        try Data("0123456789".utf8).write(to: file)
        await expectRemote(contains: "outside the selected workspace") {
            _ = try await fixture.read(path: file.path, offset: -1, limit: 64)
        }
        await expectRemote(contains: "outside the selected workspace") {
            _ = try await fixture.read(path: file.path, offset: 0,
                                       limit: Int64(BridgeAbsoluteFileRead.maximumChunkBytes + 1))
        }
        await expectRemote(containingAny: ["incomplete or invalid", "不完整或无效"]) {
            _ = try await fixture.read(path: file.path, offset: 0, limit: 64,
                                       expectedIdentity: "not-a-digest")
        }
        await expectRemote(contains: "beyond the end") {
            _ = try await fixture.read(path: file.path, offset: 11, limit: 64)
        }
    }

    @Test("Empty files have a valid empty page and whole-file receipt")
    func emptyFile() async throws {
        let (fixture, home) = try await makeFixture()
        let other = try makeRoot("empty")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: other)
        }
        let file = other.appendingPathComponent("empty.txt")
        try Data().write(to: file)
        let page = try await fixture.read(path: file.path, limit: 64)
        #expect(try bytes(page).isEmpty)
        #expect(page["offset"] == .integer(0))
        #expect(page["totalBytes"] == .integer(0))
        let receipt = try await fixture.read(path: file.path, offset: 0, limit: 1,
                                             expectedIdentity: page["identity"]?.string,
                                             sha256: true)
        #expect(receipt["sha256"]?.string == BridgeWire.digest(Data()))
    }
}
#endif
