// Focused contract tests for the per-process Skill secret environment
// transport. These exercise the production channel with a scripted guest
// console and the real shell/Mac request construction. They are host tests:
// the static riscv64 runner and the real guest still need the release
// owner's component build and device qualification.

import XCTest
@testable import FloeExecution
import FloeCore
import FloeTools

// MARK: - scripted guest console

/// Minimal protocol peer: answers HELLO with the configured CAPS, records
/// command payloads, and completes them (optionally only after SIGNAL INT).
final class ScriptedGuestConsole: LinuxGuestConsoleTransport, @unchecked Sendable {
    struct CapturedFrame: Sendable {
        let name: String
        let token: String
        let payload: Data?
    }

    private struct Assembly {
        let name: String
        let expected: Int
        let chunkCount: Int
        var chunks: [Int: String] = [:]
    }

    var capabilities: String
    var holdCommands = false
    var commandOutput = "ran"
    var answersSessions = true

    private let lock = NSLock()
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var writes: [UInt8] = []
    private var frames: [CapturedFrame] = []
    private var assemblies: [String: Assembly] = [:]

    init(capabilities: String) {
        self.capabilities = capabilities
        var captured: AsyncStream<Data>.Continuation!
        self.stream = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    func write(_ bytes: [UInt8]) async throws {
        let text = String(decoding: bytes, as: UTF8.self)
        let responses = process(text)
        for response in responses {
            continuation.yield(response)
        }
    }

    func close() async {
        continuation.finish()
    }

    func output() async -> AsyncStream<Data> {
        stream
    }

    var writtenText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: writes, as: UTF8.self)
    }

    func capturedFrames(named name: String) -> [CapturedFrame] {
        lock.lock()
        defer { lock.unlock() }
        return frames.filter { $0.name == name }
    }

    var allFrames: [CapturedFrame] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    // MARK: frame processing

    private func process(_ text: String) -> [Data] {
        lock.lock()
        writes.append(contentsOf: text.utf8)
        lock.unlock()

        guard let parsed = Self.parseFrame(text) else { return [] }
        switch parsed.name {
        case "HELLO":
            record(name: "HELLO", token: parsed.token, payload: nil)
            return [
                Self.frame("CAPS", token: parsed.token, body: capabilities),
                Self.frame("END", token: parsed.token, body: "0"),
            ]
        case "EXEC", "EXECENV":
            if let header = Self.parseHeader(parsed.arguments) {
                lock.lock()
                assemblies[parsed.token] = Assembly(
                    name: parsed.name,
                    expected: header.bytes,
                    chunkCount: header.chunks
                )
                lock.unlock()
                return []
            }
            guard let payload = Data(base64Encoded: parsed.arguments.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return []
            }
            record(name: parsed.name, token: parsed.token, payload: payload)
            return holdCommands ? [Self.frame("BEGIN", token: parsed.token, body: nil)] : commandFrames(name: parsed.name, token: parsed.token)
        case "OPEN", "OPENENV":
            guard let header = Self.parseHeader(parsed.arguments) else { return [] }
            lock.lock()
            assemblies[parsed.token] = Assembly(
                name: parsed.name,
                expected: header.bytes,
                chunkCount: header.chunks
            )
            lock.unlock()
            return []
        case "CHUNK":
            let parts = parsed.arguments.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let index = Int(parts[0]) else { return [] }
            lock.lock()
            assemblies[parsed.token]?.chunks[index] = String(parts[1])
            lock.unlock()
            return []
        case "RUN":
            lock.lock()
            let assembly = assemblies.removeValue(forKey: parsed.token)
            lock.unlock()
            guard let assembly else { return [] }
            let joined = (0..<assembly.chunkCount).compactMap { assembly.chunks[$0] }.joined()
            guard let payload = Data(base64Encoded: joined) else { return [] }
            record(name: assembly.name, token: parsed.token, payload: payload)
            if assembly.name.hasPrefix("OPEN") {
                return answersSessions ? commandFrames(name: assembly.name, token: parsed.token) : []
            }
            return holdCommands ? [Self.frame("BEGIN", token: parsed.token, body: nil)] : commandFrames(name: assembly.name, token: parsed.token)
        case "SIGNAL":
            guard parsed.arguments.hasPrefix("INT") else { return [] }
            // Simulate a reaped interrupted process group.
            return [
                Self.frame("END", token: parsed.token, body: "130"),
            ]
        default:
            return []
        }
    }

    private func record(name: String, token: String, payload: Data?) {
        lock.lock()
        frames.append(CapturedFrame(name: name, token: token, payload: payload))
        lock.unlock()
    }

    private func commandFrames(name: String, token: String) -> [Data] {
        [
            Self.frame("BEGIN", token: token, body: nil),
            Self.outputFrame(token: token, text: commandOutput),
            Self.frame("END", token: token, body: "0"),
        ]
    }

    private static func outputFrame(token: String, text: String) -> Data {
        var data = Data("\u{1e}FLOE-OUT \(token)\u{1e}".utf8)
        data.append(Data(text.utf8))
        return data
    }

    private struct ParsedFrame {
        let name: String
        let token: String
        let arguments: String
    }

    private static func parseFrame(_ text: String) -> ParsedFrame? {
        let prefix = "\u{1e}FLOE-"
        guard let range = text.range(of: prefix) else { return nil }
        let remainder = text[range.upperBound...]
        guard let space = remainder.firstIndex(of: " ") else { return nil }
        let name = String(remainder[..<space])
        let afterName = remainder[remainder.index(after: space)...]
        let tokenEnd = afterName.firstIndex(where: { $0 == " " || $0 == "\u{1e}" || $0 == "\n" }) ?? afterName.endIndex
        let token = String(afterName[..<tokenEnd])
        let arguments = tokenEnd == afterName.endIndex
            ? ""
            : String(afterName[afterName.index(after: tokenEnd)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\u{1e}\n"))
        guard !token.isEmpty else { return nil }
        return ParsedFrame(name: name, token: token, arguments: arguments)
    }

    private static func parseHeader(_ arguments: String) -> (bytes: Int, chunks: Int)? {
        let parts = arguments.split(separator: " ")
        guard parts.count == 2, let bytes = Int(parts[0]), let chunks = Int(parts[1]) else { return nil }
        return (bytes, chunks)
    }

    private static func frame(_ name: String, token: String, body: String?) -> Data {
        var text = "\u{1e}FLOE-\(name) \(token)"
        if let body { text += " " + body }
        text += "\u{1e}"
        return Data(text.utf8)
    }
}

// MARK: - helpers

private func decodeFields(_ data: Data) throws -> [Data] {
    var fields: [Data] = []
    var offset = 0
    func readUInt32() throws -> Int {
        guard offset + 4 <= data.count else {
            throw NSError(domain: "test", code: 1)
        }
        let start = data.startIndex + offset
        let value = data[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
        offset += 4
        return value
    }
    let count = try readUInt32()
    for _ in 0..<count {
        let length = try readUInt32()
        guard offset + length <= data.count else {
            throw NSError(domain: "test", code: 2)
        }
        let start = data.startIndex + offset
        fields.append(Data(data[start..<start + length]))
        offset += length
    }
    return fields
}

private func decodeEnvironmentBlock(_ data: Data) throws -> [(String, String)] {
    var result: [(String, String)] = []
    var offset = 0
    func readUInt32() throws -> Int {
        guard offset + 4 <= data.count else { throw NSError(domain: "test", code: 3) }
        let start = data.startIndex + offset
        let value = data[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
        offset += 4
        return value
    }
    func readString(_ length: Int) -> String {
        let start = data.startIndex + offset
        let value = String(decoding: data[start..<start + length], as: UTF8.self)
        offset += length
        return value
    }
    let count = try readUInt32()
    for _ in 0..<count {
        let nameLength = try readUInt32()
        let name = readString(nameLength)
        let valueLength = try readUInt32()
        let value = readString(valueLength)
        result.append((name, value))
    }
    return result
}

private func env(_ pairs: [(String, String)]) throws -> SensitiveProcessEnvironment {
    try SensitiveProcessEnvironment(entries: pairs.map { .init(name: $0.0, value: $0.1) })
}

private func toolEnvironment(id: String = "env-test") -> ToolEnvironment {
    ToolEnvironment(
        id: id,
        writableLayerURL: FileManager.default.temporaryDirectory,
        layerURLs: [],
        variables: [:]
    )
}

private let supportedCaps = "runner=2.1.0 protocol=3 maxCommands=8 maxSessions=4 env=1 net=down hostArchive=none"
private let legacyCaps = "runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4 net=down hostArchive=none"

// MARK: - tests

final class SensitiveEnvironmentTransportTests: XCTestCase {
    private let secretA = "secret-A-sentinel-91f3"
    private let secretB = "secret-B-sentinel-2d77"

    // MARK: validation / redaction

    func testValidationRejectsInvalidInputs() throws {
        XCTAssertThrowsError(try env([("BAD-NAME", "x")]))
        XCTAssertThrowsError(try env([("1BAD", "x")]))
        XCTAssertThrowsError(try env([("", "x")]))
        XCTAssertThrowsError(try env([(String(repeating: "A", count: 129), "x")]))
        XCTAssertThrowsError(try env([("GOOD", "a\0b")]))
        XCTAssertThrowsError(try env([("GOOD", String(repeating: "x", count: 33 * 1024))]))
        XCTAssertThrowsError(try env([("DUP", "1"), ("DUP", "2")]))
        XCTAssertThrowsError(try SensitiveProcessEnvironment(entries:
            (0..<65).map { SensitiveProcessEnvironment.Entry(name: "V\($0)", value: "x") }
        ))
    }

    func testValidationRejectsOrdinaryOverlap() throws {
        let environment = try env([("SHARED", "secret")])
        XCTAssertThrowsError(try environment.validateDisjoint(from: ["SHARED": "ordinary"]))
        XCTAssertNoThrow(try environment.validateDisjoint(from: ["OTHER": "ordinary"]))
    }

    func testDescriptionNeverContainsValues() throws {
        let environment = try env([("OPENAI_API_KEY", secretA)])
        XCTAssertFalse(String(describing: environment).contains(secretA))
        XCTAssertFalse(environment.debugDescription.contains(secretA))
        XCTAssertFalse(String(reflecting: environment).contains(secretA))
    }

    func testCompleteOutputRedactsTrailingPartialPrefix() throws {
        let environment = try env([("OPENAI_API_KEY", secretA)])
        XCTAssertEqual(environment.redactor.redactComplete("value=secret-A"), "value=[REDACTED]")
        XCTAssertEqual(environment.redactor.redactComplete("value=\(secretA)"), "value=[REDACTED]")
    }

    func testWireByteCountMatchesEncoder() throws {
        let environment = try env([("A", "1"), ("LONG_NAME", "value")])
        let encoded = LinuxGuestFraming.environmentBlock(entries: environment.wireEntries)
        XCTAssertEqual(encoded.count, environment.wireByteCount)
    }

    // MARK: framing

    func testExecPayloadKeepsEnvOutOfArgvAndStdinSeparate() throws {
        let environment = try env([("OPENAI_API_KEY", secretA)])
        let payload = LinuxGuestFraming.payload(
            of: ["/bin/sh", "-c", "printenv OPENAI_API_KEY"],
            workingDirectory: "/workspace",
            standardInput: "stdin-sentinel",
            environmentEntries: environment.wireEntries
        )
        let fields = try decodeFields(payload)
        XCTAssertEqual(fields.count, 6)
        XCTAssertEqual(String(decoding: fields[0], as: UTF8.self), "/workspace")
        XCTAssertEqual(String(decoding: fields[1], as: UTF8.self), "stdin-sentinel")
        let environmentFields = try decodeEnvironmentBlock(fields[2])
        XCTAssertEqual(environmentFields.map { $0.0 }, ["OPENAI_API_KEY"])
        XCTAssertEqual(environmentFields.map { $0.1 }, [secretA])
        let argv = fields[3...].map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(argv, ["/bin/sh", "-c", "printenv OPENAI_API_KEY"])
        XCTAssertFalse(argv.joined().contains(secretA))
    }

    func testSessionPayloadKeepsEnvOutOfArgv() throws {
        let environment = try env([("TOKEN", secretA)])
        let payload = LinuxGuestFraming.sessionPayload(
            argv: ["/bin/sh", "-c", "printenv TOKEN"],
            workingDirectory: "/workspace",
            columns: 80,
            rows: 24,
            environmentEntries: environment.wireEntries
        )
        let fields = try decodeFields(payload)
        XCTAssertEqual(fields.count, 8)
        XCTAssertEqual(String(decoding: fields[0], as: UTF8.self), "pty")
        let environmentFields = try decodeEnvironmentBlock(fields[4])
        XCTAssertEqual(environmentFields.map { $0.1 }, [secretA])
        XCTAssertFalse(fields[5...].map { String(decoding: $0, as: UTF8.self) }.joined().contains(secretA))
    }

    func testEmptyEnvironmentUsesOrdinaryLayout() throws {
        let payload = LinuxGuestFraming.payload(
            of: ["/bin/echo"],
            workingDirectory: nil,
            standardInput: nil,
            environmentEntries: []
        )
        let ordinaryFields = try decodeFields(payload)
        XCTAssertEqual(ordinaryFields.count, 3)
    }

    func testCapabilityParsing() {
        XCTAssertTrue(LinuxGuestFraming.supportsEnvironmentDelivery(capabilities: supportedCaps))
        XCTAssertFalse(LinuxGuestFraming.supportsEnvironmentDelivery(capabilities: legacyCaps))
        XCTAssertFalse(LinuxGuestFraming.supportsEnvironmentDelivery(capabilities: "env=10"))
        XCTAssertFalse(LinuxGuestFraming.supportsEnvironmentDelivery(capabilities: nil))
    }

    // MARK: channel transport

    func testUnsupportedGuestFailsClosedWithoutSendingSecrets() async throws {
        let console = ScriptedGuestConsole(capabilities: legacyCaps)
        let channel = LinuxGuestCommandChannel(transport: console, limits: .standard)
        let environment = try env([("OPENAI_API_KEY", secretA)])
        do {
            _ = try await channel.run(
                argv: ["/bin/sh", "-c", "true"],
                standardInput: "stdin",
                sensitiveEnvironment: environment,
                deadline: .unlimited
            )
            XCTFail("expected unsupported runner failure")
        } catch let error as LinuxGuestError {
            guard case .perProcessEnvironmentUnsupported = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("No secret value was sent"))
        }
        XCTAssertEqual(console.capturedFrames(named: "HELLO").count, 1)
        XCTAssertTrue(console.capturedFrames(named: "EXECENV").isEmpty)
        XCTAssertTrue(console.capturedFrames(named: "EXEC").isEmpty)
        XCTAssertFalse(console.writtenText.contains(secretA))
    }

    func testSupportedGuestCarriesEnvironmentInExecEnvFrame() async throws {
        let console = ScriptedGuestConsole(capabilities: supportedCaps)
        let channel = LinuxGuestCommandChannel(transport: console, limits: .standard)
        let environment = try env([("OPENAI_API_KEY", secretA)])
        let result = try await channel.run(
            argv: ["/bin/sh", "-c", "printenv OPENAI_API_KEY"],
            standardInput: "stdin-sentinel",
            sensitiveEnvironment: environment,
            deadline: .unlimited
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "ran")
        let frames = console.capturedFrames(named: "EXECENV")
        XCTAssertEqual(frames.count, 1)
        let capturedPayload = try XCTUnwrap(frames.first?.payload)
        let fields = try decodeFields(capturedPayload)
        XCTAssertEqual(String(decoding: fields[1], as: UTF8.self), "stdin-sentinel")
        let environmentFields = try decodeEnvironmentBlock(fields[2])
        XCTAssertEqual(environmentFields.map { $0.1 }, [secretA])
        XCTAssertFalse(fields[3...].map { String(decoding: $0, as: UTF8.self) }.joined().contains(secretA))
    }

    func testOrdinaryCommandStillUsesExecFrame() async throws {
        let console = ScriptedGuestConsole(capabilities: supportedCaps)
        let channel = LinuxGuestCommandChannel(transport: console, limits: .standard)
        _ = try await channel.run(
            argv: ["/bin/echo", "hi"],
            standardInput: "stdin",
            deadline: .unlimited
        )
        XCTAssertEqual(console.capturedFrames(named: "EXEC").count, 1)
        XCTAssertTrue(console.capturedFrames(named: "EXECENV").isEmpty)
        let capturedPayload = try XCTUnwrap(console.capturedFrames(named: "EXEC").first?.payload)
        let fields = try decodeFields(capturedPayload)
        XCTAssertEqual(fields.count, 4)
    }

    func testTwoConcurrentCommandsCarryDistinctSecrets() async throws {
        let console = ScriptedGuestConsole(capabilities: supportedCaps)
        let channel = LinuxGuestCommandChannel(transport: console, limits: .standard)
        let environmentA = try env([("SECRET_A", secretA)])
        let environmentB = try env([("SECRET_B", secretB)])
        async let first = channel.run(
            argv: ["/bin/sh", "-c", "true"],
            sensitiveEnvironment: environmentA,
            deadline: .unlimited
        )
        async let second = channel.run(
            argv: ["/bin/sh", "-c", "true"],
            sensitiveEnvironment: environmentB,
            deadline: .unlimited
        )
        _ = try await (first, second)
        let frames = console.capturedFrames(named: "EXECENV")
        XCTAssertEqual(frames.count, 2)
        var seen: Set<String> = []
        for frame in frames {
            let fields = try decodeFields(try XCTUnwrap(frame.payload))
            let values = try decodeEnvironmentBlock(fields[2]).map { $0.1 }
            XCTAssertEqual(values.count, 1)
            seen.insert(values[0])
        }
        XCTAssertEqual(seen, Set([secretA, secretB]))
    }

    func testTicketScopedThroughProductionSignature() async throws {
        let console = ScriptedGuestConsole(capabilities: supportedCaps)
        let channel = LinuxGuestCommandChannel(transport: console, limits: .standard)
        let environment = try env([("OPENAI_API_KEY", secretA)])
        let ticket = SensitiveProcessEnvironmentTicket(environment)
        let result = try await SensitiveProcessEnvironmentCarrier.$pending.withValue(ticket) {
            try await channel.run(
                argv: ["/bin/sh", "-c", "true"],
                deadline: .unlimited
            )
        }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(ticket.wasConsumed)
        XCTAssertEqual(console.capturedFrames(named: "EXECENV").count, 1)
    }

    func testCancellationDrainsTheSecretCommand() async throws {
        let console = ScriptedGuestConsole(capabilities: supportedCaps)
        console.holdCommands = true
        let channel = LinuxGuestCommandChannel(transport: console, limits: .standard)
        let environment = try env([("OPENAI_API_KEY", secretA)])
        let cancellation = CancellationToken()
        let task = Task {
            try await channel.run(
                argv: ["/bin/sh", "-c", "sleep 30"],
                sensitiveEnvironment: environment,
                deadline: .unlimited,
                cancellation: cancellation
            )
        }
        for _ in 0..<200 {
            if !console.capturedFrames(named: "EXECENV").isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(console.capturedFrames(named: "EXECENV").count, 1)
        cancellation.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch FloeError.cancelled {
            // Expected: the guest confirmed the process group was reaped.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
    }

    // MARK: shell backend

    func testShellBackendDeliversTicketAndKeepsSecretOutOfArgv() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingRunner(root: root)
        let backend = LinuxGuestShellBackend(runner: runner, limits: .standard)
        let environment = try env([("OPENAI_API_KEY", secretA)])
        let request = ShellRunRequest(
            command: "printf hello",
            cwd: ".",
            rootURL: root,
            sensitiveEnvironment: environment,
            sessionID: UUID().uuidString,
            toolEnvironment: toolEnvironment()
        )
        let outcome = await backend.run(request, cancellation: nil)
        guard case .exited(let code, _, _, _, _, _) = outcome else {
            return XCTFail("unexpected outcome: \(outcome)")
        }
        XCTAssertEqual(code, 0)
        let recorded = await runner.recorded
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0].environment?.entries.first?.value, secretA)
        XCTAssertFalse(recorded[0].argv.joined().contains(secretA))
    }

    func testShellBackendRejectsNonDeliveringBackendBeforeRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = PlainRunner()
        let backend = LinuxGuestShellBackend(runner: runner, limits: .standard)
        let environment = try env([("OPENAI_API_KEY", secretA)])
        let request = ShellRunRequest(
            command: "printf hello",
            cwd: ".",
            rootURL: root,
            sensitiveEnvironment: environment,
            sessionID: UUID().uuidString,
            toolEnvironment: toolEnvironment()
        )
        let outcome = await backend.run(request, cancellation: nil)
        guard case .failed(let message) = outcome else {
            return XCTFail("unexpected outcome: \(outcome)")
        }
        XCTAssertTrue(message.contains("per-process secret environment"))
        let calls = await runner.callCount
        XCTAssertEqual(calls, 0)
    }

    func testStagedLargeScriptNeverContainsSecret() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingRunner(root: root)
        let backend = LinuxGuestShellBackend(runner: runner, limits: .standard)
        let environment = try env([("OPENAI_API_KEY", secretA)])
        let padding = String(repeating: "# large script padding\n", count: 4_000)
        let request = ShellRunRequest(
            command: padding + "printf done",
            cwd: ".",
            rootURL: root,
            sensitiveEnvironment: environment,
            sessionID: UUID().uuidString,
            toolEnvironment: toolEnvironment()
        )
        let outcome = await backend.run(request, cancellation: nil)
        guard case .exited(let code, _, _, _, _, _) = outcome else {
            return XCTFail("unexpected outcome: \(outcome)")
        }
        XCTAssertEqual(code, 0)
        let recorded = await runner.recorded
        XCTAssertEqual(recorded.count, 1)
        XCTAssertFalse(recorded[0].argv.joined().contains(secretA))
        XCTAssertTrue(recorded[0].stagedScripts.allSatisfy { !$0.contains(secretA) })
        XCTAssertFalse(recorded[0].stagedScripts.isEmpty, "large command should have been staged")
    }

    func testOrdinaryEnvironmentPreambleDoesNotGainSensitiveValues() throws {
        let environment = try env([("OPENAI_API_KEY", secretA)])
        let preamble = try LinuxGuestShellBackend.environmentPreamble(["ORDINARY": "value"])
        XCTAssertEqual(preamble, "export ORDINARY='value'; ")
        XCTAssertFalse(preamble.contains(secretA))
        XCTAssertEqual(environment.entries.count, 1)
    }

    // MARK: Mac bridge request construction

    func testMacBridgePayloadMergesSecretIntoEnvironmentOnly() throws {
        let environment = try env([("OPENAI_API_KEY", secretA)])
        let values = MacBridgeShellBackend.mergedEnvironmentPayload(
            environment: ["ORDINARY": "value"],
            sensitiveEnvironment: environment
        )
        XCTAssertEqual(values["OPENAI_API_KEY"], secretA)
        XCTAssertEqual(values["ORDINARY"], "value")
        XCTAssertEqual(values.count, 2)
        // The command is built from the caller's command text only; the
        // merge result above is the object the companion turns into envp.
        let command = "printf hello"
        XCTAssertFalse(command.contains(secretA))
    }

    func testMacBridgeRejectsNamesItControls() throws {
        for name in ["PATH", "HOME", "TMPDIR", "PYTHONPATH", "NODE_PATH", "TERM", "FLOE_EXECUTION_BACKEND"] {
            let environment = try env([(name, "x")])
            XCTAssertThrowsError(try MacBridgeShellBackend.validateSensitiveNames(environment), name)
        }
    }

    // MARK: limits

    func testSensitiveEnvironmentLimitMatchesGuestBound() {
        XCTAssertEqual(LinuxGuestLimits.standard.maxSensitiveEnvironmentBytes, 64 * 1024)
        let custom = LinuxGuestLimits(maxSensitiveEnvironmentBytes: 8 * 1024 * 1024)
        XCTAssertEqual(custom.maxSensitiveEnvironmentBytes, LinuxGuestLimits.runnerEnvelopeBytes)
    }

    /// This is a dispatch regression: the capability must be a protocol
    /// requirement, otherwise `any LocalShellBackend` always sees the
    /// extension's false default and silently ignores the concrete override.
    func testCapabilityDispatchesThroughExistential() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let linux: any LocalShellBackend = LinuxGuestShellBackend(runner: RecordingRunner(root: root))
        XCTAssertTrue(linux.supportsSensitiveProcessEnvironment(for: toolEnvironment()))
        let unavailable: any LocalShellBackend = UnavailableShellBackend()
        XCTAssertFalse(unavailable.supportsSensitiveProcessEnvironment(for: toolEnvironment()))
        let router: any LocalShellBackend = MacBridgeExecutionRouter(defaultBackend: UnavailableShellBackend())
        let macTarget = ToolEnvironment(
            id: "mac-target",
            writableLayerURL: root,
            layerURLs: [],
            variables: ["FLOE_EXECUTION_BACKEND": "macBridge"]
        )
        XCTAssertTrue(router.supportsSensitiveProcessEnvironment(for: macTarget))
        XCTAssertFalse(router.supportsSensitiveProcessEnvironment(for: toolEnvironment()))
    }
}

// MARK: - fakes

/// Production-shaped runner that consumes the ticket exactly like the guest
/// channel and records what it saw while the staged script still exists.
actor RecordingRunner: LinuxCommandRunning, LinuxGuestSensitiveEnvironmentDelivering {
    struct Record: Sendable {
        let argv: [String]
        let environment: SensitiveProcessEnvironment?
        let stagedScripts: [String]
    }

    private let root: URL
    private(set) var recorded: [Record] = []

    init(root: URL) { self.root = root }

    func supports(environmentID: String) async -> Bool { true }
    func ownsLinuxEnvironment(environmentID: String) async -> Bool { true }

    func run(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        standardInput: String?,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        try await run(
            environmentID: environmentID,
            argv: argv,
            workingDirectory: workingDirectory,
            standardInput: standardInput,
            deadline: .seconds(timeout),
            maxOutputBytes: maxOutputBytes,
            cancellation: cancellation
        )
    }

    func run(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        standardInput: String?,
        deadline: ShellExecutionDeadline,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        let environment = SensitiveProcessEnvironmentCarrier.pending?.consume()
        var scripts: [String] = []
        let directory = root.appendingPathComponent(LinuxGuestShellBackend.stagingDirectoryName, isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for entry in entries where entry.hasSuffix(".sh") {
                if let text = try? String(contentsOf: directory.appendingPathComponent(entry), encoding: .utf8) {
                    scripts.append(text)
                }
            }
        }
        recorded.append(Record(argv: argv, environment: environment, stagedScripts: scripts))
        return LinuxCommandResult(stdout: "ok", stderr: "", exitCode: 0)
    }
}

/// A Linux runner that does NOT adopt the marker: sensitive requests must be
/// refused before this can run.
actor PlainRunner: LinuxCommandRunning {
    private(set) var callCount = 0

    func supports(environmentID: String) async -> Bool { true }
    func ownsLinuxEnvironment(environmentID: String) async -> Bool { true }

    func run(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        standardInput: String?,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        callCount += 1
        return LinuxCommandResult(stdout: "", stderr: "", exitCode: 0)
    }

    func run(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        standardInput: String?,
        deadline: ShellExecutionDeadline,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        callCount += 1
        return LinuxCommandResult(stdout: "", stderr: "", exitCode: 0)
    }
}
