// SPDX-License-Identifier: MPL-2.0
#if canImport(Darwin)
import XCTest
import Foundation
import Crypto
import FloeCore
import FloeTools
import FloeTransport
@testable import FloeAndroidWebTools

/// G02 D1 host behavioural suite for the minimal web.search/web.fetch
/// closure (job-35f36db9026e4076). Two coverage planes, mirroring the
/// qualified transport lane's contract:
///
/// 1. The ORIGINAL Apple production paths (public inits + `bytes(for:)` /
///    `data(for:)` / `download(for:)`) run end-to-end through the tools and
///    services against the synthetic scripted loopback fixture — proving
///    bounded truncation, redirect revalidation, cross-origin credential
///    stripping, header allow-listing, provider failover, parse
///    normalisation, cancellation and the original error taxonomy.
/// 2. The EXACT Android/Linux bodies (`WebBoundedStream.execute`,
///    `WebSearchCollect.execute`, both `makeStreamingSession`
///    constructions) — compiled on every platform and normally wired only
///    under `os(Linux) || os(Android)` — run directly against the same
///    delegate transport, so the Android branch has real behavioural
///    coverage before the device gate.
///
/// These tests use ONLY synthetic local loopback fixtures and the existing
/// test-only `validateDestination` injection seam (internal integration
/// init). They do NOT weaken any production destination policy, do NOT use
/// real DNS/cloud/TLS, and are NOT proof of Android Foundation Networking
/// internals or device behaviour (Main's gates).

// MARK: - Sendable-clean helpers (no test-class captures inside resolvers)

private func webURL(_ server: ScriptedLoopbackFixture, _ path: String) -> URL {
    URL(string: "http://127.0.0.1:\(server.port)\(path)")!
}

private func providerConfig(_ kind: WebSearchProviderKind, _ path: String?, server: ScriptedLoopbackFixture,
                            priority: Int = 0, options: [String: String] = [:],
                            displayName: String? = nil) -> WebSearchProviderConfiguration {
    WebSearchProviderConfiguration(kind: kind, displayName: displayName ?? kind.rawValue,
                                   endpoint: path.map { webURL(server, $0) },
                                   credentialAccount: "test-\(kind.rawValue)",
                                   priority: priority, options: options)
}

private func ephemeralWebConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    return configuration
}

/// Test-only destination injection through the ORIGINAL internal
/// integration seam: the production public init still uses the strict
/// system-resolver policy; only loopback endpoints are permitted here.
private func fixtureSearchService(configurations: @escaping WebSearchConfigurationResolver) -> WebSearchService {
    WebSearchService(configuration: ephemeralWebConfiguration(), configurations: configurations) { target, _ in
        guard target.host == "127.0.0.1" else { throw HTTPRequestError.privateNetworkTarget(target.host ?? "?") }
    }
}

final class AndroidWebToolsTests: XCTestCase {

    private var fixtures: [ScriptedLoopbackFixture] = []

    private func startFixture() throws -> ScriptedLoopbackFixture {
        let server = try ScriptedLoopbackFixture()
        server.start()
        fixtures.append(server)
        return server
    }

    private func request(_ server: ScriptedLoopbackFixture,
                         _ path: String,
                         method: String = "GET",
                         body: Data? = nil,
                         headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: webURL(server, path))
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// Bounded poll for the fixture's early-close observation (the scripted
    /// write fails only once the client socket is actually gone).
    private func waitUntil(_ predicate: @escaping @Sendable () -> Bool, timeout: TimeInterval = 8.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return predicate()
    }

    override func tearDown() {
        for fixture in fixtures { fixture.stop() }
        fixtures.removeAll()
        super.tearDown()
    }

    // MARK: - 1. Target policy boundaries (no transport, fail-closed)

    func testPublicPolicyRejectsNonPublicShapes() throws {
        // Non-HTTPS, userinfo and denied suffixes are rejected with the
        // ORIGINAL typed errors, in the original order.
        XCTAssertThrowsError(try PublicNetworkTargetPolicy.validate(URL(string: "http://example.com/")!)) { error in
            guard case HTTPRequestError.invalidURL = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertThrowsError(try PublicNetworkTargetPolicy.validate(URL(string: "https://user:pass@example.com/")!)) { error in
            guard case HTTPRequestError.invalidURL = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertThrowsError(try PublicNetworkTargetPolicy.validate(URL(string: "https://api.localhost/v1")!)) { error in
            guard case HTTPRequestError.privateNetworkTarget(let host) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(host, "api.localhost")
        }
        XCTAssertNoThrow(try PublicNetworkTargetPolicy.validate(URL(string: "https://example.com/")!,
                                                                allowTransientTunnelAddresses: false))
    }

    func testPublicPolicyUsesInjectedResolverAndStaysFailClosed() throws {
        // Test-only resolver seam (package-internal, never production):
        // fake-IP 198.18.0.0/15 answers are accepted ONLY when explicitly
        // granted for a fixed built-in endpoint; every other non-public
        // range is refused; resolution failure fails closed as invalidURL.
        XCTAssertNoThrow(try PublicNetworkTargetPolicy.validate(
            URL(string: "https://provider.example/")!,
            allowTransientTunnelAddresses: true,
            resolve: { _ in ["198.18.0.42"] }))
        XCTAssertThrowsError(try PublicNetworkTargetPolicy.validate(
            URL(string: "https://provider.example/")!,
            allowTransientTunnelAddresses: false,
            resolve: { _ in ["198.18.0.42"] })) { error in
            guard case HTTPRequestError.privateNetworkTarget = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertThrowsError(try PublicNetworkTargetPolicy.validate(
            URL(string: "https://provider.example/")!,
            allowTransientTunnelAddresses: false,
            resolve: { _ in ["10.0.0.5"] }))
        XCTAssertThrowsError(try PublicNetworkTargetPolicy.validate(
            URL(string: "https://provider.example/")!,
            allowTransientTunnelAddresses: true,
            resolve: { _ in ["10.0.0.5"] }), "tunnel relaxation must not widen to 10/8")
        XCTAssertThrowsError(try PublicNetworkTargetPolicy.validate(
            URL(string: "https://nx.example/")!,
            allowTransientTunnelAddresses: false,
            resolve: { _ in throw NetworkDestinationError.resolutionFailed("nx.example") })) { error in
            guard case HTTPRequestError.invalidURL = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertNoThrow(try PublicNetworkTargetPolicy.validate(
            URL(string: "https://provider.example/")!,
            allowTransientTunnelAddresses: false,
            resolve: { _ in ["93.184.216.34"] }))
    }

    func testPrivatePolicyAllowsLoopbackRejectsLinkLocalMetadata() throws {
        let server = try startFixture()
        XCTAssertNoThrow(try PrivateNetworkTargetPolicy.validate(webURL(server, "/x")))
        XCTAssertNoThrow(try PrivateNetworkTargetPolicy.validate(URL(string: "http://10.1.2.3/api")!))
        XCTAssertThrowsError(try PrivateNetworkTargetPolicy.validate(URL(string: "http://169.254.169.254/latest/meta-data/")!)) { error in
            guard case HTTPRequestError.privateNetworkTarget(let host) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(host, "169.254.169.254")
        }
        XCTAssertThrowsError(try PrivateNetworkTargetPolicy.validate(URL(string: "http://[fe80::1]/")!))
    }

    func testBlockedHeadersAreRefused() {
        for blocked in ["Host", "Connection", "Content-Length", "Transfer-Encoding",
                        "Proxy-Authorization", "Upgrade", "TE", "Trailer", " proxy-authorization "] {
            XCTAssertFalse(PublicNetworkTargetPolicy.isAllowedHeader(blocked), blocked)
        }
        for allowed in ["Accept", "X-Subscription-Token", "Authorization", "Content-Type"] {
            XCTAssertTrue(PublicNetworkTargetPolicy.isAllowedHeader(allowed), allowed)
        }
    }

    func testSendGuardsRunBeforeAnyNetwork() async throws {
        let server = try startFixture()
        let service = HTTPRequestService(configuration: ephemeralWebConfiguration(), allowsPrivateNetwork: true)
        do {
            _ = try await service.send(method: "TRACE", url: webURL(server, "/never"), headers: [:], body: nil, timeout: 5, maxResponseBytes: 4096)
            XCTFail("TRACE must be rejected")
        } catch let error as HTTPRequestError {
            guard case HTTPRequestError.invalidMethod = error else { return XCTFail("wrong error: \(error)") }
        }
        do {
            _ = try await service.send(method: "GET", url: webURL(server, "/never"), headers: ["Host": "evil"], body: nil, timeout: 5, maxResponseBytes: 4096)
            XCTFail("blocked header must be rejected")
        } catch let error as HTTPRequestError {
            guard case HTTPRequestError.invalidHeaders = error else { return XCTFail("wrong error: \(error)") }
        }
        // Default service + loopback: the PUBLIC policy's HTTPS requirement
        // fails closed BEFORE the private-classification step (original
        // ordering), and the fixture never sees a request (no blanket trust
        // exception). https://localhost demonstrates the same refusal at the
        // private-target step itself.
        let publicService = HTTPRequestService(configuration: ephemeralWebConfiguration())
        do {
            _ = try await publicService.send(method: "GET", url: webURL(server, "/never"), headers: [:], body: nil, timeout: 5, maxResponseBytes: 4096)
            XCTFail("loopback must be refused for the public service")
        } catch let error as HTTPRequestError {
            guard case HTTPRequestError.invalidURL = error else { return XCTFail("wrong error: \(error)") }
        }
        do {
            _ = try await publicService.send(method: "GET", url: URL(string: "https://localhost:\(server.port)/never")!, headers: [:], body: nil, timeout: 5, maxResponseBytes: 4096)
            XCTFail("localhost suffix must be refused")
        } catch let error as HTTPRequestError {
            guard case HTTPRequestError.privateNetworkTarget = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertEqual(server.count(for: "/never"), 0, "guard rejection must not touch the network")
    }

    // MARK: - 2. Original Apple send path (bytes(for:) preserved)

    func testSendBoundedTruncationAndHeaderAllowList() async throws {
        let server = try startFixture()
        let payload = Data((0..<16_384).map { UInt8(ascii: "A") + UInt8($0 % 26) })
        server.register(path: "/page") { connection in
            connection.sendHead(status: 200, headers: [
                "content-type": "text/html; charset=utf-8",
                "transfer-encoding": "chunked",
                "etag": "\"abc\"",
                "set-cookie": "session=leak; Path=/",
                "x-secret": "no",
            ])
            var offset = 0
            while offset < payload.count {
                let end = min(offset + 1024, payload.count)
                connection.sendChunk(payload[offset..<end])
                offset = end
                ScriptedLoopbackFixture.sleep(5)
            }
            connection.finishChunked()
        }
        let service = HTTPRequestService(configuration: ephemeralWebConfiguration(), allowsPrivateNetwork: true)
        let response = try await service.send(method: "GET", url: webURL(server, "/page"),
                                              headers: ["Accept": "text/html"], body: nil,
                                              timeout: 20, maxResponseBytes: 4096)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.truncated, "oversize body must return truncated=true, never an error")
        XCTAssertEqual(response.body.count, 4096)
        XCTAssertEqual(response.finalURL, webURL(server, "/page").absoluteString)
        XCTAssertEqual(response.contentType, "text/html; charset=utf-8")
        XCTAssertEqual(response.headers["content-type"], "text/html; charset=utf-8")
        XCTAssertEqual(response.headers["etag"], "\"abc\"")
        XCTAssertNil(response.headers["set-cookie"], "cookies never enter model context")
        XCTAssertNil(response.headers["x-secret"])
    }

    func testSendNonSuccessStatusIsNotAnError() async throws {
        // Original behaviour: `send` returns the status; the TOOL maps it
        // (exit 22 / fallback), the transport does not throw httpStatus.
        let server = try startFixture()
        server.register(path: "/gone") { connection in
            connection.sendHead(status: 404, headers: ["content-type": "text/plain"])
            connection.sendRaw(Data("missing".utf8))
        }
        let service = HTTPRequestService(configuration: ephemeralWebConfiguration(), allowsPrivateNetwork: true)
        let response = try await service.send(method: "GET", url: webURL(server, "/gone"), headers: [:], body: nil, timeout: 20, maxResponseBytes: 4096)
        XCTAssertEqual(response.statusCode, 404)
        XCTAssertEqual(response.body, "missing")
        XCTAssertFalse(response.truncated)
    }

    func testPublicRedirectDelegateStripsCredentialsAcrossOrigin() async throws {
        let origin = try startFixture()
        let cross = try startFixture()
        origin.register(path: "/redir") { connection in
            connection.sendHead(status: 302, headers: ["location": "http://127.0.0.1:\(cross.port)/stealer"])
        }
        cross.register(path: "/stealer") { connection in
            connection.sendHead(status: 200, headers: ["content-type": "text/plain"])
            connection.sendRaw(Data("stolen".utf8))
        }
        let service = HTTPRequestService(configuration: ephemeralWebConfiguration(), allowsPrivateNetwork: true)
        let response = try await service.send(method: "GET", url: webURL(origin, "/redir"),
                                              headers: ["Authorization": "Bearer super-secret"], body: nil,
                                              timeout: 20, maxResponseBytes: 4096)
        // The diagnostic policy ALLOWS the loopback target but the original
        // delegate STRIPS Authorization/Cookie/Proxy-Authorization across the
        // origin change (different port = different origin).
        XCTAssertEqual(response.statusCode, 200)
        let stealerHeaders = try XCTUnwrap(cross.headers(for: "/stealer"))
        XCTAssertNil(stealerHeaders["authorization"], "cross-origin redirect must not carry Authorization")
        XCTAssertNil(stealerHeaders["cookie"])
        // Same-origin requests keep their explicit headers (original policy).
        let originHeaders = try XCTUnwrap(origin.headers(for: "/redir"))
        XCTAssertEqual(originHeaders["authorization"], "Bearer super-secret")
    }

    func testRedirectToMetadataEndpointIsRefusedAndSurfacesAsStatus() async throws {
        let origin = try startFixture()
        origin.register(path: "/meta") { connection in
            connection.sendHead(status: 302, headers: ["location": "http://169.254.169.254/latest/meta-data/"])
        }
        let service = HTTPRequestService(configuration: ephemeralWebConfiguration(), allowsPrivateNetwork: true)
        let response = try await service.send(method: "GET", url: webURL(origin, "/meta"), headers: [:], body: nil, timeout: 20, maxResponseBytes: 4096)
        // The redirect delegate fails closed: the 3xx itself is surfaced
        // (original semantics) and no hop is attempted toward the metadata
        // address (the fixture set never connects outward).
        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(response.body, "")
    }

    // MARK: - 3. EXACT Android/Linux send body (delegate transport)

    func testAndroidStreamBodyTruncatesAtCapAndCancelsOwnedRead() async throws {
        let server = try startFixture()
        let chunk = Data((0..<8192).map { _ in UInt8(ascii: "x") })
        server.register(path: "/stream") { connection in
            connection.sendHead(status: 200, headers: ["content-type": "text/plain", "transfer-encoding": "chunked"])
            for _ in 0..<8 {
                if connection.fixture.clientAborted(for: "/stream") { return }
                connection.sendChunk(chunk)
                ScriptedLoopbackFixture.sleep(40)
            }
            connection.finishChunked()
        }
        let session = HTTPRequestService.makeStreamingSession(configuration: ephemeralWebConfiguration(),
                                                              allowsPrivateNetwork: true)
        let (bounded, response) = try await WebBoundedStream.execute(
            request(server, "/stream"), via: session, cap: 4096)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        // cap+1-style bounded read: at least one byte past the cap, and the
        // caller's prefix(cap)+truncated math gives the ORIGINAL result —
        // NOT a responseTooLarge throw.
        XCTAssertGreaterThan(bounded.count, 4096)
        XCTAssertLessThanOrEqual(bounded.count, 4096 + 8192)
        let aborted = await waitUntil { server.sawClientAbort(for: "/stream") }
        XCTAssertTrue(aborted, "owned task must stop reading as soon as the cap is crossed")
    }

    func testAndroidStreamBodyIgnoresDeclaredLengthAlone() async throws {
        // A declared Content-Length beyond the cap must NOT cancel early in
        // stream mode (the original bytes(for:) reads anyway and returns
        // truncated). This pins the deliberate difference from `collect`.
        let server = try startFixture()
        let body = Data((0..<65_536).map { _ in UInt8(ascii: "y") })
        server.register(path: "/declared") { connection in
            connection.sendHead(status: 200, headers: [
                "content-type": "text/plain", "content-length": "65536",
            ])
            connection.sendRaw(body)
        }
        let session = HTTPRequestService.makeStreamingSession(configuration: ephemeralWebConfiguration(),
                                                              allowsPrivateNetwork: true)
        let (bounded, response) = try await WebBoundedStream.execute(
            request(server, "/declared"), via: session, cap: 4096)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertGreaterThan(bounded.count, 4096, "declared length beyond cap is a truncated SUCCESS, not an error")
    }

    func testAndroidStreamBodyFailsClosedOnPlainSession() async throws {
        let server = try startFixture()
        server.register(path: "/plain") { connection in
            connection.sendHead(status: 200, headers: ["content-length": "0"])
        }
        do {
            _ = try await WebBoundedStream.execute(request(server, "/plain"),
                                                   via: URLSession(configuration: ephemeralWebConfiguration()),
                                                   cap: 4096)
            XCTFail("a plain session must fail closed")
        } catch let error as IncrementalTransportError {
            guard case .sessionNotStreamable = error else { return XCTFail("wrong error: \(error)") }
        }
        // The typed outcome is `sessionNotStreamable` BEFORE task creation:
        // the request was never moved onto a recreated session.
        XCTAssertEqual(server.count(for: "/plain"), 0)
    }

    func testAndroidStreamBodyPreservesCredentialStrippingThroughRouter() async throws {
        let origin = try startFixture()
        let cross = try startFixture()
        origin.register(path: "/redir") { connection in
            connection.sendHead(status: 302, headers: ["location": "http://127.0.0.1:\(cross.port)/stealer"])
        }
        cross.register(path: "/stealer") { connection in
            connection.sendHead(status: 200, headers: ["content-type": "text/plain"])
            connection.sendRaw(Data("stolen".utf8))
        }
        // The EXACT production Android construction: original
        // PrivateRedirectDelegate installed as the router's policy object.
        let session = HTTPRequestService.makeStreamingSession(configuration: ephemeralWebConfiguration(),
                                                              allowsPrivateNetwork: true)
        let (body, response) = try await WebBoundedStream.execute(
            request(origin, "/redir", headers: ["Authorization": "Bearer super-secret"]), via: session, cap: 4096)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "stolen")
        let headers = try XCTUnwrap(cross.headers(for: "/stealer"))
        XCTAssertNil(headers["authorization"], "router-forwarded delegate must still strip cross-origin credentials")
    }

    func testAndroidStreamBodyPublicServiceRejectsLoopbackHop() async throws {
        let origin = try startFixture()
        let hop = try startFixture()
        origin.register(path: "/hop") { connection in
            connection.sendHead(status: 302, headers: ["location": "http://127.0.0.1:\(hop.port)/landing"])
        }
        hop.register(path: "/landing") { connection in
            connection.sendHead(status: 200, headers: ["content-length": "0"])
        }
        // allowsPrivateNetwork=false → PublicRedirectDelegate revalidates the
        // redirect and refuses the loopback hop: the 302 is surfaced and the
        // landing server is never contacted.
        let session = HTTPRequestService.makeStreamingSession(configuration: ephemeralWebConfiguration(),
                                                              allowsPrivateNetwork: false)
        let (_, response) = try await WebBoundedStream.execute(request(origin, "/hop"), via: session, cap: 4096)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 302)
        XCTAssertEqual(hop.count(for: "/landing"), 0, "refused redirect must produce ZERO requests to the hop target")
    }

    // MARK: - 4. download + staged commit (generic download stays intact)

    func testCommitDownloadBoundariesAndCleanup() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("webtools-commit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        func makeTemp(_ size: Int) throws -> URL {
            let file = temporaryDirectory.appendingPathComponent("payload-\(size)-\(UUID().uuidString)")
            try Data((0..<size).map { _ in UInt8(ascii: "z") }).write(to: file)
            return file
        }
        func response(_ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://example.com/file")!,
                            statusCode: status, httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Type": "application/pdf"])!
        }
        // Success: the staged temporary moves to the destination exactly once.
        let ok = try makeTemp(4096)
        let destination = temporaryDirectory.appendingPathComponent("saved.bin")
        let result = try HTTPRequestService.commitDownload(temporary: ok, response: response(200), maxBytes: 8192, destination: destination)
        XCTAssertEqual(result.byteCount, 4096)
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.contentType, "application/pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ok.path))
        // Oversize: deleted; the partial file is NEVER kept (original contract).
        let big = try makeTemp(8192)
        XCTAssertThrowsError(try HTTPRequestService.commitDownload(temporary: big, response: response(200), maxBytes: 1024,
                                                                   destination: temporaryDirectory.appendingPathComponent("never.bin"))) { error in
            guard case HTTPRequestError.requestFailed(let detail) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertTrue(detail.contains("1024"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: big.path))
        // Non-2xx: typed httpStatus error + cleanup with the original "no
        // destination file was created" wording.
        let failed = try makeTemp(512)
        XCTAssertThrowsError(try HTTPRequestService.commitDownload(temporary: failed, response: response(500), maxBytes: 8192,
                                                                   destination: temporaryDirectory.appendingPathComponent("nope.bin"))) { error in
            guard case HTTPRequestError.httpStatus(let code) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(code, 500)
            guard case HTTPRequestError.httpStatus = error,
                  let description = (error as? HTTPRequestError)?.localizedDescription else { return }
            XCTAssertTrue(description.contains("no destination file was created"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
    }

    func testDownloadCancellationStopsTransferAndThrowsCancelled() async throws {
        let server = try startFixture()
        let chunk = Data((0..<32_768).map { _ in UInt8(ascii: "d") })
        server.register(path: "/bigfile") { connection in
            connection.sendHead(status: 200, headers: ["content-type": "application/octet-stream", "content-length": "3276800"])
            for _ in 0..<100 {
                if connection.fixture.clientAborted(for: "/bigfile") { return }
                connection.sendRaw(chunk)
                ScriptedLoopbackFixture.sleep(30)
            }
        }
        let service = HTTPRequestService(configuration: ephemeralWebConfiguration(), allowsPrivateNetwork: true)
        let token = CancellationToken()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("webtools-dl-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }
        let canceller = Task {
            try? await Task.sleep(for: .milliseconds(300))
            token.cancel()
        }
        do {
            _ = try await service.download(url: webURL(server, "/bigfile"), timeout: 30, maxBytes: 1_000_000,
                                           to: destination, cancellation: token)
            await canceller.value
            XCTFail("cancelled download must not complete")
        } catch let error as FloeError {
            guard case FloeError.cancelled = error else { return XCTFail("wrong error: \(error)") }
        }
        await canceller.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let aborted = await waitUntil { server.sawClientAbort(for: "/bigfile") }
        XCTAssertTrue(aborted, "cancellation must stop the underlying task, not just the caller")
    }

    func testDownloadRejectsCancelledTokenBeforeAnyNetwork() async throws {
        let server = try startFixture()
        server.register(path: "/never-dl") { connection in
            connection.sendHead(status: 200, headers: ["content-length": "0"])
        }
        let token = CancellationToken()
        token.cancel()
        let service = HTTPRequestService(configuration: ephemeralWebConfiguration(), allowsPrivateNetwork: true)
        do {
            _ = try await service.download(url: webURL(server, "/never-dl"), timeout: 5, maxBytes: 1024,
                                           to: FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID().uuidString)"),
                                           cancellation: token)
            XCTFail("pre-cancelled token must refuse")
        } catch let error as FloeError {
            guard case FloeError.cancelled = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertEqual(server.count(for: "/never-dl"), 0)
    }

    // MARK: - 5. WebSearchService: original request building/policy (no net)

    func testMakeRequestWiringPerKind() throws {
        let server = try startFixture()
        func credential(_ values: [String: String]) -> WebSearchCredential { WebSearchCredential(values: values) }
        // Bocha: bearer + summary default/option/explicit.
        XCTAssertThrowsError(try WebSearchService.makeRequest(providerConfig(.bochaWeb, nil, server: server),
                                                              credential: credential([:]), query: .init(text: "q"))) { error in
            guard case WebRetrievalError.missingCredential("apiKey") = error else { return XCTFail("wrong: \(error)") }
        }
        let bocha = try WebSearchService.makeRequest(providerConfig(.bochaWeb, "/b", server: server),
                                                     credential: credential(["apiKey": "k1"]),
                                                     query: .init(text: "q", summaryEnabled: true))
        XCTAssertEqual(bocha.value(forHTTPHeaderField: "Authorization"), "Bearer k1")
        let bochaBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(bocha.httpBody)) as? [String: Any])
        XCTAssertEqual(bochaBody["summary"] as? Bool, true)
        XCTAssertEqual(bochaBody["count"] as? Int, 10)
        let bochaOff = try WebSearchService.makeRequest(
            providerConfig(.bochaWeb, "/b", server: server, options: ["summaryEnabled": "false"]),
            credential: credential(["apiKey": "k1"]), query: .init(text: "q"))
        let offBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(bochaOff.httpBody)) as? [String: Any])
        XCTAssertEqual(offBody["summary"] as? Bool, false, "provider option respected when the query defers (nil)")
        // Brave: documented same-endpoint extras + subscription token.
        let brave = try WebSearchService.makeRequest(providerConfig(.brave, "/brave", server: server),
                                                     credential: credential(["apiKey": "bk"]),
                                                     query: .init(text: "hello world", maxResults: 30))
        XCTAssertEqual(brave.value(forHTTPHeaderField: "X-Subscription-Token"), "bk")
        let braveComponents = try XCTUnwrap(URLComponents(url: try XCTUnwrap(brave.url), resolvingAgainstBaseURL: false))
        let braveItems = Dictionary(uniqueKeysWithValues: (braveComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(braveItems["q"], "hello world")
        XCTAssertEqual(braveItems["count"], "20", "brave caps at 20")
        XCTAssertEqual(braveItems["extra_snippets"], "true")
        XCTAssertEqual(braveItems["include_fetch_metadata"], "true")
        // Tencent: deterministic TC3 signing for a fixed now + stable headers.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tencentA = try WebSearchService.makeRequest(providerConfig(.tencentWSA, "/tc", server: server),
                                                        credential: credential(["secretId": "id", "secretKey": "key"]),
                                                        query: .init(text: "q", domains: ["example.com"], recencyDays: 5),
                                                        now: now)
        let first = try XCTUnwrap(tencentA.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(first.hasPrefix("TC3-HMAC-SHA256 Credential=id/"), first)
        XCTAssertTrue(first.contains("2023-11-14/wsa/tc3_request"), first)
        let signature = try XCTUnwrap(first.components(separatedBy: "Signature=").last)
        XCTAssertEqual(signature.count, 64)
        XCTAssertTrue(signature.allSatisfy { $0.isHexDigit })
        let tencentB = try WebSearchService.makeRequest(providerConfig(.tencentWSA, "/tc", server: server),
                                                        credential: credential(["secretId": "id", "secretKey": "key"]),
                                                        query: .init(text: "q", domains: ["example.com"], recencyDays: 5),
                                                        now: now)
        XCTAssertEqual(tencentB.value(forHTTPHeaderField: "Authorization"), first, "signing is deterministic for fixed now")
        XCTAssertEqual(tencentA.value(forHTTPHeaderField: "X-TC-Action"), "SearchPro")
        XCTAssertEqual(tencentA.value(forHTTPHeaderField: "X-TC-Version"), "2025-05-08")
        XCTAssertEqual(tencentA.value(forHTTPHeaderField: "X-TC-Timestamp"), "1700000000")
        let tencentBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(tencentA.httpBody)) as? [String: Any])
        XCTAssertEqual(tencentBody["Freshness"] as? String, "d5")
        XCTAssertEqual(tencentBody["Site"] as? String, "example.com")
        XCTAssertEqual(tencentBody["Cnt"] as? Int, 10)
        // Google: key+cx+num≤10. Tavily: api_key inside body. Exa: x-api-key.
        let google = try WebSearchService.makeRequest(providerConfig(.googleProgrammable, "/g", server: server),
                                                      credential: credential(["apiKey": "gk", "engineId": "e1"]),
                                                      query: .init(text: "q", maxResults: 50))
        let googleComponents = try XCTUnwrap(URLComponents(url: try XCTUnwrap(google.url), resolvingAgainstBaseURL: false))
        let googleItems = Dictionary(uniqueKeysWithValues:
            (try XCTUnwrap(googleComponents.queryItems)).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(googleItems["key"], "gk")
        XCTAssertEqual(googleItems["cx"], "e1")
        XCTAssertEqual(googleItems["num"], "10")
        let tavily = try WebSearchService.makeRequest(providerConfig(.tavily, "/t", server: server),
                                                      credential: credential(["apiKey": "tk"]),
                                                      query: .init(text: "q", mode: .fast))
        let tavilyBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(tavily.httpBody)) as? [String: Any])
        XCTAssertEqual(tavilyBody["api_key"] as? String, "tk")
        XCTAssertEqual(tavilyBody["search_depth"] as? String, "basic")
        let exa = try WebSearchService.makeRequest(providerConfig(.exa, "/e", server: server),
                                                   credential: credential(["apiKey": "ek"]),
                                                   query: .init(text: "q"))
        XCTAssertEqual(exa.value(forHTTPHeaderField: "x-api-key"), "ek")
        // SearXNG: endpoint required, anonymous OK. Custom/volcengine: Bearer.
        XCTAssertThrowsError(try WebSearchService.makeRequest(providerConfig(.searxng, nil, server: server),
                                                              credential: WebSearchCredential(values: [:]),
                                                              query: .init(text: "q"))) { error in
            guard case WebRetrievalError.invalidResponse = error else { return XCTFail("wrong: \(error)") }
        }
        let custom = try WebSearchService.makeRequest(providerConfig(.custom, "/c", server: server),
                                                      credential: credential(["apiKey": "ck"]),
                                                      query: .init(text: "q"))
        XCTAssertEqual(custom.value(forHTTPHeaderField: "Authorization"), "Bearer ck")
        // Every provider request carries the JSON accept header + 30s timeout.
        XCTAssertEqual(brave.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(brave.timeoutInterval, 30)
    }

    func testCanonicalEndpointAndTunnelRelaxationContract() throws {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
        // Bocha canonical (no endpoint override) → fake-IP answers tolerated.
        XCTAssertTrue(WebSearchService.allowsTransientTunnel(
            for: .init(kind: .bochaWeb, displayName: "b", credentialAccount: "a")))
        // An endpoint override forfeits, even to the canonical URL itself.
        XCTAssertFalse(WebSearchService.allowsTransientTunnel(
            for: .init(kind: .bochaWeb, displayName: "b",
                       endpoint: WebSearchService.canonicalEndpoints[.bochaWeb], credentialAccount: "a")))
        // custom has no canonical contract even pointing at a canonical host.
        XCTAssertFalse(WebSearchService.allowsTransientTunnel(
            for: .init(kind: .custom, displayName: "c",
                       endpoint: URL(string: "https://api.bochaai.com/v1/web-search"), credentialAccount: "a")))
        // Brave carries generated query parameters — still canonical.
        XCTAssertTrue(WebSearchService.requestURLIsCanonical(
            URL(string: "https://api.search.brave.com/res/v1/web/search?q=hi&count=20&extra_snippets=true"), kind: .brave))
        XCTAssertFalse(WebSearchService.requestURLIsCanonical(URL(string: "https://api.search.brave.com/res/v2/web/search")!, kind: .brave))
        XCTAssertFalse(WebSearchService.requestURLIsCanonical(URL(string: "https://api.search.brave.com:8443/res/v1/web/search")!, kind: .brave))
        // Brave freshness mapping incl. the deterministic custom range
        // (400 days before 2023-11-14 = 2022-10-11).
        XCTAssertEqual(WebSearchService.braveFreshness(days: 1, now: fixedNow), "pd")
        XCTAssertEqual(WebSearchService.braveFreshness(days: 7, now: fixedNow), "pw")
        XCTAssertEqual(WebSearchService.braveFreshness(days: 31, now: fixedNow), "pm")
        XCTAssertEqual(WebSearchService.braveFreshness(days: 365, now: fixedNow), "py")
        XCTAssertEqual(WebSearchService.braveFreshness(days: 400, now: fixedNow), "2022-10-11to2023-11-14")
        XCTAssertNil(WebSearchService.braveFreshness(days: 0, now: fixedNow))
        XCTAssertNil(WebSearchService.braveFreshness(days: nil, now: fixedNow))
    }

    func testIsConfiguredGatesLocallyWithoutProbing() throws {
        let server = try startFixture()
        let credential = WebSearchCredential(values: ["apiKey": " k "])
        XCTAssertTrue(WebSearchService.isConfigured(providerConfig(.brave, nil, server: server), credential: credential))
        var disabled = providerConfig(.brave, nil, server: server)
        disabled.enabled = false
        XCTAssertFalse(WebSearchService.isConfigured(disabled, credential: credential), "disabled never configured")
        XCTAssertFalse(WebSearchService.isConfigured(providerConfig(.brave, nil, server: server),
                                                     credential: WebSearchCredential(values: ["apiKey": "  "])),
                       "blank key after trim")
        XCTAssertFalse(WebSearchService.isConfigured(providerConfig(.searxng, nil, server: server),
                                                     credential: WebSearchCredential(values: [:])),
                       "searxng needs endpoint")
        XCTAssertTrue(WebSearchService.isConfigured(providerConfig(.searxng, "/sx", server: server),
                                                    credential: WebSearchCredential(values: [:])),
                      "self-hosted SearXNG may be anonymous")
        XCTAssertFalse(WebSearchService.isConfigured(providerConfig(.brave, nil, server: server),
                                                     credential: WebSearchCredential(values: [:])))
    }

    // MARK: - 6. WebSearchService end-to-end over loopback fixtures

    func testSearchFailoverDeduplicateAndNormalize() async throws {
        let first = try startFixture()
        let second = try startFixture()
        first.register(path: "/empty") { connection in
            connection.sendHead(status: 200, headers: ["content-type": "application/json"])
            connection.sendRaw(Data(#"{"web":{"results":[]}}"#.utf8))
        }
        let payload = #"""
        {"web":{"results":[
          {"title":"Alpha","url":"https://example.com/a?utm_source=x#frag","snippet":"one","age":"2 days ago"},
          {"title":"Alpha dup","url":"https://example.com/a","content":"fallback excerpt"},
          {"title":"","url":"https://example.com/untitled","snippet":"dropped"},
          {"title":"Beta","url":"ftp://nope/x","snippet":"dropped"},
          {"title":"Gamma","url":"https://example.com/g","description":"brave style","extra_snippets":["e1","","e2"],"page_age":"yesterday","profile":{"long_name":"Example","url":"https://example.com"},"meta_url":{"hostname":"example.com","path":"/g"}},
          {"title":"Alpha","url":"https://example.com/a?utm_source=x#frag","snippet":"one"}
        ]}}
        """#
        second.register(path: "/results") { connection in
            connection.sendHead(status: 200, headers: ["content-type": "application/json"])
            connection.sendRaw(Data(payload.utf8))
        }
        // POST-bodied kinds keep fixture paths query-free and deterministic.
        let service = fixtureSearchService {
            [
                (providerConfig(.custom, "/empty", server: first, priority: 0), WebSearchCredential(values: ["apiKey": "k"])),
                (providerConfig(.tavily, "/results", server: second, priority: 1), WebSearchCredential(values: ["apiKey": "k"])),
            ]
        }
        let response = try await service.search(WebSearchQuery(text: "q", mode: .balanced, maxResults: 10))
        // Failover: first provider is a VALID EMPTY result → recorded failure,
        // second provider answers; providersUsed keeps the original shape.
        XCTAssertEqual(response.providersUsed, [.tavily])
        XCTAssertEqual(response.failures, ["custom: empty result"])
        // Title-less and non-http rows drop; an EXACT repeat row collapses.
        // The utm+fragment row and its plain twin stay SEPARATE: that is the
        // ORIGINAL shared deduplicate behaviour on the same Foundation code
        // both platforms run (normalising away utm_/fragment serialises to a
        // trailing "?", so the keys differ) — preserved verbatim, no new
        // behaviour is invented by this port.
        XCTAssertEqual(response.results.map(\.title), ["Alpha", "Alpha dup", "Gamma"])
        // The citation target stays EXACT (dedup normalisation never rewrites
        // the stored URL).
        XCTAssertEqual(response.results[0].url.absoluteString, "https://example.com/a?utm_source=x#frag")
        XCTAssertEqual(response.results[0].effectiveContentState, .searchMetadataOnly)
        XCTAssertEqual(response.results[0].relativeAge, "2 days ago")
        XCTAssertEqual(response.results[1].snippet, "fallback excerpt", "content participates in excerpt priority")
        let gamma = response.results[2]
        XCTAssertEqual(gamma.snippet, "brave style", "description participates in excerpt priority")
        XCTAssertEqual(gamma.extraSnippets, ["e1", "e2"], "empty extras dropped, never fabricated")
        XCTAssertEqual(gamma.sourceProfileName, "Example")
        XCTAssertEqual(gamma.displayPath, "/g")
        XCTAssertEqual(gamma.pageAge, "yesterday", "page_age never relabels publishedAt")
        XCTAssertNil(gamma.publishedAt)
        // Citation ID: 12-char lowercase-hex of sha256("provider|url") —
        // independent oracle, stable seed.
        let seed = Data("tavily|https://example.com/a?utm_source=x#frag".utf8)
        let expected = String(SHA256.hash(data: seed).map { String(format: "%02x", $0) }.joined().prefix(12))
        XCTAssertEqual(response.results[0].citationID, expected)
    }

    func testSearchAllProvidersFailedCarriesTypedError() async throws {
        let server = try startFixture()
        server.register(path: "/none") { connection in
            connection.sendHead(status: 200, headers: ["content-type": "application/json"])
            connection.sendRaw(Data(#"{"results":[]}"#.utf8))
        }
        server.register(path: "/boom") { connection in
            connection.sendHead(status: 500, headers: ["content-type": "text/plain"])
            connection.sendRaw(Data("nope".utf8))
        }
        let service = fixtureSearchService {
            [
                (providerConfig(.custom, "/none", server: server, priority: 0), WebSearchCredential(values: ["apiKey": "k"])),
                (providerConfig(.tavily, "/boom", server: server, priority: 1), WebSearchCredential(values: ["apiKey": "k"])),
            ]
        }
        do {
            _ = try await service.search(WebSearchQuery(text: "q"))
            XCTFail("all-empty must throw")
        } catch let error as WebRetrievalError {
            guard case WebRetrievalError.allProvidersFailed(let failures) = error else { return XCTFail("wrong: \(error)") }
            XCTAssertEqual(failures, ["custom: empty result", "tavily: HTTP 500"],
                           "original failure taxonomy: typed status text, never a fake success")
        }
    }

    func testSearchNoProviderAndUnknownRequestedProvider() async throws {
        let server = try startFixture()
        let empty = fixtureSearchService { [] }
        do {
            _ = try await empty.search(WebSearchQuery(text: "q"))
            XCTFail()
        } catch let error as WebRetrievalError {
            guard case WebRetrievalError.noProviderConfigured = error else { return XCTFail("wrong: \(error)") }
        }
        let configured = fixtureSearchService {
            [(providerConfig(.brave, "/never", server: server), WebSearchCredential(values: ["apiKey": "k"]))]
        }
        do {
            _ = try await configured.search(WebSearchQuery(text: "q", requestedProvider: "ghost"))
            XCTFail()
        } catch let error as WebRetrievalError {
            guard case WebRetrievalError.providerNotFound("ghost") = error else { return XCTFail("wrong: \(error)") }
        }
        // Brave's canonical endpoint would have been used; selection failed
        // before any transport — but with the endpoint override to the
        // fixture, "never" must still show zero requests.
        XCTAssertEqual(server.count(for: "/never"), 0)
    }

    func testSearchDeepModeCombinesUpToThreeProviders() async throws {
        let server = try startFixture()
        @Sendable func resultsRow(_ name: String) -> Data {
            Data("{\"results\":[{\"title\":\"\(name)\",\"url\":\"https://example.com/\(name)\",\"snippet\":\"s\"}]}".utf8)
        }
        server.register(path: "/p1") { connection in
            connection.sendHead(status: 200, headers: ["content-type": "application/json"])
            connection.sendRaw(resultsRow("one"))
        }
        server.register(path: "/p2") { connection in
            connection.sendHead(status: 200, headers: ["content-type": "application/json"])
            connection.sendRaw(resultsRow("two"))
        }
        server.register(path: "/p3") { connection in
            connection.sendHead(status: 200, headers: ["content-type": "application/json"])
            connection.sendRaw(resultsRow("three"))
        }
        // POST-bodied kinds keep fixture paths query-free and deterministic.
        let service = fixtureSearchService {
            [
                (providerConfig(.volcengine, "/p3", server: server, priority: 2), WebSearchCredential(values: ["apiKey": "k"])),
                (providerConfig(.bochaAI, "/p1", server: server, priority: 0), WebSearchCredential(values: ["apiKey": "k"])),
                (providerConfig(.custom, "/p2", server: server, priority: 1), WebSearchCredential(values: ["apiKey": "k"])),
            ]
        }
        let response = try await service.search(WebSearchQuery(text: "q", mode: .deep, maxResults: 10))
        // deep selects up to three providers by priority and MERGES
        // concurrently; completion order is not contractual.
        XCTAssertEqual(Set(response.results.map(\.title)), Set(["one", "two", "three"]))
        XCTAssertEqual(Set(response.providersUsed.map(\.rawValue)), Set(["bochaAI", "custom", "volcengine"]))
    }

    func testSearchRejectsCrossOriginRedirectAndKeepsKeyOnSameOrigin() async throws {
        let server = try startFixture()
        let outside = try startFixture()
        server.register(path: "/samehop") { connection in
            connection.sendHead(status: 302, headers: ["location": "http://127.0.0.1:\(server.port)/final"])
        }
        server.register(path: "/final") { connection in
            connection.sendHead(status: 200, headers: ["content-type": "application/json"])
            connection.sendRaw(Data(#"{"results":[{"title":"Kept","url":"https://example.com/k","snippet":"s"}]}"#.utf8))
        }
        server.register(path: "/crosshop") { connection in
            connection.sendHead(status: 302, headers: ["location": "http://127.0.0.1:\(outside.port)/stealer"])
        }
        outside.register(path: "/stealer") { connection in
            connection.sendHead(status: 200, headers: ["content-type": "application/json"])
            connection.sendRaw(Data(#"{"results":[{"title":"Stolen","url":"https://evil.example/","snippet":"s"}]}"#.utf8))
        }
        // Same origin (same host+port): the ORIGINAL delegate follows and the
        // provider credential rides along untouched.
        let sameOrigin = fixtureSearchService {
            [(providerConfig(.custom, "/samehop", server: server), WebSearchCredential(values: ["apiKey": "k"]))]
        }
        let kept = try await sameOrigin.search(WebSearchQuery(text: "q"))
        XCTAssertEqual(kept.results.map(\.title), ["Kept"])
        // Cross-origin (different port): rejected OUTRIGHT — not followed
        // with the key stripped — and the key target is never contacted.
        let cross = fixtureSearchService {
            [(providerConfig(.custom, "/crosshop", server: server), WebSearchCredential(values: ["apiKey": "k"]))]
        }
        do {
            _ = try await cross.search(WebSearchQuery(text: "q"))
            XCTFail()
        } catch let error as WebRetrievalError {
            guard case WebRetrievalError.allProvidersFailed(let failures) = error else { return XCTFail("wrong: \(error)") }
            XCTAssertTrue(failures.contains { $0.contains("HTTP 302") }, failures.description)
        }
        XCTAssertEqual(outside.count(for: "/stealer"), 0, "provider credentials never leave the pinned origin")
    }

    func testSearchRedirectRevalidationUsesTheSamePolicy() async throws {
        // The REDIRECT path reuses the very same destination check as the
        // initial request (no silent fallback to a looser policy): a hop to
        // a non-loopback target is refused by the injected test validator.
        let server = try startFixture()
        server.register(path: "/to-public") { connection in
            connection.sendHead(status: 302, headers: ["location": "https://example.com/land"])
        }
        let service = fixtureSearchService {
            [(providerConfig(.custom, "/to-public", server: server), WebSearchCredential(values: ["apiKey": "k"]))]
        }
        do {
            _ = try await service.search(WebSearchQuery(text: "q", maxResults: 1))
            XCTFail("validator refuses the non-loopback hop")
        } catch let error as WebRetrievalError {
            guard case WebRetrievalError.allProvidersFailed(let failures) = error else { return XCTFail("wrong: \(error)") }
            XCTAssertTrue(failures.contains { $0.contains("HTTP 302") }, failures.description)
        }
    }

    // MARK: - 7. EXACT Android/Linux provider collect body

    func testAndroidCollectBodyRunsThroughProductionConstruction() async throws {
        let server = try startFixture()
        server.register(path: "/json") { connection in
            connection.sendHead(status: 200, headers: ["content-type": "application/json"])
            connection.sendRaw(Data(#"{"web":{"results":[{"title":"T","url":"https://example.com/1","snippet":"s"}]}}"#.utf8))
        }
        server.register(path: "/status404") { connection in
            connection.sendHead(status: 404, headers: ["content-type": "application/json"])
            connection.sendRaw(Data(#"{"message":"gone"}"#.utf8))
        }
        let allowLoopback: @Sendable (URL, Bool) throws -> Void = { target, _ in
            guard target.host == "127.0.0.1" else { throw HTTPRequestError.privateNetworkTarget(target.host ?? "?") }
        }
        // EXACT Android session construction: the ORIGINAL
        // SearchProviderRedirectDelegate installed as router policy.
        let session = WebSearchService.makeStreamingSession(configuration: ephemeralWebConfiguration(),
                                                            validateDestination: allowLoopback)
        let (data, response) = try await WebSearchCollect.execute(request(server, "/json"), via: session)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"title\":\"T\""))
        // Status passthrough stays in the ORIGINAL guard inside run(): a
        // collect of a 404 returns bytes + status, it does NOT throw.
        let (missingData, missingResponse) = try await WebSearchCollect.execute(request(server, "/status404"), via: session)
        XCTAssertEqual((missingResponse as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertFalse(missingData.isEmpty)
        // Plain injected session: fail closed, zero requests, no recreation.
        do {
            _ = try await WebSearchCollect.execute(request(server, "/json"),
                                                   via: URLSession(configuration: ephemeralWebConfiguration()))
            XCTFail()
        } catch let error as IncrementalTransportError {
            guard case .sessionNotStreamable = error else { return XCTFail("wrong: \(error)") }
        }
    }

    func testAndroidCollectBodyPreservesRedirectPolicy() async throws {
        let origin = try startFixture()
        let cross = try startFixture()
        origin.register(path: "/hop") { connection in
            connection.sendHead(status: 302, headers: ["location": "http://127.0.0.1:\(cross.port)/stealer"])
        }
        cross.register(path: "/stealer") { connection in
            connection.sendHead(status: 200, headers: ["content-length": "0"])
        }
        let allowLoopback: @Sendable (URL, Bool) throws -> Void = { target, _ in
            guard target.host == "127.0.0.1" else { throw HTTPRequestError.privateNetworkTarget(target.host ?? "?") }
        }
        let session = WebSearchService.makeStreamingSession(configuration: ephemeralWebConfiguration(),
                                                            validateDestination: allowLoopback)
        let (body, response) = try await WebSearchCollect.execute(
            request(origin, "/hop", headers: ["Authorization": "Bearer provider-key"]), via: session)
        // Cross-origin hop (same host, different port): the ORIGINAL delegate
        // refuses outright → the 3xx surfaces as the final response and the
        // hop target receives nothing.
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 302)
        XCTAssertEqual(body.count, 0)
        XCTAssertEqual(cross.count(for: "/stealer"), 0, "zero requests may reach the refused hop")
    }

    // MARK: - 8. Tool layer: original semantics, temporary-chat ceiling

    private func context(cancellation: CancellationToken = CancellationToken(),
                         publicWebOnly: Bool = false) -> ToolContext {
        ToolContext(runID: UUID(), publicWebOnly: publicWebOnly, cancellation: cancellation)
    }

    func testWebFetchToolExtractAndPassthrough() throws {
        let html = "<html><head><script>var evil=1;</script><style>a{}</style></head>"
            + "<body><noscript>ns</noscript><h1>Title &amp; \"Quotes\"</h1><p>Body&nbsp;text</p></body></html>"
        let extracted = WebFetchTool.extract(html, contentType: "text/html")
        XCTAssertFalse(extracted.contains("evil"))
        XCTAssertFalse(extracted.contains("ns"))
        XCTAssertTrue(extracted.contains("Title & \"Quotes\""))
        XCTAssertTrue(extracted.contains("Body text"))
        XCTAssertEqual(WebFetchTool.extract("plain text", contentType: "text/plain"), "plain text", "non-HTML passes through")
    }

    func testWebFetchToolExecutesAndBoundsOutput() async throws {
        let server = try startFixture()
        let html = "<html><body><p>\(String(repeating: "word ", count: 5_000))</p></body></html>"
        server.register(path: "/article") { connection in
            connection.sendHead(status: 200, headers: ["content-type": "text/html; charset=utf-8",
                                                       "content-length": String(html.utf8.count)])
            connection.sendRaw(Data(html.utf8))
        }
        let service = HTTPRequestService(configuration: ephemeralWebConfiguration(), allowsPrivateNetwork: true)
        let tool = WebFetchTool(service: service)
        try tool.validate(.init(url: webURL(server, "/article").absoluteString, localNetwork: true))
        let output = try await tool.execute(.init(url: webURL(server, "/article").absoluteString,
                                                  maxCharacters: 1_000, timeout: 20, localNetwork: true),
                                            context: context())
        XCTAssertEqual(output.exitStatus, 0)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
        XCTAssertEqual(payload["statusCode"] as? Int, 200)
        let text = try XCTUnwrap(payload["text"] as? String)
        XCTAssertEqual(text.count, 1_000, "maxCharacters bounds extracted text")
        XCTAssertEqual(payload["truncated"] as? Bool, true, "transport-level truncation stays visible")
        XCTAssertEqual(payload["browserFallback"] as? String, "")
        XCTAssertEqual(output.fullOutputSHA256.count, 64)
    }

    func testWebFetchToolBinaryAndNonSuccessExitStatuses() async throws {
        let server = try startFixture()
        server.register(path: "/pdf") { connection in
            connection.sendHead(status: 200, headers: ["content-type": "application/pdf", "content-length": "8"])
            connection.sendRaw(Data("%PDF-1.4".utf8))
        }
        server.register(path: "/err") { connection in
            connection.sendHead(status: 503, headers: ["content-type": "text/plain"])
            connection.sendRaw(Data("busy".utf8))
        }
        let service = HTTPRequestService(configuration: ephemeralWebConfiguration(), allowsPrivateNetwork: true)
        let tool = WebFetchTool(service: service)
        let binary = try await tool.execute(.init(url: webURL(server, "/pdf").absoluteString, localNetwork: true),
                                            context: context())
        let binaryPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(binary.summary.utf8)) as? [String: Any])
        XCTAssertEqual(binaryPayload["browserFallback"] as? String, "binary_use_network_download")
        XCTAssertEqual(binaryPayload["text"] as? String, "", "binary bytes never enter model context")
        let failed = try await tool.execute(.init(url: webURL(server, "/err").absoluteString, localNetwork: true),
                                            context: context())
        XCTAssertEqual(failed.exitStatus, 22, "non-2xx/3xx exits 22 with the status visible")
        let failedPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(failed.summary.utf8)) as? [String: Any])
        XCTAssertEqual(failedPayload["statusCode"] as? Int, 503)
    }

    func testWebFetchTemporaryChatCeiling() async throws {
        let server = try startFixture()
        server.register(path: "/t") { connection in
            connection.sendHead(status: 200, headers: ["content-length": "0"])
        }
        let tool = WebFetchTool(service: HTTPRequestService(configuration: ephemeralWebConfiguration(), allowsPrivateNetwork: true))
        // Temporary chat: the LAN opt-in is refused outright.
        do {
            _ = try await tool.execute(.init(url: webURL(server, "/t").absoluteString, localNetwork: true),
                                       context: context(publicWebOnly: true))
            XCTFail()
        } catch let error as FloeError {
            guard case FloeError.validationFailed(let message) = error else { return XCTFail("wrong: \(error)") }
            XCTAssertTrue(message.contains("Temporary chats"))
        }
        // Temporary chat: even WITHOUT the opt-in, a private target is
        // refused by the public policy — never downgraded to the diagnostic
        // path. https://localhost trips the denied-suffix rule; an http
        // loopback would first fail the HTTPS requirement.
        do {
            _ = try await tool.execute(.init(url: "https://localhost:\(server.port)/t"),
                                       context: context(publicWebOnly: true))
            XCTFail()
        } catch let error as HTTPRequestError {
            guard case HTTPRequestError.privateNetworkTarget = error else { return XCTFail("wrong: \(error)") }
        }
        XCTAssertEqual(server.count(for: "/t"), 0, "the ceiling must refuse before any request leaves")
        // Pre-cancelled run: refused before anything starts.
        let token = CancellationToken()
        token.cancel()
        do {
            _ = try await tool.execute(.init(url: webURL(server, "/t").absoluteString, localNetwork: true),
                                       context: context(cancellation: token))
            XCTFail()
        } catch let error as FloeError {
            guard case FloeError.cancelled = error else { return XCTFail("wrong: \(error)") }
        }
    }

    func testWebSearchToolArgumentValidation() throws {
        let service = WebSearchService(configuration: ephemeralWebConfiguration(), configurations: { [] })
        let tool = WebSearchTool(service: service)
        XCTAssertNoThrow(try tool.validate(.init(query: "hello")))
        for bad in ["", "   ", String(repeating: "q", count: 2_001)] {
            XCTAssertThrowsError(try tool.validate(.init(query: bad)), bad)
        }
        XCTAssertThrowsError(try tool.validate(.init(query: "ok", mode: "turbo")))
        XCTAssertThrowsError(try tool.validate(.init(query: "ok", maxResults: 0)))
        XCTAssertThrowsError(try tool.validate(.init(query: "ok", maxResults: 51)))
        XCTAssertNoThrow(try tool.validate(.init(query: "ok", mode: "deep", maxResults: 50)))
    }

    func testWebSearchToolOutputStaysBoundedValidJSON() throws {
        func result(_ index: Int, target: String, snippet: String) -> WebSearchResult {
            WebSearchResult(title: "Title \(index)", url: URL(string: target)!, snippet: snippet,
                            provider: .brave, citationID: String(repeating: "a", count: 12),
                            extraSnippets: [snippet], contentState: .searchMetadataOnly)
        }
        let long = String(repeating: "s", count: 5_000)
        let many = WebSearchResponse(query: "q",
                                     results: (0..<40).map { result($0, target: "https://example.com/p\($0)", snippet: long) },
                                     providersUsed: [.brave])
        let output = try WebSearchTool.output(many)
        XCTAssertLessThanOrEqual(output.summary.count, 4_096)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(output.summary.utf8)),
                         "the runtime 4096-prefix must never cut JSON")
        XCTAssertEqual(parsed["evidenceState"] as? String, "searchMetadataOnly")
        XCTAssertEqual(parsed["pageVerification"] as? String, "notFetched")
        let returned = parsed["returned"] as? Int ?? 0
        XCTAssertGreaterThan(returned, 0)
        XCTAssertEqual(parsed["available"] as? Int, 40)
        XCTAssertEqual(parsed["omittedResults"] as? Int, 40 - returned)
        XCTAssertEqual(parsed["truncated"] as? Bool, true)
        let entries = try XCTUnwrap(parsed["results"] as? [[String: Any]])
        XCTAssertEqual(entries.count, returned)
        for entry in entries {
            XCTAssertEqual(entry["snippetTruncated"] as? Bool, true)
            let target = try XCTUnwrap(entry["url"] as? String)
            XCTAssertTrue(target.hasPrefix("https://example.com/p"), "citation URL stays EXACT: \(target)")
        }
        // Oversize citation targets are OMITTED whole, never shortened.
        let hugeURL = "https://example.com/" + String(repeating: "x", count: 1_500)
        let withOversize = WebSearchResponse(query: "q", results: [result(0, target: hugeURL, snippet: "ok"),
                                                                  result(1, target: "https://example.com/keep", snippet: "ok")],
                                             providersUsed: [.brave])
        let omitted = try WebSearchTool.output(withOversize)
        let omittedPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(omitted.summary.utf8)) as? [String: Any])
        XCTAssertEqual(omittedPayload["omittedOversizeURLRows"] as? Int, 1)
        XCTAssertEqual(omittedPayload["available"] as? Int, 2)
        let urls = try XCTUnwrap(omittedPayload["results"] as? [[String: Any]]).map { $0["url"] as? String }
        XCTAssertEqual(urls, ["https://example.com/keep"], "the oversized row disappears whole; no broken citation")
        // Pathological tiny budget → explicit valid fallback page, never
        // silently-truncated JSON.
        let fallback = try WebSearchTool.output(withOversize, maximumCharacters: 600)
        let fallbackPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fallback.summary.utf8)) as? [String: Any])
        XCTAssertEqual(fallbackPayload["error"] as? String, "resultExceedsBudget")
        XCTAssertEqual(fallbackPayload["returned"] as? Int, 0)
        XCTAssertEqual(fallbackPayload["available"] as? Int, 2)
        XCTAssertEqual(fallbackPayload["truncated"] as? Bool, true)
    }

    func testBochaAISearchToolWiresSummaryThroughService() async throws {
        let server = try startFixture()
        server.register(path: "/ai") { connection in
            let received = (try? JSONSerialization.jsonObject(with: connection.request.body)) as? [String: Any]
            let summary = received?["summary"] as? Bool ?? false
            connection.sendHead(status: 200, headers: ["content-type": "application/json"])
            let quoted = summary ? "\"synthesized\"" : "\"none\""
            let payload = "{\"data\":{\"webPages\":{\"value\":[{\"name\":\"AI answer\",\"url\":\"https://example.com/src\",\"snippet\":\(quoted)}]}}}"
            connection.sendRaw(Data(payload.utf8))
        }
        let service = fixtureSearchService {
            [(providerConfig(.bochaWeb, "/ai", server: server), WebSearchCredential(values: ["apiKey": "k"]))]
        }
        let ai = BochaAISearchTool(service: service)
        let output = try await ai.execute(.init(query: "deep question", maxResults: 5), context: context())
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
        XCTAssertEqual(output.exitStatus, 0)
        let entries = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["snippet"] as? String, "synthesized",
                       "web.searchAI must send summary=true and the Bocha name/url keys normalize")
        XCTAssertEqual(payload["providers"] as? [String], ["bochaWeb"])
        let recorded = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: server.requests.first(where: { $0.path == "/ai" })!.body)) as? [String: Any])
        XCTAssertEqual(recorded["summary"] as? Bool, true)
        // web.search (summaryEnabled=false) is the same provider WITHOUT the
        // synthesis flag — the capability separation stays at the request
        // layer, exactly like the original iOS wiring.
        let plain = WebSearchTool(service: service)
        _ = try await plain.execute(.init(query: "plain question"), context: context())
        let secondBody = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: server.requests.filter { $0.path == "/ai" }.last!.body)) as? [String: Any])
        XCTAssertEqual(secondBody["summary"] as? Bool, false)
    }

    // MARK: - 9. Privacy-audit invariants (ephemerality) survive the mirror

    func testServicesKeepEphemeralNoCookieNoCredentialState() throws {
        // The privacy-audit assertions on the INTERNAL `session` property:
        // a COPY of the caller configuration with cookie/credential storage
        // detached — identical hardening on both platform branches (Apple
        // original construction; Android router session built from the SAME
        // copied configuration).
        for allowsPrivate in [false, true] {
            let dirty = URLSessionConfiguration.default
            dirty.httpShouldSetCookies = true
            dirty.httpCookieStorage = HTTPCookieStorage.shared
            let service = HTTPRequestService(configuration: dirty, allowsPrivateNetwork: allowsPrivate)
            let held = try XCTUnwrap(service.session.configuration)
            XCTAssertEqual(held.httpShouldSetCookies, false)
            XCTAssertNil(held.httpCookieStorage)
            XCTAssertNil(held.urlCredentialStorage)
            XCTAssertFalse(service.session === URLSession.shared, "no shared-session inheritance")
        }
    }
}
#endif
