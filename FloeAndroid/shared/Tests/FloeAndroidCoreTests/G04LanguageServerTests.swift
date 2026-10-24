// SPDX-License-Identifier: MPL-2.0
// Meaningful synthetic tests for the G04 LSP stack (job-dda32d23d55e4460):
// real Content-Length framing over fragmented/coalesced pages, framing
// contamination refusal, versioned document fences, completion/diagnostics
// mapping with exact revision fences, $/cancelRequest semantics, honest
// workspace/applyEdit all-or-nothing + partial truth, and the typed
// availability states (no silent fake servers). Frames written by the
// client are PARSED back (never substring-matched), so JSON formatting
// differences cannot mask or fake an assertion.
import XCTest
@testable import FloeAndroidCore

// MARK: - Fakes

final class FakeAuthority: G04WorkspaceDocumentAuthority, @unchecked Sendable {
    struct Doc {
        var path: String
        var revision: Int
        var text: String
    }
    private let lock = NSLock()
    var docs: [UUID: Doc] = [:]
    var editCalls: [(documentID: UUID, expectedRevision: String, location: Int, length: Int)] = []
    var failEditFor: UUID?

    func seed(_ id: UUID, path: String, revision: Int = 1, text: String) {
        lock.lock(); docs[id] = Doc(path: path, revision: revision, text: text); lock.unlock()
    }
    func tabs(taskID: UUID, workspaceID: UUID) async throws -> [G04DocumentTab] {
        lock.g04Locked {
            docs.map { (id, doc) in
                G04DocumentTab(documentID: id, relativePath: doc.path, revision: "rev-\(doc.revision)",
                               utf8Bytes: doc.text.utf8.count, dirty: false)
            }
        }
    }
    func open(taskID: UUID, workspaceID: UUID, relativePath: String) async throws -> G04DocumentTab {
        try lock.g04Locked {
            guard let entry = docs.first(where: { $0.value.path == relativePath }) else {
                throw G04DocumentAuthorityError.missingDocument
            }
            return G04DocumentTab(documentID: entry.key, relativePath: entry.value.path,
                                  revision: "rev-\(entry.value.revision)",
                                  utf8Bytes: entry.value.text.utf8.count, dirty: false)
        }
    }
    func fullText(taskID: UUID, workspaceID: UUID, documentID: UUID, revision: String) async throws -> String {
        try lock.g04Locked {
            guard let doc = docs[documentID] else { throw G04DocumentAuthorityError.missingDocument }
            guard "rev-\(doc.revision)" == revision else { throw G04DocumentAuthorityError.staleRevision }
            return doc.text
        }
    }
    func edit(taskID: UUID, workspaceID: UUID, documentID: UUID, expectedRevision: String,
              location: Int, length: Int, replacement: String) async throws -> G04DocumentAppliedEdit {
        return try lock.g04Locked {
            editCalls.append((documentID, expectedRevision, location, length))
            let shouldFail = failEditFor == documentID
            guard var doc = docs[documentID], !shouldFail else {
                if shouldFail { throw G04DocumentAuthorityError.staleRevision }
                throw G04DocumentAuthorityError.missingDocument
            }
            guard "rev-\(doc.revision)" == expectedRevision else {
                throw G04DocumentAuthorityError.staleRevision
            }
            let units = Array(doc.text.utf16)
            guard location >= 0, length >= 0, location + length <= units.count else {
                throw G04DocumentAuthorityError.invalidRange
            }
            var updated = Array(doc.text.utf16)
            updated.replaceSubrange(location..<(location + length),
                                    with: Array(replacement.utf16))
            doc.text = String(utf16CodeUnits: updated, count: updated.count)
            doc.revision += 1
            docs[documentID] = doc
            return G04DocumentAppliedEdit(documentID: documentID, relativePath: doc.path,
                                          previousRevision: expectedRevision, newRevision: "rev-\(doc.revision)")
        }
    }
}

final class FakeLspTransport: G04LspSessionTransport, @unchecked Sendable {
    private let lock = NSLock()
    var startedCommand: String?
    var written = Data()
    var readQueue: [G04LspPage] = []
    var stopRequested = false
    var closed = false
    var startError: Error?
    /// Synthetic owned-work receipt state (deletion fence / retirement).
    var cancellationRequested = false

    func enqueue(_ data: Data) {
        lock.lock(); readQueue.append(G04LspPage(bytes: data, terminal: false)); lock.unlock()
    }
    func enqueueTerminal(exit: Int32?) {
        lock.lock(); readQueue.append(G04LspPage(bytes: Data(), terminal: true, exitCode: exit)); lock.unlock()
    }
    var allWritten: Data { lock.lock(); defer { lock.unlock() }; return written }

    func start(command: String) async throws -> String {
        if let startError { throw startError }
        lock.g04Locked { startedCommand = command }
        return "lsp-session-1"
    }
    func write(_ bytes: Data) async throws -> G04LspPage {
        lock.g04Locked {
            written.append(bytes)
            return readQueue.isEmpty ? G04LspPage(bytes: Data(), terminal: false) : readQueue.removeFirst()
        }
    }
    func read() async throws -> G04LspPage {
        lock.g04Locked {
            if !readQueue.isEmpty { return readQueue.removeFirst() }
            return G04LspPage(bytes: Data(), terminal: false)
        }
    }
    func requestStop() async { lock.g04Locked { stopRequested = true } }
    func close() async { lock.g04Locked { closed = true } }
    func isCancellationRequested() async -> Bool {
        lock.g04Locked { cancellationRequested }
    }
}

/// Parse the client's written stream back into JSON-RPC objects (the
/// framing is shared, so what the client SENT must be what the server sees).
private func parsedClientFrames(_ data: Data) throws -> [[String: Any]] {
    let parser = G04LspFrameParser()
    parser.feed(data)
    var frames: [[String: Any]] = []
    while true {
        switch parser.nextFrame() {
        case .failure: return frames
        case .success(nil): return frames
        case .success(let body?):
            if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                frames.append(object)
            }
        }
    }
}

private func clientMethodRequest(_ transport: FakeLspTransport, method: String) throws -> [String: Any]? {
    try parsedClientFrames(transport.allWritten).first {
        ($0["method"] as? String) == method
    }
}

final class RecordingLspSink: G04TerminalEventSink, @unchecked Sendable {
    private let lock = NSLock()
    var controls: [[String: Any]] = []
    var outputs: [(token: String, seq: Int64, bytes: Data)] = []
    func emitControl(_ object: [String: Any]) { lock.lock(); controls.append(object); lock.unlock() }
    func emitOutput(sessionToken: String, seq: Int64, bytes: Data) {
        lock.lock(); outputs.append((sessionToken, seq, bytes)); lock.unlock()
    }
    func events(type: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return controls.filter { ($0["type"] as? String) == type }
    }
    func reply(requestID: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return controls.first { ($0["type"] as? String) == "actionReply" && ($0["requestID"] as? String) == requestID }
    }
}

private func frame(_ object: [String: Any]) throws -> Data {
    try G04LspFrameWriter.frame(object)
}

final class G04LanguageServerTests: XCTestCase {

    // MARK: - Framing

    func testWriterIsCanonicalAndBounded() throws {
        let data = try frame(["jsonrpc": "2.0", "id": 1, "method": "ping"])
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return XCTFail("missing header separator") }
        let header = String(decoding: data.subdata(in: 0..<range.lowerBound), as: UTF8.self)
        XCTAssertTrue(header.hasPrefix("Content-Length: "))
        let declared = Int(header.dropFirst("Content-Length: ".count))!
        XCTAssertEqual(data.count - range.upperBound, declared)
        XCTAssertThrowsError(try G04LspFrameWriter.frame(body: Data(repeating: 0x41,
            count: G04LspFramingLimits.maximumBodyBytes + 1)))
        XCTAssertThrowsError(try G04LspFrameWriter.frame(body: Data([0x41, 0x00, 0x42])))
    }

    func testFragmentedAndCoalescedFramesParse() throws {
        let body = Data(#"{"jsonrpc":"2.0","method":"a"}"#.utf8)
        let first = try G04LspFrameWriter.frame(body: body)
        let second = try G04LspFrameWriter.frame(body: Data(#"{"jsonrpc":"2.0","method":"b"}"#.utf8))
        let parser = G04LspFrameParser()
        parser.feed(first.prefix(8))
        XCTAssertNil(try parser.nextFrame().get())
        parser.feed(first.subdata(in: 8..<first.count))
        XCTAssertEqual(try parser.nextFrame().get(), body)
        let joined = G04LspFrameParser()
        joined.feed(first + second)
        XCTAssertEqual(try joined.nextFrame().get(), body)
        let parser2 = G04LspFrameParser()
        parser2.feed(first + second)
        XCTAssertEqual(try parser2.nextFrame().get(), body)
        XCTAssertNotNil(try parser2.nextFrame().get())
    }

    func testBareLFHeaderSeparatorParses() throws {
        let body = Data(#"{"jsonrpc":"2.0","method":"x"}"#.utf8)
        let frameData = Data("Content-Length: \(body.count)\n\n".utf8) + body
        let parser = G04LspFrameParser()
        parser.feed(frameData)
        XCTAssertEqual(try parser.nextFrame().get(), body)
    }

    func testContaminationRefusesAndPoisons() throws {
        let parser = G04LspFrameParser()
        // A header line is only decidable once it terminates: the streaming
        // parser legitimately buffers an unterminated fragment. Feed the
        // prompt WITH its line terminator — the line's name component
        // "admin@guest" contains '@', which is NOT an RFC 7230 token
        // character, so the parser must type it as framingContaminated.
        parser.feed(Data("admin@guest:~$ \r\n".utf8))
        do {
            _ = try parser.nextFrame().get()
            XCTFail("prompt bytes must be typed contamination")
        } catch let error as G04LspFramingError {
            guard case .framingContaminated(let prefix) = error else {
                XCTFail("expected contamination, got \(error)"); return
            }
            XCTAssertTrue(prefix.contains("admin"))
        }
        // Poisoned: even a perfectly valid later frame still fails.
        XCTAssertThrowsError(try parser.nextFrame().get())
        parser.feed(try frame(["jsonrpc": "2.0", "method": "y"]))
        XCTAssertThrowsError(try parser.nextFrame().get())
    }

    func testMissingContentLengthAndNonCanonicalRefused() throws {
        let parser = G04LspFrameParser()
        parser.feed(Data("X-Wrong: 1\r\n\r\n{}".utf8))
        XCTAssertThrowsError(try parser.nextFrame().get()) { error in
            guard let typed = error as? G04LspFramingError, case .missingContentLength = typed else {
                return XCTFail("missingContentLength expected, got \(error)")
            }
        }
        let parser2 = G04LspFrameParser()
        parser2.feed(Data("Content-Length: 007\r\n\r\n1234567".utf8))
        XCTAssertThrowsError(try parser2.nextFrame().get())
    }

    func testBodyTooLargeRefusedBeforeAccumulation() throws {
        let parser = G04LspFrameParser()
        parser.feed(Data("Content-Length: 999999999\r\n\r\n".utf8))
        XCTAssertThrowsError(try parser.nextFrame().get()) { error in
            guard let typed = error as? G04LspFramingError, case .bodyTooLarge(let declared) = typed else {
                return XCTFail("bodyTooLarge expected, got \(error)")
            }
            XCTAssertEqual(declared, 999_999_999)
        }
    }

    func testInvalidUTF8BodyRefused() throws {
        let broken = Data([0xC3, 0x28])
        let frameData = Data("Content-Length: \(broken.count)\r\n\r\n".utf8) + broken
        let parser = G04LspFrameParser()
        parser.feed(frameData)
        XCTAssertThrowsError(try parser.nextFrame().get())
    }

    // MARK: - Mapping

    func testPathMappingRoundTripAndRefusals() {
        let uri = G04LspPathMapping.uri(relativePath: "src/笔记/hello world.py")
        XCTAssertEqual(G04LspPathMapping.relativePath(uri: uri), "src/笔记/hello world.py")
        XCTAssertNil(G04LspPathMapping.relativePath(uri: "file:///etc/passwd"))
        XCTAssertNil(G04LspPathMapping.relativePath(uri: "file:///workspace/../escape"))
        XCTAssertNil(G04LspPathMapping.relativePath(uri: "vscode://x"))
        XCTAssertNil(G04LspPathMapping.relativePath(uri: "file:///workspace"))
        XCTAssertEqual(G04LspPathMapping.rootUri, "file:///workspace")
    }

    func testPositionOffsetsAcrossLineTerminatorStyles() {
        // \r\n + \r + \n all count as ONE terminator for LSP lines.
        let text = "ab\r\nc😀d\re\nf"
        let units = text.utf16
        XCTAssertEqual(G04LspPosition.offset(range: (0, 1, 0, 2), utf16: units)?.location, 1)
        // line 1 "c😀d": 😀 occupies two UTF-16 units at characters 1..3
        XCTAssertEqual(G04LspPosition.offset(range: (1, 1, 1, 3), utf16: units)?.length, 2)
        let e = G04LspPosition.offset(range: (2, 0, 2, 1), utf16: units)
        XCTAssertNotNil(e)
        let extracted = Array(Array(units)[e!.location..<(e!.location + e!.length)])
        XCTAssertEqual(String(utf16CodeUnits: extracted, count: extracted.count), "e")
        // clamped beyond EOL -> zero length at line end
        let clamp = G04LspPosition.offset(range: (0, 99, 0, 99), utf16: units)
        XCTAssertEqual(clamp?.length, 0)
        XCTAssertNil(G04LspPosition.offset(range: (9, 0, 9, 1), utf16: units))
    }

    // MARK: - Lifecycle helpers

    private func makeSession(_ transport: FakeLspTransport, _ authority: FakeAuthority,
                             _ sink: RecordingLspSink, language: String = "python")
        -> G04LanguageServerSession {
        G04LanguageServerSession(conversationID: UUID(), workspaceID: UUID(), languageID: language,
                                 transport: transport, authority: authority, sink: sink)
    }

    private func pumpUntil(timeoutSeconds: Double = 4,
                           _ condition: @escaping @Sendable () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            if Date() >= deadline { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "condition never satisfied before deadline")
    }

    /// Runs the whole initialize handshake deterministically.
    private func startReady(session: G04LanguageServerSession, transport: FakeLspTransport,
                            sink: RecordingLspSink, requestID: String = "init") async throws {
        Task { await session.ensureStarted(requestID: requestID) }
        try await pumpUntil {
            (try? clientMethodRequest(transport, method: "initialize")) != nil
        }
        let initialize = try XCTUnwrap(clientMethodRequest(transport, method: "initialize"))
        let id = try XCTUnwrap(initialize["id"] as? NSNumber).int64Value
        transport.enqueue(try frame(["jsonrpc": "2.0", "id": id,
                                      "result": ["capabilities": ["completionProvider":
                                        ["triggerCharacters": ["."]]]]]))
        try await pumpUntil { sink.events(type: "lspStatus").last?["state"] as? String == "ready" }
        XCTAssertEqual(sink.reply(requestID: requestID)?["ok"] as? Bool, true)
        // initialized notification rides the ordered stream.
        try await pumpUntil {
            (try? parsedClientFrames(transport.allWritten))?.contains {
                ($0["method"] as? String) == "initialized"
            } ?? false
        }
    }

    // MARK: - Lifecycle

    func testInitializeHandshakeAndReady() async throws {
        let transport = FakeLspTransport()
        let sink = RecordingLspSink()
        let session = makeSession(transport, FakeAuthority(), sink)
        try await startReady(session: session, transport: transport, sink: sink)
        XCTAssertEqual(sink.events(type: "lspStatus").last?["state"] as? String, "ready")
    }

    func testToolMissingMarkerBecomesTypedUnavailable() async throws {
        let transport = FakeLspTransport()
        let sink = RecordingLspSink()
        let session = makeSession(transport, FakeAuthority(), sink)
        Task { await session.ensureStarted(requestID: "r") }
        try await pumpUntil {
            (try? clientMethodRequest(transport, method: "initialize")) != nil
        }
        // The guest printed the closed marker BEFORE any framing (and the
        // process then exited): the typed state is toolMissing, never a
        // generic "running" lie.
        transport.enqueue(Data("FLOE-LSP-TOOL-MISSING 'pylsp'\n".utf8))
        transport.enqueueTerminal(exit: 127)
        try await pumpUntil {
            sink.events(type: "lspStatus").last?["state"] as? String == "unavailable"
        }
        XCTAssertEqual(sink.events(type: "lspStatus").last?["code"] as? String, "toolMissing")
        XCTAssertEqual(sink.events(type: "lspFramingFault").last?["code"] as? String, "toolMissing")
    }

    func testRevisionFencesAndVersionedSync() async throws {
        let transport = FakeLspTransport()
        let authority = FakeAuthority()
        let sink = RecordingLspSink()
        let document = UUID()
        authority.seed(document, path: "app.py", revision: 1, text: "x = 1\n")
        let session = makeSession(transport, authority, sink)
        // Not ready yet: refused before any didOpen byte is produced.
        await session.openDocument(documentID: document, expectedRevision: "rev-1",
                                   text: "x = 1\n", requestID: "early")
        XCTAssertEqual(sink.reply(requestID: "early")?["ok"] as? Bool, false)
        try await startReady(session: session, transport: transport, sink: sink)
        await session.openDocument(documentID: document, expectedRevision: "rev-9",
                                   text: "x = 1\n", requestID: "stale")
        XCTAssertEqual(sink.reply(requestID: "stale")?["code"] as? String, "staleRevision")
        await session.openDocument(documentID: document, expectedRevision: "rev-1",
                                   text: "x = 1\n", requestID: "open")
        let didOpen = try await pumpThenUnwrap {
            try clientMethodRequest(transport, method: "textDocument/didOpen")
        }
        let textDocument = try XCTUnwrap(didOpen["params"] as? [String: Any])
        let descriptor = try XCTUnwrap(textDocument["textDocument"] as? [String: Any])
        XCTAssertEqual(descriptor["uri"] as? String, "file:///workspace/app.py")
        XCTAssertEqual((descriptor["version"] as? NSNumber)?.intValue, 1)
        // Change bumps the version monotonically against a NEW native revision.
        authority.seed(document, path: "app.py", revision: 2, text: "x = 2\n")
        await session.changeDocument(documentID: document, expectedRevision: "rev-2",
                                     text: "x = 2\n", requestID: "change")
        let didChange = try await pumpThenUnwrap {
            try clientMethodRequest(transport, method: "textDocument/didChange")
        }
        let changeParams = try XCTUnwrap(didChange["params"] as? [String: Any])
        let changedDoc = try XCTUnwrap(changeParams["textDocument"] as? [String: Any])
        XCTAssertEqual((changedDoc["version"] as? NSNumber)?.intValue, 2)
        let changes = try XCTUnwrap(changeParams["contentChanges"] as? [[String: Any]])
        XCTAssertEqual(changes.first?["text"] as? String, "x = 2\n")
        // And a stale change is refused without touching the queue. The
        // NATIVE revision must actually have advanced for "rev-2" to be
        // stale: in the real composition the editor's save bumps the tab
        // revision, while changeDocument only ever consumes
        // expectedRevision == current tab revision (see production gate at
        // G04LanguageServer.changeDocument). Re-seed rev-3 to restore the
        // authored premise without touching any assertion.
        authority.seed(document, path: "app.py", revision: 3, text: "x = 2\n")
        await session.changeDocument(documentID: document, expectedRevision: "rev-2",
                                     text: "x = 3\n", requestID: "stale-change")
        XCTAssertEqual(sink.reply(requestID: "stale-change")?["code"] as? String, "staleRevision")
    }

    private func pumpThenUnwrap(_ find: @escaping @Sendable () throws -> [String: Any]?) async throws -> [String: Any] {
        var result: [String: Any]?
        let deadline = Date().addingTimeInterval(4)
        while result == nil, Date() < deadline {
            result = try find()
            if result == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        return try XCTUnwrap(result)
    }

    func testCompletionResultMappingAndLateCancel() async throws {
        let transport = FakeLspTransport()
        let authority = FakeAuthority()
        let sink = RecordingLspSink()
        let document = UUID()
        authority.seed(document, path: "app.py", revision: 1, text: "print(\n")
        let session = makeSession(transport, authority, sink)
        try await startReady(session: session, transport: transport, sink: sink)
        await session.openDocument(documentID: document, expectedRevision: "rev-1",
                                   text: "print(\n", requestID: "open")
        _ = try await pumpThenUnwrap { try clientMethodRequest(transport, method: "textDocument/didOpen") }
        Task {
            await session.completion(documentID: document, expectedRevision: "rev-1",
                                     line: 0, character: 6, requestID: "comp-1")
        }
        let completion = try await pumpThenUnwrap {
            try clientMethodRequest(transport, method: "textDocument/completion")
        }
        let completionID = try XCTUnwrap(completion["id"] as? NSNumber).int64Value
        // Host cancel: releases the waiter ONCE with `cancelled` and orders
        // $/cancelRequest on the SAME stream.
        await session.cancel(hostRequestID: "comp-1", requestID: "cancel-ack")
        let cancelReply = try XCTUnwrap(sink.reply(requestID: "comp-1"))
        XCTAssertEqual(cancelReply["code"] as? String, "cancelled")
        _ = try await pumpThenUnwrap {
            try clientMethodRequest(transport, method: "$/cancelRequest")
        }
        // A late result must NOT deliver a second answer or a completion event.
        transport.enqueue(try frame(["jsonrpc": "2.0", "id": completionID, "result": [
            "isIncomplete": false,
            "items": [["label": "pprint", "kind": 3, "insertText": "pprint", "insertTextFormat": 2]],
        ]]))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(sink.events(type: "lspCompletion").count, 0)
        let all = sink.controls.filter { ($0["requestID"] as? String) == "comp-1" }
        XCTAssertEqual(all.count, 1)
    }

    func testCompletionResultDeliversWithFences() async throws {
        let transport = FakeLspTransport()
        let authority = FakeAuthority()
        let sink = RecordingLspSink()
        let document = UUID()
        authority.seed(document, path: "app.py", revision: 1, text: "pri\n")
        let session = makeSession(transport, authority, sink)
        try await startReady(session: session, transport: transport, sink: sink)
        await session.openDocument(documentID: document, expectedRevision: "rev-1", text: "pri\n", requestID: "open")
        Task {
            await session.completion(documentID: document, expectedRevision: "rev-1",
                                     line: 0, character: 3, requestID: "comp-2")
        }
        let completion = try await pumpThenUnwrap {
            try clientMethodRequest(transport, method: "textDocument/completion")
        }
        let completionID = try XCTUnwrap(completion["id"] as? NSNumber).int64Value
        transport.enqueue(try frame(["jsonrpc": "2.0", "id": completionID, "result": [
            "isIncomplete": true,
            "items": [
                ["label": "print", "kind": 3, "insertText": "print", "insertTextFormat": 1],
                ["label": "printf", "kind": 3, "insertTextFormat": 2],   // snippet: label fallback
            ],
        ]]))
        try await pumpUntil { !sink.events(type: "lspCompletion").isEmpty }
        let event = sink.events(type: "lspCompletion")[0]
        XCTAssertEqual(event["requestID"] as? String, "comp-2")
        XCTAssertEqual(event["documentID"] as? String, document.uuidString)
        XCTAssertEqual(event["revision"] as? String, "rev-1")
        XCTAssertEqual(event["incomplete"] as? Bool, true)
        let items = try XCTUnwrap(event["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["insertText"] as? String, "print")
        // Snippet items never smuggle raw snippet bytes: label fallback.
        XCTAssertEqual(items[1]["insertText"] as? String, "printf")
    }

    func testDiagnosticsFenceAndUnknownUriIgnored() async throws {
        let transport = FakeLspTransport()
        let authority = FakeAuthority()
        let sink = RecordingLspSink()
        let document = UUID()
        authority.seed(document, path: "app.py", revision: 3, text: "x = ?\n")
        let session = makeSession(transport, authority, sink)
        try await startReady(session: session, transport: transport, sink: sink)
        await session.openDocument(documentID: document, expectedRevision: "rev-3",
                                   text: "x = ?\n", requestID: "open")
        transport.enqueue(try frame(["jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                                      "params": ["uri": "file:///workspace/ghost.py",
                                                  "diagnostics": [["range": ["start": ["line": 0, "character": 0],
                                                                      "end": ["line": 0, "character": 1]],
                                                                   "severity": 1, "message": "x"]]]]))
        transport.enqueue(try frame(["jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                                      "params": ["uri": "file:///workspace/app.py",
                                                  "diagnostics": [["range": ["start": ["line": 0, "character": 4],
                                                                      "end": ["line": 0, "character": 5]],
                                                                   "severity": 1, "message": "invalid syntax"],
                                                                  ["range": ["start": ["line": 0, "character": 0],
                                                                      "end": ["line": 0, "character": 1]],
                                                                   "severity": 2, "message": "hint-ish"]]]]))
        try await pumpUntil { !sink.events(type: "lspDiagnostics").isEmpty }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sink.events(type: "lspDiagnostics").count, 1)  // ghost uri ignored
        let published = sink.events(type: "lspDiagnostics")[0]
        XCTAssertEqual(published["documentID"] as? String, document.uuidString)
        XCTAssertEqual(published["revision"] as? String, "rev-3")
        XCTAssertEqual(published["relativePath"] as? String, "app.py")
        let items = try XCTUnwrap(published["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual((items[0]["severity"] as? NSNumber)?.intValue, 1)
    }

    func testApplyEditFullPrevalidationRefusesWholeEdit() async throws {
        let transport = FakeLspTransport()
        let authority = FakeAuthority()
        let sink = RecordingLspSink()
        let good = UUID()
        authority.seed(good, path: "a.py", revision: 1, text: "old\n")
        let session = makeSession(transport, authority, sink)
        try await startReady(session: session, transport: transport, sink: sink)
        await session.openDocument(documentID: good, expectedRevision: "rev-1", text: "old\n", requestID: "open1")
        // The second document URI is OUTSIDE the mapped workspace: the
        // whole applyEdit refuses and the good document sees ZERO edits.
        transport.enqueue(try frame(["jsonrpc": "2.0", "id": 55, "method": "workspace/applyEdit",
                                      "params": ["edit": ["changes": [
                                          "file:///workspace/a.py": [["range": ["start": ["line": 0, "character": 0],
                                                                        "end": ["line": 0, "character": 3]],
                                                                     "newText": "new"]],
                                          "file:///etc/shadow": [["range": ["start": ["line": 0, "character": 0],
                                                                            "end": ["line": 0, "character": 0]],
                                                                   "newText": "x"]],
                                      ]]]]))
        let reply = try await pumpThenUnwrap {
            try parsedClientFrames(transport.allWritten).first {
                ($0["id"] as? NSNumber)?.int64Value == 55
            }
        }
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["applied"] as? Bool, false)
        XCTAssertEqual(result["failureReason"] as? String, "uriOutsideMappedWorkspace")
        XCTAssertTrue(authority.editCalls.isEmpty)
    }

    func testApplyEditUnsupportedFileOperationsRefused() async throws {
        let transport = FakeLspTransport()
        let authority = FakeAuthority()
        let sink = RecordingLspSink()
        let session = makeSession(transport, authority, sink)
        try await startReady(session: session, transport: transport, sink: sink)
        transport.enqueue(try frame(["jsonrpc": "2.0", "id": 56, "method": "workspace/applyEdit",
                                      "params": ["edit": ["documentChanges": [
                                          ["kind": "create", "uri": "file:///workspace/new.py"],
                                      ]]]]))
        let reply = try await pumpThenUnwrap {
            try parsedClientFrames(transport.allWritten).first {
                ($0["id"] as? NSNumber)?.int64Value == 56
            }
        }
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["applied"] as? Bool, false)
        XCTAssertEqual(result["failureReason"] as? String, "unsupportedFileOperations")
    }

    func testApplyEditPartialFailureReportsAppliedExactly() async throws {
        let transport = FakeLspTransport()
        let authority = FakeAuthority()
        let sink = RecordingLspSink()
        let first = UUID()
        let second = UUID()
        authority.seed(first, path: "a.py", revision: 1, text: "old\n")
        authority.seed(second, path: "b.py", revision: 1, text: "beta\n")
        let session = makeSession(transport, authority, sink)
        try await startReady(session: session, transport: transport, sink: sink)
        await session.openDocument(documentID: first, expectedRevision: "rev-1", text: "old\n", requestID: "o1")
        await session.openDocument(documentID: second, expectedRevision: "rev-1", text: "beta\n", requestID: "o2")
        // Prevalidation now passes; the authority starts failing ONLY after
        // the first document applied (failEditFor set post-prepare is not
        // possible here, so fail via the SECOND document's stale view: bump
        // its native revision between prepare steps by making the first
        // apply succeed and the second doc's seed change underneath through
        // the edit counter). Simplest deterministic fail: second doc missing
        // its synced state AFTER prepare -> inject failure directly.
        authority.failEditFor = second
        transport.enqueue(try frame(["jsonrpc": "2.0", "id": 61, "method": "workspace/applyEdit",
                                      "params": ["edit": ["documentChanges": [
                                          ["textDocument": ["uri": "file:///workspace/a.py", "version": 1],
                                           "edits": [["range": ["start": ["line": 0, "character": 0],
                                                           "end": ["line": 0, "character": 3]],
                                                      "newText": "new"]]],
                                          ["textDocument": ["uri": "file:///workspace/b.py", "version": 1],
                                           "edits": [["range": ["start": ["line": 0, "character": 0],
                                                           "end": ["line": 0, "character": 4]],
                                                      "newText": "gone"]]],
                                      ]]]]))
        // applied:false overall.
        let reply = try await pumpThenUnwrap {
            try parsedClientFrames(transport.allWritten).first {
                ($0["id"] as? NSNumber)?.int64Value == 61
            }
        }
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["applied"] as? Bool, false)
        // The first document's real application is surfaced EXACTLY, with
        // its new revision; nothing is hidden behind a success flag.
        let partial = try await pumpThenUnwrap {
            try sink.events(type: "lspApplyEditPartial").first
        }
        let applied = try XCTUnwrap(partial["applied"] as? [[String: Any]])
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied.first?["documentID"] as? String, first.uuidString)
        XCTAssertEqual(applied.first?["revision"] as? String, "rev-2")
        XCTAssertEqual(authority.editCalls.count, 2)
        XCTAssertEqual(authority.editCalls.last?.documentID, second)
    }

    func testApplyEditSuccessReportsAppliedAndResyncs() async throws {
        let transport = FakeLspTransport()
        let authority = FakeAuthority()
        let sink = RecordingLspSink()
        let document = UUID()
        authority.seed(document, path: "a.py", revision: 1, text: "old\n")
        let session = makeSession(transport, authority, sink)
        try await startReady(session: session, transport: transport, sink: sink)
        await session.openDocument(documentID: document, expectedRevision: "rev-1",
                                   text: "old\n", requestID: "o1")
        transport.enqueue(try frame(["jsonrpc": "2.0", "id": 71, "method": "workspace/applyEdit",
                                      "params": ["edit": ["changes": [
                                          "file:///workspace/a.py": [["range": ["start": ["line": 0, "character": 0],
                                                                        "end": ["line": 0, "character": 3]],
                                                                     "newText": "new"]]]]]]))
        let reply = try await pumpThenUnwrap {
            try parsedClientFrames(transport.allWritten).first {
                ($0["id"] as? NSNumber)?.int64Value == 71
            }
        }
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["applied"] as? Bool, true)
        let applied = try await pumpThenUnwrap {
            try sink.events(type: "lspApplyEditApplied").first
        }
        let rows = try XCTUnwrap(applied["applied"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["revision"] as? String, "rev-2")
        // The server is re-synced to the NEW native bytes (FULL didChange
        // with the bumped version), never left on the stale pre-edit text.
        try await pumpUntil {
            let frames = (try? parsedClientFrames(transport.allWritten)) ?? []
            return frames.contains { frame in
                guard (frame["method"] as? String) == "textDocument/didChange",
                      let params = frame["params"] as? [String: Any],
                      let doc = params["textDocument"] as? [String: Any],
                      let version = doc["version"] as? NSNumber,
                      let changes = params["contentChanges"] as? [[String: Any]],
                      let text = changes.first?["text"] as? String else { return false }
                return version.intValue >= 2 && text == "new\n"
            }
        }
        XCTAssertEqual(authority.editCalls.count, 1)
    }

    func testServerExitFencesPendingAndClosesSession() async throws {
        let transport = FakeLspTransport()
        let authority = FakeAuthority()
        let sink = RecordingLspSink()
        let document = UUID()
        authority.seed(document, path: "a.py", revision: 1, text: "x\n")
        let session = makeSession(transport, authority, sink)
        try await startReady(session: session, transport: transport, sink: sink)
        await session.openDocument(documentID: document, expectedRevision: "rev-1", text: "x\n", requestID: "o")
        Task {
            await session.completion(documentID: document, expectedRevision: "rev-1",
                                     line: 0, character: 1, requestID: "late")
        }
        _ = try await pumpThenUnwrap { try clientMethodRequest(transport, method: "textDocument/completion") }
        // The server process truly exits (engine-proven terminal).
        transport.enqueueTerminal(exit: 137)
        try await pumpUntil {
            sink.controls.contains { ($0["requestID"] as? String) == "late"
                && ($0["code"] as? String) == "serverGone" }
        }
        try await pumpUntil { transport.closed }
        XCTAssertEqual(sink.events(type: "lspStatus").last?["state"] as? String, "stopped")
    }

    func testExplicitShutdownSendsShutdownExitAndCloses() async throws {
        let transport = FakeLspTransport()
        let authority = FakeAuthority()
        let sink = RecordingLspSink()
        let session = makeSession(transport, authority, sink)
        try await startReady(session: session, transport: transport, sink: sink)
        // Answer shutdown so the flush loop ends quickly.
        Task {
            for _ in 0..<60 {
                let frames = (try? parsedClientFrames(transport.allWritten)) ?? []
                if let shutdown = frames.first(where: { ($0["method"] as? String) == "shutdown" }),
                   let id = shutdown["id"] as? NSNumber {
                    transport.enqueue(try frame(["jsonrpc": "2.0", "id": id.int64Value, "result": NSNull()]))
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        await session.shutdown(reason: "explicit-shutdown", requestID: "sd")
        let frames = try parsedClientFrames(transport.allWritten)
        XCTAssertTrue(frames.contains { ($0["method"] as? String) == "shutdown" })
        XCTAssertTrue(frames.contains { ($0["method"] as? String) == "exit" })
        try await pumpUntil { transport.closed }
        XCTAssertEqual(sink.reply(requestID: "sd")?["ok"] as? Bool, true)
        XCTAssertEqual(sink.events(type: "lspStatus").last?["state"] as? String, "stopped")
    }

    func testLanguageLaunchRecipeBoundsFramingReality() {
        // The launch recipe must: probe the tool, force raw echo-off PTY,
        // drop stderr, exec the server, and emit only the closed markers.
        let descriptor = try! XCTUnwrap(G04LanguageServerCatalog.descriptor(for: "python"))
        let command = G04LanguageServerCatalog.startCommand(for: descriptor)
        XCTAssertTrue(command.contains("command -v 'pylsp'"))
        XCTAssertTrue(command.contains("stty raw -echo"))
        XCTAssertTrue(command.contains("FLOE-LSP-TOOL-MISSING"))
        XCTAssertTrue(command.contains("FLOE-LSP-NO-RAWTTY"))
        XCTAssertTrue(command.contains("2>/dev/null"))
        XCTAssertTrue(command.contains("exec 'pylsp'"))
    }

    // MARK: - Lifecycle settlement (job-bdebb54ff6ff4403 additions)

    func testReceiptCancellationSettlesServerThroughOriginalClose() async throws {
        let transport = FakeLspTransport()
        let authority = FakeAuthority()
        let sink = RecordingLspSink()
        let session = makeSession(transport, authority, sink)
        try await startReady(session: session, transport: transport, sink: sink)
        // The ORIGINAL deletion fence / retirement cancels the receipt:
        // the pump must follow the honest close path (transport.close = the
        // ORIGINAL engine teardown + receipt settlement), type the state,
        // and never re-open anything afterwards.
        transport.cancellationRequested = true
        try await pumpUntil { transport.closed }
        let finalStatus = try XCTUnwrap(sink.events(type: "lspStatus").last)
        XCTAssertEqual(finalStatus["state"] as? String, "stopped")
        XCTAssertEqual(finalStatus["code"] as? String, "lifecycle-cancelled")
        XCTAssertTrue(transport.closed)
    }

    func testHoldsNoDocumentsReflectsRealSyncedSet() async throws {
        let transport = FakeLspTransport()
        let authority = FakeAuthority()
        let sink = RecordingLspSink()
        let document = UUID()
        authority.seed(document, path: "app.py", revision: 1, text: "x\n")
        let session = makeSession(transport, authority, sink)
        try await startReady(session: session, transport: transport, sink: sink)
        let emptyAtStart = await session.holdsNoDocuments()
        XCTAssertTrue(emptyAtStart)
        await session.openDocument(documentID: document, expectedRevision: "rev-1",
                                   text: "x\n", requestID: "open")
        _ = try await pumpThenUnwrap { try clientMethodRequest(transport, method: "textDocument/didOpen") }
        let stillHasDocument = await session.holdsNoDocuments()
        XCTAssertFalse(stillHasDocument)
        // A close for an UNKNOWN document refuses and must not look like a
        // last close (nothing was actually removed).
        let refused = await session.closeDocument(documentID: UUID(), requestID: "ghost")
        XCTAssertFalse(refused)
        let afterRefused = await session.holdsNoDocuments()
        XCTAssertFalse(afterRefused)
        // The real close counts and empties the synced set.
        let closedOne = await session.closeDocument(documentID: document, requestID: "close")
        XCTAssertTrue(closedOne)
        let emptyAtEnd = await session.holdsNoDocuments()
        XCTAssertTrue(emptyAtEnd)
        _ = try await pumpThenUnwrap { try clientMethodRequest(transport, method: "textDocument/didClose") }
    }

    func testCenterRouteShutsDownServerAfterLastRealDocumentClose() async throws {
        let transport = FakeLspTransport()
        let authority = FakeAuthority()
        let sink = RecordingLspSink()
        let document = UUID()
        authority.seed(document, path: "app.py", revision: 1, text: "x\n")
        let conversation = UUID()
        let session = makeSession(transport, authority, sink)
        try await startReady(session: session, transport: transport, sink: sink)
        let center = G04LanguageServerCenter(epoch: 4_242_424, sink: sink)
        await center.seedSessionForTests(session, conversationID: conversation, language: "python")
        await center.route(documentAction: "lspOpenDocument", conversationID: conversation,
                           workspaceID: nil, language: "python", documentID: document,
                           expectedRevision: "rev-1", text: "x\n", line: nil, character: nil,
                           hostRequestID: "r-open", cancelTarget: nil)
        _ = try await pumpThenUnwrap { try clientMethodRequest(transport, method: "textDocument/didOpen") }
        // A refused close must NOT tear the server down (noSession still no).
        await center.route(documentAction: "lspCloseDocument", conversationID: conversation,
                           workspaceID: nil, language: "python", documentID: UUID(),
                           expectedRevision: "", text: nil, line: nil, character: nil,
                           hostRequestID: "r-ghost", cancelTarget: nil)
        XCTAssertEqual(sink.reply(requestID: "r-ghost")?["code"] as? String, "missingDocument")
        // The REAL last-document close settles the server explicitly.
        await center.route(documentAction: "lspCloseDocument", conversationID: conversation,
                           workspaceID: nil, language: "python", documentID: document,
                           expectedRevision: "rev-1", text: nil, line: nil, character: nil,
                           hostRequestID: "r-close", cancelTarget: nil)
        XCTAssertEqual(sink.reply(requestID: "r-close")?["ok"] as? Bool, true)
        try await pumpUntil { transport.closed }
        let finalStatus = try XCTUnwrap(sink.events(type: "lspStatus").last)
        XCTAssertEqual(finalStatus["code"] as? String, "last-document-closed")
        // The center removed the entry: follow-up work answers noSession,
        // so an orphaned conversation cannot keep routing into a dead
        // server or hold the shared session budget.
        await center.route(documentAction: "lspCompletion", conversationID: conversation,
                           workspaceID: nil, language: "python", documentID: document,
                           expectedRevision: "rev-1", text: nil, line: 0, character: 0,
                           hostRequestID: "r-after", cancelTarget: nil)
        XCTAssertEqual(sink.reply(requestID: "r-after")?["code"] as? String, "serverUnavailable")
        XCTAssertEqual(sink.reply(requestID: "r-after")?["reason"] as? String, "noSession")
    }

}
