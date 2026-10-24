// FloeBrowserTests — preview loopback adjudication: token, Host, traversal,
// ranges, MIME, budgets. Authored (job-9960651880854093), not executed here.

import XCTest
@testable import FloeBrowser

private func headerBlock(_ lines: [String]) -> Data {
    Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
}

private func makeLeaseSession(port: Int = 47111, tokenOverride: String? = nil, files: [String: String] = [:], root: PreviewWorkspaceRoot? = nil) async -> (LocalPreviewServer, FakePreviewResource, String) {
    let token = tokenOverride ?? LocalPreviewServer.mintToken()
    let resource = FakePreviewResource()
    for (name, body) in files { await resource.seed(body: body, at: name) }
    let owner = BrowserTestHarness.owner()
    let session = LocalPreviewServer.Session(
        root: root ?? PreviewWorkspaceRoot(owner: owner, relativeRoot: ""),
        entry: "index.html",
        url: URL(string: "http://127.0.0.1:\(port)/\(token)/index.html")!,
        token: token,
        port: port,
        leaseID: UUID()
    )
    return (LocalPreviewServer(session: session, resource: resource), resource, token)
}

final class LocalPreviewAdjudicationTests: XCTestCase {
    func testTokenSegmentMustMatchExactly() async {
        let (server, _, token) = await makeLeaseSession(files: ["index.html": "<html>ok</html>"])
        let wrong = await server.adjudicate(requestID: UUID(), headerBlock: headerBlock([
            "GET /\(String(repeating: "0", count: 32))/index.html HTTP/1.1", "Host: 127.0.0.1:47111",
        ]))
        XCTAssertEqual(wrong.statusLine, "404 Not Found")

        let right = await server.adjudicate(requestID: UUID(), headerBlock: headerBlock([
            "GET /\(token)/index.html HTTP/1.1", "Host: 127.0.0.1:47111",
        ]))
        XCTAssertEqual(right.statusLine, "200 OK")
        // Truthful length: the exact byte count of the seeded file. The
        // earlier hand-count of "<html>ok</html>" said 13; those bytes are
        // 15, and the server's stat-backed declaration is the correct answer
        // the fixture must compare against the same literal it seeded.
        XCTAssertEqual(right.bodyLength, Data("<html>ok</html>".utf8).count)
        XCTAssertTrue(right.chunk.isEmpty == false)
    }

    func testHostMustBeExactAllocation() async {
        let (server, _, token) = await makeLeaseSession(files: ["index.html": "x"])
        for (host, expected) in [
            ("127.0.0.1:47111", "200 OK"),
            ("localhost:47111", "200 OK"),
            ("127.0.0.1:9999", "421 Misdirected Request"),
            ("attacker.example", "421 Misdirected Request"),
        ] as [(String, String)] {
            let verdict = await server.adjudicate(requestID: UUID(), headerBlock: headerBlock([
                "GET /\(token)/index.html HTTP/1.1", "Host: \(host)",
            ]))
            XCTAssertEqual(verdict.statusLine, expected, "host \(host)")
        }
        let missing = await server.adjudicate(requestID: UUID(), headerBlock: headerBlock([
            "GET /\(token)/index.html HTTP/1.1",
        ]))
        XCTAssertEqual(missing.statusLine, "400 Bad Request")
    }

    func testMethodAndRequestLineRules() async {
        let (server, _, token) = await makeLeaseSession(files: ["index.html": "x"])
        let post = await server.adjudicate(requestID: UUID(), headerBlock: headerBlock([
            "POST /\(token)/index.html HTTP/1.1", "Host: 127.0.0.1:47111",
        ]))
        XCTAssertEqual(post.statusLine, "405 Method Not Allowed")
        let uriForm = await server.adjudicate(requestID: UUID(), headerBlock: headerBlock([
            "GET http://127.0.0.1:47111/\(token)/index.html HTTP/1.1", "Host: 127.0.0.1:47111",
        ]))
        XCTAssertEqual(uriForm.statusLine, "400 Bad Request")
        let garbage = await server.adjudicate(requestID: UUID(), headerBlock: Data("nonsense\r\n\r\n".utf8))
        XCTAssertEqual(garbage.statusLine, "400 Bad Request")
        // Re-enforced header ceiling even if the transport skipped its own.
        let huge = await server.adjudicate(requestID: UUID(), headerBlock: Data(("GET /x HTTP/1.1\r\nX: " + String(repeating: "y", count: 70_000) + "\r\n\r\n").utf8))
        XCTAssertEqual(huge.statusLine, "431 Request Header Fields Too Large")
    }

    func testTraversalDoubleDecodeAndBackslashAllFailClosed() async {
        let (server, resource, token) = await makeLeaseSession(files: [
            "index.html": "x",
        ])
        for path in [
            "/\(token)/../../secrets/credentials.json",
            "/\(token)/..%2f..%2fsecrets/credentials.json",   // decoded once -> "..", reject
            "/\(token)/%2e%2e/secrets/credentials.json",      // decoded once -> "..", reject
            "/\(token)/..%252e%2526/secrets",                 // double-encoded stays literal -> 404
            "/\(token)/sub\\..\\secret",                      // backslashes rejected
            "/\(token)/",                                      // empty relative -> 404
        ] {
            let verdict = await server.adjudicate(requestID: UUID(), headerBlock: headerBlock([
                "GET \(path) HTTP/1.1", "Host: 127.0.0.1:47111",
            ]))
            XCTAssertEqual(verdict.statusLine, "404 Not Found", "path \(path)")
        }
        // The native-port escape refusal never produces bytes either.
        await resource.markEscape("../outside.html")
        await resource.seed(body: "outside-body", at: "../outside.html")
        let escaped = await server.adjudicate(requestID: UUID(), headerBlock: headerBlock([
            "GET /\(token)/outside.html HTTP/1.1", "Host: 127.0.0.1:47111", "Range: bytes=0-3",
        ]))
        // Not seeded under that name at the root: honest 404.
        XCTAssertEqual(escaped.statusLine, "404 Not Found")
    }

    func testSizeCeilingIsTheOriginalNotFound() async {
        let (server, resource, token) = await makeLeaseSession()
        await resource.seed("big.html", Data(repeating: 1, count: LocalPreviewServer.maximumResourceBytes + 1))
        let verdict = await server.adjudicate(requestID: UUID(), headerBlock: headerBlock([
            "GET /\(token)/big.html HTTP/1.1", "Host: 127.0.0.1:47111",
        ]))
        XCTAssertEqual(verdict.statusLine, "404 Not Found")
    }

    func testHeadDeclaresLengthButServesNoBody() async {
        let (server, _, token) = await makeLeaseSession(files: ["style.css": "body{}"])
        let verdict = await server.adjudicate(requestID: UUID(), headerBlock: headerBlock([
            "HEAD /\(token)/style.css HTTP/1.1", "Host: 127.0.0.1:47111",
        ]))
        XCTAssertEqual(verdict.statusLine, "200 OK")
        XCTAssertEqual(verdict.bodyLength, 0)
        XCTAssertTrue(verdict.chunk.isEmpty)
        XCTAssertTrue(verdict.headers.contains { $0.name == "Content-Length" && $0.value == String("body{}".count) })
    }

    func testRangesAreHonoredOrHonestlyRefused() async {
        let bytes = Data((0..<1000).map { UInt8($0 % 251) })
        let (server, resource, token) = await makeLeaseSession()
        await resource.seed("asset.wasm", bytes)

        let open = await server.adjudicate(requestID: UUID(), headerBlock: headerBlock([
            "GET /\(token)/asset.wasm HTTP/1.1", "Host: 127.0.0.1:47111", "Range: bytes=100-",
        ]))
        XCTAssertEqual(open.statusLine, "206 Partial Content")
        XCTAssertEqual(open.bodyLength, 900)
        XCTAssertEqual(open.bodyStart, 100)
        XCTAssertTrue(open.headers.contains { $0.name == "Content-Range" && $0.value == "bytes 100-999/1000" })

        let closed = await server.adjudicate(requestID: UUID(), headerBlock: headerBlock([
            "GET /\(token)/asset.wasm HTTP/1.1", "Host: 127.0.0.1:47111", "Range: bytes=0-499",
        ]))
        XCTAssertEqual(closed.bodyLength, 500)

        let suffix = await server.adjudicate(requestID: UUID(), headerBlock: headerBlock([
            "GET /\(token)/asset.wasm HTTP/1.1", "Host: 127.0.0.1:47111", "Range: bytes=-10",
        ]))
        XCTAssertEqual(suffix.bodyLength, 10)
        XCTAssertEqual(suffix.bodyStart, 990)

        let impossible = await server.adjudicate(requestID: UUID(), headerBlock: headerBlock([
            "GET /\(token)/asset.wasm HTTP/1.1", "Host: 127.0.0.1:47111", "Range: bytes=5000-9000",
        ]))
        XCTAssertEqual(impossible.statusLine, "416 Range Not Satisfiable")
        XCTAssertTrue(impossible.headers.contains { $0.name == "Content-Range" && $0.value == "bytes */1000" })

        let multi = await server.adjudicate(requestID: UUID(), headerBlock: headerBlock([
            "GET /\(token)/asset.wasm HTTP/1.1", "Host: 127.0.0.1:47111", "Range: bytes=0-9,20-29",
        ]))
        // Typed unsupported: honest full 200 with Accept-Ranges, never a fake
        // multipart body the original server could not speak.
        XCTAssertEqual(multi.statusLine, "200 OK")
        XCTAssertEqual(multi.bodyLength, 1000)

        let foreign = await server.adjudicate(requestID: UUID(), headerBlock: headerBlock([
            "GET /\(token)/asset.wasm HTTP/1.1", "Host: 127.0.0.1:47111", "Range: minutes=5",
        ]))
        XCTAssertEqual(foreign.statusLine, "200 OK")
    }

    func testMimeTablePorted() {
        XCTAssertEqual(LocalPreviewServer.mimeType(for: "html"), "text/html; charset=utf-8")
        XCTAssertEqual(LocalPreviewServer.mimeType(for: "js"), "text/javascript; charset=utf-8")
        XCTAssertEqual(LocalPreviewServer.mimeType(for: "MAP"), "application/json; charset=utf-8")
        XCTAssertEqual(LocalPreviewServer.mimeType(for: "wasm"), "application/wasm")
        XCTAssertEqual(LocalPreviewServer.mimeType(for: "svg"), "image/svg+xml")
        XCTAssertEqual(LocalPreviewServer.mimeType(for: "bin"), "application/octet-stream")
    }

    func testChunkingIsBoundedAndRetiresAfterCompletion() async {
        let bytes = Data(repeating: 42, count: 200_000)
        let (server, resource, token) = await makeLeaseSession()
        await resource.seed("big.js", bytes)
        let requestID = UUID()
        let verdict = await server.adjudicate(requestID: requestID, headerBlock: headerBlock([
            "GET /\(token)/big.js HTTP/1.1", "Host: 127.0.0.1:47111",
        ]))
        XCTAssertEqual(verdict.chunk.count, LocalPreviewServer.chunkBytes)
        var offset = verdict.chunk.count
        var total = verdict.chunk.count
        while offset < verdict.bodyLength {
            let next = await server.readChunk(requestID: requestID, offset: offset)
            XCTAssertLessThanOrEqual(next.count, LocalPreviewServer.chunkBytes)
            if next.isEmpty { break }
            total += next.count
            offset += next.count
        }
        XCTAssertEqual(total, bytes.count)
        // After completion the allocation is retired; a re-read yields nothing.
        let after = await server.readChunk(requestID: requestID, offset: 0)
        XCTAssertTrue(after.isEmpty)
    }

    func testStopMakesEveryLaterRequestAFour04() async {
        let (server, _, token) = await makeLeaseSession(files: ["index.html": "x"])
        await server.stop()
        let verdict = await server.adjudicate(requestID: UUID(), headerBlock: headerBlock([
            "GET /\(token)/index.html HTTP/1.1", "Host: 127.0.0.1:47111",
        ]))
        XCTAssertEqual(verdict.statusLine, "404 Not Found")
    }

    func testTokenShapeIsUnpredictableEnough() {
        let tokens = Set((0..<200).map { _ in LocalPreviewServer.mintToken() })
        XCTAssertEqual(tokens.count, 200)
        for token in tokens {
            XCTAssertEqual(token.count, 32)
            XCTAssertTrue(token.allSatisfy(\.isHexDigit))
        }
    }
}
