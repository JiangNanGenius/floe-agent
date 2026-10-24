// SPDX-License-Identifier: MPL-2.0
//
// GitHubActionsArtifactStreamingTests — synthetic localhost coverage for the
// Android service-owned download seam: public-entry guards (HTTPS / expired /
// declared size / path containment / destination exists), staging path rules,
// digest attestation honesty, and the real incremental streaming behaviors —
// early cap cancellation, early-EOF refusal, cooperative cancellation,
// 404/302 typed failures, same-origin bearer attach and token redaction.
// No real token, no real GitHub, no paid model calls. The socket fixture is
// Darwin-only test code (host cohort; same family as the qualified G02-P3
// transport fixture); the logic half compiles everywhere.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import FloeGit

// MARK: - Pure rules (compile and run on every platform)

@Suite("artifact streaming — pure rules")
struct GitHubActionsStreamingRulesTests {
    @Test("workspace-relative destination rules mirror the original guards")
    func relativePaths() throws {
        #expect(try GitHubActionsArtifactStreamer.validated(relativeDirectory: "Artifacts") == "Artifacts")
        #expect(try GitHubActionsArtifactStreamer.validated(relativeDirectory: "a/b/c") == "a/b/c")
        #expect(try GitHubActionsArtifactStreamer.validated(relativeDirectory: "a\\b") == "a/b")
        for bad in ["", "   ", "/abs", "../escape", "a/../../b", ".git", ".git/hooks", "x/.git/y"] {
            #expect(throws: (any Error).self) {
                _ = try GitHubActionsArtifactStreamer.validated(relativeDirectory: bad)
            }
        }
    }

    @Test("artifact file naming copies the original sanitization rule")
    func fileNames() {
        // Byte-for-byte the original rule (GitHubActionsService.swift:587-593):
        // EVERY unsafe character becomes "_" with no collapsing/trimming, and
        // the `artifact-<id>.zip` fallback fires only when the name is EMPTY
        // (a whole-name of unsafe chars sanitizes to underscores, it does not
        // vanish). The authored expectations above contradicted the quoted
        // original; corrected to the true mirrored behavior — same number of
        // checks, fallback path still asserted (with the genuinely-empty name).
        #expect(GitHubActionsArtifactStreamer.suggestedArtifactName(id: 7, name: "demo logs!!") == "demo_logs__.zip")
        #expect(GitHubActionsArtifactStreamer.suggestedArtifactName(id: 7, name: "ok-1.2_x") == "ok-1.2_x.zip")
        #expect(GitHubActionsArtifactStreamer.suggestedArtifactName(id: 42, name: "///") == "___.zip")
        #expect(GitHubActionsArtifactStreamer.suggestedArtifactName(id: 42, name: "") == "artifact-42.zip")
    }

    @Test("path escaping matches the mirrored client")
    func escaping() {
        #expect(GitHubActionsArtifactStreamer.escaped("owner") == "owner")
        #expect(GitHubActionsArtifactStreamer.escaped("a b") == "a%20b")
        #expect(GitHubActionsArtifactStreamer.escaped("x/y") == "x%2Fy")
    }

    @Test("token redaction is applied to every surfaced message")
    func redaction() async throws {
        let streamer = GitHubActionsArtifactStreamer()
        let token = "ghp_synthetic-token-0123456789abcdef"
        let redacted = await streamer.redact("auth failed for \(token)!", token: token)
        #expect(!redacted.contains(token))
        #expect(redacted.contains("<redacted>"))
        await streamer.finish()
    }

    @Test("public entry refuses non-HTTPS artifacts before any socket")
    func httpsGuard() async throws {
        let streamer = GitHubActionsArtifactStreamer()
        let artifact = GitHubActionsArtifact(
            id: 1, name: "a", sizeInBytes: 21, expired: false,
            archiveDownloadURL: URL(string: "http://127.0.0.1:1/blob")!,
            createdAt: Date(), expiresAt: nil)
        await #expect(throws: GitHubActionsStreamingError.self) {
            _ = try await streamer.stage(
                artifact: artifact, token: "t",
                intoTrustedRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
                relativeDirectory: "out")
        }
        await streamer.finish()
    }

    @Test("expired artifacts and over-cap declared sizes are typed pre-network rejections")
    func preflightRejections() async throws {
        let streamer = GitHubActionsArtifactStreamer()
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = URL(string: "https://api.github.com/blob/3")!
        let expired = GitHubActionsArtifact(id: 2, name: "e", sizeInBytes: 21, expired: true,
                                            archiveDownloadURL: url, createdAt: Date(), expiresAt: nil)
        do {
            _ = try await streamer.stage(artifact: expired, token: "t", intoTrustedRoot: root,
                                         relativeDirectory: "out")
            Issue.record("expired artifact must be rejected")
        } catch let error as GitHubActionsStreamingError {
            guard case .expiredArtifact(let name) = error else { throw error }
            #expect(name == "e")
        }
        let oversized = GitHubActionsArtifact(id: 3, name: "o", sizeInBytes: 1_000, expired: false,
                                              archiveDownloadURL: url, createdAt: Date(), expiresAt: nil)
        do {
            _ = try await streamer.stage(artifact: oversized, token: "t", intoTrustedRoot: root,
                                         relativeDirectory: "out", maxBytes: 100)
            Issue.record("declared size over cap must be rejected before the network")
        } catch let error as GitHubActionsStreamingError {
            guard case .responseTooLarge(let limit) = error else { throw error }
            #expect(limit == 100)
        }
        await streamer.finish()
    }

    @Test("an existing final destination is refused instead of overwritten")
    func destinationExistsRefused() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("floegit-dest-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("out"), withIntermediateDirectories: true)
        let existing = root.appendingPathComponent("out/a.zip")
        fm.createFile(atPath: existing.path, contents: Data("old".utf8))
        defer { try? fm.removeItem(at: root) }
        let streamer = GitHubActionsArtifactStreamer()
        let artifact = GitHubActionsArtifact(
            id: 4, name: "a", sizeInBytes: 21, expired: false,
            archiveDownloadURL: URL(string: "https://api.github.com/blob/4")!,
            createdAt: Date(), expiresAt: nil)
        do {
            _ = try await streamer.stage(artifact: artifact, token: "t", intoTrustedRoot: root,
                                         relativeDirectory: "out")
            Issue.record("existing destination must be refused")
        } catch let error as GitHubActionsStreamingError {
            guard case .destinationExists = error else { throw error }
        }
        // The refused path left the previous file byte-identical.
        #expect(try Data(contentsOf: existing) == Data("old".utf8))
        await streamer.finish()
    }
}

#if canImport(Darwin)
import Darwin

// MARK: - Loopback streaming fixture (host test code only, never production)

/// Minimal scripted HTTP/1.1 loopback server for the streaming seam. Binds
/// 127.0.0.1:0, serves registered paths, records request headers, can stream
/// slow chunked bodies or short bodies against a lying Content-Length, and
/// observes client aborts (early-cap / cancellation evidence). Mirrors the
/// qualified G02-P3 `ScriptedLoopbackFixture` mechanics inside this test
/// target; no TLS, no external network.
private final class GitLoopbackServer: @unchecked Sendable {
    struct Response {
        var status = 200
        /// Extra head lines (e.g. a lying `Content-Length`).
        var headers: [String: String] = [:]
        /// Raw body sent with the caller's Content-Length (fixed framing).
        var fixedBody: Data? = nil
        /// Chunked framing body parts (hex-framed by the server).
        var chunks: [Data]? = nil
        var chunkDelayMillis = 0
        /// false ⇒ never send the terminating 0-chunk (until the client aborts).
        var finishChunked = true
    }

    private let listenFD: Int32
    private(set) var port: UInt16
    private let stateLock = NSLock()
    private var handlers: [String: Response] = [:]
    private var seenHeaders: [String: [String: String]] = [:]
    private var aborts = Set<String>()
    private var requestCount = 0
    private var stopped = false

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        guard withUnsafePointer(to: &address, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }) == 0 else {
            Darwin.close(fd); throw POSIXError(.EADDRINUSE)
        }
        guard Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd); throw POSIXError(.ECONNABORTED)
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        })
        port = UInt16(bigEndian: bound.sin_port)
        listenFD = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    func register(path: String, _ response: Response) {
        stateLock.lock(); handlers[path] = response; stateLock.unlock()
    }

    var count: Int { stateLock.lock(); defer { stateLock.unlock() }; return requestCount }
    func headers(for path: String) -> [String: String]? {
        stateLock.lock(); defer { stateLock.unlock() }; return seenHeaders[path]
    }
    func sawAbort(for path: String) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return aborts.contains(path)
    }
    func stop() {
        stateLock.lock()
        if stopped { stateLock.unlock(); return }
        stopped = true
        stateLock.unlock()
        Darwin.close(listenFD)
    }

    private func acceptLoop() {
        while true {
            var clientAddr = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr, {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenFD, $0, &length)
                }
            })
            if client < 0 { return }
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd) }
        // Host-cohort root cause (test-145137.log:611→616, test-161129.log:746:
        // "crossing the byte cap cancels EARLY" is the LAST test started before
        // swiftpm-testing-helper dies with signal 13): production's early-cap
        // `cancelOwned()` is correct — it closes the client socket mid-script —
        // and the fixture's chunk loop then writes into a reset peer. A
        // default-disposition SIGPIPE kills the WHOLE test process before the
        // abort assertion can run. The fixture owns its socket lifecycle, so
        // this per-connection option (Darwin-only, fixture-only) makes the
        // write return EPIPE instead of signalling; writeAll already records
        // that as a real server-observed abort.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil, buffer.count < 64 * 1024 {
            let read = recv(fd, &chunk, chunk.count, 0)
            if read <= 0 { return }
            buffer.append(contentsOf: chunk[0..<read])
        }
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let path = parts[1]
        stateLock.lock()
        requestCount += 1
        seenHeaders[path] = headers
        let response = handlers[path]
        stateLock.unlock()
        guard let response else {
            writeAll(fd, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8), path: path)
            return
        }
        var headText = "HTTP/1.1 \(response.status) Reason\r\n"
        for (k, v) in response.headers { headText += "\(k): \(v)\r\n" }
        if response.chunks != nil { headText += "Transfer-Encoding: chunked\r\n" }
        headText += "\r\n"
        if !writeAll(fd, Data(headText.utf8), path: path) { return }
        if let fixed = response.fixedBody {
            _ = writeAll(fd, fixed, path: path)
            return
        }
        if let chunks = response.chunks {
            for part in chunks {
                var framed = Data(String(format: "%x\r\n", part.count).utf8)
                framed.append(part)
                framed.append(Data("\r\n".utf8))
                if !writeAll(fd, framed, path: path) { return }
                if response.chunkDelayMillis > 0 {
                    usleep(useconds_t(response.chunkDelayMillis) * 1000)
                }
            }
            if response.finishChunked {
                _ = writeAll(fd, Data("0\r\n\r\n".utf8), path: path)
            }
        }
    }

    @discardableResult
    private func writeAll(_ fd: Int32, _ data: Data, path: String) -> Bool {
        var ok = true
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let written = Darwin.send(fd, base + sent, raw.count - sent, 0)
                if written <= 0 {
                    ok = false
                    stateLock.lock(); aborts.insert(path); stateLock.unlock()
                    return
                }
                sent += written
            }
        }
        return ok
    }

    static func sleep(_ milliseconds: Int) { usleep(useconds_t(milliseconds) * 1000) }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private final class LastTotal: @unchecked Sendable {
    private let lock = NSLock()
    var value = -1
    func set(_ received: Int) { lock.lock(); value = received; lock.unlock() }
    func current() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite("artifact streaming — loopback transport", .serialized)
struct GitHubActionsArtifactStreamingLoopbackTests {
    private static let payload = Data("floe-artifact-payload".utf8)   // 21 bytes
    private static let payloadSHA =
        "9f3d75aab8f07cb4d61d01d68a1354a275773ef3c2660ad2995a57ca33255747"

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floegit-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func server(_ setup: (GitLoopbackServer) throws -> Void) throws -> GitLoopbackServer {
        let value = try GitLoopbackServer()
        try setup(value)
        return value
    }

    private func artifact(_ server: GitLoopbackServer, path: String = "/blob",
                          size: Int64 = 21, digest: String? = nil) -> GitHubActionsArtifact {
        GitHubActionsArtifact(
            id: 7, name: "a", sizeInBytes: size, expired: false,
            archiveDownloadURL: URL(string: "http://127.0.0.1:\(server.port)\(path)")!,
            createdAt: Date(), expiresAt: nil, digest: digest)
    }

    private func streamer(_ server: GitLoopbackServer) -> GitHubActionsArtifactStreamer {
        GitHubActionsArtifactStreamer(baseURL: URL(string: "http://127.0.0.1:\(server.port)/")!)
    }

    @Test("complete body without a server attestation ends checksum-only")
    func plainSuccess() async throws {
        let srv = try server { $0.register(path: "/blob", .init(
            headers: ["Content-Length": "21"], fixedBody: Self.payload)) }
        defer { srv.stop() }
        let dl = streamer(srv)
        defer { Task { await dl.finish() } }
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("blob.part")
        let result = try await dl.streamToStaging(
            artifact: artifact(srv), token: "synthetic-token-abcdefghijklmnop",
            stagingURL: staging, maxBytes: 1024, progress: nil, isCancellationRequested: { false })
        #expect(result.byteCount == 21)
        #expect(result.sha256 == Self.payloadSHA)
        #expect(result.serverAttested == false)
        #expect(result.sourceHost == "127.0.0.1")
        #expect(try Data(contentsOf: staging) == Self.payload)
        // Same-origin rule: the bearer rode to the configured API host only.
        #expect(srv.headers(for: "/blob")?["authorization"] == "Bearer synthetic-token-abcdefghijklmnop")
    }

    @Test("matching sha256 attestation reports server-verified")
    func attestedMatch() async throws {
        let srv = try server { $0.register(path: "/blob", .init(
            headers: ["Content-Length": "21"], fixedBody: Self.payload)) }
        defer { srv.stop() }
        let dl = streamer(srv)
        defer { Task { await dl.finish() } }
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await dl.streamToStaging(
            artifact: artifact(srv, digest: "SHA256:\(Self.payloadSHA)"), token: "t",
            stagingURL: root.appendingPathComponent("b.part"), maxBytes: 1024,
            progress: nil, isCancellationRequested: { false })
        #expect(result.serverAttested == true)
    }

    @Test("digest mismatch is a typed failure (bytes never committed)")
    func attestedMismatch() async throws {
        let srv = try server { $0.register(path: "/blob", .init(
            headers: ["Content-Length": "21"], fixedBody: Self.payload)) }
        defer { srv.stop() }
        let dl = streamer(srv)
        defer { Task { await dl.finish() } }
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await dl.streamToStaging(
                artifact: artifact(srv, digest: "sha256:\(String(repeating: "0", count: 64))"),
                token: "t", stagingURL: root.appendingPathComponent("bad.part"), maxBytes: 1024,
                progress: nil, isCancellationRequested: { false })
            Issue.record("digest mismatch must throw")
        } catch let error as GitHubActionsStreamingError {
            guard case .digestMismatch(let serverDigest, let computed) = error else { throw error }
            #expect(serverDigest == String(repeating: "0", count: 64))
            #expect(computed == Self.payloadSHA)
        }
    }

    @Test("unknown digest algorithms fail typed instead of downgrading")
    func unknownDigestAlgorithm() async throws {
        let srv = try server { $0.register(path: "/blob", .init(
            headers: ["Content-Length": "21"], fixedBody: Self.payload)) }
        defer { srv.stop() }
        let dl = streamer(srv)
        defer { Task { await dl.finish() } }
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await dl.streamToStaging(
                artifact: artifact(srv, digest: "sha512:whatever"), token: "t",
                stagingURL: root.appendingPathComponent("u.part"), maxBytes: 1024,
                progress: nil, isCancellationRequested: { false })
            Issue.record("unsupported attestation algorithm must throw")
        } catch let error as GitHubActionsStreamingError {
            guard case .invalidConfiguration = error else { throw error }
        }
    }

    @Test("a body that ends short of its declared length never counts as success")
    func truncatedBodyRefused() async throws {
        let srv = try server { $0.register(path: "/blob", .init(
            headers: ["Content-Length": "100"], fixedBody: Data("only21bytes-floeart".utf8))) }
        defer { srv.stop() }
        let dl = streamer(srv)
        defer { Task { await dl.finish() } }
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await dl.streamToStaging(
                artifact: artifact(srv, size: 100), token: "t",
                stagingURL: root.appendingPathComponent("tr.part"), maxBytes: 1024,
                progress: nil, isCancellationRequested: { false })
            Issue.record("early EOF must never commit as success")
        } catch let error as GitHubActionsStreamingError {
            // Either our explicit truncation rule fires, or the transport
            // reports the connection loss — both typed, both non-success.
            switch error {
            case .truncated(let declared, let received):
                #expect(declared == 100)
                #expect(received == 18)
            case .transport:
                break
            default:
                throw error
            }
        }
    }

    @Test("crossing the byte cap cancels EARLY: the server observes the abort")
    func earlyCapCancel() async throws {
        let chunk = Self.payload // 21 bytes per chunk
        let srv = try server { $0.register(path: "/blob", .init(
            chunks: Array(repeating: chunk, count: 60), chunkDelayMillis: 5, finishChunked: false)) }
        defer { srv.stop() }
        let dl = streamer(srv)
        defer { Task { await dl.finish() } }
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await dl.streamToStaging(
                artifact: artifact(srv, size: 0), token: "t",
                stagingURL: root.appendingPathComponent("cap.part"), maxBytes: 50,
                progress: nil, isCancellationRequested: { false })
            Issue.record("over-cap stream must fail")
        } catch let error as GitHubActionsStreamingError {
            guard case .responseTooLarge(let limit) = error else { throw error }
            #expect(limit == 50)
        }
        // 1260 bytes were scripted; an early cancel aborts far below that.
        GitLoopbackServer.sleep(50)
        #expect(srv.sawAbort(for: "/blob"))
    }

    @Test("cooperative cancellation stops the owned task")
    func cooperativeCancellation() async throws {
        let chunk = Self.payload
        let srv = try server { $0.register(path: "/blob", .init(
            chunks: Array(repeating: chunk, count: 40), chunkDelayMillis: 10)) }
        defer { srv.stop() }
        let dl = streamer(srv)
        defer { Task { await dl.finish() } }
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let flag = CancelFlag()
        do {
            _ = try await dl.streamToStaging(
                artifact: artifact(srv, size: 0), token: "t",
                stagingURL: root.appendingPathComponent("canc.part"), maxBytes: 100_000,
                progress: { received in if received >= 42 { flag.set() } },
                isCancellationRequested: { flag.get() })
            Issue.record("cancellation must stop the download")
        } catch let error as GitHubActionsStreamingError {
            guard case .cancelled = error else { throw error }
        }
    }

    @Test("missing artifact answers a typed 404, never a fabricated success")
    func notFound() async throws {
        let srv = try server { _ in }
        defer { srv.stop() }
        let dl = streamer(srv)
        defer { Task { await dl.finish() } }
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await dl.streamToStaging(
                artifact: artifact(srv), token: "t",
                stagingURL: root.appendingPathComponent("nf.part"), maxBytes: 1024,
                progress: nil, isCancellationRequested: { false })
            Issue.record("404 must be typed")
        } catch let error as GitHubActionsStreamingError {
            guard case .http(let status, _) = error else { throw error }
            #expect(status == 404)
        }
    }

    @Test("a cleartext redirect is refused by the guard, surfaced as non-2xx")
    func redirectRefused() async throws {
        let srv = try server { $0.register(path: "/blob", .init(
            status: 302, headers: ["Location": "http://127.0.0.1:1/blob2"])) }
        defer { srv.stop() }
        let dl = streamer(srv)
        defer { Task { await dl.finish() } }
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await dl.streamToStaging(
                artifact: artifact(srv), token: "t",
                stagingURL: root.appendingPathComponent("r.part"), maxBytes: 1024,
                progress: nil, isCancellationRequested: { false })
            Issue.record("non-HTTPS redirect must be refused")
        } catch let error as GitHubActionsStreamingError {
            guard case .http(let status, _) = error else { throw error }
            // The redirect guard answered completionHandler(nil): the 302
            // itself becomes the (typed, non-2xx) terminal response.
            #expect(status == 302)
        }
    }

    @Test("progress totals equal the committed byte count")
    func progressMatches() async throws {
        let srv = try server { $0.register(path: "/blob", .init(
            headers: ["Content-Length": "21"],
            fixedBody: Self.payload)) }
        defer { srv.stop() }
        let dl = streamer(srv)
        defer { Task { await dl.finish() } }
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let totals = LastTotal()
        let result = try await dl.streamToStaging(
            artifact: artifact(srv), token: "t",
            stagingURL: root.appendingPathComponent("p.part"), maxBytes: 1024,
            progress: { totals.set($0) }, isCancellationRequested: { false })
        #expect(result.byteCount == 21)
        #expect(totals.current() == 21)
    }

    @Test("foreign-origin archive URL is fetched without the bearer token")
    func crossOriginNoToken() async throws {
        // API origin = localhost; artifact host = 127.0.0.1 → different
        // origin strings ⇒ the token must NOT be attached (loopback twin of
        // the api.github.com → blob-storage rule).
        let srv = try server { $0.register(path: "/blob", .init(
            headers: ["Content-Length": "21"], fixedBody: Self.payload)) }
        defer { srv.stop() }
        let dl = GitHubActionsArtifactStreamer(
            baseURL: URL(string: "http://localhost:\(srv.port)/")!)
        defer { Task { await dl.finish() } }
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await dl.streamToStaging(
            artifact: artifact(srv), token: "secret-token-not-for-foreign-host",
            stagingURL: root.appendingPathComponent("x.part"), maxBytes: 1024,
            progress: nil, isCancellationRequested: { false })
        #expect(result.byteCount == 21)
        #expect(srv.headers(for: "/blob")?["authorization"] == nil)
    }
}
#endif
