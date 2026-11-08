// SPDX-License-Identifier: MPL-2.0
//
// Android skills connector transport — qualification TEST SOURCE (authored,
// NOT executed by this source-only lane; Main runs the composed
// Swift/Native batch). The credentialed community route is exercised
// against the SAME synthetic 127.0.0.1 scripted-loopback fixture the G02-P3
// transport suites use, through the REAL HTTPRequestService seam (headers a
// real server observes, redirect auth stripping, truncation and client
// aborts). All tokens are SYNTHETIC constants; no real account, device,
// mirror or external network is touched. The anonymous-delegation tests
// prove the tokenless community path never reaches the contents API.
#if canImport(Darwin)
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeSkills
import FloeGit
import FloeAndroidWebTools

final class AndroidSkillsConnectorTransportTests: XCTestCase, @unchecked Sendable {

    private let pin = "0123456789abcdef0123456789abcdef01234567"
    private let token = "synthetic-gh-token-deadbeef-0123456789abcdef"

    // MARK: - Test doubles

    private struct SyntheticLease: GitHubCredentialLeasing {
        let value: String?
        let failure: Error?
        func leasedToken() async throws -> String? {
            if let failure { throw failure }
            return value
        }
    }

    enum LeaseFailure: Error { case stale, vaultUnavailable }

    /// Records every SkillsRemoteTransport call it receives; serves a
    /// scripted community upgrade (one 40-hex pin; entry inventory JSON;
    /// file bytes) so the domain staging chain can run end-to-end.
    final class RecordingTransport: SkillsRemoteTransport, @unchecked Sendable {
        struct Call: Sendable { let kind: String; let source: String; let path: String }
        private let lock = NSLock()
        private var calls: [Call] = []
        var resolveResult: Result<String, Error>!
        var fileBodies: [String: Result<Data, Error>] = [:]
        var entryBody: Result<Data, Error>!

        func snapshot() -> [Call] { lock.withLock { calls } }
        func record(_ kind: String, _ source: GitHubSkillSource, _ path: String = "") {
            lock.withLock { calls.append(Call(kind: kind,
                                              source: "\(source.owner)/\(source.repository)@\(source.ref)",
                                              path: path)) }
        }
        func resolveCommit(_ source: GitHubSkillSource) async throws -> String {
            record("resolve", source)
            return try resolveResult.get()
        }
        func fetch(_ source: GitHubSkillSource, commit: String, path: String) async throws -> Data {
            record("fetch", source, path)
            if path == source.path {
                return try entryBody.get()
            }
            guard let body = fileBodies[path] else {
                throw SkillsDomainRefusal.transportUnavailable
            }
            return try body.get()
        }
        func fetchFinderEnvelope(url: URL) async throws -> Data {
            lock.withLock { calls.append(Call(kind: "envelope", source: url.absoluteString, path: "")) }
            return Data("envelope-bytes".utf8)
        }
    }

    private func ephemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return configuration
    }

    private func loopbackHTTP() -> HTTPRequestService {
        HTTPRequestService(configuration: ephemeralConfiguration(), allowsPrivateNetwork: true)
    }

    private func fixtureBase(_ fixture: ScriptedLoopbackFixture) -> URL {
        URL(string: "http://127.0.0.1:\(fixture.port)")!
    }

    private func communitySource(ref: String = "main", path: String = "pkg/inventory.json") throws -> GitHubSkillSource {
        try GitHubSkillSource(owner: "octo-org", repository: "community-skill", ref: ref, path: path)
    }

    private func makeConnector(fixture: ScriptedLoopbackFixture? = nil,
                               token: String? = nil,
                               leaseFailure: Error? = nil,
                               anonymous: RecordingTransport? = nil)
        -> (transport: WebToolsSkillsConnectorTransport, delegate: RecordingTransport) {
        let delegate = anonymous ?? RecordingTransport()
        let store = GitHubCredentialStore(
            lease: SyntheticLease(value: token, failure: leaseFailure))
        let transport = WebToolsSkillsConnectorTransport(
            http: loopbackHTTP(),
            credentials: store,
            anonymousTransport: delegate,
            apiBase: fixture.map { fixtureBase($0) } ?? WebToolsSkillsConnectorTransport.productionAPIBase)
        return (transport, delegate)
    }

    // MARK: - Base pinning and URL building

    func testAPIBaseClampsAnythingThatIsNotGitHubAPIOrLoopback() {
        XCTAssertEqual(WebToolsSkillsConnectorTransport.acceptedBase(
            URL(string: "https://api.github.com")!), URL(string: "https://api.github.com")!)
        XCTAssertEqual(WebToolsSkillsConnectorTransport.acceptedBase(
            URL(string: "http://127.0.0.1:8080")!), URL(string: "http://127.0.0.1:8080")!)
        // http (non-loopback), foreign https hosts, and credential-in-URL
        // bases can never widen the token's reach: clamp to production.
        XCTAssertEqual(WebToolsSkillsConnectorTransport.acceptedBase(
            URL(string: "http://github.example.com")!), WebToolsSkillsConnectorTransport.productionAPIBase)
        XCTAssertEqual(WebToolsSkillsConnectorTransport.acceptedBase(
            URL(string: "https://git-hub.example.com")!), WebToolsSkillsConnectorTransport.productionAPIBase)
        XCTAssertEqual(WebToolsSkillsConnectorTransport.acceptedBase(
            URL(string: "https://user:pass@api.github.com")!), WebToolsSkillsConnectorTransport.productionAPIBase)
    }

    func testEndpointEncodingMatchesIOSConnectorSegments() throws {
        // Ref slashes and version '+' bytes encode exactly like the iOS
        // `encoded(_:)` character set (alphanumerics + -_.~).
        let url = try WebToolsSkillsConnectorTransport.endpoint(
            base: URL(string: "https://api.github.com")!,
            owner: "octo-org", repository: "community.skill",
            suffix: ["commits", "feature/next"], query: [])
        XCTAssertEqual(url.absoluteString,
                       "https://api.github.com/repos/octo-org/community.skill/commits/feature%2Fnext")
        let file = try WebToolsSkillsConnectorTransport.endpoint(
            base: URL(string: "https://api.github.com")!,
            owner: "octo-org", repository: "community-skill",
            suffix: ["contents", "dist", "ortie-2.3.0+floe.1.zip"],
            query: [URLQueryItem(name: "ref", value: pin)])
        XCTAssertEqual(file.absoluteString,
                       "https://api.github.com/repos/octo-org/community-skill/contents/dist/ortie-2.3.0%2Bfloe.1.zip?ref=\(pin)")
    }

    // MARK: - Tokenless community sources keep the anonymous public path

    func testNoTokenDelegatesResolveAndFetchToAnonymousTransport() async throws {
        let server = try ScriptedLoopbackFixture()
        server.start()
        defer { server.stop() }
        let (connector, delegate) = makeConnector(fixture: server, token: nil)
        delegate.resolveResult = .success(pin)
        delegate.entryBody = .success(Data(#"{"files":{"SKILL.md":"x"}}"#.utf8))
        delegate.fileBodies["pkg/SKILL.md"] = .success(Data("markdown".utf8))

        let source = try communitySource()
        let commit = try await connector.resolveCommit(source)
        XCTAssertEqual(commit, pin)
        let bytes = try await connector.fetch(source, commit: pin, path: "pkg/SKILL.md")
        XCTAssertEqual(bytes, Data("markdown".utf8))

        // The contents API (or ANY api.github.com request) saw nothing:
        // tokenless public installs keep the existing anonymous transport.
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertEqual(delegate.snapshot().map(\.kind), ["resolve", "fetch"])
    }

    // MARK: - Credentialed route: synthetic token only on the official API

    func testTokenlessAccessFailuresRemainActionableWithoutRetry() async throws {
        for status in [401, 403, 404] {
            let anonymous = RecordingTransport()
            anonymous.resolveResult = .failure(WebToolsSkillsRemoteTransport.TransportError.status(status))
            anonymous.entryBody = .failure(AndroidHubMirrorTransport.Failure.httpStatus(status))
            let (connector, _) = makeConnector(anonymous: anonymous)
            let source = try communitySource()
            do {
                _ = try await connector.resolveCommit(source)
                XCTFail("an inaccessible anonymous source must not become a resolved commit")
            } catch SkillsConnectorFetchFailure.accessDenied(status) {}
            do {
                _ = try await connector.fetch(source, commit: pin, path: source.path)
                XCTFail("an inaccessible anonymous source must not become content")
            } catch SkillsConnectorFetchFailure.accessDenied(status) {}
            XCTAssertEqual(anonymous.snapshot().map(\.kind), ["resolve", "fetch"])
        }
    }

    func testCredentialedResolveSendsBearerExactlyOnceAndNeverInURL() async throws {
        let server = try ScriptedLoopbackFixture()
        let source = try communitySource(ref: "feature/next")
        let path = "/repos/octo-org/community-skill/commits/feature%2Fnext"
        server.register(path: path) { connection in
            connection.sendHead(status: 200, headers: [
                "content-type": "text/plain", "content-length": "40"])
            connection.sendRaw(Data(self.pin.utf8))
        }
        server.start()
        defer { server.stop() }
        let (connector, delegate) = makeConnector(fixture: server, token: token)

        let commit = try await connector.resolveCommit(source)
        XCTAssertEqual(commit, pin)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.path, path)
        XCTAssertEqual(request.headers["authorization"], "Bearer \(token)")
        XCTAssertEqual(request.headers["accept"], "application/vnd.github.sha")
        // The credential never becomes part of the URL.
        XCTAssertFalse(request.path.contains(self.token))
        XCTAssertFalse(request.path.contains("token="))
        // Exactly ONE request; no anonymous fallback fired.
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertTrue(delegate.snapshot().isEmpty)
    }

    func testCredentialedFetchPinsImmutableCommitAndEncodesPath() async throws {
        let server = try ScriptedLoopbackFixture()
        let source = try communitySource(path: "pkg dir/inventory.json")
        let encodedPath = "/repos/octo-org/community-skill/contents/pkg%20dir/inventory.json?ref=\(pin)"
        server.register(path: encodedPath) { connection in
            connection.sendHead(status: 200, headers: [
                "content-type": "application/json", "content-length": "2"])
            connection.sendRaw(Data("{}".utf8))
        }
        server.start()
        defer { server.stop() }
        let (connector, _) = makeConnector(fixture: server, token: token)

        _ = try await connector.fetch(source, commit: pin, path: "pkg dir/inventory.json")
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.path, encodedPath)
        XCTAssertTrue(request.path.contains("ref=\(self.pin)"))
        XCTAssertFalse(request.path.contains("ref=main"),
                       "contents fetches must pin the immutable resolved commit, never the mutable ref")
        XCTAssertEqual(request.headers["authorization"], "Bearer \(token)")
        XCTAssertEqual(request.headers["accept"], "application/vnd.github.raw+json")
    }

    // MARK: - Fail-closed behaviour on the credentialed route

    func testAccessAndServerFailuresFailClosedWithoutAnonymousRetry() async throws {
        for (status, expected) in [
            (401, SkillsConnectorFetchFailure.accessDenied(401)),
            (403, SkillsConnectorFetchFailure.accessDenied(403)),
            (404, SkillsConnectorFetchFailure.accessDenied(404)),
            (500, SkillsConnectorFetchFailure.status(500)),
        ] {
            let server = try ScriptedLoopbackFixture()
            let path = "/repos/octo-org/community-skill/commits/main"
            server.register(path: path) { connection in
                connection.sendHead(status: status, headers: ["content-length": "0"])
            }
            server.start()
            let (connector, delegate) = makeConnector(fixture: server, token: token)
            do {
                _ = try await connector.resolveCommit(try communitySource())
                XCTFail("status \(status) must fail closed")
            } catch let failure as SkillsConnectorFetchFailure {
                XCTAssertEqual(failure, expected)
            }
            // One request, no retry of any kind, and the anonymous public
            // path was NOT silently retried after the access failure.
            XCTAssertEqual(server.requests.count, 1, "status \(status)")
            XCTAssertTrue(delegate.snapshot().isEmpty, "status \(status)")
            server.stop()
        }
    }

    func testStaleLeaseFailsClosedBeforeAnyRequest() async throws {
        let server = try ScriptedLoopbackFixture()
        server.start()
        defer { server.stop() }
        let (connector, delegate) = makeConnector(fixture: server, leaseFailure: LeaseFailure.stale)
        do {
            _ = try await connector.resolveCommit(try communitySource())
            XCTFail("a stale lease must fail closed, never degrade to anonymous")
        } catch LeaseFailure.stale {
            // The lease error propagates typed; no request was attempted.
        }
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertTrue(delegate.snapshot().isEmpty)
    }

    func testTruncatedEntryBodyFailsClosedWithPartialBytesNeverReturned() async throws {
        let server = try ScriptedLoopbackFixture()
        let source = try communitySource()
        let path = "/repos/octo-org/community-skill/contents/pkg/inventory.json?ref=\(pin)"
        server.register(path: path) { connection in
            connection.sendHead(status: 200, headers: [
                "content-type": "application/octet-stream", "transfer-encoding": "chunked"])
            for _ in 0..<8 {
                connection.sendChunk(Data(repeating: 0x41, count: 65_536))
                if connection.fixture.sawClientAbort(for: connection.request.path) { return }
            }
            connection.finishChunked()
        }
        server.start()
        defer { server.stop() }
        let (connector, _) = makeConnector(fixture: server, token: token)
        do {
            _ = try await connector.fetch(source, commit: pin, path: source.path)
            XCTFail("an over-cap entry body must fail closed")
        } catch SkillsConnectorFetchFailure.oversized("entry") {
            // The bounded download refuses an entry above 256 KiB;
            // no partial bytes survive as an installable inventory.
        }
        XCTAssertLessThanOrEqual(server.requests.count, 1)
    }

    func testCancellationAbortsTheOwnedRequest() async throws {
        let server = try ScriptedLoopbackFixture()
        let path = "/repos/octo-org/community-skill/commits/main"
        server.register(path: path) { connection in
            connection.sendHead(status: 200, headers: [
                "content-type": "text/plain", "transfer-encoding": "chunked"])
            for _ in 0..<64 {
                connection.sendChunk(Data(repeating: 0x42, count: 1_024))
                if connection.fixture.sawClientAbort(for: connection.request.path) { return }
                ScriptedLoopbackFixture.sleep(25)
            }
            connection.finishChunked()
        }
        server.start()
        defer { server.stop() }
        let (connector, _) = makeConnector(fixture: server, token: token)
        let task = Task {
            try await connector.resolveCommit(try self.communitySource())
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancellation must surface, not a parsed commit")
        } catch is CancellationError {
            // expected
        }
        let aborted = await waitUntil { server.sawClientAbort(for: path) }
        XCTAssertTrue(aborted,
                      "cancellation must abort the owned request instead of reading the full body")
    }

    private func waitUntil(_ predicate: @escaping @Sendable () -> Bool,
                           timeout: TimeInterval = 8.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return predicate()
    }

    // MARK: - Credentialed inventory files: byte-exact bounded download path

    func testBinaryFileAboveSendClampSurvivesByteExact() async throws {
        // 300 KiB of 0x00...0xFF cycles: NOT valid UTF-8, bigger than the
        // 256 KiB send() clamp — must arrive byte-exact through the bounded
        // download path (no body re-encoding).
        let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
        let server = try ScriptedLoopbackFixture()
        let path = "/repos/octo-org/community-skill/contents/pkg/asset.bin?ref=\(pin)"
        server.register(path: path) { connection in
            connection.sendHead(status: 200, headers: [
                "content-type": "application/octet-stream",
                "content-length": "\(bytes.count)"])
            connection.sendRaw(bytes)
        }
        server.start()
        defer { server.stop() }
        let (connector, _) = makeConnector(fixture: server, token: token)

        let got = try await connector.fetch(try communitySource(), commit: pin,
                                            path: "pkg/asset.bin")
        XCTAssertEqual(got, bytes)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.headers["authorization"], "Bearer \(token)")
        XCTAssertEqual(request.headers["accept"], "application/vnd.github.raw+json")
        XCTAssertFalse(request.path.contains(self.token))
    }

    func testOverCapFileFailsClosedAndCleansScratch() async throws {
        let temp = FileManager.default.temporaryDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: temp.path))
        let bytes = Data(repeating: 0x41, count: 2_097_153) // 2 MiB + 1
        let server = try ScriptedLoopbackFixture()
        let path = "/repos/octo-org/community-skill/contents/pkg/big.bin?ref=\(pin)"
        server.register(path: path) { connection in
            connection.sendHead(status: 200, headers: [
                "content-type": "application/octet-stream",
                "content-length": "\(bytes.count)"])
            connection.sendRaw(bytes)
        }
        server.start()
        defer { server.stop() }
        let (connector, _) = makeConnector(fixture: server, token: token)

        do {
            _ = try await connector.fetch(try communitySource(), commit: pin,
                                          path: "pkg/big.bin")
            XCTFail("a 2 MiB+1 file must fail closed at the per-file bound")
        } catch SkillsConnectorFetchFailure.oversized("file") {
            // expected
        }
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: temp.path))
        let leftovers = after.subtracting(before).filter { $0.hasPrefix("floe-connector-") }
        XCTAssertTrue(leftovers.isEmpty,
                      "the bounded download must delete its scratch file on failure, got \(leftovers)")
    }

    func testCredentialedDownloadStripsAuthorizationAcrossOrigins() async throws {
        let origin = try ScriptedLoopbackFixture()
        let destination = try ScriptedLoopbackFixture()
        let bytes = Data([0x00, 0xff, 0x41])
        destination.register(path: "/asset") { connection in
            connection.sendHead(status: 200, headers: ["content-length": "\(bytes.count)"])
            connection.sendRaw(bytes)
        }
        let destinationURL = fixtureBase(destination).appendingPathComponent("asset").absoluteString
        let path = "/repos/octo-org/community-skill/contents/pkg/asset.bin?ref=\(pin)"
        origin.register(path: path) { connection in
            connection.sendHead(status: 302, headers: [
                "location": destinationURL, "content-length": "0"])
        }
        origin.start()
        destination.start()
        defer { origin.stop(); destination.stop() }
        let (connector, delegate) = makeConnector(fixture: origin, token: token)
        let result = try await connector.fetch(try communitySource(), commit: pin,
                                               path: "pkg/asset.bin")
        XCTAssertEqual(result, bytes)
        XCTAssertEqual(origin.requests.count, 1)
        XCTAssertEqual(destination.requests.count, 1)
        XCTAssertEqual(origin.requests.first?.headers["authorization"], "Bearer \(token)")
        XCTAssertNil(destination.requests.first?.headers["authorization"])
        XCTAssertTrue(delegate.snapshot().isEmpty)
    }

    func testCredentialedFetchCancellationAbortsTransferAndCleansScratch() async throws {
        let temp = FileManager.default.temporaryDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: temp.path))
        let server = try ScriptedLoopbackFixture()
        let path = "/repos/octo-org/community-skill/contents/pkg/drip.bin?ref=\(pin)"
        server.register(path: path) { connection in
            connection.sendHead(status: 200, headers: [
                "content-type": "application/octet-stream", "transfer-encoding": "chunked"])
            for _ in 0..<24 {
                connection.sendChunk(Data(repeating: 0x43, count: 32_768))
                if connection.fixture.sawClientAbort(for: connection.request.path) { return }
                ScriptedLoopbackFixture.sleep(50)
            }
            connection.finishChunked()
        }
        server.start()
        defer { server.stop() }
        let (connector, _) = makeConnector(fixture: server, token: token)
        let task = Task {
            try await connector.fetch(try self.communitySource(), commit: self.pin,
                                      path: "pkg/drip.bin")
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancellation must surface, not file bytes")
        } catch is CancellationError {
            // expected
        }
        let aborted = await waitUntil { server.sawClientAbort(for: path) }
        XCTAssertTrue(aborted, "cancellation must abort the owned download")
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: temp.path))
        let leftovers = after.subtracting(before).filter { $0.hasPrefix("floe-connector-") }
        XCTAssertTrue(leftovers.isEmpty,
                      "a cancelled download must remove its scratch file, got \(leftovers)")
    }

    // MARK: - Hub shapes and Finder envelopes never take the credentialed route

    func testOfficialAndCuratedHubSourcesAreRefusedBeforeAnyRequest() async throws {
        let server = try ScriptedLoopbackFixture()
        server.start()
        defer { server.stop() }
        let (connector, delegate) = makeConnector(fixture: server, token: token)
        for source in [try OfficialSkillHub.source(),
                       try CuratedSkillHub.source(channel: .ios),
                       try CuratedSkillHub.source(channel: .android)] {
            do {
                _ = try await connector.resolveCommit(source)
                XCTFail("hub source \(source.repository) must be refused by the connector")
            } catch SkillsConnectorFetchFailure.officialHubSourceRefused {
                // expected: Hub content stays on the anonymous public transport
            }
        }
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertTrue(delegate.snapshot().isEmpty)
    }

    func testFinderEnvelopeStaysOnTheAnonymousPublicTransport() async throws {
        let server = try ScriptedLoopbackFixture()
        server.start()
        defer { server.stop() }
        let (connector, delegate) = makeConnector(fixture: server, token: token)
        let bytes = try await connector.fetchFinderEnvelope(
            url: URL(string: "https://example.com/envelope.json")!)
        XCTAssertEqual(bytes, Data("envelope-bytes".utf8))
        XCTAssertEqual(delegate.snapshot().map(\.kind), ["envelope"])
        XCTAssertTrue(server.requests.isEmpty,
                      "the credentialed API origin must never see a Finder envelope request")
    }
}
#endif
