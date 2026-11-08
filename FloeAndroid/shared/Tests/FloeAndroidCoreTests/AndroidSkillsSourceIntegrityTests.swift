// SPDX-License-Identifier: MPL-2.0
#if canImport(Darwin)
import XCTest
import Foundation
import Crypto
@testable import FloeAndroidCore
import FloeSkills
import FloeGit
import FloeAndroidWebTools

final class AndroidSkillsSourceIntegrityTests: XCTestCase, @unchecked Sendable {
    private let pin = String(repeating: "a", count: 40)

    private func http() -> HTTPRequestService {
        HTTPRequestService(configuration: .ephemeral, allowsPrivateNetwork: true)
    }

    private func base(_ server: ScriptedLoopbackFixture) -> URL {
        URL(string: "http://127.0.0.1:\(server.port)")!
    }

    private func hubTemps() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("floe-hub-") })
    }

    func testAnonymousResourceDownloadKeepsBinaryBytesAboveTheTextClamp() async throws {
        let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
        let server = try ScriptedLoopbackFixture()
        server.register(path: "/asset") { connection in
            connection.sendHead(status: 200, headers: ["content-length": "\(bytes.count)"])
            connection.sendRaw(bytes)
        }
        server.start()
        defer { server.stop() }
        let source = try GitHubSkillSource(owner: "octo-org", repository: "community",
                                           ref: "main", path: "inventory.json")
        let limit = WebToolsSkillsRemoteTransport.communityMaximumBytes(source: source, path: "assets/image.png")
        XCTAssertEqual(limit, 2_097_152)
        XCTAssertEqual(WebToolsSkillsRemoteTransport.communityMaximumBytes(source: source, path: source.path), 262_144)
        let transport = WebToolsSkillsRemoteTransport(http: http())
        let got = try await transport.downloadBounded(url: base(server).appendingPathComponent("asset"), maxBytes: limit)
        XCTAssertEqual(got, bytes)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertNil(server.requests.first?.headers["authorization"])
        XCTAssertNil(server.requests.first?.headers["cookie"])
    }

    func testOversizedAnonymousDownloadDiscardsItsScratch() async throws {
        let before = try hubTemps()
        let bytes = Data(repeating: 0x41, count: 2_097_153)
        let server = try ScriptedLoopbackFixture()
        server.register(path: "/asset") { connection in
            connection.sendHead(status: 200, headers: ["content-length": "\(bytes.count)"])
            connection.sendRaw(bytes)
        }
        server.start()
        defer { server.stop() }
        do {
            _ = try await WebToolsSkillsRemoteTransport(http: http()).downloadBounded(
                url: base(server).appendingPathComponent("asset"), maxBytes: 2_097_152)
            XCTFail("an oversized resource must not become usable bytes")
        } catch HTTPRequestError.responseTooLarge(2_097_152) {}
        XCTAssertTrue(try hubTemps().subtracting(before).isEmpty)
    }

    func testAnonymousDownloadCancellationStopsTheRequestAndCleansScratch() async throws {
        let before = try hubTemps()
        let server = try ScriptedLoopbackFixture()
        server.register(path: "/slow") { connection in
            connection.sendHead(status: 200, headers: ["transfer-encoding": "chunked"])
            for _ in 0..<64 {
                connection.sendChunk(Data(repeating: 0x42, count: 32_768))
                if connection.fixture.sawClientAbort(for: connection.request.path) { return }
                ScriptedLoopbackFixture.sleep(25)
            }
            connection.finishChunked()
        }
        server.start()
        defer { server.stop() }
        let transport = WebToolsSkillsRemoteTransport(http: http())
        let url = base(server).appendingPathComponent("slow")
        let task = Task { try await transport.downloadBounded(url: url, maxBytes: 2_097_152) }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled work must not deliver a completed resource")
        } catch is CancellationError {}
        for _ in 0..<100 where !server.sawClientAbort(for: "/slow") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(server.sawClientAbort(for: "/slow"))
        XCTAssertTrue(try hubTemps().subtracting(before).isEmpty)
    }

    private struct AnonymousCommit: SkillsRemoteTransport {
        let pin: String
        func resolveCommit(_ source: GitHubSkillSource) async throws -> String { pin }
        func fetch(_ source: GitHubSkillSource, commit: String, path: String) async throws -> Data {
            throw SkillsDomainRefusal.transportUnavailable
        }
        func fetchFinderEnvelope(url: URL) async throws -> Data {
            throw SkillsDomainRefusal.transportUnavailable
        }
    }

    private func blobSHA(_ bytes: Data) -> String {
        var value = Insecure.SHA1()
        value.update(data: Data("blob \(bytes.count)\0".utf8))
        value.update(data: bytes)
        return value.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func testRootDirectoryListingUsesPinnedAPIWithoutAToken() async throws {
        let server = try ScriptedLoopbackFixture()
        server.register(path: "/repos/octo-org/community/contents?ref=\(pin)") { connection in
            connection.sendHead(status: 200, headers: ["content-length": "2"])
            connection.sendRaw(Data("[]".utf8))
        }
        server.start()
        defer { server.stop() }
        let source = try GitHubSkillSource(owner: "octo-org", repository: "community", ref: "main", path: "SKILL.md")
        let transport = WebToolsSkillsConnectorTransport(http: http(), credentials: GitHubCredentialStore(),
            anonymousTransport: AnonymousCommit(pin: pin), apiBase: base(server))
        let listing = try await transport.fetch(source, commit: pin, path: "")
        XCTAssertEqual(listing, Data("[]".utf8))
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertNil(server.requests.first?.headers["authorization"])
    }

    private func directoryFixture(tamper: Bool = false, symlink: Bool = false, includeManifest: Bool = true,
                                  supplementalFiles: [String: Data] = [:])
        throws -> (ScriptedLoopbackFixture, [String: Data]) {
        let server = try ScriptedLoopbackFixture()
        let manifest = SkillManifest(id: "directory-fixture", version: "2.0.0",
                                     capabilities: [SkillCapability.remoteExecution.rawValue],
                                     tools: ["exec.shell"], platforms: [SkillPlatform.android.rawValue],
                                     scriptRuntime: .remote)
        var files: [String: Data] = [
            "SKILL.md": Data("---\nname: directory-fixture\ndescription: Directory fixture\n---\nUse the task environment.\n".utf8),
            "scripts/run.sh": Data("#!/bin/sh\nprintf directory-fixture\n".utf8),
            "assets/image.png": Data([0x89, 0x50, 0x4e, 0x47]) + Data(repeating: 0xff, count: 300_000),
        ]
        if includeManifest { files["floe.json"] = try JSONEncoder().encode(manifest) }
        files.merge(supplementalFiles) { _, new in new }
        func fileEntry(_ name: String) -> [String: Any] {
            ["name": URL(fileURLWithPath: name).lastPathComponent, "path": "pkg/" + name,
             "type": "file", "size": files[name]!.count, "sha": blobSHA(files[name]!),
             "download_url": "http://127.0.0.1:9/must-not-follow"]
        }
        func directoryEntry(_ name: String) -> [String: Any] {
            ["name": name, "path": "pkg/" + name, "type": "dir", "size": 0, "sha": pin]
        }
        var packageEntries = [fileEntry("SKILL.md")] +
            (includeManifest ? [fileEntry("floe.json")] : []) +
            [directoryEntry("assets"), directoryEntry("scripts")]
        if files["LICENSE.txt"] != nil { packageEntries.append(fileEntry("LICENSE.txt")) }
        if files.keys.contains(where: { $0.hasPrefix("examples/") }) {
            packageEntries.append(directoryEntry("examples"))
        }
        let root: [[String: Any]] = symlink ? [
            ["name": "escape", "path": "pkg/escape", "type": "symlink", "size": 0,
             "sha": pin, "target": "../../outside"]
        ] : packageEntries
        var responses: [String: Data] = [
            "pkg": try JSONSerialization.data(withJSONObject: root),
            "pkg/assets": try JSONSerialization.data(withJSONObject: [fileEntry("assets/image.png")]),
            "pkg/scripts": try JSONSerialization.data(withJSONObject: [fileEntry("scripts/run.sh")]),
        ]
        if files.keys.contains(where: { $0.hasPrefix("examples/") }) {
            responses["pkg/examples"] = try JSONSerialization.data(withJSONObject:
                files.keys.filter { $0.hasPrefix("examples/") }.sorted().map(fileEntry))
        }
        for (name, bytes) in files {
            var body = bytes
            if tamper && name == "assets/image.png" { body[body.startIndex] ^= 0x01 }
            responses["pkg/" + name] = body
        }
        for (path, bytes) in responses {
            server.register(path: "/repos/octo-org/community/contents/\(path)?ref=\(pin)") { connection in
                connection.sendHead(status: 200, headers: ["content-length": "\(bytes.count)"])
                connection.sendRaw(bytes)
            }
        }
        return (server, files)
    }

    private func stage(_ server: ScriptedLoopbackFixture, at destination: URL) async throws -> SkillContentSnapshot {
        let source = try GitHubSkillSource(owner: "octo-org", repository: "community",
                                           ref: "feature/next", path: "pkg/SKILL.md")
        let transport = WebToolsSkillsConnectorTransport(http: http(), credentials: GitHubCredentialStore(),
            anonymousTransport: AnonymousCommit(pin: pin), apiBase: base(server))
        let (commit, snapshot) = try await GitHubSkillDownload.stage(source: source, at: destination,
            resolve: { try await transport.resolveCommit($0) },
            fetch: { try await transport.fetch($0, commit: $1, path: $2) })
        XCTAssertEqual(commit, pin)
        return snapshot
    }

    func testDirectoryUpdateIncludesScriptAndBinaryWithoutAnAccount() async throws {
        let (server, files) = try directoryFixture()
        server.start()
        defer { server.stop() }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("floe-directory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: destination) }
        let snapshot = try await stage(server, at: destination)
        XCTAssertEqual(snapshot.package.manifest.version, "2.0.0")
        XCTAssertEqual(snapshot.files, files)
        XCTAssertEqual(server.requests.count, 7)
        XCTAssertTrue(server.requests.allSatisfy { $0.headers["authorization"] == nil && $0.path.hasSuffix("ref=\(pin)") })
    }

    func testDirectoryHashMismatchNeverMaterializesPartialPackage() async throws {
        let (server, _) = try directoryFixture(tamper: true)
        server.start()
        defer { server.stop() }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("floe-directory-\(UUID())")
        do {
            _ = try await stage(server, at: destination)
            XCTFail("a changed resource must not become an upgrade snapshot")
        } catch SkillUpgradeError.hashMismatch("assets/image.png") {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testTraditionalDirectoryDerivesAndroidEnvironmentManifestWithoutChangingSourceFiles() async throws {
        let (server, files) = try directoryFixture(includeManifest: false)
        server.start()
        defer { server.stop() }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("floe-directory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: destination) }
        let snapshot = try await stage(server, at: destination)
        XCTAssertEqual(snapshot.package.manifest.platforms, [SkillPlatform.android.rawValue])
        XCTAssertEqual(snapshot.package.manifest.tools, ["exec.shell"])
        XCTAssertEqual(snapshot.package.manifest.scriptRuntime, .remote)
        XCTAssertEqual(snapshot.files, files)
        XCTAssertNil(snapshot.files["floe.json"])
    }

    func testDirectorySymlinkIsRejectedBeforeAnyFileFetch() async throws {
        let (server, _) = try directoryFixture(symlink: true)
        server.start()
        defer { server.stop() }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("floe-directory-\(UUID())")
        do {
            _ = try await stage(server, at: destination)
            XCTFail("a symlink must not be followed")
        } catch SkillUpgradeError.invalidInventory {}
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testTraditionalDirectoryPreservesLicenseAndExamplesInItsVerifiedDigest() async throws {
        let supplemental = ["LICENSE.txt": Data("Fixture license\n".utf8),
                            "examples/update.md": Data("An untrusted example, not an instruction.\n".utf8)]
        let (server, files) = try directoryFixture(includeManifest: false, supplementalFiles: supplemental)
        server.start()
        defer { server.stop() }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("floe-directory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: destination) }
        let snapshot = try await stage(server, at: destination)
        XCTAssertEqual(snapshot.files, files)
        XCTAssertEqual(Set(snapshot.package.files.map(\.relativePath)), Set(files.keys))
    }

    func testExamplesDoNotPermitDisguisedNativePayloads() async throws {
        let (server, _) = try directoryFixture(includeManifest: false,
            supplementalFiles: ["examples/payload.dat": Data([0x7f, 0x45, 0x4c, 0x46, 0])])
        server.start()
        defer { server.stop() }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("floe-directory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: destination) }
        do {
            _ = try await stage(server, at: destination)
            XCTFail("an example is data, never a native payload admission path")
        } catch SkillValidationError.unsupportedFile("examples/payload.dat") {}
    }
}
#endif
